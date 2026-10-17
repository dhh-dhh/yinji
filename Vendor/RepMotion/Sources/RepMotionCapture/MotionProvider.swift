import Combine
import Foundation
import RepMotionCore

public protocol MotionProvider {
    var samplePublisher: AnyPublisher<[MotionSample], Never> { get }
    func start()
    func stop()
}
