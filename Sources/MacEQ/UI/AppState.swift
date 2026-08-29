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
    private var undoStack: [EQSettings] = []
    private var redoStack: [EQSettings] = []
    private var restoringForDevice = false
    private var lastSeenDeviceUID = ""

    /// Presets share the built-in list, so the selection is meaningful even
    /// before anything is saved.
    var selectedPreset: EQPreset? { presets.preset(id: selectedPresetID) }

    /// True once the live curve has drifted from the preset it came from.
    var isModified: Bool {
        guard let preset = selectedPreset else { return true }
        return preset.settings != live
    }

    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }

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

    /// `beginGesture` is what makes undo useful: one drag is one undo step,
    /// not one per frame.
    func beginGesture() {
        undoStack.append(live)
        if undoStack.count > 50 { undoStack.removeFirst() }
        redoStack.removeAll()
    }

    func setBandGain(_ index: Int, dB: Double, isGesture: Bool = false) {
        guard index >= 0, index < EQBands.count else { return }
        if !isGesture { beginGesture() }
        var settings = live
        settings.bandGainsDB[index] = EQBands.clamp(dB)
        commit(settings)
    }

    func setPreampDB(_ value: Double) {
        beginGesture()
        var settings = live
        settings.preampDB = min(max(value, -24), 12)
        commit(settings)
    }

    func setAutoHeadroom(_ value: Bool) {
        beginGesture()
        var settings = live
        settings.autoHeadroom = value
        commit(settings)
    }

    func resetBands() {
        select(preset: EQPreset.flatPreset)
    }

    func select(preset: EQPreset) {
        beginGesture()
        selectedPresetID = preset.id
        commit(preset.settings)
        persist { $0.selectedPresetID = preset.id }
        rememberPresetForCurrentDevice()
    }

    func undo() {
        guard let previous = undoStack.popLast() else { return }
        redoStack.append(live)
        commit(previous)
    }

    func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(live)
        commit(next)
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
        presets.removeAllUserPresets()
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
            commit(deviceState.live)
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
        commit(preset.settings)
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
        undoStack.removeAll()
        redoStack.removeAll()
        session.apply(settings: live)
        session.retry()
    }

    func retryAudio() { session.retry() }

    private func persist(_ mutate: @escaping (inout AppSettings) -> Void) {
        store.update(mutate)
    }
}
