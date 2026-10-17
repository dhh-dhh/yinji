import Foundation

/// Signed principal-axis projection avoids the doubled frequency of acceleration magnitude.
/// This is a motion-cycle estimator, not a classifier of activities.
struct ThreeAxisDetector {
    struct Result {
        var counted = false
        var warmup = 0.0
    }
    var sensitivity = 1.0
    init(sensitivity: Double = 1) { self.sensitivity = sensitivity }
    private var samples: [SIMD3<Double>] = []
    private var direction = SIMD3<Double>(0, 1, 0)
    private var mean = SIMD3<Double>(repeating: 0)
    private var filtered = SIMD3<Double>(repeating: 0)
    private var threshold = 0.08
    private var directional = false
    private var start: Double?
    private var lastTime: Double?
    private var cooldownUntil = 0.0
    private var sampleIndex = 0
    private var positiveTime: Double?
    private var negativeTime: Double?

    mutating func reset() {
        let setting = sensitivity
        self = ThreeAxisDetector()
        sensitivity = setting
    }

    mutating func process(time: Double, acceleration: SIMD3<Double>, rotation: SIMD3<Double>) -> Result {
        guard time.isFinite, values(acceleration).allSatisfy({ $0.isFinite }),
              values(rotation).allSatisfy({ $0.isFinite }) else { return Result() }
        if let lastTime, time <= lastTime { return Result(warmup: max(0, 3 - (lastTime - (start ?? lastTime)))) }
        if let lastTime, time - lastTime > 0.5 { reset() }
        if start == nil { start = time }
        let dt = lastTime.map { time - $0 } ?? 0.02
        lastTime = time
        // Time-based smoothing tolerates sampling rates around the requested 50 Hz.
        let alpha = 1 - exp(-dt / 0.045)
        filtered += (acceleration - filtered) * alpha
        samples.append(filtered)
        if samples.count > 100 { samples.removeFirst() }
        sampleIndex += 1
        if sampleIndex % 10 == 0, samples.count >= 25 { updateDirection(at: time) }

        if dot(rotation, rotation) > 25 {
            cooldownUntil = max(cooldownUntil, time + 0.6)
        }
        let remaining = max(0, 3 - (time - (start ?? time)))
        guard remaining == 0, time >= cooldownUntil, directional else {
            positiveTime = nil; negativeTime = nil
            return Result(warmup: remaining)
        }
        let signal = dot(filtered - mean, direction)
        if let positiveTime, time - positiveTime > 2.5 {
            self.positiveTime = nil; negativeTime = nil
        }
        if signal > threshold {
            if let positive = positiveTime, let negative = negativeTime {
                let period = time - positive
                // Require both lobes and a plausible complete cycle, not three independent peaks.
                let valid = period >= 0.3 && period <= 2.5 && negative - positive >= 0.08 && time - negative >= 0.08
                positiveTime = time; negativeTime = nil
                return Result(counted: valid)
            }
            if positiveTime == nil { positiveTime = time }
        } else if signal < -threshold, positiveTime != nil, negativeTime == nil {
            negativeTime = time
        }
        return Result()
    }

    private mutating func updateDirection(at time: Double) {
        mean = samples.reduce(SIMD3<Double>(repeating: 0), +) / Double(samples.count)
        var xx = 0.0, yy = 0.0, zz = 0.0, xy = 0.0, xz = 0.0, yz = 0.0
        for sample in samples {
            let a = sample - mean
            xx += a.x * a.x; yy += a.y * a.y; zz += a.z * a.z
            xy += a.x * a.y; xz += a.x * a.z; yz += a.y * a.z
        }
        let n = Double(samples.count)
        xx /= n; yy /= n; zz /= n; xy /= n; xz /= n; yz /= n
        func multiply(_ v: SIMD3<Double>) -> SIMD3<Double> {
            SIMD3(xx * v.x + xy * v.y + xz * v.z, xy * v.x + yy * v.y + yz * v.z, xz * v.x + yz * v.y + zz * v.z)
        }
        var axis = xx >= yy && xx >= zz ? SIMD3<Double>(1, 0, 0) : (yy >= zz ? SIMD3<Double>(0, 1, 0) : SIMD3<Double>(0, 0, 1))
        for _ in 0..<12 {
            let next = multiply(axis)
            let norm = sqrt(dot(next, next))
            guard norm > 1e-10 else { directional = false; return }
            axis = next / norm
        }
        let variance = max(0, dot(axis, multiply(axis)))
        let total = xx + yy + zz
        directional = total > 0.0004 && variance / total >= 0.6
        if dot(axis, direction) < 0 { axis = -axis }
        if abs(dot(axis, direction)) < 0.7 {
            cooldownUntil = max(cooldownUntil, time + 0.6)
            positiveTime = nil; negativeTime = nil
        }
        direction = axis
        threshold = max(0.08, sqrt(variance) * 0.55) * min(2, max(0.5, sensitivity))
    }

    private func dot(_ a: SIMD3<Double>, _ b: SIMD3<Double>) -> Double { a.x * b.x + a.y * b.y + a.z * b.z }
    private func values(_ v: SIMD3<Double>) -> [Double] { [v.x, v.y, v.z] }
}
