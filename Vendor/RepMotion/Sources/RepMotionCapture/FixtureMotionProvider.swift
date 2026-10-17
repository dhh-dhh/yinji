import Combine
import Foundation
import RepMotionCore

public final class FixtureMotionProvider: MotionProvider {

    public var samplePublisher: AnyPublisher<[MotionSample], Never> {
        sampleSubject.eraseToAnyPublisher()
    }

    private let samples: [MotionSample]
    private let batchSize: Int
    private let speedMultiplier: Double
    private let sampleSubject = PassthroughSubject<[MotionSample], Never>()
    private var timer: DispatchSourceTimer?
    private var index = 0

    public init(samples: [MotionSample], batchSize: Int = 1, speedMultiplier: Double = 1.0) {
        self.samples = samples
        self.batchSize = batchSize
        self.speedMultiplier = max(0.1, speedMultiplier)
    }

    public func start() {
        guard !samples.isEmpty else { return }
        index = 0

        let interval = samples.count >= 2
            ? (samples[1].timestamp - samples[0].timestamp) / speedMultiplier
            : 0.02 / speedMultiplier

        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .userInteractive))
        timer.schedule(deadline: .now(), repeating: interval * Double(batchSize))
        timer.setEventHandler { [weak self] in
            self?.emitNextBatch()
        }
        timer.resume()
        self.timer = timer
    }

    public func stop() {
        timer?.cancel()
        timer = nil
    }

    /// Emit all samples synchronously in batches. Useful for unit tests.
    public func replayAll() {
        var offset = 0
        while offset < samples.count {
            let end = min(offset + batchSize, samples.count)
            sampleSubject.send(Array(samples[offset..<end]))
            offset = end
        }
    }

    private func emitNextBatch() {
        guard index < samples.count else {
            stop()
            return
        }
        let end = min(index + batchSize, samples.count)
        sampleSubject.send(Array(samples[index..<end]))
        index = end
    }
}
