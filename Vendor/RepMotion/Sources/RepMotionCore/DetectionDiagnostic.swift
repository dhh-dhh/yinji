import Foundation

public struct DetectionDiagnostic: Sendable {
    public let sampleIndex: Int
    public let rawValue: Double
    public let filteredValue: Double
    public let threshold: Double
    public let mean: Double
    public let stddev: Double

    public init(
        sampleIndex: Int,
        rawValue: Double,
        filteredValue: Double,
        threshold: Double,
        mean: Double,
        stddev: Double
    ) {
        self.sampleIndex = sampleIndex
        self.rawValue = rawValue
        self.filteredValue = filteredValue
        self.threshold = threshold
        self.mean = mean
        self.stddev = stddev
    }
}
