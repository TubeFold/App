import AppKit
import Combine
import Foundation

@MainActor
final class ProviderSetupViewModel: ObservableObject {
    @Published private(set) var currentStep: SetupStep = .beforeBegin
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

    static let defaultOutputLanguage = "English"

    private let service = ProviderSetupService()

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
        hasLoadedState && apiReachable && (hasInstallationFailure || hasConnectionFailure)
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
        setupState?.preferredOutputDirectory ?? "Default summaries folder"
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
        case .beforeBegin:
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
        case .beforeBegin, .checkInstallation, .complete:
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
            configureStep(from: state)

            if let executablePath = state.executablePath(for: selectedProviderID) {
                let result = try await service.detect(provider: selectedProviderID, path: executablePath)
                installationResult = result
                setupState = try await service.loadState()
                if let setupState {
                    configureModelSettings(from: setupState)
                    configureStep(from: setupState)
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

    func selectProvider(_ provider: String) async {
        guard provider != selectedProviderID else { return }
        await runBusy("Switching provider") {
            let response = try await service.selectProvider(provider)
            selectedProviderID = response.provider
            setupState = response.state
            availableProviders = response.providers
            modelOptions = response.modelOptions
            installationResult = nil
            connectionResult = nil
            configureModelSettings(from: response.state)
            configureStep(from: response.state)
            apiReachable = true

            if let executablePath = response.state.executablePath(for: selectedProviderID) {
                installationResult = try await service.detect(provider: selectedProviderID, path: executablePath)
                setupState = try await service.loadState()
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
        case .beforeBegin:
            currentStep = .checkInstallation
            await prepareCurrentStepIfNeeded()
        case .checkInstallation:
            if !installationSucceeded {
                await detectInstallation(path: setupState?.executablePath(for: selectedProviderID))
            }
            if installationSucceeded {
                currentStep = .testConnection
            }
        case .testConnection:
            if !connectionSucceeded {
                await testConnection()
            }
            if connectionSucceeded {
                currentStep = .complete
            }
        case .complete:
            await completeSetup()
        }
    }

    func goBack() {
        guard let previous = SetupStep(rawValue: currentStep.rawValue - 1) else { return }
        currentStep = previous
    }

    func startRepair() {
        connectionResult = nil
        currentStep = .checkInstallation
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

    func testConnection() async {
        await runBusy("Testing \(providerDisplayName)") {
            let path = installationResult?.path ?? setupState?.executablePath(for: selectedProviderID)
            let result = try await service.test(provider: selectedProviderID, path: path)
            connectionResult = result
            apiReachable = true
            if result.status == "success" {
                setupState = try await service.loadState()
            }
        }
    }

    func completeSetup() async {
        await runBusy("Saving setup") {
            let response = try await service.completeSetup()
            setupState = response.state
            configureModelSettings(from: response.state)
            currentStep = .complete
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
        case .beforeBegin:
            currentStep.rawValue > step.rawValue || hasLoadedState
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

    private var hasInstallationFailure: Bool {
        guard let status = installationResult?.status else { return false }
        return status != "installed"
    }

    private var hasConnectionFailure: Bool {
        guard let status = connectionResult?.status else { return false }
        return status != "success"
    }

    private func configureStep(from state: ProviderSetupState) {
        if hasInstallationFailure || hasConnectionFailure {
            currentStep = .checkInstallation
        } else if state.providerSetupCompleted {
            currentStep = .complete
        } else if state.executablePath(for: selectedProviderID) != nil || state.lastSuccessfulConnectionTest != nil {
            currentStep = .checkInstallation
        } else {
            currentStep = .beforeBegin
        }
    }

    private func configureModelSettings(from state: ProviderSetupState) {
        selectedModel = state.model(for: selectedProviderID) ?? CodexModelOption.defaultModel(for: selectedProviderID)
    }

    private func applyOutputLanguage(from state: ProviderSetupState) {
        let value = state.outputLanguage ?? ProviderSetupViewModel.defaultOutputLanguage
        outputLanguage = value
        outputLanguageDraft = value
    }

    private func persistOutputLanguage(_ value: String) async {
        await runBusy("Saving language") {
            let response = try await service.saveOutputLanguage(value)
            setupState = response.state
            applyOutputLanguage(from: response.state)
            apiReachable = true
        }
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
}
