import Foundation

public enum InstallationStatus: String, Sendable {
    case installed
    case invalid
    case failed
    case notInstalled
}

public struct InstallationResult: Sendable {
    public let status: InstallationStatus
    public let provider: String
    public let displayName: String
    public let path: String?
    public let version: String?
    public let checkedPaths: [String]
    public let userMessage: String
}

public enum ConnectionTestStatus: String, Sendable {
    case success
    case installationMissing
    case installationInvalid
    case authenticationRequired
    case usageLimitReached
    case networkError
    case timeout
    case invalidResponse
    case processFailed
}

public struct ConnectionTestResult: Sendable {
    public let status: ConnectionTestStatus
    public let provider: String
    public let userMessage: String
    public let executablePath: String?
    public let model: String?
    public let exitCode: Int32?
    public let stderrExcerpt: String
    public let stdoutExcerpt: String
    public let durationSeconds: Double?
}

/// Detection, sign-in test, and settings for a CLI provider used via the
/// user's subscription. Detect/test/model are direct async calls from the UI.
public struct ProviderDiagnostics: Sendable {
    public let descriptor: ProviderDescriptor
    public let store: ProviderSetupStore

    public init(descriptor: ProviderDescriptor, store: ProviderSetupStore) {
        self.descriptor = descriptor
        self.store = store
    }

    public var providerID: String { descriptor.id }

    // MARK: - Detection

    public func detectInstallation(requestedPath: String? = nil) async -> InstallationResult {
        var checked: [String] = []
        for candidate in candidatePaths(requestedPath: requestedPath) {
            guard !candidate.isEmpty else { continue }
            let path = URL(fileURLWithPath: NSString(string: candidate).expandingTildeInPath)
                .resolvingSymlinksInPath().path
            checked.append(path)
            guard FileManager.default.fileExists(atPath: path) else { continue }
            guard FileManager.default.isExecutableFile(atPath: path) else {
                markSetupIncomplete(clearPath: false)
                return InstallationResult(
                    status: .invalid,
                    provider: providerID,
                    displayName: descriptor.displayName,
                    path: path,
                    version: nil,
                    checkedPaths: checked,
                    userMessage: "\(descriptor.displayName) was found, but it cannot be launched."
                )
            }

            let result = (try? await Subprocess.run(
                executable: path,
                arguments: ["--version"],
                currentDirectory: FileManager.default.temporaryDirectory,
                environment: Subprocess.controlledEnvironment(),
                timeout: 15
            )) ?? SubprocessResult(exitCode: 127, stdout: "", stderr: "", durationSeconds: 0, timedOut: false)

            if result.exitCode == 0 {
                let version = Self.parseCLIVersion(stdout: result.stdout, stderr: result.stderr)
                _ = try? store.update([
                    descriptor.pathKey: path,
                    descriptor.versionKey: version,
                    "selectedProviderID": providerID,
                ])
                return InstallationResult(
                    status: .installed,
                    provider: providerID,
                    displayName: descriptor.displayName,
                    path: path,
                    version: version,
                    checkedPaths: checked,
                    userMessage: "Ready to check sign-in."
                )
            }
            markSetupIncomplete(clearPath: false)
            return InstallationResult(
                status: .failed,
                provider: providerID,
                displayName: descriptor.displayName,
                path: path,
                version: nil,
                checkedPaths: checked,
                userMessage: "\(descriptor.displayName) is installed, but the app could not read its version."
            )
        }

        markSetupIncomplete(clearPath: true)
        return InstallationResult(
            status: .notInstalled,
            provider: providerID,
            displayName: descriptor.displayName,
            path: nil,
            version: nil,
            checkedPaths: checked,
            userMessage: "\(descriptor.displayName) was not found."
        )
    }

    // MARK: - Connection test

    public func testConnection(executablePath: String? = nil) async -> ConnectionTestResult {
        let state = store.load()
        var pathValue = executablePath ?? (state[descriptor.pathKey] as? String)
        if pathValue == nil || pathValue?.isEmpty == true {
            let detected = await detectInstallation()
            guard detected.status == .installed, let detectedPath = detected.path else {
                return ConnectionTestResult(
                    status: .installationMissing,
                    provider: providerID,
                    userMessage: "\(descriptor.displayName) was not found.",
                    executablePath: nil,
                    model: nil,
                    exitCode: nil,
                    stderrExcerpt: "",
                    stdoutExcerpt: "",
                    durationSeconds: nil
                )
            }
            pathValue = detectedPath
        }

        let exePath = URL(fileURLWithPath: NSString(string: pathValue ?? "").expandingTildeInPath)
            .resolvingSymlinksInPath().path
        guard FileManager.default.fileExists(atPath: exePath),
              FileManager.default.isExecutableFile(atPath: exePath) else {
            markSetupIncomplete(clearPath: false)
            return ConnectionTestResult(
                status: .installationInvalid,
                provider: providerID,
                userMessage: "\(descriptor.displayName) executable is missing or cannot be launched.",
                executablePath: exePath,
                model: nil,
                exitCode: nil,
                stderrExcerpt: "",
                stdoutExcerpt: "",
                durationSeconds: nil
            )
        }

        let workdir = try? IsolatedWorkdir.make(prefix: "tubefold-\(providerID)-test-")
        defer { workdir?.cleanUp() }
        guard let workdir else {
            return ConnectionTestResult(
                status: .processFailed,
                provider: providerID,
                userMessage: "\(descriptor.displayName) connection test failed.",
                executablePath: exePath,
                model: nil,
                exitCode: nil,
                stderrExcerpt: "",
                stdoutExcerpt: "",
                durationSeconds: nil
            )
        }
        let outputFile = workdir.url.appendingPathComponent("last-message.txt")
        let model = descriptor.validModel(state[descriptor.modelKey] as? String)
        let effort = descriptor.validEffort(state[descriptor.effortKey] as? String)
        let (arguments, readsStdout) = descriptor.connectionCommand(
            executable: exePath,
            model: model,
            effort: effort,
            workdir: workdir.url,
            outputFile: outputFile
        )
        let prompt = "Reply with exactly: \(descriptor.marker)\n"

        let result = (try? await Subprocess.run(
            executable: arguments[0],
            arguments: Array(arguments.dropFirst()),
            currentDirectory: workdir.url,
            environment: Subprocess.controlledEnvironment(),
            stdin: prompt,
            timeout: 90
        )) ?? SubprocessResult(exitCode: 127, stdout: "", stderr: "", durationSeconds: 0, timedOut: false)

        let outputText: String = if readsStdout {
            result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            (try? String(contentsOf: outputFile, encoding: .utf8))?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        }

        let category = Self.classifyResult(result, outputText: outputText, descriptor: descriptor)

        if category == .success {
            let now = ISO8601DateFormatter().string(from: Date())
            _ = try? store.update([
                "selectedProviderID": providerID,
                "providerSetupCompleted": true,
                "lastSuccessfulConnectionTest": now,
                descriptor.pathKey: exePath,
                descriptor.connectedKey: now,
            ])
            return ConnectionTestResult(
                status: .success,
                provider: providerID,
                userMessage: "\(descriptor.displayName) is connected and ready.",
                executablePath: exePath,
                model: model,
                exitCode: result.exitCode,
                stderrExcerpt: Self.excerpt(result.stderr),
                stdoutExcerpt: Self.excerpt(result.stdout),
                durationSeconds: result.durationSeconds
            )
        }

        markSetupIncomplete(clearPath: false)
        return ConnectionTestResult(
            status: category,
            provider: providerID,
            userMessage: Self.userMessage(for: category, descriptor: descriptor),
            executablePath: exePath,
            model: model,
            exitCode: result.exitCode,
            stderrExcerpt: Self.excerpt(result.stderr),
            stdoutExcerpt: Self.excerpt(result.stdout),
            durationSeconds: result.durationSeconds
        )
    }

    // MARK: - Settings

    public func saveModelSettings(model: String?, reasoningEffort: String?) throws -> [String: Any] {
        try store.update([
            descriptor.modelKey: descriptor.validModel(model),
            descriptor.effortKey: descriptor.validEffort(reasoningEffort),
        ])
    }

    public func completeSetup() throws -> [String: Any] {
        try store.update([
            "providerSetupCompleted": true,
            "selectedProviderID": providerID,
        ])
    }

    // MARK: - Internals

    func markSetupIncomplete(clearPath: Bool) {
        var changes: [String: Any] = [
            "providerSetupCompleted": false,
            "lastSuccessfulConnectionTest": NSNull(),
            descriptor.connectedKey: NSNull(),
        ]
        if clearPath {
            changes[descriptor.pathKey] = NSNull()
            changes[descriptor.versionKey] = NSNull()
        }
        _ = try? store.update(changes)
    }

    func candidatePaths(requestedPath: String?) -> [String] {
        let state = store.load()
        var candidates: [String] = []
        if let requestedPath, !requestedPath.isEmpty {
            candidates.append(requestedPath)
        }
        if let storedPath = state[descriptor.pathKey] as? String, !storedPath.isEmpty {
            candidates.append(storedPath)
        }
        if let shellPath = Self.detectViaLoginShell(binaryName: descriptor.binaryName) {
            candidates.append(shellPath)
        }
        candidates.append(contentsOf: descriptor.homebrewPaths)

        var seen = Set<String>()
        var deduped: [String] = []
        for candidate in candidates {
            let expanded = URL(fileURLWithPath: NSString(string: candidate).expandingTildeInPath)
                .resolvingSymlinksInPath().path
            if seen.insert(expanded).inserted {
                deduped.append(expanded)
            }
        }
        return deduped
    }

    /// Resolve a binary through the user's login shell so PATH customizations
    /// (nvm, mise, custom installs) are honored.
    public static func detectViaLoginShell(binaryName: String) -> String? {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = ["-lc", "command -v \(binaryName)"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            return nil
        }
        let deadline = Date().addingTimeInterval(10)
        while process.isRunning, Date() < deadline {
            usleep(50_000)
        }
        if process.isRunning {
            process.terminate()
            return nil
        }
        guard process.terminationStatus == 0,
              let data = try? pipe.fileHandleForReading.readToEnd(),
              let output = String(data: data, encoding: .utf8)?
              .trimmingCharacters(in: .whitespacesAndNewlines),
              !output.isEmpty else {
            return nil
        }
        return output.components(separatedBy: "\n").first
    }

    static func parseCLIVersion(stdout: String, stderr: String) -> String {
        let text = (stdout.isEmpty ? stderr : stdout).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return "unknown" }
        return text.components(separatedBy: "\n").first ?? "unknown"
    }

    static func classifyResult(
        _ result: SubprocessResult,
        outputText: String,
        descriptor: ProviderDescriptor
    ) -> ConnectionTestStatus {
        let combined = "\(result.stdout)\n\(result.stderr)\n\(outputText)".lowercased()
        let markerOK = descriptor.markerExact
            ? outputText.trimmingCharacters(in: .whitespacesAndNewlines) == descriptor.marker
            : outputText.contains(descriptor.marker)
        if result.exitCode == 0, markerOK {
            return .success
        }
        if result.exitCode == Subprocess.timeoutExitCode {
            return .timeout
        }
        if combined.contains("not logged in") || combined.contains("login") || combined.contains("auth") {
            return .authenticationRequired
        }
        if combined.contains("rate limit") || combined.contains("usage limit") || combined.contains("quota") {
            return .usageLimitReached
        }
        if combined.contains("network") || combined.contains("connection")
            || combined.contains("could not resolve") || combined.contains("timed out") {
            return .networkError
        }
        if result.exitCode != 0 {
            return .processFailed
        }
        return .invalidResponse
    }

    static func userMessage(for status: ConnectionTestStatus, descriptor: ProviderDescriptor) -> String {
        let name = descriptor.displayName
        return switch status {
        case .success: "\(name) is connected and ready."
        case .authenticationRequired: "\(name) is installed, but you are not signed in."
        case .usageLimitReached: "\(name) is connected, but your current usage limit has been reached."
        case .networkError: "Could not reach \(name) services."
        case .timeout: "\(name) did not respond in time."
        case .invalidResponse: "\(name) responded, but the connection test could not be verified."
        case .processFailed: "\(name) process failed."
        case .installationMissing: "\(name) was not found."
        case .installationInvalid: "\(name) executable is missing or cannot be launched."
        }
    }

    static func excerpt(_ text: String, maxChars: Int = 1200) -> String {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard clean.count > maxChars else { return clean }
        return String(clean.prefix(maxChars)).trimmingTrailing(charactersIn: " \t\n\r") + "..."
    }
}

/// Per-provider configuration summary for the settings picker.
public struct ProviderSummary: Sendable, Equatable {
    public let id: String
    public let displayName: String
    public let configured: Bool
    public let executablePath: String?
    public let version: String?
}

public func providerSummaries(store: ProviderSetupStore) -> [ProviderSummary] {
    let state = store.load()
    return ProviderDescriptors.all.map { descriptor in
        let connected = state[descriptor.connectedKey]
        return ProviderSummary(
            id: descriptor.id,
            displayName: descriptor.displayName,
            configured: connected != nil && !(connected is NSNull),
            executablePath: state[descriptor.pathKey] as? String,
            version: state[descriptor.versionKey] as? String
        )
    }
}
