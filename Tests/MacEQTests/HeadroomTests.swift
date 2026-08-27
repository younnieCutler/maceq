import XCTest
@testable import maceq

final class HeadroomTests: XCTestCase {
    let sampleRate = 48_000.0

    func testFlatEQNeedsNoHeadroom() {
        let gains = [Double](repeating: 0, count: EQBands.count)
        XCTAssertEqual(Headroom.requiredDB(bandGainsDB: gains, sampleRate: sampleRate), 0)
    }

    func testAllCutsNeedNoHeadroom() {
        let gains = [Double](repeating: -6, count: EQBands.count)
        XCTAssertEqual(Headroom.requiredDB(bandGainsDB: gains, sampleRate: sampleRate), 0)
    }

    func testSingleBandNeedsApproximatelyItsOwnGain() {
        var gains = [Double](repeating: 0, count: EQBands.count)
        gains[10] = 6
        let required = Headroom.requiredDB(bandGainsDB: gains, sampleRate: sampleRate)
        XCTAssertEqual(required, 6.5, accuracy: 0.05)
    }

    func testPositivePeakIncludesSafetyMargin() {
        var gains = [Double](repeating: 0, count: EQBands.count)
        gains[10] = 4
        XCTAssertEqual(Headroom.requiredDB(bandGainsDB: gains, sampleRate: sampleRate), 4.5, accuracy: 0.05)
    }

    func testOverlappingBandsNeedMoreThanOneAloneButLessThanTheSum() {
        var single = [Double](repeating: 0, count: EQBands.count)
        single[10] = 6
        let singleHeadroom = Headroom.requiredDB(bandGainsDB: single, sampleRate: sampleRate)

        var pair = single
        pair[11] = 6
        let pairHeadroom = Headroom.requiredDB(bandGainsDB: pair, sampleRate: sampleRate)

        XCTAssertGreaterThan(pairHeadroom, singleHeadroom)
        XCTAssertLessThan(pairHeadroom, 12)
    }

    func testEffectivePreampCancelsRequiredHeadroomWhenAutoOn() {
        let effective = Headroom.effectivePreampDB(userPreampDB: 2, requiredDB: 5, autoHeadroom: true)
        XCTAssertEqual(effective, -3)
    }

    func testEffectivePreampIgnoresHeadroomWhenAutoOff() {
        let effective = Headroom.effectivePreampDB(userPreampDB: 2, requiredDB: 5, autoHeadroom: false)
        XCTAssertEqual(effective, 2)
    }
}
