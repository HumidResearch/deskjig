//  TerminalSupplementationService.swift
//  DeskJigShared

import Foundation
import AppKit
import CoreGraphics

// MARK: - Supplementation Result

/// Result of terminal window supplementation
public struct TerminalSupplementationResult: Sendable {
    /// Number of terminal windows that were enriched
    public let enrichedCount: Int
    /// Number of terminal windows that failed supplementation
    public let failedCount: Int
    /// Total time taken in milliseconds
    public let durationMs: Int
    /// Method used for fetching working directories
    public let method: TerminalFetchMethod
    /// Notes about the supplementation process
    public let notes: [String]

    public init(
        enrichedCount: Int,
        failedCount: Int,
        durationMs: Int,
        method: TerminalFetchMethod,
        notes: [String] = []
    ) {
        self.enrichedCount = enrichedCount
        self.failedCount = failedCount
        self.durationMs = durationMs
        self.method = method
        self.notes = notes
    }
}

// MARK: - Terminal Supplementation Service

/// Actor that enriches terminal windows in a snapshot with working directory data.
///
/// Terminal windows in quick CGWindowList captures lack reliable working directory information.
/// This service fetches fresh AX document paths (which contain the working directory)
/// for better terminal window matching during restoration.
///
/// ## Supported Terminals
/// - Ghostty (com.mitchellh.ghostty)
/// - Terminal.app (com.apple.Terminal)
/// - iTerm2 (com.googlecode.iterm2)
/// - Kitty (net.kovidgoyal.kitty)
/// - Alacritty (org.alacritty)
///
/// ## Usage
/// ```swift
/// let service = TerminalSupplementationService()
/// let enrichedSnapshot = await service.supplementTerminalWindows(
///     in: snapshot,
///     method: .axWithLsofFallback,
///     runId: "restore-123"
/// )
/// ```
public actor TerminalSupplementationService {

    // MARK: - Constants

    /// Tolerance for frame matching between AX windows and CGWindowList
    private let frameTolerance: CGFloat = 10.0

    // MARK: - Dependencies

    /// AX access used to resolve a terminal app's PID and enumerate its windows.
    /// Injected with a default so production call sites stay unchanged while
    /// tests can supply a mock; methods must use this property instead of
    /// referencing `AXWindowService.shared` directly (#481).
    private let axService: AXWindowEnumerating

    // MARK: - Initialization

    public init(axService: AXWindowEnumerating = AXWindowService.shared) {
        self.axService = axService
    }

    // MARK: - Public API

    /// Supplement terminal windows in a snapshot with working directory data.
    ///
    /// - Parameters:
    ///   - snapshot: The system snapshot containing terminal windows to enrich
    ///   - method: Method to use for fetching working directories
    ///   - runId: Restoration run ID for logging
    /// - Returns: A new snapshot with enriched terminal windows
    public func supplementTerminalWindows(
        in snapshot: SystemSnapshot,
        method: TerminalFetchMethod,
        runId: String
    ) async -> SystemSnapshot {
        let startTime = Date()

        // Find terminal windows in snapshot
        let terminalWindows = snapshot.windows.filter {
            guard let bundleId = $0.bundleId else { return false }
            return BundleRegistry.isTerminal(bundleId)
        }

        guard !terminalWindows.isEmpty else {
            DeskJigLog.debug(.terminal, "No terminal windows to supplement", runId: runId)
            return snapshot
        }

        DeskJigLog.debug(.restorationSnapshot, "Starting terminal supplementation", fields: [
            "count": terminalWindows.count,
            "method": method.rawValue
        ], runId: runId)

        // Skip if disabled
        if method == .disabled {
            DeskJigLog.debug(.terminal, "Terminal supplementation disabled", runId: runId)
            return markWindowsAsStatus(snapshot, status: .notRequired, runId: runId)
        }

        // Mark terminal windows as pending
        let workingSnapshot = markTerminalWindowsAsPending(snapshot, runId: runId)

        // Fetch working directories for each terminal
        let workingDirs = await fetchWorkingDirectories(
            for: terminalWindows,
            method: method,
            runId: runId
        )

        // Enrich windows with fetched data
        var enrichedCount = 0
        var failedCount = 0
        var enrichedWindows: [SnapshotWindow] = []

        for window in workingSnapshot.windows {
            if let bundleId = window.bundleId, BundleRegistry.isTerminal(bundleId) {
                var enriched = window

                // Apply working directory
                if let data = workingDirs[window.windowId] {
                    enriched.freshWorkingDirectory = data.path
                    enriched.workingDirectorySource = data.source
                    // Also update documentPath if it was nil
                    if enriched.documentPath == nil {
                        enriched.documentPath = data.path
                    }
                    enriched.terminalSupplementationStatus = .completed
                    enrichedCount += 1
                } else {
                    enriched.terminalSupplementationStatus = .failed
                    failedCount += 1
                }

                enrichedWindows.append(enriched)
            } else {
                enrichedWindows.append(window)
            }
        }

        let durationMs = Int(Date().timeIntervalSince(startTime) * 1000)

        DeskJigLog.info(.restorationSnapshot, "Terminal supplementation complete", fields: [
            "enriched": enrichedCount,
            "failed": failedCount,
            "durationMs": durationMs
        ], runId: runId)

        // Build new snapshot with enriched windows
        return SystemSnapshot(
            captureTime: snapshot.captureTime,
            captureDurationMs: snapshot.captureDurationMs,
            runId: snapshot.runId,
            timing: snapshot.timing,
            displays: snapshot.displays,
            windows: enrichedWindows,
            chromeCaptures: snapshot.chromeCaptures
        )
    }

    // MARK: - Private Helpers

    /// Data returned from working directory fetch
    private struct WorkingDirData {
        let path: String
        let source: TerminalWorkingDirectorySource
    }

    /// Mark all terminal windows as pending supplementation
    private func markTerminalWindowsAsPending(_ snapshot: SystemSnapshot, runId: String) -> SystemSnapshot {
        let windows = snapshot.windows.map { window -> SnapshotWindow in
            if let bundleId = window.bundleId, BundleRegistry.isTerminal(bundleId) {
                var updated = window
                updated.terminalSupplementationStatus = .pending
                return updated
            }
            return window
        }

        return SystemSnapshot(
            captureTime: snapshot.captureTime,
            captureDurationMs: snapshot.captureDurationMs,
            runId: snapshot.runId,
            timing: snapshot.timing,
            displays: snapshot.displays,
            windows: windows,
            chromeCaptures: snapshot.chromeCaptures
        )
    }

    /// Mark all windows with a specific status (for disabled case)
    private func markWindowsAsStatus(_ snapshot: SystemSnapshot, status: TerminalSupplementationStatus, runId: String) -> SystemSnapshot {
        let windows = snapshot.windows.map { window -> SnapshotWindow in
            var updated = window
            if let bundleId = window.bundleId, BundleRegistry.isTerminal(bundleId) {
                updated.terminalSupplementationStatus = status
            } else {
                updated.terminalSupplementationStatus = .notRequired
            }
            return updated
        }

        return SystemSnapshot(
            captureTime: snapshot.captureTime,
            captureDurationMs: snapshot.captureDurationMs,
            runId: snapshot.runId,
            timing: snapshot.timing,
            displays: snapshot.displays,
            windows: windows,
            chromeCaptures: snapshot.chromeCaptures
        )
    }

    /// Fetch working directories for terminal windows using appropriate method.
    private func fetchWorkingDirectories(
        for windows: [SnapshotWindow],
        method: TerminalFetchMethod,
        runId: String
    ) async -> [CGWindowID: WorkingDirData] {
        var result: [CGWindowID: WorkingDirData] = [:]

        // Group windows by bundle ID for efficient per-app fetching
        let windowsByBundle = Dictionary(grouping: windows) { $0.bundleId ?? "" }

        for (bundleId, bundleWindows) in windowsByBundle {
            var fetched: [CGWindowID: WorkingDirData] = [:]

            switch method {
            case .axAPI:
                fetched = await fetchViaAX(for: bundleWindows, bundleId: bundleId, runId: runId)
            case .lsof:
                if bundleId == BundleRegistry.iterm2 {
                    fetched = await fetchViaITermTTY(for: bundleWindows, runId: runId)
                    let missing = bundleWindows.filter { fetched[$0.windowId] == nil }
                    if !missing.isEmpty {
                        DeskJigLog.trace(.restorationSnapshot, "Falling back to lsof for iTerm2 windows", fields: [
                            "count": missing.count
                        ], runId: runId)
                        let lsofResults = await fetchViaLsof(for: missing, runId: runId)
                        for (id, data) in lsofResults {
                            fetched[id] = data
                        }
                    }
                } else {
                    fetched = await fetchViaLsof(for: bundleWindows, runId: runId)
                }
            case .titleParse:
                fetched = parseFromTitles(for: bundleWindows, runId: runId)
            case .axWithLsofFallback:
                // Try AX first
                fetched = await fetchViaAX(for: bundleWindows, bundleId: bundleId, runId: runId)
                // Fill gaps with lsof
                var missing = bundleWindows.filter { fetched[$0.windowId] == nil }
                if !missing.isEmpty, bundleId == BundleRegistry.iterm2 {
                    DeskJigLog.trace(.restorationSnapshot, "Falling back to iTerm2 TTY mapping", fields: [
                        "count": missing.count
                    ], runId: runId)
                    let ttyResults = await fetchViaITermTTY(for: missing, runId: runId)
                    for (id, data) in ttyResults {
                        fetched[id] = data
                    }
                    missing = bundleWindows.filter { fetched[$0.windowId] == nil }
                }

                if !missing.isEmpty {
                    DeskJigLog.trace(.restorationSnapshot, "Falling back to lsof", fields: [
                        "count": missing.count
                    ], runId: runId)
                    let lsofResults = await fetchViaLsof(for: missing, runId: runId)
                    for (id, data) in lsofResults {
                        fetched[id] = data
                    }
                }
            case .disabled:
                continue
            }

            for (id, data) in fetched {
                result[id] = data
            }
        }

        return result
    }

    /// Fetch working directory via iTerm TTY mapping (best-effort fallback).
    /// Uses AppleScript to fetch session TTYs, then resolves cwd via lsof.
    private func fetchViaITermTTY(
        for windows: [SnapshotWindow],
        runId: String
    ) async -> [CGWindowID: WorkingDirData] {
        guard !windows.isEmpty else { return [:] }

        let sessions = fetchITermSessions(runId: runId)
        guard !sessions.isEmpty else {
            DeskJigLog.debug(.terminal, "iTerm TTY mapping returned no sessions", runId: runId)
            return [:]
        }

        var windowsByTitle: [String: [SnapshotWindow]] = [:]
        for window in windows {
            let titleKey = normalizeTitleKey(window.title)
            windowsByTitle[titleKey, default: []].append(window)
        }

        var result: [CGWindowID: WorkingDirData] = [:]

        for session in sessions {
            guard let cwd = resolveWorkingDirectoryFromTTY(session.tty, runId: runId) else { continue }
            let titleKey = normalizeTitleKey(session.title)

            if var list = windowsByTitle[titleKey], !list.isEmpty {
                let window = list.removeFirst()
                windowsByTitle[titleKey] = list
                result[window.windowId] = WorkingDirData(path: cwd, source: .tty)
                DeskJigLog.debug(.restorationSnapshot, "iTerm TTY working dir", fields: [
                    "windowId": "\(window.windowId)",
                    "title": session.title,
                    "cwd": cwd
                ], runId: runId)
                continue
            }

            if let window = findFuzzyTitleMatch(for: session.title, in: &windowsByTitle) {
                result[window.windowId] = WorkingDirData(path: cwd, source: .tty)
                DeskJigLog.debug(.restorationSnapshot, "iTerm TTY working dir (fuzzy)", fields: [
                    "windowId": "\(window.windowId)",
                    "title": session.title,
                    "cwd": cwd
                ], runId: runId)
            }
        }

        DeskJigLog.trace(.restorationSnapshot, "Fetched working dirs via iTerm TTY mapping", fields: [
            "fetched": result.count,
            "total": windows.count
        ], runId: runId)
        return result
    }

    private struct ITermSession {
        let title: String
        let tty: String
    }

    private func fetchITermSessions(runId: String) -> [ITermSession] {
        let script = """
        tell application "iTerm2"
            set output to ""
            repeat with w in windows
                repeat with s in sessions of w
                    set output to output & (name of s) & "|" & (tty of s) & "\\n"
                end repeat
            end repeat
            return output
        end tell
        """

        let output = AppleScriptRunner.runOsascript(script, timeout: nil).output
        let lines = output.split(separator: "\n")

        var sessions: [ITermSession] = []
        for line in lines {
            let parts = line.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { continue }
            let title = String(parts[0]).trimmingCharacters(in: .whitespacesAndNewlines)
            let tty = String(parts[1]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty, !tty.isEmpty else { continue }
            sessions.append(ITermSession(title: title, tty: tty))
        }

        DeskJigLog.trace(.restorationSnapshot, "iTerm TTY mapping sessions", fields: [
            "count": sessions.count
        ], runId: runId)
        return sessions
    }

    private func findFuzzyTitleMatch(
        for sessionTitle: String,
        in windowsByTitle: inout [String: [SnapshotWindow]]
    ) -> SnapshotWindow? {
        let sessionKey = normalizeTitleKey(sessionTitle)
        for (key, windows) in windowsByTitle {
            if key.contains(sessionKey) || sessionKey.contains(key) {
                var list = windows
                let window = list.removeFirst()
                windowsByTitle[key] = list
                return window
            }
        }
        return nil
    }

    private func resolveWorkingDirectoryFromTTY(_ tty: String, runId: String) -> String? {
        let device = tty.replacingOccurrences(of: "/dev/", with: "")
        guard !device.isEmpty else { return nil }

        let psOutput = runCommand("/bin/ps", arguments: ["-t", device, "-o", "pid=", "-o", "comm="])
        let pidLines = psOutput.split(separator: "\n")

        let candidates: [pid_t] = pidLines.compactMap { line in
            let parts = line.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: " ", maxSplits: 1)
            guard let pidPart = parts.first else { return nil }
            return Int32(pidPart)
        }

        for pid in candidates.reversed() {
            if let cwd = fetchCwdForPid(pid) {
                if cwd != "/" && !cwd.hasPrefix("/dev") {
                    return cwd
                }
            }
        }

        DeskJigLog.debug(.terminal, "No cwd resolved for tty \(tty)", runId: runId)
        return nil
    }

    private func fetchCwdForPid(_ pid: pid_t) -> String? {
        let output = runCommand("/usr/sbin/lsof", arguments: ["-a", "-d", "cwd", "-p", "\(pid)", "-Fn"])
        for line in output.split(separator: "\n") {
            if line.hasPrefix("n") {
                return String(line.dropFirst())
            }
        }
        return nil
    }

    private func normalizeTitleKey(_ title: String?) -> String {
        (title ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private func runCommand(_ launchPath: String, arguments: [String]) -> String {
        ProcessRunner.run(launchPath, arguments: arguments)
    }

    /// Fetch working directory via AX API.
    /// Uses kAXDocument attribute which returns file:// URL to working directory.
    private func fetchViaAX(
        for windows: [SnapshotWindow],
        bundleId: String,
        runId: String
    ) async -> [CGWindowID: WorkingDirData] {
        var result: [CGWindowID: WorkingDirData] = [:]

        // Get PID for this terminal app
        guard let pid = axService.getProcessID(for: bundleId) else {
            DeskJigLog.debug(.terminal, "Terminal app not running: \(bundleId)", runId: runId)
            return result
        }

        // Get AX windows via the shared enumeration skeleton.
        guard let axWindows = axService.enumerateWindows(
            pid: pid,
            includeTitle: false,
            includeWindowNumber: false,
            includeDocumentPath: true
        ) else {
            DeskJigLog.debug(.terminal, "Failed to get AX windows for \(bundleId)", runId: runId)
            return result
        }

        // Build frame -> window data mapping from AX windows
        var axWindowData: [(frame: CGRect, docPath: String?)] = []
        for axWindow in axWindows {
            guard let frame = axWindow.frame else { continue }
            axWindowData.append((frame: frame, docPath: axWindow.documentPath))
        }

        // Match each CGWindowList window to an AX window by frame
        for window in windows {
            for axData in axWindowData {
                if framesMatch(window.frame, axData.frame), let path = axData.docPath, path != "/" {
                    result[window.windowId] = WorkingDirData(
                        path: path,
                        source: .axDocument
                    )
                    DeskJigLog.debug(.restorationSnapshot, "AX working dir", fields: [
                        "windowId": "\(window.windowId)",
                        "path": path
                    ], runId: runId)
                    break
                }
            }
        }

        DeskJigLog.trace(.restorationSnapshot, "Fetched working dirs via AX", fields: [
            "fetched": result.count,
            "total": windows.count,
            "bundleId": bundleId
        ], runId: runId)
        return result
    }

    /// Fetch working directory via lsof (slower fallback).
    /// Uses lsof to find the cwd of the terminal process.
    private func fetchViaLsof(
        for windows: [SnapshotWindow],
        runId: String
    ) async -> [CGWindowID: WorkingDirData] {
        var result: [CGWindowID: WorkingDirData] = [:]

        for window in windows {
            let pid = window.pid

            // Run: lsof -a -d cwd -p <pid> -Fn
            // This shows the current working directory for the process
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
            process.arguments = ["-a", "-d", "cwd", "-p", "\(pid)", "-Fn"]

            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice

            do {
                try process.run()
                process.waitUntilExit()

                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                if let output = String(data: data, encoding: .utf8) {
                    // Parse lsof output: lines starting with 'n' contain the path
                    for line in output.components(separatedBy: "\n") {
                        if line.hasPrefix("n") && !line.hasPrefix("n/dev") {
                            let path = String(line.dropFirst())
                            // Skip root directory - indicates we got parent process cwd, not shell's
                            guard path != "/" else {
                                DeskJigLog.trace(.restorationSnapshot, "lsof returned root, skipping", fields: [
                                    "pid": "\(pid)",
                                    "windowId": "\(window.windowId)"
                                ], runId: runId)
                                continue
                            }
                            result[window.windowId] = WorkingDirData(
                                path: path,
                                source: .lsof
                            )
                            DeskJigLog.debug(.restorationSnapshot, "lsof working dir", fields: [
                                "windowId": "\(window.windowId)",
                                "path": path
                            ], runId: runId)
                            break
                        }
                    }
                }
            } catch {
                DeskJigLog.debug(.terminal, "lsof failed for pid \(pid): \(error)", runId: runId)
            }
        }

        DeskJigLog.trace(.restorationSnapshot, "Fetched working dirs via lsof", fields: [
            "fetched": result.count,
            "total": windows.count
        ], runId: runId)
        return result
    }

    /// Parse working directory from window titles.
    /// Handles common terminal title formats.
    private func parseFromTitles(
        for windows: [SnapshotWindow],
        runId: String
    ) -> [CGWindowID: WorkingDirData] {
        var result: [CGWindowID: WorkingDirData] = [:]

        for window in windows {
            guard let title = window.title else { continue }

            if let path = parseWorkingDirectoryFromTitle(title) {
                result[window.windowId] = WorkingDirData(
                    path: path,
                    source: .titleParse
                )
                DeskJigLog.debug(.restorationSnapshot, "Title-parsed working dir", fields: [
                    "windowId": "\(window.windowId)",
                    "path": path
                ], runId: runId)
            }
        }

        DeskJigLog.debug(.restorationSnapshot, "Parsed working dirs from titles", fields: [
            "parsed": result.count,
            "total": windows.count
        ], runId: runId)
        return result
    }

    /// Parse working directory from terminal window title.
    /// Handles common formats:
    /// - "user@host:~/path"
    /// - "~/path - Ghostty"
    /// - "path -- Terminal"
    private func parseWorkingDirectoryFromTitle(_ title: String) -> String? {
        // Pattern: "user@host:path" (common SSH/shell format)
        if let colonIndex = title.lastIndex(of: ":") {
            let afterColon = String(title[title.index(after: colonIndex)...])
                .trimmingCharacters(in: .whitespaces)
            if afterColon.hasPrefix("~") || afterColon.hasPrefix("/") {
                // Remove trailing app name if present (e.g., " - Ghostty")
                var path = afterColon
                for separator in [" - ", " — ", " – "] {
                    if let range = path.range(of: separator) {
                        path = String(path[..<range.lowerBound])
                        break
                    }
                }
                return expandTildePath(path.trimmingCharacters(in: .whitespaces))
            }
        }

        // Pattern: "path - AppName" or "path -- AppName"
        for separator in [" - ", " — ", " – ", " -- "] {
            if let range = title.range(of: separator) {
                let before = String(title[..<range.lowerBound])
                if before.hasPrefix("~") || before.hasPrefix("/") {
                    return expandTildePath(before)
                }
            }
        }

        // Check if whole title is a path
        if title.hasPrefix("~") || title.hasPrefix("/") {
            return expandTildePath(title)
        }

        return nil
    }

    /// Expand tilde in path to full home directory
    private func expandTildePath(_ path: String) -> String {
        if path.hasPrefix("~") {
            let home = FileManager.default.homeDirectoryForCurrentUser.path
            return home + path.dropFirst()
        }
        return path
    }

    /// Check if two frames match within tolerance.
    private func framesMatch(_ frame1: CGRect, _ frame2: CGRect) -> Bool {
        frame1.approximatelyEquals(frame2, tolerance: frameTolerance)
    }
}

// MARK: - SystemSnapshot Extension for Terminal

extension SystemSnapshot {
    /// Returns true if any terminal windows are still pending supplementation.
    public var hasPendingTerminalSupplementation: Bool {
        windows.contains { $0.terminalSupplementationStatus == .pending }
    }

    /// Returns terminal windows that have completed supplementation.
    public var supplementedTerminalWindows: [SnapshotWindow] {
        windows.filter { $0.terminalSupplementationStatus == .completed }
    }

    /// Find a terminal window by working directory.
    public func findTerminalWindow(withWorkingDirectory path: String, bundleId: String? = nil) -> SnapshotWindow? {
        let normalizedPath = normalizePath(path)
        return windows.first { window in
            // Check bundle ID if specified
            if let targetBundleId = bundleId {
                guard window.bundleId == targetBundleId else { return false }
            } else {
                guard let bundleId = window.bundleId, BundleRegistry.isTerminal(bundleId) else { return false }
            }

            // Check supplemented working directory first
            if let workDir = window.freshWorkingDirectory {
                return normalizePath(workDir) == normalizedPath
            }
            // Fall back to documentPath
            if let docPath = window.documentPath {
                return normalizePath(docPath) == normalizedPath
            }
            return false
        }
    }

    /// Normalize a path for comparison (expand ~, lowercase, remove trailing slash)
    private func normalizePath(_ path: String) -> String {
        var normalized = path

        // Expand tilde
        if normalized.hasPrefix("~") {
            let home = FileManager.default.homeDirectoryForCurrentUser.path
            normalized = home + normalized.dropFirst()
        }

        // Standardize path
        normalized = (normalized as NSString).standardizingPath.lowercased()

        // Remove trailing slash
        if normalized.hasSuffix("/") && normalized.count > 1 {
            normalized = String(normalized.dropLast())
        }

        return normalized
    }
}
