public struct PowerReading: Sendable {
    public let relativePower: Double
    public let rollingAvgPower: Double
    public let rollingMaxPower: Double
    public let peakAcceleration: Double
    public let repAvgAcceleration: Double

    public init(
        relativePower: Double,
        rollingAvgPower: Double,
        rollingMaxPower: Double,
        peakAcceleration: Double,
        repAvgAcceleration: Double
    ) {
        self.relativePower = relativePower
        self.rollingAvgPower = rollingAvgPower
        self.rollingMaxPower = rollingMaxPower
        self.peakAcceleration = peakAcceleration
        self.repAvgAcceleration = repAvgAcceleration
    }

    public func value(for mode: PowerMode) -> Double {
        switch mode {
        case .rollingAvg: return rollingAvgPower
        case .rollingMax: return rollingMaxPower
        case .absolute: return peakAcceleration
        }
    }
}
