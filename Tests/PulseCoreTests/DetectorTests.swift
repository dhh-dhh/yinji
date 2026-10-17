import XCTest
import Combine
import RepMotionCore
import RepMotionDetection

final class DetectorTests: XCTestCase {
    func testPeriodicMotionAndReset() {
        let detector = RepDetectionService()
        detector.calibration = RepCalibration(alpha: 0.35, thresholdMultiplier: 1,
            refractoryPeriod: 0.22, warmupDuration: 3)
        var count = 0
        let token = detector.repPublisher.sink { _ in count += 1 }
        for i in 0..<1000 {
            let t = Double(i) / 50
            detector.processBatch([MotionSample(timestamp: 100 + t, ax: 0, ay: sin(t * 2 * .pi * 1.5) * 0.8, az: 0)])
        }
        XCTAssertTrue((24...27).contains(count), "Expected approximately 25 peaks after warmup, got \(count)")
        detector.reset(); count = 0
        for i in 0..<500 {
            detector.processBatch([MotionSample(timestamp: 200 + Double(i) / 50, ax: 0, ay: 0, az: 0)])
        }
        XCTAssertEqual(count, 0)
        withExtendedLifetime(token) {}
    }
}
