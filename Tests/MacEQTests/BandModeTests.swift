import XCTest
@testable import maceq

final class BandModeTests: XCTestCase {
    func testCollapsedCurveHasNoIndependentHiddenGains() {
        var gains = [Double](repeating: 0, count: EQBands.count)
        gains[1] = 10

        let collapsed = EQBands.collapseToTen(gains)
        let visible = EQBands.tenBandGains(from: gains)

        XCTAssertEqual(collapsed, EQBands.expandedFromTen(visible))
        XCTAssertNotEqual(collapsed[1], 10)
    }

    func testCollapseToTenIsIdempotent() {
        let gains = [1.0, 10, -2, 4, 0, 3, -1, 2, 0, -4,
                     1, 5, 0, -3, 2, 6, 0, -2, 1, 4]
        let collapsed = EQBands.collapseToTen(gains)
        XCTAssertEqual(EQBands.collapseToTen(collapsed), collapsed)
    }

    func testTenBandEditDerivesTheHiddenHalfOctaveBands() async {
        let url = temporarySettingsURL()
        defer { try? FileManager.default.removeItem(at: url) }
        await MainActor.run {
            let state = AppState(store: SettingsStore(url: url))
            state.setBandGain(0, dB: 4)

            let visible = EQBands.tenBandIndices.map { state.live.bandGainsDB[$0] }
            XCTAssertEqual(visible[0], 4, accuracy: 0.001)
            XCTAssertEqual(state.live.bandGainsDB, EQBands.expandedFromTen(visible))
        }
    }

    func testSwitchingToTenBandsCollapsesExistingHiddenGains() async {
        let url = temporarySettingsURL()
        defer { try? FileManager.default.removeItem(at: url) }
        await MainActor.run {
            let state = AppState(store: SettingsStore(url: url))
            state.showTwentyBands = true
            state.setBandGain(1, dB: 10)
            state.showTwentyBands = false

            let visible = EQBands.tenBandIndices.map { state.live.bandGainsDB[$0] }
            XCTAssertEqual(state.live.bandGainsDB, EQBands.expandedFromTen(visible))
        }
    }

    func testSelectingPresetInTenBandModeKeepsTheCurveUnmodified() async {
        let url = temporarySettingsURL()
        defer { try? FileManager.default.removeItem(at: url) }
        await MainActor.run {
            let state = AppState(store: SettingsStore(url: url))
            let preset = EQPreset.builtIns[0]
            state.select(preset: preset)

            let visible = EQBands.tenBandIndices.map { state.live.bandGainsDB[$0] }
            XCTAssertEqual(state.live.bandGainsDB, EQBands.expandedFromTen(visible))
            XCTAssertFalse(state.isModified)
        }
    }

    func testTenBandStateIsStableAcrossReload() async {
        let url = temporarySettingsURL()
        defer { try? FileManager.default.removeItem(at: url) }
        await MainActor.run {
            let store = SettingsStore(url: url)
            let first = AppState(store: store)
            first.showTwentyBands = true
            first.setBandGain(1, dB: 10)
            first.showTwentyBands = false
            store.flush()
            let saved = store.settings.live

            let reloaded = AppState(store: SettingsStore(url: url))
            XCTAssertEqual(reloaded.live, saved)
        }
    }

    private func temporarySettingsURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("maceq-band-mode-\(UUID().uuidString).json")
    }
}
