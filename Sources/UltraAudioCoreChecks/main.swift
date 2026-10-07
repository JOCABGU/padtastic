// Runs the same checks as Tests/UltraAudioCoreTests without XCTest (for toolchains where the
// XCTest runner is unavailable, e.g. Swift on Windows with a portable SDK):  swift run UltraAudioCoreChecks
import Foundation
import Foundation
import UltraAudioCore

private let rate = 48000.0
private let fpp = 48

private func makePacket(_ i: UInt32, session: UInt32 = 7, base: UInt32 = 0) -> [UInt8] {
    var l = [Float](repeating: 0, count: fpp), r = l
    for k in 0..<fpp {
        let t = Double(Int(i) * fpp + k) / rate
        l[k] = Float(0.5 * sin(2 * Double.pi * 440 * t)); r[k] = -l[k]
    }
    var h = UltraHeader()
    h.session = session
    h.sequence = i
    h.sampleCounter = base &+ i &* UInt32(fpp)
    return ultraBuildPacket(h, left: l, right: r)
}

/// Deterministic network + sound-card simulation (same as the C++ tests).
private struct Sim {
    var jb: UltraJitterBuffer
    var delayMs: (UInt32) -> Double = { _ in 1 }
    var drop: (UInt32) -> Bool = { _ in false }
    var copies: (UInt32) -> Int = { _ in 1 }
    var clockRatio = 1.0
    var block = 128
    var energy = 0.0

    init(adaptive: Bool = true) {
        var c = UltraJitterBuffer.Config()
        c.adaptive = adaptive
        jb = UltraJitterBuffer(config: c)
    }

    mutating func run(_ packets: UInt32, base: UInt32 = 0) {
        var evs: [(t: Double, i: UInt32)] = []
        for i in 0..<packets where !drop(i) {
            for c in 0..<copies(i) { evs.append((Double(i) * 0.001 + delayMs(i) / 1000 + Double(c) * 1e-6, i)) }
        }
        evs.sort { $0.t < $1.t }
        let end = evs.last?.t ?? 0
        var l = [Float](repeating: 0, count: block), r = l
        var next = 0.01
        var e = 0
        let buffer = jb
        func deliver(_ ev: (t: Double, i: UInt32)) {
            let p = makePacket(ev.i, base: base)
            p.withUnsafeBytes { raw in
                if let h = ultraParse(raw) { buffer.push(h, payload: raw.baseAddress! + UltraProtocol.headerSize, arrival: ev.t) }
            }
        }
        while next < end {
            while e < evs.count && evs[e].t <= next { deliver(evs[e]); e += 1 }
            l.withUnsafeMutableBufferPointer { lp in
                r.withUnsafeMutableBufferPointer { rp in buffer.pull(left: lp.baseAddress!, right: rp.baseAddress!, frames: block) }
            }
            for x in l { energy += Double(x * x) }
            next += Double(block) / rate / clockRatio
        }
        while e < evs.count { deliver(evs[e]); e += 1 }
    }
}


var failures = 0
func XCTAssertEqual<T: Equatable>(_ a: T, _ b: T, file: String = #file, line: Int = #line) { if a != b { failures += 1; print("FALLO línea \(line): \(a) != \(b)") } }
func XCTAssertEqual(_ a: Double, _ b: Double, accuracy: Double, line: Int = #line) { if abs(a - b) > accuracy { failures += 1; print("FALLO línea \(line): \(a) != \(b) ± \(accuracy)") } }
func XCTAssertNil<T>(_ v: T?, line: Int = #line) { if v != nil { failures += 1; print("FALLO línea \(line): se esperaba nil") } }
func XCTAssertNotNil<T>(_ v: T?, line: Int = #line) { if v == nil { failures += 1; print("FALLO línea \(line): nil") } }
func XCTAssertGreaterThan<T: Comparable>(_ a: T, _ b: T, line: Int = #line) { if !(a > b) { failures += 1; print("FALLO línea \(line): \(a) <= \(b)") } }
func XCTAssertLessThan<T: Comparable>(_ a: T, _ b: T, line: Int = #line) { if !(a < b) { failures += 1; print("FALLO línea \(line): \(a) >= \(b)") } }

struct ProtocolChecks {
    func testHeaderBytesAreLittleEndianAndMatchTheSpec() {
        var h = UltraHeader()
        h.session = 0xA1B2_C3D4; h.sequence = 0x0102_0304; h.sampleCounter = 0xFFFF_FF00
        h.frameCount = 48; h.payloadBytes = 192; h.flags = 0x8001
        var b = [UInt8](repeating: 0, count: 24)
        b.withUnsafeMutableBytes { h.write(to: $0.baseAddress!) }
        let expected: [UInt8] = [0x55, 0x41, 1, 1, 0xD4, 0xC3, 0xB2, 0xA1, 0x04, 0x03, 0x02, 0x01,
                                 0x00, 0xFF, 0xFF, 0xFF, 48, 0, 192, 0, 2, 1, 0x01, 0x80]
        XCTAssertEqual(b, expected)
        let back = b.withUnsafeBytes { UltraHeader.read($0.baseAddress!) }
        XCTAssertEqual(back, h)
    }

    func testMalformedPacketsAreRejected() {
        let p = makePacket(5)
        XCTAssertEqual(p.count, 24 + fpp * 4)
        XCTAssertNotNil(p.withUnsafeBytes { ultraParse($0) })
        var bad = p; bad[0] = 0
        XCTAssertNil(bad.withUnsafeBytes { ultraParse($0) })
        bad = p; bad[20] = 3
        XCTAssertNil(bad.withUnsafeBytes { ultraParse($0) })
        XCTAssertNil(Array(p.dropLast()).withUnsafeBytes { ultraParse($0) })
    }

    func testConversionAndWrap() {
        XCTAssertEqual(ultraFloatToS16(1.5), 32767)
        XCTAssertEqual(ultraFloatToS16(-1.5), -32767)
        XCTAssertEqual(ultraWrapDiff(5, 0xFFFF_FFFB), 10)
    }
}

struct JitterChecks {
    func testCleanStream() {
        var s = Sim(); s.run(3000)
        let st = s.jb.stats
        XCTAssertEqual(st.underruns, 0); XCTAssertEqual(st.lost, 0); XCTAssertEqual(st.received, 3000)
        XCTAssertGreaterThan(s.energy, 100)
    }

    func testLossIsCountedAndConcealed() {
        var s = Sim(); s.drop = { $0 % 50 == 25 }; s.run(5000)
        XCTAssertEqual(s.jb.stats.lost, 100)
        XCTAssertGreaterThan(s.jb.stats.concealedFrames, 0)
        XCTAssertEqual(s.jb.stats.underruns, 0)
    }

    func testDuplicatesAreDropped() {
        var s = Sim(); s.copies = { _ in 2 }; s.run(2000)
        XCTAssertEqual(s.jb.stats.duplicates, 2000)
        XCTAssertEqual(s.jb.stats.concealedFrames, 0)
    }

    func testOutOfOrderIsReassembled() {
        var s = Sim(adaptive: false); s.delayMs = { $0 % 2 == 0 ? 1.6 : 0.5 }; s.run(3000)
        XCTAssertGreaterThan(s.jb.stats.reordered, 1000)
        XCTAssertEqual(s.jb.stats.concealedFrames, 0)
    }

    func testAdaptiveTargetAbsorbsJitter() {
        var rng = SystemRandomNumberGenerator()
        let d = (0..<10000).map { _ in 1 + 6 * Double.random(in: 0..<1, using: &rng) }
        var s = Sim(); s.delayMs = { d[Int($0)] }; s.run(10000)
        XCTAssertGreaterThan(s.jb.stats.targetMs, 3)
        XCTAssertLessThan(s.jb.stats.late, 150)
    }

    func testClockDriftIsCorrected() {
        for ppm in [300.0, -300.0] {
            var s = Sim(adaptive: false); s.clockRatio = 1 + ppm * 1e-6; s.run(60000)
            XCTAssertEqual(s.jb.stats.underruns, 0)
            XCTAssertEqual(s.jb.stats.overruns, 0)
            XCTAssertEqual(s.jb.stats.fillMs, 5, accuracy: 2.5)
        }
    }

    func testCounterWrap() {
        var s = Sim(); s.run(3000, base: ((0xFFFF_FFFF - 1000 * 48) / 48) * 48)
        XCTAssertEqual(s.jb.stats.underruns, 0); XCTAssertEqual(s.jb.stats.lost, 0)
    }
}


let p = ProtocolChecks()
p.testHeaderBytesAreLittleEndianAndMatchTheSpec(); p.testMalformedPacketsAreRejected(); p.testConversionAndWrap()
let j = JitterChecks()
j.testCleanStream(); j.testLossIsCountedAndConcealed(); j.testDuplicatesAreDropped(); j.testOutOfOrderIsReassembled()
j.testAdaptiveTargetAbsorbsJitter(); j.testClockDriftIsCorrected(); j.testCounterWrap()
print(failures == 0 ? "UltraAudioCore (Swift): TODAS LAS COMPROBACIONES PASARON" : "UltraAudioCore (Swift): \(failures) FALLOS")
exit(failures == 0 ? 0 : 1)
