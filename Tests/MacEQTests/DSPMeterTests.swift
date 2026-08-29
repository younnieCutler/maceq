import XCTest
@testable import maceq

final class DSPMeterTests: XCTestCase {
    func testSpectrumMagnitudeUsesWindowNormalization() {
        XCTAssertEqual(SpectrumMath.magnitudeDB(q1: 512,
                                                q2: 0,
                                                coefficient: 0,
                                                windowSize: 1_024),
                       0,
                       accuracy: 0.001)
    }

    func testSpectrumMagnitudeHasAnEightyDecibelNoiseFloor() {
        XCTAssertEqual(SpectrumMath.magnitudeDB(q1: 0,
                                                q2: 0,
                                                coefficient: 0,
                                                windowSize: 1_024),
                       -80,
                       accuracy: 0.001)
    }

    func testMetersKeepIndependentStereoPeaks() {
        var meters = DSPCore.Meters()
        meters.peakOutLeft = 0.25
        meters.peakOutRight = 0.75
        XCTAssertEqual(meters.peakOutLeft, 0.25)
        XCTAssertEqual(meters.peakOutRight, 0.75)
    }
}
