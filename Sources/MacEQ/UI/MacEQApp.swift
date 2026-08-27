import AppKit
import SwiftUI

@main
struct MacEQApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        Window("MacEQ", id: WindowID.main) {
            RootView()
                .environmentObject(delegate.state)
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
        }

        MenuBarExtra("MacEQ", systemImage: delegate.state.eqEnabled ? "slider.horizontal.3" : "slider.horizontal.below.rectangle",
                     isInserted: Binding(get: { delegate.state.showMenuBarIcon },
                                         set: { delegate.state.showMenuBarIcon = $0 })) {
            MenuBarContent()
                .environmentObject(delegate.state)
        }
        .menuBarExtraStyle(.menu)
    }
}

enum WindowID {
    static let main = "main"
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
    }
}
