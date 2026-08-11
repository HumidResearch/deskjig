//  TmuxCommandService.swift
//  DeskJigShared

import Foundation

// MARK: - Tmux Client Info

/// Information about a connected tmux client.
public struct TmuxClientInfo: Sendable {
    /// The client's TTY path (e.g., /dev/ttys001)
    public let clientTTY: String
    /// The session name this client is attached to
    public let sessionName: String
    /// The PID of the client process
    public let clientPID: pid_t

    public init(clientTTY: String, sessionName: String, clientPID: pid_t) {
        self.clientTTY = clientTTY
        self.sessionName = sessionName
        self.clientPID = clientPID
    }
}

// MARK: - Tmux Session Info

/// Information about a tmux session.
public struct TmuxSessionInfo: Sendable {
    /// The session name
    public let sessionName: String
    /// Whether the session has any attached clients
    public let isAttached: Bool
    /// The session's working directory
    public let sessionPath: String

    public init(sessionName: String, isAttached: Bool, sessionPath: String) {
        self.sessionName = sessionName
        self.isAttached = isAttached
        self.sessionPath = sessionPath
    }
}

// MARK: - Tmux Command Service

/// Actor wrapping all tmux CLI calls via `Process()`.
///
/// Provides low-level tmux operations used by `TmuxSessionManager` for
/// workspace-level session coordination. Each method maps to a single
/// tmux command invocation.
///
/// ## Overview
///
/// - Auto-detects tmux binary location
/// - Uses `Process()` with cleaned environment (same pattern as `FluentGhosttyLauncher`)
/// - 5-second timeout per command
/// - All operations are idempotent where possible
///
/// ## Example
///
/// ```swift
/// let tmux = TmuxCommandService()
///
/// if await tmux.isAvailable {
///     try await tmux.ensureSession(name: "bento_a1b2c3d4_f1a2b3c4", workingDirectory: "~/code/deskjig")
///     let sessions = try await tmux.listSessions()
/// }
/// ```
public actor TmuxCommandService {

    // MARK: - Properties

    private var resolvedBinaryPath: String?
    private var availabilityChecked = false

    /// Common tmux binary locations to search
    private static let binarySearchPaths = [
        "/opt/homebrew/bin/tmux",
        "/usr/local/bin/tmux",
        "/usr/bin/tmux",
        "/bin/tmux"
    ]

    /// Stable DeskJig tmux socket path shared by app- and terminal-launched tmux commands.
    public static var deskJigSocketPath: String {
        "/tmp/\(BundleIdentity.tmuxSocketPrefix)-\(getuid()).sock"
    }

    static func shouldMutateExistingSessionWorkingDirectory() -> Bool {
        false
    }

    /// Timeout for each tmux command in seconds
    private let commandTimeout: TimeInterval = 5.0
    // Logging via DeskJigLog(.tmux)

    // MARK: - Initialization

    public init() {}

    // MARK: - Availability

    /// Whether tmux is installed and available on the system.
    public var isAvailable: Bool {
        get async {
            if !availabilityChecked {
                resolvedBinaryPath = Self.findTmuxBinary()
                availabilityChecked = true
            }
            return resolvedBinaryPath != nil
        }
    }

    /// The resolved tmux binary path, or nil if not available.
    public var binaryPath: String? {
        get async {
            if !availabilityChecked {
                resolvedBinaryPath = Self.findTmuxBinary()
                availabilityChecked = true
            }
            return resolvedBinaryPath
        }
    }

    // MARK: - Session Operations

    /// Creates a tmux session if it doesn't already exist (idempotent).
    ///
    /// Uses `tmux new-session -A -d -s <name> -c <dir>` which attaches to an
    /// existing session or creates a new one.
    ///
    /// - Parameters:
    ///   - name: The session name
    ///   - workingDirectory: The initial working directory for the session
    /// - Throws: If the tmux command fails
    public func ensureSession(name: String, workingDirectory: String) async throws {
        // Check if session already exists first — `new-session -A -d` fails with
        // "not a terminal" when the session exists because -A tries to attach.
        if await sessionExists(name: name) {
            // Preserve session history/cwd for existing sessions.
            DeskJigLog.trace(.tmux, "session-exists-preserving-history session=\(name) directory=\(workingDirectory)")
            return
        }

        let expandedDir = (workingDirectory as NSString).expandingTildeInPath
        // -d: detached (don't attach this process)
        try runTmux(["new-session", "-d", "-s", name, "-c", expandedDir])
    }

    /// Checks whether a session with the given name exists.
    ///
    /// - Parameter name: The session name to check
    /// - Returns: `true` if the session exists
    public func sessionExists(name: String) async -> Bool {
        do {
            try runTmux(["has-session", "-t", name])
            return true
        } catch {
            return false
        }
    }

    /// Lists all tmux sessions with structured output.
    ///
    /// - Returns: Array of session information
    /// - Throws: If the tmux command fails
    public func listSessions() async throws -> [TmuxSessionInfo] {
        let output = try runTmuxWithOutput(
            ["list-sessions", "-F", "#{session_name}|||#{session_attached}|||#{session_path}"]
        )

        return output.components(separatedBy: "\n")
            .filter { !$0.isEmpty }
            .compactMap { line -> TmuxSessionInfo? in
                let parts = line.components(separatedBy: "|||")
                guard parts.count >= 3 else { return nil }
                return TmuxSessionInfo(
                    sessionName: parts[0],
                    isAttached: parts[1] == "1",
                    sessionPath: parts[2]
                )
            }
    }

    /// Lists all connected tmux clients with structured output.
    ///
    /// - Returns: Array of client information
    /// - Throws: If the tmux command fails
    public func listClients() async throws -> [TmuxClientInfo] {
        let output = try runTmuxWithOutput(
            ["list-clients", "-F", "#{client_tty}|||#{session_name}|||#{client_pid}"]
        )
        return output.components(separatedBy: "\n")
            .filter { !$0.isEmpty }
            .compactMap { line -> TmuxClientInfo? in
                let parts = line.components(separatedBy: "|||")
                guard parts.count >= 3,
                      let pid = Int32(parts[2]) else { return nil }
                return TmuxClientInfo(clientTTY: parts[0], sessionName: parts[1], clientPID: pid)
            }
    }

    /// Lists tmux clients attached to a specific session.
    ///
    /// - Parameter sessionName: The session to list clients for
    /// - Returns: Array of client information for that session
    /// - Throws: If the tmux command fails
    public func listClientsForSession(_ sessionName: String) async throws -> [TmuxClientInfo] {
        let output = try runTmuxWithOutput(
            ["list-clients", "-t", sessionName,
             "-F", "#{client_tty}|||#{session_name}|||#{client_pid}"]
        )

        return output.components(separatedBy: "\n")
            .filter { !$0.isEmpty }
            .compactMap { line -> TmuxClientInfo? in
                let parts = line.components(separatedBy: "|||")
                guard parts.count >= 3,
                      let pid = Int32(parts[2]) else { return nil }
                return TmuxClientInfo(
                    clientTTY: parts[0],
                    sessionName: parts[1],
                    clientPID: pid
                )
            }
    }

    /// Returns raw diagnostic output from `list-clients` for debugging.
    ///
    /// Uses an independent inline Process (not `runTmuxWithOutput`) so diagnostics
    /// work even if the shared helper has issues.
    public func listClientsDiagnostic() async -> String {
        let socketPath = Self.deskJigSocketPath
        let binary = resolvedBinaryPath ?? Self.findTmuxBinary() ?? "(not found)"

        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = Self.withSocketArguments(
            ["list-clients", "-F", "#{client_tty}|||#{session_name}|||#{client_pid}"]
        )
        process.environment = Self.cleanedEnvironment()

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        var result: String?
        do {
            try process.run()
            process.waitUntilExit()
            let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
            _ = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            if process.terminationStatus == 0 {
                result = String(data: stdoutData, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
        } catch {
            // Process launch failed
        }

        return "binary=\(binary) socket=\(socketPath) stdout=[\(result ?? "(nil)")] stdoutBytes=\(result?.count ?? 0)"
    }

    /// Switches a tmux client to a different session.
    ///
    /// This is the core fast-switch operation (~5ms). It changes which session
    /// a terminal window displays without closing or opening anything.
    ///
    /// - Parameters:
    ///   - clientTTY: The client TTY to switch (e.g., /dev/ttys001)
    ///   - session: The target session name
    /// - Throws: If the tmux command fails
    public func switchClient(clientTTY: String, toSession session: String) async throws {
        try runTmux(["switch-client", "-c", clientTTY, "-t", session])
    }

    /// Sets a global tmux option on the DeskJig tmux server.
    ///
    /// - Parameters:
    ///   - option: The option name (e.g., "mouse")
    ///   - value: The option value (e.g., "off")
    /// - Throws: If the tmux command fails
    public func setGlobalOption(_ option: String, value: String) async throws {
        try runTmux(["set-option", "-g", option, value])
    }

    /// Sets the pane title for the first pane of a tmux session.
    ///
    /// Combined with `ensureTitlePropagation()`, this causes the terminal's
    /// CGWindowList title to update to the pane title — enabling reliable
    /// window matching by indexed title during fast-switch restoration.
    ///
    /// - Parameters:
    ///   - session: The target session name
    ///   - title: The title to set on the pane
    /// - Throws: If the tmux command fails
    public func setPaneTitle(session: String, title: String) async throws {
        try runTmux(["select-pane", "-t", session, "-T", title])
    }

    /// Sends keys to the first pane of a tmux session.
    ///
    /// Used to change the working directory in a pane when the window
    /// already owns its session (e.g., quick-switch path updates).
    ///
    /// - Parameters:
    ///   - session: The target session name
    ///   - keys: The key string to send
    ///   - pressEnter: Whether to append Enter (default: true)
    public func sendKeys(session: String, keys: String, pressEnter: Bool = true) async throws {
        var args = ["send-keys", "-t", session, keys]
        if pressEnter { args.append("Enter") }
        try runTmux(args)
    }

    /// Gets the pane title of the first pane in a tmux session.
    ///
    /// Used to check whether a session's pane already has the expected
    /// indexed managed title — indicating a window is displaying it.
    public func getPaneTitle(session: String) async throws -> String? {
        let output = try runTmuxWithOutput(["display-message", "-t", session, "-p", "#{pane_title}"])
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Ensures tmux is configured to propagate pane titles to the terminal window title.
    ///
    /// Sets `set-titles on` and `set-titles-string #{pane_title}` globally. These are
    /// idempotent and only need to be called once per restore run. The caller should
    /// cache this to avoid redundant calls.
    ///
    /// - Throws: If the tmux command fails
    public func ensureTitlePropagation() async throws {
        try runTmux(["set-option", "-g", "set-titles", "on"])
        try runTmux(["set-option", "-g", "set-titles-string", "#{pane_title}"])
    }

    /// Kills a tmux session.
    ///
    /// - Parameter name: The session name to kill
    /// - Throws: If the tmux command fails
    public func killSession(name: String) async throws {
        try runTmux(["kill-session", "-t", name])
    }

    /// Returns the tmux version string (e.g., "tmux 3.4").
    ///
    /// Runs `tmux -V` which doesn't require a socket connection.
    /// - Returns: The version string, or nil if tmux is not available
    public func version() async -> String? {
        guard let binary = resolvedBinaryPath ?? Self.findTmuxBinary() else {
            return nil
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = ["-V"]
        process.environment = Self.cleanedEnvironment()

        let stdoutPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = Pipe()

        do {
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            let data = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
            return String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            return nil
        }
    }

    /// Kills the entire DeskJig tmux server (all sessions and clients on the DeskJig socket).
    ///
    /// Sessions will be recreated on next workspace restoration.
    /// - Throws: If the tmux command fails
    public func killServer() async throws {
        try runTmux(["kill-server"])
    }

    /// Lists only DeskJig-managed tmux sessions.
    ///
    /// The `bento_` prefix is the legacy session namespace and remains unchanged so
    /// existing live sessions continue to attach after the product rename.
    ///
    /// - Returns: Array of session information for managed sessions
    /// - Throws: If the tmux command fails
    public func listManagedSessions() async throws -> [TmuxSessionInfo] {
        let allSessions = try await listSessions()
        return allSessions.filter { $0.sessionName.hasPrefix("bento_") }
    }

    // MARK: - Private Helpers

    /// Finds the tmux binary on the system.
    private static func findTmuxBinary() -> String? {
        for path in binarySearchPaths {
            if FileManager.default.isExecutableFile(atPath: path) {
                return path
            }
        }

        // Fallback: try `which tmux` via shell
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        process.arguments = ["tmux"]
        process.environment = cleanedEnvironment()

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()

        do {
            try process.run()
            process.waitUntilExit()

            if process.terminationStatus == 0 {
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                let path = String(data: data, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if let path, !path.isEmpty, FileManager.default.isExecutableFile(atPath: path) {
                    return path
                }
            }
        } catch {
            // which not found or failed
        }

        return nil
    }

    /// Prefixes tmux CLI arguments with the DeskJig socket so all callers operate
    /// on the same tmux server (critical for reliable client discovery/switching).
    private static func withSocketArguments(_ arguments: [String]) -> [String] {
        ["-S", deskJigSocketPath] + arguments
    }

    /// Runs a tmux command, discarding output.
    ///
    /// Runs synchronously on the actor thread. tmux commands complete in < 100ms
    /// via the local Unix socket, so blocking the actor briefly is acceptable and
    /// avoids the GCD dispatch issues that cause pipe reads to return empty data.
    ///
    /// A safety timeout terminates the process if it doesn't exit within 10 seconds,
    /// preventing a stuck tmux server from blocking the entire restoration.
    @discardableResult
    private func runTmux(_ arguments: [String]) throws -> Int32 {
        guard let binary = resolvedBinaryPath ?? Self.findTmuxBinary() else {
            throw TmuxError.notAvailable
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = Self.withSocketArguments(arguments)
        process.environment = Self.cleanedEnvironment()
        process.standardOutput = Pipe()
        let stderrPipe = Pipe()
        process.standardError = stderrPipe

        try process.run()

        // Safety timeout: terminate the process if it doesn't exit within 10s.
        // tmux commands normally complete in <100ms via the Unix socket; a hang
        // here indicates a stuck tmux server or broken pipe.
        let processRef = process
        let timeoutItem = DispatchWorkItem { processRef.terminate() }
        DispatchQueue.global().asyncAfter(deadline: .now() + 10, execute: timeoutItem)

        process.waitUntilExit()
        timeoutItem.cancel()

        if process.terminationReason == .uncaughtSignal {
            throw TmuxError.timeout(command: arguments.joined(separator: " "))
        }

        let exitCode = process.terminationStatus
        if exitCode != 0 {
            let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            let stderr = String(data: stderrData, encoding: .utf8) ?? ""
            throw TmuxError.commandFailed(
                command: arguments.joined(separator: " "),
                exitCode: exitCode,
                stderr: stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }

        return exitCode
    }

    /// Runs a tmux command and returns stdout.
    ///
    /// Runs synchronously on the actor thread — same pattern as
    /// `listClientsDiagnostic()` which reliably returns output. The previous
    /// `withCheckedThrowingContinuation` + `DispatchQueue.global().async` approach
    /// consistently returned empty pipe data despite the process exiting with
    /// code 0 and correct output (confirmed by the synchronous diagnostic).
    private func runTmuxWithOutput(_ arguments: [String]) throws -> String {
        guard let binary = resolvedBinaryPath ?? Self.findTmuxBinary() else {
            throw TmuxError.notAvailable
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = Self.withSocketArguments(arguments)
        process.environment = Self.cleanedEnvironment()

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        try process.run()

        // Safety timeout (same as runTmux)
        let processRef = process
        let timeoutItem = DispatchWorkItem { processRef.terminate() }
        DispatchQueue.global().asyncAfter(deadline: .now() + 10, execute: timeoutItem)

        process.waitUntilExit()
        timeoutItem.cancel()

        if process.terminationReason == .uncaughtSignal {
            throw TmuxError.timeout(command: arguments.joined(separator: " "))
        }

        let exitCode = process.terminationStatus

        if exitCode != 0 {
            let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            let stderr = String(data: stderrData, encoding: .utf8) ?? ""
            throw TmuxError.commandFailed(
                command: arguments.joined(separator: " "),
                exitCode: exitCode,
                stderr: stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }

        // Drain stderr unconditionally after waitUntilExit(). Not reading both
        // pipes after process exit can cause stdout data loss on macOS.
        _ = stderrPipe.fileHandleForReading.readDataToEndOfFile()

        let data = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        return output
    }

    /// Clean environment to strip Xcode/debugger variables that interfere with CLI tools.
    static func cleanedEnvironment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment

        let variablesToStrip = [
            "__XCODE_BUILT_PRODUCTS_DIR_PATHS",
            "DYLD_INSERT_LIBRARIES",
            "DYLD_LIBRARY_PATH",
            "DYLD_FRAMEWORK_PATH",
            "__XPC_DYLD_LIBRARY_PATH",
            "__XPC_DYLD_FRAMEWORK_PATH",
            // Avoid inheriting client-specific tmux socket context from parent
            // processes (e.g., running inside an existing tmux client).
            "TMUX",
            "TMUX_PANE",
            "TMUX_TMPDIR"
        ]

        for varName in variablesToStrip {
            env.removeValue(forKey: varName)
        }

        let keysToRemove = env.keys.filter { key in
            key.hasPrefix("__XCODE") || key.hasPrefix("LLDB_")
        }
        for key in keysToRemove {
            env.removeValue(forKey: key)
        }

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

    // MARK: - Homebrew Detection & Install

    /// Finds the Homebrew binary on the system.
    /// Checks Apple Silicon path first, then Intel path.
    public static func findHomebrewBinary() -> String? {
        let candidates = [
            "/opt/homebrew/bin/brew",  // Apple Silicon
            "/usr/local/bin/brew"      // Intel
        ]
        for path in candidates {
            if FileManager.default.isExecutableFile(atPath: path) {
                return path
            }
        }
        return nil
    }

    /// Installs tmux via Homebrew.
    /// Returns a tuple indicating success and output/error text.
    public static func installViaHomebrew() async -> (success: Bool, output: String) {
        guard let brewPath = findHomebrewBinary() else {
            return (false, "Homebrew is not installed. Install it from https://brew.sh and try again.")
        }

        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: brewPath)
                process.arguments = ["install", "tmux"]
                process.environment = cleanedEnvironment()

                let stdoutPipe = Pipe()
                let stderrPipe = Pipe()
                process.standardOutput = stdoutPipe
                process.standardError = stderrPipe

                do {
                    try process.run()
                    process.waitUntilExit()

                    let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                    let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                    let stdout = String(data: stdoutData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    let stderr = String(data: stderrData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

                    if process.terminationStatus == 0 {
                        continuation.resume(returning: (true, stdout.isEmpty ? "tmux installed successfully." : stdout))
                    } else {
                        let combined = [stdout, stderr].filter { !$0.isEmpty }.joined(separator: "\n")
                        continuation.resume(returning: (false, combined.isEmpty ? "brew install tmux failed (exit \(process.terminationStatus))." : combined))
                    }
                } catch {
                    continuation.resume(returning: (false, "Failed to launch brew: \(error.localizedDescription)"))
                }
            }
        }
    }
}

// MARK: - Tmux Errors

/// Errors from tmux command execution.
public enum TmuxError: Error, LocalizedError {
    case notAvailable
    case timeout(command: String)
    case commandFailed(command: String, exitCode: Int32, stderr: String)

    public var errorDescription: String? {
        switch self {
        case .notAvailable:
            return "tmux is not installed or not found in PATH"
        case .timeout(let command):
            return "tmux command timed out: \(command)"
        case .commandFailed(let command, let exitCode, let stderr):
            return "tmux command failed (exit \(exitCode)): \(command)\(stderr.isEmpty ? "" : " - \(stderr)")"
        }
    }
}
