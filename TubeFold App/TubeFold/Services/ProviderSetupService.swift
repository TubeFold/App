import Foundation
import TubeFoldKit

/// Provider onboarding/settings — direct async calls into the in-process
/// backend (no HTTP). Response models keep the old API payload shapes.
struct ProviderSetupService {
    private var backend: TubeFoldBackend {
        TubeFoldBackend.shared
    }

    func loadSetup() async throws -> ProviderSetupResponse {
        try await mapErrors {
            try TubeFoldBackend.decode(backend.providerSetupPayload())
        }
    }

    func loadState() async throws -> ProviderSetupState {
        try await loadSetup().state
    }

    func selectProvider(_ provider: String) async throws -> ProviderSelectionResult {
        try await mapErrors {
            try TubeFoldBackend.decode(backend.selectProvider(provider))
        }
    }

    func detect(provider: String, path: String?) async throws -> InstallationResult {
        try await mapErrors {
            try await TubeFoldBackend.decode(backend.detectProviderInstallation(providerID: provider, path: path))
        }
    }

    func test(provider: String, path: String?) async throws -> ConnectionTestResult {
        try await mapErrors {
            try await TubeFoldBackend.decode(backend.testProviderConnection(providerID: provider, path: path))
        }
    }

    func completeSetup() async throws -> CompleteSetupResult {
        try await mapErrors {
            try TubeFoldBackend.decode(backend.completeProviderSetup())
        }
    }

    func saveModelSettings(
        provider: String,
        model: String,
        reasoningEffort: String,
    ) async throws -> SaveModelSettingsResult {
        try await mapErrors {
            try TubeFoldBackend.decode(backend.saveModelSettings(
                providerID: provider,
                model: model,
                reasoningEffort: reasoningEffort,
            ))
        }
    }

    func loadUsage() async throws -> UsageSummary {
        try await mapErrors {
            try await TubeFoldBackend.decode(backend.usagePayload())
        }
    }

    func loadExtensionStatus() async throws -> ExtensionStatus {
        try await mapErrors {
            try await TubeFoldBackend.decode(backend.extensionStatusPayload())
        }
    }

    func saveOutputLanguage(_ outputLanguage: String) async throws -> SaveModelSettingsResult {
        try await mapErrors {
            try TubeFoldBackend.decode(backend.saveOutputLanguage(outputLanguage))
        }
    }

    func resetData() async throws -> ResetDataResult {
        try await mapErrors {
            let removed = try await backend.resetAllData()
            return ResetDataResult(status: "reset", removed: removed)
        }
    }

    func resetFirstRunState() async throws -> ResetDataResult {
        try await mapErrors {
            let removed = try await backend.resetFirstRunState()
            return ResetDataResult(status: "reset", removed: removed)
        }
    }

    private func mapErrors<T>(_ body: () async throws -> T) async throws -> T {
        do {
            return try await body()
        } catch let error as BackendAPIError {
            throw ProviderSetupAPIError(message: error.message)
        } catch let error as ProviderSetupAPIError {
            throw error
        } catch {
            throw ProviderSetupAPIError(message: error.localizedDescription)
        }
    }
}

struct ProviderSetupAPIError: LocalizedError {
    let message: String

    var errorDescription: String? {
        message
    }
}
