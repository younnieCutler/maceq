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
        .alert(L("home.savePreset.title"), isPresented: $showSavePreset) {
            TextField(L("home.savePreset.field"), text: $newPresetName)
            Button(L("common.save")) {
                let name = newPresetName.trimmingCharacters(in: .whitespacesAndNewlines)
                state.saveAsPreset(named: name.isEmpty ? L("home.savePreset.defaultName") : name)
                newPresetName = ""
            }
            Button(L("common.cancel"), role: .cancel) { newPresetName = "" }
        } message: {
            Text(L("home.savePreset.message"))
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("MacEQ")
                .font(.largeTitle.weight(.semibold))
            Spacer()
            Toggle(L("home.eq.accessibilityLabel"), isOn: $state.eqEnabled)
                .toggleStyle(.switch)
                .labelsHidden()
                .accessibilityLabel(L("home.eq.accessibilityLabel"))
                .accessibilityValue(state.eqEnabled ? L("common.on") : L("common.off"))
            Text(state.eqEnabled ? L("common.on") : L("common.off"))
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
        guard state.status.sampleRate > 0 else { return L("home.device.waiting") }
        let rate = String(format: "%.4g kHz", state.status.sampleRate / 1_000)
        return L("home.device.connected", rate)
    }

    private var soundSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle(L("home.section.sound"))
            PresetChips()
            HStack(spacing: 12) {
                Button(L("home.saveCurve")) { showSavePreset = true }
                if let preset = state.selectedPreset, !preset.isBuiltIn, state.isModified {
                    Button(L("home.updatePreset", preset.name)) { state.updateSelectedPreset() }
                }
                Spacer()
                if state.isModified {
                    Text(L("home.modified"))
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
                sectionTitle(L("home.section.equalizer"))
                Spacer()
                Button(L("common.reset")) { state.resetBands() }
                    .buttonStyle(.link)
                    .disabled(state.live.isFlat)
            }
            CurveEditorView()
            HStack {
                Text("32 Hz").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button(L("home.editBands")) { showBands = true }
                Spacer()
                Text("20 kHz").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var preampSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            sectionTitle(L("home.section.preamp"))
            HStack {
                Text(state.live.autoHeadroom ? L("home.preamp.auto") : L("home.preamp.manual"))
                    .foregroundStyle(.secondary)
                Slider(value: Binding(get: { state.live.preampDB },
                                      set: { state.setPreampDB($0) }),
                       in: -24...12, step: 0.5)
                    .accessibilityLabel(L("home.section.preamp"))
                    .accessibilityValue(EQBands.spokenGain(state.live.preampDB))
                Text(String(format: "%+.1f dB", state.status.effectivePreampDB))
                    .font(.body.monospacedDigit())
                    .frame(width: 72, alignment: .trailing)
            }

            Toggle(isOn: Binding(get: { state.live.autoHeadroom },
                                 set: { state.setAutoHeadroom($0) })) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(L("home.autoHeadroom.title"))
                    Text(state.live.autoHeadroom
                         ? L("home.autoHeadroom.on", state.status.requiredHeadroomDB)
                         : L("home.autoHeadroom.off"))
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
                        .padding(.vertical, 8)
                }
                .buttonStyle(.bordered)
                .tint(preset.id == state.selectedPresetID ? .macEQAccent : .secondary)
                .accessibilityAddTraits(preset.id == state.selectedPresetID ? .isSelected : [])
                .contextMenu {
                    Button(L("common.duplicate")) { state.duplicate(preset) }
                    if !preset.isBuiltIn {
                        Button(L("common.delete"), role: .destructive) { state.delete(preset) }
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
                   title: L("status.needsPermission.title"),
                   message: L("status.needsPermission.message"),
                   actionTitle: L("status.openSettings")) {
                PermissionManager.openSystemSettings()
            }
        case .failed(let reason):
            banner(icon: "exclamationmark.triangle",
                   title: L("status.failed.title"),
                   message: reason,
                   actionTitle: L("status.retry")) {
                state.retryAudio()
            }
        case .recovering(let attempt):
            banner(icon: "arrow.clockwise",
                   title: L("status.recovering.title"),
                   message: L("status.recovering.message", attempt),
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
        .padding(16)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .combine)
    }
}
