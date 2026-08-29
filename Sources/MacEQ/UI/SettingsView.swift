import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @EnvironmentObject private var state: AppState
    @State private var message: String?
    @State private var confirmReset = false

    var body: some View {
        Form {
            Section { generalSettings } header: { sectionHeader(L("settings.tab.general")) }
            Section { audioSettings } header: { sectionHeader(L("settings.tab.audio")) }
            Section { equalizerSettings } header: { sectionHeader(L("settings.tab.equalizer")) }
            Section { appearanceSettings } header: { sectionHeader(L("settings.section.appearance")) }
            Section { advancedSettings } header: { sectionHeader(L("settings.tab.advanced")) }
            Section { aboutSettings } header: { sectionHeader(L("settings.tab.about")) }
        }
        .formStyle(.grouped)
        .frame(width: 560, height: 620)
        .preferredColorScheme(state.appearance.colorScheme)
        .onAppear {
            state.refreshDevices()
            DispatchQueue.main.async { recenterIfOffScreen(NSApp.keyWindow) }
        }
        .alert(L("settings.advanced.resetConfirm.title"), isPresented: $confirmReset) {
            Button(L("common.reset"), role: .destructive) { state.resetEverything() }
            Button(L("common.cancel"), role: .cancel) {}
        } message: {
            Text(L("settings.advanced.resetConfirm.message"))
        }
    }

    private var generalSettings: some View {
        Group {
            Toggle(L("settings.general.launchAtLogin"), isOn: Binding(
                get: { if case .enabled = state.loginItemStatus { return true } else { return false } },
                set: { state.setLaunchAtLogin($0) }
            ))

            if case .blockedByUser = state.loginItemStatus {
                VStack(alignment: .leading, spacing: 8) {
                    Text(L("settings.general.loginBlocked"))
                        .font(.caption)
                    Button(L("settings.general.loginBlocked.action")) {
                        LoginItemManager.openLoginItemsSettings()
                    }
                    .buttonStyle(.link)
                }
            }

            if case .unavailable(let reason) = state.loginItemStatus {
                Text(L("settings.general.loginFailed", reason))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Toggle(L("settings.general.startEnabled"), isOn: $state.startEQEnabled)
            Toggle(L("settings.general.menuBarIcon"), isOn: $state.showMenuBarIcon)
            Toggle(L("settings.general.dockIcon"), isOn: $state.showDockIcon)
        }
    }

    private var audioSettings: some View {
        Group {
            Picker(L("settings.audio.outputDevice"), selection: Binding(
                get: { state.preferredDeviceUID ?? "" },
                set: { state.preferredDeviceUID = $0.isEmpty ? nil : $0 }
            )) {
                Text(L("settings.audio.followSystem")).tag("")
                ForEach(state.availableOutputs, id: \.uid) { device in
                    Text(device.name).tag(device.uid)
                }
            }

            Button(L("settings.audio.refreshDevices")) { state.refreshDevices() }
                .buttonStyle(.link)

            Toggle(L("settings.audio.autoHeadroom"), isOn: Binding(
                get: { state.live.autoHeadroom },
                set: { state.setAutoHeadroom($0) }
            ))
            Toggle(L("settings.audio.safetyLimiter"), isOn: $state.limiterEnabled)
            Toggle(L("settings.audio.spectrumAnalyzer"), isOn: $state.spectrumEnabled)

            LabeledContent(L("settings.audio.engine")) { Text(engineDescription) }
        }
    }

    private var equalizerSettings: some View {
        Group {
            LabeledContent(L("settings.eq.currentPreset")) {
                Text(state.selectedPreset?.name ?? "—")
            }
            if state.isModified {
                Label(L("settings.eq.modified"), systemImage: "slider.horizontal.3")
                    .foregroundStyle(.secondary)
            }
            if state.live.autoHeadroom {
                LabeledContent(L("settings.eq.effectivePreamp")) {
                    Text(String(format: "%+.1f dB", state.status.effectivePreampDB))
                        .monospacedDigit()
                }
            }

            Toggle(L("home.bandMode.twenty"), isOn: $state.showTwentyBands)

            Picker(L("settings.eq.choosePreset"), selection: Binding(
                get: { state.selectedPresetID },
                set: { id in
                    if let preset = state.presets.preset(id: id) { state.select(preset: preset) }
                }
            )) {
                Section(L("settings.eq.builtIns")) {
                    ForEach(EQPreset.builtIns) { preset in
                        Text(preset.name).tag(preset.id)
                    }
                }
                if !state.presets.userPresets.isEmpty {
                    Section(L("settings.eq.userPresets")) {
                        ForEach(state.presets.userPresets) { preset in
                            Text(preset.name).tag(preset.id)
                        }
                    }
                }
            }

            HStack {
                Button(L("common.export")) { export() }
                Button(L("common.import")) { performImport() }
                Spacer()
                Button(L("settings.eq.resetUserPresets"), role: .destructive) {
                    state.resetPresets()
                }
            }

            if let message {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var appearanceSettings: some View {
        Picker(L("settings.appearance.label"), selection: $state.appearance) {
            ForEach(AppearanceMode.allCases) { mode in
                Text(mode.label).tag(mode)
            }
        }
    }

    private var advancedSettings: some View {
        Group {
            DiagnosticsView()
            Button(L("settings.advanced.restartEngine")) { state.retryAudio() }
            Button(L("settings.advanced.resetEverything")) { confirmReset = true }
        }
    }

    private var aboutSettings: some View {
        Group {
            LabeledContent(L("settings.about.version")) {
                Text("\(AppInfo.version) (\(AppInfo.build))")
            }
            HStack {
                Button(L("settings.about.checkUpdates")) { state.updates.check() }
                Text(updateDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                if case .available = state.updates.state {
                    Button(L("settings.about.viewRelease")) { state.updates.openReleasePage() }
                }
            }
            Link("GitHub", destination: AppInfo.repositoryURL)
            Text(L("settings.about.privacy"))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
    }

    private var engineDescription: String {
        guard state.status.sampleRate > 0 else { return L("settings.audio.engine.stopped") }
        return L("settings.audio.engine.running",
                 Int(state.status.sampleRate), state.status.channels, Int(state.status.bufferFrames))
    }

    private var updateDescription: String {
        switch state.updates.state {
        case .idle: return ""
        case .checking: return L("settings.about.checking")
        case .upToDate: return L("settings.about.upToDate")
        case .available(let version, _): return L("settings.about.available", version)
        case .failed(let reason): return L("settings.about.checkFailed", reason)
        }
    }

    private func export() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "MacEQ Presets.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try state.exportPresets(to: url)
            message = L("settings.eq.exported", state.presets.userPresets.count)
        } catch {
            message = L("settings.eq.exportFailed", error.localizedDescription)
        }
    }

    private func performImport() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let count = try state.importPresets(from: url)
            message = L("settings.eq.imported", count)
        } catch {
            message = L("settings.eq.importFailed")
        }
    }
}
