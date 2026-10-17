import Combine
import Foundation
import RepMotionCore

public struct CalibrationResult: Sendable {
    public let calibration: RepCalibration
    public let detectedReps: Int
    public let previousReps: Int
    public let targetReps: Int
    public let combinationsTested: Int
    public let perfectMatches: Int

    public var improvement: Int {
        abs(previousReps - targetReps) - abs(detectedReps - targetReps)
    }

    public var isAlreadyOptimal: Bool {
        previousReps == targetReps
    }

    public init(
        calibration: RepCalibration,
        detectedReps: Int,
        previousReps: Int,
        targetReps: Int,
        combinationsTested: Int,
        perfectMatches: Int
    ) {
        self.calibration = calibration
        self.detectedReps = detectedReps
        self.previousReps = previousReps
        self.targetReps = targetReps
        self.combinationsTested = combinationsTested
        self.perfectMatches = perfectMatches
    }
}

public struct CalibrationEngine: Sendable {

    public init() {}

    public func calibrate(
        samples: [MotionSample],
        target: Int,
        current: RepCalibration
    ) -> CalibrationResult? {
        guard target > 0, samples.count >= 50 else { return nil }

        let previousCount = replayCount(samples: samples, calibration: current)

        if previousCount == target {
            return CalibrationResult(
                calibration: current,
                detectedReps: previousCount,
                previousReps: previousCount,
                targetReps: target,
                combinationsTested: 1,
                perfectMatches: 1
            )
        }

        // --- Pass 1: Coarse ---
        let coarseThresholds = [0.5, 0.7, 0.8, 1.0, 1.2, 1.5, 1.8, 2.0, 2.5]
        let coarseRefractory = [0.2, 0.3, 0.4, 0.6, 0.8]
        let axes: [DetectionAxis] = DetectionAxis.allCases
        let polarities: [PeakPolarity] = PeakPolarity.allCases

        var scored: [(RepCalibration, Int, Double)] = []

        for axis in axes {
            for thresh in coarseThresholds {
                for refrac in coarseRefractory {
                    for polarity in polarities {
                        var candidate = current
                        candidate.thresholdMultiplier = thresh
                        candidate.refractoryPeriod = refrac
                        candidate.detectionAxis = axis
                        candidate.peakPolarity = polarity

                        let count = replayCount(samples: samples, calibration: candidate)
                        let s = score(detected: count, target: target, candidate: candidate, current: current)
                        scored.append((candidate, count, s))
                    }
                }
            }
        }

        scored.sort { $0.2 < $1.2 }
        let top3 = Array(scored.prefix(3))

        // --- Pass 2: Fine ---
        var fineScored: [(RepCalibration, Int, Double)] = scored
        let alphas = [0.1, 0.15, 0.2, 0.25, 0.3]

        for (base, _, _) in top3 {
            let threshRange = stride(from: max(0.3, base.thresholdMultiplier - 0.2),
                                     through: base.thresholdMultiplier + 0.2,
                                     by: 0.05)
            let refracRange = stride(from: max(0.15, base.refractoryPeriod - 0.05),
                                     through: min(1.0, base.refractoryPeriod + 0.05),
                                     by: 0.01)
            for alpha in alphas {
                for thresh in threshRange {
                    for refrac in refracRange {
                        var candidate = base
                        candidate.alpha = alpha
                        candidate.thresholdMultiplier = thresh
                        candidate.refractoryPeriod = refrac

                        let count = replayCount(samples: samples, calibration: candidate)
                        let s = score(detected: count, target: target, candidate: candidate, current: current)
                        fineScored.append((candidate, count, s))
                    }
                }
            }
        }

        fineScored.sort { $0.2 < $1.2 }
        let perfectCount = fineScored.filter { $0.1 == target }.count

        guard let best = fineScored.first else { return nil }

        return CalibrationResult(
            calibration: best.0,
            detectedReps: best.1,
            previousReps: previousCount,
            targetReps: target,
            combinationsTested: fineScored.count,
            perfectMatches: perfectCount
        )
    }

    // MARK: - Private

    private func replayCount(samples: [MotionSample], calibration: RepCalibration) -> Int {
        let service = RepDetectionService()
        service.calibration = calibration
        var count = 0
        let cancellable = service.repPublisher.sink { _ in count += 1 }
        service.processBatch(samples)
        cancellable.cancel()
        return count
    }

    private func score(
        detected: Int,
        target: Int,
        candidate: RepCalibration,
        current: RepCalibration
    ) -> Double {
        let error = Double(abs(detected - target))
        let overshoot = Double(max(0, detected - target))
        let drift = paramDistance(candidate, current)
        return error + 0.3 * overshoot + 0.01 * drift
    }

    private func paramDistance(_ a: RepCalibration, _ b: RepCalibration) -> Double {
        let dThresh = abs(a.thresholdMultiplier - b.thresholdMultiplier)
        let dRefrac = abs(a.refractoryPeriod - b.refractoryPeriod) * 10
        let dAlpha = abs(a.alpha - b.alpha) * 5
        return dThresh + dRefrac + dAlpha
    }
}
