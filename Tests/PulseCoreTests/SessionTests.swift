import XCTest
@testable import PulseCore
final class SessionTests: XCTestCase {
    func testManualHealthRecordKeepsWallClockAndPauseIntervals() throws {
        let start = Date(timeIntervalSince1970: 1000)
        var record = SessionRecord(id: UUID(), startedAt: start, duration: 90, count: 50,
                                   isDemo: false, csvFilename: nil)
        record.endedAt = start.addingTimeInterval(120)
        record.pauseIntervals = [DateInterval(start: start.addingTimeInterval(30), duration: 30)]
        let copy = try JSONDecoder().decode(SessionRecord.self, from: JSONEncoder().encode(record))
        XCTAssertNil(copy.healthWorkoutID)
        XCTAssertEqual(copy.endedAt?.timeIntervalSince(start), 120)
        XCTAssertEqual(copy.pauseIntervals?.first?.duration, 30)
        XCTAssertEqual(copy.duration, 90)
    }
    func testOldRecordWithoutHealthFieldsStillLoads() throws {
        let id = UUID()
        let json = """
        {"id":"\(id.uuidString)","startedAt":0,"duration":60,"count":90,"isDemo":false}
        """
        let record = try JSONDecoder().decode(SessionRecord.self, from: Data(json.utf8))
        XCTAssertEqual(record.id, id)
        XCTAssertNil(record.healthStatus)
        XCTAssertNil(record.healthWorkoutID)
        XCTAssertNil(record.averageHeartRate)
        XCTAssertNil(record.maximumHeartRate)
        XCTAssertEqual(record.mode, .solo)
        XCTAssertNil(record.motionSummary)
        XCTAssertEqual(record.averageRPM, 90)
    }

    func testHealthSaveStatusRoundTrip() throws {
        var record = SessionRecord(id: UUID(), startedAt: Date(), duration: 0, count: 0,
                                   isDemo: false, csvFilename: nil)
        record.healthStatus = "已写入健康"
        record.healthWorkoutID = UUID()
        record.averageHeartRate = 104.5
        record.maximumHeartRate = 132
        let decoded = try JSONDecoder().decode(SessionRecord.self, from: JSONEncoder().encode(record))
        XCTAssertEqual(decoded.healthStatus, record.healthStatus)
        XCTAssertEqual(decoded.healthWorkoutID, record.healthWorkoutID)
        XCTAssertEqual(decoded.averageHeartRate, 104.5)
        XCTAssertEqual(decoded.maximumHeartRate, 132)
        XCTAssertEqual(decoded.averageRPM, 0)
    }

    func testCadenceStopsAfterNoMovement() {
        var window = CadenceWindow()
        [10.0, 10.5, 11.0].forEach { window.append($0) }
        XCTAssertEqual(window.rate(at: 11), 120, accuracy: 0.01)
        XCTAssertEqual(window.rate(at: 13.1), 0)
        XCTAssertEqual(window.rate(at: 20), 0)
    }
    func testOutOfOrderTransferDoesNotReplaceFinalHeartDataOrDuplicateRecord() throws {
        var early = SessionRecord(id: UUID(), startedAt: Date(timeIntervalSince1970: 100), duration: 60,
                                  count: 90, isDemo: false, csvFilename: nil)
        early.updatedAt = Date(timeIntervalSince1970: 200)
        var final = early
        final.updatedAt = Date(timeIntervalSince1970: 201)
        final.averageHeartRate = 110
        final.healthStatus = "已写入健康"
        let packet = RecordTransfer(version: 1, records: [early])
        let decoded = try JSONDecoder().decode(RecordTransfer.self, from: JSONEncoder().encode(packet))
        let result = SessionRecord.merging([final], with: decoded.records + [early])
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].averageHeartRate, 110)
        XCTAssertEqual(result[0].healthStatus, "已写入健康")
        XCTAssertEqual(SessionRecord.merging([early], with: [final])[0].averageHeartRate, 110)
    }

    func testCSVIncludesHeartDataAndLeavesMissingDataEmpty() {
        var record = SessionRecord(id: UUID(), startedAt: Date(timeIntervalSince1970: 0), duration: 120,
                                   count: 180, isDemo: false, csvFilename: nil)
        let missing = SessionRecord.csv([record])
        XCTAssertTrue(missing.contains(",90.0,,,false"))
        record.averageHeartRate = 100
        record.maximumHeartRate = 130
        let csv = SessionRecord.csv([record])
        XCTAssertTrue(csv.hasPrefix("\u{FEFF}id,"))
        XCTAssertTrue(csv.contains("1970-01-01T00:00:00Z,120.0,180,90.0,100.0,130.0,false"))
    }

    func testPartnerModeSurvivesArchiveTransferAndCSV() throws {
        var record = SessionRecord(id: UUID(), startedAt: Date(), duration: 120,
                                   count: 80, isDemo: false, csvFilename: nil)
        record.modeKey = RecordingMode.partner.rawValue
        record.averageHeartRate = 110
        let packet = RecordTransfer(version: 1, records: [record])
        let decoded = try JSONDecoder().decode(RecordTransfer.self, from: JSONEncoder().encode(packet))
        let merged = SessionRecord.merging([], with: decoded.records)
        XCTAssertEqual(merged.first?.mode, .partner)
        XCTAssertEqual(merged.first?.averageHeartRate, 110)
        XCTAssertTrue(SessionRecord.csv(merged).contains(",false,partner,"))
        XCTAssertTrue(SessionRecord.csv(merged).contains("is_demo,mode"))
    }
    func testArchiveRoundTripAndDeletion() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let archive = SessionArchive(directory: directory)
        XCTAssertTrue(try archive.load().isEmpty)
        let record = SessionRecord(id: UUID(), startedAt: Date(), duration: 60, count: 90, isDemo: true, csvFilename: nil)
        try archive.save([record])
        let loaded = try archive.load()
        XCTAssertEqual(loaded.first?.id, record.id)
        XCTAssertEqual(loaded.first?.averageRPM, 90)
        try archive.save([])
        XCTAssertTrue(try archive.load().isEmpty)
    }
    func testCorruptArchiveThrowsInsteadOfOverwriting() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let archive = SessionArchive(directory: directory)
        try Data("bad json".utf8).write(to: archive.indexURL)
        XCTAssertThrowsError(try archive.load())
    }
}
