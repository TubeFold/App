import Foundation
import Testing

@testable import TubeFoldKit

// Usage parsing for both Codex JSONL schemas and the Claude result object.
@Suite struct ProviderUsageTests {
    private func claudeResult(_ json: String) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any] ?? [:]
    }

    @Test func claudeExtractsTokensAndCost() {
        let result = claudeResult("""
        {
          "result": "body",
          "usage": {
            "input_tokens": 12,
            "output_tokens": 34,
            "cache_creation_input_tokens": 5,
            "cache_read_input_tokens": 7
          },
          "total_cost_usd": 0.0123
        }
        """)
        let usage = UsageParsing.claudeUsage(fromResultObject: result)
        #expect(usage == ProviderUsage(
            provider: "claude",
            inputTokens: 12,
            outputTokens: 34,
            totalTokens: 46,
            cacheCreationInputTokens: 5,
            cacheReadInputTokens: 7,
            costUSD: 0.0123
        ))
    }

    @Test func claudeMissingUsageReturnsNil() {
        #expect(UsageParsing.claudeUsage(fromResultObject: ["result": "body"]) == nil)
    }

    @Test func codexTurnCompletedUsage() {
        let stdout = """
        {"type":"turn.started"}
        {"type":"turn.completed","usage":{"input_tokens":100,"cached_input_tokens":40,"output_tokens":25,"reasoning_output_tokens":9}}
        """
        let usage = UsageParsing.codexUsage(fromJSONL: stdout)
        #expect(usage == ProviderUsage(
            provider: "codex",
            inputTokens: 100,
            outputTokens: 25,
            totalTokens: 125,
            reasoningOutputTokens: 9,
            cachedInputTokens: 40
        ))
    }

    @Test func codexTurnCompletedPreferredOverLegacyTokenCount() {
        let stdout = """
        {"payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":1,"output_tokens":2,"total_tokens":3}}}}
        {"type":"turn.completed","usage":{"input_tokens":100,"output_tokens":25}}
        """
        let usage = UsageParsing.codexUsage(fromJSONL: stdout)
        #expect(usage?.inputTokens == 100)
        #expect(usage?.totalTokens == 125)
    }

    @Test func codexUsesLastLegacyTokenCount() {
        let stdout = """
        {"payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":1,"output_tokens":2,"reasoning_output_tokens":0,"total_tokens":3}}}}
        {"payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":10,"output_tokens":20,"reasoning_output_tokens":5,"total_tokens":30}}}}
        """
        let usage = UsageParsing.codexUsage(fromJSONL: stdout)
        #expect(usage == ProviderUsage(
            provider: "codex",
            inputTokens: 10,
            outputTokens: 20,
            totalTokens: 30,
            reasoningOutputTokens: 5
        ))
    }

    @Test func codexNoTokenCountReturnsNil() {
        #expect(UsageParsing.codexUsage(fromJSONL: "{\"type\":\"turn.started\"}") == nil)
        #expect(UsageParsing.codexUsage(fromJSONL: "") == nil)
    }

    @Test func codexGarbledLinesAreSkipped() {
        let stdout = """
        not json at all
        {"type":"turn.completed","usage":{"input_tokens":7,"output_tokens":3}}
        {broken
        """
        let usage = UsageParsing.codexUsage(fromJSONL: stdout)
        #expect(usage?.totalTokens == 10)
    }

    @Test func usageJSONUsesSnakeCaseKeys() throws {
        let usage = ProviderUsage(provider: "codex", inputTokens: 1, outputTokens: 2, totalTokens: 3)
        let data = try JSONEncoder().encode(usage)
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(object?["input_tokens"] as? Int == 1)
        #expect(object?["total_tokens"] as? Int == 3)
    }
}

// Provider response parsing and error-stream extraction.
@Suite struct ProviderResponseParsingTests {
    @Test func claudeParsesResultObject() {
        let stdout = """
        {"result": "# Summary\\n\\nBody.", "usage": {"input_tokens": 1, "output_tokens": 2}}
        """
        let (body, usage) = ClaudeProvider.parseResponse(stdout)
        #expect(body == "# Summary\n\nBody.")
        #expect(usage?.totalTokens == 3)
    }

    @Test func claudeNonJSONFallsBackToRawBody() {
        let (body, usage) = ClaudeProvider.parseResponse("plain markdown, not JSON")
        #expect(body == "plain markdown, not JSON")
        #expect(usage == nil)
    }

    @Test func claudeJSONWithoutResultFallsBackToRawBody() {
        let stdout = "{\"something\": \"else\"}"
        let (body, usage) = ClaudeProvider.parseResponse(stdout)
        #expect(body == stdout)
        #expect(usage == nil)
    }

    @Test func codexErrorStreamMessageExtracted() {
        let stdout = """
        {"type":"turn.started"}
        {"type":"error","message":"API 400: model_reasoning_effort invalid"}
        """
        #expect(CodexProvider.errorFromJSONStream(stdout) == "API 400: model_reasoning_effort invalid")
    }

    @Test func codexTurnFailedNestedErrorExtracted() {
        let stdout = """
        {"type":"turn.failed","error":{"message":"quota exceeded"}}
        """
        #expect(CodexProvider.errorFromJSONStream(stdout) == "quota exceeded")
        #expect(CodexProvider.errorFromJSONStream("{\"type\":\"turn.started\"}") == "")
    }

    @Test func failureClassification() {
        #expect(ProviderFailure.classifyCodex("Error: not logged in") == "authorization/login problem")
        #expect(ProviderFailure.classifyCodex("You hit your rate limit") == "rate limit or quota problem")
        #expect(ProviderFailure.classifyClaude("connection refused") == "network problem")
        #expect(ProviderFailure.classifyClaude("something odd") == "see Claude stderr")
    }
}
