import Foundation

/// Last stage before the hardware. Catches peaks the headroom calculation
/// cannot predict: the moment a preset changes, a drag through an extreme
/// curve, or source material that was already near full scale.
///
/// Deliberately not a compressor. It sits at unity until the signal would
/// clip, so ordinary music passes through untouched.
struct SafetyLimiter {
    /// -0.3 dBFS: leaves room for inter-sample peaks without being audible.
    static let thresholdDB: Double = -0.3

    private var gain: Double = 1
    private var attackCoefficient: Double = 0
    private var releaseCoefficient: Double = 0
    private var threshold: Double = 1
    private(set) var reduction: Double = 0

    mutating func prepare(sampleRate: Double) {
        threshold = pow(10, SafetyLimiter.thresholdDB / 20)
        // 0.3 ms to clamp down, 100 ms to let go. Short enough that the
        // overshoot before the gain catches up stays inside the hard clamp
        // that follows, long enough not to distort low frequencies.
        attackCoefficient = 1 - exp(-1 / (0.0003 * sampleRate))
        releaseCoefficient = 1 - exp(-1 / (0.100 * sampleRate))
        gain = 1
        reduction = 0
    }

    mutating func reset() {
        gain = 1
        reduction = 0
    }

    /// Feedback design: no lookahead, so a single sample can slip through a
    /// fraction of a dB over threshold before the gain catches up.
    /// ponytail: acceptable while Auto Headroom does the real work. Swap in a
    ///           lookahead delay line only if measurements show overshoot.
    @inline(__always)
    mutating func gain(forPeak peak: Double) -> Double {
        let desired = peak > threshold ? threshold / peak : 1
        let coefficient = desired < gain ? attackCoefficient : releaseCoefficient
        gain += (desired - gain) * coefficient
        if gain < 1 {
            let amount = -20 * log10(max(gain, 1e-6))
            if amount > reduction { reduction = amount }
        }
        return gain
    }

    mutating func drainReduction() -> Double {
        let value = reduction
        reduction = 0
        return value
    }
}
