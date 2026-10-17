import SwiftUI
import Combine
import CoreMotion
import HealthKit
import RepMotionCore
import RepMotionDetection

@MainActor
final class SessionModel: NSObject, ObservableObject {
    @Published var selectedMode: RecordingMode = .solo
    @Published private(set) var activeMode: RecordingMode = .solo
    @Published var running = false
    @Published var paused = false
    @Published var starting = false
    private let healthStore = HKHealthStore()
    private var workout: HKWorkoutSession?
    private var workoutBuilder: HKLiveWorkoutBuilder?
    private var collectionTask: Task<Void, Error>?
    private let heartType = HKQuantityType(.heartRate)
    @Published var heartRate: Double?
    private var heartDate: Date?
    @Published var count = 0
    @Published var elapsed: TimeInterval = 0
    @Published var cadence: Double = 0
    @Published var warmup: Double = 0
    @Published var records: [SessionRecord] = []
    @Published var errorMessage: String?
    @Published var demo = false
    @AppStorage("detectionMethodV2") var axis = "Y"
    @AppStorage("sensitivity") var sensitivity = 1.0
    @AppStorage("saveRaw") var saveRaw = false
    private let motion = CMMotionManager()
    private let detector = RepDetectionService()
    private var threeAxis = ThreeAxisDetector()
    private var sessionAxis = "Y"
    private var subscriptions = Set<AnyCancellable>()
    private var timer: Timer?
    private var startDate = Date()
    private var pauseStartedAt: Date?
    private var pauseIntervals: [DateInterval] = []
    private var startUptime: TimeInterval = 0
    private var window = CadenceWindow()
    private var statistics = MotionStatistics()
    private var processingSampleTime: Double?
    private var rawFile: FileHandle?
    private var rawName: String?
    private var sessionIsDemo = false
    private var lastSampleTime: TimeInterval = 0
    private var pendingRecord: SessionRecord?
    private var archiveReadable = true
    private let archive: SessionArchive

    override init() {
        let base = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        archive = SessionArchive(directory: base)
        super.init()
        // One-time fallback for existing installs; later manual selections remain respected.
        if !UserDefaults.standard.bool(forKey: "didRestoreYAxisDefaultV1") {
            if axis == "AUTO" { axis = "Y" }
            UserDefaults.standard.set(true, forKey: "didRestoreYAxisDefaultV1")
        }
        _ = ConnectivityStore.shared
        do {
            records = try archive.load().map { record in
                var restored = record
                if restored.healthStatus == "正在写入健康" {
                    restored.healthStatus = "写入结果未确认，请在健康中检查"
                }
                return restored
            }
        }
        catch { archiveReadable = false; errorMessage = "历史记录读取失败：\(error.localizedDescription)" }
        detector.repPublisher.sink { [weak self] _ in
            guard let self, self.running, !self.paused else { return }
            self.recordRep(at: self.processingSampleTime ?? ProcessInfo.processInfo.systemUptime)
        }.store(in: &subscriptions)
        detector.warmupPublisher.sink { [weak self] remaining in
            self?.warmup = remaining
        }.store(in: &subscriptions)
    }

    func start() {
        guard !running, !starting else { return }
        let requestedMode = selectedMode
        if demo { beginRecording(mode: requestedMode); return }
        guard HKHealthStore.isHealthDataAvailable() else {
            errorMessage = "此设备不支持后台运动会话。"; return
        }
        starting = true
        Task {
            defer { starting = false }
            do {
                try await healthStore.requestAuthorization(toShare: [HKObjectType.workoutType()], read: [heartType])
                guard healthStore.authorizationStatus(for: HKObjectType.workoutType()) == .sharingAuthorized else {
                    errorMessage = "请允许体能训练权限，以便落腕和熄屏后继续记录。"; return
                }
                beginRecording(mode: requestedMode)
            } catch { errorMessage = "无法获得后台记录权限：\(error.localizedDescription)" }
        }
    }

    private func beginRecording(mode: RecordingMode) {
        guard !running, pendingRecord == nil else { return }
        guard archiveReadable else { errorMessage = "历史文件损坏，已停止写入以保留原文件。请先通过 Xcode 备份 App 容器。"; return }
        guard demo || motion.isDeviceMotionAvailable else {
            errorMessage = "当前设备无法提供运动数据。模拟器请开启演示模式。"; return
        }
        pauseStartedAt = nil; pauseIntervals = []
        activeMode = mode
        sessionAxis = axis
        threeAxis = ThreeAxisDetector(sensitivity: sensitivity)
        detector.reset()
        detector.calibration = RepCalibration(alpha: 0.35, thresholdMultiplier: sensitivity,
            refractoryPeriod: 0.22, detectionAxis: DetectionAxis(rawValue: axis) ?? .y,
            warmupDuration: 3)
        heartRate = nil; heartDate = nil
        count = 0; cadence = 0; elapsed = 0; warmup = 3
        statistics = MotionStatistics(); processingSampleTime = nil
        window = CadenceWindow(); startDate = Date()
        startUptime = ProcessInfo.processInfo.systemUptime
        lastSampleTime = startUptime; sessionIsDemo = demo; rawName = nil
        if saveRaw && !demo {
            let name = "motion-\(UUID().uuidString).csv"
            let url = archive.directory.appendingPathComponent(name)
            do {
                try "seconds,ax_g,ay_g,az_g,gx_rad_s,gy_rad_s,gz_rad_s\n".write(to: url, atomically: true, encoding: .utf8)
                rawFile = try FileHandle(forWritingTo: url)
                try rawFile?.seekToEnd(); rawName = name
            } catch { errorMessage = "无法创建数据文件：\(error.localizedDescription)"; return }
        }
        if !demo {
            do {
                let configuration = HKWorkoutConfiguration()
                configuration.activityType = .other
                configuration.locationType = .indoor
                let session = try HKWorkoutSession(healthStore: healthStore, configuration: configuration)
                session.delegate = self
                workout = session
                let builder = session.associatedWorkoutBuilder()
                builder.delegate = self
                let source = HKLiveWorkoutDataSource(healthStore: healthStore, workoutConfiguration: configuration)
                for type in source.typesToCollect where type != heartType { source.disableCollection(for: type) }
                source.enableCollection(for: heartType, predicate: nil)
                builder.dataSource = source
                workoutBuilder = builder
                session.startActivity(with: startDate)
                let collectionStart = startDate
                collectionTask = Task {
                    try await builder.beginCollection(at: collectionStart)
                }
            } catch {
                try? rawFile?.close(); rawFile = nil
                errorMessage = "无法启动后台记录：\(error.localizedDescription)"; return
            }
        }
        paused = false
        running = true
        if !demo {
            motion.deviceMotionUpdateInterval = 1.0 / 50.0
            motion.startDeviceMotionUpdates(to: .main) { [weak self] data, error in
                guard let self, self.running, !self.paused else { return }
                if let error { self.finish(); self.errorMessage = "采集停止：\(error.localizedDescription)"; return }
                guard let data else { return }
                self.lastSampleTime = ProcessInfo.processInfo.systemUptime
                let a = data.userAcceleration, g = data.rotationRate
                self.consume(MotionSample(timestamp: data.timestamp, ax: a.x, ay: a.y, az: a.z, gx: g.x, gy: g.y, gz: g.z))
            }
        }
        timer = Timer.scheduledTimer(withTimeInterval: demo ? 0.02 : 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    private func recordRep(at time: Double) {
        count += 1
        window.append(time)
        statistics.recordRep(at: max(0, time - startUptime))
    }

    private func consume(_ sample: MotionSample) {
        processingSampleTime = sample.timestamp
        if sessionAxis == "AUTO" {
            let result = threeAxis.process(time: sample.timestamp,
                acceleration: SIMD3(sample.ax, sample.ay, sample.az), rotation: SIMD3(sample.gx, sample.gy, sample.gz))
            warmup = result.warmup
            if result.counted { recordRep(at: sample.timestamp) }
        } else {
            detector.processBatch([sample])
        }
        processingSampleTime = nil
        let freshHeart = heartDate.flatMap { Date().timeIntervalSince($0) <= 30 ? heartRate : nil }
        statistics.consume(at: max(0, sample.timestamp - startUptime), ax: sample.ax, ay: sample.ay, az: sample.az,
                           cadence: window.rate(at: sample.timestamp), heartRate: freshHeart)
        if let file = rawFile {
            let row = "\(sample.timestamp),\(sample.ax),\(sample.ay),\(sample.az),\(sample.gx),\(sample.gy),\(sample.gz)\n"
            do { try file.write(contentsOf: Data(row.utf8)) }
            catch { finish(); errorMessage = "运动数据写入失败：\(error.localizedDescription)" }
        }
    }

    private func tick() {
        guard running, !paused else { return }
        let now = ProcessInfo.processInfo.systemUptime
        elapsed = now - startUptime
        if sessionIsDemo {
            let value = sin(elapsed * 2 * .pi * 1.5) * 0.8
            consume(MotionSample(timestamp: now, ax: value, ay: value, az: value))
        } else if now - lastSampleTime > 5 {
            finish(); errorMessage = "超过 5 秒未收到运动数据，已结束记录。请检查运动权限。"; return
        }
        cadence = window.rate(at: now)
        if let date = heartDate, Date().timeIntervalSince(date) > 30 { heartRate = nil }
    }

    func togglePause() {
        guard running else { return }
        heartRate = nil; heartDate = nil
        if paused {
            if let pauseStartedAt { pauseIntervals.append(DateInterval(start: pauseStartedAt, end: Date())) }
            pauseStartedAt = nil
            startUptime = ProcessInfo.processInfo.systemUptime - elapsed
            lastSampleTime = ProcessInfo.processInfo.systemUptime
            window = CadenceWindow()
            detector.reset()
            threeAxis.reset()
            warmup = 3
            paused = false
            workout?.resume()
        } else {
            elapsed = ProcessInfo.processInfo.systemUptime - startUptime
            statistics.pause()
            pauseStartedAt = Date()
            paused = true
            cadence = 0
            workout?.pause()
        }
    }

    func finish() {
        guard running else { return }
        if !paused { elapsed = ProcessInfo.processInfo.systemUptime - startUptime }
        let endedAt = Date()
        if let pauseStartedAt { pauseIntervals.append(DateInterval(start: pauseStartedAt, end: endedAt)) }
        pauseStartedAt = nil
        let session = workout; workout = nil; session?.end()
        let builder = workoutBuilder; workoutBuilder = nil
        let collection = collectionTask; collectionTask = nil
        paused = false
        running = false; motion.stopDeviceMotionUpdates(); timer?.invalidate(); timer = nil
        do { try rawFile?.close() } catch { errorMessage = "数据文件关闭失败：\(error.localizedDescription)" }
        rawFile = nil
        pendingRecord = SessionRecord(id: UUID(), startedAt: startDate, duration: elapsed,
            count: count, isDemo: sessionIsDemo, csvFilename: rawName)
        pendingRecord?.endedAt = endedAt
        pendingRecord?.pauseIntervals = pauseIntervals
        pendingRecord?.motionSummary = statistics.finish(duration: elapsed)
        pendingRecord?.detectorMethod = sessionAxis == "AUTO" ? "three-axis-v1" : "single-\(sessionAxis)"
        pendingRecord?.modeKey = activeMode.rawValue
        pendingRecord?.updatedAt = Date()
        if let builder {
            let stats = builder.statistics(for: heartType)
            pendingRecord?.averageHeartRate = stats?.averageQuantity()?.doubleValue(for: .count().unitDivided(by: .minute()))
            pendingRecord?.maximumHeartRate = stats?.maximumQuantity()?.doubleValue(for: .count().unitDivided(by: .minute()))
        }
        if !sessionIsDemo { pendingRecord?.healthStatus = "未同步 · 请在 iPhone 选择" }
        let completedRecord = pendingRecord
        retrySave()
        if let record = completedRecord, !record.isDemo, let builder, let collection {
            Task {
                do {
                    try await collection.value
                    try await builder.endCollection(at: endedAt)
                    let stats = builder.statistics(for: heartType)
                    updateHeartSummary(record.id, average: stats?.averageQuantity()?.doubleValue(for: .count().unitDivided(by: .minute())), maximum: stats?.maximumQuantity()?.doubleValue(for: .count().unitDivided(by: .minute())))
                    builder.discardWorkout()
                } catch {
                    builder.discardWorkout()
                    errorMessage = "本次心率收尾未完成，本地运动记录已保留：\(error.localizedDescription)"
                }
                // Keep the ended session alive until its associated builder finishes saving.
                _ = session?.state
            }
        }
    }

    private func updateHeartSummary(_ id: UUID, average: Double?, maximum: Double?) {
        if pendingRecord?.id == id {
            pendingRecord?.averageHeartRate = average
            pendingRecord?.maximumHeartRate = maximum
            return
        }
        guard let index = records.firstIndex(where: { $0.id == id }) else { return }
        var updated = records
        updated[index].averageHeartRate = average
        updated[index].maximumHeartRate = maximum
        updated[index].updatedAt = Date()
        do { try archive.save(updated); records = updated; ConnectivityStore.shared.sendRecords(updated) }
        catch { errorMessage = "心率摘要保存失败：\(error.localizedDescription)" }
    }

    func retrySave() {
        guard let record = pendingRecord else { return }
        do {
            let updated = [record] + records
            try archive.save(updated); records = updated; ConnectivityStore.shared.sendRecords(updated); pendingRecord = nil
        } catch { errorMessage = "保存失败，请点“重试保存”：\(error.localizedDescription)" }
    }
    var needsSave: Bool { pendingRecord != nil }
    func delete(_ record: SessionRecord) {
        do {
            let updated = records.filter { $0.id != record.id }
            try archive.save(updated); records = updated; ConnectivityStore.shared.sendRecords(updated)
            if let filename = record.csvFilename {
                try FileManager.default.removeItem(at: archive.directory.appendingPathComponent(filename))
            }
        } catch { errorMessage = "删除失败：\(error.localizedDescription)" }
    }
}

// Delegate calls arrive on a background queue; ignore events from an old session.
extension SessionModel: HKWorkoutSessionDelegate {
    nonisolated func workoutSession(_ workoutSession: HKWorkoutSession,
        didChangeTo toState: HKWorkoutSessionState, from fromState: HKWorkoutSessionState, date: Date) {
        Task { @MainActor [weak self] in
            guard let self, self.workout === workoutSession else { return }
            if toState == .ended {
                self.finish()
                self.errorMessage = "系统已结束运动会话，已保存本次记录。"
            }
        }
    }

    nonisolated func workoutSession(_ workoutSession: HKWorkoutSession, didFailWithError error: Error) {
        Task { @MainActor [weak self] in
            guard let self, self.workout === workoutSession else { return }
            self.finish()
            self.errorMessage = "后台记录中断，已保存本次记录：\(error.localizedDescription)"
        }
    }
}

extension SessionModel: HKLiveWorkoutBuilderDelegate {
    nonisolated func workoutBuilderDidCollectEvent(_ workoutBuilder: HKLiveWorkoutBuilder) {}
    nonisolated func workoutBuilder(_ workoutBuilder: HKLiveWorkoutBuilder,
        didCollectDataOf collectedTypes: Set<HKSampleType>) {
        guard collectedTypes.contains(HKQuantityType(.heartRate)) else { return }
        Task { @MainActor [weak self] in
            guard let self, self.running, !self.paused, self.workoutBuilder === workoutBuilder,
                  let stats = workoutBuilder.statistics(for: self.heartType),
                  let quantity = stats.mostRecentQuantity(),
                  let date = stats.mostRecentQuantityDateInterval()?.end,
                  Date().timeIntervalSince(date) <= 30 else { return }
            let value = quantity.doubleValue(for: .count().unitDivided(by: .minute()))
            guard value.isFinite, value > 0 else { return }
            self.heartDate = date
            self.heartRate = value
        }
    }
}
