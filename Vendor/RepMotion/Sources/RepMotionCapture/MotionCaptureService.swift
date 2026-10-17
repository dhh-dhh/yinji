import Combine
import CoreMotion
import Foundation
import RepMotionCore

public final class MotionCaptureService: MotionProvider {

    public var samplePublisher: AnyPublisher<[MotionSample], Never> {
        sampleSubject.eraseToAnyPublisher()
    }

    public let sampleRate: Double

    public init(sampleRate: Double = 50.0) {
        self.sampleRate = sampleRate
    }

    private let sampleSubject = PassthroughSubject<[MotionSample], Never>()
    private var motionManager: CMMotionManager?
    private let bufferQueue = DispatchQueue(label: "com.repmotion.capture", qos: .userInteractive)

    public func start() {
        let mm = CMMotionManager()
        mm.deviceMotionUpdateInterval = 1.0 / sampleRate
        mm.startDeviceMotionUpdates(to: OperationQueue()) { [weak self] motion, error in
            guard let self, let motion, error == nil else { return }
            let sample = MotionSample(
                timestamp: motion.timestamp,
                ax: motion.userAcceleration.x,
                ay: motion.userAcceleration.y,
                az: motion.userAcceleration.z,
                gx: motion.rotationRate.x,
                gy: motion.rotationRate.y,
                gz: motion.rotationRate.z
            )
            self.bufferQueue.async {
                self.sampleSubject.send([sample])
            }
        }
        motionManager = mm
    }

    public func stop() {
        motionManager?.stopDeviceMotionUpdates()
        motionManager = nil
    }
}
