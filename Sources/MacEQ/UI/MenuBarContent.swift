import SwiftUI

/// The everyday interface. Everything here is one click from the menu bar.
struct MenuBarContent: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Toggle(L("menubar.equalizer"), isOn: $state.eqEnabled)

        if !state.status.deviceName.isEmpty {
            Text(state.status.deviceName)
        }
        if case .needsPermission = state.status.state {
            Button(L("menubar.needsPermission")) { PermissionManager.openSystemSettings() }
        }

        Divider()

        ForEach(state.presets.quickPicks) { preset in
            Button {
                state.select(preset: preset)
            } label: {
                if preset.id == state.selectedPresetID {
                    Label(preset.name, systemImage: "checkmark")
                } else {
                    Text(preset.name)
                }
            }
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
}
