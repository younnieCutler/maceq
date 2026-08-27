import XCTest
@testable import maceq

final class PresetStoreTests: XCTestCase {
    func testBuiltInsCannotBeDeletedOrRenamed() {
        var store = PresetStore(userPresets: [])
        let flat = EQPreset.flatPreset
        let originalName = flat.name
        store.rename(id: flat.id, to: "Nope")
        store.delete(id: flat.id)
        XCTAssertTrue(store.all.contains { $0.id == flat.id && $0.name == originalName })
    }

    func testCreateGivesUniqueNames() {
        var store = PresetStore(userPresets: [])
        let a = store.create(name: "My Sound", settings: .flat)
        let b = store.create(name: "My Sound", settings: .flat)
        XCTAssertNotEqual(a.name, b.name)
    }

    func testDuplicateCopiesSettingsWithNewID() {
        var store = PresetStore(userPresets: [])
        var settings = EQSettings.flat
        settings.bandGainsDB[0] = 4
        let original = store.create(name: "Custom", settings: settings)
        let copy = store.duplicate(original)
        XCTAssertNotEqual(copy.id, original.id)
        XCTAssertEqual(copy.settings, original.settings)
    }

    func testExportImportRoundTripsWithFreshIDs() throws {
        var store = PresetStore(userPresets: [])
        let original = store.create(name: "Custom", settings: .flat)
        let data = try store.exportData([original])

        var target = PresetStore(userPresets: [])
        let count = try target.importData(data)
        XCTAssertEqual(count, 1)
        XCTAssertEqual(target.userPresets.first?.name, original.name)
        XCTAssertNotEqual(target.userPresets.first?.id, original.id)
    }

    func testDeleteRemovesOnlyTheTargetedPreset() {
        var store = PresetStore(userPresets: [])
        let a = store.create(name: "A", settings: .flat)
        let b = store.create(name: "B", settings: .flat)
        store.delete(id: a.id)
        XCTAssertNil(store.preset(id: a.id))
        XCTAssertNotNil(store.preset(id: b.id))
    }
}

final class EQSettingsTests: XCTestCase {
    func testGainsAreClampedToRange() {
        let settings = EQSettings(bandGainsDB: [100, -100] + [Double](repeating: 0, count: 18))
        XCTAssertEqual(settings.bandGainsDB[0], EQBands.maxGainDB)
        XCTAssertEqual(settings.bandGainsDB[1], EQBands.minGainDB)
    }

    func testShortArrayIsPaddedWithZero() {
        let settings = EQSettings(bandGainsDB: [3, 3])
        XCTAssertEqual(settings.bandGainsDB.count, EQBands.count)
        XCTAssertEqual(settings.bandGainsDB[19], 0)
    }

    func testNonFiniteGainBecomesZero() {
        let settings = EQSettings(bandGainsDB: [.nan, .infinity] + [Double](repeating: 0, count: 18))
        XCTAssertEqual(settings.bandGainsDB[0], 0)
        XCTAssertEqual(settings.bandGainsDB[1], 0)
    }

    func testCodableRoundTrip() throws {
        var settings = EQSettings.flat
        settings.bandGainsDB[5] = 3.5
        settings.preampDB = -2
        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(EQSettings.self, from: data)
        XCTAssertEqual(decoded, settings)
    }

    func testDecodingMissingFieldsFallsBackToDefaults() throws {
        let data = Data("{}".utf8)
        let decoded = try JSONDecoder().decode(EQSettings.self, from: data)
        XCTAssertEqual(decoded, EQSettings.flat)
    }
}
