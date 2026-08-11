//  EnhancedSnapshot.swift
//  DeskJigShared

import Foundation
import CoreGraphics

// MARK: - Enhanced Snapshot

/// Extended snapshot with path-based indexing for efficient window matching.
///
/// `EnhancedSnapshot` wraps an `SystemSnapshot` and adds pre-computed indexes
/// for fast lookups by document path, working directory, and Chrome profile.
/// This enables efficient matching during workspace restoration.
///
/// ## Overview
///
/// During workspace restoration, each saved window needs to be matched to an
/// existing system window. Path-based matching (matching a terminal to its
/// working directory, or an IDE to its project path) is the highest quality
/// match type. `EnhancedSnapshot` pre-computes these indexes at capture time
/// for efficient O(1) lookups.
///
/// ## Example
///
/// ```swift
/// // Capture and enhance a snapshot
/// let baseSnapshot = await SystemSnapshotCapture.capture(runId: "restore_123")
/// let snapshot = EnhancedSnapshot.from(baseSnapshot)
///
/// // Find windows by path
/// if let windows = snapshot.windowsByDocumentPath["/Users/me/project/main.swift"] {
///     print("Found \(windows.count) windows with that document")
/// }
///
/// // Find best match for a workspace window
/// let result = snapshot.findMatch(for: workspaceWindow, excluding: claimedWindows)
/// ```
///
/// ## See Also
/// - ``SystemSnapshot``
/// - ``MatchResult``
/// - ``RestorationPlanBuilder``
public struct EnhancedSnapshot: Sendable {

    // MARK: - Properties

    /// The underlying system snapshot
    public let base: SystemSnapshot

    /// Windows indexed by normalized document path (lowercased, expanded)
    public let windowsByDocumentPath: [String: [SnapshotWindow]]

    /// Windows indexed by parsed working directory from terminal titles
    public let windowsByWorkingDir: [String: [SnapshotWindow]]

    /// Windows indexed by Chrome profile directory
    public let windowsByChromeProfile: [String: [SnapshotWindow]]

    /// Windows indexed by bundle ID
    public let windowsByBundleId: [String: [SnapshotWindow]]

    /// Windows indexed by legacy managed title (exact match on the persisted title pattern)
    /// Multiple windows can share a title across different apps, so store lists.
    public let windowsByBentoTitle: [String: [SnapshotWindow]]

    /// Time taken to build indexes in milliseconds
    public let indexBuildDurationMs: Int

    // MARK: - Initialization

    /// Creates an enhanced snapshot from a base snapshot.
    ///
    /// Builds all path-based indexes for efficient matching.
    ///
    /// - Parameter base: The base system snapshot
    /// - Returns: Enhanced snapshot with pre-computed indexes
    ///
    /// ## Example
    ///
    /// ```swift
    /// let baseSnapshot = await SystemSnapshotCapture.capture(runId: "restore_123")
    /// let snapshot = EnhancedSnapshot.from(baseSnapshot)
    /// ```
    public static func from(_ base: SystemSnapshot) -> EnhancedSnapshot {
        let startTime = Date()

        var byDocPath: [String: [SnapshotWindow]] = [:]
        var byWorkingDir: [String: [SnapshotWindow]] = [:]
        var byChromeProfile: [String: [SnapshotWindow]] = [:]
        var byBundleId: [String: [SnapshotWindow]] = [:]
        var byManagedTitle: [String: [SnapshotWindow]] = [:]

        for window in base.windows {
            // Index by bundle ID
            if let bundleId = window.bundleId {
                byBundleId[bundleId, default: []].append(window)
            }

            // Index by document/open paths (AX + IDE supplementation).
            // Xcode often reports .xcworkspace/.xcodeproj paths, so we also index the parent directory.
            for normalizedPath in Self.documentPaths(for: window) {
                byDocPath[normalizedPath, default: []].append(window)
            }

            // Index by working directory (parsed from terminal titles)
            if let workingDir = Self.parseWorkingDirectory(from: window) {
                let normalizedDir = Self.normalizePath(workingDir)
                byWorkingDir[normalizedDir, default: []].append(window)
            }

            // Index by Chrome profile
            if let profileName = window.chromeProfileName {
                byChromeProfile[profileName, default: []].append(window)
            }

            // Index by the persisted managed-title pattern.
            if let title = window.title,
               title.hasPrefix("\(BundleIdentity.terminalTitleTokenPrefix):") {
                byManagedTitle[title, default: []].append(window)
            }
        }

        // Also index Chrome captures by profile (with base-name fallback)
        for capture in base.chromeCaptures {
            let profileDir = capture.profileDirectory
            let targetProfile = capture.profileName
            let targetBase = targetProfile.components(separatedBy: " (").first ?? targetProfile

            // Find the window for this capture (exact match first, then base-name)
            if let matchingWindow = base.windows.first(where: { window in
                guard window.bundleId == "com.google.Chrome",
                      let windowProfile = window.chromeProfileName else { return false }

                // Exact match
                if windowProfile == targetProfile { return true }

                // Base-name fallback: "Andrew" matches "Andrew (mscontrol.ai)"
                let windowBase = windowProfile.components(separatedBy: " (").first ?? windowProfile
                return windowBase.localizedCaseInsensitiveCompare(targetBase) == .orderedSame
            }) {
                byChromeProfile[profileDir, default: []].append(matchingWindow)
            }
        }

        let durationMs = Int(Date().timeIntervalSince(startTime) * 1000)

        return EnhancedSnapshot(
            base: base,
            windowsByDocumentPath: byDocPath,
            windowsByWorkingDir: byWorkingDir,
            windowsByChromeProfile: byChromeProfile,
            windowsByBundleId: byBundleId,
            windowsByBentoTitle: byManagedTitle,
            indexBuildDurationMs: durationMs
        )
    }

    // MARK: - Matching

    /// Finds the best match for a workspace window.
    ///
    /// Attempts matching in priority order:
    /// 1. Document path (for IDEs, editors)
    /// 2. Working directory (for terminals)
    /// 3. Chrome profile (for Chrome windows)
    /// 4. Exact title match
    /// 5. Frame match with tolerance
    ///
    /// - Parameters:
    ///   - workspaceWindow: The saved window configuration to match
    ///   - claimed: Set of window IDs already claimed by other tasks
    ///   - config: Matching configuration options
    ///
    /// - Returns: A `MatchResult` with the best match found
    ///
    /// ## Example
    ///
    /// ```swift
    /// var claimedWindows: Set<CGWindowID> = []
    ///
    /// for workspaceWindow in workspace.windows {
    ///     let result = snapshot.findMatch(
    ///         for: workspaceWindow,
    ///         excluding: claimedWindows
    ///     )
    ///
    ///     if let window = result.window {
    ///         claimedWindows.insert(window.windowId)
    ///     }
    /// }
    /// ```
    public func findMatch(
        for workspaceWindow: WorkspaceWindow,
        excluding claimed: Set<CGWindowID>,
        config: MatchConfiguration = .default
    ) -> MatchResult {
        let startTime = Date()
        let bundleId = workspaceWindow.bundleIdentifier
        let isTerminal = BundleRegistry.isTerminal(bundleId)

        // 0. For terminals: Try exact managed-title match first (highest priority)
        // This is the ONLY way to match terminal windows during restoration
        if isTerminal {
            let expectedTitle = workspaceWindow.windowTitle

            // If the workspace has a managed title, we MUST match it exactly.
            if expectedTitle.hasPrefix("\(BundleIdentity.terminalTitleTokenPrefix):") {
                if let candidates = windowsByBentoTitle[expectedTitle] {
                    let sameAppCandidates = candidates.filter {
                        $0.bundleId == bundleId && !claimed.contains($0.windowId)
                    }
                    if let match = sameAppCandidates.sorted(by: {
                        ($0.zOrderIndex ?? Int.max) < ($1.zOrderIndex ?? Int.max)
                    }).first {
                        return MatchResult(
                            window: match,
                            confidence: 1.0,
                            method: .bentoTitle(expectedTitle),
                            searchDurationMs: Int(Date().timeIntervalSince(startTime) * 1000)
                        )
                    }
                }

                // Managed title expected but not found - MUST launch new window.
                // Do NOT fall back to loose matching (workingDirectory, title contains, etc.)
                // This ensures we only position windows we created with the correct title
                return MatchResult.noMatch(
                    searchDurationMs: Int(Date().timeIntervalSince(startTime) * 1000)
                )
            }
        }

        // 1. Try path-based matching (for non-terminal apps or terminals without managed titles)
        if config.enablePathMatching {
            // Check openPath for terminals/IDEs
            if let openPath = workspaceWindow.openPath {
                let normalizedPath = Self.normalizePath(openPath)

                if isTerminal {
                    // For terminals without a managed title: Try working directory match
                    if let candidates = windowsByWorkingDir[normalizedPath] {
                        // Filter to only windows from the same app
                        let sameAppCandidates = candidates.filter { $0.bundleId == bundleId }
                        if let match = sameAppCandidates.first(where: { !claimed.contains($0.windowId) }) {
                            return MatchResult(
                                window: match,
                                confidence: 0.95,
                                method: .workingDirectory(normalizedPath),
                                searchDurationMs: Int(Date().timeIntervalSince(startTime) * 1000)
                            )
                        }
                    }
                } else {
                    // Try document path match for non-terminals (IDEs, editors)
                    if let candidates = windowsByDocumentPath[normalizedPath] {
                        // Filter to only windows from the same app
                        let sameAppCandidates = candidates.filter { $0.bundleId == bundleId }
                        if let match = sameAppCandidates.first(where: { !claimed.contains($0.windowId) }) {
                            return MatchResult(
                                window: match,
                                confidence: 0.95,
                                method: .documentPath(normalizedPath),
                                searchDurationMs: Int(Date().timeIntervalSince(startTime) * 1000)
                            )
                        }
                    }

                    // For IDE apps (Xcode, Cursor, VSCode), the document path is
                    // the authoritative match. If it failed, don't fall through to title
                    // matching — quick-switch rewrites openPath but not windowTitle, so
                    // the saved title matches the WRONG project's window.
                    // Returning noMatch causes openNewWithPath, which either focuses
                    // an existing window for the target project or launches it.
                    if BundleRegistry.isIDE(bundleId) {
                        let bundleCandidates = (windowsByBundleId[bundleId] ?? [])
                            .filter { !claimed.contains($0.windowId) }

                        // Codex is effectively single-instance: the CLI switches the
                        // project inside the existing app, so reusing the one live
                        // window is safer than forcing an open-by-path relaunch.
                        if bundleId == BundleRegistry.codex, bundleCandidates.count == 1 {
                            DeskJigLog.info(.restorationPlanner, "Codex single-instance fallback match: \(bundleId) → wid:\(bundleCandidates[0].windowId) '\(bundleCandidates[0].title ?? "?")'")
                            return MatchResult(
                                window: bundleCandidates[0],
                                confidence: 0.65,
                                method: .bundleIdOnly,
                                searchDurationMs: Int(Date().timeIntervalSince(startTime) * 1000)
                            )
                        }

                        // Try openPath-basename matching: use the target project directory name
                        // to find the correct IDE window by title. This is safe because openPath
                        // is rewritten by quick-switch (unlike saved windowTitle which is stale).
                        let pathBasename = URL(fileURLWithPath: normalizedPath).lastPathComponent.lowercased()
                        if !pathBasename.isEmpty {
                            let titleMatches = bundleCandidates.filter { window in
                                guard !claimed.contains(window.windowId),
                                      let title = window.title?.lowercased() else { return false }
                                guard title.contains(pathBasename) else { return false }
                                // If the candidate has a document path, verify it's under the expected
                                // directory. This prevents matching the wrong project when names overlap
                                // (e.g., a DeskJig worktree vs the main DeskJig checkout).
                                if let docPath = window.ideDocumentPath ?? window.documentPath {
                                    let normalizedDoc = Self.normalizePath(docPath)
                                    if normalizedDoc != normalizedPath
                                        && !normalizedDoc.hasPrefix("\(normalizedPath)/") {
                                        return false
                                    }
                                }
                                return true
                            }
                            if titleMatches.count == 1 {
                                DeskJigLog.info(.restorationPlanner, "IDE openPath-basename match: \(bundleId) basename=\(pathBasename) → wid:\(titleMatches[0].windowId) '\(titleMatches[0].title ?? "?")'")
                                return MatchResult(
                                    window: titleMatches[0],
                                    confidence: 0.7,
                                    method: .titleContains(pathBasename),
                                    searchDurationMs: Int(Date().timeIntervalSince(startTime) * 1000)
                                )
                            }
                            DeskJigLog.info(.restorationPlanner, "IDE openPath-basename no unique match: \(bundleId) basename=\(pathBasename) titleMatches=\(titleMatches.count)")
                        }

                        DeskJigLog.info(.restorationPlanner, "IDE document-path miss: \(bundleId) openPath=\(normalizedPath) candidates=\(bundleCandidates.count)")
                        DeskJigLog.debug(.restorationTrace, "IDE path match failed, skipping title fallback", fields: [
                            "bundleId": bundleId,
                            "openPath": normalizedPath,
                            "candidateCount": "\(bundleCandidates.count)"
                        ], runId: "snapshot")
                        return MatchResult.noMatch(
                            searchDurationMs: Int(Date().timeIntervalSince(startTime) * 1000)
                        )
                    }
                }
            }
        }

        // 2. Try Chrome profile matching
        if config.enableProfileMatching {
            if let chromeState = workspaceWindow.chromeState {
                let profileDir = chromeState.profileDirectory
                let targetProfile = chromeState.profileDisplayName.isEmpty ? profileDir : chromeState.profileDisplayName

                // Phase 1: Try exact profile directory match
                if let candidates = windowsByChromeProfile[profileDir] {
                    if let match = candidates.first(where: { !claimed.contains($0.windowId) }) {
                        return MatchResult(
                            window: match,
                            confidence: 0.9,
                            method: .chromeProfile(profileDir),
                            searchDurationMs: Int(Date().timeIntervalSince(startTime) * 1000)
                        )
                    }
                }

                // Phase 2: Base-name fallback (strip domain suffix)
                // "Andrew" matches "Andrew (mscontrol.ai)"
                let targetBase = targetProfile.components(separatedBy: " (").first ?? targetProfile
                for (indexedProfile, candidates) in windowsByChromeProfile {
                    let indexedBase = indexedProfile.components(separatedBy: " (").first ?? indexedProfile
                    if indexedBase.localizedCaseInsensitiveCompare(targetBase) == .orderedSame {
                        if let match = candidates.first(where: { !claimed.contains($0.windowId) }) {
                            return MatchResult(
                                window: match,
                                confidence: 0.85,
                                method: .chromeProfile(indexedProfile),
                                searchDurationMs: Int(Date().timeIntervalSince(startTime) * 1000)
                            )
                        }
                    }
                }
            }
        }

        // 3. Try title matching
        if let candidates = windowsByBundleId[bundleId] {
            let unclaimedCandidates = candidates.filter { !claimed.contains($0.windowId) }

            // Exact title match
            let title = workspaceWindow.windowTitle
            if let match = unclaimedCandidates.first(where: { $0.title == title }) {
                return MatchResult(
                    window: match,
                    confidence: 0.8,
                    method: .titleExact,
                    searchDurationMs: Int(Date().timeIntervalSince(startTime) * 1000)
                )
            }

            // Partial title match (contains)
            if let match = unclaimedCandidates.first(where: { $0.title?.contains(title) == true }) {
                return MatchResult(
                    window: match,
                    confidence: 0.6,
                    method: .titleContains(title),
                    searchDurationMs: Int(Date().timeIntervalSince(startTime) * 1000)
                )
            }

            // 4. Frame matching is skipped here because WorkspaceWindow only has relativeFrame
            // Frame matching requires screen info to convert relative to absolute coordinates
            // This is handled in RestorationPlanBuilder which has access to current screens

            // DO NOT fall back to bundle-ID-only matching - it's too unreliable
            // Log failure with details about what was tried
            DeskJigLog.debug(.restorationTrace, "FAILED: No window match found", fields: [
                "bundleId": bundleId,
                "tried": "path,profile,title",
                "candidateCount": "\(unclaimedCandidates.count)",
                "error": "NO_CONFIDENT_MATCH"
            ], runId: "snapshot")
        }

        // No match found
        return MatchResult.noMatch(
            searchDurationMs: Int(Date().timeIntervalSince(startTime) * 1000)
        )
    }

    /// Finds a bundle ID or frame-based match for generic apps.
    ///
    /// This skips path/title matching entirely and only attempts:
    /// 1. Bundle ID match when there is exactly one candidate
    /// 2. Frame match within tolerance for disambiguation
    ///
    /// - Parameters:
    ///   - workspaceWindow: The saved window configuration to match
    ///   - claimed: Set of window IDs already claimed by other tasks
    ///   - targetFrame: Absolute target frame for frame matching
    ///   - config: Matching configuration options
    /// - Returns: A `MatchResult` with the best match found
    public func findGenericMatch(
        for workspaceWindow: WorkspaceWindow,
        excluding claimed: Set<CGWindowID>,
        targetFrame: CGRect,
        config: MatchConfiguration = .default
    ) -> MatchResult {
        let startTime = Date()
        let bundleId = workspaceWindow.bundleIdentifier
        let durationMs = { Int(Date().timeIntervalSince(startTime) * 1000) }

        guard let candidates = windowsByBundleId[bundleId] else {
            return MatchResult.noMatch(searchDurationMs: durationMs())
        }

        let unclaimedCandidates = candidates.filter { !claimed.contains($0.windowId) }
        guard !unclaimedCandidates.isEmpty else {
            return MatchResult.noMatch(searchDurationMs: durationMs())
        }

        if BundleRegistry.isAdobeCreativeApp(bundleId) {
            return findAdobeCreativeMatch(
                bundleId: bundleId,
                candidates: unclaimedCandidates,
                targetFrame: targetFrame,
                config: config,
                searchDurationMs: durationMs
            )
        }

        if unclaimedCandidates.count == 1 {
            return MatchResult(
                window: unclaimedCandidates[0],
                confidence: 0.45,
                method: .bundleIdOnly,
                searchDurationMs: durationMs()
            )
        }

        let hasTargetFrame = targetFrame.width > 0 && targetFrame.height > 0
        if hasTargetFrame {
            let frameMatches = unclaimedCandidates.filter {
                $0.frameMatches(targetFrame, tolerance: config.frameTolerance)
            }

            if frameMatches.count == 1, let match = frameMatches.first {
                return MatchResult(
                    window: match,
                    confidence: 0.6,
                    method: .frameWithTolerance(tolerance: config.frameTolerance),
                    searchDurationMs: durationMs()
                )
            }

            if frameMatches.count > 1 {
                let selected = frameMatches.sorted {
                    ($0.zOrderIndex ?? Int.max) < ($1.zOrderIndex ?? Int.max)
                }.first

                if let selected {
                    DeskJigLog.debug(.restorationTrace, "Multiple frame matches - using frontmost", fields: [
                        "bundleId": bundleId,
                        "candidateCount": "\(frameMatches.count)",
                        "selectedWindowId": "\(selected.windowId)"
                    ], runId: "snapshot")

                    return MatchResult(
                        window: selected,
                        confidence: 0.55,
                        method: .frameWithTolerance(tolerance: config.frameTolerance),
                        searchDurationMs: durationMs()
                    )
                }
            }

            if frameMatches.isEmpty {
                let sortedByDistance = unclaimedCandidates.sorted { lhs, rhs in
                    let lhsDistance = abs(lhs.frame.origin.x - targetFrame.origin.x) +
                    abs(lhs.frame.origin.y - targetFrame.origin.y) +
                    abs(lhs.frame.width - targetFrame.width) +
                    abs(lhs.frame.height - targetFrame.height)
                    let rhsDistance = abs(rhs.frame.origin.x - targetFrame.origin.x) +
                    abs(rhs.frame.origin.y - targetFrame.origin.y) +
                    abs(rhs.frame.width - targetFrame.width) +
                    abs(rhs.frame.height - targetFrame.height)
                    if lhsDistance != rhsDistance {
                        return lhsDistance < rhsDistance
                    }
                    return (lhs.zOrderIndex ?? Int.max) < (rhs.zOrderIndex ?? Int.max)
                }

                if let selected = sortedByDistance.first {
                    let distance = abs(selected.frame.origin.x - targetFrame.origin.x) +
                    abs(selected.frame.origin.y - targetFrame.origin.y) +
                    abs(selected.frame.width - targetFrame.width) +
                    abs(selected.frame.height - targetFrame.height)

                    DeskJigLog.debug(.restorationTrace, "No frame match within tolerance - using closest frame", fields: [
                        "bundleId": bundleId,
                        "candidateCount": "\(unclaimedCandidates.count)",
                        "selectedWindowId": "\(selected.windowId)",
                        "distance": "\(Int(distance))"
                    ], runId: "snapshot")

                    return MatchResult(
                        window: selected,
                        confidence: 0.4,
                        method: .frameWithTolerance(tolerance: config.frameTolerance),
                        searchDurationMs: durationMs()
                    )
                }
            }
        }

        DeskJigLog.debug(.restorationTrace, "FAILED: No window match found (bundle/frame)", fields: [
            "bundleId": bundleId,
            "candidateCount": "\(unclaimedCandidates.count)",
            "targetFrame": "\(Int(targetFrame.origin.x)),\(Int(targetFrame.origin.y)) \(Int(targetFrame.width))x\(Int(targetFrame.height))",
            "error": hasTargetFrame ? "NO_BUNDLE_OR_FRAME_MATCH" : "NO_BUNDLE_MATCH"
        ], runId: "snapshot")

        return MatchResult.noMatch(searchDurationMs: durationMs())
    }

    private func findAdobeCreativeMatch(
        bundleId: String,
        candidates: [SnapshotWindow],
        targetFrame: CGRect,
        config: MatchConfiguration,
        searchDurationMs: () -> Int
    ) -> MatchResult {
        guard !candidates.isEmpty else {
            return MatchResult.noMatch(searchDurationMs: searchDurationMs())
        }

        let hasTargetFrame = targetFrame.width > 0 && targetFrame.height > 0
        if !hasTargetFrame {
            if candidates.count == 1 {
                return MatchResult(
                    window: candidates[0],
                    confidence: 0.35,
                    method: .bundleIdOnly,
                    searchDurationMs: searchDurationMs()
                )
            }
            return MatchResult.noMatch(searchDurationMs: searchDurationMs())
        }

        let minimumRatio: CGFloat = 0.72
        let targetDisplayIndex = displayIndex(for: targetFrame)

        let sizeEligible = candidates.filter { candidate in
            let widthRatio = candidate.frame.width / max(targetFrame.width, 1)
            let heightRatio = candidate.frame.height / max(targetFrame.height, 1)
            return widthRatio >= minimumRatio && heightRatio >= minimumRatio
        }

        guard !sizeEligible.isEmpty else {
            DeskJigLog.debug(.restorationTrace, "Adobe match rejected all candidates as transient/small", fields: [
                "bundleId": bundleId,
                "candidateCount": "\(candidates.count)",
                "targetFrame": "\(Int(targetFrame.origin.x)),\(Int(targetFrame.origin.y)) \(Int(targetFrame.width))x\(Int(targetFrame.height))"
            ], runId: "snapshot")
            return MatchResult.noMatch(searchDurationMs: searchDurationMs())
        }

        let frameMatches = sizeEligible.filter {
            $0.frameMatches(targetFrame, tolerance: config.frameTolerance)
        }
        if let selected = frameMatches.sorted(by: adobeCandidateComparator(targetFrame: targetFrame, targetDisplayIndex: targetDisplayIndex)).first {
            return MatchResult(
                window: selected,
                confidence: 0.75,
                method: .frameWithTolerance(tolerance: config.frameTolerance),
                searchDurationMs: searchDurationMs()
            )
        }

        let sortedCandidates = sizeEligible.sorted(
            by: adobeCandidateComparator(targetFrame: targetFrame, targetDisplayIndex: targetDisplayIndex)
        )
        guard let selected = sortedCandidates.first else {
            return MatchResult.noMatch(searchDurationMs: searchDurationMs())
        }

        return MatchResult(
            window: selected,
            confidence: 0.55,
            method: .frameWithTolerance(tolerance: config.frameTolerance),
            searchDurationMs: searchDurationMs()
        )
    }

    private func adobeCandidateComparator(
        targetFrame: CGRect,
        targetDisplayIndex: Int?
    ) -> (SnapshotWindow, SnapshotWindow) -> Bool {
        { lhs, rhs in
            let leftScore = adobeCandidateScore(lhs, targetFrame: targetFrame, targetDisplayIndex: targetDisplayIndex)
            let rightScore = adobeCandidateScore(rhs, targetFrame: targetFrame, targetDisplayIndex: targetDisplayIndex)
            if leftScore != rightScore {
                return leftScore < rightScore
            }
            return (lhs.zOrderIndex ?? Int.max) < (rhs.zOrderIndex ?? Int.max)
        }
    }

    private func adobeCandidateScore(
        _ candidate: SnapshotWindow,
        targetFrame: CGRect,
        targetDisplayIndex: Int?
    ) -> CGFloat {
        var score = abs(candidate.frame.origin.x - targetFrame.origin.x)
            + abs(candidate.frame.origin.y - targetFrame.origin.y)
            + abs(candidate.frame.width - targetFrame.width)
            + abs(candidate.frame.height - targetFrame.height)

        if let targetDisplayIndex, candidate.displayIndex != targetDisplayIndex {
            score += max(targetFrame.width, targetFrame.height) * 4
        }

        let trimmedTitle = candidate.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if trimmedTitle.isEmpty {
            score += max(targetFrame.width, targetFrame.height) * 0.25
        }

        return score
    }

    private func displayIndex(for targetFrame: CGRect) -> Int? {
        let targetCenter = CGPoint(x: targetFrame.midX, y: targetFrame.midY)
        if let containing = displays.first(where: { $0.visibleFrame.contains(targetCenter) || $0.frame.contains(targetCenter) }) {
            return containing.index
        }

        let bestIntersecting = displays.max { lhs, rhs in
            intersectionArea(lhs.visibleFrame, targetFrame) < intersectionArea(rhs.visibleFrame, targetFrame)
        }
        return bestIntersecting?.index
    }

    private func intersectionArea(_ lhs: CGRect, _ rhs: CGRect) -> CGFloat {
        let intersection = lhs.intersection(rhs)
        guard !intersection.isNull, !intersection.isEmpty else { return 0 }
        return intersection.width * intersection.height
    }

    // MARK: - Convenience Accessors

    /// All windows in the snapshot.
    public var windows: [SnapshotWindow] {
        base.windows
    }

    /// All displays in the snapshot.
    public var displays: [DisplayInfo] {
        base.displays
    }

    /// Chrome captures.
    public var chromeCaptures: [ChromeWindowCapture] {
        base.chromeCaptures
    }

    /// Total number of windows.
    public var windowCount: Int {
        base.windows.count
    }

    /// Capture timestamp.
    public var captureTime: Date {
        base.captureTime
    }

    /// Total capture duration including index building.
    public var totalDurationMs: Int {
        base.captureDurationMs + indexBuildDurationMs
    }

    // MARK: - Lookup Methods

    /// Gets windows for a specific bundle ID.
    ///
    /// - Parameter bundleId: The bundle identifier to look up
    /// - Returns: Array of windows for that bundle ID
    public func windows(forBundleId bundleId: String) -> [SnapshotWindow] {
        windowsByBundleId[bundleId] ?? []
    }

    /// Gets windows on a specific display.
    ///
    /// - Parameter displayIndex: The display index
    /// - Returns: Array of windows on that display
    public func windows(onDisplay displayIndex: Int) -> [SnapshotWindow] {
        base.windows.filter { $0.displayIndex == displayIndex }
    }

    /// Gets the Chrome capture for a specific profile.
    ///
    /// - Parameter profileDir: Chrome profile directory
    /// - Returns: The Chrome capture if found
    public func chromeCapture(forProfile profileDir: String) -> ChromeWindowCapture? {
        base.chromeCaptures.first { $0.profileDirectory == profileDir }
    }

    // MARK: - Private Helpers

    /// Normalizes a path for consistent matching.
    private static func normalizePath(_ path: String) -> String {
        var normalized = path

        // Handle file:// URLs returned by AX APIs.
        if normalized.hasPrefix("file://") {
            normalized = String(normalized.dropFirst("file://".count))
        }

        // Decode escaped characters (%20, etc).
        normalized = normalized.removingPercentEncoding ?? normalized

        // Expand tilde
        if normalized.hasPrefix("~") {
            let home = FileManager.default.homeDirectoryForCurrentUser.path
            normalized = home + normalized.dropFirst()
        }

        // Resolve symlinks and standardize
        normalized = (normalized as NSString).standardizingPath

        // Lowercase for case-insensitive matching
        normalized = normalized.lowercased()

        // Remove trailing slash
        if normalized.hasSuffix("/") && normalized.count > 1 {
            normalized = String(normalized.dropLast())
        }

        return normalized
    }

    /// Collect normalized document paths used for path-based matching.
    /// Includes IDE-supplemented paths and Xcode directory extraction.
    private static func documentPaths(for window: SnapshotWindow) -> [String] {
        var normalizedPaths = Set<String>()
        let bundleId = window.bundleId

        func addPath(_ rawPath: String) {
            normalizedPaths.insert(normalizePath(rawPath))

            // Xcode AX paths often point to .xcworkspace/.xcodeproj; index the parent directory too.
            if bundleId == OpenByPathBundleIdentifiers.xcode {
                let extracted = extractDirectoryFromXcodeProjectPath(rawPath)
                normalizedPaths.insert(normalizePath(extracted))
            }
        }

        if let idePath = window.ideDocumentPath, !idePath.isEmpty {
            addPath(idePath)
        }
        if let docPath = window.documentPath, !docPath.isEmpty {
            addPath(docPath)
        }

        return Array(normalizedPaths)
    }

    private static func extractDirectoryFromXcodeProjectPath(_ path: String) -> String {
        let normalizedPath = normalizePath(path)
        if normalizedPath.hasSuffix(".xcworkspace") || normalizedPath.hasSuffix(".xcodeproj") {
            return URL(fileURLWithPath: normalizedPath).deletingLastPathComponent().path
        }
        return normalizedPath
    }

    /// Parses working directory from a window's title.
    ///
    /// Handles common terminal title formats:
    /// - "user@host:~/path"
    /// - "~/path - Ghostty"
    /// - "path — Terminal"
    private static func parseWorkingDirectory(from window: SnapshotWindow) -> String? {
        guard let title = window.title else { return nil }

        // Only parse working directory for terminal apps
        guard let bundleId = window.bundleId,
              BundleRegistry.isTerminal(bundleId) else {
            return nil
        }

        // Try to extract path from title

        // Pattern: "user@host:path" or just "path"
        if let colonIndex = title.lastIndex(of: ":") {
            let afterColon = String(title[title.index(after: colonIndex)...])
                .trimmingCharacters(in: .whitespaces)
            if afterColon.hasPrefix("~") || afterColon.hasPrefix("/") {
                // Remove trailing app name if present (e.g., " - Ghostty")
                if let dashIndex = afterColon.lastIndex(of: "-") {
                    return String(afterColon[..<dashIndex]).trimmingCharacters(in: .whitespaces)
                }
                return afterColon
            }
        }

        // Pattern: "path - AppName" or "path — AppName"
        for separator in [" - ", " — ", " – "] {
            if let range = title.range(of: separator) {
                let before = String(title[..<range.lowerBound])
                if before.hasPrefix("~") || before.hasPrefix("/") {
                    return before
                }
            }
        }

        // Check if the whole title looks like a path
        if title.hasPrefix("~") || title.hasPrefix("/") {
            return title
        }

        return nil
    }
}

// MARK: - Report Generation

extension EnhancedSnapshot {
    /// Generates a human-readable report of the enhanced snapshot.
    ///
    /// - Returns: Formatted string with snapshot details
    public func generateReport() -> String {
        var lines: [String] = []

        lines.append("=== Enhanced Snapshot Report ===")
        lines.append("Capture time: \(captureTime)")
        lines.append("Total duration: \(totalDurationMs)ms (base: \(base.captureDurationMs)ms, indexing: \(indexBuildDurationMs)ms)")
        lines.append("")

        lines.append("Window counts:")
        lines.append("  Total windows: \(windowCount)")
        lines.append("  By document path: \(windowsByDocumentPath.count) unique paths")
        lines.append("  By working dir: \(windowsByWorkingDir.count) unique directories")
        let managedTitleWindowCount = windowsByBentoTitle.values.reduce(0) { $0 + $1.count }
        lines.append("  By managed title: \(managedTitleWindowCount) windows (\(windowsByBentoTitle.count) unique titles)")
        lines.append("  By Chrome profile: \(windowsByChromeProfile.count) profiles")
        lines.append("  By bundle ID: \(windowsByBundleId.count) apps")
        lines.append("")

        lines.append("Displays: \(displays.count)")
        for display in displays {
            lines.append("  [\(display.index)] \(display.name ?? "Unknown") - \(display.frame)")
        }

        return lines.joined(separator: "\n")
    }
}
