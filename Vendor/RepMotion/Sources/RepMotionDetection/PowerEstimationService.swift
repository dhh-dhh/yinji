import Combine
import Foundation
import RepMotionCore

public final class PowerEstimationService {

    // MARK: - Public

    public var powerPublisher: AnyPublisher<PowerReading, Never> {
        powerSubject.eraseToAnyPublisher()
    }

    public init() {}

    // MARK: - Private state

    private let powerSubject = PassthroughSubject<PowerReading, Never>()

    private var sessionPeakAccel: Double = 0
    private var recentRepPeaks: [Double] = []
    private let recentRepPeaksCap = 5

    private var currentWindowPeak: Double = 0

    // MARK: - Public API

    public func processBatch(_ samples: [MotionSample]) {
        for sample in samples {
            let magnitude = sqrt(sample.ax * sample.ax +
                                 sample.ay * sample.ay +
                                 sample.az * sample.az)
            if magnitude > currentWindowPeak {
                currentWindowPeak = magnitude
            }
        }
    }

    public func consumeRepEvent(_ event: RepEvent) {
        let repPeak = currentWindowPeak
        currentWindowPeak = 0

        recentRepPeaks.append(repPeak)
        if recentRepPeaks.count > recentRepPeaksCap {
            recentRepPeaks.removeFirst()
        }

        if repPeak > sessionPeakAccel {
            sessionPeakAccel = repPeak
        }

        let relativePower: Double
        if sessionPeakAccel > 0 {
            relativePower = min(1.0, repPeak / sessionPeakAccel)
        } else {
            relativePower = 0
        }

        let rollingAvg = recentRepPeaks.reduce(0, +) / Double(recentRepPeaks.count)
        let rollingMax = recentRepPeaks.max() ?? 0

        let rollingAvgPower: Double = rollingAvg > 0 ? repPeak / rollingAvg : 0
        let rollingMaxPower: Double = rollingMax > 0 ? repPeak / rollingMax : 0

        let reading = PowerReading(
            relativePower: relativePower,
            rollingAvgPower: rollingAvgPower,
            rollingMaxPower: rollingMaxPower,
            peakAcceleration: repPeak,
            repAvgAcceleration: rollingAvg
        )
        powerSubject.send(reading)
    }

    public func reset() {
        sessionPeakAccel = 0
        recentRepPeaks.removeAll()
        currentWindowPeak = 0
    }
}
