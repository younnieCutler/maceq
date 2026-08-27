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
            Text("Mac의 소리를\n원하는 대로.")
                .font(.system(size: 34, weight: .semibold))
            Text("20밴드 이퀄라이저를 모든 소리에 적용합니다.")
                .font(.title3)
                .foregroundStyle(.secondary)
        }
    }

    private var permission: some View {
        VStack(alignment: .leading, spacing: 16) {
            Image(systemName: "waveform")
                .font(.system(size: 40))
                .foregroundStyle(.tint)
            Text("시스템 오디오 접근")
                .font(.system(size: 28, weight: .semibold))
            Text("MacEQ는 소리를 처리할 뿐 녹음하거나 업로드하지 않습니다.\n오디오는 이 Mac을 벗어나지 않습니다.")
                .font(.title3)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if case .needsPermission = state.status.state {
                Button("시스템 설정 열기") { PermissionManager.openSystemSettings() }
                    .controlSize(.large)
            }
        }
    }

    private var pick: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("준비됐습니다.")
                .font(.system(size: 28, weight: .semibold))
            Text("먼저 들어볼 소리를 골라주세요.")
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
                Button("이전") { step -= 1 }
            }
            Spacer()
            Button(step < 2 ? "계속" : "시작하기") {
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
