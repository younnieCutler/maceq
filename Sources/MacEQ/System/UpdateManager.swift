import AppKit
import Foundation

/// Checks the GitHub Releases API for a newer tag.
///
/// ponytail: no Sparkle. MacEQ ships without a Developer ID certificate, so an
///           auto-installed update would be blocked by Gatekeeper anyway and
///           the framework, appcast hosting and EdDSA keys would all be dead
///           weight. Swap it in if the project ever gets notarised.
@MainActor
final class UpdateManager: ObservableObject {
    enum State: Equatable {
        case idle
        case checking
        case upToDate
        case available(version: String, url: URL)
        case failed(String)
    }

    @Published private(set) var state: State = .idle

    private let repository: String
    private let currentVersion: String

    init(repository: String = "aforcekim/maceq",
         currentVersion: String = AppInfo.version) {
        self.repository = repository
        self.currentVersion = currentVersion
    }

    func check() {
        guard state != .checking else { return }
        state = .checking
        let url = URL(string: "https://api.github.com/repos/\(repository)/releases/latest")!
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")

        Task { [weak self] in
            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                guard let http = response as? HTTPURLResponse else {
                    throw URLError(.badServerResponse)
                }
                guard http.statusCode != 404 else {
                    self?.state = .upToDate  // no releases published yet
                    return
                }
                guard http.statusCode == 200 else {
                    throw URLError(.badServerResponse)
                }
                let release = try JSONDecoder().decode(Release.self, from: data)
                let latest = release.tag_name.trimmingCharacters(in: CharacterSet(charactersIn: "v"))
                guard let page = URL(string: release.html_url) else {
                    throw URLError(.badURL)
                }
                if let self, UpdateManager.isNewer(latest, than: self.currentVersion) {
                    self.state = .available(version: latest, url: page)
                } else {
                    self?.state = .upToDate
                }
            } catch {
                self?.state = .failed(error.localizedDescription)
            }
        }
    }

    func openReleasePage() {
        if case .available(_, let url) = state {
            NSWorkspace.shared.open(url)
        }
    }

    static func isNewer(_ candidate: String, than current: String) -> Bool {
        func parts(_ value: String) -> [Int] {
            value.split(separator: ".").map { Int($0.filter(\.isNumber)) ?? 0 }
        }
        let left = parts(candidate), right = parts(current)
        for index in 0..<max(left.count, right.count) {
            let a = index < left.count ? left[index] : 0
            let b = index < right.count ? right[index] : 0
            if a != b { return a > b }
        }
        return false
    }

    private struct Release: Decodable {
        let tag_name: String
        let html_url: String
    }
}

enum AppInfo {
    static var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
    }
    static var build: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "0"
    }
    static let repositoryURL = URL(string: "https://github.com/aforcekim/maceq")!
}
