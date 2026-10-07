// Padtastic UltraAudio wire format (ULTRAAUDIO_PROTOCOL.md). Must match src/ultra/UltraProtocol.h.
// All multi-byte fields are little-endian, read/written byte by byte (independent of the CPU).

public enum UltraProtocol {
    public static let magic: UInt16 = 0x4155         // bytes "UA" on the wire
    public static let version: UInt8 = 1
    public static let typeAudio: UInt8 = 1
    public static let formatPCMS16: UInt8 = 1
    public static let headerSize = 24
    public static let maxFrames = 480
    public static let maxChannels = 2
    public static let maxPacketSize = headerSize + maxFrames * maxChannels * 2
    public static let defaultControlPort: UInt16 = 49200 // TCP on the computer
    public static let defaultAudioPort: UInt16 = 49201   // UDP on the iPhone
    public static let bonjourType = "_padtastic._tcp"
}

public struct UltraHeader: Equatable {
    public var magic: UInt16 = UltraProtocol.magic
    public var version: UInt8 = UltraProtocol.version
    public var type: UInt8 = UltraProtocol.typeAudio
    public var session: UInt32 = 0
    public var sequence: UInt32 = 0
    public var sampleCounter: UInt32 = 0
    public var frameCount: UInt16 = 0
    public var payloadBytes: UInt16 = 0
    public var channels: UInt8 = 2
    public var format: UInt8 = UltraProtocol.formatPCMS16
    public var flags: UInt16 = 0

    public init() {}

    @inline(__always) static func get16(_ p: UnsafeRawPointer, _ o: Int) -> UInt16 {
        UInt16(p.load(fromByteOffset: o, as: UInt8.self)) | (UInt16(p.load(fromByteOffset: o + 1, as: UInt8.self)) << 8)
    }

    @inline(__always) static func get32(_ p: UnsafeRawPointer, _ o: Int) -> UInt32 {
        UInt32(get16(p, o)) | (UInt32(get16(p, o + 2)) << 16)
    }

    @inline(__always) static func put16(_ p: UnsafeMutableRawPointer, _ o: Int, _ v: UInt16) {
        p.storeBytes(of: UInt8(truncatingIfNeeded: v), toByteOffset: o, as: UInt8.self)
        p.storeBytes(of: UInt8(truncatingIfNeeded: v >> 8), toByteOffset: o + 1, as: UInt8.self)
    }

    @inline(__always) static func put32(_ p: UnsafeMutableRawPointer, _ o: Int, _ v: UInt32) {
        put16(p, o, UInt16(truncatingIfNeeded: v))
        put16(p, o + 2, UInt16(truncatingIfNeeded: v >> 16))
    }

    /// Reads the 24-byte header at `p` (caller guarantees 24 readable bytes).
    public static func read(_ p: UnsafeRawPointer) -> UltraHeader {
        var h = UltraHeader()
        h.magic = get16(p, 0)
        h.version = p.load(fromByteOffset: 2, as: UInt8.self)
        h.type = p.load(fromByteOffset: 3, as: UInt8.self)
        h.session = get32(p, 4)
        h.sequence = get32(p, 8)
        h.sampleCounter = get32(p, 12)
        h.frameCount = get16(p, 16)
        h.payloadBytes = get16(p, 18)
        h.channels = p.load(fromByteOffset: 20, as: UInt8.self)
        h.format = p.load(fromByteOffset: 21, as: UInt8.self)
        h.flags = get16(p, 22)
        return h
    }

    public func write(to p: UnsafeMutableRawPointer) {
        UltraHeader.put16(p, 0, magic)
        p.storeBytes(of: version, toByteOffset: 2, as: UInt8.self)
        p.storeBytes(of: type, toByteOffset: 3, as: UInt8.self)
        UltraHeader.put32(p, 4, session)
        UltraHeader.put32(p, 8, sequence)
        UltraHeader.put32(p, 12, sampleCounter)
        UltraHeader.put16(p, 16, frameCount)
        UltraHeader.put16(p, 18, payloadBytes)
        p.storeBytes(of: channels, toByteOffset: 20, as: UInt8.self)
        p.storeBytes(of: format, toByteOffset: 21, as: UInt8.self)
        UltraHeader.put16(p, 22, flags)
    }
}

/// Validates a datagram. Returns the header, or nil for anything malformed (the payload starts at byte 24).
public func ultraParse(_ data: UnsafeRawBufferPointer) -> UltraHeader? {
    guard let base = data.baseAddress, data.count >= UltraProtocol.headerSize else { return nil }
    let h = UltraHeader.read(base)
    guard h.magic == UltraProtocol.magic, h.version == UltraProtocol.version,
          h.type == UltraProtocol.typeAudio, h.format == UltraProtocol.formatPCMS16,
          h.channels >= 1, Int(h.channels) <= UltraProtocol.maxChannels,
          h.frameCount >= 1, Int(h.frameCount) <= UltraProtocol.maxFrames,
          Int(h.payloadBytes) == Int(h.frameCount) * Int(h.channels) * 2,
          data.count == UltraProtocol.headerSize + Int(h.payloadBytes) else { return nil }
    return h
}

@inline(__always) public func ultraFloatToS16(_ x: Float) -> Int16 {
    let c = max(-1, min(1, x)) * 32767
    return Int16(c >= 0 ? c + 0.5 : c - 0.5)
}

@inline(__always) public func ultraS16ToFloat(_ v: Int16) -> Float { Float(v) / 32768 }

/// Signed distance a - b of wrapping 32-bit counters.
@inline(__always) public func ultraWrapDiff(_ a: UInt32, _ b: UInt32) -> Int64 {
    Int64(Int32(bitPattern: a &- b))
}

/// Builds a datagram (used by tests and tools).
public func ultraBuildPacket(_ header: UltraHeader, left: [Float], right: [Float]) -> [UInt8] {
    var h = header
    h.frameCount = UInt16(left.count)
    h.payloadBytes = UInt16(left.count * Int(h.channels) * 2)
    var out = [UInt8](repeating: 0, count: UltraProtocol.headerSize + Int(h.payloadBytes))
    out.withUnsafeMutableBytes { buf in
        let p = buf.baseAddress!
        h.write(to: p)
        var o = UltraProtocol.headerSize
        for i in 0..<left.count {
            UltraHeader.put16(p, o, UInt16(bitPattern: ultraFloatToS16(left[i]))); o += 2
            if h.channels == 2 { UltraHeader.put16(p, o, UInt16(bitPattern: ultraFloatToS16(right[i]))); o += 2 }
        }
    }
    return out
}
