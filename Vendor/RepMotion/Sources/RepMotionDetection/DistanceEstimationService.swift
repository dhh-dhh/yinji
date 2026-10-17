import Combine
import Foundation

public final class DistanceEstimationService {

    public static let defaultBaseMeters: Double = 8.0

    public var distancePublisher: AnyPublisher<Double, Never> {
        distanceSubject.eraseToAnyPublisher()
    }

    public private(set) var totalDistance: Double = 0

    public init() {}

    private let distanceSubject = CurrentValueSubject<Double, Never>(0)

    public func addRep(power: Double) {
        totalDistance += Self.defaultBaseMeters * max(0, 0.5 + power)
        distanceSubject.send(totalDistance)
    }

    public func reset() {
        totalDistance = 0
        distanceSubject.send(0)
    }
}
