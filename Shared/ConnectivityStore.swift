import Foundation
import Combine
import WatchConnectivity
#if os(iOS)
import HealthKit
#endif

@MainActor
final class ConnectivityStore: NSObject, ObservableObject, WCSessionDelegate {
    static let shared = ConnectivityStore()
    @Published var records: [SessionRecord] = []
    @Published var status = "等待手表连接"
    @Published var errorMessage: String?
    @Published var lastReceived: Date?
    #if os(iOS)
    @Published var healthSaving = Set<UUID>()
    @Published var healthResults: [UUID: String] = [:]
    private let healthStore = HKHealthStore()

    func healthIsSaved(_ record: SessionRecord) -> Bool {
        record.healthWorkoutID != nil || UserDefaults.standard.string(forKey: "healthSaved.\(record.id)") != nil
    }
    func healthStatus(_ record: SessionRecord) -> String {
        if let result = healthResults[record.id] { return result }
        return healthIsSaved(record) ? "已同步到苹果健康" : "未同步到苹果健康"
    }
    func saveToHealth(_ record: SessionRecord) {
        guard !record.isDemo, !healthIsSaved(record), !healthSaving.contains(record.id), canWrite else { return }
        guard HKHealthStore.isHealthDataAvailable() else { errorMessage = "此设备无法使用健康"; return }
        healthSaving.insert(record.id)
        healthResults[record.id] = "正在同步…"
        Task {
            defer { healthSaving.remove(record.id) }
            let configuration = HKWorkoutConfiguration()
            configuration.activityType = .other
            configuration.locationType = .indoor
            let builder = HKWorkoutBuilder(healthStore: healthStore, configuration: configuration, device: nil)
            do {
                let heart = HKQuantityType(.heartRate)
                try await healthStore.requestAuthorization(toShare: [HKObjectType.workoutType()], read: [heart, HKObjectType.workoutType()])
                guard healthStore.authorizationStatus(for: HKObjectType.workoutType()) == .sharingAuthorized else {
                    throw NSError(domain: "Yinji", code: 1, userInfo: [NSLocalizedDescriptionKey: "请允许写入体能训练后再试"])
                }
                let syncID = "com.personal.yinji.\(record.id.uuidString)"
                let existing = try await healthSamples(type: HKObjectType.workoutType(), predicate: HKQuery.predicateForObjects(withMetadataKey: HKMetadataKeySyncIdentifier, allowedValues: [syncID]))
                if let saved = existing.first as? HKWorkout {
                    UserDefaults.standard.set(saved.uuid.uuidString, forKey: "healthSaved.\(record.id)")
                    healthResults[record.id] = "已同步到苹果健康"
                    return
                }
                let end = record.endedAt ?? record.startedAt.addingTimeInterval(record.duration)
                let pauses = record.pauseIntervals ?? []
                try await builder.beginCollection(at: record.startedAt)
                let events = pauses.flatMap { interval in
                    [HKWorkoutEvent(type: .pause, dateInterval: DateInterval(start: interval.start, duration: 0), metadata: nil),
                     HKWorkoutEvent(type: .resume, dateInterval: DateInterval(start: interval.end, duration: 0), metadata: nil)]
                }
                if !events.isEmpty { try await builder.addWorkoutEvents(events) }
                let predicate = HKQuery.predicateForSamples(withStart: record.startedAt, end: end, options: [.strictStartDate, .strictEndDate])
                let samples = try await healthSamples(type: heart, predicate: predicate).filter { sample in
                    !pauses.contains { $0.contains(sample.startDate) }
                }
                if !samples.isEmpty { try await builder.addSamples(samples) }
                var metadata: [String: Any] = [HKMetadataKeySyncIdentifier: syncID, HKMetadataKeySyncVersion: 1,
                    HKMetadataKeyIndoorWorkout: true,
                    "com.personal.yinji.motionCount": record.count,
                    "com.personal.yinji.averageCadencePerMinute": record.averageRPM,
                    "com.personal.yinji.activeDurationSeconds": record.duration,
                    "com.personal.yinji.recordingMode": record.mode.rawValue,
                    "com.personal.yinji.detectorMethod": record.detectorMethod ?? "legacy-single"]
                if let average = record.averageHeartRate { metadata["com.personal.yinji.averageHeartRate"] = average }
                if let maximum = record.maximumHeartRate { metadata["com.personal.yinji.maximumHeartRate"] = maximum }
                try await builder.addMetadata(metadata)
                try await builder.endCollection(at: end)
                guard let saved = try await builder.finishWorkout() else {
                    throw NSError(domain: "Yinji", code: 2, userInfo: [NSLocalizedDescriptionKey: "未收到健康保存结果"])
                }
                UserDefaults.standard.set(saved.uuid.uuidString, forKey: "healthSaved.\(record.id)")
                healthResults[record.id] = samples.isEmpty ? "已同步（无可关联的健康心率样本）" : "已同步到苹果健康"
            } catch {
                builder.discardWorkout()
                healthResults[record.id] = "同步失败，可重试"
                errorMessage = "健康同步失败：\(error.localizedDescription)"
            }
        }
    }
    private func healthSamples(type: HKSampleType, predicate: NSPredicate) async throws -> [HKSample] {
        try await withCheckedThrowingContinuation { continuation in
            let query = HKSampleQuery(sampleType: type, predicate: predicate, limit: HKObjectQueryNoLimit, sortDescriptors: nil) { _, samples, error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume(returning: samples ?? []) }
            }
            healthStore.execute(query)
        }
    }
    #endif
    private let archive: SessionArchive
    private var canWrite = true
    private var session: WCSession? { WCSession.isSupported() ? WCSession.default : nil }
    private var staging: URL { archive.directory.appendingPathComponent("Transfers", isDirectory: true) }

    override init() {
        archive = SessionArchive(directory: FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0])
        super.init()
        do { records = try archive.load() }
        catch { canWrite = false; errorMessage = "记录读取失败，已保留原文件：\(error.localizedDescription)" }
        session?.delegate = self
        session?.activate()
    }

    func requestSync() {
        guard let session, session.activationState == .activated else { status = "正在连接…"; session?.activate(); return }
        #if os(iOS)
        guard session.isPaired, session.isWatchAppInstalled else { status = "请先在配对手表安装并打开隐记"; return }
        session.transferUserInfo(["requestRecords": true])
        status = "已请求同步，等待手表传送"
        #else
        do { sendRecords(try archive.load()) } catch { errorMessage = error.localizedDescription }
        #endif
    }

    func sendRecords(_ records: [SessionRecord]) {
        #if os(watchOS)
        guard let session, session.activationState == .activated, session.isCompanionAppInstalled else { return }
        do {
            try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
            let url = staging.appendingPathComponent("\(UUID().uuidString).json")
            try JSONEncoder().encode(RecordTransfer(version: 1, records: records)).write(to: url, options: .atomic)
            session.transferFile(url, metadata: ["kind": "records"])
            // Snapshot the finished CSV so deleting local history cannot invalidate a queued transfer.
            for record in records {
                guard let name = record.csvFilename, name == URL(fileURLWithPath: name).lastPathComponent else { continue }
                let source = archive.directory.appendingPathComponent(name)
                guard FileManager.default.fileExists(atPath: source.path) else { continue }
                let key = "rawDelivered.\(record.id.uuidString)"
                guard !UserDefaults.standard.bool(forKey: key),
                      !session.outstandingFileTransfers.contains(where: { $0.file.metadata?["recordID"] as? String == record.id.uuidString }) else { continue }
                let copy = staging.appendingPathComponent("\(UUID().uuidString).csv")
                try FileManager.default.copyItem(at: source, to: copy)
                session.transferFile(copy, metadata: ["kind": "raw", "recordID": record.id.uuidString])
            }
        } catch { errorMessage = "同步准备失败：\(error.localizedDescription)" }
        #endif
    }

    func summaryExport(_ selected: [SessionRecord]) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("yinji-\(UUID().uuidString).csv")
        try SessionRecord.csv(selected).write(to: url, atomically: true, encoding: .utf8)
        return url
    }
    func timelineExport(_ record: SessionRecord) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("yinji-timeline-\(UUID().uuidString).csv")
        try record.timelineCSV.write(to: url, atomically: true, encoding: .utf8)
        return url
    }
    func rawURL(_ record: SessionRecord) -> URL? {
        let url = archive.directory.appendingPathComponent("raw-\(record.id.uuidString).csv")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        Task { @MainActor in
            if let error { self.status = "连接失败"; self.errorMessage = error.localizedDescription; return }
            guard activationState == .activated else { return }
            self.status = "连接服务已就绪"
            self.requestSync()
        }
    }
    nonisolated func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any]) {
        #if os(watchOS)
        guard userInfo["requestRecords"] as? Bool == true else { return }
        Task { @MainActor in
            // Explicit requests also recover raw files after a phone reinstall.
            if let records = try? self.archive.load() {
                for record in records { UserDefaults.standard.removeObject(forKey: "rawDelivered.\(record.id.uuidString)") }
                self.sendRecords(records)
            }
        }
        #endif
    }
    nonisolated func session(_ session: WCSession, didReceive file: WCSessionFile) {
        #if os(iOS)
        // WCSession deletes the incoming URL after this callback returns.
        let copy = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        do { try FileManager.default.copyItem(at: file.fileURL, to: copy) }
        catch { Task { @MainActor in self.errorMessage = "同步文件接收失败：\(error.localizedDescription)" }; return }
        let kind = file.metadata?["kind"] as? String
        let id = (file.metadata?["recordID"] as? String).flatMap(UUID.init(uuidString:))
        Task { @MainActor in
            defer { try? FileManager.default.removeItem(at: copy) }
            guard self.canWrite else { self.errorMessage = "本地记录读取失败，暂未合并新数据"; return }
            do {
                if kind == "records" {
                    let packet = try JSONDecoder().decode(RecordTransfer.self, from: Data(contentsOf: copy))
                    guard packet.version == 1 else { self.errorMessage = "请更新手机 App 后同步"; return }
                    let merged = SessionRecord.merging(self.records, with: packet.records)
                    try self.archive.save(merged)
                    self.records = merged
                } else if kind == "raw", let id {
                    try FileManager.default.createDirectory(at: self.archive.directory, withIntermediateDirectories: true)
                    let destination = self.archive.directory.appendingPathComponent("raw-\(id.uuidString).csv")
                    try Data(contentsOf: copy).write(to: destination, options: .atomic)
                } else { return }
                self.lastReceived = Date()
                self.status = "已收到手表数据"
            } catch { self.errorMessage = "同步保存失败，请重新同步：\(error.localizedDescription)" }
        }
        #endif
    }
    nonisolated func session(_ session: WCSession, didFinish fileTransfer: WCSessionFileTransfer, error: Error?) {
        let url = fileTransfer.file.fileURL
        let id = fileTransfer.file.metadata?["recordID"] as? String
        Task { @MainActor in
            if error == nil, let id { UserDefaults.standard.set(true, forKey: "rawDelivered.\(id)") }
            if let error { self.errorMessage = "传输未完成，打开 App 后重试：\(error.localizedDescription)" }
            // Only remove our private staging copies.
            if url.deletingLastPathComponent().standardizedFileURL == self.staging.standardizedFileURL {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }
    #if os(iOS)
    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}
    nonisolated func sessionDidDeactivate(_ session: WCSession) { session.activate() }
    #endif
}
