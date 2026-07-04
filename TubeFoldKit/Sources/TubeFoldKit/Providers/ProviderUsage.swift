import Foundation

/// Token usage for one provider run, parsed in-process from the CLI's JSON
/// output; it travels with the run result.
///
/// Capture is best-effort: `nil` usage (fake provider, CLI format change)
/// means no usage recorded, never a failed job.
public struct ProviderUsage: Sendable, Equatable, Codable {
    public let provider: String
    public let inputTokens: Int
    public let outputTokens: Int
    public let totalTokens: Int
    public let reasoningOutputTokens: Int?
    public let cachedInputTokens: Int?
    public let cacheCreationInputTokens: Int?
    public let cacheReadInputTokens: Int?
    public let costUSD: Double?

    enum CodingKeys: String, CodingKey {
        case provider
        case inputTokens = "input_tokens"
        case outputTokens = "output_tokens"
        case totalTokens = "total_tokens"
        case reasoningOutputTokens = "reasoning_output_tokens"
        case cachedInputTokens = "cached_input_tokens"
        case cacheCreationInputTokens = "cache_creation_input_tokens"
        case cacheReadInputTokens = "cache_read_input_tokens"
        case costUSD = "cost_usd"
    }

    public init(
        provider: String,
        inputTokens: Int,
        outputTokens: Int,
        totalTokens: Int,
        reasoningOutputTokens: Int? = nil,
        cachedInputTokens: Int? = nil,
        cacheCreationInputTokens: Int? = nil,
        cacheReadInputTokens: Int? = nil,
        costUSD: Double? = nil
    ) {
        self.provider = provider
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.totalTokens = totalTokens
        self.reasoningOutputTokens = reasoningOutputTokens
        self.cachedInputTokens = cachedInputTokens
        self.cacheCreationInputTokens = cacheCreationInputTokens
        self.cacheReadInputTokens = cacheReadInputTokens
        self.costUSD = costUSD
    }
}

enum UsageParsing {
    private static func asInt(_ value: Any?) -> Int {
        switch value {
        case let intValue as Int: intValue
        case let doubleValue as Double: Int(doubleValue)
        case let stringValue as String: Int(stringValue) ?? 0
        default: 0
        }
    }

    /// Extract usage from a `claude --print --output-format json` result object.
    ///
    /// Claude's accounting splits the prompt into fresh vs. cached input
    /// tokens; we surface the parts and report total = input + output (cache
    /// reads are not billed as fresh usage). Returns `nil` when no usage
    /// block is present.
    static func claudeUsage(fromResultObject resultObject: [String: Any]) -> ProviderUsage? {
        guard let usage = resultObject["usage"] as? [String: Any] else {
            return nil
        }
        let inputTokens = asInt(usage["input_tokens"])
        let outputTokens = asInt(usage["output_tokens"])
        let cost = resultObject["total_cost_usd"]
        return ProviderUsage(
            provider: "claude",
            inputTokens: inputTokens,
            outputTokens: outputTokens,
            totalTokens: inputTokens + outputTokens,
            cacheCreationInputTokens: asInt(usage["cache_creation_input_tokens"]),
            cacheReadInputTokens: asInt(usage["cache_read_input_tokens"]),
            costUSD: (cost as? Double) ?? (cost as? Int).map(Double.init)
        )
    }

    /// Extract token usage from `codex exec --json` JSONL output.
    ///
    /// Codex's JSONL schema changed across CLI versions, so we handle both:
    ///
    /// - **Current** (codex-cli >= ~0.40): a flat `turn.completed` event
    ///   carrying `usage` (`input_tokens`/`cached_input_tokens`/
    ///   `output_tokens`/`reasoning_output_tokens`).
    /// - **Legacy**: an `event_msg` whose `payload.type == "token_count"`
    ///   holds `info.total_token_usage`.
    ///
    /// The **last** matching event of either kind wins (cumulative totals for
    /// the run). The current format is preferred when both appear. Returns
    /// `nil` when neither is found.
    static func codexUsage(fromJSONL stdout: String) -> ProviderUsage? {
        var lastTurnUsage: [String: Any]?
        var lastTokenCount: [String: Any]?

        for rawLine in stdout.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty,
                  let parsed = try? JSONSerialization.jsonObject(with: Data(line.utf8)),
                  let event = parsed as? [String: Any] else {
                continue
            }
            if event["type"] as? String == "turn.completed", let usage = event["usage"] as? [String: Any] {
                lastTurnUsage = usage
                continue
            }
            if let payload = event["payload"] as? [String: Any], payload["type"] as? String == "token_count" {
                lastTokenCount = payload
            }
        }

        if let usage = lastTurnUsage {
            let inputTokens = asInt(usage["input_tokens"])
            let outputTokens = asInt(usage["output_tokens"])
            // No total in the new schema, and cached input isn't billed as
            // fresh usage — report total = input + output (matches Claude).
            return ProviderUsage(
                provider: "codex",
                inputTokens: inputTokens,
                outputTokens: outputTokens,
                totalTokens: inputTokens + outputTokens,
                reasoningOutputTokens: asInt(usage["reasoning_output_tokens"]),
                cachedInputTokens: asInt(usage["cached_input_tokens"])
            )
        }

        guard let payload = lastTokenCount else {
            return nil
        }
        let info = payload["info"] as? [String: Any] ?? [:]
        let total = info["total_token_usage"] as? [String: Any] ?? [:]
        return ProviderUsage(
            provider: "codex",
            inputTokens: asInt(total["input_tokens"]),
            outputTokens: asInt(total["output_tokens"]),
            totalTokens: asInt(total["total_tokens"]),
            reasoningOutputTokens: asInt(total["reasoning_output_tokens"])
        )
    }
}
