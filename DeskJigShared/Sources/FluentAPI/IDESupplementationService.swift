//  IDESupplementationService.swift
//  DeskJigShared

import Foundation
import AppKit
import CoreGraphics

// MARK: - Supplementation Result

/// Result of IDE window supplementation
public struct IDESupplementationResult: Sendable {
    /// Number of IDE windows that were enriched
    public let enrichedCount: Int
    /// Number of IDE windows that failed supplementation
    public let failedCount: Int
    /// Total time taken in milliseconds
    public let durationMs: Int
    /// Method used for fetching document paths
    public let method: IDEFetchMethod
    /// Notes about the supplementation process
    public let notes: [String]

    public init(
        enrichedCount: Int,
        failedCount: Int,
        durationMs: Int,
        method: IDEFetchMethod,
        notes: [String] = []
    ) {
        self.enrichedCount = enrichedCount
        self.failedCount = failedCount
        self.durationMs = durationMs
        self.method = method
        self.notes = notes
    }
}

// MARK: - IDE Supplementation Service

/// Actor that enriches IDE windows in a snapshot with document path data.
///
/// IDE windows in quick CGWindowList captures lack reliable document path information.
/// This service fetches document paths (project folders) for better IDE window matching
/// during restoration.
///
/// ## Supported IDEs
/// - Cursor (com.todesktop.230313mzl4w4u92)
/// - Visual Studio Code (com.microsoft.VSCode)
///
/// ## Data Sources
/// - **Primary (Cursor)**: Cursor's storage.json contains window-folder mappings
/// - **Fallback**: AX API kAXDocument attribute, process-tree lsof cwd
///
/// ## Usage
/// ```swift
/// let service = IDESupplementationService()
/// let enrichedSnapshot = await service.supplementIDEWindows(
///     in: snapshot,
///     method: .cursorStateWithAXFallback,
///     runId: "restore-123"
/// )
/// ```
public actor IDESupplementationService {

    // MARK: - Constants

    /// Tolerance for frame matching between state file and CGWindowList
    private let frameTolerance: CGFloat = 50.0

    // MARK: - Dependencies

    private let cursorStateReader: CursorStateReader

    // MARK: - Initialization

    public init(cursorStateReader: CursorStateReader = CursorStateReader()) {
        self.cursorStateReader = cursorStateReader
    }

    // MARK: - Public API

    /// Supplement IDE windows in a snapshot with document path data.
    ///
    /// - Parameters:
    ///   - snapshot: The system snapshot containing IDE windows to enrich
    ///   - method: Method to use for fetching document paths
    ///   - runId: Restoration run ID for logging
    /// - Returns: A new snapshot with enriched IDE windows
    public func supplementIDEWindows(
        in snapshot: SystemSnapshot,
        method: IDEFetchMethod,
        runId: String,
        bundleAllowlist: Set<String>? = nil
    ) async -> SystemSnapshot {
        let startTime = Date()

        // Find IDE windows in snapshot
        let ideWindows = snapshot.windows.filter {
            guard let bundleId = $0.bundleId else { return false }
            guard BundleRegistry.isIDE(bundleId) else { return false }
            if let bundleAllowlist {
                return bundleAllowlist.contains(bundleId)
            }
            return true
        }

        guard !ideWindows.isEmpty else {
            DeskJigLog.debug(.restorationSnapshot, "No IDE windows to supplement", runId: runId)
            return snapshot
        }

        DeskJigLog.debug(
            .restorationSnapshot,
            "Starting IDE supplementation (count=\(ideWindows.count), method=\(method.rawValue))",
            runId: runId
        )

        // Skip if disabled
        if method == .disabled {
            DeskJigLog.debug(.restorationSnapshot, "IDE supplementation disabled", runId: runId)
            return markWindowsAsStatus(snapshot, status: .notRequired, runId: runId)
        }

        // Mark IDE windows as pending
        let workingSnapshot = markIDEWindowsAsPending(snapshot, runId: runId)

        // Fetch document paths for each IDE
        let documentPaths = await fetchDocumentPaths(
            for: ideWindows,
            method: method,
            runId: runId
        )

        // Enrich windows with fetched data
        var enrichedCount = 0
        var failedCount = 0
        var enrichedWindows: [SnapshotWindow] = []

        for window in workingSnapshot.windows {
            if let bundleId = window.bundleId, BundleRegistry.isIDE(bundleId) {
                var enriched = window

                // Apply document path
                if let data = documentPaths[window.windowId] {
                    enriched.ideDocumentPath = data.path
                    enriched.ideDocumentPathSource = data.source
                    // Keep base documentPath synchronized to avoid stale AX frame matches
                    // from earlier snapshot enrichment influencing later matching logic.
                    enriched.documentPath = data.path
                    enriched.ideSupplementationStatus = .completed
                    enrichedCount += 1
                    DeskJigLog.trace(
                        .restorationSnapshot,
                        "Enriched window \(window.windowId) with path: \(data.path)",
                        runId: runId
                    )
                } else {
                    enriched.ideSupplementationStatus = .failed
                    failedCount += 1
                }

                enrichedWindows.append(enriched)
            } else {
                enrichedWindows.append(window)
            }
        }

        let durationMs = Int(Date().timeIntervalSince(startTime) * 1000)

        DeskJigLog.debug(
            .restorationSnapshot,
            "IDE supplementation complete (enriched=\(enrichedCount), failed=\(failedCount), duration=\(durationMs)ms)",
            runId: runId
        )

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

    /// Data returned from document path fetch
    private struct DocumentPathData {
        let path: String
        let source: IDEDocumentPathSource
    }

    /// Mark all IDE windows as pending supplementation
    private func markIDEWindowsAsPending(_ snapshot: SystemSnapshot, runId: String) -> SystemSnapshot {
        let windows = snapshot.windows.map { window -> SnapshotWindow in
            if let bundleId = window.bundleId, BundleRegistry.isIDE(bundleId) {
                var updated = window
                updated.ideSupplementationStatus = .pending
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
    private func markWindowsAsStatus(_ snapshot: SystemSnapshot, status: IDESupplementationStatus, runId: String) -> SystemSnapshot {
        let windows = snapshot.windows.map { window -> SnapshotWindow in
            var updated = window
            if let bundleId = window.bundleId, BundleRegistry.isIDE(bundleId) {
                updated.ideSupplementationStatus = status
            } else {
                updated.ideSupplementationStatus = .notRequired
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

    /// Fetch document paths for IDE windows using appropriate method.
    private func fetchDocumentPaths(
        for windows: [SnapshotWindow],
        method: IDEFetchMethod,
        runId: String
    ) async -> [CGWindowID: DocumentPathData] {
        var result: [CGWindowID: DocumentPathData] = [:]

        // Group windows by bundle ID for efficient per-app fetching
        let windowsByBundle = Dictionary(grouping: windows) { $0.bundleId ?? "" }

        for (bundleId, bundleWindows) in windowsByBundle {
            var fetched: [CGWindowID: DocumentPathData] = [:]

            switch method {
            case .cursorState:
                // Only use Cursor state for Cursor windows
                if bundleId == BundleRegistry.cursor {
                    fetched = fetchViaCursorState(for: bundleWindows, runId: runId)
                } else {
                    // Other IDEs - use AX API
                    fetched = await fetchViaAX(for: bundleWindows, bundleId: bundleId, runId: runId)
                }

            case .axAPI:
                fetched = await fetchViaAX(for: bundleWindows, bundleId: bundleId, runId: runId)

            case .cursorStateWithAXFallback:
                // Try Cursor state first for Cursor windows
                if bundleId == BundleRegistry.cursor {
                    fetched = fetchViaCursorState(for: bundleWindows, runId: runId)
                    // Fill gaps with AX
                    let missing = bundleWindows.filter { fetched[$0.windowId] == nil }
                    if !missing.isEmpty {
                        DeskJigLog.trace(
                            .restorationSnapshot,
                            "Falling back to AX for \(missing.count) Cursor windows",
                            runId: runId
                        )
                        let axResults = await fetchViaAX(for: missing, bundleId: bundleId, runId: runId)
                        for (id, data) in axResults {
                            fetched[id] = data
                        }
                    }

                    let remaining = bundleWindows.filter { fetched[$0.windowId] == nil }
                    if !remaining.isEmpty {
                        DeskJigLog.trace(
                            .restorationSnapshot,
                            "Falling back to process tree cwd for \(remaining.count) Cursor windows",
                            runId: runId
                        )
                        let processResults = await fetchViaProcessTreeLsof(
                            for: remaining,
                            bundleId: bundleId,
                            runId: runId
                        )
                        for (id, data) in processResults {
                            fetched[id] = data
                        }
                    }
                } else {
                    // Other IDEs - just use AX API
                    fetched = await fetchViaAX(for: bundleWindows, bundleId: bundleId, runId: runId)
                    let remaining = bundleWindows.filter { fetched[$0.windowId] == nil }
                    if !remaining.isEmpty {
                        DeskJigLog.trace(
                            .restorationSnapshot,
                            "Falling back to process tree cwd for \(remaining.count) \(bundleId) windows",
                            runId: runId
                        )
                        let processResults = await fetchViaProcessTreeLsof(
                            for: remaining,
                            bundleId: bundleId,
                            runId: runId
                        )
                        for (id, data) in processResults {
                            fetched[id] = data
                        }
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

    /// Fetch document paths from Cursor's storage.json state file.
    /// Uses title-based matching (em-dash pattern) as primary strategy, frame matching as fallback.
    /// IMPORTANT: Uses one-to-one matching - each Cursor state entry can only match one window.
    private func fetchViaCursorState(
        for windows: [SnapshotWindow],
        runId: String
    ) -> [CGWindowID: DocumentPathData] {
        var result: [CGWindowID: DocumentPathData] = [:]

        let cursorWindowStates = cursorStateReader.getAllWindowStates()

        guard !cursorWindowStates.isEmpty else {
            DeskJigLog.debug(.restorationSnapshot, "CursorStateReader returned no windows", runId: runId)
            return result
        }

        DeskJigLog.debug(
            .restorationSnapshot,
            "CursorStateReader found \(cursorWindowStates.count) window states",
            runId: runId
        )

        // Fetch FRESH AX titles to avoid stale snapshot titles
        // Snapshot titles may have changed if user switched tabs/files since capture
        let freshTitles = fetchFreshAxTitles(
            for: windows,
            bundleId: "com.todesktop.230313mzl4w4u92", // Cursor bundle ID
            runId: runId
        )

        // Build a mutable copy of cursor states with matched flag for one-to-one matching
        struct CursorStateEntry {
            let folderPath: String?
            let frame: CGRect?
            let projectName: String
            var matched: Bool
        }

        var cursorStates: [CursorStateEntry] = cursorWindowStates.map { state in
            let projectName = state.folderPath.map { ($0 as NSString).lastPathComponent } ?? ""
            return CursorStateEntry(
                folderPath: state.folderPath,
                frame: state.frame,
                projectName: projectName,
                matched: false
            )
        }

        // Strategy 1: Match by TITLE suffix (em-dash pattern) - MOST RELIABLE
        // Cursor titles: "filename — ProjectName" where ProjectName is the folder name
        // Use fresh AX titles when available, fall back to snapshot titles
        let emDashSeparator = " \u{2014} "  // em-dash with spaces
        for window in windows where result[window.windowId] == nil {
            // Prefer fresh AX title, fall back to snapshot title
            let windowTitle = freshTitles[window.windowId] ?? window.title
            guard let title = windowTitle else { continue }
            guard let range = title.range(of: emDashSeparator, options: .backwards) else { continue }
            let projectName = String(title[range.upperBound...])
                .trimmingCharacters(in: .whitespacesAndNewlines)

            // Find an unmatched Cursor state entry with matching project name
            for i in 0..<cursorStates.count where !cursorStates[i].matched {
                guard let folderPath = cursorStates[i].folderPath else { continue }

                if cursorStates[i].projectName.localizedCaseInsensitiveCompare(projectName) == .orderedSame {
                    result[window.windowId] = DocumentPathData(
                        path: folderPath,
                        source: .cursorState
                    )
                    cursorStates[i].matched = true  // Mark as used - one-to-one matching
                    DeskJigLog.debug(
                        .restorationSnapshot,
                        "Title match: windowId=\(window.windowId) project='\(projectName)' -> \(folderPath)",
                        runId: runId
                    )
                    break
                }
            }
        }

        // Strategy 2: Frame matching as fallback (one-to-one)
        for window in windows where result[window.windowId] == nil {
            for i in 0..<cursorStates.count where !cursorStates[i].matched {
                guard let cursorFrame = cursorStates[i].frame,
                      let folderPath = cursorStates[i].folderPath else {
                    continue
                }

                if framesMatch(window.frame, cursorFrame) {
                    result[window.windowId] = DocumentPathData(
                        path: folderPath,
                        source: .cursorState
                    )
                    cursorStates[i].matched = true  // Mark as used - one-to-one matching
                    DeskJigLog.debug(
                        .restorationSnapshot,
                        "Frame match: windowId=\(window.windowId) -> \(folderPath)",
                        runId: runId
                    )
                    break
                }
            }
        }

        DeskJigLog.debug(
            .restorationSnapshot,
            "Fetched \(result.count)/\(windows.count) document paths via Cursor state",
            runId: runId
        )
        return result
    }

    /// Fetch document path via AX API.
    /// Uses kAXDocument attribute which returns file:// URL to document/project.
    /// IMPORTANT: Uses one-to-one matching to prevent stacked windows from all matching the same AX window.
    private func fetchViaAX(
        for windows: [SnapshotWindow],
        bundleId: String,
        runId: String
    ) async -> [CGWindowID: DocumentPathData] {
        var result: [CGWindowID: DocumentPathData] = [:]

        // Get PID for this IDE app
        guard let app = NSWorkspace.shared.runningApplications.first(where: {
            $0.bundleIdentifier == bundleId
        }) else {
            DeskJigLog.debug(.restorationSnapshot, "IDE app not running: \(bundleId)", runId: runId)
            return result
        }

        let pid = app.processIdentifier

        // Get AX windows via the shared enumeration skeleton. Prefer direct AX window-number
        // mapping (to avoid frame ambiguity) and read the document path + title for
        // disambiguating stacked windows with identical frames.
        guard let axWindows = AXWindowService.shared.enumerateWindows(
            pid: pid,
            includeTitle: true,
            includeWindowNumber: true,
            includeDocumentPath: true
        ) else {
            DeskJigLog.debug(.restorationSnapshot, "Failed to get AX windows for \(bundleId)", runId: runId)
            return result
        }

        // Build frame + title + document data from AX windows (with matched flag for one-to-one matching)
        var axWindowData: [(frame: CGRect, title: String, docPath: String?, windowId: CGWindowID?, matched: Bool)] = []
        for axWindow in axWindows {
            guard let frame = axWindow.frame else { continue }
            axWindowData.append((
                frame: frame,
                title: axWindow.title ?? "",
                docPath: axWindow.documentPath,
                windowId: axWindow.windowNumber,
                matched: false
            ))
        }

        // Strategy 0: Exact AX window-number mapping (most reliable).
        for window in windows where result[window.windowId] == nil {
            guard let index = axWindowData.firstIndex(where: {
                !$0.matched &&
                $0.windowId == window.windowId &&
                ($0.docPath != nil && $0.docPath != "/")
            }) else {
                continue
            }

            let path = axWindowData[index].docPath!
            result[window.windowId] = DocumentPathData(
                path: path,
                source: .axDocument
            )
            axWindowData[index].matched = true
            DeskJigLog.debug(
                .restorationSnapshot,
                "AX window-number match: windowId=\(window.windowId) -> \(path)",
                runId: runId
            )
        }

        let frameMatchTolerance = (bundleId == OpenByPathBundleIdentifiers.xcode) ? CGFloat(12.0) : frameTolerance

        // Strategy 1: Match each remaining CGWindowList window to an AX window by frame (one-to-one).
        // This is more reliable than token matching for Xcode where many windows share the same project token.
        for window in windows where result[window.windowId] == nil {
            for i in 0..<axWindowData.count where !axWindowData[i].matched {
                if framesMatch(window.frame, axWindowData[i].frame, tolerance: frameMatchTolerance),
                   let path = axWindowData[i].docPath,
                   path != "/" {
                    result[window.windowId] = DocumentPathData(
                        path: path,
                        source: .axDocument
                    )
                    axWindowData[i].matched = true  // Mark as used - one-to-one matching
                    DeskJigLog.trace(
                        .restorationSnapshot,
                        "AX document path: windowId=\(window.windowId) -> \(path)",
                        runId: runId
                    )
                    break
                }
            }
        }

        // Strategy 2: Match by project token only as a fallback, and only when unambiguous.
        for window in windows where result[window.windowId] == nil {
            guard let windowTitle = window.title, !windowTitle.isEmpty else { continue }
            let windowToken = normalizedProjectToken(extractProjectToken(from: windowTitle) ?? windowTitle)
            guard !windowToken.isEmpty else { continue }

            var matchingIndices: [Int] = []
            for i in 0..<axWindowData.count where !axWindowData[i].matched {
                guard let path = axWindowData[i].docPath, path != "/" else { continue }

                let axTitleToken = normalizedProjectToken(
                    extractProjectToken(from: axWindowData[i].title).flatMap { $0.isEmpty ? nil : $0 } ?? axWindowData[i].title
                )
                let pathToken = normalizedProjectToken(projectTokenFromPath(path) ?? "")

                if windowToken == axTitleToken || windowToken == pathToken {
                    matchingIndices.append(i)
                }
            }

            guard matchingIndices.count == 1, let matchedIndex = matchingIndices.first else {
                if matchingIndices.count > 1 {
                    let candidatePaths = matchingIndices.compactMap { axWindowData[$0].docPath }.joined(separator: " | ")
                    DeskJigLog.debug(
                        .restorationSnapshot,
                        "AX project-token ambiguous: windowId=\(window.windowId) token='\(windowToken)' candidates=\(candidatePaths)",
                        runId: runId
                    )
                }
                continue
            }

            guard let path = axWindowData[matchedIndex].docPath else { continue }
            result[window.windowId] = DocumentPathData(
                path: path,
                source: .axDocument
            )
            axWindowData[matchedIndex].matched = true
            DeskJigLog.debug(
                .restorationSnapshot,
                "AX project-token match: windowId=\(window.windowId) token='\(windowToken)' -> \(path)",
                runId: runId
            )
        }

        DeskJigLog.debug(
            .restorationSnapshot,
            "Fetched \(result.count)/\(windows.count) document paths via AX for \(bundleId)",
            runId: runId
        )
        return result
    }

    /// Fetch document paths via process tree cwd lookup (lsof-based fallback).
    /// Best-effort: match candidate cwd paths to window titles by project token.
    private func fetchViaProcessTreeLsof(
        for windows: [SnapshotWindow],
        bundleId: String,
        runId: String
    ) async -> [CGWindowID: DocumentPathData] {
        guard !windows.isEmpty else { return [:] }

        guard let app = NSWorkspace.shared.runningApplications.first(where: {
            $0.bundleIdentifier == bundleId
        }) else {
            DeskJigLog.debug(.restorationSnapshot, "IDE app not running for process fallback: \(bundleId)", runId: runId)
            return [:]
        }

        let pids = collectProcessTreePids(rootPid: app.processIdentifier, runId: runId)
        let candidatePaths = collectCandidatePaths(from: pids, runId: runId)

        guard !candidatePaths.isEmpty else {
            DeskJigLog.debug(.restorationSnapshot, "No candidate cwd paths found via process tree for \(bundleId)", runId: runId)
            return [:]
        }

        let matched = matchProcessPathsToWindows(
            windows: windows,
            candidatePaths: candidatePaths,
            runId: runId
        )

        DeskJigLog.debug(
            .restorationSnapshot,
            "Fetched \(matched.count)/\(windows.count) document paths via process tree for \(bundleId)",
            runId: runId
        )
        return matched
    }

    private func collectProcessTreePids(rootPid: pid_t, runId: String) -> [pid_t] {
        var seen = Set<pid_t>()
        var queue: [pid_t] = [rootPid]
        var index = 0
        let maxPids = 64

        while index < queue.count && seen.count < maxPids {
            let pid = queue[index]
            index += 1
            guard !seen.contains(pid) else { continue }
            seen.insert(pid)

            let output = runCommand("/usr/bin/pgrep", arguments: ["-P", "\(pid)"])
            let children = parsePids(from: output)
            for child in children where !seen.contains(child) {
                queue.append(child)
            }
        }

        if seen.count >= maxPids {
            DeskJigLog.debug(.restorationSnapshot, "Process tree pid cap reached (\(maxPids)) for pid \(rootPid)", runId: runId)
        }

        return Array(seen)
    }

    private func collectCandidatePaths(from pids: [pid_t], runId: String) -> [String] {
        var paths = Set<String>()
        for pid in pids {
            guard let path = fetchCwdForPid(pid) else { continue }
            guard isLikelyUserPath(path) else { continue }
            paths.insert(normalizePath(path))
        }
        DeskJigLog.debug(
            .restorationSnapshot,
            "Process tree candidate cwd paths: \(paths.sorted().joined(separator: " | "))",
            runId: runId
        )
        return Array(paths)
    }

    private func matchProcessPathsToWindows(
        windows: [SnapshotWindow],
        candidatePaths: [String],
        runId: String
    ) -> [CGWindowID: DocumentPathData] {
        var result: [CGWindowID: DocumentPathData] = [:]

        let normalizedCandidates = candidatePaths.map(normalizePath)
        let candidatesByToken = Dictionary(grouping: normalizedCandidates) { path in
            URL(fileURLWithPath: path).lastPathComponent.lowercased()
        }

        for window in windows {
            guard let title = window.title, let token = extractProjectToken(from: title) else { continue }
            let normalizedToken = token.lowercased()
            guard let candidates = candidatesByToken[normalizedToken], !candidates.isEmpty else { continue }
            let selected = candidates.sorted { $0.count < $1.count }.first ?? candidates[0]

            result[window.windowId] = DocumentPathData(
                path: selected,
                source: .processTreeLsof
            )
            DeskJigLog.debug(
                .restorationSnapshot,
                "Process cwd match: windowId=\(window.windowId) token='\(token)' -> \(selected)",
                runId: runId
            )
        }

        if result.isEmpty, windows.count == 1, let onlyPath = normalizedCandidates.first {
            let window = windows[0]
            result[window.windowId] = DocumentPathData(path: onlyPath, source: .processTreeLsof)
            DeskJigLog.debug(
                .restorationSnapshot,
                "Process cwd single-window fallback: windowId=\(window.windowId) -> \(onlyPath)",
                runId: runId
            )
        }

        return result
    }

    private func extractProjectToken(from title: String) -> String? {
        let separators = [" \u{2014} ", " - ", " – "]
        for separator in separators {
            if let range = title.range(of: separator, options: .backwards) {
                let suffix = title[range.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
                if !suffix.isEmpty { return suffix }
            }
        }
        return nil
    }

    private func projectTokenFromPath(_ path: String) -> String? {
        let normalized = normalizePath(path)
        let last = URL(fileURLWithPath: normalized).lastPathComponent
        return last.isEmpty ? nil : last
    }

    private func normalizedProjectToken(_ token: String) -> String {
        var value = token.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        for suffix in [".xcworkspace", ".xcodeproj", ".code-workspace"] {
            if value.hasSuffix(suffix) {
                value = String(value.dropLast(suffix.count))
                break
            }
        }
        return value
    }

    private func fetchCwdForPid(_ pid: pid_t) -> String? {
        let output = runCommand("/usr/sbin/lsof", arguments: ["-a", "-d", "cwd", "-p", "\(pid)", "-Fn"])
        for line in output.split(separator: "\n") {
            if line.hasPrefix("n") {
                let path = String(line.dropFirst())
                if path == "/" || path.hasPrefix("/dev") { continue }
                return path
            }
        }
        return nil
    }

    private func runCommand(_ launchPath: String, arguments: [String]) -> String {
        ProcessRunner.run(launchPath, arguments: arguments)
    }

    private func parsePids(from output: String) -> [pid_t] {
        output
            .split(separator: "\n")
            .compactMap { Int32($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
    }

    private func normalizePath(_ path: String) -> String {
        PathNormalization.standardize(path)
    }

    private func isLikelyUserPath(_ path: String) -> Bool {
        guard !path.isEmpty else { return false }
        let excludedPrefixes = [
            "/System",
            "/Library",
            "/Applications",
            "/usr",
            "/bin",
            "/sbin",
            "/private",
            "/dev",
            "/var"
        ]
        return !excludedPrefixes.contains { path.hasPrefix($0) }
    }

    /// Fetch fresh AX titles for IDE windows.
    /// Snapshot titles can be stale if the user switched tabs/files between capture and restoration.
    /// IMPORTANT: Uses one-to-one matching to prevent stacked windows from all matching the same AX window.
    private func fetchFreshAxTitles(
        for windows: [SnapshotWindow],
        bundleId: String,
        runId: String
    ) -> [CGWindowID: String] {
        var result: [CGWindowID: String] = [:]

        // Get PID for this IDE app
        guard let app = NSWorkspace.shared.runningApplications.first(where: {
            $0.bundleIdentifier == bundleId
        }) else {
            DeskJigLog.debug(
                .restorationSnapshot,
                "IDE app not running, cannot fetch fresh AX titles: \(bundleId)",
                runId: runId
            )
            return result
        }

        let pid = app.processIdentifier

        // Get AX windows via the shared enumeration skeleton.
        guard let axWindows = AXWindowService.shared.enumerateWindows(pid: pid, includeTitle: true) else {
            DeskJigLog.debug(.restorationSnapshot, "Failed to get AX windows for \(bundleId)", runId: runId)
            return result
        }

        // Build frame + title data from AX windows (with matched flag for one-to-one matching)
        var axWindowData: [(frame: CGRect, title: String, matched: Bool)] = []
        for axWindow in axWindows {
            guard let frame = axWindow.frame else { continue }
            axWindowData.append((frame: frame, title: axWindow.title ?? "", matched: false))
        }

        // STRATEGY 1: Match by title similarity (project name suffix)
        // IDE titles end with " — ProjectName", match CGWindowList titles to AX titles with same project
        let emDashSeparator = " \u{2014} "  // em-dash with spaces
        for window in windows where result[window.windowId] == nil {
            guard let cgTitle = window.title,
                  let cgRange = cgTitle.range(of: emDashSeparator, options: .backwards) else { continue }
            let cgProjectName = String(cgTitle[cgRange.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)

            for i in 0..<axWindowData.count where !axWindowData[i].matched && !axWindowData[i].title.isEmpty {
                let axTitle = axWindowData[i].title
                guard let axRange = axTitle.range(of: emDashSeparator, options: .backwards) else { continue }
                let axProjectName = String(axTitle[axRange.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)

                if cgProjectName.localizedCaseInsensitiveCompare(axProjectName) == .orderedSame {
                    result[window.windowId] = axTitle
                    axWindowData[i].matched = true
                    DeskJigLog.debug(
                        .restorationSnapshot,
                        "Fresh AX title via project match: windowId=\(window.windowId) project='\(cgProjectName)' title='\(axTitle.prefix(60))'",
                        runId: runId
                    )
                    break
                }
            }
        }

        // STRATEGY 2: Frame matching as fallback (one-to-one)
        for window in windows where result[window.windowId] == nil {
            for i in 0..<axWindowData.count where !axWindowData[i].matched && !axWindowData[i].title.isEmpty {
                if framesMatch(window.frame, axWindowData[i].frame) {
                    result[window.windowId] = axWindowData[i].title
                    axWindowData[i].matched = true
                    DeskJigLog.debug(
                        .restorationSnapshot,
                        "Fresh AX title via frame match: windowId=\(window.windowId) title='\(axWindowData[i].title.prefix(60))'",
                        runId: runId
                    )
                    break
                }
            }
        }

        DeskJigLog.debug(
            .restorationSnapshot,
            "Fetched \(result.count)/\(windows.count) fresh AX titles for \(bundleId)",
            runId: runId
        )
        return result
    }

    /// Check if two frames match within tolerance.
    private func framesMatch(_ frame1: CGRect, _ frame2: CGRect, tolerance: CGFloat? = nil) -> Bool {
        frame1.approximatelyEquals(frame2, tolerance: tolerance ?? frameTolerance)
    }
}

// MARK: - SystemSnapshot Extension for IDE

extension SystemSnapshot {
    /// Returns true if any IDE windows are still pending supplementation.
    public var hasPendingIDESupplementation: Bool {
        windows.contains { $0.ideSupplementationStatus == .pending }
    }

    /// Returns IDE windows that have completed supplementation.
    public var supplementedIDEWindows: [SnapshotWindow] {
        windows.filter { $0.ideSupplementationStatus == .completed }
    }

    /// Find an IDE window by document/project path.
    public func findIDEWindow(withDocumentPath path: String, bundleId: String? = nil) -> SnapshotWindow? {
        let normalizedPath = normalizePath(path)
        return windows.first { window in
            // Check bundle ID if specified
            if let targetBundleId = bundleId {
                guard window.bundleId == targetBundleId else { return false }
            } else {
                guard let windowBundleId = window.bundleId, BundleRegistry.isIDE(windowBundleId) else { return false }
            }

            // Check supplemented IDE document path first
            if let idePath = window.ideDocumentPath {
                return normalizePath(idePath) == normalizedPath
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
