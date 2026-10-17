import Foundation

public struct RepEvent: Sendable {
    public let timestamp: Date
    public let confidence: Double
    public let peakAcceleration: Double

    public init(timestamp: Date, confidence: Double, peakAcceleration: Double) {
        self.timestamp = timestamp
        self.confidence = confidence
        self.peakAcceleration = peakAcceleration
    }
}
