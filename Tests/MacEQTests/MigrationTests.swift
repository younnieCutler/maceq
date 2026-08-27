import XCTest
@testable import maceq

final class MigrationTests: XCTestCase {
    func testUnknownSelectedPresetFallsBackToDefault() {
        var settings = AppSettings()
        settings.selectedPresetID = UUID()
        let migrated = Migration.migrate(settings)
        XCTAssertEqual(migrated.selectedPresetID, EQPreset.defaultPreset.id)
    }

    func testKnownSelectedPresetIsKept() {
        var settings = AppSettings()
        let target = EQPreset.builtIns[2].id
        settings.selectedPresetID = target
        XCTAssertEqual(Migration.migrate(settings).selectedPresetID, target)
    }

    func testDevicePresetsPointingAtDeletedPresetsAreDropped() {
        var settings = AppSettings()
        settings.devicePresets = [
            "device-a": EQPreset.defaultPreset.id,
            "device-b": UUID(),
        ]
        let migrated = Migration.migrate(settings)
        XCTAssertEqual(migrated.devicePresets.count, 1)
        XCTAssertNotNil(migrated.devicePresets["device-a"])
    }

    func testSchemaVersionIsStampedCurrent() {
        var settings = AppSettings()
        settings.schemaVersion = 0
        XCTAssertEqual(Migration.migrate(settings).schemaVersion, AppSettings.currentSchemaVersion)
    }
}
