import Foundation

struct ProviderSetupState: Codable {
    let selectedProviderID: String?
    let codexExecutablePath: String?
    let codexVersion: String?
    let codexModel: String?
    let codexConnectedAt: String?
    let claudeExecutablePath: String?
    let claudeVersion: String?
    let claudeModel: String?
    let claudeConnectedAt: String?
    let outputLanguage: String?
    let outputLanguageConfigured: Bool?
    let providerSetupCompleted: Bool
    let lastSuccessfulConnectionTest: String?
    let preferredOutputDirectory: String?

    var provider: String {
        selectedProviderID ?? "codex"
    }

    func executablePath(for provider: String) -> String? {
        provider == "claude" ? claudeExecutablePath : codexExecutablePath
    }

    func version(for provider: String) -> String? {
        provider == "claude" ? claudeVersion : codexVersion
    }

    func model(for provider: String) -> String? {
        provider == "claude" ? claudeModel : codexModel
    }
}

struct ProviderInfo: Decodable, Identifiable, Hashable {
    let id: String
    let displayName: String
    let configured: Bool
    let executablePath: String?
    let version: String?

    static let defaults: [ProviderInfo] = [
        ProviderInfo(
            id: "codex",
            displayName: "Codex CLI",
            configured: false,
            executablePath: nil,
            version: nil,
        ),
        ProviderInfo(
            id: "claude",
            displayName: "Claude Code CLI",
            configured: false,
            executablePath: nil,
            version: nil,
        ),
    ]
}

struct ProviderSetupResponse: Decodable {
    let provider: String
    let state: ProviderSetupState
    let providers: [ProviderInfo]
    let modelOptions: [CodexModelOption]

    enum CodingKeys: String, CodingKey {
        case provider
        case state
        case providers
        case modelOptions
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        provider = try container.decode(String.self, forKey: .provider)
        state = try container.decode(ProviderSetupState.self, forKey: .state)
        providers = try container.decodeIfPresent([ProviderInfo].self, forKey: .providers)
            ?? ProviderInfo.defaults
        modelOptions = try container.decodeIfPresent([CodexModelOption].self, forKey: .modelOptions)
            ?? CodexModelOption.defaultModelOptions
    }
}

struct ProviderSelectionResult: Decodable {
    let status: String
    let provider: String
    let state: ProviderSetupState
    let providers: [ProviderInfo]
    let modelOptions: [CodexModelOption]

    enum CodingKeys: String, CodingKey {
        case status
        case provider
        case state
        case providers
        case modelOptions
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        status = try container.decode(String.self, forKey: .status)
        provider = try container.decode(String.self, forKey: .provider)
        state = try container.decode(ProviderSetupState.self, forKey: .state)
        providers = try container.decodeIfPresent([ProviderInfo].self, forKey: .providers)
            ?? ProviderInfo.defaults
        modelOptions = try container.decodeIfPresent([CodexModelOption].self, forKey: .modelOptions)
            ?? CodexModelOption.defaultModelOptions
    }
}

struct CodexModelOption: Decodable, Identifiable, Hashable {
    let id: String
    let label: String
    let description: String

    static let defaultModelOptions: [CodexModelOption] = [
        CodexModelOption(id: "gpt-5.4-mini", label: "GPT-5.4 Mini", description: "Fast, efficient mini model."),
        CodexModelOption(id: "gpt-5.5", label: "GPT-5.5", description: "Recommended Codex model for complex work."),
        CodexModelOption(id: "gpt-5.4", label: "GPT-5.4", description: "Flagship model for professional work."),
    ]

    static let defaultClaudeModelOptions: [CodexModelOption] = [
        CodexModelOption(id: "sonnet", label: "Sonnet 5", description: "Recommended balance of quality and speed."),
        CodexModelOption(id: "opus", label: "Opus 4.8", description: "Most capable model for the hardest transcripts."),
        CodexModelOption(id: "haiku", label: "Haiku 4.5", description: "Fastest, most efficient model."),
    ]

    static func defaultModelOptions(for provider: String) -> [CodexModelOption] {
        provider == "claude" ? defaultClaudeModelOptions : defaultModelOptions
    }

    static func defaultModel(for provider: String) -> String {
        provider == "claude" ? "sonnet" : "gpt-5.4-mini"
    }
}

struct InstallationResult: Decodable {
    let status: String
    let provider: String
    let displayName: String?
    let path: String?
    let version: String?
    let checkedPaths: [String]
    let userMessage: String
    let details: [String: JSONValue]
}

struct ConnectionTestResult: Decodable {
    let status: String
    let provider: String
    let userMessage: String
    let details: [String: JSONValue]
}

struct CompleteSetupResult: Decodable {
    let status: String
    let provider: String
    let state: ProviderSetupState
}

struct SaveModelSettingsResult: Decodable {
    let status: String
    let provider: String
    let state: ProviderSetupState
    let modelOptions: [CodexModelOption]
}

struct ResetDataResult: Decodable {
    let status: String
    let removed: [String: Int]
}

enum JSONValue: Decodable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: JSONValue])
    case array([JSONValue])
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else {
            self = try .object(container.decode([String: JSONValue].self))
        }
    }

    var displayValue: String {
        switch self {
        case let .string(value):
            value
        case let .number(value):
            value.rounded() == value ? String(Int(value)) : String(value)
        case let .bool(value):
            value ? "true" : "false"
        case let .object(value):
            value
                .sorted { $0.key < $1.key }
                .map { "\($0.key)=\($0.value.displayValue)" }
                .joined(separator: ", ")
        case let .array(value):
            value.map(\.displayValue).joined(separator: ", ")
        case .null:
            "null"
        }
    }
}

extension [String: JSONValue] {
    var formattedLines: [String] {
        sorted { $0.key < $1.key }
            .map { "\($0.key): \($0.value.displayValue)" }
            .filter { !$0.hasSuffix(": ") }
    }
}

struct UsageSummary: Decodable {
    let totalTokens: Int
    let byProvider: [String: ProviderUsage]

    struct ProviderUsage: Decodable {
        let jobs: Int
        let inputTokens: Int
        let outputTokens: Int
        let totalTokens: Int
        let costUsd: Double?
    }

    var sortedProviders: [(name: String, usage: ProviderUsage)] {
        byProvider
            .sorted { $0.value.totalTokens > $1.value.totalTokens }
            .map { (name: $0.key, usage: $0.value) }
    }

    static let empty = UsageSummary(totalTokens: 0, byProvider: [:])
}

struct StringRequest: Encodable {
    let path: String?
}

struct ModelSettingsRequest: Encodable {
    let model: String
    let reasoningEffort: String
}

struct SelectProviderRequest: Encodable {
    let provider: String
}

struct OutputLanguageRequest: Encodable {
    let outputLanguage: String
}
