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
        store.update { $0.eqEnabled = false; $0.live.bandGainsDB[3] = 4 }
        store.flush()

        let reloaded = SettingsStore(url: url)
        XCTAssertEqual(reloaded.settings.eqEnabled, false)
        XCTAssertEqual(reloaded.settings.live.bandGainsDB[3], 4)
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
