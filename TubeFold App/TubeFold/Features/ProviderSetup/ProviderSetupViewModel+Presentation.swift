import AppKit
import Foundation

/// Derived, read-only presentation state over the view model's published
/// properties — everything the setup wizard and Settings screens render.
extension ProviderSetupViewModel {
    var providerDisplayName: String {
        availableProviders.first { $0.id == selectedProviderID }?.displayName
            ?? (selectedProviderID == "claude" ? "Claude Code CLI" : "Codex CLI")
    }

    func providerAccountName(for providerID: String) -> String {
        providerID == "claude" ? "Claude" : "ChatGPT"
    }

    func providerAccountSubtitle(for providerID: String) -> String {
        providerID == "claude"
            ? "Uses Claude Code CLI"
            : "Uses Codex CLI"
    }

    var isSetupComplete: Bool {
        setupState?.providerSetupCompleted == true && !hasInstallationFailure && !hasConnectionFailure
    }

    var shouldPresentSetupOnLaunch: Bool {
        hasLoadedState && setupState?.providerSetupCompleted != true
    }

    var requiresRepair: Bool {
        hasLoadedState
            && apiReachable
            && setupState?.providerSetupCompleted == true
            && (hasInstallationFailure || hasConnectionFailure)
    }

    var installationSucceeded: Bool {
        installationResult?.status == "installed"
    }

    var connectionSucceeded: Bool {
        guard !hasInstallationFailure, !hasConnectionFailure else { return false }
        return connectionResult?.status == "success" || setupState?
            .lastSuccessfulConnectionTest != nil || isSetupComplete
    }

    var providerSummary: String {
        if hasInstallationFailure || hasConnectionFailure {
            return "Repair needed"
        }
        if connectionSucceeded {
            return "Ready"
        }
        if installationSucceeded {
            return "Installed"
        }
        if let version = setupState?.version(for: selectedProviderID), !version.isEmpty {
            return "Needs check: \(version)"
        }
        if setupState?.executablePath(for: selectedProviderID) != nil {
            return "Needs check"
        }
        return "Not configured"
    }

    var versionSummary: String {
        if providerUpdateAvailable,
           let installedVersion = installationResult?.details["installedVersion"]?.stringValue,
           let latestVersion = installationResult?.details["latestVersion"]?.stringValue
        {
            return "\(installedVersion) → \(latestVersion)"
        }
        return installationResult?.version ?? setupState?.version(for: selectedProviderID) ?? "Unknown version"
    }

    var providerInstallationStatusTitle: String {
        providerUpdateAvailable ? "Update available" : "Installed"
    }

    var providerUpdateAvailable: Bool {
        selectedProviderID == "codex"
            && installationResult?.details["updateAvailable"]?.boolValue == true
    }

    var modelSummary: String {
        selectedModelOption?.label ?? selectedModel
    }

    var selectedModelOption: CodexModelOption? {
        modelOptions.first { $0.id == selectedModel }
    }

    var outputLanguageDirty: Bool {
        outputLanguageDraft.trimmingCharacters(in: .whitespacesAndNewlines) != outputLanguage
    }

    var providerInstalled: Bool {
        installationSucceeded || (isSetupComplete && setupState?.executablePath(for: selectedProviderID) != nil)
    }

    var providerSignedIn: Bool {
        connectionSucceeded
    }

    var providerReady: Bool {
        isSetupComplete
    }

    var setupButtonTitle: String {
        requiresRepair ? "Repair \(providerDisplayName)" : "Provider Setup"
    }

    var outputDirectorySummary: String {
        outputDirectoryURL.path
    }

    /// Resolved on-disk location where summaries are saved. Falls back to the
    /// default `~/Library/Application Support/TubeFold/exports` folder when the
    /// backend hasn't reported a preferred directory yet.
    var outputDirectoryURL: URL {
        if let path = setupState?.preferredOutputDirectory, !path.isEmpty {
            return URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true)
        }
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(
                "Library/Application Support",
                isDirectory: true,
            )
        return appSupport
            .appendingPathComponent("TubeFold", isDirectory: true)
            .appendingPathComponent("exports", isDirectory: true)
    }

    /// Open the summaries folder in Finder, creating it first if it doesn't
    /// exist yet (e.g. before the first summary has been saved).
    func revealOutputDirectory() {
        let url = outputDirectoryURL
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    var primaryButtonTitle: String {
        switch currentStep {
        case .welcome:
            "Get Started"
        case .outputLanguage:
            "Next"
        case .beforeBegin:
            "Next"
        case .checkInstallation:
            installationSucceeded ? "Next" : "Check Installation"
        case .testConnection:
            connectionSucceeded ? "Next" : "Test Connection"
        case .complete:
            "Complete Setup"
        }
    }

    var primaryButtonSystemImage: String {
        switch currentStep {
        case .welcome, .outputLanguage, .beforeBegin:
            "chevron.right"
        case .checkInstallation:
            installationSucceeded ? "chevron.right" : "arrow.clockwise"
        case .testConnection:
            connectionSucceeded ? "chevron.right" : "bolt.fill"
        case .complete:
            "checkmark.circle.fill"
        }
    }

    var canAdvance: Bool {
        switch currentStep {
        case .welcome, .outputLanguage, .beforeBegin, .checkInstallation, .complete:
            true
        case .testConnection:
            installationSucceeded || connectionSucceeded
        }
    }

    var installationStatusTitle: String {
        guard let result = installationResult else {
            return "Not checked"
        }
        switch result.status {
        case "installed":
            return result.version ?? "Installed"
        case "notInstalled":
            return "Not installed"
        case "invalid":
            return "Cannot launch"
        default:
            return result.status
        }
    }

    var installationMessage: String {
        installationResult?.userMessage
            ?? setupState?.executablePath(for: selectedProviderID)
            ?? "TubeFold will look for \(providerDisplayName) automatically. You can also choose it manually."
    }

    var shouldShowCodexCLIInstallHelp: Bool {
        selectedProviderID == "codex"
            && installationResult?.details["errorCategory"]?.stringValue == "installationMissing"
    }

    var codexAppInstalled: Bool {
        installationResult?.details["codexAppInstalled"]?.boolValue == true
    }

    var codexAppPath: String? {
        installationResult?.details["codexAppPath"]?.stringValue
    }

    var chatGPTAppInstalled: Bool {
        installationResult?.details["chatGPTAppInstalled"]?.boolValue == true
    }

    var chatGPTAppPath: String? {
        installationResult?.details["chatGPTAppPath"]?.stringValue
    }

    var installationDetails: [String] {
        guard let result = installationResult else { return [] }
        var lines = result.checkedPaths.map { "checked: \($0)" }
        lines.append(contentsOf: result.details.formattedLines)
        return lines
    }

    var installationHasError: Bool {
        guard let result = installationResult else { return false }
        return result.status != "installed"
    }

    var connectionStatusTitle: String {
        guard let result = connectionResult else {
            return connectionSucceeded ? "Connected" : "Not tested"
        }
        switch result.status {
        case "success":
            return "Signed in"
        case "authenticationRequired":
            return "Sign-in required"
        case "usageLimitReached":
            return "Usage limit reached"
        case "networkError":
            return "Network error"
        case "timeout":
            return "Timed out"
        default:
            return result.status
        }
    }

    var connectionMessage: String {
        connectionResult?.userMessage
            ?? "Run a quick \(providerDisplayName) request to confirm this Mac is signed in."
    }

    var connectionDetails: [String] {
        connectionResult?.details.formattedLines ?? []
    }

    var connectionHasError: Bool {
        guard let result = connectionResult else { return false }
        return result.status != "success"
    }

    func isStepComplete(_ step: SetupStep) -> Bool {
        switch step {
        case .welcome, .outputLanguage, .beforeBegin:
            currentStep.rawValue > step.rawValue
        case .checkInstallation:
            installationSucceeded && currentStep.rawValue > step.rawValue
        case .testConnection:
            connectionSucceeded && currentStep.rawValue > step.rawValue
        case .complete:
            isSetupComplete
        }
    }

    /// The app UI language as an English language name ("Russian"), used as the
    /// default summary output language.
    static func localizedAppLanguageName() -> String? {
        let appLocalization = Bundle.main.preferredLocalizations
            .first { !$0.isEmpty && $0 != "Base" }
        return outputLanguageName(for: appLocalization)
            ?? outputLanguageName(for: Locale.preferredLanguages.first)
    }

    static func outputLanguageName(for identifier: String?) -> String? {
        guard let identifier, !identifier.isEmpty, identifier != "Base" else { return nil }
        let normalizedIdentifier = identifier.replacingOccurrences(of: "_", with: "-")
        let languageCode = Locale(identifier: normalizedIdentifier)
            .language.languageCode?.identifier ?? normalizedIdentifier
        guard let name = Locale(identifier: "en_US_POSIX").localizedString(forLanguageCode: languageCode),
              !name.isEmpty
        else {
            return nil
        }
        return name
    }
}
