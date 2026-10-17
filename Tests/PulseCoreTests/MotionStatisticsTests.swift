import XCTest
@testable import PulseCore

final class MotionStatisticsTests: XCTestCase {
    func testStillAndMovingWindowsAndIntensity() {
        var stats = MotionStatistics()
        for i in 0...200 {
            let t = Double(i) / 100
            stats.consume(at: t, ax: t < 1 ? 0 : 0.2, ay: 0, az: 0, cadence: t < 1 ? 0 : 90, heartRate: nil)
        }
        let result = stats.finish(duration: 2)
        XCTAssertEqual(result.movementSeconds + result.stillSeconds, 2, accuracy: 0.0001)
        XCTAssertEqual(result.movementSeconds, 1.01, accuracy: 0.0001)
        XCTAssertEqual(result.stillSeconds, 0.99, accuracy: 0.0001)
        XCTAssertEqual(result.peakAccelerationG!, 0.2, accuracy: 0.0001)
        XCTAssertEqual(result.rmsAccelerationG!, sqrt(0.04 * 1.01 / 2), accuracy: 0.0001)
        XCTAssertEqual(result.fastestCadence, 90)
        XCTAssertTrue(result.timeline.allSatisfy { $0.heartRate == nil })
    }

    func testDropoutIsNotStillnessAndPauseDoesNotBridgeIntervals() {
        var stats = MotionStatistics()
        stats.consume(at: 0, ax: 0, ay: 0, az: 0, cadence: 0, heartRate: 100)
        stats.consume(at: 0.1, ax: 0, ay: 0, az: 0, cadence: 0, heartRate: 100)
        stats.consume(at: 5, ax: 0, ay: 0, az: 0, cadence: 0, heartRate: nil)
        stats.consume(at: 5.1, ax: 0, ay: 0, az: 0, cadence: 0, heartRate: nil)
        stats.recordRep(at: 5)
        stats.pause()
        stats.recordRep(at: 5.2)
        stats.consume(at: 5.2, ax: 0.3, ay: 0, az: 0, cadence: 0, heartRate: nil)
        stats.consume(at: 5.3, ax: 0.3, ay: 0, az: 0, cadence: 0, heartRate: nil)
        let result = stats.finish(duration: 5.3)
        XCTAssertEqual(result.unobservedSeconds, 5, accuracy: 0.0001)
        XCTAssertEqual(result.intervalCount, 0)
        XCTAssertEqual(Set(result.timeline.map(\.segment)).count, 3)
        XCTAssertNil(result.timeline.last?.heartRate)
    }

    func testRhythmStabilityRequiresEnoughIntervalsAndDistinguishesVariation() {
        var regular = MotionStatistics()
        [0.0, 0.5, 1, 1.5].forEach { regular.recordRep(at: $0) }
        XCTAssertNil(regular.finish(duration: 2).rhythmStability)
        regular.recordRep(at: 2)
        XCTAssertEqual(regular.finish(duration: 2).rhythmStability, 100)
        var varied = MotionStatistics()
        [0.0, 0.3, 1, 1.3, 2].forEach { varied.recordRep(at: $0) }
        XCTAssertEqual(varied.finish(duration: 2).rhythmStability!, 60, accuracy: 0.0001)
    }

    func testLongRecordBoundsTimelineWithoutLosingTotals() {
        var stats = MotionStatistics()
        for i in 0...40_000 {
            stats.consume(at: Double(i) / 10, ax: 0.1, ay: 0, az: 0, cadence: 60, heartRate: 100)
        }
        let result = stats.finish(duration: 4000)
        XCTAssertLessThan(result.timeline.count, 3600)
        XCTAssertEqual(result.timelineStrideSeconds, 2)
        XCTAssertEqual(result.movementSeconds, 4000, accuracy: 0.001)
        XCTAssertEqual(result.peakAccelerationG!, 0.1, accuracy: 0.0001)
    }

    func testAnalysisSurvivesSyncAndExportsMissingHeartAsEmpty() throws {
        var stats = MotionStatistics()
        stats.consume(at: 0, ax: 0, ay: 0, az: 0, cadence: 0, heartRate: nil)
        stats.consume(at: 0.1, ax: 0.2, ay: 0, az: 0, cadence: 90, heartRate: nil)
        var record = SessionRecord(id: UUID(), startedAt: Date(), duration: 0.1, count: 1, isDemo: false, csvFilename: nil)
        record.motionSummary = stats.finish(duration: 0.1)
        let packet = RecordTransfer(version: 1, records: [record])
        let decoded = try JSONDecoder().decode(RecordTransfer.self, from: JSONEncoder().encode(packet))
        XCTAssertEqual(decoded.records[0].motionSummary?.timeline.count, 1)
        XCTAssertTrue(decoded.records[0].timelineCSV.contains(",90.0,,0.2"))
        XCTAssertTrue(SessionRecord.csv(decoded.records).contains("movement_seconds"))
    }
}
