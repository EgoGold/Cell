import Foundation

public struct ProcessResult: Sendable {
    public let status: Int32
    public let stdout: String
    public let stderr: String
    public var succeeded: Bool { status == 0 }
    public var combinedOutput: String { stdout.isEmpty ? stderr : (stderr.isEmpty ? stdout : stdout + "\n" + stderr) }
}

public enum ProcessRunnerError: LocalizedError {
    case launchFailed(String, Error)
    case timedOut(String)
    case failed(String, ProcessResult)

    public var errorDescription: String? {
        switch self {
        case .launchFailed(let tool, let error): return "Could not start \(tool): \(error.localizedDescription)"
        case .timedOut(let tool): return "\(tool) did not finish in time."
        case .failed(let tool, let result):
            let detail = result.combinedOutput.trimmingCharacters(in: .whitespacesAndNewlines)
            let tail = detail.split(separator: "\n").suffix(6).joined(separator: "\n")
            return "\(tool) failed (exit \(result.status))" + (tail.isEmpty ? "." : ":\n\(tail)")
        }
    }
}

/// Runs helper processes.
///
/// Output is captured through temporary files instead of pipes: Wine starts a `wineserver`
/// that inherits standard output and can keep a pipe open long after the command finished,
/// which would make pipe-based readers hang.
public enum ProcessRunner {
    @discardableResult
    public static func run(
        _ executable: URL,
        arguments: [String] = [],
        environment: [String: String]? = nil,
        currentDirectory: URL? = nil,
        timeout: TimeInterval? = nil,
        outputDirectory: URL? = nil
    ) throws -> ProcessResult {
        let fm = FileManager.default
        let scratch = outputDirectory ?? fm.temporaryDirectory.appendingPathComponent("cell-proc-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { if outputDirectory == nil { try? fm.removeItem(at: scratch) } }
        let outURL = scratch.appendingPathComponent("stdout")
        let errURL = scratch.appendingPathComponent("stderr")
        fm.createFile(atPath: outURL.path, contents: nil)
        fm.createFile(atPath: errURL.path, contents: nil)
        let outHandle = try FileHandle(forWritingTo: outURL)
        let errHandle = try FileHandle(forWritingTo: errURL)

        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        if let environment { process.environment = environment }
        if let currentDirectory { process.currentDirectoryURL = currentDirectory }
        process.standardOutput = outHandle
        process.standardError = errHandle
        process.standardInput = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            try? outHandle.close(); try? errHandle.close()
            throw ProcessRunnerError.launchFailed(executable.lastPathComponent, error)
        }

        var timedOut = false
        if let timeout {
            let deadline = Date().addingTimeInterval(timeout)
            while process.isRunning && Date() < deadline {
                Thread.sleep(forTimeInterval: 0.05)
            }
            if process.isRunning {
                timedOut = true
                process.terminate()
                Thread.sleep(forTimeInterval: 0.5)
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            }
        }
        process.waitUntilExit()
        try? outHandle.close(); try? errHandle.close()

        let stdout = (try? String(contentsOf: outURL, encoding: .utf8)) ?? String(decoding: (try? Data(contentsOf: outURL)) ?? Data(), as: UTF8.self)
        let stderr = (try? String(contentsOf: errURL, encoding: .utf8)) ?? String(decoding: (try? Data(contentsOf: errURL)) ?? Data(), as: UTF8.self)
        if timedOut { throw ProcessRunnerError.timedOut(executable.lastPathComponent) }
        return ProcessResult(status: process.terminationStatus, stdout: stdout, stderr: stderr)
    }

    /// Runs and throws when the exit status is not zero.
    @discardableResult
    public static func runChecked(
        _ executable: URL,
        arguments: [String] = [],
        environment: [String: String]? = nil,
        currentDirectory: URL? = nil,
        timeout: TimeInterval? = nil
    ) throws -> ProcessResult {
        let result = try run(executable, arguments: arguments, environment: environment,
                             currentDirectory: currentDirectory, timeout: timeout)
        guard result.succeeded else { throw ProcessRunnerError.failed(executable.lastPathComponent, result) }
        return result
    }

    public static func runAsync(
        _ executable: URL,
        arguments: [String] = [],
        environment: [String: String]? = nil,
        currentDirectory: URL? = nil,
        timeout: TimeInterval? = nil,
        outputDirectory: URL? = nil
    ) async throws -> ProcessResult {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let result = try run(executable, arguments: arguments, environment: environment,
                                         currentDirectory: currentDirectory, timeout: timeout, outputDirectory: outputDirectory)
                    continuation.resume(returning: result)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    public static func runCheckedAsync(
        _ executable: URL,
        arguments: [String] = [],
        environment: [String: String]? = nil,
        currentDirectory: URL? = nil,
        timeout: TimeInterval? = nil
    ) async throws -> ProcessResult {
        let result = try await runAsync(executable, arguments: arguments, environment: environment,
                                        currentDirectory: currentDirectory, timeout: timeout)
        guard result.succeeded else { throw ProcessRunnerError.failed(executable.lastPathComponent, result) }
        return result
    }

    /// Whether a process with this PID is alive.
    public static func isAlive(_ pid: pid_t) -> Bool {
        guard pid > 0 else { return false }
        return kill(pid, 0) == 0 || errno == EPERM
    }

    /// Lists processes as (pid, command line) pairs using `ps`.
    public static func processList() -> [(pid: pid_t, command: String)] {
        guard let result = try? run(URL(fileURLWithPath: "/bin/ps"), arguments: ["-axww", "-o", "pid=,command="]) else { return [] }
        return result.stdout.split(separator: "\n").compactMap { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard let space = trimmed.firstIndex(of: " "), let pid = pid_t(trimmed[..<space]) else { return nil }
            return (pid, String(trimmed[space...]).trimmingCharacters(in: .whitespaces))
        }
    }
}
