import Combine
import Foundation
import Sparkle

/// Owns the Sparkle updater for the whole app.
///
/// `SPUStandardUpdaterController` must be created once and kept alive for the
/// process lifetime; it wires up Sparkle's standard UI (the "update available"
/// window, progress, install-and-relaunch). We start it eagerly from
/// `AppDelegate` so the automatic background check (gated by
/// `SUEnableAutomaticChecks` in Info.plist) runs, and drive the About screen's
/// "Check for Updates…" button and auto-update toggle from here.
@MainActor
final class UpdaterController: ObservableObject {
    static let shared = UpdaterController()

    /// Mirrors `SPUUpdater.canCheckForUpdates` (false while a check is in
    /// flight), published so the menu item / button can disable themselves.
    @Published private(set) var canCheckForUpdates = false

    /// Two-way bound to the "Check for updates automatically" toggle.
    @Published var automaticallyChecksForUpdates: Bool {
        didSet {
            controller.updater.automaticallyChecksForUpdates = automaticallyChecksForUpdates
        }
    }

    private let controller: SPUStandardUpdaterController
    private var cancellable: AnyCancellable?

    private init() {
        let controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        self.controller = controller
        self.canCheckForUpdates = controller.updater.canCheckForUpdates
        self.automaticallyChecksForUpdates = controller.updater.automaticallyChecksForUpdates
        self.cancellable = nil

        // Keep `canCheckForUpdates` in sync with Sparkle's state.
        cancellable = controller.updater.publisher(for: \.canCheckForUpdates)
            .receive(on: RunLoop.main)
            .sink { [weak self] value in self?.canCheckForUpdates = value }
    }

    func checkForUpdates() {
        controller.checkForUpdates(nil)
    }

    /// Silent background check, fired once at launch. Unlike Sparkle's scheduled
    /// check (gated by `SUScheduledCheckInterval`, default 24h) this runs every
    /// time the app starts, but only surfaces UI when an update is actually
    /// available — so it never nags when the user is up to date. No-op when the
    /// auto-update toggle is off.
    func checkForUpdatesInBackground() {
        guard automaticallyChecksForUpdates else { return }
        controller.updater.checkForUpdatesInBackground()
    }
}
