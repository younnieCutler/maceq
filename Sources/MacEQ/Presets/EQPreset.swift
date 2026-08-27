import Foundation

/// Everything that shapes the sound. Presets, device mappings and the live
/// state all round-trip through this one type.
struct EQSettings: Codable, Equatable, Sendable {
    var bandGainsDB: [Double]
    var preampDB: Double
    var autoHeadroom: Bool

    static let flat = EQSettings(bandGainsDB: [Double](repeating: 0, count: EQBands.count),
                                 preampDB: 0,
                                 autoHeadroom: true)

    init(bandGainsDB: [Double], preampDB: Double = 0, autoHeadroom: Bool = true) {
        self.bandGainsDB = EQSettings.normalize(bandGainsDB)
        self.preampDB = min(max(preampDB, -24), 12)
        self.autoHeadroom = autoHeadroom
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let gains = (try? container.decode([Double].self, forKey: .bandGainsDB)) ?? []
        let preamp = (try? container.decode(Double.self, forKey: .preampDB)) ?? 0
        let auto = (try? container.decode(Bool.self, forKey: .autoHeadroom)) ?? true
        self.init(bandGainsDB: gains, preampDB: preamp, autoHeadroom: auto)
    }

    /// Pads, truncates and clamps so a hand-edited or older file can never
    /// produce a malformed band list.
    private static func normalize(_ gains: [Double]) -> [Double] {
        (0..<EQBands.count).map { index in
            guard index < gains.count, gains[index].isFinite else { return 0 }
            return EQBands.clamp(gains[index])
        }
    }

    var isFlat: Bool { bandGainsDB.allSatisfy { abs($0) < 1e-6 } }
}

struct EQPreset: Codable, Equatable, Identifiable, Sendable {
    var id: UUID
    var name: String
    var settings: EQSettings
    var isBuiltIn: Bool
    var createdAt: Date
    var updatedAt: Date

    init(id: UUID = UUID(),
         name: String,
         settings: EQSettings,
         isBuiltIn: Bool = false,
         createdAt: Date = Date(),
         updatedAt: Date = Date()) {
        self.id = id
        self.name = name
        self.settings = settings
        self.isBuiltIn = isBuiltIn
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

extension EQPreset {
    /// Stable IDs so a device mapping written by an older build still resolves.
    private static func builtInID(_ index: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-4000-8000-%012d", index))!
    }

    /// Index of "Flat" within `builtIns`, so lookups don't have to match on
    /// the (now localized, no longer stable) display name.
    static let flatIndex = 8

    static let builtIns: [EQPreset] = {
        // Localization keys, not display names — the display name is looked
        // up through L() below so it follows the system language.
        let definitions: [(String, [Double])] = [
            ("preset.balanced", [1.5, 1.5, 1, 1, 0.5, 0.5, 0, 0, 0, 0,
                                 0, 0, 0.5, 0.5, 0.5, 0.5, 0.5, 0.5, 0, 0]),
            ("preset.bassBoost", [5, 4.5, 4, 3.5, 3, 2.5, 2, 1.5, 1, 0.5,
                                  0, 0, 0, 0, 0, 0, 0, 0, 0, 0]),
            ("preset.vocal", [-2.5, -2, -1.5, -1, -0.5, 0, 0, 0.5, 0.5, 1,
                              1.5, 2, 2, 1.5, 1, 0.5, 0, -0.5, -0.5, -0.5]),
            ("preset.acoustic", [-1.5, -1, -0.5, 0, 0.5, 0.5, 0, -0.5, -0.5, 0,
                                 0.5, 1, 1.5, 1.5, 1, 0.5, 1, 1.5, 1, 0.5]),
            ("preset.electronic", [4, 4, 3.5, 3, 2.5, 1.5, 0.5, -0.5, -1, -0.5,
                                   0, 0.5, 1, 1.5, 2, 2.5, 3, 3, 2.5, 2]),
            ("preset.classical", [0.5, 0.5, 0.5, 0.5, 0.5, 0, -0.5, -0.5, -0.5, 0,
                                  0, 0, 0, 0.5, 0.5, 0.5, 1, 1, 0.5, 0]),
            ("preset.podcast", [-6, -5, -4, -3, -2, -1, 0, 0.5, 1, 1.5,
                                2, 2.5, 2.5, 2, 1.5, 1, 0, -0.5, -1, -1.5]),
            ("preset.night", [2.5, 2.5, 2, 1.5, 1, 0.5, 0, 0, 0, 0,
                              0, 0, 0, 0, 0.5, 1, 1.5, 1.5, 1, 0.5]),
            ("preset.flat", [Double](repeating: 0, count: EQBands.count)),
        ]
        return definitions.enumerated().map { index, definition in
            EQPreset(id: builtInID(index),
                     name: L(definition.0),
                     settings: EQSettings(bandGainsDB: definition.1),
                     isBuiltIn: true,
                     createdAt: Date(timeIntervalSince1970: 0),
                     updatedAt: Date(timeIntervalSince1970: 0))
        }
    }()

    static var defaultPreset: EQPreset { builtIns[0] }
    static var flatPreset: EQPreset { builtIns[flatIndex] }
}
