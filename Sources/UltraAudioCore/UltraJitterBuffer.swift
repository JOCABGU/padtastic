// Receiver core: same algorithm as src/ultra/UltraJitterBuffer.cpp (the tested C++ reference).
// push() runs on the network queue, pull() on the real-time audio thread: no locks, no allocation,
// shared values go through C11 atomics (CUltraAtomics). reset() allocates: call it only while
// neither push() nor pull() can run (see ReceiverEngine.configure).

import CUltraAtomics
import Foundation

public final class UltraJitterBuffer {
    public struct Config {
        public var sampleRate: Double = 48000
        public var channels: Int = 2
        public var framesPerPacket: Int = 48
        public var minTargetMs: Double = 3
        public var maxTargetMs: Double = 60
        public var adaptive: Bool = true
        public var fixedTargetMs: Double = 5
        public var capacityFrames: Int = 32768
        public init() {}
    }

    public struct Stats {
        public var received: Int64 = 0, lost: Int64 = 0, late: Int64 = 0, duplicates: Int64 = 0
        public var reordered: Int64 = 0, rejected: Int64 = 0, underruns: Int64 = 0, overruns: Int64 = 0
        public var concealedFrames: Int64 = 0
        public var jitterMs: Double = 0, targetMs: Double = 0, fillMs: Double = 0, driftPpm: Double = 0
        public init() {}
    }

    // Shared (cross-thread) values, stored as Int64 (doubles as bit patterns)
    private enum K: Int, CaseIterable {
        case latestEnd, readFrame, anyData, target, pullFrames, policyAdaptive, policyMs
        case received, late, dup, reorder, rejected, under, over, concealed, lost, jitter, fill, drift
    }

    public private(set) var config = Config()
    private let shared: UnsafeMutablePointer<Int64>
    private var ring: UnsafeMutablePointer<Float>
    private var stamp: UnsafeMutablePointer<Int64>
    private var capacity = 0
    private var numSlots = 0

    // writer side (network queue)
    private var haveFirst = false
    private var lastExt: Int64 = 0
    private var highestSeq: UInt32 = 0
    private var firstSeq: UInt32 = 0
    private var lastTransit = 0.0, jitterSec = 0.0, baseline = 0.0, peakDev = 0.0

    // reader side (audio thread)
    private var started = false
    private var pos = 0.0, fillAvg = 0.0, gain = 0.0
    private var lastL: Float = 0, lastR: Float = 0

    public init(config: Config = Config()) {
        shared = .allocate(capacity: K.allCases.count)
        shared.initialize(repeating: 0, count: K.allCases.count)
        ring = .allocate(capacity: 1)
        stamp = .allocate(capacity: 1)
        reset(config)
    }

    deinit {
        shared.deallocate()
        ring.deallocate()
        stamp.deallocate()
    }

    @inline(__always) private func ld(_ k: K) -> Int64 { ua_load(shared + k.rawValue) }
    @inline(__always) private func st(_ k: K, _ v: Int64) { ua_store(shared + k.rawValue, v) }
    @inline(__always) private func inc(_ k: K, _ v: Int64 = 1) { _ = ua_fetch_add(shared + k.rawValue, v) }
    @inline(__always) private func ldD(_ k: K) -> Double { Double(bitPattern: UInt64(bitPattern: ld(k))) }
    @inline(__always) private func stD(_ k: K, _ v: Double) { st(k, Int64(bitPattern: v.bitPattern)) }

    public func reset(_ c: Config) {
        config = c
        numSlots = max(8, (c.capacityFrames + c.framesPerPacket - 1) / c.framesPerPacket)
        capacity = numSlots * c.framesPerPacket
        config.capacityFrames = capacity

        ring.deallocate()
        stamp.deallocate()
        ring = .allocate(capacity: capacity * c.channels)
        ring.initialize(repeating: 0, count: capacity * c.channels)
        stamp = .allocate(capacity: numSlots)
        stamp.initialize(repeating: 0, count: numSlots)

        haveFirst = false
        lastExt = 0
        highestSeq = 0; firstSeq = 0
        lastTransit = 0; jitterSec = 0; baseline = 0; peakDev = 0

        for k in K.allCases { st(k, 0) }
        let ms = c.adaptive ? c.minTargetMs : c.fixedTargetMs
        st(.policyAdaptive, c.adaptive ? 1 : 0)
        stD(.policyMs, ms)
        st(.target, Int64((ms * c.sampleRate / 1000).rounded()))
        st(.pullFrames, 128)

        started = false
        pos = 0; fillAvg = 0; gain = 0
        lastL = 0; lastR = 0
    }

    /// 0 = adaptive (ms = minimum), otherwise a fixed playout delay. Any thread.
    public func setTargetPolicy(adaptive: Bool, ms: Double) {
        let v = min(max(ms, 1), config.maxTargetMs)
        stD(.policyMs, v)
        st(.policyAdaptive, adaptive ? 1 : 0)
        if !adaptive { st(.target, Int64((v * config.sampleRate / 1000).rounded())) }
    }

    // MARK: - writer (network)

    public func push(_ h: UltraHeader, payload: UnsafeRawPointer, arrival: Double) {
        let fpp = config.framesPerPacket
        guard Int(h.channels) == config.channels, Int(h.frameCount) == fpp else { inc(.rejected); return }

        let ext: Int64 = haveFirst ? lastExt + ultraWrapDiff(h.sampleCounter, UInt32(truncatingIfNeeded: lastExt))
                                   : Int64(h.sampleCounter)
        guard ext >= 0, ext % Int64(fpp) == 0 else { inc(.rejected); return }

        let slot = Int((ext / Int64(fpp)) % Int64(numSlots))
        if ua_load(stamp + slot) == ext + 1 { inc(.dup); return }

        if !haveFirst {
            haveFirst = true
            firstSeq = h.sequence; highestSeq = h.sequence
            lastExt = ext
        } else {
            let d = ultraWrapDiff(h.sequence, highestSeq)
            if d > 0 { highestSeq = h.sequence } else { inc(.reorder) }
        }

        if ld(.anyData) != 0 && ext + Int64(fpp) <= ld(.readFrame) {
            inc(.late) // too late to be played: never catch up with stale audio
        } else {
            let ch = config.channels
            var o = 0
            for i in 0..<fpp {
                let base = Int((ext + Int64(i)) % Int64(capacity)) * ch
                for c in 0..<ch {
                    let raw = UltraHeader.get16(payload, o)
                    ring[base + c] = ultraS16ToFloat(Int16(bitPattern: raw))
                    o += 2
                }
            }
            ua_store(stamp + slot, ext + 1)
            _ = ua_store_max(shared + K.latestEnd.rawValue, ext + Int64(fpp))
            st(.anyData, 1)
            inc(.received)
        }

        if ext > lastExt { lastExt = ext }

        let expected = ultraWrapDiff(highestSeq, firstSeq) + 1
        let arrived = ld(.received) + ld(.late)
        st(.lost, max(0, expected - arrived))

        // delay variation tracking (same as the C++ reference)
        let transit = arrival - Double(ext) / config.sampleRate
        let packetSec = Double(fpp) / config.sampleRate
        if ld(.received) <= 1 {
            baseline = transit
            peakDev = 0
        } else {
            if ext == lastExt { jitterSec += (abs(transit - lastTransit) - jitterSec) / 16 }
            baseline = min(transit, baseline + 0.0005 * packetSec)
            peakDev = max(transit - baseline, peakDev * pow(0.5, packetSec / 5))
        }
        lastTransit = transit
        stD(.jitter, jitterSec * 1000)

        if ld(.policyAdaptive) != 0 {
            let ms = 1000 * (peakDev + packetSec + Double(ld(.pullFrames)) / config.sampleRate) + 0.5
            let clamped = min(max(ms, ldD(.policyMs)), config.maxTargetMs)
            st(.target, Int64((clamped * config.sampleRate / 1000).rounded()))
        }
    }

    // MARK: - reader (real-time audio thread)

    @inline(__always) private func sample(_ frame: Int64, _ ch: Int, _ valid: inout Bool) -> Float {
        guard frame >= 0 else { valid = false; return 0 }
        let block = frame / Int64(config.framesPerPacket)
        valid = ua_load(stamp + Int(block % Int64(numSlots))) == block * Int64(config.framesPerPacket) + 1
        return ring[Int(frame % Int64(capacity)) * config.channels + ch]
    }

    /// Fills `frames` samples. Pass right == nil for mono output.
    public func pull(left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>?, frames n: Int) {
        let stereo = config.channels == 2 && right != nil
        guard ld(.anyData) != 0 else {
            left.update(repeating: 0, count: n)
            right?.update(repeating: 0, count: n)
            return
        }

        st(.pullFrames, Int64(n))
        let tgt = Int(ld(.target))
        let le = ld(.latestEnd)
        let sr = config.sampleRate
        let rampStep = 1 / (0.002 * sr) // 2 ms fades

        if !started {
            pos = Double(le - Int64(tgt))
            fillAvg = Double(tgt)
            gain = 0
            started = true
        }

        var fill = Double(le) - pos
        if fill <= 0 {
            inc(.under)
            for i in 0..<n {
                gain = max(0, gain - rampStep)
                left[i] = lastL * Float(gain)
                if stereo { right![i] = lastR * Float(gain) }
            }
            started = false
            return
        }

        let overLimit = Double(tgt + max(tgt, Int(0.02 * sr)))
        if fill > overLimit || fill > Double(capacity - 2 * config.framesPerPacket) {
            inc(.over)
            pos = Double(le - Int64(tgt))
            fill = Double(tgt)
            fillAvg = Double(tgt)
            gain = 0
        }

        fillAvg += (fill - fillAvg) * 0.05
        let ratio = 1 + min(max(0.004 * (fillAvg - Double(tgt)) / Double(max(1, tgt)), -0.002), 0.002)
        stD(.drift, (ratio - 1) * 1e6)
        stD(.fill, 1000 * fill / sr)

        var concealed: Int64 = 0
        for i in 0..<n {
            let i0 = Int64(pos.rounded(.down))
            let fr = Float(pos - Double(i0))
            var v0 = true, v1 = true, v2 = true, v3 = true
            let l0 = sample(i0, 0, &v0), l1 = sample(i0 + 1, 0, &v1)
            var r0 = l0, r1 = l1
            if config.channels == 2 {
                r0 = sample(i0, 1, &v2)
                r1 = sample(i0 + 1, 1, &v3)
            }
            if v0 && v1 {
                gain = min(1, gain + rampStep)
                lastL = l0 + (l1 - l0) * fr
                lastR = r0 + (r1 - r0) * fr
            } else {
                gain = max(0, gain - rampStep) // lost packet: fade instead of a hard gap
                concealed += 1
            }
            left[i] = lastL * Float(gain)
            if stereo { right![i] = lastR * Float(gain) }
            pos += ratio
        }

        if concealed > 0 { inc(.concealed, concealed) }
        st(.readFrame, Int64(pos))
    }

    public var stats: Stats {
        var s = Stats()
        s.received = ld(.received); s.lost = ld(.lost); s.late = ld(.late); s.duplicates = ld(.dup)
        s.reordered = ld(.reorder); s.rejected = ld(.rejected); s.underruns = ld(.under); s.overruns = ld(.over)
        s.concealedFrames = ld(.concealed)
        s.jitterMs = ldD(.jitter); s.fillMs = ldD(.fill); s.driftPpm = ldD(.drift)
        s.targetMs = 1000 * Double(ld(.target)) / config.sampleRate
        return s
    }
}
