import AppKit
import SwiftUI

@main
struct MacEQApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        Window("MacEQ", id: WindowID.main) {
            RootView()
                .environmentObject(delegate.state)
                .tint(.macEQAccent)
        }
        .defaultSize(width: 520, height: 640)
        .windowResizability(.contentSize)
        .commands {
            CommandGroup(replacing: .undoRedo) {
                Button("실행 취소") { delegate.state.undo() }
                    .keyboardShortcut("z", modifiers: .command)
                    .disabled(!delegate.state.canUndo)
                Button("다시 실행") { delegate.state.redo() }
                    .keyboardShortcut("z", modifiers: [.command, .shift])
                    .disabled(!delegate.state.canRedo)
            }
            CommandGroup(replacing: .newItem) {}
        }

        Settings {
            SettingsView()
                .environmentObject(delegate.state)
                .tint(.macEQAccent)
        }

        MenuBarExtra("MacEQ", systemImage: delegate.state.eqEnabled ? "slider.horizontal.3" : "slider.horizontal.below.rectangle",
                     isInserted: Binding(get: { delegate.state.showMenuBarIcon },
                                         set: { delegate.state.showMenuBarIcon = $0 })) {
            MenuBarContent()
                .environmentObject(delegate.state)
                .tint(.macEQAccent)
        }
        .menuBarExtraStyle(.menu)
    }
}

enum WindowID {
    static let main = "main"
}

/// Restored SwiftUI windows can retain coordinates from a disconnected screen.
/// Keep every app-owned window reachable from the menu-bar display.
@MainActor
func recenterIfOffScreen(_ window: NSWindow?) {
    guard let window, let primaryScreen = NSScreen.screens.first,
          !primaryScreen.visibleFrame.intersects(window.frame) else { return }
    window.setFrameOrigin(NSPoint(
        x: primaryScreen.visibleFrame.midX - window.frame.width / 2,
        y: primaryScreen.visibleFrame.midY - window.frame.height / 2))
}

/// Owns the single AppState instance so it exists — and its audio session can
/// start — before any SwiftUI view has to appear. Relying on view `onAppear`
/// for this raced applicationDidFinishLaunching: the delegate's state
/// reference was still nil when launch finished, and the session never
/// started.
///
/// Closing the window must not stop the EQ, and quitting must release the tap
/// and the aggregate device.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let state = AppState()

    func applicationDidFinishLaunching(_ notification: Notification) {
        ProcessTap.destroyOrphans()
        TapAggregateDevice.destroyOrphans()
        state.start()
        // LSUIElement keeps MacEQ out of the Dock, but the very first launch
        // has to put onboarding in front of the user.
        if !state.onboardingCompleted {
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationWillTerminate(_ notification: Notification) {
        state.shutdown()
    }
}

/// Onboarding takes over the window until it is done, so the first launch
/// cannot land on an empty-looking Home with no audio.
struct RootView: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        Group {
            if state.onboardingCompleted {
                HomeView()
            } else {
                OnboardingView()
            }
        }
        .frame(minWidth: 480, minHeight: 600)
        .onAppear(perform: recenterMainWindowIfNeeded)
    }

    /// macOS restores the window to its last-known frame. That frame can sit
    /// on a screen AppKit still lists — an extended display that isn't
    /// currently being looked at — while being nowhere near the main
    /// display. As an accessory-policy app with no Dock icon, that reads as
    /// "MacEQ didn't open" rather than "the window is on another screen".
    /// Recenter onto the main screen whenever the restored frame misses it.
    ///
    /// Deferred to the next run loop turn: at `onAppear` time AppKit has not
    /// finished applying the restored frame yet, so checking synchronously
    /// reads the window's pre-restoration position.
    private func recenterMainWindowIfNeeded() {
        DispatchQueue.main.async {
            // `NSScreen.main` is the screen under the key window — which, if
            // the window restored onto a stale/extended display, is that
            // same wrong screen. `.screens.first` is always the display that
            // actually carries the menu bar, so it's the one to fall back to.
            recenterIfOffScreen(NSApp.windows.first(where: { $0.title == "MacEQ" }))
        }
    }
}
