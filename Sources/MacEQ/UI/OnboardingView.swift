import SwiftUI

/// Three steps, no account. Permission is explained before macOS asks, so the
/// system prompt is not the first thing the user sees.
struct OnboardingView: View {
    @EnvironmentObject private var state: AppState
    @State private var step = 0
    @State private var chosen = EQPreset.defaultPreset.id

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            Spacer()
            switch step {
            case 0: welcome
            case 1: permission
            default: pick
            }
            Spacer()
            footer
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(L("onboarding.welcome.title"))
                .font(.system(size: 34, weight: .semibold))
            Text(L("onboarding.welcome.subtitle"))
                .font(.title3)
                .foregroundStyle(.secondary)
        }
    }

    private var permission: some View {
        VStack(alignment: .leading, spacing: 16) {
            Image(systemName: "waveform")
                .font(.system(size: 40))
                .foregroundStyle(.tint)
            Text(L("onboarding.permission.title"))
                .font(.system(size: 28, weight: .semibold))
            Text(L("onboarding.permission.body"))
                .font(.title3)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if case .needsPermission = state.status.state {
                Button(L("status.openSettings")) { PermissionManager.openSystemSettings() }
                    .controlSize(.large)
            }
        }
    }

    private var pick: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(L("onboarding.pick.title"))
                .font(.system(size: 28, weight: .semibold))
            Text(L("onboarding.pick.subtitle"))
                .foregroundStyle(.secondary)
            Picker("", selection: $chosen) {
                ForEach(EQPreset.builtIns.prefix(4)) { preset in
                    Text(preset.name).tag(preset.id)
                }
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()
        }
    }

    private var footer: some View {
        HStack {
            if step > 0 {
                Button(L("common.back")) { step -= 1 }
            }
            Spacer()
            Button(step < 2 ? L("common.continue") : L("onboarding.start")) {
                if step < 2 {
                    step += 1
                } else {
                    if let preset = state.presets.preset(id: chosen) {
                        state.select(preset: preset)
                    }
                    state.completeOnboarding()
                }
            }
            .keyboardShortcut(.defaultAction)
            .controlSize(.large)
        }
    }
}
