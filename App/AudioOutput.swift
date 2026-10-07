import AVFoundation
import AudioToolbox

/// Something that fills audio on the real-time thread (no allocation, no locks, no Objective-C messaging).
protocol AudioRenderSource: AnyObject {
    func render(left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>, frames: Int)
}

/// RemoteIO output with the smallest I/O buffer iOS grants. The stream is fed as Float32 non-interleaved
/// stereo at the *stream* sample rate; RemoteIO converts to the hardware rate when they differ.
final class AudioOutput {
    struct SessionInfo {
        var hardwareRate: Double = 0
        var ioBufferMs: Double = 0        // granted by iOS (may be larger than requested)
        var requestedBufferMs: Double = 0
        var outputLatencyMs: Double = 0   // reported by iOS for the current route
        var route = ""
        var routeKind = RouteKind.unknown
    }

    enum RouteKind: String {
        case wired = "Con cable"
        case usb = "USB-C (con cable)"
        case bluetooth = "Bluetooth (no recomendado: añade 100-250 ms)"
        case speaker = "Altavoz del iPhone"
        case other = "Otra salida"
        case unknown = "—"
    }

    weak var source: AudioRenderSource?
    private var unit: AudioComponentInstance?
    private(set) var streamRate: Double = 0
    private(set) var info = SessionInfo()
    var onRouteChange: (() -> Void)?

    init() {
        NotificationCenter.default.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.refreshInfo()
            self?.onRouteChange?()
        }
    }

    /// frames: 64 / 128 / 256 at 48 kHz (1.33 / 2.67 / 5.33 ms)
    func configureSession(preferredFrames: Int) throws {
        let s = AVAudioSession.sharedInstance()
        try s.setCategory(.playback, mode: .default, options: [])
        try s.setPreferredSampleRate(48000)
        let seconds = Double(preferredFrames) / 48000
        try s.setPreferredIOBufferDuration(seconds)
        try s.setActive(true)
        info.requestedBufferMs = seconds * 1000
        refreshInfo()
    }

    func refreshInfo() {
        let s = AVAudioSession.sharedInstance()
        info.hardwareRate = s.sampleRate
        info.ioBufferMs = s.ioBufferDuration * 1000
        info.outputLatencyMs = s.outputLatency * 1000
        let out = s.currentRoute.outputs.first
        info.route = out?.portName ?? "—"
        switch out?.portType {
        case .some(.headphones): info.routeKind = .wired
        case .some(.usbAudio): info.routeKind = .usb
        case .some(.bluetoothA2DP), .some(.bluetoothLE), .some(.bluetoothHFP): info.routeKind = .bluetooth
        case .some(.builtInSpeaker), .some(.builtInReceiver): info.routeKind = .speaker
        case .none: info.routeKind = .unknown
        default: info.routeKind = .other
        }
    }

    func start(streamRate rate: Double) throws {
        if unit != nil && rate == streamRate { return }
        stop()

        var desc = AudioComponentDescription(componentType: kAudioUnitType_Output,
                                             componentSubType: kAudioUnitSubType_RemoteIO,
                                             componentManufacturer: kAudioUnitManufacturer_Apple,
                                             componentFlags: 0, componentFlagsMask: 0)
        guard let comp = AudioComponentFindNext(nil, &desc) else { throw NSError(domain: "UltraAudio", code: 1) }
        var newUnit: AudioComponentInstance?
        try check(AudioComponentInstanceNew(comp, &newUnit))
        guard let u = newUnit else { throw NSError(domain: "UltraAudio", code: 2) }

        var format = AudioStreamBasicDescription(
            mSampleRate: rate, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | kAudioFormatFlagIsNonInterleaved,
            mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4, mChannelsPerFrame: 2, mBitsPerChannel: 32, mReserved: 0)
        try check(AudioUnitSetProperty(u, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0,
                                       &format, UInt32(MemoryLayout<AudioStreamBasicDescription>.size)))

        var maxFrames: UInt32 = 4096
        AudioUnitSetProperty(u, kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0,
                             &maxFrames, UInt32(MemoryLayout<UInt32>.size))

        var callback = AURenderCallbackStruct(inputProc: ultraRenderProc,
                                              inputProcRefCon: Unmanaged.passUnretained(self).toOpaque())
        try check(AudioUnitSetProperty(u, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0,
                                       &callback, UInt32(MemoryLayout<AURenderCallbackStruct>.size)))
        try check(AudioUnitInitialize(u))
        try check(AudioOutputUnitStart(u))
        unit = u
        streamRate = rate
        refreshInfo()
    }

    func stop() {
        guard let u = unit else { return }
        AudioOutputUnitStop(u)
        AudioUnitUninitialize(u)
        AudioComponentInstanceDispose(u)
        unit = nil
        streamRate = 0
    }

    private func check(_ status: OSStatus) throws {
        if status != noErr { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
    }

    fileprivate func renderInto(_ ioData: UnsafeMutablePointer<AudioBufferList>, frames: Int) {
        let buffers = UnsafeMutableAudioBufferListPointer(ioData)
        guard buffers.count >= 2,
              let l = buffers[0].mData?.assumingMemoryBound(to: Float.self),
              let r = buffers[1].mData?.assumingMemoryBound(to: Float.self) else { return }
        if let src = source {
            src.render(left: l, right: r, frames: frames)
        } else {
            l.update(repeating: 0, count: frames)
            r.update(repeating: 0, count: frames)
        }
    }
}

/// Real-time render callback (C function pointer).
private let ultraRenderProc: AURenderCallback = { refCon, _, _, _, frames, ioData in
    guard let ioData else { return noErr }
    let output = Unmanaged<AudioOutput>.fromOpaque(refCon).takeUnretainedValue()
    output.renderInto(ioData, frames: Int(frames))
    return noErr
}
