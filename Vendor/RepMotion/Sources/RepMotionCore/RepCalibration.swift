import Foundation

public enum DetectionAxis: String, CaseIterable, Identifiable, Sendable {
    case x = "X", y = "Y", z = "Z"
    public var id: String { rawValue }
}

public enum PeakPolarity: String, CaseIterable, Identifiable, Sendable {
    case positive = "Positive (+)"
    case negative = "Negative (−)"
    public var id: String { rawValue }
    public var multiplier: Double { self == .positive ? 1.0 : -1.0 }
}

public struct RepCalibration: Sendable {
    public var alpha: Double
    public var thresholdMultiplier: Double
    public var refractoryPeriod: Double
    public var detectionAxis: DetectionAxis
    public var peakPolarity: PeakPolarity
    public var warmupDuration: TimeInterval
    public var cooldownDuration: TimeInterval

    public init(
        alpha: Double = 0.2,
        thresholdMultiplier: Double = 1.5,
        refractoryPeriod: Double = 0.4,
        detectionAxis: DetectionAxis = .y,
        peakPolarity: PeakPolarity = .positive,
        warmupDuration: TimeInterval = 5.0,
        cooldownDuration: TimeInterval = 3.0
    ) {
        self.alpha = alpha
        self.thresholdMultiplier = thresholdMultiplier
        self.refractoryPeriod = refractoryPeriod
        self.detectionAxis = detectionAxis
        self.peakPolarity = peakPolarity
        self.warmupDuration = warmupDuration
        self.cooldownDuration = cooldownDuration
    }

    public static let `default` = RepCalibration()
}
