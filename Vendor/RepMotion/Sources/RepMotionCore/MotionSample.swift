import Foundation

public struct MotionSample: Sendable {
    public let timestamp: TimeInterval
    public let ax: Double, ay: Double, az: Double
    public let gx: Double, gy: Double, gz: Double

    public init(
        timestamp: TimeInterval,
        ax: Double, ay: Double, az: Double,
        gx: Double = 0, gy: Double = 0, gz: Double = 0
    ) {
        self.timestamp = timestamp
        self.ax = ax
        self.ay = ay
        self.az = az
        self.gx = gx
        self.gy = gy
        self.gz = gz
    }

    public func toDictionary() -> [String: Any] {
        ["ts": timestamp, "ax": ax, "ay": ay, "az": az,
         "gx": gx, "gy": gy, "gz": gz]
    }

    public static func from(dictionary dict: [String: Any]) -> MotionSample? {
        guard let ts = dict["ts"] as? TimeInterval,
              let ax = dict["ax"] as? Double,
              let ay = dict["ay"] as? Double,
              let az = dict["az"] as? Double else { return nil }
        return MotionSample(
            timestamp: ts, ax: ax, ay: ay, az: az,
            gx: dict["gx"] as? Double ?? 0,
            gy: dict["gy"] as? Double ?? 0,
            gz: dict["gz"] as? Double ?? 0
        )
    }
}
