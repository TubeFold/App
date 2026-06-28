import AppKit
import SwiftUI

@main
struct TubeFoldApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView()
                .frame(minWidth: 900, minHeight: 620)
                .onOpenURL { url in
                    // Any tubefold:// link (e.g. the extension's "Open App" button)
                    // just brings the app and its window to the front.
                    guard url.scheme == "tubefold" else { return }
                    NSApp.activate(ignoringOtherApps: true)
                    NSApp.windows.first(where: { $0.canBecomeMain })?.makeKeyAndOrderFront(nil)
                }
        }
        .windowStyle(.titleBar)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // If another copy of TubeFold is already running (e.g. an installed build
        // while LaunchServices opened a tubefold:// link against a different bundle
        // path), focus that one and bail instead of standing up a second instance.
        if activateRunningInstanceIfPresent() { return }
        // Start Sparkle: kicks off the automatic background update check and keeps
        // the updater alive for the manual "Check for Updates…" menu item.
        let updater = UpdaterController.shared
        // Sparkle's scheduled check only runs once per `SUScheduledCheckInterval`
        // (default 24h), so a fresh launch often won't check. Fire an explicit
        // silent check every launch — it only shows UI if an update exists.
        updater.checkForUpdatesInBackground()
        MenuBarController.shared.start()
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

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        MenuBarController.shared.stop()
        BackendProcessController.shared.stop()
        return .terminateNow
    }

    func applicationWillTerminate(_ notification: Notification) {
        MenuBarController.shared.stop()
        BackendProcessController.shared.stop()
    }
}
