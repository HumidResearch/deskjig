//  FluentIDELauncher.swift
//  DeskJigShared

import Foundation
import AppKit

// MARK: - IDE Launch Mode

/// Launch modes for IDE applications (VS Code, Cursor)
public enum IDELaunchMode: String, CaseIterable, Sendable {
    /// Open in a new window (default) - uses --new-window
    case newWindow = "New Window"
    /// Reuse the last active window - uses --reuse-window
    case reuseWindow = "Reuse Window"
    /// Open a .code-workspace file
    case workspaceFile = "Workspace File"
    /// Open file at specific line/column - uses --goto file:line:column
    case gotoLine = "Go to Line"
    /// Open diff editor - uses --diff file1 file2
    case diffFiles = "Diff Files"
}

// MARK: - IDE Launcher

public struct FluentIDELauncher: FluentAppLauncher {
    public let bundleId: String
    public let appName: String
    private let cliName: String
    private let cliSearchPaths: [String]

    public init(bundleId: String, appName: String, cliName: String, cliSearchPaths: [String]) {
        self.bundleId = bundleId
        self.appName = appName
        self.cliName = cliName
        self.cliSearchPaths = cliSearchPaths
    }

    /// Create a launcher for Cursor
    public static func cursor() -> FluentIDELauncher {
        FluentIDELauncher(
            bundleId: "com.todesktop.230313mzl4w4u92",
            appName: "Cursor",
            cliName: "cursor",
            cliSearchPaths: [
                "/usr/local/bin/cursor",
                "/opt/homebrew/bin/cursor",
                "~/.cursor/bin/cursor"
            ]
        )
    }

    /// Create a launcher for VS Code
    public static func vscode() -> FluentIDELauncher {
        FluentIDELauncher(
            bundleId: "com.microsoft.VSCode",
            appName: "VS Code",
            cliName: "code",
            cliSearchPaths: [
                "/usr/local/bin/code",
                "/opt/homebrew/bin/code",
                "/Applications/Visual Studio Code.app/Contents/Resources/app/bin/code"
            ]
        )
    }

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

        // Note: IDEs don't support setting custom window titles via CLI
        // The title parameter is accepted for protocol conformance but not used
        _ = title

        // Try to find CLI
        if let cliPath = findCLI() {
            return try await launchViaCLI(cliPath, directory: directory, task: task, startTime: startTime)
        }

        // Fallback to open command
        return try await launchViaOpen(directory: directory, task: task, startTime: startTime)
    }

    // MARK: - Extended Launch with Mode

    /// Launch IDE with specific mode and options
    ///
    /// - Parameters:
    ///   - directory: Working directory to open
    ///   - mode: Launch mode (newWindow, reuseWindow, etc.)
    ///   - fileWithLine: File path with optional line:column (e.g., "src/main.ts:42:5") for gotoLine mode
    ///   - diffFiles: Two file paths for diff mode
    ///   - task: Task context for logging
    /// - Returns: Launch result
    public func launchWithMode(
        directory: String?,
        mode: IDELaunchMode,
        fileWithLine: String? = nil,
        diffFiles: (String, String)? = nil,
        task: RestorationTaskContext
    ) async throws -> ExpLaunchResult {
        let startTime = Date()

        DeskJigLog.debug(.restorationTrace, "Launching \(appName)", fields: [
            "taskId": task.taskId,
            "taskType": task.taskType.rawValue,
            "app": appName,
            "method": "cli-\(mode.rawValue)",
            "directory": directory ?? "none"
        ], runId: task.runId)

        // Try to find CLI
        guard let cliPath = findCLI() else {
            // Fallback to open command for newWindow mode only
            if mode == .newWindow {
                return try await launchViaOpen(directory: directory, task: task, startTime: startTime)
            }
            return ExpLaunchResult(
                success: false,
                launchDurationMs: Int(Date().timeIntervalSince(startTime) * 1000),
                method: .cli,
                notes: ["CLI not found - \(mode.rawValue) requires CLI"]
            )
        }

        // Build arguments based on mode
        var args: [String] = []

        switch mode {
        case .newWindow:
            args.append("--new-window")
            if let dir = directory {
                args.append(dir)
            }

        case .reuseWindow:
            args.append("--reuse-window")
            if let dir = directory {
                args.append(dir)
            }

        case .workspaceFile:
            // Create a workspace file if directory is provided
            if let dir = directory {
                let workspaceURL = try createWorkspaceFile(forDirectory: dir)
                args.append(workspaceURL.path)
            }

        case .gotoLine:
            args.append("--goto")
            if let fileSpec = fileWithLine {
                args.append(fileSpec)
            }

        case .diffFiles:
            args.append("--diff")
            if let (file1, file2) = diffFiles {
                args.append(file1)
                args.append(file2)
            }
        }

        do {
            let (exitCode, duration, timedOut) = try await LauncherUtils.runProcessAsyncBestEffort(
                executable: cliPath,
                arguments: args,
                timeoutSeconds: 2.0
            )

            let durationMs = Int(duration * 1000)

            DeskJigLog.debug(.restorationTrace, "\(appName) CLI launch (\(mode.rawValue)) \(exitCode == 0 ? "completed" : "failed")", fields: [
                "taskId": task.taskId,
                "taskType": task.taskType.rawValue,
                "durationMs": "\(durationMs)",
                "exitCode": "\(exitCode)",
                "mode": mode.rawValue,
                "timedOut": "\(timedOut)"
            ], runId: task.runId)

            return ExpLaunchResult(
                success: exitCode == 0,
                launchDurationMs: durationMs,
                method: .cli,
                notes: ["mode=\(mode.rawValue)", "cli=\(cliPath.path)", timedOut ? "timeout=2s" : "exit=0"]
            )
        } catch {
            let durationMs = Int(Date().timeIntervalSince(startTime) * 1000)
            DeskJigLog.debug(.restorationTrace, "\(appName) CLI launch error: \(error.localizedDescription)", fields: [
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

    /// Create a temporary .code-workspace file for a directory
    private func createWorkspaceFile(forDirectory directory: String) throws -> URL {
        let expandedDir = (directory as NSString).expandingTildeInPath
        let dirURL = URL(fileURLWithPath: expandedDir).standardizedFileURL
        let fileName = "deskjig-\(dirURL.lastPathComponent)-\(UUID().uuidString).code-workspace"
        let workspaceURL = FileManager.default.temporaryDirectory.appendingPathComponent(fileName)

        let payload: [String: Any] = [
            "folders": [
                ["path": dirURL.path]
            ],
            "settings": [:]
        ]

        let data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: workspaceURL, options: [.atomic])
        return workspaceURL
    }

    /// Check if CLI is available for this launcher
    public func isCLIInstalled() -> CLILocator.CLIStatus {
        CLILocator.cliStatus(for: bundleId)
    }

    private func findCLI() -> URL? {
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
        var args = ["--new-window"]
        if let dir = directory {
            args.append(dir)
        }

        do {
            let (exitCode, duration, timedOut) = try await LauncherUtils.runProcessAsyncBestEffort(
                executable: cliPath,
                arguments: args,
                timeoutSeconds: 2.0
            )

            let durationMs = Int(duration * 1000)

            DeskJigLog.debug(.restorationTrace, "\(appName) CLI launch \(exitCode == 0 ? "completed" : "failed")", fields: [
                "taskId": task.taskId,
                "taskType": task.taskType.rawValue,
                "durationMs": "\(durationMs)",
                "exitCode": "\(exitCode)",
                "method": "cli",
                "timedOut": "\(timedOut)"
            ], runId: task.runId)

            return ExpLaunchResult(
                success: exitCode == 0,
                launchDurationMs: durationMs,
                method: .cli,
                notes: directory != nil
                    ? ["directory=\(directory!)", "cli=\(cliPath.path)", timedOut ? "timeout=2s" : "exit=0"]
                    : ["cli=\(cliPath.path)", timedOut ? "timeout=2s" : "exit=0"]
            )
        } catch {
            let durationMs = Int(Date().timeIntervalSince(startTime) * 1000)
            DeskJigLog.debug(.restorationTrace, "\(appName) CLI launch error: \(error.localizedDescription)", fields: [
                "taskId": task.taskId,
                "taskType": task.taskType.rawValue,
                "durationMs": "\(durationMs)"
            ], runId: task.runId)

            // Try fallback to open command
            return try await launchViaOpen(directory: directory, task: task, startTime: startTime)
        }
    }

    private func launchViaOpen(
        directory: String?,
        task: RestorationTaskContext,
        startTime: Date
    ) async throws -> ExpLaunchResult {
        var args = ["-na", appName]
        if let dir = directory {
            args.append(dir)
        }

        do {
            let (exitCode, _, timedOut) = try await LauncherUtils.runProcessAsyncBestEffort(
                executable: URL(fileURLWithPath: "/usr/bin/open"),
                arguments: args,
                timeoutSeconds: 2.0
            )

            let durationMs = Int(Date().timeIntervalSince(startTime) * 1000)

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
                notes: directory != nil
                    ? ["directory=\(directory!)", timedOut ? "timeout=2s" : "exit=0"]
                    : [timedOut ? "timeout=2s" : "exit=0"]
            )
        } catch {
            let durationMs = Int(Date().timeIntervalSince(startTime) * 1000)
            return ExpLaunchResult(
                success: false,
                launchDurationMs: durationMs,
                method: .open,
                notes: ["error=\(error.localizedDescription)"]
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

        // IDEs don't use the legacy `bento:` title token; they show the project/file name.
        _ = title

        // Strategy 1: Match by documentPath (highest confidence)
        if let dir = directory {
            attemptedStrategies.append("documentPath")
            let normalizedExpected = Self.normalizePath(dir)

            // Debug: Log what documentPaths we have to diagnose matching issues
            // Check ideDocumentPath first (from IDE supplementation), then fallback to documentPath (from AX)
            let docPaths = ideWindows.map { w in
                "\(w.windowId):\(w.ideDocumentPath ?? w.documentPath ?? "nil")"
            }
            DeskJigLog.debug(.restorationTrace, "IDE documentPath check", fields: [
                "taskId": task.taskId,
                "taskType": task.taskType.rawValue,
                "expectedDir": dir,
                "normalizedExpected": normalizedExpected,
                "windowDocPaths": docPaths.joined(separator: "|"),
                "windowCount": "\(ideWindows.count)"
            ], runId: task.runId)

            // Check ideDocumentPath first (from IDE supplementation), then documentPath (from AX)
            if let window = ideWindows.first(where: {
                let docPath = $0.ideDocumentPath ?? $0.documentPath
                guard let path = docPath, !path.isEmpty else { return false }
                return Self.normalizePath(path) == normalizedExpected
            }) {
                DeskJigLog.debug(.restorationTrace, "Matched \(appName) window", fields: [
                    "taskId": task.taskId,
                    "taskType": task.taskType.rawValue,
                    "app": appName,
                    "windowId": Int(window.windowId),
                    "confidence": "exact",
                    "method": "documentPath",
                    "path": dir,
                    "strategiesAttempted": attemptedStrategies.joined(separator: ",")
                ], runId: task.runId)
                return ExpWindowMatch(window: window, confidence: .exact, method: .documentPath, matchedValue: dir)
            }

            // Strategy 2: Match by project name in title (em-dash/dash separator)
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
                DeskJigLog.debug(.restorationTrace, "Matched \(appName) window", fields: [
                    "taskId": task.taskId,
                    "taskType": task.taskType.rawValue,
                    "app": appName,
                    "windowId": Int(window.windowId),
                    "confidence": "high",
                    "method": "titlePattern",
                    "pattern": dirBasename,
                    "strategiesAttempted": attemptedStrategies.joined(separator: ",")
                ], runId: task.runId)
                return ExpWindowMatch(window: window, confidence: .high, method: .titlePattern, matchedValue: window.title)
            }

            // Strategy 3: Title contains directory basename (looser match with word boundary)
            attemptedStrategies.append("titlePatternLoose")
            if let window = ideWindows.first(where: {
                guard isDocPathCompatible($0) else { return false }
                guard let title = $0.title else { return false }
                return Self.titleContainsFolder(title, folderName: dirBasename)
            }) {
                DeskJigLog.debug(.restorationTrace, "Matched \(appName) window", fields: [
                    "taskId": task.taskId,
                    "taskType": task.taskType.rawValue,
                    "app": appName,
                    "windowId": Int(window.windowId),
                    "confidence": "medium",
                    "method": "titlePattern",
                    "pattern": dirBasename,
                    "strategiesAttempted": attemptedStrategies.joined(separator: ",")
                ], runId: task.runId)
                return ExpWindowMatch(window: window, confidence: .medium, method: .titlePattern, matchedValue: window.title)
            }
        }

        // No match found - log strategies attempted and return nil (triggers new window launch)
        DeskJigLog.debug(.restorationTrace, "No matching \(appName) window found - will launch new", fields: [
            "taskId": task.taskId,
            "taskType": task.taskType.rawValue,
            "strategiesAttempted": attemptedStrategies.joined(separator: ","),
            "windowsChecked": "\(ideWindows.count)",
            "expectedPath": directory ?? "none"
        ], runId: task.runId)
        return nil
    }

    // MARK: - Path Normalization

    /// Normalize a path for comparison by expanding tildes, resolving file:// URLs,
    /// URL-decoding, and standardizing the path format.
    private static func normalizePath(_ path: String) -> String {
        guard !path.isEmpty else { return "" }
        var p = path

        // Handle file:// URLs
        if p.hasPrefix("file://") {
            p = String(p.dropFirst(7))
        }

        // URL decode (handles %20, etc.)
        p = p.removingPercentEncoding ?? p

        // Expand tilde
        p = (p as NSString).expandingTildeInPath

        // Standardize path (resolves .., removes trailing slash, etc.)
        return URL(fileURLWithPath: p).standardizedFileURL.path
    }

    /// Checks if a window title contains the folder name using word boundary matching.
    /// This prevents false positives like "deskjig" matching "deskjig-web".
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
