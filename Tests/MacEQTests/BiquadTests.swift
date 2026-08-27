import XCTest
@testable import maceq

final class BiquadTests: XCTestCase {
    let sampleRate = 48_000.0

    func testZeroDBIsPassThrough() {
        let coefficients = BiquadCoefficients(peakingAt: 1_000, sampleRate: sampleRate, q: 1, gainDB: 0)
        var state = BiquadState()
        for i in 0..<1_000 {
            let x = sin(2 * Double.pi * 440 * Double(i) / sampleRate)
            XCTAssertEqual(state.process(x, coefficients), x, accuracy: 1e-9)
        }
    }

    func testTwelveDBBoostMatchesTheoreticalGain() {
        let coefficients = BiquadCoefficients(peakingAt: 1_000, sampleRate: sampleRate, q: 1, gainDB: 12)
        var state = BiquadState()
        var inputEnergy = 0.0, outputEnergy = 0.0
        for i in 0..<9_600 {
            let x = sin(2 * Double.pi * 1_000 * Double(i) / sampleRate)
            let y = state.process(x, coefficients)
            if i >= 4_800 { inputEnergy += x * x; outputEnergy += y * y }
        }
        let ratio = (outputEnergy / inputEnergy).squareRoot()
        XCTAssertEqual(ratio, pow(10, 12.0 / 20), accuracy: pow(10, 12.0 / 20) * 0.01)
    }

    func testBoostDoesNotLeakIntoDistantBand() {
        let coefficients = BiquadCoefficients(peakingAt: 1_000, sampleRate: sampleRate, q: 1, gainDB: 12)
        var state = BiquadState()
        var inputEnergy = 0.0, outputEnergy = 0.0
        for i in 0..<9_600 {
            let x = sin(2 * Double.pi * 50 * Double(i) / sampleRate)
            let y = state.process(x, coefficients)
            if i >= 4_800 { inputEnergy += x * x; outputEnergy += y * y }
        }
        XCTAssertEqual((outputEnergy / inputEnergy).squareRoot(), 1, accuracy: 0.05)
    }

    func testDegenerateInputsFallBackToIdentity() {
        XCTAssertEqual(BiquadCoefficients(peakingAt: 1_000, sampleRate: 0, q: 1, gainDB: 6).b0, 1)
        XCTAssertEqual(BiquadCoefficients(peakingAt: -10, sampleRate: sampleRate, q: 1, gainDB: 6).b0, 1)
        XCTAssertEqual(BiquadCoefficients(peakingAt: 30_000, sampleRate: sampleRate, q: 1, gainDB: 6).b0, 1)
        XCTAssertEqual(BiquadCoefficients(peakingAt: 1_000, sampleRate: sampleRate, q: 0, gainDB: 6).b0, 1)
    }
}
