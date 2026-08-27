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
            HStack(alignment: .firstTextBaseline) {
                sectionTitle(L("home.section.sound"))
                Spacer()
                if let preset = state.selectedPreset {
                    Label(state.isModified ? L("home.modified") : L("home.sound.active", preset.name),
                          systemImage: state.isModified ? "slider.horizontal.3" : "checkmark.circle.fill")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(state.isModified ? Color.secondary : Color.macEQAccent)
                }
            }
            PresetChips()
            if state.isModified {
                HStack(spacing: 12) {
                    Button(L("home.saveCurve")) { showSavePreset = true }
                    if let preset = state.selectedPreset, !preset.isBuiltIn {
                        Button(L("home.updatePreset", preset.name)) { state.updateSelectedPreset() }
                    }
                    Spacer()
                }
                .buttonStyle(.link)
            }
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
                Text(EQBands.label(0)).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button(L("home.editBands")) { showBands = true }
                Spacer()
                Text(EQBands.label(EQBands.count - 1)).font(.caption).foregroundStyle(.secondary)
            }
            if state.live.autoHeadroom {
                let peak = max(state.status.requiredHeadroomDB - Headroom.safetyMarginDB, 0)
                Text(L("home.headroom.summary", peak, Headroom.safetyMarginDB, state.status.effectivePreampDB))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
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
    @State private var presetToRename: EQPreset?
    @State private var renamedPreset = ""

    private let columns = [GridItem(.adaptive(minimum: 112), spacing: 8)]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            LazyVGrid(columns: columns, alignment: .leading, spacing: 8) {
                ForEach(EQPreset.builtIns) { preset in
                    presetButton(preset, isUserPreset: false)
                }
            }

            if !state.presets.userPresets.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text(L("home.userPresets"))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    LazyVGrid(columns: columns, alignment: .leading, spacing: 8) {
                        ForEach(state.presets.userPresets) { preset in
                            HStack(spacing: 4) {
                                presetButton(preset, isUserPreset: true)
                                Menu {
                                    Button(L("common.duplicate")) { state.duplicate(preset) }
                                    Button(L("home.renamePreset")) {
                                        presetToRename = preset
                                        renamedPreset = preset.name
                                    }
                                    Button(L("common.delete"), role: .destructive) { state.delete(preset) }
                                } label: {
                                    Image(systemName: "ellipsis.circle")
                                        .frame(width: 28, height: 44)
                                }
                                .menuStyle(.borderlessButton)
                                .accessibilityLabel(L("home.userPreset.actions", preset.name))
                            }
                        }
                    }
                }
            }
        }
        .alert(L("home.renamePreset.title"), isPresented: Binding(
            get: { presetToRename != nil },
            set: { if !$0 { presetToRename = nil } }
        )) {
            TextField(L("home.renamePreset.field"), text: $renamedPreset)
            Button(L("common.save")) {
                if let presetToRename { state.rename(presetToRename, to: renamedPreset) }
                presetToRename = nil
            }
            Button(L("common.cancel"), role: .cancel) { presetToRename = nil }
        } message: {
            Text(L("home.renamePreset.message"))
        }
    }

    private func presetButton(_ preset: EQPreset, isUserPreset: Bool) -> some View {
        let selected = preset.id == state.selectedPresetID
        return Button { state.select(preset: preset) } label: {
            HStack(spacing: 6) {
                Image(systemName: selected ? "checkmark.circle.fill" : (isUserPreset ? "person.crop.circle" : "waveform"))
                    .imageScale(.small)
                Text(preset.name).lineLimit(1)
                Spacer(minLength: 0)
            }
            .font(.callout.weight(selected ? .semibold : .regular))
            .foregroundStyle(selected ? Color.macEQAccent : Color.primary)
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, minHeight: 44)
            .background {
                if selected {
                    RoundedRectangle(cornerRadius: 10).fill(Color.macEQAccent.opacity(0.16))
                } else {
                    RoundedRectangle(cornerRadius: 10).fill(.quaternary.opacity(0.35))
                }
            }
            .overlay {
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(selected ? Color.macEQAccent.opacity(0.45) : .clear)
            }
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
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
