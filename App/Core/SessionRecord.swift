import Foundation

enum RecordingMode: String, CaseIterable {
    case solo, partner
    var title: String { self == .solo ? "单人" : "双人" }
    var symbol: String { self == .solo ? "person.fill" : "person.2.fill" }
}

struct SessionRecord: Codable, Identifiable {
    let id: UUID
    let startedAt: Date
    let duration: TimeInterval
    let count: Int
    let isDemo: Bool
    let csvFilename: String?
    var healthStatus: String? = nil
    var healthWorkoutID: UUID? = nil
    var averageHeartRate: Double? = nil
    var maximumHeartRate: Double? = nil
    var updatedAt: Date? = nil
    var modeKey: String? = nil
    var endedAt: Date? = nil
    var pauseIntervals: [DateInterval]? = nil
    var detectorMethod: String? = nil
    var motionSummary: MotionSummary? = nil
    var mode: RecordingMode { RecordingMode(rawValue: modeKey ?? "solo") ?? .solo }
    var averageRPM: Double { duration > 0 ? Double(count) * 60 / duration : 0 }
}

struct CadenceWindow {
    private var events: [TimeInterval] = []
    mutating func append(_ time: TimeInterval) { events.append(time) }
    mutating func rate(at time: TimeInterval) -> Double {
        events.removeAll { time - $0 > 5 }
        guard events.count >= 2, let first = events.first, let last = events.last,
              time - last < 2, last > first else { return 0 }
        return Double(events.count - 1) * 60 / (last - first)
    }
}

struct SessionArchive {
    let directory: URL
    var indexURL: URL { directory.appendingPathComponent("sessions.json") }
    func load() throws -> [SessionRecord] {
        guard FileManager.default.fileExists(atPath: indexURL.path) else { return [] }
        return try JSONDecoder().decode([SessionRecord].self, from: Data(contentsOf: indexURL))
    }
    func save(_ records: [SessionRecord]) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(records).write(to: indexURL, options: .atomic)
    }
}

struct RecordTransfer: Codable {
    let version: Int
    let records: [SessionRecord]
}

extension SessionRecord {
    static func merging(_ existing: [SessionRecord], with incoming: [SessionRecord]) -> [SessionRecord] {
        var result = Dictionary(existing.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        for record in incoming {
            if let old = result[record.id], (old.updatedAt ?? old.startedAt) > (record.updatedAt ?? record.startedAt) { continue }
            result[record.id] = record
        }
        return result.values.sorted { $0.startedAt > $1.startedAt }
    }
    static func csv(_ records: [SessionRecord]) -> String {
        let formatter = ISO8601DateFormatter()
        let header = "id,started_at,active_seconds,motion_count,average_per_minute,average_heart_bpm,max_heart_bpm,is_demo,mode,movement_seconds,still_seconds,unobserved_seconds,rms_acceleration_g,peak_acceleration_g,fastest_cadence,stability_percent,detector_method"
        func number(_ value: Double?) -> String { value.map { String($0) } ?? "" }
        let rows: [String] = records.map { r in
            var fields = [r.id.uuidString, formatter.string(from: r.startedAt), String(r.duration), String(r.count)]
            fields += [String(r.averageRPM), number(r.averageHeartRate), number(r.maximumHeartRate), String(r.isDemo), r.mode.rawValue]
            fields += [number(r.motionSummary?.movementSeconds), number(r.motionSummary?.stillSeconds), number(r.motionSummary?.unobservedSeconds)]
            fields += [number(r.motionSummary?.rmsAccelerationG), number(r.motionSummary?.peakAccelerationG)]
            fields += [number(r.motionSummary?.fastestCadence), number(r.motionSummary?.rhythmStability)]
            fields.append(r.detectorMethod ?? "legacy-single")
            return fields.joined(separator: ",")
        }
        return "\u{FEFF}" + ([header] + rows).joined(separator: "\r\n") + "\r\n"
    }
}

struct MotionTimelinePoint: Codable, Identifiable {
    let seconds: Double
    let segment: Int
    let cadence: Double
    let heartRate: Double?
    let intensityG: Double
    var id: Double { seconds }
}

struct MotionSummary: Codable {
    let version: Int
    let movementSeconds: Double
    let stillSeconds: Double
    let unobservedSeconds: Double
    let rmsAccelerationG: Double?
    let peakAccelerationG: Double?
    let fastestCadence: Double?
    let rhythmStability: Double?
    let intervalCount: Int
    let movementThresholdG: Double
    let timeline: [MotionTimelinePoint]
    let timelineStrideSeconds: Int
}

// One-second RMS windows classify measured motion only; missing samples are not stillness.
struct MotionStatistics {
    static let movementThresholdG = 0.08
    private var previousTime: Double?
    private var previousRep: Double?
    private var intervalCount = 0
    private var intervalMean = 0.0
    private var intervalM2 = 0.0
    private var totalEnergy = 0.0
    private var observed = 0.0
    private var peak = 0.0
    private var fastest = 0.0
    private var moving = 0.0
    private var still = 0.0
    private var bucketEnergy = 0.0
    private var bucketDuration = 0.0
    private var bucketCadence = 0.0
    private var bucketHeart: Double?
    private var bucketIndex: Int?
    private var lastTime = 0.0
    private var segment = 0
    private var timeline: [MotionTimelinePoint] = []
    private var stride = 1

    mutating func recordRep(at seconds: Double) {
        guard seconds.isFinite else { return }
        defer { previousRep = seconds }
        guard let last = previousRep else { return }
        let interval = seconds - last
        // Exclude gaps between motion bouts, using the cadence display's two-second timeout.
        guard interval > 0, interval < 2 else { return }
        intervalCount += 1
        let delta = interval - intervalMean
        intervalMean += delta / Double(intervalCount)
        intervalM2 += delta * (interval - intervalMean)
    }

    mutating func consume(at seconds: Double, ax: Double, ay: Double, az: Double,
                          cadence: Double, heartRate: Double?) {
        guard [seconds, ax, ay, az, cadence].allSatisfy({ $0.isFinite }), seconds >= 0 else { return }
        let energy = ax * ax + ay * ay + az * az
        guard energy.isFinite else { return }
        if let previousTime, seconds <= previousTime { return }
        let delta = previousTime.map { seconds - $0 } ?? 0
        previousTime = seconds
        if bucketIndex != Int(seconds) || delta > 0.25 {
            flush()
            if delta > 0.25 { segment += 1; previousRep = nil }
            bucketIndex = Int(seconds)
        }
        lastTime = seconds
        peak = max(peak, sqrt(energy))
        fastest = max(fastest, max(0, cadence))
        // 50 Hz requested; large gaps do not pretend to contain measured movement.
        guard delta > 0, delta <= 0.25 else { return }
        observed += delta
        totalEnergy += energy * delta
        bucketEnergy += energy * delta
        bucketDuration += delta
        bucketCadence += max(0, cadence) * delta
        bucketHeart = heartRate.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
    }

    mutating func pause() {
        flush()
        previousTime = nil
        previousRep = nil
        bucketIndex = nil
        segment += 1
    }

    mutating func finish(duration: Double) -> MotionSummary {
        flush()
        let stability: Double? = intervalCount >= 4 && intervalMean > 0
            ? max(0, min(100, 100 * (1 - sqrt(max(0, intervalM2) / Double(intervalCount)) / intervalMean))) : nil
        return MotionSummary(version: 1, movementSeconds: moving, stillSeconds: still,
            unobservedSeconds: max(0, duration - observed),
            rmsAccelerationG: observed > 0 ? sqrt(totalEnergy / observed) : nil,
            peakAccelerationG: observed > 0 ? peak : nil,
            fastestCadence: observed > 0 ? fastest : nil,
            rhythmStability: stability, intervalCount: intervalCount,
            movementThresholdG: Self.movementThresholdG, timeline: timeline, timelineStrideSeconds: stride)
    }

    private mutating func flush() {
        guard bucketDuration > 0 else { return }
        let rms = sqrt(bucketEnergy / bucketDuration)
        if rms >= Self.movementThresholdG { moving += bucketDuration } else { still += bucketDuration }
        if (bucketIndex ?? 0) % stride == 0 {
            timeline.append(MotionTimelinePoint(seconds: lastTime, segment: segment,
                cadence: bucketCadence / bucketDuration, heartRate: bucketHeart, intensityG: rms))
        }
        if timeline.count >= 3600 {
            timeline = timeline.enumerated().compactMap { $0.offset.isMultiple(of: 2) ? $0.element : nil }
            stride *= 2
        }
        bucketEnergy = 0; bucketDuration = 0; bucketCadence = 0; bucketHeart = nil
    }
}

extension SessionRecord {
    var timelineCSV: String {
        let header = "active_seconds,segment,cadence_per_minute,heart_bpm,rms_acceleration_g"
        let rows = (motionSummary?.timeline ?? []).map { point in
            [String(point.seconds), String(point.segment), String(point.cadence),
             point.heartRate.map { String($0) } ?? "", String(point.intensityG)].joined(separator: ",")
        }
        return "\u{FEFF}" + ([header] + rows).joined(separator: "\r\n") + "\r\n"
    }
}
