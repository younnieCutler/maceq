import SwiftUI

struct HomeView: View {
    @EnvironmentObject private var state: AppState
    @State private var showSavePreset = false
    @State private var newPresetName = ""
    @State private var presetToRename: EQPreset?
    @State private var renamedPreset = ""
    @State private var preampText = ""
    @FocusState private var preampFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            StatusBanner()
                .padding(.horizontal, 24)

            HStack(spacing: 12) {
                CurveEditorView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                StereoOutputMeter()
                    .frame(width: 28)
            }
            .padding(.horizontal, 24)
            .padding(.top, 12)
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            equalizerFooter
            bottomBar
        }
        .background(.background)
        .frame(minWidth: 720, minHeight: 520)
        .toolbar { toolbarContent }
        .onAppear { preampText = format(state.live.preampDB) }
        .onChange(of: state.live.preampDB) { _, value in
            if !preampFocused { preampText = format(value) }
        }
        .onChange(of: preampFocused) { _, focused in
            if !focused { commitPreamp() }
        }
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

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            HStack(spacing: 16) {
                deviceMenu
                Divider().frame(height: 16)
                presetMenu
            }
        }

        ToolbarItem(placement: .primaryAction) {
            HStack(spacing: 8) {
                Text("EQ")
                    .font(.callout.weight(.medium))
                Toggle("", isOn: $state.eqEnabled)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
            }
            .accessibilityLabel(L("home.eq.accessibilityLabel"))
            .accessibilityValue(state.eqEnabled ? L("common.on") : L("common.off"))
        }
    }

    private var deviceMenu: some View {
        Menu {
            deviceChoice(L("settings.audio.followSystem"), selected: state.preferredDeviceUID == nil) {
                state.preferredDeviceUID = nil
            }

            if !state.availableOutputs.isEmpty {
                Divider()
                ForEach(state.availableOutputs, id: \.uid) { device in
                    deviceChoice(device.name, selected: state.preferredDeviceUID == device.uid) {
                        state.preferredDeviceUID = device.uid
                    }
                }
            }
        } label: {
            HStack(spacing: 6) {
                Text(state.status.deviceName)
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.caption2)
            }
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .accessibilityLabel(L("settings.audio.outputDevice"))
        .accessibilityValue(state.status.deviceName)
    }

    @ViewBuilder
    private func deviceChoice(_ name: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            if selected {
                Label(name, systemImage: "checkmark")
            } else {
                Text(name)
            }
        }
    }

    private var presetMenu: some View {
        Menu {
            Section(L("home.presets.builtIn")) {
                ForEach(EQPreset.builtIns) { preset in
                    presetChoice(preset)
                }
            }

            if !state.presets.userPresets.isEmpty {
                Section(L("home.presets.user")) {
                    ForEach(state.presets.userPresets) { preset in
                        Menu {
                            presetChoice(preset)
                            Divider()
                            Button(L("home.renamePreset")) {
                                presetToRename = preset
                                renamedPreset = preset.name
                            }
                            Button(L("common.duplicate")) { state.duplicate(preset) }
                            Button(L("common.delete"), role: .destructive) { state.delete(preset) }
                        } label: {
                            menuSelectionLabel(preset.name, selected: preset.id == state.selectedPresetID)
                        }
                    }
                }
            }

            if state.isModified {
                Divider()
                Button(L("home.saveCurve")) { showSavePreset = true }
                if let preset = state.selectedPreset, !preset.isBuiltIn {
                    Button(L("home.updatePreset", preset.name)) { state.updateSelectedPreset() }
                }
            }
        } label: {
            HStack(spacing: 6) {
                Text(state.selectedPreset?.name ?? "—")
                    .lineLimit(1)
                if state.isModified {
                    Text("•")
                        .foregroundStyle(.secondary)
                }
                Image(systemName: "chevron.down")
                    .font(.caption2)
            }
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .accessibilityLabel(L("home.section.sound"))
        .accessibilityValue(state.selectedPreset?.name ?? "—")
    }

    @ViewBuilder
    private func presetChoice(_ preset: EQPreset) -> some View {
        Button { state.select(preset: preset) } label: {
            menuSelectionLabel(preset.name, selected: preset.id == state.selectedPresetID)
        }
    }

    @ViewBuilder
    private func menuSelectionLabel(_ name: String, selected: Bool) -> some View {
        if selected {
            Label(name, systemImage: "checkmark")
        } else {
            Text(name)
        }
    }

    private var equalizerFooter: some View {
        HStack(spacing: 16) {
            Text(L("home.eq.scale"))
                .font(.caption)
                .foregroundStyle(.secondary)

            Spacer()

            Toggle(L("home.bandMode.twenty"), isOn: $state.showTwentyBands)
                .toggleStyle(.switch)
                .controlSize(.small)

            Button(L("common.reset")) { state.resetBands() }
                .buttonStyle(.link)
                .disabled(state.live.isFlat)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 10)
    }

    private var bottomBar: some View {
        HStack(spacing: 16) {
            preampControl

            Spacer(minLength: 24)

            Toggle(L("home.autoGain.title"), isOn: Binding(
                get: { state.live.autoHeadroom },
                set: { state.setAutoHeadroom($0) }
            ))
            .toggleStyle(.switch)
            .controlSize(.small)

            Toggle(L("home.limiter.title"), isOn: $state.limiterEnabled)
                .toggleStyle(.switch)
                .controlSize(.small)
        }
        .padding(.horizontal, 24)
        .frame(height: 56)
        .overlay(alignment: .top) { Divider() }
    }

    private var preampControl: some View {
        HStack(spacing: 8) {
            Text(L("home.preamp.label"))
                .font(.callout)
                .foregroundStyle(.secondary)

            TextField(L("home.preamp.field"), text: $preampText)
                .textFieldStyle(.plain)
                .font(.body.monospacedDigit())
                .multilineTextAlignment(.trailing)
                .frame(width: 58)
                .focused($preampFocused)
                .onSubmit {
                    commitPreamp()
                    preampFocused = false
                }

            Text("dB")
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(L("home.preamp.label"))
        .accessibilityValue(EQBands.spokenGain(state.live.preampDB))
    }

    private func commitPreamp() {
        let normalized = preampText.replacingOccurrences(of: ",", with: ".")
        guard let value = Double(normalized) else {
            preampText = format(state.live.preampDB)
            return
        }
        state.setPreampDB(value)
        preampText = format(min(max(value, -24), 12))
    }

    private func format(_ value: Double) -> String {
        String(format: "%+.1f", value)
    }
}

/// One compact status row for failures that need user action. It deliberately
/// does not compete with the EQ surface as a card or modal.
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
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: icon)
                .foregroundStyle(.orange)
            Text(title)
                .font(.callout.weight(.medium))
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 8)
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .controlSize(.small)
            }
        }
        .padding(.vertical, 8)
        .overlay(alignment: .bottom) { Divider() }
        .accessibilityElement(children: .contain)
    }
}

struct StereoOutputMeter: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        VStack(spacing: 4) {
            Text("L")
            meter
            Text("R")
        }
        .font(.caption2.monospaced())
        .foregroundStyle(.secondary)
        .frame(maxHeight: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(L("home.outputMeter"))
        .accessibilityValue(levelDescription)
    }

    private var meter: some View {
        GeometryReader { geometry in
            let height = max(geometry.size.height, 1)
            let levelHeight = height * normalizedLevel
            ZStack(alignment: .bottom) {
                Rectangle()
                    .fill(.secondary.opacity(0.18))
                    .frame(width: 2)
                Rectangle()
                    .fill(isClipping ? Color.red : Color.primary.opacity(0.6))
                    .frame(width: 3, height: max(levelHeight, normalizedLevel > 0 ? 1 : 0))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: 12)
    }

    private var normalizedLevel: CGFloat {
        guard state.status.peakOutDB.isFinite else { return 0 }
        return CGFloat(min(max((state.status.peakOutDB + 60) / 60, 0), 1))
    }

    private var isClipping: Bool {
        state.status.peakOutDB.isFinite && state.status.peakOutDB >= -0.1
    }

    private var levelDescription: String {
        state.status.peakOutDB.isFinite
            ? String(format: "%.1f dBFS", state.status.peakOutDB)
            : L("diagnostics.silent")
    }
}
