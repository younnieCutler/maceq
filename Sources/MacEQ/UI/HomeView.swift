import SwiftUI

struct HomeView: View {
    @EnvironmentObject private var state: AppState
    @State private var showBands = false
    @State private var showSavePreset = false
    @State private var newPresetName = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                header
                StatusBanner()
                deviceCard
                soundSection
                equalizerSection
                preampSection
            }
            .padding(28)
        }
        .background(.background)
        .sheet(isPresented: $showBands) { BandsView() }
        .alert("프리셋 저장", isPresented: $showSavePreset) {
            TextField("이름", text: $newPresetName)
            Button("저장") {
                let name = newPresetName.trimmingCharacters(in: .whitespacesAndNewlines)
                state.saveAsPreset(named: name.isEmpty ? "내 프리셋" : name)
                newPresetName = ""
            }
            Button("취소", role: .cancel) { newPresetName = "" }
        } message: {
            Text("현재 곡선을 새 프리셋으로 저장합니다.")
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("MacEQ")
                .font(.largeTitle.weight(.semibold))
            Spacer()
            Toggle("이퀄라이저 켜기", isOn: $state.eqEnabled)
                .toggleStyle(.switch)
                .labelsHidden()
                .accessibilityLabel("이퀄라이저")
                .accessibilityValue(state.eqEnabled ? "켜짐" : "꺼짐")
            Text(state.eqEnabled ? "켜짐" : "꺼짐")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .frame(width: 36, alignment: .leading)
        }
    }

    private var deviceCard: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(state.status.deviceName)
                .font(.title3.weight(.medium))
            Text(deviceSubtitle)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }

    private var deviceSubtitle: String {
        guard state.status.sampleRate > 0 else { return "연결 대기 중" }
        let rate = String(format: "%.4g kHz", state.status.sampleRate / 1_000)
        return "연결됨 · \(rate)"
    }

    private var soundSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("사운드")
            PresetChips()
            HStack(spacing: 12) {
                Button("현재 곡선 저장…") { showSavePreset = true }
                if let preset = state.selectedPreset, !preset.isBuiltIn, state.isModified {
                    Button("‘\(preset.name)’ 업데이트") { state.updateSelectedPreset() }
                }
                Spacer()
                if state.isModified {
                    Text("수정됨")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.link)
        }
    }

    private var equalizerSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                sectionTitle("이퀄라이저")
                Spacer()
                Button("초기화") { state.resetBands() }
                    .buttonStyle(.link)
                    .disabled(state.live.isFlat)
            }
            CurveEditorView()
            HStack {
                Text("32 Hz").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("20밴드 편집") { showBands = true }
                Spacer()
                Text("20 kHz").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var preampSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            sectionTitle("프리앰프")
            HStack {
                Text(state.live.autoHeadroom ? "자동" : "수동")
                    .foregroundStyle(.secondary)
                Slider(value: Binding(get: { state.live.preampDB },
                                      set: { state.setPreampDB($0) }),
                       in: -24...12, step: 0.5)
                    .accessibilityLabel("프리앰프")
                    .accessibilityValue(EQBands.spokenGain(state.live.preampDB))
                Text(String(format: "%+.1f dB", state.status.effectivePreampDB))
                    .font(.body.monospacedDigit())
                    .frame(width: 72, alignment: .trailing)
            }

            Toggle(isOn: Binding(get: { state.live.autoHeadroom },
                                 set: { state.setAutoHeadroom($0) })) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("자동 헤드룸")
                    Text(state.live.autoHeadroom
                         ? "클리핑을 자동으로 방지합니다. 현재 \(String(format: "%.1f", state.status.requiredHeadroomDB)) dB 확보 중."
                         : "부스트가 클수록 소리가 깨질 수 있습니다.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .toggleStyle(.switch)
        }
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text)
            .font(.headline)
            .foregroundStyle(.secondary)
    }
}

struct PresetChips: View {
    @EnvironmentObject private var state: AppState

    private let columns = [GridItem(.adaptive(minimum: 96), spacing: 8)]

    var body: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: 8) {
            ForEach(state.presets.all) { preset in
                Button {
                    state.select(preset: preset)
                } label: {
                    Text(preset.name)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 7)
                }
                .buttonStyle(.bordered)
                .tint(preset.id == state.selectedPresetID ? .accentColor : .secondary)
                .accessibilityAddTraits(preset.id == state.selectedPresetID ? .isSelected : [])
                .contextMenu {
                    Button("복제") { state.duplicate(preset) }
                    if !preset.isBuiltIn {
                        Button("삭제", role: .destructive) { state.delete(preset) }
                    }
                }
            }
        }
    }
}

/// One place for everything that needs the user to act: no permission, a
/// failed pipeline, or a blocked login item.
struct StatusBanner: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        switch state.status.state {
        case .needsPermission:
            banner(icon: "waveform.badge.exclamationmark",
                   title: "시스템 오디오 접근이 꺼져 있습니다",
                   message: "MacEQ가 소리를 조절하려면 권한이 필요합니다.",
                   actionTitle: "설정 열기") {
                PermissionManager.openSystemSettings()
            }
        case .failed(let reason):
            banner(icon: "exclamationmark.triangle",
                   title: "오디오 연결을 복구하지 못했습니다",
                   message: reason,
                   actionTitle: "다시 연결") {
                state.retryAudio()
            }
        case .recovering(let attempt):
            banner(icon: "arrow.clockwise",
                   title: "오디오를 다시 연결하는 중",
                   message: "\(attempt)번째 시도",
                   actionTitle: nil, action: nil)
        default:
            EmptyView()
        }
    }

    @ViewBuilder
    private func banner(icon: String, title: String, message: String,
                        actionTitle: String?, action: (() -> Void)?) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.callout.weight(.medium))
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            if let actionTitle, let action {
                Button(actionTitle, action: action)
            }
        }
        .padding(14)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
        .accessibilityElement(children: .combine)
    }
}
