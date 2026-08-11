//  OpenByPathMatcher.swift
//  DeskJigShared

import Foundation
import CoreGraphics

/// Helper for matching OpenByPath windows.
public struct OpenByPathMatcher {

    // MARK: - Matching Strategies

    public enum MatchStrategy {
        case documentPath(String)
        case titleToken(String)
        case ghosttyIndex(String, Int)
    }

    // MARK: - Finding Windows

    /// Find matching windows for the given configuration.
    /// - Parameters:
    ///   - bundleID: The bundle identifier
    ///   - directoryPath: The target directory path
    ///   - expectedTitle: Optional expected title (for token/Ghostty)
    ///   - targetFrame: Target frame for sorting candidates (unused for open-by-path matching)
    ///   - windowID: Workspace window ID (for logging)
    /// - Returns: List of WindowHandle sorted by relevance (best match first)
    public static func findMatches(
        bundleID: String,
        directoryPath: String,
        expectedTitle: String?,
        targetFrame: CGRect?,
        windowID: UUID?
    ) -> [WindowHandle] {

        let windows: [WindowHandle]
        if bundleID == OpenByPathBundleIdentifiers.ghostty {
            windows = getAllGhosttyWindows()
        } else {
            windows = Window.allAcrossProcesses(forBundleID: bundleID)
        }

        // Handles were just built by allAcrossProcesses/getAllGhosttyWindows above and
        // are already fresh; the previous per-candidate `refresh()` was a redundant full
        // AX re-enumeration of every candidate (winh-04). Use them directly.
        let activeWindows = windows

        if activeWindows.isEmpty { return [] }

        logCandidates(
            bundleID: bundleID,
            expectedTitle: expectedTitle,
            directoryPath: directoryPath,
            windows: activeWindows
        )

        // 1. Ghostty specific logic (title-only)
        if bundleID == OpenByPathBundleIdentifiers.ghostty {
            let matches = findGhosttyMatches(windows: activeWindows, directoryPath: directoryPath, expectedTitle: expectedTitle)
            logMatches(bundleID: bundleID, matches: matches)
            return matches
        }

        // 2. IDE logic (Document Path primary)
        if bundleID == OpenByPathBundleIdentifiers.cursor ||
            bundleID == OpenByPathBundleIdentifiers.codex ||
            bundleID == OpenByPathBundleIdentifiers.vscode ||
            bundleID == OpenByPathBundleIdentifiers.xcode {
            let matches = findDocumentMatches(
                windows: activeWindows,
                directoryPath: directoryPath,
                expectedTitle: expectedTitle,
                bundleID: bundleID
            )
            logMatches(bundleID: bundleID, matches: matches)
            return matches
        }

        // 3. Terminal/iTerm/Kitty/Alacritty logic (title-first, doc fallback)
        let matches = findTitleTokenMatches(
            windows: activeWindows,
            directoryPath: directoryPath,
            expectedTitle: expectedTitle
        )
        logMatches(bundleID: bundleID, matches: matches)
        return matches
    }

    // MARK: - Private Matchers

    private static func findGhosttyMatches(
        windows: [WindowHandle],
        directoryPath: String,
        expectedTitle: String?
    ) -> [WindowHandle] {
        guard let expectedTitle, !expectedTitle.isEmpty else {
            DeskJigLog.debug(.restorationExecutor, "Ghostty match skipped: missing expectedTitle for '\(directoryPath)'")
            return []
        }

        let matches = windows.filter { $0.title == expectedTitle }
        return sortCandidates(matches)
    }

    private static func findDocumentMatches(
        windows: [WindowHandle],
        directoryPath: String,
        expectedTitle: String?,
        bundleID: String
    ) -> [WindowHandle] {
        let expectedPath = normalizePath(directoryPath) ?? directoryPath
        let token = expectedTitle ?? URL(fileURLWithPath: expectedPath).lastPathComponent

        // 1. Exact document path match (highest confidence for IDEs)
        let docMatches = windows.filter {
            guard let candidatePath = normalizedDocumentPath(for: $0, bundleID: bundleID) else { return false }
            if bundleID == OpenByPathBundleIdentifiers.xcode {
                return pathMatchesExpectedDirectory(observedPath: candidatePath, expectedDirectory: expectedPath)
            }
            return candidatePath == expectedPath
        }
        if !docMatches.isEmpty {
            return sortCandidates(docMatches)
        }

        // 2. Title suffix match (Cursor " - ProjectName")
        let suffixMatches = windows.filter {
            guard let title = $0.title else { return false }
            let separator = " \u{2014} "
            if let range = title.range(of: separator, options: .backwards) {
                let suffix = title[range.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
                return suffix.localizedCaseInsensitiveCompare(token) == .orderedSame
            }
            return false
        }
        if !suffixMatches.isEmpty {
            return sortCandidates(suffixMatches)
        }

        // 3. Title token match (word-boundary to avoid false positives)
        let titleMatches = windows.filter {
            guard let title = $0.title else { return false }
            return titleContainsFolder(title, folderName: token)
        }
        if !titleMatches.isEmpty {
            return sortCandidates(titleMatches)
        }

        // 4. Exact title fallback, but skip generic IDE app-name titles.
        if let expectedTitle, !expectedTitle.isEmpty, !isGenericIDETitle(expectedTitle, bundleID: bundleID) {
            let exactMatches = windows.filter { $0.title == expectedTitle }
            if !exactMatches.isEmpty {
                return sortCandidates(exactMatches)
            }
        }

        return []
    }

    private static func findTitleTokenMatches(
        windows: [WindowHandle],
        directoryPath: String,
        expectedTitle: String?
    ) -> [WindowHandle] {
        let normalizedPath = normalizePath(directoryPath)

        // Exclude launch command windows for Terminal
        let filteredWindows = windows.filter {
            !($0.title?.localizedCaseInsensitiveContains("launch.command") ?? false)
        }

        // 1. Exact title match
        if let expectedTitle, !expectedTitle.isEmpty {
            let titleMatches = filteredWindows.filter { $0.title == expectedTitle }
            if !titleMatches.isEmpty {
                return sortCandidates(titleMatches)
            }
        } else {
            DeskJigLog.debug(.restorationExecutor, "Title match skipped: missing expectedTitle for '\(directoryPath)'")
        }

        // 2. Document path fallback
        if let normalizedPath {
            let docMatches = filteredWindows.filter { normalizePath($0.documentPath) == normalizedPath }
            if !docMatches.isEmpty {
                return sortCandidates(docMatches)
            }
        }

        return []
    }

    // MARK: - Helpers

    private static func sortCandidates(_ candidates: [WindowHandle]) -> [WindowHandle] {
        return candidates.sorted { lhs, rhs in
            // Tie-breaker: prefer the managed terminal-title prefix.
            let lhsManagedTitle = lhs.title?.lowercased().hasPrefix("\(BundleIdentity.terminalTitleTokenPrefix):") ?? false
            let rhsManagedTitle = rhs.title?.lowercased().hasPrefix("\(BundleIdentity.terminalTitleTokenPrefix):") ?? false
            if lhsManagedTitle != rhsManagedTitle {
                return lhsManagedTitle
            }

            let lhsTitle = lhs.title ?? ""
            let rhsTitle = rhs.title ?? ""
            if lhsTitle != rhsTitle {
                return lhsTitle.localizedCaseInsensitiveCompare(rhsTitle) == .orderedAscending
            }

            let lhsPid = lhs.processID ?? 0
            let rhsPid = rhs.processID ?? 0
            if lhsPid != rhsPid {
                return lhsPid < rhsPid
            }

            let lhsHash = lhs.axElementHash ?? 0
            let rhsHash = rhs.axElementHash ?? 0
            return lhsHash < rhsHash
        }
    }

    private static func normalizePath(_ path: String?) -> String? {
        PathNormalization.normalizeURLPath(path)
    }

    private static func pathMatchesExpectedDirectory(observedPath: String, expectedDirectory: String) -> Bool {
        XcodePathMatching.pathMatchesDirectory(observedPath: observedPath, expectedDirectory: expectedDirectory)
    }

    private static func normalizedDocumentPath(for window: WindowHandle, bundleID: String) -> String? {
        guard let docPath = normalizePath(window.documentPath) else { return nil }

        if bundleID == OpenByPathBundleIdentifiers.xcode {
            return extractDirectoryFromXcodeProjectPath(docPath)
        }

        return docPath
    }

    private static func extractDirectoryFromXcodeProjectPath(_ normalizedPath: String) -> String {
        if normalizedPath.hasSuffix(".xcworkspace") || normalizedPath.hasSuffix(".xcodeproj") {
            return URL(fileURLWithPath: normalizedPath).deletingLastPathComponent().path
        }
        return normalizedPath
    }

    static func isGenericIDETitle(_ title: String, bundleID: String) -> Bool {
        let normalized = title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch bundleID {
        case OpenByPathBundleIdentifiers.xcode:
            return normalized == "xcode"
        case OpenByPathBundleIdentifiers.cursor:
            return normalized == "cursor"
        case OpenByPathBundleIdentifiers.codex:
            return normalized == "codex"
        case OpenByPathBundleIdentifiers.vscode:
            return normalized == "code" || normalized == "visual studio code"
        default:
            return false
        }
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

    private static func getAllGhosttyWindows() -> [WindowHandle] {
        let pids = GhosttyProcessLocator.findPIDs()
        guard !pids.isEmpty else { return [] }

        var windows: [WindowHandle] = []
        let service = AXWindowService.shared
        for pid in pids {
            let axWindows = service.getWindows(forProcessID: pid, bundleIdentifier: OpenByPathBundleIdentifiers.ghostty)
            windows.append(contentsOf: axWindows.map { WindowHandle(axWindow: $0) })
        }
        return windows
    }

    private static func logCandidates(
        bundleID: String,
        expectedTitle: String?,
        directoryPath: String,
        windows: [WindowHandle]
    ) {
        DeskJigLog.debug(
            .restorationExecutor,
            "Matcher candidates bundle='\(bundleID)' expectedTitle='\(expectedTitle ?? "nil")' path='\(directoryPath)' count=\(windows.count)"
        )
        for window in windows {
            DeskJigLog.debug(.restorationExecutor, "Candidate \(describeWindow(window))")
        }
    }

    private static func logMatches(bundleID: String, matches: [WindowHandle]) {
        DeskJigLog.debug(.restorationExecutor, "Matcher results bundle='\(bundleID)' matches=\(matches.count)")
        for window in matches {
            DeskJigLog.debug(.restorationExecutor, "Match \(describeWindow(window))")
        }
    }

    private static func describeWindow(_ window: WindowHandle) -> String {
        let frameStr = window.frame.map { String(format: "(%.0f, %.0f) %.0fx%.0f", $0.origin.x, $0.origin.y, $0.size.width, $0.size.height) } ?? "nil"
        let visible = (!window.isHidden && !window.isMinimized) ? "1" : "0"
        return "title='\(window.title ?? "nil")' doc='\(window.documentPath ?? "nil")' frame=\(frameStr) pid=\(window.processID.map(String.init) ?? "nil") hidden=\(window.isHidden ? "1" : "0") minimized=\(window.isMinimized ? "1" : "0") visible=\(visible) ax=\(window.axElementHash.map(String.init) ?? "nil") bundle=\(window.bundleIdentifier ?? "nil")"
    }
}

