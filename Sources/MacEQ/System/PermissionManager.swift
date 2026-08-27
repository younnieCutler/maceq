import AppKit
import Foundation

/// System audio capture is granted through System Settings, and there is no
/// API to query or request it directly for Core Audio taps — the only signal
/// is whether audio actually arrives, which `AudioSession` watches for.
enum PermissionManager {
    /// Privacy & Security -> Screen & System Audio Recording, where the audio
    /// capture toggle lives.
    private static let settingsURL = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!

    static func openSystemSettings() {
        NSWorkspace.shared.open(settingsURL)
    }
}
