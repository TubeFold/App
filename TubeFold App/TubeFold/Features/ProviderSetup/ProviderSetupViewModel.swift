import AppKit
import Combine
import Foundation
import OSLog

/// Actions and state for the provider-setup wizard and Settings screens.
/// Derived display-only properties live in
/// `ProviderSetupViewModel+Presentation.swift`.
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
    @Published private(set) var selectedModel = "gpt-5.6-luna"
    @Published private(set) var outputLanguage = ProviderSetupViewModel.defaultOutputLanguage
    @Published var outputLanguageDraft = ProviderSetupViewModel.defaultOutputLanguage
    @Published private(set) var usage: UsageSummary?
    @Published private(set) var telegraphPages: [TelegraphPage]?
    @Published private(set) var telegraphAccount: String?
    @Published private(set) var providerUpdateCommandCopied = false
    /// Defaults to `true` so we never flash an install pitch before the first
    /// status check resolves; flips to the real value once the backend answers.
    @Published private(set) var extensionConnected = true

    static var defaultOutputLanguage: String {
        localizedAppLanguageName() ?? backendDefaultOutputLanguage
    }

    private static let backendDefaultOutputLanguage = "English"
    static let codexCLIInstallCommand = "curl -fsSL https://chatgpt.com/codex/install.sh | sh"
    static let codexCLIUpdateCommand = "codex update"
    static let codexCLIInstallGuideURL = URL(string: "https://developers.openai.com/codex/cli")!

    private let service = ProviderSetupService()
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "TubeFold", category: "ProviderSetup")
    private var providerUpdateCommandCopiedTask: Task<Void, Never>?

    var hasInstallationFailure: Bool {
        guard let status = installationResult?.status else { return false }
        return status != "installed"
    }

    var hasConnectionFailure: Bool {
        guard let status = connectionResult?.status else { return false }
        return status != "success"
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
        await refreshTelegraphPages()
    }

    /// Fetch the token-usage summary without blocking the UI with the busy spinner.
    /// Failures leave the previous value in place (the panel just shows stale/empty data).
    func refreshUsage() async {
        guard let summary = try? await service.loadUsage() else { return }
        usage = summary
    }

    /// Fetch the list of articles published to Telegraph. Failures (offline,
    /// Telegraph down) keep the previous value so the card never flashes empty.
    func refreshTelegraphPages() async {
        guard let response = try? await service.loadTelegraphPages() else { return }
        telegraphPages = response.pages
        telegraphAccount = response.account
    }

    /// Replace the Telegraph account with a fresh one; the article list
    /// reloads empty and future publishes create pages under the new account.
    func regenerateTelegraphAccount() async {
        do {
            _ = try await service.regenerateTelegraphAccount()
            await refreshTelegraphPages()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Best-effort check of whether the companion Chrome extension is installed.
    /// A failure (e.g. older backend without the endpoint) leaves the prior value,
    /// so we never spuriously start nagging.
    func refreshExtensionStatus() async {
        guard let status = try? await service.loadExtensionStatus() else { return }
        extensionConnected = status.connected
    }

    /// Re-check the installed binary and the latest stable Codex release when
    /// Settings is opened. Network failures never turn a healthy installation
    /// into a warning.
    func refreshProviderInstallation() async {
        guard let path = setupState?.executablePath(for: selectedProviderID),
              let result = try? await service.detect(provider: selectedProviderID, path: path)
        else {
            return
        }
        installationResult = result
    }

    func copyProviderUpdateCommand() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(Self.codexCLIUpdateCommand, forType: .string)
        providerUpdateCommandCopiedTask?.cancel()
        providerUpdateCommandCopied = true
        providerUpdateCommandCopiedTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            self?.providerUpdateCommandCopied = false
        }
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
}

// MARK: - Private plumbing

private extension ProviderSetupViewModel {
    func runBusy(_ message: String, operation: () async throws -> Void) async {
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

    func resetLoadedState() {
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

    func configureStep(from state: ProviderSetupState, reason: String, allowBackward: Bool = true) {
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

    func setCurrentStep(_ step: SetupStep, reason: String, allowBackward: Bool = true) {
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

    func configureModelSettings(from state: ProviderSetupState) {
        selectedModel = state.model(for: selectedProviderID) ?? CodexModelOption.defaultModel(for: selectedProviderID)
    }

    func applyOutputLanguage(from state: ProviderSetupState) {
        let backendValue = state.outputLanguage ?? Self.backendDefaultOutputLanguage
        let shouldUseAppDefault = !state.providerSetupCompleted
            && state.outputLanguageConfigured != true
            && backendValue == Self.backendDefaultOutputLanguage
        let value = shouldUseAppDefault ? Self.defaultOutputLanguage : backendValue
        outputLanguage = value
        outputLanguageDraft = value
    }

    @discardableResult
    func persistOutputLanguage(_ value: String) async -> Bool {
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

    func saveOutputLanguageAndContinue() async {
        guard await persistOutputLanguage(outputLanguageDraft) else { return }
        setCurrentStep(.beforeBegin, reason: "advance.outputLanguage.saved")
    }

    func saveModelSettings() async {
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
}
