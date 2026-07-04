import Foundation

/// Result of one child-process run.
public struct SubprocessResult: Sendable, Equatable {
    public let exitCode: Int32
    public let stdout: String
    public let stderr: String
    public let durationSeconds: Double
    public let timedOut: Bool
}

/// Box for Foundation types (`Process`, `FileHandle`) that predate Sendable
/// but are safe to hand across the specific await points used below.
private struct UncheckedSendable<Value>: @unchecked Sendable {
    let value: Value
}

/// Async `Process` wrapper: prompt on stdin, captured stdout/stderr,
/// wall-clock timeout that
/// SIGTERMs the child and escalates to SIGKILL after a grace period.
public enum Subprocess {
    public static let timeoutExitCode: Int32 = 124

    public static func run(
        executable: String,
        arguments: [String],
        currentDirectory: URL? = nil,
        environment: [String: String]? = nil,
        stdin: String? = nil,
        timeout: TimeInterval
    ) async throws -> SubprocessResult {
        let clock = ContinuousClock()
        let started = clock.now

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if let currentDirectory {
            process.currentDirectoryURL = currentDirectory
        }
        if let environment {
            process.environment = environment
        }

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        let stdinPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        process.standardInput = stdinPipe

        try process.run()

        // Feed stdin off the current task so a full pipe can't deadlock us.
        let stdinData = Data((stdin ?? "").utf8)
        let stdinHandle = UncheckedSendable(value: stdinPipe.fileHandleForWriting)
        Task.detached {
            try? stdinHandle.value.write(contentsOf: stdinData)
            try? stdinHandle.value.close()
        }

        // Drain both pipes concurrently (also deadlock avoidance).
        async let stdoutData = readAll(stdoutPipe.fileHandleForReading)
        async let stderrData = readAll(stderrPipe.fileHandleForReading)

        let timedOut = await waitWithTimeout(process, timeout: timeout)

        let stdout = String(decoding: await stdoutData, as: UTF8.self)
        let stderr = String(decoding: await stderrData, as: UTF8.self)
        let elapsed = started.duration(to: clock.now)

        return SubprocessResult(
            exitCode: timedOut ? timeoutExitCode : process.terminationStatus,
            stdout: stdout,
            stderr: stderr,
            durationSeconds: Double(elapsed.components.seconds)
                + Double(elapsed.components.attoseconds) / 1e18,
            timedOut: timedOut
        )
    }

    private static func readAll(_ handle: FileHandle) async -> Data {
        let boxed = UncheckedSendable(value: handle)
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let data = (try? boxed.value.readToEnd()) ?? Data()
                try? boxed.value.close()
                continuation.resume(returning: data)
            }
        }
    }

    /// Wait for exit; on timeout send SIGTERM, wait a 10s grace period, then
    /// SIGKILL. Returns whether the run timed out.
    private static func waitWithTimeout(_ process: Process, timeout: TimeInterval) async -> Bool {
        if await raceExit(process, against: timeout) {
            return false
        }
        process.terminate() // SIGTERM
        if !(await raceExit(process, against: 10)) {
            kill(process.processIdentifier, SIGKILL)
            await waitUntilExit(process)
        }
        return true
    }

    /// `true` if the process exits before the deadline.
    private static func raceExit(_ process: Process, against seconds: TimeInterval) async -> Bool {
        let boxed = UncheckedSendable(value: process)
        return await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                await waitUntilExit(boxed.value)
                return true
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(seconds))
                return false
            }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
    }

    private static func waitUntilExit(_ process: Process) async {
        let boxed = UncheckedSendable(value: process)
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                boxed.value.waitUntilExit()
                continuation.resume()
            }
        }
    }

    /// PATH-restricted environment used for provider CLI invocations.
    public static func controlledEnvironment(extra: [String: String] = [:]) -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        for (key, value) in extra {
            env[key] = value
        }
        return env
    }
}
