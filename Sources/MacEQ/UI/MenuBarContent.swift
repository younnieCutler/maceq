import SwiftUI

/// The everyday interface. Everything here is one click from the menu bar.
struct MenuBarContent: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Toggle(L("menubar.equalizer"), isOn: $state.eqEnabled)

        deviceMenu
        presetMenu

        if case .needsPermission = state.status.state {
            Button(L("menubar.needsPermission")) { PermissionManager.openSystemSettings() }
        }

        Divider()

        Text(L("home.preamp.label") + "  " + String(format: "%+.1f dB", state.live.preampDB))
        Toggle(L("home.autoGain.title"), isOn: Binding(
            get: { state.live.autoHeadroom },
            set: { state.setAutoHeadroom($0) }
        ))
        Toggle(L("home.limiter.title"), isOn: $state.limiterEnabled)

        Divider()

        Button(L("menubar.open")) {
            NSApp.activate(ignoringOtherApps: true)
            openWindow(id: WindowID.main)
        }
        SettingsLink { Text(L("menubar.settings")) }
            .keyboardShortcut(",", modifiers: .command)
        Button(L("menubar.quit")) { NSApp.terminate(nil) }
            .keyboardShortcut("q", modifiers: .command)
    }

    private var deviceMenu: some View {
        Menu {
            Button {
                state.preferredDeviceUID = nil
            } label: {
                Text((state.preferredDeviceUID == nil ? "✓ " : "  ")
                    + L("settings.audio.followSystem"))
            }

            if !state.availableOutputs.isEmpty {
                Divider()
                ForEach(state.availableOutputs, id: \.uid) { device in
                    Button {
                        state.preferredDeviceUID = device.uid
                    } label: {
                        Text((state.preferredDeviceUID == device.uid ? "✓ " : "  ") + device.name)
                    }
                }
            }
        } label: {
            Text(state.status.deviceName)
        }
    }

    private var presetMenu: some View {
        Menu {
            Section(L("home.presets.builtIn")) {
                ForEach(EQPreset.builtIns) { preset in
                    presetButton(preset)
                }
            }
            if !state.presets.userPresets.isEmpty {
                Section(L("home.presets.user")) {
                    ForEach(state.presets.userPresets) { preset in
                        presetButton(preset)
                    }
                }
            }
        } label: {
            Text(L("menubar.preset") + "  " + (state.selectedPreset?.name ?? "—"))
        }
    }

    @ViewBuilder
    private func presetButton(_ preset: EQPreset) -> some View {
        Button { state.select(preset: preset) } label: {
            Text((preset.id == state.selectedPresetID ? "✓ " : "  ") + preset.name)
        }
    }
}
