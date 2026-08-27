import ServiceManagement
import Foundation

/// Wraps `SMAppService.mainApp`. Registration can be refused — the user may
/// have blocked login items in System Settings — and that is a normal outcome
/// to show, not an error to swallow.
enum LoginItemManager {
    enum Status {
        case enabled
        case disabled
        case blockedByUser
        case unavailable(String)
    }

    static var status: Status {
        switch SMAppService.mainApp.status {
        case .enabled: return .enabled
        case .requiresApproval: return .blockedByUser
        case .notRegistered, .notFound: return .disabled
        @unknown default: return .disabled
        }
    }

    /// Returns the status that actually resulted, which may not be what was
    /// asked for.
    @discardableResult
    static func setEnabled(_ enabled: Bool) -> Status {
        do {
            if enabled {
                if SMAppService.mainApp.status == .enabled { return .enabled }
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            return status
        } catch {
            Log.info("login item \(enabled ? "register" : "unregister") failed: \(error)")
            let current = status
            if case .disabled = current, enabled {
                return .unavailable("\(error)")
            }
            return current
        }
    }

    static func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
