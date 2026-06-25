import Foundation

final class BackendProcessController {
    static let shared = BackendProcessController()

    private let healthURL = URL(string: "http://127.0.0.1:43821/health")!
    private let port = "43821"
    private var process: Process?

    private init() {}

    func ensureRunning() async throws {
        if await isCompatibleBackendHealthy() {
            return
        }

        if let process, process.isRunning {
            NSLog("youtube-brain-server: stopping incompatible helper pid=%d", process.processIdentifier)
            process.terminate()
            self.process = nil
        } else {
            terminateStaleHelperOnPort()
        }

        try launch()

        for _ in 0..<30 {
            try await Task.sleep(nanoseconds: 200_000_000)
            if await isCompatibleBackendHealthy() {
                return
            }
        }

        throw ProviderSetupAPIError(message: "YouTube Brain could not start its local helper. Reopen the app or reinstall the command-line helper.")
    }

    func stop() {
        process?.terminate()
        process = nil
    }

    private func isCompatibleBackendHealthy() async -> Bool {
        var request = URLRequest(url: healthURL)
        request.timeoutInterval = 1.5

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else { return false }
            guard (200..<300).contains(httpResponse.statusCode) else { return false }

            let health = try JSONDecoder().decode(BackendHealthResponse.self, from: data)
            let features = health.backendFeatures
            return health.status == "ok"
                && health.apiVersion == 1
                && features?.codexModelSettings == true
                && features?.libraryRegenerate == true
                && features?.unlimitedTranscripts == true
        } catch {
            return false
        }
    }

    private func launch() throws {
        guard let executableURL = discoverServerExecutable() else {
            throw ProviderSetupAPIError(message: "YouTube Brain helper is missing from the app bundle. Rebuild the app or install the command-line helper.")
        }

        let launchedProcess = Process()
        launchedProcess.executableURL = executableURL
        launchedProcess.arguments = ["--provider", "codex"]
        launchedProcess.environment = processEnvironment()

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        launchedProcess.standardOutput = outputPipe
        launchedProcess.standardError = errorPipe
        attachLogHandler(outputPipe, prefix: "youtube-brain-server")
        attachLogHandler(errorPipe, prefix: "youtube-brain-server")

        try launchedProcess.run()
        process = launchedProcess
    }

    private func terminateStaleHelperOnPort() {
        guard let output = runProcessAndCapture(
            executable: "/usr/sbin/lsof",
            arguments: ["-nP", "-tiTCP:\(port)", "-sTCP:LISTEN"]
        ) else {
            return
        }

        let currentPID = ProcessInfo.processInfo.processIdentifier
        let pids = output
            .split(whereSeparator: \.isNewline)
            .compactMap { Int32(String($0).trimmingCharacters(in: .whitespacesAndNewlines)) }
            .filter { $0 != currentPID }

        for pid in pids {
            NSLog("youtube-brain-server: terminating stale helper on port %@ pid=%d", port, pid)
            _ = runProcessAndCapture(executable: "/bin/kill", arguments: [String(pid)])
        }

        if !pids.isEmpty {
            Thread.sleep(forTimeInterval: 0.2)
        }
    }

    private func runProcessAndCapture(executable: String, arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return nil
        }

        guard process.terminationStatus == 0 else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)
    }

    private func discoverServerExecutable() -> URL? {
        if let embeddedURL = embeddedServerExecutable() {
            return embeddedURL
        }

        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = [
            "\(home)/.local/bin/youtube-brain-server",
            "/opt/homebrew/bin/youtube-brain-server",
            "/usr/local/bin/youtube-brain-server"
        ]

        if let path = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
            return URL(fileURLWithPath: path)
        }

        return lookupInLoginShell(command: "youtube-brain-server").flatMap { path in
            FileManager.default.isExecutableFile(atPath: path) ? URL(fileURLWithPath: path) : nil
        }
    }

    private func embeddedServerExecutable() -> URL? {
        guard let resourceURL = Bundle.main.resourceURL else { return nil }
        let executableURL = resourceURL
            .appendingPathComponent("YouTubeBrainBackend", isDirectory: true)
            .appendingPathComponent("youtube-brain-server")
        return FileManager.default.isExecutableFile(atPath: executableURL.path) ? executableURL : nil
    }

    private func lookupInLoginShell(command: String) -> String? {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = ["-lc", "command -v \(command)"]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return nil
        }

        guard process.terminationStatus == 0 else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let path = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return path?.isEmpty == false ? path : nil
    }

    private func processEnvironment() -> [String: String] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var environment = ProcessInfo.processInfo.environment
        let extraPath = [
            "\(home)/.local/bin",
            "\(home)/.local/share/mise/shims",
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/usr/bin",
            "/bin",
            "/usr/sbin",
            "/sbin"
        ].joined(separator: ":")
        environment["PATH"] = "\(extraPath):\(environment["PATH"] ?? "")"
        return environment
    }

    private func attachLogHandler(_ pipe: Pipe, prefix: String) {
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            NSLog("%@: %@", prefix, text.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }
}

private struct BackendHealthResponse: Decodable {
    let status: String
    let apiVersion: Int
    let backendFeatures: BackendFeatures?
}

private struct BackendFeatures: Decodable {
    let codexModelSettings: Bool
    let libraryRegenerate: Bool
    let unlimitedTranscripts: Bool
}
