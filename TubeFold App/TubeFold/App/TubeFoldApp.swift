import AppKit
import SwiftUI
import TubeFoldKit

/// Bridges SwiftUI's `openWindow` action out to AppKit code (the menu bar /
/// URL handlers), so we can recreate the main window even after it was closed —
/// `NSApp.windows` no longer contains it once SwiftUI tears it down.
@MainActor
final class MainWindowOpener {
    static let shared = MainWindowOpener()
    var open: (() -> Void)?
}

private struct CaptureWindowOpener: ViewModifier {
    @Environment(\.openWindow) private var openWindow

    func body(content: Content) -> some View {
        content.onAppear {
            MainWindowOpener.shared.open = { openWindow(id: TubeFoldApp.mainWindowID) }
            // Apply the saved Dock-icon preference once the window actually
            // exists, so the launch-time restore in `applyDockIconVisibility`
            // can always find it instead of racing SwiftUI's window creation.
            AppSettings.applyDockIconVisibility(hidden: AppSettings.shared.hideDockIcon)
        }
    }
}

@main
struct TubeFoldApp: App {
    static let mainWindowID = "main"

    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup(id: Self.mainWindowID) {
            ContentView()
                .frame(minWidth: 900, minHeight: 620)
                // Route external events (tubefold:// opens) into this window if
                // it already exists — without this, WindowGroup creates a brand
                // new window for every incoming URL.
                .handlesExternalEvents(preferring: ["*"], allowing: ["*"])
                .modifier(CaptureWindowOpener())
                .onOpenURL { url in
                    // Any tubefold:// link (e.g. the extension's "Open App" button)
                    // just brings the app and its window to the front.
                    guard url.scheme == "tubefold" else { return }
                    AppDelegate.showMainWindow()
                }
        }
        .windowStyle(.titleBar)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_: Notification) {
        // SwiftUI Previews boot the full app executable to host the Canvas, which
        // runs this delegate. Skip all production startup — the single-instance
        // exit(0) guard below, Sparkle, the menu bar and the backend each take down
        // the preview agent ("…app may have crashed") and break every #Preview.
        if ProcessInfo.processInfo.environment["XCODE_RUNNING_FOR_PREVIEWS"] == "1" {
            return
        }

        // If another copy of TubeFold is already running (e.g. an installed build
        // while LaunchServices opened a tubefold:// link against a different bundle
        // path), focus that one and bail instead of standing up a second instance.
        if activateRunningInstanceIfPresent() {
            return
        }
        // Bring up the in-process backend: reclaims orphaned jobs, drains the
        // queue, and serves the Chrome extension on 127.0.0.1:43821.
        TubeFoldBackend.shared.startServing()
        // Start Sparkle: kicks off the automatic background update check and keeps
        // the updater alive for the manual "Check for Updates…" menu item.
        let updater = UpdaterController.shared
        // Sparkle's scheduled check only runs once per `SUScheduledCheckInterval`
        // (default 24h), so a fresh launch often won't check. Fire an explicit
        // silent check every launch — it only shows UI if an update exists.
        updater.checkForUpdatesInBackground()
        MenuBarController.shared.start()
        // The Dock-icon preference is applied once the main window appears
        // (see `CaptureWindowOpener`), not here — applying it this early can
        // race SwiftUI's window creation and leave the app with no Dock icon
        // and no visible window.
    }

    private func activateRunningInstanceIfPresent() -> Bool {
        let current = NSRunningApplication.current
        guard let bundleID = current.bundleIdentifier else { return false }
        let others = NSRunningApplication
            .runningApplications(withBundleIdentifier: bundleID)
            .filter { $0.processIdentifier != current.processIdentifier && !$0.isTerminated }
        guard let existing = others.first else { return false }
        existing.activate(options: [.activateAllWindows])
        // Exit hard so the redundant instance never touches the menu bar or backend
        // the running instance already owns.
        exit(0)
    }

    /// Bring the main window back to the front, recreating it if SwiftUI has
    /// already torn it down (e.g. after the Dock icon was hidden and the window
    /// closed). Works whether the app is `.regular` or `.accessory`.
    static func showMainWindow() {
        NSApp.activate(ignoringOtherApps: true)
        if let window = NSApp.windows.first(where: { $0.canBecomeMain }) {
            if window.isMiniaturized {
                window.deminiaturize(nil)
            }
            window.makeKeyAndOrderFront(nil)
        } else {
            MainWindowOpener.shared.open?()
        }
    }

    /// Keep running when the last window closes — the app lives in the menu bar
    /// (and may have no Dock icon), so closing the window must not quit it.
    func applicationShouldTerminateAfterLastWindowClosed(_: NSApplication) -> Bool {
        false
    }

    /// Clicking the Dock icon (or otherwise reopening) restores/focuses the single
    /// main window instead of spawning another one.
    func applicationShouldHandleReopen(_: NSApplication, hasVisibleWindows _: Bool) -> Bool {
        // Always bring the existing window forward ourselves and return `false` so
        // neither AppKit nor SwiftUI's `WindowGroup` runs its default reopen — that
        // default recreates a second window even when one is already visible.
        AppDelegate.showMainWindow()
        return false
    }

    func applicationShouldTerminate(_: NSApplication) -> NSApplication.TerminateReply {
        MenuBarController.shared.stop()
        TubeFoldBackend.shared.stopServing()
        return .terminateNow
    }

    func applicationWillTerminate(_: Notification) {
        MenuBarController.shared.stop()
        TubeFoldBackend.shared.stopServing()
    }
}
