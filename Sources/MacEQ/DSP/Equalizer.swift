import Foundation

/// The fixed 20-band graphic EQ layout from the product spec.
enum EQBands {
    /// Roughly half-octave spacing from 31 Hz to 20 kHz.
    static let frequencies: [Double] = [
        31, 44, 63, 88, 125, 177, 250, 354, 500, 707,
        1_000, 1_400, 2_000, 2_800, 4_000, 5_600, 8_000, 11_300, 16_000, 20_000,
    ]

    static let count = frequencies.count

    /// Half-octave spacing would call for Q ≈ 2.87, where adjacent -3 dB points
    /// just touch. Widening the sections slightly makes neighbours overlap, so
    /// the summed response follows the curve the user drew instead of rippling
    /// between band centres.
    static let q: Double = 2.0

    static let minGainDB: Double = -12
    static let maxGainDB: Double = 12

    static func clamp(_ gainDB: Double) -> Double {
        min(max(gainDB, minGainDB), maxGainDB)
    }
}

extension BiquadCoefficients {
    /// Magnitude response at `frequency`, in dB.
    func magnitudeDB(at frequency: Double, sampleRate: Double) -> Double {
        let w = 2 * Double.pi * frequency / sampleRate
        let cosW = cos(w), sinW = sin(w)
        let cos2W = cos(2 * w), sin2W = sin(2 * w)

        let numeratorReal = b0 + b1 * cosW + b2 * cos2W
        let numeratorImaginary = -(b1 * sinW + b2 * sin2W)
        let denominatorReal = 1 + a1 * cosW + a2 * cos2W
        let denominatorImaginary = -(a1 * sinW + a2 * sin2W)

        let numerator = (numeratorReal * numeratorReal + numeratorImaginary * numeratorImaginary).squareRoot()
        let denominator = (denominatorReal * denominatorReal + denominatorImaginary * denominatorImaginary).squareRoot()
        guard denominator > 0 else { return 0 }
        return 20 * log10(max(numerator / denominator, 1e-12))
    }
}

/// Works out how much the EQ can amplify the loudest part of the signal, which
/// is what Auto Headroom has to cancel out.
///
/// Summing the positive band gains would massively over-estimate, and taking
/// the single largest band gain under-estimates wherever neighbours overlap.
/// Evaluating the actual cascade response is both cheap and correct.
enum Headroom {
    /// Peak magnitude of the whole cascade, in dB, never below 0.
    static func requiredDB(bandGainsDB: [Double], sampleRate: Double) -> Double {
        guard bandGainsDB.contains(where: { abs($0) > 1e-6 }) else { return 0 }
        let nyquist = sampleRate / 2

        var coefficients: [BiquadCoefficients] = []
        coefficients.reserveCapacity(EQBands.count)
        for (index, frequency) in EQBands.frequencies.enumerated() where index < bandGainsDB.count {
            coefficients.append(BiquadCoefficients(peakingAt: frequency,
                                                   sampleRate: sampleRate,
                                                   q: EQBands.q,
                                                   gainDB: bandGainsDB[index]))
        }

        // 256 log-spaced probes from 20 Hz to just under Nyquist resolve every
        // peak a Q=2 section can produce.
        let probes = 256
        let lowest = 20.0
        let highest = min(22_000, nyquist * 0.98)
        guard highest > lowest else { return 0 }
        let ratio = log(highest / lowest) / Double(probes - 1)

        var peak = 0.0
        for step in 0..<probes {
            let frequency = lowest * exp(Double(step) * ratio)
            var total = 0.0
            for coefficient in coefficients {
                total += coefficient.magnitudeDB(at: frequency, sampleRate: sampleRate)
            }
            if total > peak { peak = total }
        }
        return peak
    }

    /// Preamp actually applied once Auto Headroom has had its say.
    static func effectivePreampDB(userPreampDB: Double,
                                  requiredDB: Double,
                                  autoHeadroom: Bool) -> Double {
        autoHeadroom ? userPreampDB - requiredDB : userPreampDB
    }
}

#if DEBUG
enum HeadroomSelfCheck {
    /// A wrong headroom number is inaudible until something clips, so it gets
    /// checked at startup like the biquad does.
    static func run() {
        let rate = 48_000.0

        let flat = Headroom.requiredDB(bandGainsDB: [Double](repeating: 0, count: EQBands.count),
                                       sampleRate: rate)
        assert(flat == 0, "flat EQ should need no headroom, got \(flat)")

        // One band at +6 dB must ask for about 6 dB and nothing like 20.
        var single = [Double](repeating: 0, count: EQBands.count)
        single[10] = 6
        let singleHeadroom = Headroom.requiredDB(bandGainsDB: single, sampleRate: rate)
        assert(abs(singleHeadroom - 6) < 0.5,
               "single +6 dB band needs \(singleHeadroom) dB")

        // Neighbouring bands overlap, so two adjacent +6 dB bands must need
        // more than 6 dB but far less than the naive 12 dB sum.
        var pair = [Double](repeating: 0, count: EQBands.count)
        pair[10] = 6
        pair[11] = 6
        let pairHeadroom = Headroom.requiredDB(bandGainsDB: pair, sampleRate: rate)
        assert(pairHeadroom > singleHeadroom && pairHeadroom < 12,
               "adjacent bands need \(pairHeadroom) dB")

        // Cuts alone can never make the signal louder.
        let cuts = Headroom.requiredDB(bandGainsDB: [Double](repeating: -6, count: EQBands.count),
                                       sampleRate: rate)
        assert(cuts == 0, "all-cut EQ should need no headroom, got \(cuts)")

        let effective = Headroom.effectivePreampDB(userPreampDB: 0,
                                                   requiredDB: singleHeadroom,
                                                   autoHeadroom: true)
        assert(abs(effective + singleHeadroom) < 1e-9)

        Log.info(String(format: "headroom self-check passed (+6 dB band = %.2f dB, "
            + "two adjacent = %.2f dB)", singleHeadroom, pairHeadroom))
    }
}
#endif

extension EQBands {
    /// Compact label for on-screen readouts.
    static func label(_ index: Int) -> String {
        guard index >= 0, index < count else { return "—" }
        let frequency = frequencies[index]
        if frequency >= 1_000 {
            let kilohertz = frequency / 1_000
            return kilohertz == kilohertz.rounded()
                ? "\(Int(kilohertz)) kHz"
                : String(format: "%.1f kHz", kilohertz)
        }
        return "\(Int(frequency)) Hz"
    }

    /// VoiceOver reads units in full, per the accessibility requirement:
    /// "125 hertz, plus 2.5 decibels".
    static func spokenLabel(_ index: Int) -> String {
        guard index >= 0, index < count else { return "" }
        let frequency = frequencies[index]
        return frequency >= 1_000
            ? L("a11y.frequency.khz", frequency / 1_000)
            : L("a11y.frequency.hz", Int(frequency))
    }

    static func spokenGain(_ dB: Double) -> String {
        let rounded = (dB * 10).rounded() / 10
        if abs(rounded) < 0.05 { return L("a11y.gain.zero") }
        return rounded > 0 ? L("a11y.gain.plus", abs(rounded)) : L("a11y.gain.minus", abs(rounded))
    }
}

extension EQBands {
    /// Axis label, short enough for a 28-point column.
    static func shortLabel(_ index: Int) -> String {
        guard index >= 0, index < count else { return "" }
        let frequency = frequencies[index]
        if frequency >= 1_000 {
            let kilohertz = frequency / 1_000
            return kilohertz == kilohertz.rounded() ? "\(Int(kilohertz))k" : String(format: "%.1fk", kilohertz)
        }
        return "\(Int(frequency))"
    }
}
