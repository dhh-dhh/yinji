import XCTest
@testable import PulseCore

final class ThreeAxisDetectorTests: XCTestCase {
    private func count(direction: SIMD3<Double>, frequency: Double = 1.5, rate: Double = 50) -> Int {
        var detector = ThreeAxisDetector()
        var count = 0
        for i in 0..<Int(20 * rate) {
            let t = Double(i) / rate
            let a = direction * (0.8 * sin(t * 2 * .pi * frequency))
            if detector.process(time: 100 + t, acceleration: a, rotation: .zero).counted { count += 1 }
        }
        return count
    }
    func testEquivalentCountsAcrossAxesAndDiagonalWithoutDoubleCounting() {
        let directions: [SIMD3<Double>] = [SIMD3(1,0,0), SIMD3(0,1,0), SIMD3(0,0,1), SIMD3(-1,0,0), SIMD3(1,2,-2) / 3]
        let counts = directions.map { count(direction: $0) }
        for value in counts { XCTAssertTrue((23...26).contains(value), "Expected full cycles after warmup, got \(counts)") }
        XCTAssertLessThanOrEqual(counts.max()! - counts.min()!, 1)
    }
    func testSlowFastAndDifferentSamplingRates() {
        for frequency in [0.5, 1.0, 2.5] {
            for rate in [25.0, 50.0, 100.0] {
                let result = count(direction: SIMD3(0.6,0,0.8), frequency: frequency, rate: rate)
                XCTAssertEqual(Double(result), 17 * frequency - 1, accuracy: 2, "frequency \(frequency), rate \(rate)")
            }
        }
    }
    func testQuietNoiseAndPureRotationDoNotCount() {
        var detector = ThreeAxisDetector()
        var count = 0
        for i in 0..<1000 {
            let t = Double(i) / 50
            let a = SIMD3(sin(t * 17) * 0.015, cos(t * 23) * 0.015, sin(t * 31) * 0.015)
            if detector.process(time: t, acceleration: a, rotation: i < 500 ? .zero : SIMD3(0,0,6)).counted { count += 1 }
        }
        XCTAssertEqual(count, 0)
    }
    func testGraduallyChangingDirectionStillCounts() {
        var detector = ThreeAxisDetector()
        var count = 0
        for i in 0..<1500 {
            let t = Double(i) / 50
            let axis = SIMD3(cos(t * 0.07), sin(t * 0.07), 0)
            if detector.process(time: t, acceleration: axis * (sin(t * 2 * .pi * 1.5) * 0.6), rotation: .zero).counted { count += 1 }
        }
        XCTAssertEqual(Double(count), 39, accuracy: 3)
    }
    func testResetAndDropoutRequireWarmupAgain() {
        var detector = ThreeAxisDetector()
        for i in 0..<300 {
            let t = Double(i) / 50
            _ = detector.process(time: t, acceleration: SIMD3(sin(t * 9) * 0.6,0,0), rotation: .zero)
        }
        let gap = detector.process(time: 10, acceleration: SIMD3(0.6,0,0), rotation: .zero)
        XCTAssertFalse(gap.counted)
        XCTAssertEqual(gap.warmup, 3)
        detector.reset()
        let reset = detector.process(time: 11, acceleration: .zero, rotation: .zero)
        XCTAssertEqual(reset.warmup, 3)
        XCTAssertFalse(reset.counted)
    }
    func testRapidTurnSuppressesOtherwisePeriodicMotion() {
        var detector = ThreeAxisDetector()
        var count = 0
        for i in 0..<600 {
            let t = Double(i) / 50
            if detector.process(time: t, acceleration: SIMD3(0.8 * sin(t * 9),0,0), rotation: SIMD3(6,0,0)).counted { count += 1 }
        }
        XCTAssertEqual(count, 0)
    }
}
