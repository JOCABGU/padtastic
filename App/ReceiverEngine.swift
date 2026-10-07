import AVFoundation
import Foundation
import Network
import QuartzCore
import UltraAudioCore
import CUltraAtomics
#if canImport(UIKit)
import UIKit
#endif

/// Padtastic's sockets are IPv4: keep control and audio on IPv4 so the computer can answer the
/// address it sees (Bonjour may otherwise resolve to an IPv6 link-local address).
private func ipv4(_ params: NWParameters) -> NWParameters {
    if let ip = params.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options { ip.version = .v4 }
    return params
}

struct DiscoveredServer: Identifiable, Hashable {
    let id: String          // Bonjour instance name or "ip:port"
    let name: String
    let endpoint: NWEndpoint
}

struct LiveStats {
    var connected = false
    var serverName = ""
    var streamRate: Double = 0
    var framesPerPacket = 0
    var received: Int64 = 0
    var lost: Int64 = 0
    var late: Int64 = 0
    var underruns: Int64 = 0
    var jitterMs: Double = 0
    var bufferMs: Double = 0
    var targetMs: Double = 0
    var driftPpm: Double = 0
    var rttMs: Double = 0
    var level: Float = 0
    var session = AudioOutput.SessionInfo()

    var lossPercent: Double { received + lost > 0 ? 100 * Double(lost) / Double(received + lost) : 0 }
    /// Estimate, not a measurement: half the network round trip + jitter buffer + iOS I/O buffer + route latency.
    var estimatedLatencyMs: Double { rttMs / 2 + bufferMs + session.ioBufferMs + session.outputLatencyMs }
}

/// Owns the network side (control TCP, audio UDP, Bonjour) and the audio side (jitter buffer + RemoteIO).
final class ReceiverEngine: ObservableObject, AudioRenderSource {
    enum Phase: String {
        case idle = "Listo para conectar"
        case connecting = "Conectando…"
        case needsCode = "Escribe el código que muestra Padtastic"
        case connected = "Recibiendo audio"
        case reconnecting = "Reconectando…"
        case denied = "Conexión rechazada"
    }

    @Published var phase: Phase = .idle
    @Published var servers: [DiscoveredServer] = []
    @Published var stats = LiveStats()
    @Published var message = ""
    @Published var preferredFrames = 128

    let buffer = UltraJitterBuffer()
    let audio = AudioOutput()
    private let udpPort: UInt16 = UltraProtocol.defaultAudioPort
    private let netQueue = DispatchQueue(label: "ultra.udp", qos: .userInteractive)
    private let controlQueue = DispatchQueue(label: "ultra.control", qos: .userInitiated)

    // Shared with the audio thread / UDP queue through C atomics: [session, playable, renderCount, udpBusy, levelBits]
    private let flags = UnsafeMutablePointer<Int64>.allocate(capacity: 5)
    private enum F: Int { case session = 0, playable, renderCount, udpBusy, level }

    private var listener: NWListener?
    private var browser: NWBrowser?
    private var control: NWConnection?
    private var target: DiscoveredServer?
    private var code = ""
    private var pending = Data()
    private var pingTimer: DispatchSourceTimer?
    private var pingId = 0
    private var lastHeard = CACurrentMediaTime()
    private var rttMs = 0.0
    private var wantConnection = false
    private var statsTimer: Timer?

    init() {
        flags.initialize(repeating: 0, count: 5)
        audio.source = self
        audio.onRouteChange = { [weak self] in self?.refreshStats() }
        statsTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in self?.refreshStats() }
    }

    deinit { flags.deallocate() }

    // MARK: - lifecycle

    func startServices() {
        do {
            try audio.configureSession(preferredFrames: preferredFrames)
            try audio.start(streamRate: 48000)
        } catch {
            message = "No se pudo iniciar el audio: \(error.localizedDescription)"
        }
        startUdp()
        startBrowsing()
    }

    func applyPreferredBuffer() {
        try? audio.configureSession(preferredFrames: preferredFrames)
        refreshStats()
    }

    private func startUdp() {
        guard listener == nil else { return }
        let params = ipv4(NWParameters.udp)
        params.serviceClass = .interactiveVoice     // lowest-latency Wi-Fi access category
        params.allowLocalEndpointReuse = true
        do {
            let l = try NWListener(using: params, on: NWEndpoint.Port(rawValue: udpPort)!)
            l.newConnectionHandler = { [weak self] conn in
                guard let self else { return }
                conn.start(queue: self.netQueue)
                self.receive(on: conn)
            }
            l.start(queue: netQueue)
            listener = l
        } catch {
            message = "No se pudo abrir el puerto UDP \(udpPort): \(error.localizedDescription)"
        }
    }

    private func receive(on conn: NWConnection) {
        conn.receiveMessage { [weak self] data, _, _, error in
            guard let self else { return }
            if let data { self.handleDatagram(data) }
            if error == nil { self.receive(on: conn) } else { conn.cancel() }
        }
    }

    private func handleDatagram(_ data: Data) {
        let arrival = CACurrentMediaTime()
        data.withUnsafeBytes { raw in
            guard let h = ultraParse(raw), let base = raw.baseAddress else { return }
            ua_store(flags + F.udpBusy.rawValue, 1)
            let session = ua_load(flags + F.session.rawValue)
            if session != 0 && Int64(h.session) == session {
                buffer.push(h, payload: base + UltraProtocol.headerSize, arrival: arrival)
            }
            ua_store(flags + F.udpBusy.rawValue, 0)
        }
    }

    // MARK: - discovery

    private func startBrowsing() {
        let b = NWBrowser(for: .bonjour(type: UltraProtocol.bonjourType, domain: nil), using: .tcp)
        b.browseResultsChangedHandler = { [weak self] results, _ in
            let found: [DiscoveredServer] = results.compactMap { r in
                if case let .service(name, _, _, _) = r.endpoint { return DiscoveredServer(id: name, name: name, endpoint: r.endpoint) }
                return nil
            }
            DispatchQueue.main.async {
                guard let self else { return }
                self.servers = found.sorted { $0.name < $1.name }
                // reconnect by itself to a computer we already paired with
                if self.control == nil, let known = self.servers.first(where: { self.savedToken(for: $0.id) != nil }) {
                    self.connect(to: known, code: "")
                }
            }
        }
        b.start(queue: controlQueue)
        browser = b
    }

    func manualServer(host: String, port: UInt16) -> DiscoveredServer? {
        guard let p = NWEndpoint.Port(rawValue: port), !host.isEmpty else { return nil }
        return DiscoveredServer(id: "\(host):\(port)", name: host, endpoint: .hostPort(host: NWEndpoint.Host(host), port: p))
    }

    // MARK: - control channel

    func connect(to server: DiscoveredServer, code: String) {
        disconnect()
        target = server
        self.code = code
        wantConnection = true
        openControl()
    }

    func disconnect() {
        wantConnection = false
        pingTimer?.cancel()
        pingTimer = nil
        if let c = control { send(["type": "bye"], on: c); c.cancel() }
        control = nil
        ua_store(flags + F.session.rawValue, 0)
        phase = .idle
    }

    private func openControl() {
        guard wantConnection, let server = target else { return }
        phase = phase == .connected ? .reconnecting : .connecting
        let tcp = ipv4(NWParameters.tcp)
        tcp.serviceClass = .responsiveData
        let conn = NWConnection(to: server.endpoint, using: tcp)
        control = conn
        pending.removeAll()
        conn.stateUpdateHandler = { [weak self, weak conn] state in
            guard let self, let conn else { return }
            switch state {
            case .ready:
                self.lastHeard = CACurrentMediaTime()
                var hello: [String: Any] = ["type": "hello", "protocol": 1, "name": deviceName(), "udpPort": Int(self.udpPort)]
                if let token = self.savedToken(for: server.id) { hello["token"] = token } else { hello["code"] = self.code }
                self.send(hello, on: conn)
                self.readLines(on: conn)
                self.startPings(on: conn)
            case .failed, .cancelled:
                self.connectionLost(conn)
            default:
                break
            }
        }
        conn.start(queue: controlQueue)
    }

    private func connectionLost(_ conn: NWConnection) {
        guard conn === control else { return }
        ua_store(flags + F.playable.rawValue, 0)
        ua_store(flags + F.session.rawValue, 0)
        pingTimer?.cancel()
        control = nil
        DispatchQueue.main.async { if self.wantConnection { self.phase = .reconnecting } }
        if wantConnection {
            controlQueue.asyncAfter(deadline: .now() + 1) { [weak self] in
                DispatchQueue.main.async { self?.openControl() }
            }
        }
    }

    private func startPings(on conn: NWConnection) {
        pingTimer?.cancel()
        let t = DispatchSource.makeTimerSource(queue: controlQueue)
        t.schedule(deadline: .now() + 0.5, repeating: 0.5)
        var tick = 0
        t.setEventHandler { [weak self, weak conn] in
            guard let self, let conn else { return }
            if CACurrentMediaTime() - self.lastHeard > 3 { conn.cancel(); return } // computer gone
            self.pingId += 1
            self.send(["type": "ping", "id": self.pingId, "t": CACurrentMediaTime() * 1000], on: conn)
            tick += 1
            if tick % 2 == 0 { self.sendStats(on: conn) }
        }
        t.resume()
        pingTimer = t
    }

    private func sendStats(on conn: NWConnection) {
        let st = buffer.stats
        let info = audio.info
        let s = stats
        send(["type": "stats", "received": st.received, "lost": st.lost, "late": st.late,
              "underruns": st.underruns, "overruns": st.overruns, "jitterMs": st.jitterMs,
              "bufferMs": st.fillMs, "targetMs": st.targetMs, "driftPpm": st.driftPpm, "rttMs": rttMs,
              "ioBufferMs": info.ioBufferMs, "outputLatencyMs": info.outputLatencyMs,
              "hardwareRate": info.hardwareRate, "headphones": info.routeKind.rawValue,
              "latencyMs": s.estimatedLatencyMs, "device": deviceName()], on: conn)
    }

    private func send(_ object: [String: Any], on conn: NWConnection) {
        guard var data = try? JSONSerialization.data(withJSONObject: object) else { return }
        data.append(0x0A)
        conn.send(content: data, completion: .contentProcessed { _ in })
    }

    private func readLines(on conn: NWConnection) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 16384) { [weak self] data, _, done, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                self.lastHeard = CACurrentMediaTime()
                self.pending.append(data)
                while let nl = self.pending.firstIndex(of: 0x0A) {
                    let line = self.pending[self.pending.startIndex..<nl]
                    self.pending.removeSubrange(self.pending.startIndex...nl)
                    if let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any] { self.handle(obj, conn: conn) }
                }
            }
            if done || error != nil { conn.cancel() } else { self.readLines(on: conn) }
        }
    }

    private func handle(_ msg: [String: Any], conn: NWConnection) {
        switch msg["type"] as? String {
        case "welcome", "format":
            if let token = msg["token"] as? String, let id = target?.id { saveToken(token, for: id) }
            let rate = (msg["sampleRate"] as? Double) ?? 48000
            let frames = (msg["framesPerPacket"] as? Int) ?? 48
            let session = (msg["session"] as? NSNumber)?.int64Value ?? 0
            let server = msg["server"] as? String
            configure(rate: rate, frames: frames, session: session)
            if let ms = msg["bufferMs"] as? Double { applyBuffer(ms) }
            DispatchQueue.main.async {
                self.phase = .connected
                if let server { self.stats.serverName = server }
                self.message = ""
            }
        case "config":
            applyBuffer((msg["bufferMs"] as? Double) ?? 0)
        case "pong":
            if let t = msg["t"] as? Double { rttMs = CACurrentMediaTime() * 1000 - t }
        case "denied":
            let reason = msg["reason"] as? String ?? ""
            wantConnection = false
            if reason == "not_paired", let id = target?.id { forgetToken(for: id) }
            DispatchQueue.main.async {
                self.phase = reason == "not_paired" ? .needsCode : .denied
                self.message = [
                    "bad_code": "Código incorrecto.",
                    "blocked": "Demasiados intentos: espera 30 s.",
                    "not_paired": "Este iPhone no está emparejado: escribe el código.",
                    "protocol": "Versión de Padtastic incompatible.",
                ][reason] ?? "Rechazado (\(reason))."
            }
            conn.cancel()
        default:
            break
        }
    }

    private func applyBuffer(_ ms: Double) {
        if ms <= 0 { buffer.setTargetPolicy(adaptive: true, ms: 3) } else { buffer.setTargetPolicy(adaptive: false, ms: ms) }
    }

    /// Rebuilds the jitter buffer for a new stream. Stops feeding/playing and waits until both the UDP
    /// queue and the audio thread have left it (same handshake as the tested C++ receiver).
    private func configure(rate: Double, frames: Int, session: Int64) {
        ua_store(flags + F.playable.rawValue, 0)
        ua_store(flags + F.session.rawValue, 0)
        let seen = ua_load(flags + F.renderCount.rawValue)
        let deadline = CACurrentMediaTime() + 0.1
        while (ua_load(flags + F.udpBusy.rawValue) != 0 || ua_load(flags + F.renderCount.rawValue) == seen) && CACurrentMediaTime() < deadline {
            usleep(1000)
        }
        var cfg = UltraJitterBuffer.Config()
        cfg.sampleRate = rate
        cfg.framesPerPacket = frames
        buffer.reset(cfg)
        DispatchQueue.main.sync { try? self.audio.start(streamRate: rate) }
        ua_store(flags + F.session.rawValue, session)
        ua_store(flags + F.playable.rawValue, 1)
        DispatchQueue.main.async {
            self.stats.streamRate = rate
            self.stats.framesPerPacket = frames
        }
    }

    // MARK: - audio thread

    func render(left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>, frames: Int) {
        if ua_load(flags + F.playable.rawValue) != 0 {
            buffer.pull(left: left, right: right, frames: frames)
            var peak: Float = 0
            for i in 0..<frames { peak = max(peak, abs(left[i]), abs(right[i])) }
            ua_store(flags + F.level.rawValue, Int64(peak.bitPattern))
        } else {
            left.update(repeating: 0, count: frames)
            right.update(repeating: 0, count: frames)
        }
        _ = ua_fetch_add(flags + F.renderCount.rawValue, 1)
    }

    // MARK: - UI

    private func refreshStats() {
        let st = buffer.stats
        var s = stats
        s.connected = phase == .connected
        s.received = st.received; s.lost = st.lost; s.late = st.late; s.underruns = st.underruns
        s.jitterMs = st.jitterMs; s.bufferMs = st.fillMs; s.targetMs = st.targetMs; s.driftPpm = st.driftPpm
        s.rttMs = rttMs
        let level = Float(bitPattern: UInt32(truncatingIfNeeded: ua_load(flags + F.level.rawValue)))
        s.level = max(level, s.level * 0.8)
        audio.refreshInfo()
        s.session = audio.info
        stats = s
    }

    // MARK: - pairing tokens (one per computer)

    private func savedToken(for id: String) -> String? { UserDefaults.standard.string(forKey: "ultra.token.\(id)") }
    private func saveToken(_ t: String, for id: String) { UserDefaults.standard.set(t, forKey: "ultra.token.\(id)") }
    private func forgetToken(for id: String) { UserDefaults.standard.removeObject(forKey: "ultra.token.\(id)") }
}

private func deviceName() -> String {
    #if canImport(UIKit)
    return UIDevice.current.name
    #else
    return Host.current().localizedName ?? "Receptor"
    #endif
}
