import Foundation
import Testing

@testable import TubeFoldKit

private func temporaryDataDir() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("tubefoldkit-setup-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

// Setup-store and settings behavior (the subprocess-driven detect/test cases
// are covered by ProviderRunnerProcessTests with stub binaries).
@Suite struct ProviderSetupStoreTests {
    @Test func defaultsWhenNoFileExists() throws {
        let dir = try temporaryDataDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = ProviderSetupStore(dataDirectory: dir)
        let state = store.load()

        #expect(state["selectedProviderID"] as? String == "codex")
        #expect(state["codexModel"] as? String == "gpt-5.4-mini")
        #expect(state["claudeModel"] as? String == "sonnet")
        #expect(state["codexReasoningEffort"] as? String == "auto")
        #expect(state["outputLanguage"] as? String == "English")
        #expect(state["providerSetupCompleted"] as? Bool == false)
        #expect(state["codexExecutablePath"] is NSNull)
    }

    @Test func modelSettingsAreSavedAndNormalized() throws {
        let dir = try temporaryDataDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = ProviderSetupStore(dataDirectory: dir)
        let diagnostics = ProviderDiagnostics(descriptor: ProviderDescriptors.codex, store: store)

        // A valid model is kept; an invalid effort falls back to the default.
        let state = try diagnostics.saveModelSettings(model: "gpt-5.5", reasoningEffort: "bogus")
        #expect(state["codexModel"] as? String == "gpt-5.5")
        #expect(state["codexReasoningEffort"] as? String == "auto")

        // A bogus model falls back to the default.
        let state2 = try diagnostics.saveModelSettings(model: "gpt-99", reasoningEffort: "high")
        #expect(state2["codexModel"] as? String == "gpt-5.4-mini")
        #expect(state2["codexReasoningEffort"] as? String == "high")
    }

    @Test func outputLanguageIsSavedAndNormalized() throws {
        let dir = try temporaryDataDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = ProviderSetupStore(dataDirectory: dir)

        try store.update(["outputLanguage": " Русский \n язык "])
        #expect(store.outputLanguage() == "Русский язык")

        try store.update(["outputLanguage": "   "])
        #expect(store.outputLanguage() == "English")
    }

    @Test func selectSwitchesActiveProviderAndCompletion() throws {
        let dir = try temporaryDataDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = ProviderSetupStore(dataDirectory: dir)

        // Codex is connected, Claude is not.
        try store.update([
            "codexConnectedAt": "2026-07-01T10:00:00Z",
            "providerSetupCompleted": true,
            "lastSuccessfulConnectionTest": "2026-07-01T10:00:00Z",
        ])

        // Switching to (unconnected) Claude clears the global completion.
        let claudeState = try store.select(providerID: "claude")
        #expect(claudeState["selectedProviderID"] as? String == "claude")
        #expect(claudeState["providerSetupCompleted"] as? Bool == false)
        #expect(claudeState["lastSuccessfulConnectionTest"] is NSNull)

        // Switching back to connected Codex restores it from codexConnectedAt.
        let codexState = try store.select(providerID: "codex")
        #expect(codexState["selectedProviderID"] as? String == "codex")
        #expect(codexState["providerSetupCompleted"] as? Bool == true)
        #expect(codexState["lastSuccessfulConnectionTest"] as? String == "2026-07-01T10:00:00Z")
    }

    @Test func unknownProviderSelectionFallsBackToCodex() throws {
        let dir = try temporaryDataDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = ProviderSetupStore(dataDirectory: dir)
        let state = try store.select(providerID: "gemini")
        #expect(state["selectedProviderID"] as? String == "codex")
    }

    @Test func storedFileRoundTripsUnknownKeys() throws {
        let dir = try temporaryDataDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = ProviderSetupStore(dataDirectory: dir)
        try store.update(["futureKey": "kept"])
        #expect(store.load()["futureKey"] as? String == "kept")
    }

    @Test func resetRemovesStoredSetupFile() throws {
        let dir = try temporaryDataDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = ProviderSetupStore(dataDirectory: dir)
        try store.update([
            "providerSetupCompleted": true,
            "codexExecutablePath": "/usr/local/bin/codex",
        ])

        #expect(try store.reset())
        let state = store.load()
        #expect(state["providerSetupCompleted"] as? Bool == false)
        #expect(state["codexExecutablePath"] is NSNull)
        #expect(try store.reset() == false)
    }

    @Test func backendFirstRunResetClearsProviderSetupAndExtensionMeta() async throws {
        let dir = try temporaryDataDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let backend = TubeFoldBackend(
            config: PipelineConfiguration(dataDirectory: dir, provider: "fake"),
            store: try VideoStore.inMemory(),
            providerOverride: FakeProvider()
        )
        try backend.setupStore.update([
            "providerSetupCompleted": true,
            "codexExecutablePath": "/usr/local/bin/codex",
            "codexConnectedAt": "2026-07-01T10:00:00Z",
            "lastSuccessfulConnectionTest": "2026-07-01T10:00:00Z",
        ])
        try await backend.store.markExtensionSeen()

        let removed = try await backend.resetFirstRunState()
        #expect(removed["provider_setup"] == 1)
        #expect(removed["app_meta"] == 1)

        let setup = backend.providerSetupPayload()["state"] as? [String: Any]
        #expect(setup?["providerSetupCompleted"] as? Bool == false)
        #expect(setup?["codexExecutablePath"] is NSNull)
        let extensionStatus = try await backend.extensionStatusPayload()
        #expect(extensionStatus["connected"] as? Bool == false)
    }

    @Test func detectionStoresStableSymlinkPathAndRefreshesVersion() async throws {
        let dir = try temporaryDataDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let binDir = dir.appendingPathComponent("bin", isDirectory: true)
        let versionsDir = dir.appendingPathComponent("versions", isDirectory: true)
        try FileManager.default.createDirectory(at: binDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: versionsDir, withIntermediateDirectories: true)

        func makeExecutable(version: String) throws -> URL {
            let executable = versionsDir
                .appendingPathComponent(version, isDirectory: true)
                .appendingPathComponent("codex")
            try FileManager.default.createDirectory(
                at: executable.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try "#!/bin/sh\necho codex-cli \(version)\n"
                .write(to: executable, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
            return executable
        }

        let v1 = try makeExecutable(version: "1.0.0")
        let v2 = try makeExecutable(version: "2.0.0")
        let stablePath = binDir.appendingPathComponent("codex")
        try FileManager.default.createSymbolicLink(at: stablePath, withDestinationURL: v1)

        let descriptor = ProviderDescriptor(
            id: "testcodex",
            displayName: "Test Codex",
            binaryName: "missing-\(UUID().uuidString)",
            marker: "OK",
            markerExact: true,
            modelOptions: [ProviderOption(id: "model", label: "Model", description: "")],
            effortOptions: [ProviderOption(id: "auto", label: "Auto", description: "")],
            defaultModel: "model",
            defaultEffort: "auto",
            homebrewPaths: []
        )
        let store = ProviderSetupStore(dataDirectory: dir)
        let diagnostics = ProviderDiagnostics(descriptor: descriptor, store: store)

        let first = await diagnostics.detectInstallation(requestedPath: stablePath.path)
        #expect(first.status == .installed)
        #expect(first.path == stablePath.path)
        #expect(first.version == "codex-cli 1.0.0")
        #expect(store.load()[descriptor.pathKey] as? String == stablePath.path)

        try FileManager.default.removeItem(at: stablePath)
        try FileManager.default.createSymbolicLink(at: stablePath, withDestinationURL: v2)

        let second = await diagnostics.detectInstallation(requestedPath: stablePath.path)
        #expect(second.status == .installed)
        #expect(second.path == stablePath.path)
        #expect(second.version == "codex-cli 2.0.0")
        #expect(store.load()[descriptor.pathKey] as? String == stablePath.path)
    }

    @Test func providerSummariesReportConfiguration() throws {
        let dir = try temporaryDataDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = ProviderSetupStore(dataDirectory: dir)
        try store.update([
            "claudeConnectedAt": "2026-07-01T10:00:00Z",
            "claudeExecutablePath": "/usr/local/bin/claude",
            "claudeVersion": "2.1.0",
        ])
        let summaries = providerSummaries(store: store)
        let codex = summaries.first(where: { $0.id == "codex" })
        let claude = summaries.first(where: { $0.id == "claude" })
        #expect(codex?.configured == false)
        #expect(claude?.configured == true)
        #expect(claude?.executablePath == "/usr/local/bin/claude")
        #expect(claude?.version == "2.1.0")
    }

    @Test func connectionCommandShapes() {
        let workdir = URL(fileURLWithPath: "/tmp/w")
        let output = URL(fileURLWithPath: "/tmp/w/out.txt")

        let (codexArgs, codexStdout) = ProviderDescriptors.codex.connectionCommand(
            executable: "/bin/codex", model: "gpt-5.4-mini", effort: "medium", workdir: workdir, outputFile: output
        )
        #expect(!codexStdout)
        #expect(codexArgs.contains("exec"))
        #expect(codexArgs.contains("--output-last-message"))
        #expect(codexArgs.last == "-")

        let (codexAutoArgs, _) = ProviderDescriptors.codex.connectionCommand(
            executable: "/bin/codex", model: "gpt-5.4-mini", effort: "auto", workdir: workdir, outputFile: output
        )
        #expect(!codexAutoArgs.contains { $0.contains("model_reasoning_effort") })

        let (claudeArgs, claudeStdout) = ProviderDescriptors.claude.connectionCommand(
            executable: "/bin/claude", model: "sonnet", effort: "high", workdir: workdir, outputFile: output
        )
        #expect(claudeStdout)
        #expect(claudeArgs.contains("--print"))
        #expect(claudeArgs.contains("--effort"))

        let (claudeAutoArgs, _) = ProviderDescriptors.claude.connectionCommand(
            executable: "/bin/claude", model: "sonnet", effort: "auto", workdir: workdir, outputFile: output
        )
        #expect(!claudeAutoArgs.contains("--effort"))
    }

    @Test func classifyResultCategories() {
        let descriptor = ProviderDescriptors.codex
        func result(_ code: Int32, stdout: String = "", stderr: String = "") -> SubprocessResult {
            SubprocessResult(exitCode: code, stdout: stdout, stderr: stderr, durationSeconds: 0.1, timedOut: false)
        }

        #expect(ProviderDiagnostics.classifyResult(
            result(0), outputText: "CODEX_CONNECTION_OK", descriptor: descriptor
        ) == .success)
        // Exact marker required for codex — a wrong reply is invalidResponse.
        #expect(ProviderDiagnostics.classifyResult(
            result(0), outputText: "WRONG", descriptor: descriptor
        ) == .invalidResponse)
        // Substring is enough for claude.
        #expect(ProviderDiagnostics.classifyResult(
            result(0), outputText: "Sure! CLAUDE_CONNECTION_OK", descriptor: ProviderDescriptors.claude
        ) == .success)
        #expect(ProviderDiagnostics.classifyResult(
            result(124), outputText: "", descriptor: descriptor
        ) == .timeout)
        #expect(ProviderDiagnostics.classifyResult(
            result(1, stderr: "please login first"), outputText: "", descriptor: descriptor
        ) == .authenticationRequired)
        #expect(ProviderDiagnostics.classifyResult(
            result(1, stderr: "usage limit reached"), outputText: "", descriptor: descriptor
        ) == .usageLimitReached)
        #expect(ProviderDiagnostics.classifyResult(
            result(1, stderr: "could not resolve host"), outputText: "", descriptor: descriptor
        ) == .networkError)
        #expect(ProviderDiagnostics.classifyResult(
            result(1, stderr: "invalid_request_error invalid_enum_value"), outputText: "", descriptor: descriptor
        ) == .processFailed)
        #expect(ProviderDiagnostics.classifyResult(
            result(3, stderr: "boom"), outputText: "", descriptor: descriptor
        ) == .processFailed)
        #expect(ProviderDiagnostics.classifyResult(
            result(0), outputText: "something else", descriptor: descriptor
        ) == .invalidResponse)
    }
}
