import Foundation

/// Built-in presets plus whatever the user has saved. Built-ins can be
/// selected and duplicated but never renamed or deleted.
struct PresetStore {
    private(set) var userPresets: [EQPreset]

    init(userPresets: [EQPreset]) {
        self.userPresets = userPresets
    }

    var all: [EQPreset] { EQPreset.builtIns + userPresets }

    func preset(id: UUID) -> EQPreset? { all.first { $0.id == id } }

    /// Menu-bar shortlist: the presets people actually flip between.
    var quickPicks: [EQPreset] {
        let builtIn = EQPreset.builtIns.prefix(4)
        return Array(builtIn) + userPresets.prefix(4)
    }

    private func uniqueName(_ name: String) -> String {
        let existing = Set(all.map(\.name))
        guard existing.contains(name) else { return name }
        var index = 2
        while existing.contains("\(name) \(index)") { index += 1 }
        return "\(name) \(index)"
    }

    @discardableResult
    mutating func create(name: String, settings: EQSettings) -> EQPreset {
        let preset = EQPreset(name: uniqueName(name), settings: settings)
        userPresets.append(preset)
        return preset
    }

    @discardableResult
    mutating func duplicate(_ preset: EQPreset) -> EQPreset {
        create(name: "\(preset.name) Copy", settings: preset.settings)
    }

    mutating func rename(id: UUID, to name: String) {
        guard let index = userPresets.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        userPresets[index].name = uniqueName(trimmed)
        userPresets[index].updatedAt = Date()
    }

    mutating func update(id: UUID, settings: EQSettings) {
        guard let index = userPresets.firstIndex(where: { $0.id == id }) else { return }
        userPresets[index].settings = settings
        userPresets[index].updatedAt = Date()
    }

    mutating func delete(id: UUID) {
        userPresets.removeAll { $0.id == id }
    }

    mutating func removeAllUserPresets() {
        userPresets.removeAll()
    }

    // MARK: - Import / export

    func exportData(_ presets: [EQPreset]) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(presets)
    }

    /// Imported presets always get fresh ids, so a file exported on another
    /// Mac cannot collide with or overwrite a local preset.
    @discardableResult
    mutating func importData(_ data: Data) throws -> Int {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let incoming = try decoder.decode([EQPreset].self, from: data)
        for preset in incoming {
            create(name: preset.name, settings: preset.settings)
        }
        return incoming.count
    }
}
