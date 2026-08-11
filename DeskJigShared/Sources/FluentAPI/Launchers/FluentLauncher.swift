//  FluentLauncher.swift
//  DeskJigShared

import Foundation
import AppKit
import CoreGraphics

// MARK: - Launch Method

public enum ExpLaunchMethod: String, Sendable {
    case cli = "cli"
    case appleScript = "appleScript"
    case open = "open"
    case workspaceFile = "workspaceFile"
    case commandFile = "commandFile"
}

// MARK: - Match Confidence

public enum ExpMatchConfidence: String, Sendable, Comparable {
    case exact = "exact"         // documentPath match or unique identifier
    case high = "high"           // title + frame match
    case medium = "medium"       // title or frame match
    case low = "low"             // any window from app

    public static func < (lhs: ExpMatchConfidence, rhs: ExpMatchConfidence) -> Bool {
        let order: [ExpMatchConfidence] = [.low, .medium, .high, .exact]
        guard let lhsIndex = order.firstIndex(of: lhs),
              let rhsIndex = order.firstIndex(of: rhs) else { return false }
        return lhsIndex < rhsIndex
    }
}

// MARK: - Match Method

public enum MatchMethod: String, Sendable {
    case documentPath = "documentPath"
    case titlePattern = "titlePattern"
    case bentoTitle = "bentoTitle"      // Exact match on bento:dir:index title
    case frameMatch = "frameMatch"
    case bundleIdOnly = "bundleIdOnly"
    case chromeWindowId = "chromeWindowId"
    case chromeProfile = "chromeProfile"      // Match by Chrome profile name
    case chromeTabUrls = "chromeTabUrls"      // Match by tab URL overlap
}

// MARK: - Launch Result

public struct ExpLaunchResult: Sendable {
    public let success: Bool
    public let launchDurationMs: Int
    public let method: ExpLaunchMethod
    public let notes: [String]
    public let pid: pid_t?

    public init(
        success: Bool,
        launchDurationMs: Int,
        method: ExpLaunchMethod,
        notes: [String] = [],
        pid: pid_t? = nil
    ) {
        self.success = success
        self.launchDurationMs = launchDurationMs
        self.method = method
        self.notes = notes
        self.pid = pid
    }
}

// MARK: - Window Match

public struct ExpWindowMatch: Sendable {
    public let window: SnapshotWindow
    public let confidence: ExpMatchConfidence
    public let method: MatchMethod
    /// The value that was matched (e.g., title "bento:deskjig:1", path "/Users/user/code/deskjig")
    /// Used for debug logging to show what criteria led to the match
    public let matchedValue: String?

    public init(
        window: SnapshotWindow,
        confidence: ExpMatchConfidence,
        method: MatchMethod,
        matchedValue: String? = nil
    ) {
        self.window = window
        self.confidence = confidence
        self.method = method
        self.matchedValue = matchedValue
    }
}

// MARK: - Fluent App Launcher Protocol

/// Protocol for Fluent app launchers used in parallel workspace restoration.
/// Each launcher handles a specific app or category of apps.
public protocol FluentAppLauncher: Sendable {
    /// The bundle identifier for the app
    var bundleId: String { get }

    /// Human-readable app name
    var appName: String { get }

    /// Launch the app, optionally opening a specific directory/path
    /// - Parameters:
    ///   - directory: The directory to open (for IDEs, terminals) or nil
    ///   - title: The window title to set (e.g., "bento:deskjig:0" for terminals)
    ///   - task: The task context for logging
    /// - Returns: Result of the launch operation
    func launch(
        directory: String?,
        title: String?,
        task: RestorationTaskContext
    ) async throws -> ExpLaunchResult

    /// Whether the app is single-instance (e.g. Codex — only one window at a time).
    /// When true, `findOrLaunch` will still call `launch()` to switch the project
    /// even if an existing window is matched.
    var isSingleInstance: Bool { get }

    /// Find a window in the snapshot that matches what this launcher created
    /// - Parameters:
    ///   - snapshot: Current system snapshot
    ///   - directory: The directory that was opened (for matching)
    ///   - title: The expected window title (e.g., "bento:deskjig:0" for terminals)
    ///   - task: The task context for logging
    ///   - trustDeskJigTitle: If true, trust the legacy `bento:` title token even if the directory doesn't match
    /// - Returns: Matched window if found
    func matchWindow(
        in snapshot: SystemSnapshot,
        directory: String?,
        title: String?,
        task: RestorationTaskContext,
        trustDeskJigTitle: Bool
    ) -> ExpWindowMatch?

    /// Launch the app attached to an existing tmux session.
    /// Default implementation throws `.notSupported`; terminal launchers override.
    ///
    /// - Parameters:
    ///   - sessionName: The tmux session name to attach to
    ///   - workingDirectory: The working directory for the session
    ///   - task: Trace logging context
    ///   - tmuxManagedIndex: Per-bundle index for the managed window title (e.g., 0 → `bento:tmux:managed:0`)
    func launchWithTmuxSession(
        sessionName: String,
        workingDirectory: String?,
        task: RestorationTaskContext,
        tmuxManagedIndex: Int?
    ) async throws -> ExpLaunchResult
}

/// Default parameter extension for backward compatibility
public extension FluentAppLauncher {
    var isSingleInstance: Bool { false }

    func matchWindow(
        in snapshot: SystemSnapshot,
        directory: String?,
        title: String?,
        task: RestorationTaskContext
    ) -> ExpWindowMatch? {
        matchWindow(in: snapshot, directory: directory, title: title, task: task, trustDeskJigTitle: false)
    }

    /// Default implementation throws — override in terminal launchers.
    func launchWithTmuxSession(
        sessionName: String,
        workingDirectory: String?,
        task: RestorationTaskContext,
        tmuxManagedIndex: Int?
    ) async throws -> ExpLaunchResult {
        throw TmuxLaunchError.notSupported(bundleId: bundleId)
    }
}

/// Error thrown when a launcher does not support tmux session launch.
public enum TmuxLaunchError: Error, LocalizedError {
    case notSupported(bundleId: String)

    public var errorDescription: String? {
        switch self {
        case .notSupported(let bundleId):
            return "launchWithTmuxSession not supported for \(bundleId)"
        }
    }
}

// MARK: - Common Launcher Utilities

public enum LauncherUtils {
    /// Strip Xcode environment variables that can interfere with launched processes.
    /// This is the lighter variant used by the default `runProcess*` helpers and the
    /// IDE/Codex launchers; terminal launchers use the hardened `cleanLaunchEnvironment`.
    public static func cleanEnvironment() -> [String: String] {
        ProcessInfo.processInfo.environment.filter {
            !$0.key.hasPrefix("DYLD_") &&
            !$0.key.hasPrefix("__XPC") &&
            !$0.key.hasPrefix("XCODE")
        }
    }

    /// Build a hardened launch environment for the terminal launchers: strips the explicit
    /// Xcode/DYLD/XPC variables and the `__XCODE*`/`LLDB_*` prefixed ones (and, when
    /// `stripTmux` is set, the inherited tmux client context), then augments PATH so CLI
    /// tools resolve outside Xcode's environment. Ghostty passes `stripTmux: true` to avoid
    /// inheriting a parent tmux socket; Kitty/Alacritty leave tmux vars in place. The
    /// IDE/Codex launchers intentionally keep using the lighter `cleanEnvironment()`.
    public static func cleanLaunchEnvironment(stripTmux: Bool = false) -> [String: String] {
        var env = ProcessInfo.processInfo.environment

        var variablesToStrip = [
            "__XCODE_BUILT_PRODUCTS_DIR_PATHS",
            "DYLD_INSERT_LIBRARIES",
            "DYLD_LIBRARY_PATH",
            "DYLD_FRAMEWORK_PATH",
            "__XPC_DYLD_LIBRARY_PATH",
            "__XPC_DYLD_FRAMEWORK_PATH"
        ]
        if stripTmux {
            // Avoid inheriting a parent tmux client context/socket.
            variablesToStrip.append(contentsOf: ["TMUX", "TMUX_PANE", "TMUX_TMPDIR"])
        }

        for varName in variablesToStrip {
            env.removeValue(forKey: varName)
        }

        // Remove any other Xcode/LLDB prefixed variables
        let keysToRemove = env.keys.filter { key in
            key.hasPrefix("__XCODE") || key.hasPrefix("LLDB_")
        }
        for key in keysToRemove {
            env.removeValue(forKey: key)
        }

        // Ensure PATH includes common locations
        let essentialPaths = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        if let currentPath = env["PATH"] {
            if !currentPath.contains("/opt/homebrew/bin") {
                env["PATH"] = essentialPaths + ":" + currentPath
            }
        } else {
            env["PATH"] = essentialPaths
        }

        return env
    }

    /// Run a process and wait for completion
    public static func runProcess(
        executable: URL,
        arguments: [String],
        environment: [String: String]? = nil
    ) throws -> (exitCode: Int32, duration: TimeInterval) {
        let startTime = Date()
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = environment ?? cleanEnvironment()

        // Suppress output
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        try process.run()
        process.waitUntilExit()

        let duration = Date().timeIntervalSince(startTime)
        return (process.terminationStatus, duration)
    }

    /// Run a process asynchronously
    public static func runProcessAsync(
        executable: URL,
        arguments: [String],
        environment: [String: String]? = nil
    ) async throws -> (exitCode: Int32, duration: TimeInterval) {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global().async {
                do {
                    let result = try runProcess(
                        executable: executable,
                        arguments: arguments,
                        environment: environment
                    )
                    continuation.resume(returning: result)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// Run a process and capture stderr (for diagnostic logging).
    public static func runProcessCapturingStderr(
        executable: URL,
        arguments: [String],
        environment: [String: String]? = nil
    ) throws -> (exitCode: Int32, duration: TimeInterval, stderr: String) {
        let startTime = Date()
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = environment ?? cleanEnvironment()
        process.standardOutput = FileHandle.nullDevice

        let stderrPipe = Pipe()
        process.standardError = stderrPipe

        try process.run()
        process.waitUntilExit()

        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        let stderr = String(data: stderrData, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        let duration = Date().timeIntervalSince(startTime)
        return (process.terminationStatus, duration, stderr)
    }

    /// Run a process asynchronously with stderr capture.
    public static func runProcessAsyncCapturingStderr(
        executable: URL,
        arguments: [String],
        environment: [String: String]? = nil
    ) async throws -> (exitCode: Int32, duration: TimeInterval, stderr: String) {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global().async {
                do {
                    let result = try runProcessCapturingStderr(
                        executable: executable,
                        arguments: arguments,
                        environment: environment
                    )
                    continuation.resume(returning: result)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// Run a process and capture both stdout and stderr (for diagnostic logging).
    public static func runProcessCapturingAll(
        executable: URL,
        arguments: [String],
        environment: [String: String]? = nil
    ) throws -> (exitCode: Int32, duration: TimeInterval, stderr: String, stdout: String) {
        let startTime = Date()
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = environment ?? cleanEnvironment()

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        try process.run()
        process.waitUntilExit()

        let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let stdout = String(data: stdoutData, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        let stderr = String(data: stderrData, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        let duration = Date().timeIntervalSince(startTime)
        return (process.terminationStatus, duration, stderr, stdout)
    }

    /// Run a process asynchronously with both stdout and stderr capture.
    public static func runProcessAsyncCapturingAll(
        executable: URL,
        arguments: [String],
        environment: [String: String]? = nil
    ) async throws -> (exitCode: Int32, duration: TimeInterval, stderr: String, stdout: String) {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global().async {
                do {
                    let result = try runProcessCapturingAll(
                        executable: executable,
                        arguments: arguments,
                        environment: environment
                    )
                    continuation.resume(returning: result)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// Run a process asynchronously, returning early if it exceeds the timeout.
    /// If the timeout elapses, the process is left running (unless terminateOnTimeout is true).
    public static func runProcessAsyncBestEffort(
        executable: URL,
        arguments: [String],
        environment: [String: String]? = nil,
        timeoutSeconds: TimeInterval,
        terminateOnTimeout: Bool = false
    ) async throws -> (exitCode: Int32, duration: TimeInterval, timedOut: Bool) {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global().async {
                let startTime = Date()
                let process = Process()
                process.executableURL = executable
                process.arguments = arguments
                process.environment = environment ?? cleanEnvironment()
                process.standardOutput = FileHandle.nullDevice
                process.standardError = FileHandle.nullDevice

                let semaphore = DispatchSemaphore(value: 0)
                process.terminationHandler = { _ in
                    semaphore.signal()
                }

                do {
                    try process.run()
                } catch {
                    continuation.resume(throwing: error)
                    return
                }

                let timedOut = semaphore.wait(timeout: .now() + timeoutSeconds) == .timedOut
                if timedOut, terminateOnTimeout {
                    process.terminate()
                }

                let duration = Date().timeIntervalSince(startTime)
                let exitCode: Int32 = timedOut ? 0 : process.terminationStatus
                continuation.resume(returning: (exitCode, duration, timedOut))
            }
        }
    }

    /// Get the PID of a recently launched app by bundle ID
    public static func findPID(forBundleID bundleId: String, launchedAfter: Date) -> pid_t? {
        NSWorkspace.shared.runningApplications
            .first { $0.bundleIdentifier == bundleId && $0.launchDate ?? .distantPast > launchedAfter }?
            .processIdentifier
    }

    // MARK: - Shell / AppleScript Quoting

    /// POSIX single-quote a shell argument (wraps in '…' and escapes any embedded single quotes).
    public static func shellQuote(_ value: String) -> String {
        let escaped = value.replacingOccurrences(of: "'", with: "'\"'\"'")
        return "'\(escaped)'"
    }

    /// Single-quote each argument and join them with spaces into one shell command string.
    public static func shellJoin(_ arguments: [String]) -> String {
        arguments.map(shellQuote).joined(separator: " ")
    }

    /// Escape a string for safe interpolation inside an AppleScript double-quoted literal.
    public static func escapeAppleScript(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    /// Render a Swift string array as an AppleScript list literal (e.g. {"a", "b"}).
    public static func appleScriptList(_ values: [String]) -> String {
        guard !values.isEmpty else { return "{}" }
        let items = values.map { "\"\(escapeAppleScript($0))\"" }
        return "{\(items.joined(separator: ", "))}"
    }

    /// Collapse newlines so a command string can be logged on a single trace line.
    public static func sanitizeCommandForTrace(_ command: String) -> String {
        command.replacingOccurrences(of: "\n", with: " ")
    }
}
