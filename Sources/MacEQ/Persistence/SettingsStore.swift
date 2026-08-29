import Foundation

struct DeviceEQState: Codable, Equatable {
    var live: EQSettings
    var selectedPresetID: UUID
    var showTwentyBands: Bool
}

/// Everything that has to survive a relaunch.
struct AppSettings: Codable, Equatable {
    /// Bumped whenever the shape changes so `Migration` knows what it is
    /// looking at.
    var schemaVersion: Int = AppSettings.currentSchemaVersion

    var eqEnabled = true
    var startEQEnabled = true
    var selectedPresetID: UUID = EQPreset.defaultPreset.id
    /// The live curve, which drifts away from the selected preset as soon as
    /// the user touches a band.
    var live: EQSettings = EQPreset.defaultPreset.settings
    var limiterEnabled = true
    /// Optional keeps settings files from older builds decodable.
    var showTwentyBands: Bool?
    var spectrumEnabled: Bool?

    var launchAtLogin = false
    var showMenuBarIcon = true
    var showDockIcon = false
    /// `system`, `light`, or `dark`; optional for older settings files.
    var appearance: String?

    /// `nil` follows the system default output device.
    var preferredDeviceUID: String?
    /// Device UID -> preset id, so plugging headphones back in restores what
    /// they sounded like last time.
    var devicePresets: [String: UUID] = [:]
    /// Full sound snapshot per output device; optional for older settings.
    var deviceStates: [String: DeviceEQState]?

    var userPresets: [EQPreset] = []

    static let currentSchemaVersion = 1
}

/// Reads and writes `AppSettings` as JSON under Application Support.
///
/// A corrupt or partial file must never stop the app from starting, so every
/// failure path falls back to defaults and the bad file is kept aside rather
/// than deleted.
final class SettingsStore {
    private let url: URL
    private let queue = DispatchQueue(label: "com.maceq.settings")
    private var pending: DispatchWorkItem?

    private(set) var settings: AppSettings

    init(url: URL? = nil) {
        self.url = url ?? SettingsStore.defaultURL()
        settings = SettingsStore.load(from: self.url)
    }

    static func defaultURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        let directory = base.appendingPathComponent("MacEQ", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("settings.json")
    }

    private static func load(from url: URL) -> AppSettings {
        guard let data = try? Data(contentsOf: url) else { return AppSettings() }
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return Migration.migrate(try decoder.decode(AppSettings.self, from: data))
        } catch {
            // Keep the file: it is the only evidence of what went wrong, and
            // silently deleting a user's presets is worse than ignoring them.
            let backup = url.appendingPathExtension("corrupt-\(Int(Date().timeIntervalSince1970))")
            try? FileManager.default.moveItem(at: url, to: backup)
            Log.info("settings unreadable (\(error)); starting fresh, old file kept at \(backup.lastPathComponent)")
            return AppSettings()
        }
    }

    func update(_ mutate: (inout AppSettings) -> Void) {
        mutate(&settings)
        scheduleSave()
    }

    /// Coalesces bursts of changes — dragging a band fires on every frame.
    private func scheduleSave() {
        pending?.cancel()
        let snapshot = settings
        let work = DispatchWorkItem { [url] in SettingsStore.write(snapshot, to: url) }
        pending = work
        queue.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    func flush() {
        pending?.cancel()
        pending = nil
        let snapshot = settings
        queue.sync { SettingsStore.write(snapshot, to: url) }
    }

    private static func write(_ settings: AppSettings, to url: URL) {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(settings)
            // Atomic: a crash mid-write must not leave a half-written file.
            try data.write(to: url, options: .atomic)
        } catch {
            Log.info("warn: could not save settings: \(error)")
        }
    }

    func resetToDefaults() {
        settings = AppSettings()
        flush()
    }
}

enum Migration {
    static func migrate(_ settings: AppSettings) -> AppSettings {
        var result = settings
        if result.schemaVersion < AppSettings.currentSchemaVersion {
            result.schemaVersion = AppSettings.currentSchemaVersion
        }
        // A preset id that no longer resolves would leave the UI with no
        // selection at all.
        let known = Set(EQPreset.builtIns.map(\.id)).union(result.userPresets.map(\.id))
        if !known.contains(result.selectedPresetID) {
            result.selectedPresetID = EQPreset.defaultPreset.id
        }
        result.devicePresets = result.devicePresets.filter { known.contains($0.value) }
        if let deviceStates = result.deviceStates {
            result.deviceStates = deviceStates.filter { known.contains($0.value.selectedPresetID) }
        }
        return result
    }
}
