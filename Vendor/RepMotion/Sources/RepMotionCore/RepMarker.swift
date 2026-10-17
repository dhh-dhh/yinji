import Foundation

public struct RepMarker: Identifiable, Sendable {
    public let id: UUID
    public var bufferIndex: Int
    public let confidence: Double

    public init(bufferIndex: Int, confidence: Double, id: UUID = UUID()) {
        self.id = id
        self.bufferIndex = bufferIndex
        self.confidence = confidence
    }
}
