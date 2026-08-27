import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettings().tabItem { Label("일반", systemImage: "gearshape") }
            AudioSettings().tabItem { Label("오디오", systemImage: "hifispeaker") }
            EqualizerSettings().tabItem { Label("이퀄라이저", systemImage: "slider.horizontal.3") }
            AdvancedSettings().tabItem { Label("고급", systemImage: "wrench.and.screwdriver") }
            AboutSettings().tabItem { Label("정보", systemImage: "info.circle") }
        }
        .frame(width: 480, height: 380)
    }
}

private struct GeneralSettings: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        Form {
            Toggle("로그인 시 MacEQ 실행", isOn: Binding(
                get: { if case .enabled = state.loginItemStatus { return true } else { return false } },
                set: { state.setLaunchAtLogin($0) }))

            if case .blockedByUser = state.loginItemStatus {
                // Registration can be refused, and hiding that would leave the
                // toggle silently doing nothing.
                VStack(alignment: .leading, spacing: 6) {
                    Text("MacEQ가 로그인 시 자동으로 시작할 수 없습니다.")
                        .font(.caption)
                    Button("시스템 설정에서 허용") { LoginItemManager.openLoginItemsSettings() }
                        .buttonStyle(.link)
                }
            }
            if case .unavailable(let reason) = state.loginItemStatus {
                Text("등록 실패: \(reason)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Toggle("실행 시 이퀄라이저 켜기", isOn: $state.startEQEnabled)
            Toggle("메뉴 막대에 표시", isOn: $state.showMenuBarIcon)
            Toggle("Dock에 표시", isOn: $state.showDockIcon)
        }
        .formStyle(.grouped)
    }
}

private struct AudioSettings: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        Form {
            Picker("출력 장치", selection: Binding(get: { state.preferredDeviceUID ?? "" },
                                                set: { state.preferredDeviceUID = $0.isEmpty ? nil : $0 })) {
                Text("시스템 기본값 따르기").tag("")
                ForEach(state.availableOutputs, id: \.uid) { device in
                    Text(device.name).tag(device.uid)
                }
            }
            Button("장치 목록 새로 고침") { state.refreshDevices() }
                .buttonStyle(.link)

            Toggle("자동 헤드룸", isOn: Binding(get: { state.live.autoHeadroom },
                                            set: { state.setAutoHeadroom($0) }))
            Toggle("세이프티 리미터", isOn: $state.limiterEnabled)

            LabeledContent("엔진") { Text(engineDescription) }
        }
        .formStyle(.grouped)
        .onAppear { state.refreshDevices() }
    }

    private var engineDescription: String {
        guard state.status.sampleRate > 0 else { return "정지됨" }
        return "\(Int(state.status.sampleRate)) Hz · \(state.status.channels)채널 · "
            + "\(state.status.bufferFrames) 프레임"
    }
}

private struct EqualizerSettings: View {
    @EnvironmentObject private var state: AppState
    @State private var message: String?

    var body: some View {
        Form {
            Picker("기본 프리셋", selection: Binding(get: { state.selectedPresetID },
                                                set: { id in
                if let preset = state.presets.preset(id: id) { state.select(preset: preset) }
            })) {
                ForEach(state.presets.all) { preset in
                    Text(preset.name).tag(preset.id)
                }
            }

            HStack {
                Button("내보내기…") { export() }
                Button("가져오기…") { performImport() }
                Spacer()
                Button("사용자 프리셋 초기화", role: .destructive) { state.resetPresets() }
            }

            if let message {
                Text(message).font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func export() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "MacEQ Presets.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try state.exportPresets(to: url)
            message = "\(state.presets.userPresets.count)개 프리셋을 내보냈습니다."
        } catch {
            message = "내보내기 실패: \(error.localizedDescription)"
        }
    }

    private func performImport() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let count = try state.importPresets(from: url)
            message = "\(count)개 프리셋을 가져왔습니다."
        } catch {
            message = "가져오기 실패: 파일을 읽을 수 없습니다."
        }
    }
}

private struct AdvancedSettings: View {
    @EnvironmentObject private var state: AppState
    @State private var confirmReset = false

    var body: some View {
        Form {
            Section("진단") {
                DiagnosticsView()
            }
            Section {
                Button("오디오 엔진 다시 시작") { state.retryAudio() }
                Button("MacEQ 초기화…", role: .destructive) { confirmReset = true }
            }
        }
        .formStyle(.grouped)
        .alert("MacEQ를 초기화할까요?", isPresented: $confirmReset) {
            Button("초기화", role: .destructive) { state.resetEverything() }
            Button("취소", role: .cancel) {}
        } message: {
            Text("프리셋, 장치별 설정, 로그인 항목이 모두 삭제됩니다.")
        }
    }
}

private struct AboutSettings: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        Form {
            LabeledContent("버전") { Text("\(AppInfo.version) (\(AppInfo.build))") }
            HStack {
                Button("업데이트 확인") { state.updates.check() }
                Text(updateDescription).font(.caption).foregroundStyle(.secondary)
                Spacer()
                if case .available = state.updates.state {
                    Button("릴리스 보기") { state.updates.openReleasePage() }
                }
            }
            Link("GitHub", destination: AppInfo.repositoryURL)
            Text("오디오는 이 Mac을 벗어나지 않습니다. 계정도, 클라우드도, 광고도 없습니다.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
    }

    private var updateDescription: String {
        switch state.updates.state {
        case .idle: return ""
        case .checking: return "확인 중…"
        case .upToDate: return "최신 버전입니다."
        case .available(let version, _): return "\(version) 사용 가능"
        case .failed(let reason): return "확인 실패: \(reason)"
        }
    }
}
