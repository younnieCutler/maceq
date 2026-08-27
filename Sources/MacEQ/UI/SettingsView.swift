import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettings().tabItem { Label(L("settings.tab.general"), systemImage: "gearshape") }
            AudioSettings().tabItem { Label(L("settings.tab.audio"), systemImage: "hifispeaker") }
            EqualizerSettings().tabItem { Label(L("settings.tab.equalizer"), systemImage: "slider.horizontal.3") }
            AdvancedSettings().tabItem { Label(L("settings.tab.advanced"), systemImage: "wrench.and.screwdriver") }
            AboutSettings().tabItem { Label(L("settings.tab.about"), systemImage: "info.circle") }
        }
        .frame(width: 480, height: 380)
    }
}

private struct GeneralSettings: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        Form {
            Toggle(L("settings.general.launchAtLogin"), isOn: Binding(
                get: { if case .enabled = state.loginItemStatus { return true } else { return false } },
                set: { state.setLaunchAtLogin($0) }))

            if case .blockedByUser = state.loginItemStatus {
                // Registration can be refused, and hiding that would leave the
                // toggle silently doing nothing.
                VStack(alignment: .leading, spacing: 6) {
                    Text(L("settings.general.loginBlocked"))
                        .font(.caption)
                    Button(L("settings.general.loginBlocked.action")) { LoginItemManager.openLoginItemsSettings() }
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
        .formStyle(.grouped)
    }
}

private struct AudioSettings: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        Form {
            Picker(L("settings.audio.outputDevice"), selection: Binding(get: { state.preferredDeviceUID ?? "" },
                                                set: { state.preferredDeviceUID = $0.isEmpty ? nil : $0 })) {
                Text(L("settings.audio.followSystem")).tag("")
                ForEach(state.availableOutputs, id: \.uid) { device in
                    Text(device.name).tag(device.uid)
                }
            }
            Button(L("settings.audio.refreshDevices")) { state.refreshDevices() }
                .buttonStyle(.link)

            Toggle(L("settings.audio.autoHeadroom"), isOn: Binding(get: { state.live.autoHeadroom },
                                            set: { state.setAutoHeadroom($0) }))
            Toggle(L("settings.audio.safetyLimiter"), isOn: $state.limiterEnabled)

            LabeledContent(L("settings.audio.engine")) { Text(engineDescription) }
        }
        .formStyle(.grouped)
        .onAppear { state.refreshDevices() }
    }

    private var engineDescription: String {
        guard state.status.sampleRate > 0 else { return L("settings.audio.engine.stopped") }
        return L("settings.audio.engine.running",
                 Int(state.status.sampleRate), state.status.channels, Int(state.status.bufferFrames))
    }
}

private struct EqualizerSettings: View {
    @EnvironmentObject private var state: AppState
    @State private var message: String?

    var body: some View {
        Form {
            Picker(L("settings.eq.defaultPreset"), selection: Binding(get: { state.selectedPresetID },
                                                set: { id in
                if let preset = state.presets.preset(id: id) { state.select(preset: preset) }
            })) {
                ForEach(state.presets.all) { preset in
                    Text(preset.name).tag(preset.id)
                }
            }

            HStack {
                Button(L("common.export")) { export() }
                Button(L("common.import")) { performImport() }
                Spacer()
                Button(L("settings.eq.resetUserPresets"), role: .destructive) { state.resetPresets() }
            }

            if let message {
                Text(message).font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
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

private struct AdvancedSettings: View {
    @EnvironmentObject private var state: AppState
    @State private var confirmReset = false

    var body: some View {
        Form {
            Section(L("settings.advanced.diagnostics")) {
                DiagnosticsView()
            }
            Section {
                Button(L("settings.advanced.restartEngine")) { state.retryAudio() }
                Button(L("settings.advanced.resetEverything"), role: .destructive) { confirmReset = true }
            }
        }
        .formStyle(.grouped)
        .alert(L("settings.advanced.resetConfirm.title"), isPresented: $confirmReset) {
            Button(L("common.reset"), role: .destructive) { state.resetEverything() }
            Button(L("common.cancel"), role: .cancel) {}
        } message: {
            Text(L("settings.advanced.resetConfirm.message"))
        }
    }
}

private struct AboutSettings: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        Form {
            LabeledContent(L("settings.about.version")) { Text("\(AppInfo.version) (\(AppInfo.build))") }
            HStack {
                Button(L("settings.about.checkUpdates")) { state.updates.check() }
                Text(updateDescription).font(.caption).foregroundStyle(.secondary)
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
        .formStyle(.grouped)
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
}
