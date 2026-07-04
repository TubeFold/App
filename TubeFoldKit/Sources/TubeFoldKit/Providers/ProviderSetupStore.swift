import Foundation

/// Config-level defaults the store falls back to.
public struct ProviderSetupDefaults: Sendable, Equatable {
    public let codexModel: String
    public let codexReasoningEffort: String
    public let claudeModel: String
    public let claudeReasoningEffort: String
    public let outputLanguage: String
    public let preferredOutputDirectory: String

    public init(
        codexModel: String = "",
        codexReasoningEffort: String = "",
        claudeModel: String = "",
        claudeReasoningEffort: String = "",
        outputLanguage: String = "",
        preferredOutputDirectory: String = ""
    ) {
        self.codexModel = codexModel
        self.codexReasoningEffort = codexReasoningEffort
        self.claudeModel = claudeModel
        self.claudeReasoningEffort = claudeReasoningEffort
        self.outputLanguage = outputLanguage
        self.preferredOutputDirectory = preferredOutputDirectory
    }
}

/// `provider-setup.json` store: one JSON file holding provider setup state.
///
/// The schema and keys are stable across releases, so existing installs keep
/// their setup. Also the app-settings store: holds `outputLanguage`.
/// State only — never credentials or full connection-test output.
public struct ProviderSetupStore: Sendable {
    public let url: URL
    public let defaults: ProviderSetupDefaults

    public init(dataDirectory: URL, defaults: ProviderSetupDefaults = ProviderSetupDefaults()) {
        url = dataDirectory.appendingPathComponent("provider-setup.json")
        self.defaults = defaults
    }

    public func load() -> [String: Any] {
        var state: [String: Any] = [
            "selectedProviderID": ProviderDescriptors.defaultProviderID,
            "codexExecutablePath": NSNull(),
            "codexVersion": NSNull(),
            "codexModel": defaults.codexModel.isEmpty ? ProviderDescriptors.defaultCodexModel : defaults.codexModel,
            "codexReasoningEffort": defaults.codexReasoningEffort.isEmpty
                ? ProviderDescriptors.defaultEffort
                : defaults.codexReasoningEffort,
            "codexConnectedAt": NSNull(),
            "claudeExecutablePath": NSNull(),
            "claudeVersion": NSNull(),
            "claudeModel": defaults.claudeModel.isEmpty ? ProviderDescriptors.defaultClaudeModel : defaults.claudeModel,
            "claudeReasoningEffort": defaults.claudeReasoningEffort.isEmpty
                ? ProviderDescriptors.defaultEffort
                : defaults.claudeReasoningEffort,
            "claudeConnectedAt": NSNull(),
            "outputLanguage": defaults.outputLanguage.isEmpty ? OutputLanguage.defaultLanguage : defaults.outputLanguage,
            "providerSetupCompleted": false,
            "lastSuccessfulConnectionTest": NSNull(),
            "preferredOutputDirectory": defaults.preferredOutputDirectory,
        ]
        if let data = try? Data(contentsOf: url),
           let parsed = try? JSONSerialization.jsonObject(with: data),
           let stored = parsed as? [String: Any] {
            for (key, value) in stored {
                state[key] = value
            }
        }
        return Self.normalize(state)
    }

    static func normalize(_ input: [String: Any]) -> [String: Any] {
        var state = input
        for descriptor in ProviderDescriptors.all {
            state[descriptor.modelKey] = descriptor.validModel(state[descriptor.modelKey] as? String)
            state[descriptor.effortKey] = descriptor.validEffort(state[descriptor.effortKey] as? String)
        }
        if ProviderDescriptors.descriptor(for: state["selectedProviderID"] as? String) == nil {
            state["selectedProviderID"] = ProviderDescriptors.defaultProviderID
        }
        state["outputLanguage"] = OutputLanguage.normalize(state["outputLanguage"] as? String)
        return state
    }

    @discardableResult
    public func save(_ state: [String: Any]) throws -> [String: Any] {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = try JSONSerialization.data(
            withJSONObject: state,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
        try (data + Data("\n".utf8)).write(to: url, options: .atomic)
        return state
    }

    /// Merge changes into the stored state. Pass `NSNull()` to store a JSON null.
    @discardableResult
    public func update(_ changes: [String: Any]) throws -> [String: Any] {
        var state = load()
        for (key, value) in changes {
            state[key] = value
        }
        return try save(state)
    }

    /// Switch the active provider and recompute the global completion flags
    /// from that provider's stored `*ConnectedAt`.
    @discardableResult
    public func select(providerID: String) throws -> [String: Any] {
        let descriptor = ProviderDescriptors.descriptor(for: providerID) ?? ProviderDescriptors.codex
        var state = load()
        let connected = state[descriptor.connectedKey]
        let isConnected = connected != nil && !(connected is NSNull)
        state["selectedProviderID"] = descriptor.id
        state["providerSetupCompleted"] = isConnected
        state["lastSuccessfulConnectionTest"] = isConnected ? (connected ?? NSNull()) : NSNull()
        return try save(state)
    }

    public func selectedProviderID() -> String {
        load()["selectedProviderID"] as? String ?? ProviderDescriptors.defaultProviderID
    }

    public func outputLanguage() -> String {
        OutputLanguage.normalize(load()["outputLanguage"] as? String)
    }
}
