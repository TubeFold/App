import Foundation

struct ProviderSetupState: Codable {
    let selectedProviderID: String?
    let codexExecutablePath: String?
    let codexVersion: String?
    let codexModel: String?
    let codexReasoningEffort: String?
    let outputLanguage: String?
    let providerSetupCompleted: Bool
    let lastSuccessfulConnectionTest: String?
    let preferredOutputDirectory: String?
}

struct ProviderSetupResponse: Decodable {
    let provider: String
    let state: ProviderSetupState
    let modelOptions: [CodexModelOption]
    let reasoningEffortOptions: [CodexModelOption]

    enum CodingKeys: String, CodingKey {
        case provider
        case state
        case modelOptions
        case reasoningEffortOptions
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        provider = try container.decode(String.self, forKey: .provider)
        state = try container.decode(ProviderSetupState.self, forKey: .state)
        modelOptions = try container.decodeIfPresent([CodexModelOption].self, forKey: .modelOptions)
            ?? CodexModelOption.defaultModelOptions
        reasoningEffortOptions = try container.decodeIfPresent([CodexModelOption].self, forKey: .reasoningEffortOptions)
            ?? CodexModelOption.defaultReasoningEffortOptions
    }
}

struct CodexModelOption: Decodable, Identifiable, Hashable {
    let id: String
    let label: String
    let description: String

    static let defaultModelOptions: [CodexModelOption] = [
        CodexModelOption(id: "gpt-5.4-mini", label: "GPT-5.4 Mini", description: "Fast, efficient mini model."),
        CodexModelOption(id: "gpt-5.5", label: "GPT-5.5", description: "Recommended Codex model for complex work."),
        CodexModelOption(id: "gpt-5.4", label: "GPT-5.4", description: "Flagship model for professional work.")
    ]

    static let defaultReasoningEffortOptions: [CodexModelOption] = [
        CodexModelOption(id: "minimal", label: "Minimal", description: "Lowest latency where supported."),
        CodexModelOption(id: "low", label: "Low", description: "Fast summaries."),
        CodexModelOption(id: "medium", label: "Medium", description: "Recommended balance."),
        CodexModelOption(id: "high", label: "High", description: "More careful summaries."),
        CodexModelOption(id: "xhigh", label: "Extra High", description: "Hardest jobs.")
    ]
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
    let reasoningEffortOptions: [CodexModelOption]
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
            self = .object(try container.decode([String: JSONValue].self))
        }
    }

    var displayValue: String {
        switch self {
        case .string(let value):
            return value
        case .number(let value):
            return value.rounded() == value ? String(Int(value)) : String(value)
        case .bool(let value):
            return value ? "true" : "false"
        case .object(let value):
            return value
                .sorted { $0.key < $1.key }
                .map { "\($0.key)=\($0.value.displayValue)" }
                .joined(separator: ", ")
        case .array(let value):
            return value.map(\.displayValue).joined(separator: ", ")
        case .null:
            return "null"
        }
    }
}

extension Dictionary where Key == String, Value == JSONValue {
    var formattedLines: [String] {
        sorted { $0.key < $1.key }
            .map { "\($0.key): \($0.value.displayValue)" }
            .filter { !$0.hasSuffix(": ") }
    }
}

struct StringRequest: Encodable {
    let path: String?
}

struct ModelSettingsRequest: Encodable {
    let model: String
    let reasoningEffort: String
}

struct OutputLanguageRequest: Encodable {
    let outputLanguage: String
}
