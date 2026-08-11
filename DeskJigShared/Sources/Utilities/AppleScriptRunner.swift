//
//  AppleScriptRunner.swift
//  DeskJigShared
//
//  Canonical entry point for ALL AppleScript execution in the codebase.
//
//  Two engines are supported, and the distinction is load-bearing — do not
//  "simplify" a call site from one engine to the other:
//
//  - `.inProcess` (NSAppleScript): runs inside the calling process, so Apple
//    Events and System Events UI scripting are attributed to the host app's
//    identity. Required when the script needs the app's TCC grants
//    (Accessibility/Automation permission, e.g. System Events menu clicks),
//    or when `do shell script ... with administrator privileges` should show
//    the auth dialog as coming from the app. NSAppleScript has NO timeout
//    support — a hung script blocks the calling thread indefinitely — and it
//    is not thread-safe; the CALLER chooses the thread (several sites
//    deliberately dispatch to the main queue). This runner never re-dispatches.
//
//  - `.osascript` (/usr/bin/osascript subprocess): runs out-of-process, so a
//    hung script (e.g. blocked on a TCC prompt) can be killed via `timeout`,
//    and Apple Events are attributed to osascript rather than the host app.
//    Preferred for Chrome automation (see `shouldUseOsascript`) and for
//    terminal launching during restoration. The subprocess inherits the
//    parent's TCC context for Automation prompts but NOT the app's
//    Accessibility grant — System Events UI-element access will fail here.
//
//  - `.auto` resolves via `shouldUseOsascript` (env-overridable:
//    BENTO_CHROME_OSASCRIPT=1 forces osascript, BENTO_CHROME_NSAPPLESCRIPT=1
//    forces in-process; default is osascript).
//

import Foundation

// MARK: - Engine selection

/// The engine that actually executed (or was selected to execute) a script.
public enum AppleScriptEngine: String, Sendable {
    /// NSAppleScript inside the calling process. Caller-controlled threading, no timeout.
    case inProcess = "in-process"
    /// /usr/bin/osascript subprocess. Supports timeouts; separate TCC identity.
    case osascript
}

/// Caller's engine preference for the unified `run(_:engine:timeout:)` entry point.
public enum AppleScriptEngineChoice: Sendable {
    /// Force NSAppleScript in-process execution (needed for app-attributed TCC/auth flows).
    case inProcess
    /// Force an osascript subprocess (needed for timeout/kill semantics).
    case osascript
    /// Resolve via `AppleScriptRunner.shouldUseOsascript` (env-overridable).
    case auto

    /// The concrete engine this choice resolves to right now.
    public var resolved: AppleScriptEngine {
        switch self {
        case .inProcess: return .inProcess
        case .osascript: return .osascript
        case .auto: return AppleScriptRunner.shouldUseOsascript ? .osascript : .inProcess
        }
    }
}

// MARK: - Errors

/// Typed error for AppleScript execution failures, carrying the AppleScript
/// error number (when the engine provides one), the failure message, the
/// stage at which the failure occurred, and which engine ran the script.
public struct AppleScriptError: Error, CustomStringConvertible, Sendable {
    public enum Stage: String, Sendable {
        /// NSAppleScript(source:) returned nil (script could not be compiled/created).
        case compile
        /// The osascript subprocess could not be launched.
        case launch
        /// The script ran and reported an error (NSAppleScript error dictionary,
        /// or osascript nonzero exit).
        case execute
        /// The osascript subprocess exceeded its timeout and was killed.
        case timeout
    }

    /// Engine that ran (or attempted to run) the script.
    public let engine: AppleScriptEngine
    /// Where in the lifecycle the failure occurred.
    public let stage: Stage
    /// AppleScript error number (`NSAppleScript.errorNumber`), when available.
    /// osascript failures generally do not carry a structured number.
    public let errorNumber: Int?
    /// Human-readable failure message (NSAppleScript errorMessage, or osascript stderr).
    public let message: String

    public init(engine: AppleScriptEngine, stage: Stage, errorNumber: Int? = nil, message: String) {
        self.engine = engine
        self.stage = stage
        self.errorNumber = errorNumber
        self.message = message
    }

    /// True when the osascript subprocess was killed for exceeding its timeout.
    public var timedOut: Bool { stage == .timeout }

    /// True when the user canceled the script (AppleScript error -128), e.g.
    /// dismissing an administrator-privileges auth dialog.
    public var isUserCanceled: Bool { errorNumber == -128 }

    public var description: String {
        let number = errorNumber.map { " (error \($0))" } ?? ""
        return "AppleScript \(stage.rawValue) failure via \(engine.rawValue)\(number): \(message)"
    }
}

// MARK: - Results

/// Raw result of an osascript subprocess run (non-throwing API surface).
public struct AppleScriptProcessResult {
    public let output: String
    public let errorOutput: String
    public let exitCode: Int32
    public let timedOut: Bool
    /// Wall-clock duration of the subprocess run.
    public let duration: TimeInterval

    public var trimmedOutput: String {
        output.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Result of the unified throwing `run(_:engine:timeout:)` entry point.
public struct AppleScriptRunResult {
    /// Engine that actually executed the script.
    public let engine: AppleScriptEngine
    /// String output: `stringValue` of the result descriptor (in-process) or
    /// trimmed stdout (osascript). Nil/empty when the script returned nothing.
    public let output: String?
    /// The raw event descriptor — in-process engine only.
    public let descriptor: NSAppleEventDescriptor?
    /// Wall-clock execution duration.
    public let duration: TimeInterval
}

// MARK: - Runner

public enum AppleScriptRunner {
    public static let defaultTimeout: TimeInterval = 6.0

    /// Whether `.auto` engine selection should use the osascript subprocess.
    /// Env overrides: `BENTO_CHROME_OSASCRIPT=1` forces osascript,
    /// `BENTO_CHROME_NSAPPLESCRIPT=1` forces in-process. Defaults to osascript.
    public static var shouldUseOsascript: Bool {
        if let override = ProcessInfo.processInfo.environment["BENTO_CHROME_OSASCRIPT"] {
            return override == "1"
        }
        if ProcessInfo.processInfo.environment["BENTO_CHROME_NSAPPLESCRIPT"] == "1" {
            return false
        }
        return true
    }

    // MARK: In-process engine (NSAppleScript)

    /// Execute a script in-process via NSAppleScript.
    ///
    /// Engine semantics: runs with the host app's identity and TCC grants
    /// (Accessibility, Automation, admin-privileges auth dialogs). There is NO
    /// timeout — a hung script blocks the calling thread. NSAppleScript is not
    /// thread-safe; this method executes synchronously on the CALLING thread
    /// and never re-dispatches, so call sites that require main-thread
    /// execution must dispatch themselves (mirroring pre-consolidation code).
    ///
    /// - Returns: The result event descriptor. Sites that only care about
    ///   success can ignore it.
    /// - Throws: `AppleScriptError` with `stage == .compile` when the script
    ///   cannot be created, or `stage == .execute` with the AppleScript
    ///   errorNumber/errorMessage when execution fails.
    @discardableResult
    public static func runInProcess(_ script: String) throws -> NSAppleEventDescriptor {
        guard let appleScript = NSAppleScript(source: script) else {
            throw AppleScriptError(
                engine: .inProcess,
                stage: .compile,
                message: "Failed to create NSAppleScript instance"
            )
        }

        var errorDictionary: NSDictionary?
        let result = appleScript.executeAndReturnError(&errorDictionary)

        if let errorDictionary {
            let errorNumber = errorDictionary[NSAppleScript.errorNumber] as? Int
            let message = errorDictionary[NSAppleScript.errorMessage] as? String
                ?? "Unknown AppleScript error"
            throw AppleScriptError(
                engine: .inProcess,
                stage: .execute,
                errorNumber: errorNumber,
                message: message
            )
        }

        return result
    }

    // MARK: osascript engine (subprocess)

    /// Execute a script via an osascript subprocess, blocking the calling
    /// thread until completion or timeout.
    ///
    /// Engine semantics: out-of-process, killable. On timeout the process is
    /// SIGTERMed, then SIGKILLed if still alive (osascript blocked on a TCC
    /// dialog ignores SIGTERM). The script is fed via stdin (`-l AppleScript`),
    /// which avoids argv length limits and is equivalent to `-e` per line.
    ///
    /// - Parameters:
    ///   - timeout: Maximum wall-clock run time. Pass `nil` to wait
    ///     indefinitely (used by terminal-launch paths that must not kill a
    ///     slow window creation).
    ///   - environment: Environment for the subprocess. `nil` (default)
    ///     inherits the parent process environment. Terminal-launch paths pass
    ///     `LauncherUtils.cleanEnvironment()` so `DYLD_*`/`__XPC*`/`XCODE*`
    ///     variables from Xcode/LLDB don't leak into launched shells.
    public static func runOsascript(
        _ script: String,
        timeout: TimeInterval? = defaultTimeout,
        environment: [String: String]? = nil
    ) -> AppleScriptProcessResult {
        let startTime = Date()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-l", "AppleScript"]
        if let environment {
            process.environment = environment
        }

        let inputPipe = Pipe()
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        do {
            try process.run()
        } catch {
            return AppleScriptProcessResult(
                output: "",
                errorOutput: "osascript launch failed: \(error.localizedDescription)",
                exitCode: -1,
                timedOut: false,
                duration: Date().timeIntervalSince(startTime)
            )
        }

        if let data = script.data(using: .utf8) {
            inputPipe.fileHandleForWriting.write(data)
        }
        inputPipe.fileHandleForWriting.closeFile()

        let deadline = timeout.map { Date().addingTimeInterval($0) }
        while process.isRunning {
            if let deadline, Date() >= deadline { break }
            Thread.sleep(forTimeInterval: 0.05)
        }

        if process.isRunning {
            process.terminate()
            // SIGTERM may not kill osascript if it's blocked on a TCC dialog — SIGKILL as fallback
            Thread.sleep(forTimeInterval: 0.5)
            if process.isRunning {
                kill(process.processIdentifier, SIGKILL)
            }
            let timeoutMs = Int((timeout ?? 0) * 1000)
            return AppleScriptProcessResult(
                output: "",
                errorOutput: "osascript timed out after \(timeoutMs)ms",
                exitCode: process.terminationStatus,
                timedOut: true,
                duration: Date().timeIntervalSince(startTime)
            )
        }

        let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
        let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()

        let output = String(data: outputData, encoding: .utf8) ?? ""
        let errorOutput = String(data: errorData, encoding: .utf8) ?? ""

        return AppleScriptProcessResult(
            output: output,
            errorOutput: errorOutput,
            exitCode: process.terminationStatus,
            timedOut: false,
            duration: Date().timeIntervalSince(startTime)
        )
    }

    /// Async wrapper around `runOsascript` that runs the blocking subprocess
    /// wait off the calling executor. Same engine semantics as `runOsascript`.
    public static func runOsascriptAsync(
        _ script: String,
        timeout: TimeInterval? = defaultTimeout,
        environment: [String: String]? = nil
    ) async -> AppleScriptProcessResult {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: runOsascript(script, timeout: timeout, environment: environment))
            }
        }
    }

    // MARK: Unified entry point

    /// Execute a script with an explicit engine choice, throwing a typed
    /// `AppleScriptError` on failure.
    ///
    /// - Parameters:
    ///   - engine: `.inProcess`, `.osascript`, or `.auto` (resolves via
    ///     `shouldUseOsascript`). See the file header for when each engine is
    ///     required — the choice is behavioral, not stylistic.
    ///   - timeout: Applies to the osascript engine only; the in-process
    ///     engine cannot be interrupted and ignores it. `nil` waits forever.
    /// - Returns: `AppleScriptRunResult` with the resolved engine, string
    ///   output, and (for in-process runs) the raw event descriptor.
    @discardableResult
    public static func run(
        _ script: String,
        engine: AppleScriptEngineChoice = .auto,
        timeout: TimeInterval? = defaultTimeout
    ) throws -> AppleScriptRunResult {
        switch engine.resolved {
        case .inProcess:
            let startTime = Date()
            let descriptor = try runInProcess(script)
            return AppleScriptRunResult(
                engine: .inProcess,
                output: descriptor.stringValue,
                descriptor: descriptor,
                duration: Date().timeIntervalSince(startTime)
            )
        case .osascript:
            let result = runOsascript(script, timeout: timeout)
            if result.timedOut {
                throw AppleScriptError(
                    engine: .osascript,
                    stage: .timeout,
                    message: result.errorOutput
                )
            }
            if result.exitCode != 0 {
                let message = result.errorOutput.isEmpty
                    ? "osascript exited with code \(result.exitCode)"
                    : result.errorOutput
                throw AppleScriptError(
                    engine: .osascript,
                    stage: result.exitCode == -1 && result.errorOutput.hasPrefix("osascript launch failed") ? .launch : .execute,
                    message: message
                )
            }
            return AppleScriptRunResult(
                engine: .osascript,
                output: result.trimmedOutput,
                descriptor: nil,
                duration: result.duration
            )
        }
    }
}
