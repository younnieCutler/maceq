import SwiftUI

/// The everyday interface. Everything here is one click from the menu bar.
struct MenuBarContent: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Toggle("이퀄라이저", isOn: $state.eqEnabled)

        if !state.status.deviceName.isEmpty {
            Text(state.status.deviceName)
        }
        if case .needsPermission = state.status.state {
            Button("시스템 오디오 권한 필요…") { PermissionManager.openSystemSettings() }
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

        Button("이퀄라이저 열기…") {
            NSApp.activate(ignoringOtherApps: true)
            openWindow(id: WindowID.main)
        }
        SettingsLink { Text("설정…") }
            .keyboardShortcut(",", modifiers: .command)
        Button("MacEQ 종료") { NSApp.terminate(nil) }
            .keyboardShortcut("q", modifiers: .command)
    }
}
