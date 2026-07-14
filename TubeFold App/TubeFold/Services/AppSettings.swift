import AppKit
import Combine
import Foundation

/// Where the app shows up: the Dock, the menu bar, or both. A facade over the
/// two stored toggles (`hideDockIcon` / `hideMenuBarIcon`) that rules out the
/// "hidden everywhere" combination.
enum AppVisibilityMode: CaseIterable, Identifiable {
    case dockAndMenuBar
    case menuBarOnly
    case dockOnly

    var id: Self {
        self
    }

    var title: String {
        switch self {
        case .dockAndMenuBar: String(localized: "Dock & Menu Bar")
        case .menuBarOnly: String(localized: "Menu Bar Only")
        case .dockOnly: String(localized: "Dock Only")
        }
    }
}

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

        static let all = [
            autoOpenTelegraph,
            hideMenuBarIcon,
            hideDockIcon,
            dismissedExtensionTip,
            showWatchSuggestions,
        ]
    }

    /// When a summary becomes ready, publish it to Telegraph and open the page
    /// in the browser automatically. Default: off — publishing creates a
    /// public page that can never be deleted, so it has to be an opt-in.
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
            // Refresh the status-item menu so the App Visibility Mode checkmark follows.
            MenuBarController.shared.applyMenuBarVisibility()
        }
    }

    /// The two stored toggles expressed as a single three-way mode, for the
    /// Settings picker and the status-item "App Visibility Mode" submenu.
    var appVisibilityMode: AppVisibilityMode {
        get {
            if hideDockIcon {
                return .menuBarOnly
            }
            if hideMenuBarIcon {
                return .dockOnly
            }
            return .dockAndMenuBar
        }
        set {
            let hidden: (dock: Bool, menuBar: Bool) = switch newValue {
            case .dockAndMenuBar: (false, false)
            case .menuBarOnly: (true, false)
            case .dockOnly: (false, true)
            }
            // Reveal before hiding so we never pass through a state with both
            // icons gone; skip no-op writes (their didSets have side effects).
            if hideDockIcon, !hidden.dock {
                hideDockIcon = false
            }
            if hideMenuBarIcon, !hidden.menuBar {
                hideMenuBarIcon = false
            }
            if !hideDockIcon, hidden.dock {
                hideDockIcon = true
            }
            if !hideMenuBarIcon, hidden.menuBar {
                hideMenuBarIcon = true
            }
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
    /// Chrome extension's watch activity. Default: off.
    @Published var showWatchSuggestions: Bool {
        didSet { UserDefaults.standard.set(showWatchSuggestions, forKey: Keys.showWatchSuggestions) }
    }

    private init() {
        let defaults = UserDefaults.standard
        defaults.register(defaults: [
            Keys.autoOpenTelegraph: false,
            Keys.hideMenuBarIcon: false,
            Keys.hideDockIcon: false,
            Keys.dismissedExtensionTip: false,
            Keys.showWatchSuggestions: false,
        ])
        // Property observers don't fire during init, so read the stored values directly.
        autoOpenTelegraph = defaults.bool(forKey: Keys.autoOpenTelegraph)
        hideMenuBarIcon = defaults.bool(forKey: Keys.hideMenuBarIcon)
        hideDockIcon = defaults.bool(forKey: Keys.hideDockIcon)
        dismissedExtensionTip = defaults.bool(forKey: Keys.dismissedExtensionTip)
        showWatchSuggestions = defaults.bool(forKey: Keys.showWatchSuggestions)
        // Legacy state from when the two toggles were independent: both icons
        // hidden. The visibility mode can't express that, so restore the menu
        // bar icon (didSet doesn't fire in init — persist by hand).
        if hideDockIcon, hideMenuBarIcon {
            hideMenuBarIcon = false
            defaults.set(false, forKey: Keys.hideMenuBarIcon)
        }
    }

    func resetForFirstRunTesting() {
        let defaults = UserDefaults.standard
        for key in Keys.all {
            defaults.removeObject(forKey: key)
        }
        autoOpenTelegraph = false
        hideMenuBarIcon = false
        hideDockIcon = false
        dismissedExtensionTip = false
        showWatchSuggestions = false
    }
}
