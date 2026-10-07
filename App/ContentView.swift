import SwiftUI

private let accent = Color(red: 1.0, green: 0.294, blue: 0.122)   // #FF4B1F, same as the desktop app
private let cream = Color(red: 0.945, green: 0.922, blue: 0.875)
private let panel = Color(white: 0.07)
private let line = Color(white: 0.16)

struct ContentView: View {
    @StateObject private var engine = ReceiverEngine()
    @State private var code = ""
    @State private var manualHost = ""
    @State private var manualPort = "49200"
    @State private var selected: DiscoveredServer?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                statusCard
                if engine.phase != .connected { connectCard }
                statsCard
                bufferCard
                Text("La latencia mostrada es una estimación (red/2 + búfer + búfer de iOS + salida). Para medirla de verdad usa la prueba de loopback de ULTRAAUDIO_TESTING.md.")
                    .font(.system(size: 11, design: .monospaced)).foregroundColor(.gray)
            }
            .padding(20)
        }
        .background(Color.black.ignoresSafeArea())
        .preferredColorScheme(.dark)
        .onAppear { engine.startServices() }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Grid(horizontalSpacing: 3, verticalSpacing: 3) {
                GridRow { square; square }
                GridRow { square; square }
            }
            Text("padtastic").font(.system(size: 24, weight: .medium))
            Text("ULTRAAUDIO").font(.system(size: 11, design: .monospaced)).foregroundColor(.gray)
            Spacer()
        }
    }

    private var square: some View { RoundedRectangle(cornerRadius: 2).fill(accent).frame(width: 10, height: 10) }

    private var statusCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Circle().fill(engine.phase == .connected ? accent : Color.gray).frame(width: 10, height: 10)
                Text(engine.phase.rawValue).font(.system(size: 18, weight: .bold))
                Spacer()
                if engine.phase == .connected || engine.phase == .reconnecting {
                    Button("Desconectar") { engine.disconnect() }.buttonStyle(.bordered).tint(cream)
                }
            }
            if !engine.stats.serverName.isEmpty {
                Text("Computadora: \(engine.stats.serverName)").font(.system(size: 14, design: .monospaced))
            }
            if !engine.message.isEmpty {
                Text(engine.message).foregroundColor(accent).font(.system(size: 13))
            }
            meter
        }
        .card()
    }

    private var meter: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Rectangle().fill(line)
                Rectangle().fill(accent).frame(width: g.size.width * CGFloat(min(1, max(0, (20 * log10(max(1e-5, Double(engine.stats.level))) + 60) / 60))))
            }
        }
        .frame(height: 8)
    }

    private var connectCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("COMPUTADORAS EN LA RED").font(.system(size: 11, design: .monospaced)).foregroundColor(.gray)
            if engine.servers.isEmpty {
                Text("Buscando Padtastic… (misma red Wi-Fi, UltraAudio activado en la PC)").foregroundColor(.gray).font(.system(size: 13))
            }
            ForEach(engine.servers) { s in
                Button { selected = s } label: {
                    HStack {
                        Text(s.name).foregroundColor(.white)
                        Spacer()
                        if selected == s { Image(systemName: "checkmark").foregroundColor(accent) }
                    }
                    .padding(10).background(selected == s ? line : panel).cornerRadius(4)
                }
            }
            Text("O ESCRIBE LA IP QUE MUESTRA PADTASTIC").font(.system(size: 11, design: .monospaced)).foregroundColor(.gray)
            HStack {
                TextField("192.168.1.34", text: $manualHost).keyboardType(.numbersAndPunctuation).textFieldStyle(.roundedBorder)
                TextField("49200", text: $manualPort).keyboardType(.numberPad).frame(width: 80).textFieldStyle(.roundedBorder)
            }
            Text("CÓDIGO DE EMPAREJAMIENTO (solo la primera vez)").font(.system(size: 11, design: .monospaced)).foregroundColor(.gray)
            TextField("6 dígitos", text: $code).keyboardType(.numberPad).font(.system(size: 28, weight: .bold, design: .monospaced))
                .textFieldStyle(.roundedBorder)
            Button {
                let server = manualHost.isEmpty ? selected : engine.manualServer(host: manualHost, port: UInt16(manualPort) ?? 49200)
                if let server { engine.connect(to: server, code: code) }
            } label: {
                Text("Conectar").bold().frame(maxWidth: .infinity).padding(12).background(accent).foregroundColor(.white).cornerRadius(4)
            }
        }
        .card()
    }

    private var statsCard: some View {
        let s = engine.stats
        return VStack(alignment: .leading, spacing: 10) {
            Text("ESTADÍSTICAS").font(.system(size: 11, design: .monospaced)).foregroundColor(.gray)
            row("Latencia estimada*", String(format: "%.1f ms", s.estimatedLatencyMs))
            row("  · red (RTT/2)", String(format: "%.1f ms", s.rttMs / 2))
            row("  · búfer de jitter", String(format: "%.1f / %.1f ms", s.bufferMs, s.targetMs))
            row("  · búfer de iOS (concedido)", String(format: "%.2f ms (pedido %.2f)", s.session.ioBufferMs, s.session.requestedBufferMs))
            row("  · salida (iOS)", String(format: "%.1f ms", s.session.outputLatencyMs))
            row("Jitter de red", String(format: "%.2f ms", s.jitterMs))
            row("Pérdida", String(format: "%.2f %% (%lld)", s.lossPercent, s.lost))
            row("Tardíos / cortes", "\(s.late) / \(s.underruns)")
            row("Corrección de deriva", String(format: "%.0f ppm", s.driftPpm))
            row("Audio recibido", s.streamRate > 0 ? String(format: "%.0f Hz · %d frames/paquete", s.streamRate, s.framesPerPacket) : "—")
            row("Hardware iPhone", String(format: "%.0f Hz", s.session.hardwareRate))
            row("Audífonos", "\(s.session.routeKind.rawValue) · \(s.session.route)")
            if s.session.routeKind == .bluetooth || s.session.routeKind == .speaker {
                Text("Conecta audífonos con cable (USB-C o adaptador) para la menor latencia.").foregroundColor(accent).font(.system(size: 12))
            }
        }
        .card()
    }

    private var bufferCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("BÚFER DE AUDIO DEL IPHONE").font(.system(size: 11, design: .monospaced)).foregroundColor(.gray)
            Picker("Búfer", selection: $engine.preferredFrames) {
                Text("1.3 ms").tag(64)
                Text("2.7 ms").tag(128)
                Text("5.3 ms").tag(256)
            }
            .pickerStyle(.segmented)
            .onChange(of: engine.preferredFrames) { _ in engine.applyPreferredBuffer() }
            Text("iOS decide el valor final; arriba se muestra el concedido. El búfer de red se ajusta desde Padtastic (UltraAudio → Búfer del iPhone).")
                .font(.system(size: 11)).foregroundColor(.gray)
        }
        .card()
    }

    private func row(_ k: String, _ v: String) -> some View {
        HStack {
            Text(k).foregroundColor(.gray)
            Spacer()
            Text(v).foregroundColor(.white)
        }
        .font(.system(size: 13, design: .monospaced))
    }
}

private extension View {
    func card() -> some View {
        padding(16).frame(maxWidth: .infinity, alignment: .leading)
            .background(panel)
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(line))
    }
}
