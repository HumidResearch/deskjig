//  FluentXcodeLauncher.swift
//  DeskJigShared

import Foundation
import AppKit

// MARK: - Xcode Launcher

public struct FluentXcodeLauncher: FluentAppLauncher {
    public let bundleId: String = "com.apple.dt.Xcode"
    public let appName: String = "Xcode"

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
            "method": "xed",
            "directory": directory ?? "none"
        ], runId: task.runId)

        // Note: Xcode doesn't support setting custom window titles via CLI
        // The title parameter is accepted for protocol conformance but not used
        _ = title

        // Try to use xed CLI first
        let xedStatus = CLILocator.xcodeCLI()
        if xedStatus.isInstalled, let xedPath = xedStatus.path {
            return try await launchViaXed(xedPath, directory: directory, task: task, startTime: startTime)
        }

        // Fallback to open command
        return try await launchViaOpen(directory: directory, task: task, startTime: startTime)
    }

    private func launchViaXed(
        _ xedPath: String,
        directory: String?,
        task: RestorationTaskContext,
        startTime: Date
    ) async throws -> ExpLaunchResult {
        let launchTarget = resolveLaunchTargetPath(from: directory)
        let launchPath = launchTarget.path

        DeskJigLog.debug(.restorationTrace, "Resolved Xcode launch target", fields: [
            "taskId": task.taskId,
            "taskType": task.taskType.rawValue,
            "requestedPath": directory ?? "nil",
            "launchPath": launchPath ?? "nil",
            "source": launchTarget.source
        ], runId: task.runId)

        var args: [String] = []
        if let launchPath {
            args.append(launchPath)
        }

        do {
            let (exitCode, duration) = try await LauncherUtils.runProcessAsync(
                executable: URL(fileURLWithPath: xedPath),
                arguments: args
            )

            let durationMs = Int(duration * 1000)

            DeskJigLog.debug(.restorationTrace, "\(appName) xed launch \(exitCode == 0 ? "completed" : "failed")", fields: [
                "taskId": task.taskId,
                "taskType": task.taskType.rawValue,
                "durationMs": "\(durationMs)",
                "exitCode": "\(exitCode)",
                "method": "xed"
            ], runId: task.runId)

            return ExpLaunchResult(
                success: exitCode == 0,
                launchDurationMs: durationMs,
                method: .cli,
                notes: launchPath != nil
                    ? [
                        "directory=\(directory ?? launchPath!)",
                        "launchTarget=\(launchPath!)",
                        "targetSource=\(launchTarget.source)",
                        "cli=\(xedPath)"
                    ]
                    : ["cli=\(xedPath)"]
            )
        } catch {
            let durationMs = Int(Date().timeIntervalSince(startTime) * 1000)
            DeskJigLog.debug(.restorationTrace, "\(appName) xed launch error: \(error.localizedDescription)", fields: [
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
        let launchTarget = resolveLaunchTargetPath(from: directory)
        let launchPath = launchTarget.path

        DeskJigLog.debug(.restorationTrace, "Resolved Xcode open target", fields: [
            "taskId": task.taskId,
            "taskType": task.taskType.rawValue,
            "requestedPath": directory ?? "nil",
            "launchPath": launchPath ?? "nil",
            "source": launchTarget.source
        ], runId: task.runId)

        var args = ["-na", "Xcode"]
        if let launchPath {
            args.append(launchPath)
        }

        do {
            let (exitCode, _) = try await LauncherUtils.runProcessAsync(
                executable: URL(fileURLWithPath: "/usr/bin/open"),
                arguments: args
            )

            let durationMs = Int(Date().timeIntervalSince(startTime) * 1000)

            DeskJigLog.debug(.restorationTrace, "\(appName) open launch \(exitCode == 0 ? "completed" : "failed")", fields: [
                "taskId": task.taskId,
                "taskType": task.taskType.rawValue,
                "durationMs": "\(durationMs)",
                "exitCode": "\(exitCode)",
                "method": "open"
            ], runId: task.runId)

            return ExpLaunchResult(
                success: exitCode == 0,
                launchDurationMs: durationMs,
                method: .open,
                notes: launchPath != nil
                    ? [
                        "directory=\(directory ?? launchPath!)",
                        "launchTarget=\(launchPath!)",
                        "targetSource=\(launchTarget.source)"
                    ]
                    : []
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

    /// Check if xed CLI is available for this launcher
    public func isCLIInstalled() -> CLILocator.CLIStatus {
        CLILocator.xcodeCLI()
    }

    public func matchWindow(
        in snapshot: SystemSnapshot,
        directory: String?,
        title: String?,
        task: RestorationTaskContext,
        trustDeskJigTitle: Bool
    ) -> ExpWindowMatch? {
        let xcodeWindows = snapshot.windows(forBundleID: bundleId)
        var attemptedStrategies: [String] = []

        guard !xcodeWindows.isEmpty else {
            DeskJigLog.debug(.restorationTrace, "No \(appName) windows found in snapshot", fields: [
                "taskId": task.taskId,
                "taskType": task.taskType.rawValue
            ], runId: task.runId)
            return nil
        }

        // Xcode doesn't use the legacy `bento:` title token; it shows the project name.
        _ = title

        // Strategy 1: Match by documentPath (highest confidence)
        // Xcode AX API returns paths like: file:///Users/user/code/Project.xcworkspace
        // We need to extract the directory from the .xcworkspace/.xcodeproj path
        if let dir = directory {
            attemptedStrategies.append("documentPath")
            let normalizedExpected = Self.normalizePath(dir)
            let dirBasename = (dir as NSString).lastPathComponent.lowercased()
            let pathStrictEnabled = true

            // Debug: Log what documentPaths we have to diagnose matching issues
            let docPaths = xcodeWindows.map { w in
                "\(w.windowId):\(w.ideDocumentPath ?? w.documentPath ?? "nil")"
            }
            DeskJigLog.debug(.restorationTrace, "Xcode documentPath check", fields: [
                "taskId": task.taskId,
                "taskType": task.taskType.rawValue,
                "expectedDir": dir,
                "normalizedExpected": normalizedExpected,
                "windowDocPaths": docPaths.joined(separator: "|"),
                "windowCount": "\(xcodeWindows.count)",
                "xcodePathStrict": "\(pathStrictEnabled)"
            ], runId: task.runId)

            // Check ideDocumentPath first (from IDE supplementation), then documentPath (from AX)
            let pathMatches = xcodeWindows.filter {
                let docPath = $0.ideDocumentPath ?? $0.documentPath
                guard let path = docPath, !path.isEmpty else { return false }
                return Self.pathMatchesExpectedDirectory(path, expectedDirectory: normalizedExpected)
            }

            if !pathMatches.isEmpty {
                // When multiple windows have the same normalized path (observed with stacked Xcode windows),
                // disambiguate using title token compatibility with the expected folder name.
                let scored = pathMatches.map { window in
                    let title = window.title?.lowercased() ?? ""
                    let score = Self.titleContainsFolder(title, folderName: dirBasename) ? 1 : 0
                    return (window: window, score: score)
                }
                let best = scored.max { lhs, rhs in
                    if lhs.score == rhs.score { return lhs.window.windowId < rhs.window.windowId }
                    return lhs.score < rhs.score
                }?.window ?? pathMatches[0]

                DeskJigLog.debug(.restorationTrace, "Matched \(appName) window", fields: [
                    "taskId": task.taskId,
                    "taskType": task.taskType.rawValue,
                    "app": appName,
                    "windowId": Int(best.windowId),
                    "confidence": "exact",
                    "method": "documentPath",
                    "path": dir,
                    "strategiesAttempted": attemptedStrategies.joined(separator: ","),
                    "xcodePathStrict": "\(pathStrictEnabled)",
                    "candidateCounts": "path=\(pathMatches.count)"
                ], runId: task.runId)
                return ExpWindowMatch(window: best, confidence: .exact, method: .documentPath, matchedValue: dir)
            }

            // Strategy 2: Match by project name in title
            attemptedStrategies.append("titlePatternExact")
            let exactTitleMatches = xcodeWindows.filter { window in
                guard Self.isDocPathCompatible(window, expectedDirectory: normalizedExpected) else { return false }
                guard let windowTitle = window.title?.lowercased() else { return false }
                // Xcode titles are typically: "ProjectName — Filename.swift" or just "ProjectName"
                return windowTitle.contains(" — \(dirBasename)") ||
                       windowTitle.contains(" - \(dirBasename)") ||
                       windowTitle.hasPrefix(dirBasename) ||
                       windowTitle == dirBasename
            }

            if exactTitleMatches.count == 1, let window = exactTitleMatches.first {
                DeskJigLog.debug(.restorationTrace, "Matched \(appName) window", fields: [
                    "taskId": task.taskId,
                    "taskType": task.taskType.rawValue,
                    "app": appName,
                    "windowId": Int(window.windowId),
                    "confidence": "high",
                    "method": "titlePattern",
                    "pattern": dirBasename,
                    "strategiesAttempted": attemptedStrategies.joined(separator: ","),
                    "xcodePathStrict": "\(pathStrictEnabled)",
                    "candidateCounts": "exactTitle=\(exactTitleMatches.count)"
                ], runId: task.runId)
                return ExpWindowMatch(window: window, confidence: .high, method: .titlePattern, matchedValue: window.title)
            }
            if exactTitleMatches.count > 1 {
                DeskJigLog.debug(.restorationTrace, "Ambiguous Xcode titlePatternExact match (strict path mode)", fields: [
                    "taskId": task.taskId,
                    "taskType": task.taskType.rawValue,
                    "xcodePathStrict": "\(pathStrictEnabled)",
                    "ambiguousReason": "titlePatternExactMultipleCandidates",
                    "candidateCounts": "exactTitle=\(exactTitleMatches.count)",
                    "waitMs": "0",
                    "expectedPath": normalizedExpected
                ], runId: task.runId)
                return nil
            }

            // Strategy 3: Title contains directory basename (looser match)
            attemptedStrategies.append("titlePatternLoose")
            let looseTitleMatches = xcodeWindows.filter { window in
                guard Self.isDocPathCompatible(window, expectedDirectory: normalizedExpected) else { return false }
                guard let windowTitle = window.title else { return false }
                return Self.titleContainsFolder(windowTitle, folderName: dirBasename)
            }

            if looseTitleMatches.count == 1, let window = looseTitleMatches.first {
                DeskJigLog.debug(.restorationTrace, "Matched \(appName) window", fields: [
                    "taskId": task.taskId,
                    "taskType": task.taskType.rawValue,
                    "app": appName,
                    "windowId": Int(window.windowId),
                    "confidence": "medium",
                    "method": "titlePattern",
                    "pattern": dirBasename,
                    "strategiesAttempted": attemptedStrategies.joined(separator: ","),
                    "xcodePathStrict": "\(pathStrictEnabled)",
                    "candidateCounts": "looseTitle=\(looseTitleMatches.count)"
                ], runId: task.runId)
                return ExpWindowMatch(window: window, confidence: .medium, method: .titlePattern, matchedValue: window.title)
            }
            if looseTitleMatches.count > 1 {
                DeskJigLog.debug(.restorationTrace, "Ambiguous Xcode titlePatternLoose match (strict path mode)", fields: [
                    "taskId": task.taskId,
                    "taskType": task.taskType.rawValue,
                    "xcodePathStrict": "\(pathStrictEnabled)",
                    "ambiguousReason": "titlePatternLooseMultipleCandidates",
                    "candidateCounts": "looseTitle=\(looseTitleMatches.count)",
                    "waitMs": "0",
                    "expectedPath": normalizedExpected
                ], runId: task.runId)
                return nil
            }
        }

        // No match found - log strategies attempted and return nil (triggers new window launch)
        DeskJigLog.debug(.restorationTrace, "No matching \(appName) window found - will launch new", fields: [
            "taskId": task.taskId,
            "taskType": task.taskType.rawValue,
            "strategiesAttempted": attemptedStrategies.joined(separator: ","),
            "windowsChecked": "\(xcodeWindows.count)",
            "expectedPath": directory ?? "none"
        ], runId: task.runId)
        return nil
    }

    // MARK: - Path Normalization

    /// Normalize a path for comparison by expanding tildes, resolving file:// URLs,
    /// URL-decoding, and standardizing the path format.
    private static func normalizePath(_ path: String) -> String {
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

    /// For .xcworkspace/.xcodeproj paths, compare against the parent directory.
    /// For source files, compare as-is so nested files can match by prefix.
    private static func comparableDocumentPath(_ path: String) -> String {
        let normalizedPath = normalizePath(path)
        if normalizedPath.hasSuffix(".xcworkspace") || normalizedPath.hasSuffix(".xcodeproj") {
            return URL(fileURLWithPath: normalizedPath).deletingLastPathComponent().path
        }
        return normalizedPath
    }

    /// Returns true when the candidate document path belongs to the expected directory:
    /// - exact directory match
    /// - or any file/subpath inside the directory
    private static func pathMatchesExpectedDirectory(_ path: String, expectedDirectory: String) -> Bool {
        let candidate = comparableDocumentPath(path)
        let expected = comparableDocumentPath(expectedDirectory)
        return candidate == expected || candidate.hasPrefix("\(expected)/")
    }

    /// A window is doc-path compatible when:
    /// - no path is available yet (launch in-flight), or
    /// - its path belongs to the expected directory.
    private static func isDocPathCompatible(_ window: SnapshotWindow, expectedDirectory: String) -> Bool {
        let docPath = window.ideDocumentPath ?? window.documentPath
        guard let rawPath = docPath, !rawPath.isEmpty else { return true }
        return pathMatchesExpectedDirectory(rawPath, expectedDirectory: expectedDirectory)
    }

    /// Checks if a window title contains the folder name using word-boundary matching.
    /// This avoids false positives (for example, `deskjig` matching `deskjig-web`).
    private static func titleContainsFolder(_ title: String, folderName: String) -> Bool {
        let escaped = NSRegularExpression.escapedPattern(for: folderName)
        let pattern = "(?:^|[^a-zA-Z0-9_-])\(escaped)(?:$|[^a-zA-Z0-9_-])"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else {
            return title.localizedCaseInsensitiveContains(folderName)
        }

        let range = NSRange(title.startIndex..., in: title)
        return regex.firstMatch(in: title, options: [], range: range) != nil
    }

    /// Prefer opening a concrete .xcworkspace/.xcodeproj path when the input is a directory.
    /// This avoids Xcode opening folder mode for repos that should open a workspace/project.
    private func resolveLaunchTargetPath(from directory: String?) -> (path: String?, source: String) {
        guard let directory else {
            return (nil, "none")
        }

        let expanded = (directory as NSString).expandingTildeInPath
        let normalizedURL = URL(fileURLWithPath: expanded).standardizedFileURL
        let normalizedPath = normalizedURL.path
        let lowercasedPath = normalizedPath.lowercased()

        if lowercasedPath.hasSuffix(".xcworkspace") || lowercasedPath.hasSuffix(".xcodeproj") {
            return (normalizedPath, "explicit-project-path")
        }

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: normalizedPath, isDirectory: &isDirectory), isDirectory.boolValue else {
            return (normalizedPath, "path-not-directory")
        }

        let preferredBaseName = normalizedURL.lastPathComponent.lowercased()
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: normalizedURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return (normalizedPath, "directory")
        }

        let workspaceCandidates = contents.filter { $0.pathExtension.lowercased() == "xcworkspace" }
        let projectCandidates = contents.filter { $0.pathExtension.lowercased() == "xcodeproj" }

        func selectPreferredCandidate(_ candidates: [URL]) -> URL? {
            if let exact = candidates.first(where: {
                $0.deletingPathExtension().lastPathComponent.lowercased() == preferredBaseName
            }) {
                return exact
            }

            return candidates.sorted {
                $0.lastPathComponent.localizedCaseInsensitiveCompare($1.lastPathComponent) == .orderedAscending
            }.first
        }

        if let preferredWorkspace = selectPreferredCandidate(workspaceCandidates) {
            return (preferredWorkspace.standardizedFileURL.path, "auto-xcworkspace")
        }
        if let preferredProject = selectPreferredCandidate(projectCandidates) {
            return (preferredProject.standardizedFileURL.path, "auto-xcodeproj")
        }

        return (normalizedPath, "directory")
    }
}
