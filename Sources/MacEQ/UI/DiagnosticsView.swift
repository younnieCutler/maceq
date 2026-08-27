import AppKit
import SwiftUI

/// Raw technical detail lives here and nowhere else — error messages elsewhere
/// stay in plain language.
struct DiagnosticsView: View {
    @EnvironmentObject private var state: AppState
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(rows, id: \.0) { row in
                HStack {
                    Text(row.0).foregroundStyle(.secondary)
                    Spacer()
                    Text(row.1).font(.callout.monospacedDigit())
                }
                .font(.callout)
            }
            HStack {
                Button(copied ? L("diagnostics.copied") : L("diagnostics.copy")) { copy() }
                    .buttonStyle(.link)
                Spacer()
            }
            .padding(.top, 4)
        }
        .accessibilityElement(children: .contain)
    }

    private var rows: [(String, String)] {
        let status = state.status
        func level(_ value: Double) -> String {
            value.isFinite ? String(format: "%.1f dBFS", value) : L("diagnostics.silent")
        }
        return [
            ("MacEQ", "\(AppInfo.version) (\(AppInfo.build))"),
            (L("diagnostics.engine"), describe(status.state)),
            (L("diagnostics.output"), status.deviceName),
            (L("diagnostics.sampleRate"), status.sampleRate > 0 ? "\(Int(status.sampleRate)) Hz" : "—"),
            (L("diagnostics.channels"), "\(status.channels)"),
            (L("diagnostics.buffer"), L("diagnostics.buffer.frames", Int(status.bufferFrames))),
            (L("diagnostics.equalizer"), status.enabled ? L("common.on") : L("common.off")),
            (L("diagnostics.autoHeadroom"), status.autoHeadroom
                ? String(format: "%.1f dB", -status.requiredHeadroomDB) : L("common.off")),
            (L("diagnostics.effectivePreamp"), String(format: "%+.1f dB", status.effectivePreampDB)),
            (L("diagnostics.peakIn"), level(status.peakInDB)),
            (L("diagnostics.peakOut"), level(status.peakOutDB)),
            (L("diagnostics.limiter"), String(format: "%.1f dB", status.limiterReductionDB)),
            (L("diagnostics.lastError"), status.lastError ?? L("diagnostics.none")),
        ]
    }

    private func describe(_ state: AudioSession.State) -> String {
        switch state {
        case .stopped: return L("diagnostics.state.stopped")
        case .running: return L("diagnostics.state.running")
        case .needsPermission: return L("diagnostics.state.needsPermission")
        case .recovering(let attempt): return L("diagnostics.state.recovering", attempt)
        case .failed(let reason): return L("diagnostics.state.failed", reason)
        }
    }

    /// Diagnostics never contain audio, only the numbers describing it.
    private func copy() {
        let text = rows.map { "\($0.0): \($0.1)" }.joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { copied = false }
    }
}
