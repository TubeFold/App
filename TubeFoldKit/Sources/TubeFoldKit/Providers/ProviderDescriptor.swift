import Foundation

/// One selectable model (or effort level) shown in onboarding/settings.
public struct ProviderOption: Sendable, Equatable, Codable {
    public let id: String
    public let label: String

    public init(id: String, label: String) {
        self.id = id
        self.label = label
    }
}

/// Everything provider-specific for a first-class CLI provider.
public struct ProviderDescriptor: Sendable {
    public let id: String
    public let displayName: String
    public let binaryName: String
    /// Expected reply of the connection test.
    public let marker: String
    /// Whether the reply must equal the marker exactly (Codex) or merely
    /// contain it (Claude tends to add pleasantries).
    public let markerExact: Bool
    public let modelOptions: [ProviderOption]
    public let effortOptions: [ProviderOption]
    public let defaultModel: String
    public let defaultEffort: String
    public let homebrewPaths: [String]

    // Provider-prefixed state keys in provider-setup.json (stable across
    // releases so existing installs keep their setup).
    public var pathKey: String { "\(id)ExecutablePath" }
    public var versionKey: String { "\(id)Version" }
    public var modelKey: String { "\(id)Model" }
    public var effortKey: String { "\(id)ReasoningEffort" }
    public var connectedKey: String { "\(id)ConnectedAt" }

    public func validModel(_ value: String?) -> String {
        if let value, modelOptions.contains(where: { $0.id == value }) {
            return value
        }
        return defaultModel
    }

    public func validEffort(_ value: String?) -> String {
        if let value, effortOptions.contains(where: { $0.id == value }) {
            return value
        }
        return defaultEffort
    }

    public func modelDisplayLabel(_ modelID: String) -> String {
        modelOptions.first(where: { $0.id == modelID })?.label ?? modelID
    }

    /// Arguments for the connection-test invocation and whether the reply is
    /// read from stdout (`true`) or from `outputFile` (`false`).
    public func connectionCommand(
        executable: String,
        model: String,
        effort: String,
        workdir: URL,
        outputFile: URL
    ) -> (arguments: [String], readsStdout: Bool) {
        switch id {
        case "claude":
            // Claude Code prints the final message to stdout in --print mode.
            var args = [executable, "--print", "--model", model]
            if !effort.isEmpty, effort != "auto" {
                args += ["--effort", effort]
            }
            args += ["--output-format", "text"]
            return (args, true)
        default:
            // Codex writes its final message to --output-last-message.
            var args = [
                executable,
                "exec",
                "--model", model,
                "--sandbox", "read-only",
                "--cd", workdir.path,
                "--skip-git-repo-check",
                "--ephemeral",
                "--ignore-rules",
                "--color", "never",
                "--output-last-message", outputFile.path,
                "-",
            ]
            if !effort.isEmpty, effort != "auto" {
                args.insert(contentsOf: ["-c", "model_reasoning_effort=\"\(effort)\""], at: 4)
            }
            return (args, false)
        }
    }
}

public enum ProviderDescriptors {
    public static let connectionMarker = "CODEX_CONNECTION_OK"
    public static let claudeConnectionMarker = "CLAUDE_CONNECTION_OK"

    public static let defaultCodexModel = "gpt-5.4-mini"
    public static let defaultClaudeModel = "sonnet"
    public static let defaultEffort = "auto"

    public static let codex = ProviderDescriptor(
        id: "codex",
        displayName: "Codex CLI",
        binaryName: "codex",
        marker: connectionMarker,
        markerExact: true,
        modelOptions: [
            ProviderOption(id: "gpt-5.6-sol", label: "GPT-5.6 Sol"),
            ProviderOption(id: "gpt-5.6-terra", label: "GPT-5.6 Terra"),
            ProviderOption(id: "gpt-5.6-luna", label: "GPT-5.6 Luna"),
            ProviderOption(id: "gpt-5.5", label: "GPT-5.5"),
            ProviderOption(id: "gpt-5.4", label: "GPT-5.4"),
            ProviderOption(id: "gpt-5.4-mini", label: "GPT-5.4 Mini"),
        ],
        // "minimal" is deliberately omitted: the Codex CLI injects the
        // web_search and image_gen tools server-side for these models, and the
        // API rejects that combination with reasoning.effort 'minimal'
        // (HTTP 400), so every job fails. "auto" is a TubeFold-only sentinel:
        // the provider omits model_reasoning_effort entirely and lets the
        // Codex CLI use the model's default.
        effortOptions: [
            ProviderOption(id: "auto", label: "Auto"),
            ProviderOption(id: "low", label: "Low"),
            ProviderOption(id: "medium", label: "Medium"),
            ProviderOption(id: "high", label: "High"),
            ProviderOption(id: "xhigh", label: "xhigh"),
        ],
        defaultModel: defaultCodexModel,
        defaultEffort: defaultEffort,
        homebrewPaths: [
            "/opt/homebrew/bin/codex",
            "/usr/local/bin/codex",
            NSString(string: "~/.local/bin/codex").expandingTildeInPath,
        ]
    )

    public static let claude = ProviderDescriptor(
        id: "claude",
        displayName: "Claude Code CLI",
        binaryName: "claude",
        marker: claudeConnectionMarker,
        markerExact: false,
        modelOptions: [
            ProviderOption(id: "opus", label: "Opus 4.8"),
            ProviderOption(id: "sonnet", label: "Sonnet 5"),
            ProviderOption(id: "haiku", label: "Haiku 4.5"),
        ],
        // Effort ids mirror the Claude Code CLI's own `--effort` levels
        // verbatim; "auto" is the same TubeFold-only sentinel as for Codex.
        effortOptions: [
            ProviderOption(id: "auto", label: "Auto"),
            ProviderOption(id: "low", label: "Low"),
            ProviderOption(id: "medium", label: "Medium"),
            ProviderOption(id: "high", label: "High"),
            ProviderOption(id: "xhigh", label: "xhigh"),
            ProviderOption(id: "max", label: "max"),
        ],
        defaultModel: defaultClaudeModel,
        defaultEffort: defaultEffort,
        homebrewPaths: [
            "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude",
            NSString(string: "~/.local/bin/claude").expandingTildeInPath,
            NSString(string: "~/.claude/local/claude").expandingTildeInPath,
        ]
    )

    public static let all: [ProviderDescriptor] = [codex, claude]
    public static let defaultProviderID = codex.id

    public static func descriptor(for id: String?) -> ProviderDescriptor? {
        all.first(where: { $0.id == id })
    }
}
