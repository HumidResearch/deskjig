//  FluentCodexLauncher.swift
//  DeskJigShared

import Foundation
import AppKit

public struct FluentCodexLauncher: FluentAppLauncher {
    public let bundleId: String = OpenByPathBundleIdentifiers.codex
    public let appName: String = "Codex"
    public let isSingleInstance: Bool = true

    private let cliSearchPaths: [String] = [
        "/opt/homebrew/bin/codex",
        "/usr/local/bin/codex",
        "/usr/bin/codex"
    ]

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
            "method": "codex-cli",
            "directory": directory ?? "none"
        ], runId: task.runId)

        // IDEs don't support setting custom window titles via launcher arguments.
        _ = title

        if let cliPath = findCLI() {
            return try await launchViaCLI(cliPath, directory: directory, task: task, startTime: startTime)
        }

        return try await launchViaOpen(directory: directory, task: task, startTime: startTime)
    }

    private func findCLI() -> URL? {
        let env = ProcessInfo.processInfo.environment
        if let pathValue = env["PATH"], !pathValue.isEmpty {
            let pathDirectories = pathValue.split(separator: ":").map(String.init) + ["/opt/homebrew/bin", "/usr/local/bin"]
            for directory in pathDirectories {
                let candidate = URL(fileURLWithPath: directory).appendingPathComponent("codex")
                if FileManager.default.isExecutableFile(atPath: candidate.path) {
                    return candidate
                }
            }
        }

        for path in cliSearchPaths {
            let expandedPath = NSString(string: path).expandingTildeInPath
            let url = URL(fileURLWithPath: expandedPath)
            if FileManager.default.isExecutableFile(atPath: expandedPath) {
                return url
            }
        }

        return nil
    }

    private func launchViaCLI(
        _ cliPath: URL,
        directory: String?,
        task: RestorationTaskContext,
        startTime: Date
    ) async throws -> ExpLaunchResult {
        var args = ["app"]
        if let directory {
            args.append(directory)
        }

        do {
            let (exitCode, duration, stderr, stdout) = try await LauncherUtils.runProcessAsyncCapturingAll(
                executable: cliPath,
                arguments: args
            )

            let durationMs = Int(duration * 1000)
            let trimmedStdout = stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            let trimmedStderr = stderr.trimmingCharacters(in: .whitespacesAndNewlines)

            DeskJigLog.debug(.restorationTrace, "\(appName) codex-cli launch \(exitCode == 0 ? "completed" : "failed")", fields: [
                "taskId": task.taskId,
                "taskType": task.taskType.rawValue,
                "durationMs": "\(durationMs)",
                "exitCode": "\(exitCode)",
                "method": "codex-cli",
                "stdout": trimmedStdout.isEmpty ? "none" : trimmedStdout,
                "stderr": trimmedStderr.isEmpty ? "none" : trimmedStderr
            ], runId: task.runId)

            return ExpLaunchResult(
                success: exitCode == 0,
                launchDurationMs: durationMs,
                method: .cli,
                notes: [
                    "launched-via=codex-cli",
                    "cli=\(cliPath.path)",
                    "exit=\(exitCode)",
                    trimmedStdout.isEmpty ? "stdout=none" : "stdout=\(trimmedStdout)",
                    trimmedStderr.isEmpty ? "stderr=none" : "stderr=\(trimmedStderr)"
                ]
            )
        } catch {
            let durationMs = Int(Date().timeIntervalSince(startTime) * 1000)
            DeskJigLog.debug(.restorationTrace, "\(appName) codex-cli launch error: \(error.localizedDescription)", fields: [
                "taskId": task.taskId,
                "taskType": task.taskType.rawValue,
                "durationMs": "\(durationMs)"
            ], runId: task.runId)

            return try await launchViaOpen(directory: directory, task: task, startTime: startTime)
        }
    }

    private func launchViaOpen(
        directory: String?,
        task: RestorationTaskContext,
        startTime: Date
    ) async throws -> ExpLaunchResult {
        var args = ["-na", appName]
        if let directory {
            args.append(directory)
        }

        do {
            let (exitCode, duration, timedOut) = try await LauncherUtils.runProcessAsyncBestEffort(
                executable: URL(fileURLWithPath: "/usr/bin/open"),
                arguments: args,
                timeoutSeconds: 2.0
            )

            let durationMs = Int(duration * 1000)

            DeskJigLog.debug(.restorationTrace, "\(appName) open launch \(exitCode == 0 ? "completed" : "failed")", fields: [
                "taskId": task.taskId,
                "taskType": task.taskType.rawValue,
                "durationMs": "\(durationMs)",
                "exitCode": "\(exitCode)",
                "method": "open",
                "timedOut": "\(timedOut)"
            ], runId: task.runId)

            return ExpLaunchResult(
                success: exitCode == 0,
                launchDurationMs: durationMs,
                method: .open,
                notes: [
                    "launched-via=open",
                    timedOut ? "timeout=2s" : "exit=\(exitCode)"
                ]
            )
        } catch {
            let durationMs = Int(Date().timeIntervalSince(startTime) * 1000)
            return ExpLaunchResult(
                success: false,
                launchDurationMs: durationMs,
                method: .open,
                notes: ["error=\(error.localizedDescription)", "launched-via=open"]
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
        let ideWindows = snapshot.windows(forBundleID: bundleId)
        var attemptedStrategies: [String] = []

        guard !ideWindows.isEmpty else {
            DeskJigLog.debug(.restorationTrace, "No \(appName) windows found in snapshot", fields: [
                "taskId": task.taskId,
                "taskType": task.taskType.rawValue
            ], runId: task.runId)
            return nil
        }

        _ = title
        _ = trustDeskJigTitle

        if let dir = directory {
            attemptedStrategies.append("documentPath")
            let normalizedExpected = Self.normalizePath(dir)

            if let window = ideWindows.first(where: {
                let docPath = $0.ideDocumentPath ?? $0.documentPath
                guard let path = docPath, !path.isEmpty else { return false }
                return Self.normalizePath(path) == normalizedExpected
            }) {
                return ExpWindowMatch(window: window, confidence: .exact, method: .documentPath, matchedValue: dir)
            }

            let dirBasename = (dir as NSString).lastPathComponent.lowercased()
            attemptedStrategies.append("titlePatternExact")
            func isDocPathCompatible(_ window: SnapshotWindow) -> Bool {
                let docPath = window.ideDocumentPath ?? window.documentPath
                guard let rawPath = docPath, !rawPath.isEmpty else { return true }
                let normalizedPath = Self.normalizePath(rawPath)
                guard !normalizedPath.isEmpty else { return true }
                return normalizedPath == normalizedExpected || normalizedPath.hasPrefix("\(normalizedExpected)/")
            }

            if let window = ideWindows.first(where: { window in
                guard isDocPathCompatible(window) else { return false }
                guard let windowTitle = window.title?.lowercased() else { return false }
                return windowTitle.contains(" — \(dirBasename)") ||
                    windowTitle.contains(" - \(dirBasename)") ||
                    windowTitle.hasSuffix(dirBasename)
            }) {
                return ExpWindowMatch(window: window, confidence: .high, method: .titlePattern, matchedValue: window.title)
            }

            attemptedStrategies.append("titlePatternLoose")
            if let window = ideWindows.first(where: {
                guard isDocPathCompatible($0) else { return false }
                guard let windowTitle = $0.title else { return false }
                return Self.titleContainsFolder(windowTitle, folderName: dirBasename)
            }) {
                return ExpWindowMatch(window: window, confidence: .medium, method: .titlePattern, matchedValue: window.title)
            }
        }

        // Codex is single-instance (single-project, possibly multiple windows).
        // The launch() method calls `codex app <path>` which switches to the correct project.
        attemptedStrategies.append("singleInstance")
        if !ideWindows.isEmpty {
            let window = ideWindows
                .sorted { ($0.zOrderIndex ?? Int.max) < ($1.zOrderIndex ?? Int.max) }
                .first!
            DeskJigLog.debug(.restorationTrace, "\(appName) single-instance fallback matched", fields: [
                "taskId": task.taskId,
                "taskType": task.taskType.rawValue,
                "windowTitle": window.title ?? "nil"
            ], runId: task.runId)
            return ExpWindowMatch(window: window, confidence: .medium, method: .titlePattern, matchedValue: window.title)
        }

        DeskJigLog.debug(.restorationTrace, "No matching \(appName) window found - will launch new", fields: [
            "taskId": task.taskId,
            "taskType": task.taskType.rawValue,
            "strategiesAttempted": attemptedStrategies.joined(separator: ","),
            "windowsChecked": "\(ideWindows.count)",
            "expectedPath": directory ?? "none"
        ], runId: task.runId)
        return nil
    }

    private static func normalizePath(_ path: String) -> String {
        guard !path.isEmpty else { return "" }
        var p = path
        if p.hasPrefix("file://") {
            p = String(p.dropFirst(7))
        }
        p = p.removingPercentEncoding ?? p
        p = (p as NSString).expandingTildeInPath
        return URL(fileURLWithPath: p).standardizedFileURL.path
    }

    private static func titleContainsFolder(_ title: String, folderName: String) -> Bool {
        let escaped = NSRegularExpression.escapedPattern(for: folderName)
        let pattern = "(?:^|[^a-zA-Z0-9_-])\(escaped)(?:$|[^a-zA-Z0-9_-])"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else {
            return title.localizedCaseInsensitiveContains(folderName)
        }

        let range = NSRange(title.startIndex..., in: title)
        return regex.firstMatch(in: title, options: [], range: range) != nil
    }
}
