//  FluentGhosttyLauncher.swift
//  DeskJigShared

import Foundation
import AppKit

public struct FluentGhosttyLauncher: FluentAppLauncher {
    public let bundleId = "com.mitchellh.ghostty"
    public let appName = "Ghostty"
    /// Alias for backward compatibility — canonical constant is `BundleRegistry.managedTmuxWindowTitle`.
    public static var managedTmuxWindowTitle: String { BundleRegistry.managedTmuxWindowTitle }

    public init() {}

    public func launch(
        directory: String?,
        title: String?,
        task: RestorationTaskContext
    ) async throws -> ExpLaunchResult {
        let startTime = Date()

        DeskJigLog.debug(.restorationTrace, "Launching \(appName)", fields: [
            "taskId": task.taskId,
            "taskType": task.taskType.rawValue,
            "app": appName,
            "method": "cli",
            "directory": directory ?? "none"
        ], runId: task.runId)

        // Get the full Ghostty app path
        let ghosttyAppPath = NSWorkspace.shared.urlForApplication(
            withBundleIdentifier: bundleId
        )?.path ?? "/Applications/Ghostty.app"

        // Build arguments: open -na <app> --args --working-directory=<path> --title=<title>
        var args = ["-na", ghosttyAppPath, "--args"]
        if let dir = directory {
            args.append("--working-directory=\(dir)")
        }
        // Add title for window identification during restoration
        if let title = title {
            args.append("--title=\(title)")
            // Prevent shell from overriding the title
            args.append("--shell-integration-features=no-title")
        }
        // Prevent window state restoration from interfering
        args.append("--window-save-state=never")

        // Use Process directly with cleaned environment
        // This is critical - Xcode/debugger env vars interfere with Ghostty CLI args
        do {
            // Off-actor launch (launch-01 / fluent-03): run /usr/bin/open on a background
            // queue so the cooperative pool / executor isn't blocked on waitUntilExit while
            // sibling launches proceed. durationMs/exitCode semantics are preserved.
            let launchResult = try await LauncherUtils.runProcessAsync(
                executable: URL(fileURLWithPath: "/usr/bin/open"),
                arguments: args,
                environment: LauncherUtils.cleanLaunchEnvironment(stripTmux: true)
            )

            let durationMs = Int(Date().timeIntervalSince(startTime) * 1000)
            let exitCode = launchResult.exitCode

            DeskJigLog.debug(.restorationTrace, "Ghostty launch \(exitCode == 0 ? "completed" : "failed")", fields: [
                "taskId": task.taskId,
                "taskType": task.taskType.rawValue,
                "durationMs": "\(durationMs)",
                "exitCode": "\(exitCode)",
                "title": title ?? "none"
            ], runId: task.runId)

            var notes: [String] = []
            if let dir = directory { notes.append("directory=\(dir)") }
            if let title = title { notes.append("title=\(title)") }

            return ExpLaunchResult(
                success: exitCode == 0,
                launchDurationMs: durationMs,
                method: .cli,
                notes: notes
            )
        } catch {
            let durationMs = Int(Date().timeIntervalSince(startTime) * 1000)
            DeskJigLog.debug(.restorationTrace, "Ghostty launch error: \(error.localizedDescription)", fields: [
                "taskId": task.taskId,
                "taskType": task.taskType.rawValue,
                "durationMs": "\(durationMs)"
            ], runId: task.runId)

            return ExpLaunchResult(
                success: false,
                launchDurationMs: durationMs,
                method: .cli,
                notes: ["error=\(error.localizedDescription)"]
            )
        }
    }

    /// Launches Ghostty attached to a tmux session instead of a bare shell.
    ///
    /// Uses `open -na <app> --args` to create a new Ghostty instance with:
    /// `--window-save-state=never --working-directory=<dir> --command=/bin/zsh --initial-command=<tmux command>`.
    ///
    /// The `--args` flag ensures arguments are passed as CLI flags (not file paths),
    /// avoiding macOS open-file handler prompts. The `-n` flag forces a new instance,
    /// which is critical when Ghostty is already running — without it, the existing
    /// instance is activated and CLI arguments are silently dropped.
    ///
    /// - Parameters:
    ///   - sessionName: The tmux session name to attach to
    ///   - workingDirectory: The working directory for the session
    ///   - task: Trace logging context
    /// - Returns: Launch result
    public func launchWithTmuxSession(
        sessionName: String,
        workingDirectory: String?,
        task: RestorationTaskContext,
        tmuxManagedIndex: Int? = nil
    ) async throws -> ExpLaunchResult {
        let startTime = Date()

        DeskJigLog.debug(.restorationTrace, "Launching \(appName)", fields: [
            "taskId": task.taskId,
            "taskType": task.taskType.rawValue,
            "app": appName,
            "method": "tmux",
            "directory": workingDirectory ?? "none"
        ], runId: task.runId)

        let ghosttyAppPath = NSWorkspace.shared.urlForApplication(
            withBundleIdentifier: bundleId
        )?.path ?? "/Applications/Ghostty.app"

        let dir = workingDirectory ?? "~"
        let expandedDir = (dir as NSString).expandingTildeInPath

        let tmuxSocketPath = TmuxCommandService.deskJigSocketPath
        let tmuxCommandService = TmuxCommandService()
        guard let resolvedTmuxBinary = await tmuxCommandService.binaryPath else {
            let durationMs = Int(Date().timeIntervalSince(startTime) * 1000)
            DeskJigLog.debug(.restorationTrace, "Ghostty tmux launch failed: tmux binary unavailable", fields: [
                "taskId": task.taskId,
                "taskType": task.taskType.rawValue,
                "durationMs": "\(durationMs)",
                "sessionName": sessionName,
                "tmuxSocket": tmuxSocketPath
            ], runId: task.runId)
            return ExpLaunchResult(
                success: false,
                launchDurationMs: durationMs,
                method: .cli,
                notes: ["tmux binary unavailable", "method=tmux"]
            )
        }

        let tmuxArguments = [
            resolvedTmuxBinary,
            "-S", tmuxSocketPath,
            "new-session", "-A",
            "-s", sessionName,
            "-c", expandedDir
        ]
        let initialCommand = LauncherUtils.shellJoin(tmuxArguments)
        let sanitizedInitialCommand = LauncherUtils.sanitizeCommandForTrace(initialCommand)

        // Build Ghostty CLI arguments, then wrap with `open -na ... --args`
        // to force a new instance that properly receives all flags.
        let resolvedTitle: String
        if let idx = tmuxManagedIndex {
            resolvedTitle = BundleRegistry.managedTmuxWindowTitle(bundleId: BundleRegistry.ghostty, index: idx)
        } else {
            resolvedTitle = Self.managedTmuxWindowTitle
        }
        let ghosttyArgs = [
            "--window-save-state=never",
            "--title=\(resolvedTitle)",
            "--shell-integration-features=no-title",
            "--working-directory=\(expandedDir)",
            "--command=/bin/zsh",
            "--initial-command=\(initialCommand)"
        ]
        let args = ["-na", ghosttyAppPath, "--args"] + ghosttyArgs

        do {
            // Off-actor launch (launch-01 / fluent-03): run /usr/bin/open on a background
            // queue so the cooperative pool / executor isn't blocked on waitUntilExit while
            // sibling launches proceed. durationMs/exitCode semantics are preserved.
            let launchResult = try await LauncherUtils.runProcessAsync(
                executable: URL(fileURLWithPath: "/usr/bin/open"),
                arguments: args,
                environment: LauncherUtils.cleanLaunchEnvironment(stripTmux: true)
            )

            let durationMs = Int(Date().timeIntervalSince(startTime) * 1000)
            let exitCode = launchResult.exitCode
            let verification = await TmuxLaunchVerifier.waitForClientAttachment(
                sessionName: sessionName,
                expectedTitle: resolvedTitle,
                commandService: tmuxCommandService
            )

            DeskJigLog.debug(.restorationTrace, "Ghostty tmux launch \((exitCode == 0 && verification.success) ? "completed" : "failed")", fields: [
                "taskId": task.taskId,
                "taskType": task.taskType.rawValue,
                "durationMs": "\(durationMs)",
                "exitCode": "\(exitCode)",
                "sessionName": sessionName,
                "title": resolvedTitle,
                "attachedClientCount": "\(verification.attachedClientCount)",
                "verificationSuccess": "\(verification.success)",
                "launchExecutable": "/usr/bin/open -na \(ghosttyAppPath)",
                "resolvedTmuxBinary": resolvedTmuxBinary,
                "tmuxBinary": resolvedTmuxBinary,
                "tmuxSocket": tmuxSocketPath,
                "bootstrapMode": "initial-command",
                "initialCommand": sanitizedInitialCommand,
                "method": "tmux"
            ], runId: task.runId)

            return ExpLaunchResult(
                success: exitCode == 0 && verification.success,
                launchDurationMs: durationMs,
                method: .cli,
                notes: [
                    "tmux session=\(sessionName)",
                    "directory=\(dir)",
                    "title=\(resolvedTitle)",
                    "bootstrap=initial-command",
                    "tmux binary=\(resolvedTmuxBinary)",
                    "tmux socket=\(tmuxSocketPath)",
                    "initial command=\(sanitizedInitialCommand)",
                    "clientDetected=\(verification.success)",
                    "attachedClientCount=\(verification.attachedClientCount)"
                ]
            )
        } catch {
            let durationMs = Int(Date().timeIntervalSince(startTime) * 1000)
            DeskJigLog.debug(.restorationTrace, "Ghostty tmux launch error: \(error.localizedDescription)", fields: [
                "taskId": task.taskId,
                "taskType": task.taskType.rawValue,
                "durationMs": "\(durationMs)",
                "sessionName": sessionName
            ], runId: task.runId)

            return ExpLaunchResult(
                success: false,
                launchDurationMs: durationMs,
                method: .cli,
                notes: ["error=\(error.localizedDescription)", "method=tmux"]
            )
        }
    }

    public func matchWindow(
        in snapshot: SystemSnapshot,
        directory: String?,
        title: String?,
        task: RestorationTaskContext,
        trustDeskJigTitle: Bool
    ) -> ExpWindowMatch? {
        let ghosttyWindows = snapshot.windows(forBundleID: bundleId)

        guard !ghosttyWindows.isEmpty else {
            DeskJigLog.debug(.restorationTrace, "No Ghostty windows found", fields: [
                "taskId": task.taskId,
                "taskType": task.taskType.rawValue
            ], runId: task.runId)
            return nil
        }

        // Strategy 1: Exact legacy title-token match with directory verification
        if let expectedTitle = title, expectedTitle.hasPrefix("\(BundleIdentity.terminalTitleTokenPrefix):") {
            let matchingTitleWindows = ghosttyWindows.filter { $0.title == expectedTitle }

            if !matchingTitleWindows.isEmpty {
                // If directory specified, verify working directory matches
                // Prefer freshWorkingDirectory (from supplementation) over documentPath
                if let dir = directory {
                    let normalizedDir = Self.normalizePath(dir)
                    if let window = matchingTitleWindows.first(where: {
                        // Use supplemented freshWorkingDirectory if available, fall back to documentPath
                        guard let workingDir = $0.freshWorkingDirectory ?? $0.documentPath else { return false }
                        return Self.normalizePath(workingDir) == normalizedDir
                    }) {
                        // Perfect match: title + directory
                        let matchedPath = window.freshWorkingDirectory ?? window.documentPath ?? dir
                        let source = window.freshWorkingDirectory != nil ? "freshWorkingDirectory" : "documentPath"
                        DeskJigLog.debug(.restorationTrace, "Matched \(appName) window", fields: [
                            "taskId": task.taskId,
                            "taskType": task.taskType.rawValue,
                            "app": appName,
                            "windowId": Int(window.windowId),
                            "confidence": "exact",
                            "method": "deskJigTitle+\(source)",
                            "title": expectedTitle,
                            "path": matchedPath
                        ], runId: task.runId)
                        return ExpWindowMatch(window: window, confidence: .exact, method: .bentoTitle, matchedValue: expectedTitle)
                    }
                    // Title match but wrong directory
                    let window = matchingTitleWindows.first!
                    let actualDir = window.freshWorkingDirectory ?? window.documentPath ?? "unknown"

                    if trustDeskJigTitle {
                        // Trust the legacy title token for freshly launched windows and log the mismatch.
                        DeskJigLog.debug(.restorationTrace, "WARNING: Trusting legacy title token despite directory mismatch", fields: [
                            "taskId": task.taskId,
                            "taskType": task.taskType.rawValue,
                            "windowId": window.windowId,
                            "pid": window.pid,
                            "title": expectedTitle,
                            "expectedDir": dir,
                            "actualDir": actualDir,
                            "freshWorkingDirectory": window.freshWorkingDirectory ?? "nil",
                            "documentPath": window.documentPath ?? "nil",
                            "reason": "trustDeskJigTitle=true (freshly launched window)"
                        ], runId: task.runId)
                        return ExpWindowMatch(window: window, confidence: .high, method: .bentoTitle, matchedValue: expectedTitle)
                    }

                    // Don't trust - force new window launch
                    DeskJigLog.debug(.restorationTrace, "Legacy title token found but directory mismatch", fields: [
                        "taskId": task.taskId,
                        "taskType": task.taskType.rawValue,
                        "windowId": window.windowId,
                        "pid": window.pid,
                        "expectedDir": dir,
                        "actualDir": actualDir
                    ], runId: task.runId)
                    return nil
                }

                // No directory to verify, use title match
                if let window = matchingTitleWindows.first {
                    DeskJigLog.debug(.restorationTrace, "Matched \(appName) window", fields: [
                        "taskId": task.taskId,
                        "taskType": task.taskType.rawValue,
                        "app": appName,
                        "windowId": Int(window.windowId),
                        "confidence": "exact",
                        "method": "deskJigTitle",
                        "title": expectedTitle
                    ], runId: task.runId)
                    return ExpWindowMatch(window: window, confidence: .exact, method: .bentoTitle, matchedValue: expectedTitle)
                }
            }

            // If a legacy title token is expected but not found, don't fall back to loose matching.
            DeskJigLog.debug(.restorationTrace, "No Ghostty window with legacy title token '\(expectedTitle)' found", fields: [
                "taskId": task.taskId,
                "taskType": task.taskType.rawValue
            ], runId: task.runId)
            return nil
        }

        // Strategy 2: Match by working directory (prefer supplemented data)
        if let dir = directory {
            let normalizedDir = Self.normalizePath(dir)
            if let window = ghosttyWindows.first(where: {
                // Use supplemented freshWorkingDirectory if available, fall back to documentPath
                guard let workingDir = $0.freshWorkingDirectory ?? $0.documentPath else { return false }
                return Self.normalizePath(workingDir) == normalizedDir
            }) {
                let matchedPath = window.freshWorkingDirectory ?? window.documentPath ?? dir
                let source = window.freshWorkingDirectory != nil ? "freshWorkingDirectory" : "documentPath"
                DeskJigLog.debug(.restorationTrace, "Matched \(appName) window", fields: [
                    "taskId": task.taskId,
                    "taskType": task.taskType.rawValue,
                    "app": appName,
                    "windowId": Int(window.windowId),
                    "confidence": "exact",
                    "method": source,
                    "path": matchedPath
                ], runId: task.runId)
                return ExpWindowMatch(window: window, confidence: .exact, method: .documentPath, matchedValue: matchedPath)
            }

            // Strategy 3: Title pattern match (Ghostty often includes path in title)
            let dirBasename = (dir as NSString).lastPathComponent
            if let window = ghosttyWindows.first(where: {
                $0.title?.contains(dirBasename) == true
            }) {
                DeskJigLog.debug(.restorationTrace, "Matched \(appName) window", fields: [
                    "taskId": task.taskId,
                    "taskType": task.taskType.rawValue,
                    "app": appName,
                    "windowId": Int(window.windowId),
                    "confidence": "high",
                    "method": "titlePattern",
                    "pattern": dirBasename
                ], runId: task.runId)
                return ExpWindowMatch(window: window, confidence: .high, method: .titlePattern, matchedValue: window.title)
            }
        }

        // No match found - don't fall back to any window
        // This prevents incorrectly reusing windows when restoring multiple terminals
        return nil
    }

    /// Normalize a path for comparison (expand tilde, resolve symlinks)
    private static func normalizePath(_ path: String) -> String {
        PathNormalization.standardize(path)
    }
}
