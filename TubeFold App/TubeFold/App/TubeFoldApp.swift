import AppKit
import SwiftUI

@main
struct TubeFoldApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView()
                .frame(minWidth: 900, minHeight: 620)
        }
        .windowStyle(.titleBar)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        MenuBarController.shared.start()
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
