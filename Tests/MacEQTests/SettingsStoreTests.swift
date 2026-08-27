import XCTest
@testable import maceq

final class SettingsStoreTests: XCTestCase {
    private func tempURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("maceq-test-\(UUID().uuidString).json")
    }

    func testMissingFileFallsBackToDefaults() {
        let store = SettingsStore(url: tempURL())
        XCTAssertEqual(store.settings, AppSettings())
    }

    func testSaveAndReloadRoundTrips() {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let store = SettingsStore(url: url)
        let selected = EQPreset.builtIns[4]
        store.update {
            $0.eqEnabled = false
            $0.live.bandGainsDB[3] = 4
            $0.selectedPresetID = selected.id
        }
        store.flush()

        let reloaded = SettingsStore(url: url)
        XCTAssertEqual(reloaded.settings.eqEnabled, false)
        XCTAssertEqual(reloaded.settings.live.bandGainsDB[3], 4)
        XCTAssertEqual(reloaded.settings.selectedPresetID, selected.id)
    }

    func testSelectingPresetUpdatesLiveStateAndPersists() async {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let selected = EQPreset.builtIns[4]

        await MainActor.run {
            let store = SettingsStore(url: url)
            let state = AppState(store: store)
            state.select(preset: selected)
            XCTAssertEqual(state.selectedPresetID, selected.id)
            XCTAssertEqual(state.live, selected.settings)
            store.flush()
        }

        XCTAssertEqual(SettingsStore(url: url).settings.selectedPresetID, selected.id)
    }

    /// A corrupt settings file must not crash the app, and must not be
    /// silently deleted — it is the only evidence of what went wrong.
    func testCorruptFileFallsBackAndIsPreservedAsBackup() throws {
        let url = tempURL()
        defer {
            try? FileManager.default.removeItem(at: url)
            let backups = (try? FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path)) ?? []
            for name in backups where name.hasPrefix(url.lastPathComponent + ".corrupt-") {
                try? FileManager.default.removeItem(at: url.deletingLastPathComponent().appendingPathComponent(name))
            }
        }
        try Data("not json".utf8).write(to: url)

        let store = SettingsStore(url: url)
        XCTAssertEqual(store.settings, AppSettings())

        let siblings = try FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path)
        XCTAssertTrue(siblings.contains { $0.hasPrefix(url.lastPathComponent + ".corrupt-") })
    }
}
