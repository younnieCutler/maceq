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
                Button(copied ? "복사됨" : "진단 정보 복사") { copy() }
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
            value.isFinite ? String(format: "%.1f dBFS", value) : "무음"
        }
        return [
            ("MacEQ", "\(AppInfo.version) (\(AppInfo.build))"),
            ("엔진", describe(status.state)),
            ("출력", status.deviceName),
            ("샘플레이트", status.sampleRate > 0 ? "\(Int(status.sampleRate)) Hz" : "—"),
            ("채널", "\(status.channels)"),
            ("버퍼", "\(status.bufferFrames) 프레임"),
            ("이퀄라이저", status.enabled ? "켜짐" : "꺼짐"),
            ("자동 헤드룸", status.autoHeadroom
                ? String(format: "%.1f dB", -status.requiredHeadroomDB) : "꺼짐"),
            ("실효 프리앰프", String(format: "%+.1f dB", status.effectivePreampDB)),
            ("입력 피크", level(status.peakInDB)),
            ("출력 피크", level(status.peakOutDB)),
            ("리미터", String(format: "%.1f dB", status.limiterReductionDB)),
            ("마지막 오류", status.lastError ?? "없음"),
        ]
    }

    private func describe(_ state: AudioSession.State) -> String {
        switch state {
        case .stopped: return "정지됨"
        case .running: return "실행 중"
        case .needsPermission: return "권한 없음"
        case .recovering(let attempt): return "복구 중 (\(attempt))"
        case .failed(let reason): return "실패 — \(reason)"
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
