import AppKit
import Combine
import Foundation
import SwiftUI

/// The single object the UI talks to. Owns persistence, presets and the audio
/// session, and keeps them in step.
@MainActor
final class AppState: ObservableObject {

    @Published private(set) var status = AudioSession.Status()
    @Published private(set) var live: EQSettings
    @Published private(set) var selectedPresetID: UUID
    @Published private(set) var presets: PresetStore
    @Published var eqEnabled: Bool { didSet { applyEnabled() } }
    @Published private(set) var loginItemStatus: LoginItemManager.Status = .disabled
    @Published var showDockIcon: Bool { didSet { applyDockPolicy() } }
    @Published var showMenuBarIcon: Bool { didSet { persist { $0.showMenuBarIcon = self.showMenuBarIcon } } }
    @Published var startEQEnabled: Bool { didSet { persist { $0.startEQEnabled = self.startEQEnabled } } }
    @Published var limiterEnabled: Bool { didSet { applyLimiter() } }
    @Published var showTwentyBands: Bool {
        didSet {
            if oldValue != showTwentyBands, !showTwentyBands, !restoringForDevice {
                var settings = live
                settings.bandGainsDB = EQBands.collapseToTen(settings.bandGainsDB)
                commit(settings)
            }
            persist { $0.showTwentyBands = self.showTwentyBands }
            rememberCurrentDeviceState()
        }
    }
    @Published var spectrumEnabled: Bool {
        didSet {
            session.setSpectrumEnabled(spectrumEnabled)
            persist { $0.spectrumEnabled = self.spectrumEnabled }
        }
    }
    @Published var appearance: AppearanceMode { didSet { persist { $0.appearance = self.appearance.rawValue } } }
    @Published private(set) var availableOutputs: [OutputDevice] = []
    @Published var preferredDeviceUID: String? { didSet { applyPreferredDevice() } }

    let session = AudioSession()
    let updates = UpdateManager()

    private let store: SettingsStore
    private var restoringForDevice = false
    private var lastSeenDeviceUID = ""

    /// Presets share the built-in list, so the selection is meaningful even
    /// before anything is saved.
    var selectedPreset: EQPreset? { presets.preset(id: selectedPresetID) }

    /// True once the live curve has drifted from the preset it came from.
    var isModified: Bool {
        guard let preset = selectedPreset else { return true }
        var baseline = preset.settings
        if !showTwentyBands {
            baseline.bandGainsDB = EQBands.collapseToTen(baseline.bandGainsDB)
        }
        return baseline != live
    }

    init(store: SettingsStore = SettingsStore()) {
        self.store = store
        let settings = store.settings
        live = settings.live
        selectedPresetID = settings.selectedPresetID
        presets = PresetStore(userPresets: settings.userPresets)
        eqEnabled = settings.startEQEnabled ? settings.eqEnabled : false
        showDockIcon = settings.showDockIcon
        showMenuBarIcon = settings.showMenuBarIcon
        startEQEnabled = settings.startEQEnabled
        limiterEnabled = settings.limiterEnabled
        showTwentyBands = settings.showTwentyBands ?? false
        spectrumEnabled = settings.spectrumEnabled ?? true
        appearance = AppearanceMode(rawValue: settings.appearance ?? "") ?? .system
        preferredDeviceUID = settings.preferredDeviceUID

        if !showTwentyBands {
            let normalizedGains = EQBands.collapseToTen(live.bandGainsDB)
            if normalizedGains != live.bandGainsDB {
                live.bandGainsDB = normalizedGains
                let normalizedLive = live
                store.update { $0.live = normalizedLive }
            }
        }

        session.onStatusChange = { [weak self] status in
            Task { @MainActor in self?.handle(status: status) }
        }
    }

    func start() {
        applyDockPolicy()
        loginItemStatus = LoginItemManager.status
        refreshDevices()
        session.setPreferredDevice(uid: preferredDeviceUID)
        session.setLimiterEnabled(limiterEnabled)
        session.setSpectrumEnabled(spectrumEnabled)
        session.setEnabled(eqEnabled)
        session.apply(settings: live)
        session.start()
    }

    func shutdown() {
        store.flush()
        session.stop()
    }

    // MARK: - Equalizer

    func setBandGain(_ index: Int, dB: Double) {
        guard index >= 0, index < EQBands.count else { return }
        var settings = live
        if showTwentyBands {
            settings.bandGainsDB[index] = EQBands.clamp(dB)
        } else if let visibleIndex = EQBands.tenBandIndices.firstIndex(of: index) {
            var visibleGains = EQBands.tenBandIndices.map { settings.bandGainsDB[$0] }
            visibleGains[visibleIndex] = EQBands.clamp(dB)
            settings.bandGainsDB = EQBands.expandedFromTen(visibleGains)
        } else {
            return
        }
        commit(settings)
    }

    func setPreampDB(_ value: Double) {
        var settings = live
        settings.preampDB = min(max(value, -24), 12)
        commit(settings)
    }

    func setAutoHeadroom(_ value: Bool) {
        var settings = live
        settings.autoHeadroom = value
        commit(settings)
    }

    func resetBands() {
        select(preset: EQPreset.flatPreset)
    }

    func select(preset: EQPreset) {
        selectedPresetID = preset.id
        var settings = preset.settings
        if !showTwentyBands {
            settings.bandGainsDB = EQBands.collapseToTen(settings.bandGainsDB)
        }
        commit(settings)
        persist { $0.selectedPresetID = preset.id }
        rememberPresetForCurrentDevice()
    }

    private func commit(_ settings: EQSettings) {
        live = settings
        session.apply(settings: settings)
        persist { $0.live = settings }
        rememberCurrentDeviceState()
    }

    // MARK: - Presets

    func saveAsPreset(named name: String) {
        let preset = presets.create(name: name, settings: live)
        selectedPresetID = preset.id
        persistPresets()
        persist { $0.selectedPresetID = preset.id }
        rememberPresetForCurrentDevice()
    }

    func updateSelectedPreset() {
        guard let preset = selectedPreset, !preset.isBuiltIn else { return }
        presets.update(id: preset.id, settings: live)
        persistPresets()
    }

    func duplicate(_ preset: EQPreset) {
        let copy = presets.duplicate(preset)
        selectedPresetID = copy.id
        persistPresets()
        rememberCurrentDeviceState()
    }

    func rename(_ preset: EQPreset, to name: String) {
        presets.rename(id: preset.id, to: name)
        persistPresets()
    }

    func delete(_ preset: EQPreset) {
        guard !preset.isBuiltIn else { return }
        presets.delete(id: preset.id)
        normalizeDeviceSelections(for: [preset.id])
        if selectedPresetID == preset.id {
            select(preset: EQPreset.defaultPreset)
        }
        persistPresets()
    }

    func exportPresets(to url: URL) throws {
        let data = try presets.exportData(presets.userPresets)
        try data.write(to: url, options: .atomic)
    }

    func importPresets(from url: URL) throws -> Int {
        let count = try presets.importData(Data(contentsOf: url))
        persistPresets()
        return count
    }

    func resetPresets() {
        let deletedPresetIDs = Set(presets.userPresets.map(\.id))
        presets.removeAllUserPresets()
        normalizeDeviceSelections(for: deletedPresetIDs)
        select(preset: EQPreset.defaultPreset)
        persistPresets()
    }

    private func persistPresets() {
        let snapshot = presets.userPresets
        persist { $0.userPresets = snapshot }
        objectWillChange.send()
    }

    // MARK: - Devices

    func refreshDevices() {
        availableOutputs = OutputDevice.allOutputs()
    }

    private func applyPreferredDevice() {
        session.setPreferredDevice(uid: preferredDeviceUID)
        persist { $0.preferredDeviceUID = self.preferredDeviceUID }
    }

    private func rememberCurrentDeviceState(uid: String? = nil) {
        guard !restoringForDevice else { return }
        let deviceUID = uid ?? status.deviceUID
        guard !deviceUID.isEmpty else { return }
        let snapshot = DeviceEQState(live: live,
                                     selectedPresetID: selectedPresetID,
                                     showTwentyBands: showTwentyBands)
        persist {
            var states = $0.deviceStates ?? [:]
            states[deviceUID] = snapshot
            $0.deviceStates = states
        }
    }

    private func normalizeDeviceSelections(for deletedPresetIDs: Set<UUID>) {
        guard var states = store.settings.deviceStates else { return }
        var changed = false
        for (uid, value) in states where deletedPresetIDs.contains(value.selectedPresetID) {
            var deviceState = value
            deviceState.selectedPresetID = EQPreset.flatPreset.id
            states[uid] = deviceState
            changed = true
        }
        if changed {
            persist { $0.deviceStates = states }
        }
    }

    private func rememberPresetForCurrentDevice() {
        guard !restoringForDevice, !status.deviceUID.isEmpty else { return }
        let uid = status.deviceUID
        let presetID = selectedPresetID
        persist { $0.devicePresets[uid] = presetID }
        rememberCurrentDeviceState()
    }

    /// When the output changes, restore whatever this device sounded like last
    /// time. Guarded so the restore does not immediately write itself back.
    private func handle(status newStatus: AudioSession.Status) {
        let previousDeviceUID = lastSeenDeviceUID
        if !previousDeviceUID.isEmpty, previousDeviceUID != newStatus.deviceUID {
            rememberCurrentDeviceState(uid: previousDeviceUID)
        }
        status = newStatus
        guard !newStatus.deviceUID.isEmpty, newStatus.deviceUID != lastSeenDeviceUID else { return }
        lastSeenDeviceUID = newStatus.deviceUID
        refreshDevices()

        if let deviceState = store.settings.deviceStates?[newStatus.deviceUID] {
            restoringForDevice = true
            selectedPresetID = deviceState.selectedPresetID
            showTwentyBands = deviceState.showTwentyBands
            var settings = deviceState.live
            if !deviceState.showTwentyBands {
                settings.bandGainsDB = EQBands.collapseToTen(settings.bandGainsDB)
            }
            commit(settings)
            persist { $0.selectedPresetID = deviceState.selectedPresetID }
            restoringForDevice = false
            rememberCurrentDeviceState()
            Log.info("restored full sound state for \(newStatus.deviceName)")
            return
        }

        guard let presetID = store.settings.devicePresets[newStatus.deviceUID],
              let preset = presets.preset(id: presetID),
              presetID != selectedPresetID else { return }
        restoringForDevice = true
        selectedPresetID = preset.id
        var settings = preset.settings
        if !showTwentyBands {
            settings.bandGainsDB = EQBands.collapseToTen(settings.bandGainsDB)
        }
        commit(settings)
        persist { $0.selectedPresetID = preset.id }
        restoringForDevice = false
        rememberCurrentDeviceState()
        Log.info("restored preset '\(preset.name)' for \(newStatus.deviceName)")
    }

    // MARK: - Toggles

    private func applyEnabled() {
        session.setEnabled(eqEnabled)
        persist { $0.eqEnabled = self.eqEnabled }
    }

    private func applyLimiter() {
        session.setLimiterEnabled(limiterEnabled)
        persist { $0.limiterEnabled = self.limiterEnabled }
    }

    private func applyDockPolicy() {
        NSApp?.setActivationPolicy(showDockIcon ? .regular : .accessory)
        persist { $0.showDockIcon = self.showDockIcon }
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        loginItemStatus = LoginItemManager.setEnabled(enabled)
        persist { $0.launchAtLogin = enabled }
    }

    /// Removes presets, device mappings and the login item, and rebuilds the
    /// audio pipeline from defaults.
    func resetEverything() {
        let previousRestoringState = restoringForDevice
        restoringForDevice = true
        defer { restoringForDevice = previousRestoringState }
        LoginItemManager.setEnabled(false)
        store.resetToDefaults()
        presets = PresetStore(userPresets: [])
        selectedPresetID = EQPreset.defaultPreset.id
        live = EQPreset.defaultPreset.settings
        eqEnabled = true
        limiterEnabled = true
        showTwentyBands = false
        spectrumEnabled = true
        appearance = .system
        preferredDeviceUID = nil
        session.apply(settings: live)
        session.retry()
    }

    func retryAudio() { session.retry() }

    private func persist(_ mutate: @escaping (inout AppSettings) -> Void) {
        store.update(mutate)
    }
}
