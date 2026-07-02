import AppKit
import Combine
import Foundation

/// Client-side macOS app preferences, persisted in `UserDefaults`.
///
/// These are pure app-behavior toggles (no backend involvement), unlike the
/// provider/model/language settings which round-trip through the local server.
@MainActor
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    private enum Keys {
        static let autoOpenTelegraph = "autoOpenTelegraph"
        static let hideMenuBarIcon = "hideMenuBarIcon"
        static let hideDockIcon = "hideDockIcon"
        static let dismissedExtensionTip = "dismissedExtensionTip"
        static let showWatchSuggestions = "showWatchSuggestions"
    }

    /// When a summary becomes ready, publish it to Telegraph and open the page
    /// in the browser automatically. Default: on (the original behavior).
    @Published var autoOpenTelegraph: Bool {
        didSet { UserDefaults.standard.set(autoOpenTelegraph, forKey: Keys.autoOpenTelegraph) }
    }

    /// Hide the TubeFold status item from the macOS menu bar. Default: off.
    @Published var hideMenuBarIcon: Bool {
        didSet {
            UserDefaults.standard.set(hideMenuBarIcon, forKey: Keys.hideMenuBarIcon)
            MenuBarController.shared.applyMenuBarVisibility()
        }
    }

    /// Hide the TubeFold icon from the macOS Dock (run as an accessory/agent app).
    /// The main window stays available. Default: off.
    @Published var hideDockIcon: Bool {
        didSet {
            UserDefaults.standard.set(hideDockIcon, forKey: Keys.hideDockIcon)
            AppSettings.applyDockIconVisibility(hidden: hideDockIcon)
        }
    }

    /// Apply the Dock-icon preference by switching the app's activation policy.
    /// `.accessory` removes the Dock tile and Cmd-Tab entry; `.regular` restores
    /// them.
    ///
    /// Switching the activation policy deactivates the app and orders its windows
    /// out, which otherwise reads as "the window closed". We restore it on the
    /// next runloop tick — after AppKit has finished the transition — so toggling
    /// the setting only changes the Dock icon, never hides the open window.
    static func applyDockIconVisibility(hidden: Bool) {
        NSApp.setActivationPolicy(hidden ? .accessory : .regular)
        DispatchQueue.main.async {
            AppDelegate.showMainWindow()
        }
    }

    /// Set once the user dismisses the "get the browser extension" tip under the
    /// Library add bar, so it never comes back. Default: off (tip can show).
    @Published var dismissedExtensionTip: Bool {
        didSet { UserDefaults.standard.set(dismissedExtensionTip, forKey: Keys.dismissedExtensionTip) }
    }

    /// Show the "Recently watched" suggestion banner in the Library, fed by the
    /// Chrome extension's watch activity. Default: on.
    @Published var showWatchSuggestions: Bool {
        didSet { UserDefaults.standard.set(showWatchSuggestions, forKey: Keys.showWatchSuggestions) }
    }

    private init() {
        let defaults = UserDefaults.standard
        defaults.register(defaults: [
            Keys.autoOpenTelegraph: true,
            Keys.hideMenuBarIcon: false,
            Keys.hideDockIcon: false,
            Keys.dismissedExtensionTip: false,
            Keys.showWatchSuggestions: true,
        ])
        // Property observers don't fire during init, so read the stored values directly.
        autoOpenTelegraph = defaults.bool(forKey: Keys.autoOpenTelegraph)
        hideMenuBarIcon = defaults.bool(forKey: Keys.hideMenuBarIcon)
        hideDockIcon = defaults.bool(forKey: Keys.hideDockIcon)
        dismissedExtensionTip = defaults.bool(forKey: Keys.dismissedExtensionTip)
        showWatchSuggestions = defaults.bool(forKey: Keys.showWatchSuggestions)
    }
}
