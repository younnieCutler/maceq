import XCTest
@testable import maceq

final class SafetyLimiterTests: XCTestCase {
    func testBelowThresholdStaysAtUnityGain() {
        var limiter = SafetyLimiter()
        limiter.prepare(sampleRate: 48_000)
        var gain = 1.0
        for _ in 0..<1_000 { gain = limiter.gain(forPeak: 0.5) }
        XCTAssertEqual(gain, 1, accuracy: 1e-6)
    }

    func testAboveThresholdConvergesToTheThreshold() {
        var limiter = SafetyLimiter()
        limiter.prepare(sampleRate: 48_000)
        let peak = 2.0  // +6 dBFS
        var gain = 1.0
        for _ in 0..<48_000 { gain = limiter.gain(forPeak: peak) }
        let threshold = pow(10, SafetyLimiter.thresholdDB / 20)
        XCTAssertEqual(gain * peak, threshold, accuracy: 0.01)
    }

    /// Attack (0.3 ms) must clamp down far faster than release (100 ms) lets
    /// go, or a transient rides through before the gain catches up.
    func testAttackReactsFasterThanRelease() {
        let sampleRate = 48_000.0

        var attacking = SafetyLimiter()
        attacking.prepare(sampleRate: sampleRate)
        var gain = 1.0
        var samplesToHalveGain = 0
        while gain > 0.5, samplesToHalveGain < Int(sampleRate) {
            gain = attacking.gain(forPeak: 4.0)  // well above threshold
            samplesToHalveGain += 1
        }

        var releasing = SafetyLimiter()
        releasing.prepare(sampleRate: sampleRate)
        for _ in 0..<4_800 { _ = releasing.gain(forPeak: 4.0) }  // drive gain down first
        let reducedGain = releasing.gain(forPeak: 4.0)
        let recoveryTarget = reducedGain + (1 - reducedGain) / 2
        var samplesToRecoverHalfway = 0
        var current = reducedGain
        while current < recoveryTarget, samplesToRecoverHalfway < Int(sampleRate) {
            current = releasing.gain(forPeak: 0)  // silence: nothing to limit
            samplesToRecoverHalfway += 1
        }

        XCTAssertLessThan(samplesToHalveGain, samplesToRecoverHalfway)
    }
}
