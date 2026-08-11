//  FluentAlacrittyLauncher.swift
//  DeskJigShared

import Foundation
import AppKit

public struct FluentAlacrittyLauncher: FluentAppLauncher {
    public let bundleId = "org.alacritty"
    public let appName = "Alacritty"

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

        // Get the full Alacritty app path
        let alacrittyAppPath = NSWorkspace.shared.urlForApplication(
            withBundleIdentifier: bundleId
        )?.path ?? "/Applications/Alacritty.app"

        // Build arguments: open -na <app> --args --working-directory <path> --title <title>
        var args = ["-na", alacrittyAppPath, "--args"]
        if let dir = directory {
            args.append("--working-directory")
            args.append(dir)
        }
        // Add title for window identification during restoration
        if let title = title {
            args.append("--title")
            args.append(title)
        }

        // Use Process directly with cleaned environment
        do {
            // Off-actor launch (launch-01 / fluent-03): run /usr/bin/open on a background
            // queue so the cooperative pool / executor isn't blocked on waitUntilExit while
            // sibling launches proceed. durationMs/exitCode semantics are preserved.
            let launchResult = try await LauncherUtils.runProcessAsync(
                executable: URL(fileURLWithPath: "/usr/bin/open"),
                arguments: args,
                environment: LauncherUtils.cleanLaunchEnvironment()
            )

            let durationMs = Int(Date().timeIntervalSince(startTime) * 1000)
            let exitCode = launchResult.exitCode

            DeskJigLog.debug(.restorationTrace, "Alacritty launch \(exitCode == 0 ? "completed" : "failed")", fields: [
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
            DeskJigLog.debug(.restorationTrace, "Alacritty launch error: \(error.localizedDescription)", fields: [
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

    /// Launches Alacritty attached to a tmux session on the DeskJig socket.
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

        let alacrittyAppPath = NSWorkspace.shared.urlForApplication(
            withBundleIdentifier: bundleId
        )?.path ?? "/Applications/Alacritty.app"
        let dir = workingDirectory ?? "~"
        let expandedDir = (dir as NSString).expandingTildeInPath

        let tmuxSocketPath = TmuxCommandService.deskJigSocketPath
        let tmuxCommandService = TmuxCommandService()
        guard let resolvedTmuxBinary = await tmuxCommandService.binaryPath else {
            let durationMs = Int(Date().timeIntervalSince(startTime) * 1000)
            return ExpLaunchResult(
                success: false,
                launchDurationMs: durationMs,
                method: .cli,
                notes: ["tmux binary unavailable", "method=tmux"]
            )
        }

        let managedTitle: String
        if let idx = tmuxManagedIndex {
            managedTitle = BundleRegistry.managedTmuxWindowTitle(bundleId: BundleRegistry.alacritty, index: idx)
        } else {
            managedTitle = BundleRegistry.managedTmuxWindowTitle
        }

        // open -na Alacritty --args --title <title> -e tmux -S <socket> new-session -A -s <name> -c <dir>
        var args = ["-na", alacrittyAppPath, "--args"]
        args.append("--title")
        args.append(managedTitle)
        args.append("-e")
        args.append(resolvedTmuxBinary)
        args.append("-S")
        args.append(tmuxSocketPath)
        args.append("new-session")
        args.append("-A")
        args.append("-s")
        args.append(sessionName)
        args.append("-c")
        args.append(expandedDir)

        do {
            // Off-actor launch (launch-01 / fluent-03): run /usr/bin/open on a background
            // queue so the cooperative pool / executor isn't blocked on waitUntilExit while
            // sibling launches proceed. durationMs/exitCode semantics are preserved.
            let launchResult = try await LauncherUtils.runProcessAsync(
                executable: URL(fileURLWithPath: "/usr/bin/open"),
                arguments: args,
                environment: LauncherUtils.cleanLaunchEnvironment()
            )

            let durationMs = Int(Date().timeIntervalSince(startTime) * 1000)
            let exitCode = launchResult.exitCode
            let verification = await TmuxLaunchVerifier.waitForClientAttachment(
                sessionName: sessionName,
                expectedTitle: managedTitle,
                commandService: tmuxCommandService
            )

            DeskJigLog.debug(.restorationTrace, "Alacritty tmux launch \((exitCode == 0 && verification.success) ? "completed" : "failed")", fields: [
                "taskId": task.taskId,
                "taskType": task.taskType.rawValue,
                "durationMs": "\(durationMs)",
                "exitCode": "\(exitCode)",
                "sessionName": sessionName,
                "title": managedTitle,
                "attachedClientCount": "\(verification.attachedClientCount)",
                "verificationSuccess": "\(verification.success)",
                "method": "tmux"
            ], runId: task.runId)

            return ExpLaunchResult(
                success: exitCode == 0 && verification.success,
                launchDurationMs: durationMs,
                method: .cli,
                notes: [
                    "tmux session=\(sessionName)",
                    "title=\(managedTitle)",
                    "clientDetected=\(verification.success)",
                    "attachedClientCount=\(verification.attachedClientCount)"
                ]
            )
        } catch {
            let durationMs = Int(Date().timeIntervalSince(startTime) * 1000)
            return ExpLaunchResult(
                success: false,
                launchDurationMs: durationMs,
                method: .cli,
                notes: ["error=\(error.localizedDescription)", "method=tmux"]
            )
        }
    }

    /// Clean environment to strip Xcode/debugger variables that interfere with CLI args
    public func matchWindow(
        in snapshot: SystemSnapshot,
        directory: String?,
        title: String?,
        task: RestorationTaskContext,
        trustDeskJigTitle: Bool
    ) -> ExpWindowMatch? {
        let alacrittyWindows = snapshot.windows(forBundleID: bundleId)

        guard !alacrittyWindows.isEmpty else {
            DeskJigLog.debug(.restorationTrace, "No Alacritty windows found", fields: [
                "taskId": task.taskId,
                "taskType": task.taskType.rawValue
            ], runId: task.runId)
            return nil
        }

        // Strategy 1: Exact legacy title-token match with directory verification
        if let expectedTitle = title, expectedTitle.hasPrefix("\(BundleIdentity.terminalTitleTokenPrefix):") {
            let matchingTitleWindows = alacrittyWindows.filter { $0.title == expectedTitle }

            if !matchingTitleWindows.isEmpty {
                // If directory specified, verify working directory matches
                if let dir = directory {
                    let normalizedDir = Self.normalizePath(dir)
                    if let window = matchingTitleWindows.first(where: {
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
                        // Trust the legacy title token for freshly launched windows.
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
            DeskJigLog.debug(.restorationTrace, "No Alacritty window with legacy title token '\(expectedTitle)' found", fields: [
                "taskId": task.taskId,
                "taskType": task.taskType.rawValue
            ], runId: task.runId)
            return nil
        }

        // Strategy 2: Match by working directory (prefer supplemented data)
        if let dir = directory {
            let normalizedDir = Self.normalizePath(dir)
            if let window = alacrittyWindows.first(where: {
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

            // Strategy 3: Title pattern match (Alacritty often includes path in title)
            let dirBasename = (dir as NSString).lastPathComponent
            if let window = alacrittyWindows.first(where: {
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

        // Strategy 4: Return any Alacritty window (lowest confidence)
        if let window = alacrittyWindows.first {
            DeskJigLog.debug(.restorationTrace, "Matched \(appName) window", fields: [
                "taskId": task.taskId,
                "taskType": task.taskType.rawValue,
                "app": appName,
                "windowId": Int(window.windowId),
                "confidence": "low",
                "method": "bundleIdOnly"
            ], runId: task.runId)
            return ExpWindowMatch(window: window, confidence: .low, method: .bundleIdOnly, matchedValue: window.title)
        }

        return nil
    }

    /// Normalize a path for comparison (expand tilde, resolve symlinks)
    private static func normalizePath(_ path: String) -> String {
        PathNormalization.standardize(path)
    }
}
