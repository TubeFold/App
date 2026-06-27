import Foundation
import Sparkle

/// Owns the Sparkle updater for the whole app.
///
/// `SPUStandardUpdaterController` must be created once and kept alive for the
/// process lifetime; it wires up Sparkle's standard UI (the "update available"
/// window, progress, install-and-relaunch). We start it eagerly from
/// `AppDelegate` so the automatic background check (gated by
/// `SUEnableAutomaticChecks` in Info.plist) runs, and expose a manual check for
/// the menu-bar "Check for Updates…" item.
@MainActor
final class UpdaterController {
    static let shared = UpdaterController()

    private let controller: SPUStandardUpdaterController

    private init() {
        controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
    }

    /// False while an update check is already in flight, so the menu item can
    /// disable itself instead of stacking concurrent checks.
    var canCheckForUpdates: Bool {
        controller.updater.canCheckForUpdates
    }

    func checkForUpdates() {
        controller.checkForUpdates(nil)
    }
}
