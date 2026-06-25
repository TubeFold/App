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
    @Published private(set) var modelOptions: [CodexModelOption] = CodexModelOption.defaultModelOptions
    @Published private(set) var reasoningEffortOptions: [CodexModelOption] = CodexModelOption.defaultReasoningEffortOptions
    @Published private(set) var selectedCodexModel = "gpt-5.4-mini"
    @Published private(set) var selectedReasoningEffort = "medium"

    private let service = ProviderSetupService()

    var isSetupComplete: Bool {
        setupState?.providerSetupCompleted == true && !hasInstallationFailure && !hasConnectionFailure
    }

    var shouldPresentSetupOnLaunch: Bool {
        hasLoadedState && setupState?.providerSetupCompleted != true
    }

    var requiresCodexRepair: Bool {
        hasLoadedState && apiReachable && (hasInstallationFailure || hasConnectionFailure)
    }

    var installationSucceeded: Bool {
        installationResult?.status == "installed"
    }

    var connectionSucceeded: Bool {
        guard !hasInstallationFailure, !hasConnectionFailure else { return false }
        return connectionResult?.status == "success" || setupState?.lastSuccessfulConnectionTest != nil || isSetupComplete
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
        if let version = setupState?.codexVersion, !version.isEmpty {
            return "Needs check: \(version)"
        }
        if setupState?.codexExecutablePath != nil {
            return "Needs check"
        }
        return "Not configured"
    }

    var codexVersionSummary: String {
        installationResult?.version ?? setupState?.codexVersion ?? "Unknown version"
    }

    var codexModelSummary: String {
        let model = selectedModelOption?.label ?? selectedCodexModel
        let effort = selectedReasoningEffortOption?.label ?? selectedReasoningEffort
        return "\(model) • \(effort)"
    }

    var selectedModelOption: CodexModelOption? {
        modelOptions.first { $0.id == selectedCodexModel }
    }

    var selectedReasoningEffortOption: CodexModelOption? {
        reasoningEffortOptions.first { $0.id == selectedReasoningEffort }
    }

    var codexInstalled: Bool {
        installationSucceeded || (isSetupComplete && setupState?.codexExecutablePath != nil)
    }

    var codexSignedIn: Bool {
        connectionSucceeded
    }

    var codexReady: Bool {
        isSetupComplete
    }

    var setupButtonTitle: String {
        requiresCodexRepair ? "Repair Codex" : "Codex Setup"
    }

    var outputDirectorySummary: String {
        setupState?.preferredOutputDirectory ?? "Default summaries folder"
    }

    var primaryButtonTitle: String {
        switch currentStep {
        case .beforeBegin:
            return "Next"
        case .checkInstallation:
            return installationSucceeded ? "Next" : "Check Codex"
        case .testConnection:
            return connectionSucceeded ? "Next" : "Test Codex"
        case .complete:
            return "Complete Setup"
        }
    }

    var primaryButtonSystemImage: String {
        switch currentStep {
        case .beforeBegin:
            return "chevron.right"
        case .checkInstallation:
            return installationSucceeded ? "chevron.right" : "arrow.clockwise"
        case .testConnection:
            return connectionSucceeded ? "chevron.right" : "bolt.fill"
        case .complete:
            return "checkmark.circle.fill"
        }
    }

    var canAdvance: Bool {
        switch currentStep {
        case .beforeBegin, .checkInstallation, .complete:
            return true
        case .testConnection:
            return installationSucceeded || connectionSucceeded
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
            ?? setupState?.codexExecutablePath
            ?? "YouTube Brain will look for Codex automatically. You can also choose it manually."
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
            ?? "Run a quick Codex request to confirm this Mac is signed in."
    }

    var connectionDetails: [String] {
        connectionResult?.details.formattedLines ?? []
    }

    func loadState() async {
        await runBusy("Starting YouTube Brain") {
            let response = try await service.loadSetup()
            let state = response.state
            modelOptions = response.modelOptions
            reasoningEffortOptions = response.reasoningEffortOptions
            setupState = state
            configureModelSettings(from: state)
            apiReachable = true
            configureStep(from: state)

            if let codexPath = state.codexExecutablePath {
                let result = try await service.detectCodex(path: codexPath)
                installationResult = result
                setupState = try await service.loadState()
                if let setupState {
                    configureModelSettings(from: setupState)
                    configureStep(from: setupState)
                }
            }

            hasLoadedState = true
        }
    }

    func prepareCurrentStepIfNeeded() async {
        guard currentStep == .checkInstallation else { return }
        guard installationResult == nil, !isBusy else { return }
        await detectInstallation(path: setupState?.codexExecutablePath)
    }

    func advance() async {
        switch currentStep {
        case .beforeBegin:
            currentStep = .checkInstallation
            await prepareCurrentStepIfNeeded()
        case .checkInstallation:
            if !installationSucceeded {
                await detectInstallation(path: setupState?.codexExecutablePath)
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
        await runBusy("Checking Codex") {
            let result = try await service.detectCodex(path: path)
            installationResult = result
            apiReachable = true
            if result.status == "installed" {
                setupState = try await service.loadState()
            }
        }
    }

    func testConnection() async {
        await runBusy("Testing Codex") {
            let path = installationResult?.path ?? setupState?.codexExecutablePath
            let result = try await service.testCodex(path: path)
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

    func updateCodexModel(_ model: String) {
        selectedCodexModel = model
        Task { await saveModelSettings() }
    }

    func updateReasoningEffort(_ effort: String) {
        selectedReasoningEffort = effort
        Task { await saveModelSettings() }
    }

    func isStepComplete(_ step: SetupStep) -> Bool {
        switch step {
        case .beforeBegin:
            return currentStep.rawValue > step.rawValue || hasLoadedState
        case .checkInstallation:
            return installationSucceeded && currentStep.rawValue > step.rawValue
        case .testConnection:
            return connectionSucceeded && currentStep.rawValue > step.rawValue
        case .complete:
            return isSetupComplete
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
        } else if state.codexExecutablePath != nil || state.lastSuccessfulConnectionTest != nil {
            currentStep = .checkInstallation
        } else {
            currentStep = .beforeBegin
        }
    }

    private func configureModelSettings(from state: ProviderSetupState) {
        selectedCodexModel = state.codexModel ?? CodexModelOption.defaultModelOptions[0].id
        selectedReasoningEffort = state.codexReasoningEffort ?? "medium"
    }

    private func saveModelSettings() async {
        await runBusy("Saving Codex settings") {
            let response = try await service.saveModelSettings(
                model: selectedCodexModel,
                reasoningEffort: selectedReasoningEffort
            )
            setupState = response.state
            modelOptions = response.modelOptions
            reasoningEffortOptions = response.reasoningEffortOptions
            configureModelSettings(from: response.state)
            apiReachable = true
        }
    }

}
