import Foundation

/// Runtime configuration for the in-process pipeline — the Swift replacement
/// for `tubefold/config.AppConfig` (HTTP-server fields live with the
/// extension shim instead).
public struct PipelineConfiguration: Sendable {
    /// `~/Library/Application Support/TubeFold/` in production.
    public let dataDirectory: URL
    /// Configured provider id; `codex`/`claude` are first-class (the UI
    /// selection in provider-setup.json overrides between them), anything
    /// else (e.g. `fake`) runs verbatim.
    public let provider: String
    public let providerTimeout: TimeInterval
    /// Prompt template override; `nil` uses the bundled `detailed-summary.md`.
    public let promptTemplateURL: URL?
    /// Directory with custom `providers/<name>.sh` scripts (escape hatch).
    public let providersDirectory: URL?
    /// Fallback output language when provider-setup.json has none.
    public let outputLanguage: String

    public var videosDirectory: URL { dataDirectory.appendingPathComponent("videos") }
    public var jobsDirectory: URL { dataDirectory.appendingPathComponent("jobs") }
    public var logsDirectory: URL { dataDirectory.appendingPathComponent("logs") }

    public init(
        dataDirectory: URL,
        provider: String = "codex",
        providerTimeout: TimeInterval = 900,
        promptTemplateURL: URL? = nil,
        providersDirectory: URL? = nil,
        outputLanguage: String = OutputLanguage.defaultLanguage
    ) {
        self.dataDirectory = dataDirectory
        self.provider = provider
        self.providerTimeout = providerTimeout
        self.promptTemplateURL = promptTemplateURL
        self.providersDirectory = providersDirectory
        self.outputLanguage = outputLanguage
    }

    public static func defaultDataDirectory() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/TubeFold")
    }

    /// The bundled prompt template.
    public func promptTemplate() throws -> String {
        if let promptTemplateURL {
            return try String(contentsOf: promptTemplateURL, encoding: .utf8)
        }
        guard let url = Bundle.module.url(forResource: "detailed-summary", withExtension: "md", subdirectory: "prompts") else {
            throw ProcessingError(
                code: "prompt_failed",
                userMessage: "Could not render prompt.",
                technicalMessage: "Bundled prompt template is missing."
            )
        }
        return try String(contentsOf: url, encoding: .utf8)
    }
}

/// `language (code, auto|manual)` label rendered into the prompt.
public func transcriptLanguageLabel(language: String, languageCode: String, isGenerated: Bool) -> String {
    let language = language.trimmingCharacters(in: .whitespacesAndNewlines)
    let code = languageCode.trimmingCharacters(in: .whitespacesAndNewlines)
    let generated = isGenerated ? "auto" : "manual"
    if !language.isEmpty, !code.isEmpty, language != code {
        return "\(language) (\(code), \(generated))"
    }
    let label = code.isEmpty ? (language.isEmpty ? "unknown" : language) : code
    return "\(label) (\(generated))"
}
