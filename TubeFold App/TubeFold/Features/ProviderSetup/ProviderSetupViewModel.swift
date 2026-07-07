import AppKit
import Combine
import Foundation
import OSLog

@MainActor
final class ProviderSetupViewModel: ObservableObject {
    @Published private(set) var currentStep: SetupStep = .welcome
    @Published private(set) var setupState: ProviderSetupState?
    @Published private(set) var installationResult: InstallationResult?
    @Published private(set) var connectionResult: ConnectionTestResult?
    @Published private(set) var isBusy = false
    @Published private(set) var busyMessage = ""
    @Published private(set) var errorMessage: String?
    @Published private(set) var hasLoadedState = false
    @Published private(set) var apiReachable = false
    @Published private(set) var selectedProviderID = "codex"
    @Published private(set) var availableProviders: [ProviderInfo] = ProviderInfo.defaults
    @Published private(set) var modelOptions: [CodexModelOption] = CodexModelOption.defaultModelOptions
    @Published private(set) var selectedModel = "gpt-5.4-mini"
    @Published private(set) var outputLanguage = ProviderSetupViewModel.defaultOutputLanguage
    @Published var outputLanguageDraft = ProviderSetupViewModel.defaultOutputLanguage
    @Published private(set) var usage: UsageSummary?
    /// Defaults to `true` so we never flash an install pitch before the first
    /// status check resolves; flips to the real value once the backend answers.
    @Published private(set) var extensionConnected = true

    static var defaultOutputLanguage: String {
        localizedAppLanguageName() ?? backendDefaultOutputLanguage
    }

    private static let backendDefaultOutputLanguage = "English"

    private let service = ProviderSetupService()
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "TubeFold", category: "ProviderSetup")

    var providerDisplayName: String {
        availableProviders.first { $0.id == selectedProviderID }?.displayName
            ?? (selectedProviderID == "claude" ? "Claude Code CLI" : "Codex CLI")
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
        installationResult?.version ?? setupState?.version(for: selectedProviderID) ?? "Unknown version"
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

    var installationDetails: [String] {
        guard let result = installationResult else { return [] }
        var lines = result.checkedPaths.map { "checked: \($0)" }
        lines.append(contentsOf: result.details.formattedLines)
        return lines
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

    func loadState() async {
        var lastAutomaticallyConfiguredStep = currentStep
        await runBusy("Starting TubeFold") {
            let response = try await service.loadSetup()
            let state = response.state
            selectedProviderID = state.provider
            availableProviders = response.providers
            modelOptions = response.modelOptions
            setupState = state
            configureModelSettings(from: state)
            applyOutputLanguage(from: state)
            apiReachable = true
            if currentStep == lastAutomaticallyConfiguredStep {
                configureStep(from: state, reason: "loadState.initial", allowBackward: false)
                lastAutomaticallyConfiguredStep = currentStep
            }

            if let executablePath = state.executablePath(for: selectedProviderID) {
                let result = try await service.detect(provider: selectedProviderID, path: executablePath)
                installationResult = result
                setupState = try await service.loadState()
                if let setupState {
                    configureModelSettings(from: setupState)
                    if currentStep == lastAutomaticallyConfiguredStep {
                        configureStep(from: setupState, reason: "loadState.afterDetect", allowBackward: false)
                    }
                }
            }

            hasLoadedState = true
        }
        await refreshUsage()
        await refreshExtensionStatus()
    }

    /// Fetch the token-usage summary without blocking the UI with the busy spinner.
    /// Failures leave the previous value in place (the panel just shows stale/empty data).
    func refreshUsage() async {
        guard let summary = try? await service.loadUsage() else { return }
        usage = summary
    }

    /// Best-effort check of whether the companion Chrome extension is installed.
    /// A failure (e.g. older backend without the endpoint) leaves the prior value,
    /// so we never spuriously start nagging.
    func refreshExtensionStatus() async {
        guard let status = try? await service.loadExtensionStatus() else { return }
        extensionConnected = status.connected
    }

    func resetData() async {
        await runBusy("Clearing all data") {
            _ = try await service.resetData()
            usage = try? await service.loadUsage()
        }
    }

    func resetFirstRunState(quitAfterReset: Bool = false) async {
        var didReset = false
        await runBusy("Resetting first-run state") {
            _ = try await service.resetFirstRunState()
            AppSettings.shared.resetForFirstRunTesting()
            resetLoadedState()
            didReset = true
        }
        guard didReset else { return }
        if quitAfterReset {
            NSApp.terminate(nil)
            return
        }
        await loadState()
    }

    func selectProvider(_ provider: String) async {
        guard provider != selectedProviderID else { return }
        let stepBeforeSelection = currentStep
        await runBusy("Switching provider") {
            let response = try await service.selectProvider(provider)
            selectedProviderID = response.provider
            setupState = response.state
            availableProviders = response.providers
            modelOptions = response.modelOptions
            installationResult = nil
            connectionResult = nil
            configureModelSettings(from: response.state)
            apiReachable = true

            if let executablePath = response.state.executablePath(for: selectedProviderID) {
                installationResult = try await service.detect(provider: selectedProviderID, path: executablePath)
                setupState = try await service.loadState()
            }

            if stepBeforeSelection == .complete {
                configureStep(from: setupState ?? response.state, reason: "selectProvider.complete")
            } else {
                setCurrentStep(stepBeforeSelection, reason: "selectProvider.preserveStep")
            }
        }
    }

    func prepareCurrentStepIfNeeded() async {
        guard currentStep == .checkInstallation else { return }
        guard installationResult == nil, !isBusy else { return }
        await detectInstallation(path: setupState?.executablePath(for: selectedProviderID))
    }

    func advance() async {
        switch currentStep {
        case .welcome:
            setCurrentStep(.outputLanguage, reason: "advance.welcome")
        case .outputLanguage:
            await saveOutputLanguageAndContinue()
        case .beforeBegin:
            setCurrentStep(.checkInstallation, reason: "advance.beforeBegin")
            await prepareCurrentStepIfNeeded()
        case .checkInstallation:
            if !installationSucceeded {
                await detectInstallation(path: setupState?.executablePath(for: selectedProviderID))
            }
            if installationSucceeded {
                setCurrentStep(.testConnection, reason: "advance.checkInstallation.installed")
            }
        case .testConnection:
            if connectionSucceeded {
                setCurrentStep(.complete, reason: "advance.testConnection.alreadySucceeded")
                return
            }
            if await testConnection() {
                setCurrentStep(.complete, reason: "advance.testConnection.succeeded")
            }
        case .complete:
            await completeSetup()
        }
    }

    func goBack() {
        guard let previous = SetupStep(rawValue: currentStep.rawValue - 1) else { return }
        setCurrentStep(previous, reason: "goBack")
    }

    func startRepair() {
        connectionResult = nil
        setCurrentStep(.checkInstallation, reason: "startRepair")
    }

    func detectInstallation(path: String?) async {
        await runBusy("Checking \(providerDisplayName)") {
            let result = try await service.detect(provider: selectedProviderID, path: path)
            installationResult = result
            apiReachable = true
            if result.status == "installed" {
                setupState = try await service.loadState()
            }
        }
    }

    @discardableResult
    func testConnection() async -> Bool {
        var succeeded = false
        await runBusy("Testing \(providerDisplayName)") {
            let path = installationResult?.path ?? setupState?.executablePath(for: selectedProviderID)
            let result = try await service.test(provider: selectedProviderID, path: path)
            connectionResult = result
            apiReachable = true
            if result.status == "success" {
                succeeded = true
                setupState = try await service.loadState()
            }
        }
        return succeeded
    }

    func completeSetup() async {
        await runBusy("Saving setup") {
            let response = try await service.completeSetup()
            setupState = response.state
            configureModelSettings(from: response.state)
            setCurrentStep(.complete, reason: "completeSetup.saved")
            apiReachable = true
        }
    }

    func updateModel(_ model: String) {
        selectedModel = model
        Task { await saveModelSettings() }
    }

    func saveOutputLanguage() {
        Task { await persistOutputLanguage(outputLanguageDraft) }
    }

    func resetOutputLanguage() {
        outputLanguageDraft = ProviderSetupViewModel.defaultOutputLanguage
        Task { await persistOutputLanguage(outputLanguageDraft) }
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

    private func runBusy(_ message: String, operation: () async throws -> Void) async {
        isBusy = true
        busyMessage = message
        errorMessage = nil
        defer {
            isBusy = false
            busyMessage = ""
        }

        do {
            try await operation()
        } catch {
            apiReachable = false
            errorMessage = error.localizedDescription
        }
    }

    private func resetLoadedState() {
        setCurrentStep(.welcome, reason: "resetLoadedState")
        setupState = nil
        installationResult = nil
        connectionResult = nil
        hasLoadedState = false
        apiReachable = false
        selectedProviderID = "codex"
        availableProviders = ProviderInfo.defaults
        modelOptions = CodexModelOption.defaultModelOptions
        selectedModel = CodexModelOption.defaultModel(for: "codex")
        outputLanguage = Self.defaultOutputLanguage
        outputLanguageDraft = Self.defaultOutputLanguage
        usage = .empty
        extensionConnected = false
    }

    private var hasInstallationFailure: Bool {
        guard let status = installationResult?.status else { return false }
        return status != "installed"
    }

    private var hasConnectionFailure: Bool {
        guard let status = connectionResult?.status else { return false }
        return status != "success"
    }

    private func configureStep(from state: ProviderSetupState, reason: String, allowBackward: Bool = true) {
        let nextStep: SetupStep = if hasInstallationFailure || hasConnectionFailure {
            .checkInstallation
        } else if state.providerSetupCompleted {
            .complete
        } else if state.executablePath(for: selectedProviderID) != nil || state.lastSuccessfulConnectionTest != nil {
            .checkInstallation
        } else {
            .welcome
        }
        setCurrentStep(nextStep, reason: reason, allowBackward: allowBackward)
    }

    private func setCurrentStep(_ step: SetupStep, reason: String, allowBackward: Bool = true) {
        let previous = currentStep
        if !allowBackward, step.rawValue < previous.rawValue {
            logger.info("Step suppressed \(previous.title, privacy: .public) -> \(step.title, privacy: .public)")
            logger.info("Step reason \(reason, privacy: .public)")
            return
        }

        guard previous != step else {
            logger.debug(
                "Provider setup step kept \(step.title, privacy: .public), reason: \(reason, privacy: .public)",
            )
            return
        }

        currentStep = step
        logger.info("Step \(previous.title, privacy: .public) -> \(step.title, privacy: .public)")
        logger.info("Step reason \(reason, privacy: .public)")
    }

    private func configureModelSettings(from state: ProviderSetupState) {
        selectedModel = state.model(for: selectedProviderID) ?? CodexModelOption.defaultModel(for: selectedProviderID)
    }

    private func applyOutputLanguage(from state: ProviderSetupState) {
        let backendValue = state.outputLanguage ?? Self.backendDefaultOutputLanguage
        let shouldUseAppDefault = !state.providerSetupCompleted
            && state.outputLanguageConfigured != true
            && backendValue == Self.backendDefaultOutputLanguage
        let value = shouldUseAppDefault ? Self.defaultOutputLanguage : backendValue
        outputLanguage = value
        outputLanguageDraft = value
    }

    @discardableResult
    private func persistOutputLanguage(_ value: String) async -> Bool {
        var saved = false
        await runBusy("Saving language") {
            let response = try await service.saveOutputLanguage(value)
            setupState = response.state
            applyOutputLanguage(from: response.state)
            apiReachable = true
            saved = true
        }
        return saved
    }

    private func saveOutputLanguageAndContinue() async {
        guard await persistOutputLanguage(outputLanguageDraft) else { return }
        setCurrentStep(.beforeBegin, reason: "advance.outputLanguage.saved")
    }

    private func saveModelSettings() async {
        await runBusy("Saving \(providerDisplayName) settings") {
            // Effort is no longer user-configurable; always request "auto" so the
            // CLI uses each model's default effort. See CLAUDE_/CODEX_ settings.
            let response = try await service.saveModelSettings(
                provider: selectedProviderID,
                model: selectedModel,
                reasoningEffort: "auto",
            )
            setupState = response.state
            modelOptions = response.modelOptions
            configureModelSettings(from: response.state)
            apiReachable = true
        }
    }

    private static func localizedAppLanguageName() -> String? {
        let appLocalization = Bundle.main.preferredLocalizations
            .first { !$0.isEmpty && $0 != "Base" }
        return outputLanguageName(for: appLocalization)
            ?? outputLanguageName(for: Locale.preferredLanguages.first)
    }

    private static func outputLanguageName(for identifier: String?) -> String? {
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
