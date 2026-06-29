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
        static let dismissedExtensionTip = "dismissedExtensionTip"
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

    /// Set once the user dismisses the "get the browser extension" tip under the
    /// Library add bar, so it never comes back. Default: off (tip can show).
    @Published var dismissedExtensionTip: Bool {
        didSet { UserDefaults.standard.set(dismissedExtensionTip, forKey: Keys.dismissedExtensionTip) }
    }

    private init() {
        let defaults = UserDefaults.standard
        defaults.register(defaults: [
            Keys.autoOpenTelegraph: true,
            Keys.hideMenuBarIcon: false,
            Keys.dismissedExtensionTip: false,
        ])
        // Property observers don't fire during init, so read the stored values directly.
        autoOpenTelegraph = defaults.bool(forKey: Keys.autoOpenTelegraph)
        hideMenuBarIcon = defaults.bool(forKey: Keys.hideMenuBarIcon)
        dismissedExtensionTip = defaults.bool(forKey: Keys.dismissedExtensionTip)
    }
}
