import Foundation
import Testing

@testable import TubeFoldKit

/// Write an executable stub shell script and return its path.
private func writeStubBinary(_ name: String, script: String, in dir: URL) throws -> String {
    let url = dir.appendingPathComponent(name)
    try ("#!/bin/bash\n" + script + "\n").write(to: url, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    return url.path
}

private func makeTempDir() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("tubefoldkit-proc-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

// Provider process behavior, tested against stub `codex`/`claude` binaries.
@Suite struct ProviderRunnerProcessTests {
    @Test func codexWritesBodyAndParsesUsage() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        // Stub codex: reads stdin, writes the last-message file passed after
        // --output-last-message, emits turn.completed usage JSONL on stdout.
        let codex = try writeStubBinary("codex", script: """
        args=("$@")
        out=""
        for ((i=0; i<${#args[@]}; i++)); do
          if [[ "${args[$i]}" == "--output-last-message" ]]; then
            out="${args[$((i+1))]}"
          fi
        done
        cat > /dev/null
        printf '# Summary\\n\\nGenerated body.\\n' > "$out"
        echo '{"type":"turn.completed","usage":{"input_tokens":11,"output_tokens":22,"cached_input_tokens":3,"reasoning_output_tokens":4}}'
        """, in: dir)

        let provider = CodexProvider(executablePath: codex)
        let result = try await provider.generateSummary(
            prompt: "PROMPT",
            settings: ProviderRunSettings(model: "gpt-5.4-mini", reasoningEffort: "auto", timeout: 30)
        )
        #expect(result.markdownBody.contains("Generated body."))
        #expect(result.usage == ProviderUsage(
            provider: "codex",
            inputTokens: 11,
            outputTokens: 22,
            totalTokens: 33,
            reasoningOutputTokens: 4,
            cachedInputTokens: 3
        ))
    }

    @Test func codexFailureSurfacesStreamError() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let codex = try writeStubBinary("codex", script: """
        cat > /dev/null
        echo '{"type":"error","message":"API says no"}'
        exit 1
        """, in: dir)

        let provider = CodexProvider(executablePath: codex)
        do {
            _ = try await provider.generateSummary(prompt: "PROMPT", settings: ProviderRunSettings(timeout: 30))
            Issue.record("expected processFailed")
        } catch let ProviderRunError.processFailed(exitCode, _, stderr) {
            #expect(exitCode == 1)
            #expect(stderr.contains("API says no"))
        }
    }

    @Test func codexFailureExtractsNestedErrorFromStderr() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let providerMessage = """
        The 'gpt-5.6-sol' model requires a newer version of Codex. Please upgrade to the latest app or CLI and try again.
        """
        let codex = try writeStubBinary("codex", script: """
        cat > /dev/null
        cat >&2 <<'JSON'
        {"type":"error","status":400,"error":{"type":"invalid_request_error","message":"\(providerMessage)"}}
        JSON
        exit 1
        """, in: dir)

        let provider = CodexProvider(executablePath: codex)
        do {
            _ = try await provider.generateSummary(prompt: "PROMPT", settings: ProviderRunSettings(timeout: 30))
            Issue.record("expected processFailed")
        } catch let ProviderRunError.processFailed(_, _, stderr) {
            #expect(stderr.components(separatedBy: .newlines).first == providerMessage)
            #expect(ProviderFailure.userMessage(providerID: "codex", stderr: stderr) == providerMessage)
        }
    }

    @Test func codexAutoEffortOmitsConfigFlag() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        // Stub records its argv, then succeeds.
        let argsFile = dir.appendingPathComponent("args.txt")
        let codex = try writeStubBinary("codex", script: """
        printf '%s\\n' "$@" > "\(argsFile.path)"
        args=("$@")
        for ((i=0; i<${#args[@]}; i++)); do
          if [[ "${args[$i]}" == "--output-last-message" ]]; then
            printf 'body body body body body\\n' > "${args[$((i+1))]}"
          fi
        done
        cat > /dev/null
        """, in: dir)

        let provider = CodexProvider(executablePath: codex)

        _ = try await provider.generateSummary(
            prompt: "P",
            settings: ProviderRunSettings(model: "gpt-5.4-mini", reasoningEffort: "auto", timeout: 30)
        )
        var recorded = try String(contentsOf: argsFile, encoding: .utf8)
        #expect(!recorded.contains("model_reasoning_effort"))

        _ = try await provider.generateSummary(
            prompt: "P",
            settings: ProviderRunSettings(model: "gpt-5.4-mini", reasoningEffort: "high", timeout: 30)
        )
        recorded = try String(contentsOf: argsFile, encoding: .utf8)
        #expect(recorded.contains("model_reasoning_effort=\"high\""))
    }

    @Test func claudeWritesBodyAndParsesUsage() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let claude = try writeStubBinary("claude", script: """
        cat > /dev/null
        echo '{"result": "# Claude Summary\\n\\nBody.", "usage": {"input_tokens": 5, "output_tokens": 6}, "total_cost_usd": 0.01}'
        """, in: dir)

        let provider = ClaudeProvider(executablePath: claude)
        let result = try await provider.generateSummary(prompt: "PROMPT", settings: ProviderRunSettings(timeout: 30))
        #expect(result.markdownBody == "# Claude Summary\n\nBody.")
        #expect(result.usage?.totalTokens == 11)
        #expect(result.usage?.costUSD == 0.01)
    }

    @Test func claudeNonJSONOutputStillProducesBodyWithoutUsage() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let claude = try writeStubBinary("claude", script: """
        cat > /dev/null
        echo 'plain markdown output, long enough to validate'
        """, in: dir)

        let provider = ClaudeProvider(executablePath: claude)
        let result = try await provider.generateSummary(prompt: "PROMPT", settings: ProviderRunSettings(timeout: 30))
        #expect(result.markdownBody.contains("plain markdown output"))
        #expect(result.usage == nil)
    }

    @Test func claudeAutoEffortOmitsEffortFlag() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let argsFile = dir.appendingPathComponent("args.txt")
        let claude = try writeStubBinary("claude", script: """
        printf '%s\\n' "$@" > "\(argsFile.path)"
        cat > /dev/null
        echo '{"result": "long enough body for validation"}'
        """, in: dir)

        let provider = ClaudeProvider(executablePath: claude)

        _ = try await provider.generateSummary(
            prompt: "P",
            settings: ProviderRunSettings(model: "sonnet", reasoningEffort: "auto", timeout: 30)
        )
        var recorded = try String(contentsOf: argsFile, encoding: .utf8)
        #expect(!recorded.contains("--effort"))

        _ = try await provider.generateSummary(
            prompt: "P",
            settings: ProviderRunSettings(model: "sonnet", reasoningEffort: "max", timeout: 30)
        )
        recorded = try String(contentsOf: argsFile, encoding: .utf8)
        #expect(recorded.contains("--effort"))
        #expect(recorded.contains("max"))
    }

    @Test func timeoutKillsProcessAndThrows() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let claude = try writeStubBinary("claude", script: """
        sleep 30
        """, in: dir)

        let provider = ClaudeProvider(executablePath: claude)
        await #expect(throws: ProviderRunError.self) {
            _ = try await provider.generateSummary(prompt: "P", settings: ProviderRunSettings(timeout: 1))
        }
    }

    @Test func scriptProviderHonorsClassicContract() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let script = try writeStubBinary("custom.sh", script: """
        prompt_file="$1"
        output_file="$2"
        printf '## From custom provider\\n\\nPrompt was %s chars.\\n' "$(wc -c < "$prompt_file")" > "$output_file"
        """, in: dir)

        let provider = ScriptProvider(id: "custom", scriptURL: URL(fileURLWithPath: script))
        let result = try await provider.generateSummary(prompt: "hello", settings: ProviderRunSettings(timeout: 30))
        #expect(result.markdownBody.contains("From custom provider"))
        #expect(result.usage == nil)
    }

    @Test func fakeProviderNeedsNoProcess() async throws {
        let provider = FakeProvider()
        let result = try await provider.generateSummary(prompt: "x", settings: ProviderRunSettings(timeout: 1))
        #expect(result.markdownBody.contains("Fake Summary"))
    }

    @Test func missingExecutableThrows() async {
        let provider = CodexProvider(executablePath: "/nonexistent/codex")
        await #expect(throws: ProviderRunError.self) {
            _ = try await provider.generateSummary(prompt: "P", settings: ProviderRunSettings(timeout: 5))
        }
    }
}
