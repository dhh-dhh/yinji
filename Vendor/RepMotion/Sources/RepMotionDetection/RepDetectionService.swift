import Combine
import Foundation
import RepMotionCore

public final class RepDetectionService {

    // MARK: - Public

    public var calibration = RepCalibration()

    public var repPublisher: AnyPublisher<RepEvent, Never> {
        repSubject.eraseToAnyPublisher()
    }

    public var rpmPublisher: AnyPublisher<Double, Never> {
        rpmSubject.eraseToAnyPublisher()
    }

    public var diagnosticPublisher: AnyPublisher<DetectionDiagnostic, Never> {
        diagnosticSubject.eraseToAnyPublisher()
    }

    public var warmupPublisher: AnyPublisher<TimeInterval, Never> {
        warmupSubject.eraseToAnyPublisher()
    }

    public init() {}

    // MARK: - Private state

    private let repSubject = PassthroughSubject<RepEvent, Never>()
    private let rpmSubject = PassthroughSubject<Double, Never>()
    private let diagnosticSubject = PassthroughSubject<DetectionDiagnostic, Never>()
    private let warmupSubject = PassthroughSubject<TimeInterval, Never>()

    private var sampleBuffer: [MotionSample] = []
    private let sampleBufferCap = 500

    private let minimumAbsoluteThreshold: Double = 0.05

    private var filteredY: Double = 0
    private var prevFilteredY: Double = 0
    private var preprevFilteredY: Double = 0

    private var lastRepTimestamp: TimeInterval = 0

    private var repTimestamps: [TimeInterval] = []
    private let rpmWindow: TimeInterval = 30

    private var lastMean: Double = 0
    private var lastStddev: Double = 0

    private var processedSampleCount: Int = 0

    private var startTimestamp: TimeInterval?

    private var warmupComplete: Bool {
        guard calibration.warmupDuration > 0 else { return true }
        guard let start = startTimestamp else { return false }
        guard let latest = sampleBuffer.last?.timestamp else { return false }
        return (latest - start) >= calibration.warmupDuration
    }

    // MARK: - Public API

    public func processBatch(_ samples: [MotionSample]) {
        for sample in samples {
            process(sample)
        }
    }

    public func reset() {
        sampleBuffer.removeAll()
        filteredY = 0
        prevFilteredY = 0
        preprevFilteredY = 0
        lastRepTimestamp = 0
        repTimestamps.removeAll()
        lastMean = 0
        lastStddev = 0
        processedSampleCount = 0
        startTimestamp = nil
    }

    // MARK: - Private

    private func process(_ sample: MotionSample) {
        sampleBuffer.append(sample)
        if sampleBuffer.count > sampleBufferCap {
            sampleBuffer.removeFirst()
        }

        if startTimestamp == nil {
            startTimestamp = sample.timestamp
        }

        if calibration.warmupDuration > 0, let start = startTimestamp {
            let remaining = max(0, calibration.warmupDuration - (sample.timestamp - start))
            warmupSubject.send(remaining)
        } else {
            warmupSubject.send(0)
        }

        let rawValue = axisValue(sample) * calibration.peakPolarity.multiplier
        preprevFilteredY = prevFilteredY
        prevFilteredY = filteredY
        filteredY = calibration.alpha * rawValue + (1 - calibration.alpha) * prevFilteredY

        let (mean, stddev) = dynamicStats()
        lastMean = mean
        lastStddev = stddev
        let dynamicThreshold = mean + calibration.thresholdMultiplier * stddev
        let threshold = max(dynamicThreshold, minimumAbsoluteThreshold)

        let diagnostic = DetectionDiagnostic(
            sampleIndex: processedSampleCount,
            rawValue: rawValue,
            filteredValue: filteredY,
            threshold: threshold,
            mean: mean,
            stddev: stddev
        )
        processedSampleCount += 1
        diagnosticSubject.send(diagnostic)

        guard sampleBuffer.count >= 3 else { return }

        let isPeak = prevFilteredY > preprevFilteredY && prevFilteredY > filteredY
        guard isPeak else { return }
        guard prevFilteredY > threshold else { return }

        let now = sample.timestamp
        guard warmupComplete else { return }
        guard now - lastRepTimestamp >= calibration.refractoryPeriod else { return }

        lastRepTimestamp = now
        confirmRep(at: now, peak: prevFilteredY)
    }

    private func axisValue(_ sample: MotionSample) -> Double {
        switch calibration.detectionAxis {
        case .x: return sample.ax
        case .y: return sample.ay
        case .z: return sample.az
        }
    }

    private func dynamicStats() -> (mean: Double, stddev: Double) {
        let polarity = calibration.peakPolarity.multiplier
        let window: [Double] = sampleBuffer.suffix(100).map { axisValue($0) * polarity }
        guard window.count > 1 else { return (0, 0) }
        let mean = window.reduce(0.0, +) / Double(window.count)
        let squaredDiffs: [Double] = window.map { ($0 - mean) * ($0 - mean) }
        let stddev = sqrt(squaredDiffs.reduce(0.0, +) / Double(window.count))
        return (mean, stddev)
    }

    private func confirmRep(at timestamp: TimeInterval, peak: Double) {
        let confidence: Double
        if lastStddev > 0 {
            confidence = min(1.0, (peak - lastMean) / (2 * lastStddev))
        } else {
            confidence = 0
        }

        let event = RepEvent(
            timestamp: Date(),
            confidence: confidence,
            peakAcceleration: peak
        )
        repSubject.send(event)

        repTimestamps.append(timestamp)
        purgeOldReps(before: timestamp - rpmWindow)
        let rpm = Double(repTimestamps.count) * 2
        rpmSubject.send(rpm)
    }

    private func purgeOldReps(before cutoff: TimeInterval) {
        repTimestamps.removeAll { $0 < cutoff }
    }
}
