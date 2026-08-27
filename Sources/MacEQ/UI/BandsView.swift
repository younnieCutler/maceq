import SwiftUI

/// The full 20-band view, deliberately behind a button rather than on Home.
/// Sliders are rotated `Slider`s so keyboard focus, Full Keyboard Access and
/// VoiceOver adjustment all keep working.
struct BandsView: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 20) {
            HStack {
                Text(L("bands.title")).font(.title2.weight(.semibold))
                Spacer()
                Button(L("bands.resetAll")) { state.resetBands() }
                    .disabled(state.live.isFlat)
                Button(L("common.done")) { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }

            HStack(alignment: .bottom, spacing: 2) {
                ForEach(0..<EQBands.count, id: \.self) { index in
                    bandColumn(index)
                }
            }
            .frame(height: 300)

            Text(L("bands.hint"))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(24)
        .frame(width: 720, height: 440)
    }

    private func bandColumn(_ index: Int) -> some View {
        VStack(spacing: 6) {
            Text(String(format: "%+.1f", state.live.bandGainsDB[index]))
                .font(.caption2.monospacedDigit())
                .foregroundStyle(abs(state.live.bandGainsDB[index]) < 0.05 ? .secondary : .primary)
                .onTapGesture(count: 2) { state.setBandGain(index, dB: 0) }

            Slider(value: Binding(get: { state.live.bandGainsDB[index] },
                                  set: { state.setBandGain(index, dB: $0) }),
                   in: EQBands.minGainDB...EQBands.maxGainDB,
                   step: 0.5)
                .rotationEffect(.degrees(-90))
                .frame(width: 210)
                .frame(width: 28, height: 210)
                .accessibilityLabel(EQBands.spokenLabel(index))
                .accessibilityValue(EQBands.spokenGain(state.live.bandGainsDB[index]))

            Text(EQBands.shortLabel(index))
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize()
                .rotationEffect(.degrees(-60))
                .frame(height: 34)
        }
    }
}
