import Foundation

/// RBJ peaking-EQ biquad, Direct Form II transposed.
///
/// State and arithmetic are Double: at 31 Hz / 48 kHz the poles sit very close
/// to the unit circle and single-precision state accumulates audible noise.
/// The cost is irrelevant (20 sections x 2 channels x 48 kHz).
struct BiquadCoefficients {
    var b0: Double = 1, b1: Double = 0, b2: Double = 0
    var a1: Double = 0, a2: Double = 0

    static let identity = BiquadCoefficients()

    /// - Parameters:
    ///   - frequency: centre frequency in Hz
    ///   - q: quality factor; 1.41 gives roughly one-third-octave sections
    ///   - gainDB: peak gain, 0 dB means pass-through
    init(peakingAt frequency: Double, sampleRate: Double, q: Double, gainDB: Double) {
        guard sampleRate > 0, frequency > 0, frequency < sampleRate / 2, q > 0 else {
            self = .identity
            return
        }
        guard abs(gainDB) > 1e-9 else {
            self = .identity
            return
        }
        let a = pow(10, gainDB / 40)
        let w0 = 2 * Double.pi * frequency / sampleRate
        let cosW0 = cos(w0)
        let alpha = sin(w0) / (2 * q)

        let a0 = 1 + alpha / a
        b0 = (1 + alpha * a) / a0
        b1 = (-2 * cosW0) / a0
        b2 = (1 - alpha * a) / a0
        a1 = (-2 * cosW0) / a0
        a2 = (1 - alpha / a) / a0
    }

    init() {}
}

/// Per-channel filter state. Allocation-free once constructed; `process` is
/// safe to call from the audio IO thread.
struct BiquadState {
    private var z1: Double = 0
    private var z2: Double = 0

    mutating func reset() {
        z1 = 0
        z2 = 0
    }

    @inline(__always)
    mutating func process(_ x: Double, _ c: BiquadCoefficients) -> Double {
        let y = c.b0 * x + z1
        z1 = c.b1 * x - c.a1 * y + z2
        z2 = c.b2 * x - c.a2 * y
        return y
    }
}

#if DEBUG
enum BiquadSelfCheck {
    /// Runs at startup in debug builds. Fails loudly rather than shipping a
    /// filter that quietly does nothing.
    static func run() {
        let sampleRate = 48_000.0

        // 0 dB must be pass-through.
        let flat = BiquadCoefficients(peakingAt: 1_000, sampleRate: sampleRate, q: 1, gainDB: 0)
        var flatState = BiquadState()
        for i in 0..<1_000 {
            let x = sin(2 * Double.pi * 440 * Double(i) / sampleRate)
            let y = flatState.process(x, flat)
            assert(abs(y - x) < 1e-9, "0 dB biquad is not pass-through: \(y) vs \(x)")
        }

        // +12 dB at the centre frequency must multiply amplitude by ~3.981.
        let boost = BiquadCoefficients(peakingAt: 1_000, sampleRate: sampleRate, q: 1, gainDB: 12)
        var boostState = BiquadState()
        var inputEnergy = 0.0
        var outputEnergy = 0.0
        for i in 0..<9_600 {
            let x = sin(2 * Double.pi * 1_000 * Double(i) / sampleRate)
            let y = boostState.process(x, boost)
            if i >= 4_800 {  // skip the transient
                inputEnergy += x * x
                outputEnergy += y * y
            }
        }
        let ratio = (outputEnergy / inputEnergy).squareRoot()
        let expected = pow(10.0, 12.0 / 20.0)
        assert(abs(ratio - expected) / expected < 0.01,
               "+12 dB biquad gain is \(ratio), expected \(expected)")

        // A band far from the centre frequency must be left alone.
        var farState = BiquadState()
        var farInput = 0.0
        var farOutput = 0.0
        for i in 0..<9_600 {
            let x = sin(2 * Double.pi * 50 * Double(i) / sampleRate)
            let y = farState.process(x, boost)
            if i >= 4_800 {
                farInput += x * x
                farOutput += y * y
            }
        }
        let farRatio = (farOutput / farInput).squareRoot()
        assert(abs(farRatio - 1) < 0.05, "1 kHz boost leaked into 50 Hz: \(farRatio)")

        Log.info("biquad self-check passed (0 dB flat, +12 dB = \(String(format: "%.3f", ratio))x)")
    }
}
#endif
