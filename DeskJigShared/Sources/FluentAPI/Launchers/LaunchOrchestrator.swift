//  LaunchOrchestrator.swift
//  DeskJigShared

import Foundation
import AppKit

/// Orchestrates the complete app launch and window matching workflow.
/// Handles: check existing -> (if not found) launch -> wait -> snapshot -> supplement -> match
public actor LaunchOrchestrator {

    public enum MatchSource: String, Sendable {
        case existingWindow = "existing"
        case launchedWindow = "launched"
    }

    public struct Result: Sendable {
        public let match: ExpWindowMatch?
        public let matchSource: MatchSource?
        public let launchResult: ExpLaunchResult?
        public let snapshot: SystemSnapshot
        public let wasSupplemented: Bool
    }

    public init() {}

    /// Finds or launches an app window, with terminal/IDE supplementation support.
    ///
    /// Workflow:
    /// 1. Check for existing window in provided snapshot
    /// 2. If found, return it immediately (no launch needed)
    /// 3. If not found, launch the app
    /// 4. Wait for window to appear
    /// 5. Capture fresh snapshot
    /// 6. Supplement terminal windows (if enabled)
    /// 7. Match the launched window
    ///
    /// - Parameters:
    ///   - launcher: The app-specific launcher to use
    ///   - directory: Working directory to open
    ///   - title: Window title using the legacy `bento:<dir>:<index>` format
    ///   - existingSnapshot: Snapshot to check for existing windows
    ///   - task: Logging context
    ///   - runId: Restoration run ID
    ///   - supplementationMethod: How to fetch terminal working directories
    ///   - enableSupplementation: Whether to run terminal supplementation
    ///   - ideSupplementationMethod: How to fetch IDE document paths
    ///   - enableIDESupplementation: Whether to run IDE supplementation
    ///   - windowWaitMs: Optional explicit wait time after launch. When omitted, adaptive policy is used.
    ///
    /// - Returns: Result containing matched window (if found), source, launch status, and snapshot
    public func findOrLaunch(
        launcher: FluentAppLauncher,
        directory: String?,
        title: String?,
        existingSnapshot: SystemSnapshot,
        task: RestorationTaskContext,
        runId: String,
        supplementationMethod: TerminalFetchMethod,
        enableSupplementation: Bool,
        ideSupplementationMethod: IDEFetchMethod = .cursorStateWithAXFallback,
        enableIDESupplementation: Bool = false,
        allowReuseExisting: Bool = true,
        windowWaitMs: Int? = nil
    ) async -> Result {
        let isPathStrictXcode = launcher.bundleId == BundleRegistry.xcode && directory != nil
        let wasAlreadyRunning = !NSRunningApplication.runningApplications(withBundleIdentifier: launcher.bundleId).isEmpty
        func shouldAcceptPathStrictMatch(_ match: ExpWindowMatch) -> Bool {
            guard isPathStrictXcode else { return true }
            return match.method == .documentPath
        }

        // 1. Check for existing window in provided snapshot
        // Trust legacy `bento:` titles for terminals in the existing-window check.
        // Rationale: Terminal working directories often can't be reliably determined via lsof/AX
        // (returns "/" or "unknown"), but these titles are unique identifiers we set ourselves.
        let shouldTrustDeskJigTitle = BundleRegistry.isTerminal(launcher.bundleId) && title?.hasPrefix("\(BundleIdentity.terminalTitleTokenPrefix):") == true

        if allowReuseExisting,
           let existingMatch = launcher.matchWindow(in: existingSnapshot, directory: directory, title: title, task: task, trustDeskJigTitle: shouldTrustDeskJigTitle) {
            if shouldAcceptPathStrictMatch(existingMatch) {
                DeskJigLog.debug(.restorationTrace, "Found existing window - reusing", fields: [
                    "taskId": task.taskId,
                    "taskType": task.taskType.rawValue,
                    "windowId": Int(existingMatch.window.windowId),
                    "confidence": existingMatch.confidence.rawValue,
                    "method": existingMatch.method.rawValue,
                    "singleInstance": launcher.isSingleInstance
                ], runId: task.runId)

                // Single-instance apps (e.g. Codex) need the launch() call to switch
                // to the correct project, even though the window is already matched.
                if launcher.isSingleInstance, directory != nil {
                    var singleInstanceLaunchResult: ExpLaunchResult?
                    do {
                        singleInstanceLaunchResult = try await launcher.launch(directory: directory, title: title, task: task)
                        DeskJigLog.debug(.restorationTrace, "Single-instance project switch \(singleInstanceLaunchResult?.success == true ? "succeeded" : "failed")", fields: [
                            "taskId": task.taskId,
                            "taskType": task.taskType.rawValue,
                            "directory": directory ?? "none"
                        ], runId: task.runId)
                    } catch {
                        DeskJigLog.debug(.restorationTrace, "Single-instance project switch error (non-fatal): \(error.localizedDescription)", fields: [
                            "taskId": task.taskId,
                            "taskType": task.taskType.rawValue
                        ], runId: task.runId)
                    }
                    return Result(
                        match: existingMatch,
                        matchSource: .existingWindow,
                        launchResult: singleInstanceLaunchResult,
                        snapshot: existingSnapshot,
                        wasSupplemented: false
                    )
                }

                return Result(
                    match: existingMatch,
                    matchSource: .existingWindow,
                    launchResult: nil,
                    snapshot: existingSnapshot,
                    wasSupplemented: false
                )
            }

            DeskJigLog.debug(.restorationTrace, "Ignoring weak existing Xcode match", fields: [
                "taskId": task.taskId,
                "taskType": task.taskType.rawValue,
                "xcodePathStrict": true,
                "ambiguousReason": "existingMatchNotPathConfirmed",
                "candidateCounts": "existing=1",
                "method": existingMatch.method.rawValue,
                "waitMs": 0
            ], runId: task.runId)
        }

        DeskJigLog.debug(.restorationTrace, "No existing window found - launching", fields: [
            "taskId": task.taskId,
            "taskType": task.taskType.rawValue,
            "bundleId": launcher.bundleId,
            "directory": directory ?? "none",
            "title": title ?? "none"
        ], runId: task.runId)

        // 2. Launch the application
        var launchResult: ExpLaunchResult?
        do {
            launchResult = try await launcher.launch(directory: directory, title: title, task: task)
            DeskJigLog.debug(.restorationTrace, launchResult?.success == true ? "Launch succeeded" : "Launch failed", fields: [
                "taskId": task.taskId,
                "taskType": task.taskType.rawValue,
                "success": launchResult?.success ?? false,
                "method": launchResult?.method.rawValue ?? "unknown"
            ], runId: task.runId)
        } catch {
            DeskJigLog.debug(.restorationTrace, "Launch error: \(error.localizedDescription)", fields: [
                "taskId": task.taskId,
                "taskType": task.taskType.rawValue
            ], runId: task.runId)
            return Result(match: nil, matchSource: nil, launchResult: nil, snapshot: existingSnapshot, wasSupplemented: false)
        }

        guard launchResult?.success == true else {
            return Result(match: nil, matchSource: nil, launchResult: launchResult, snapshot: existingSnapshot, wasSupplemented: false)
        }

        // 3. Wait for window to appear
        let resolvedWindowWaitMs = Self.resolveWindowWaitMs(
            explicitWaitMs: windowWaitMs,
            bundleId: launcher.bundleId,
            wasAlreadyRunning: wasAlreadyRunning
        )
        func matchesLauncherApp(_ window: SnapshotWindow) -> Bool {
            if let bundleId = window.bundleId, bundleId == launcher.bundleId {
                return true
            }
            if let appName = window.appName, appName.caseInsensitiveCompare(launcher.appName) == .orderedSame {
                return true
            }
            return false
        }

        func matchNewlyAppearedWindow(_ snapshot: SystemSnapshot) -> ExpWindowMatch? {
            let appeared = snapshot.windowsAppeared(since: existingSnapshot)
                .filter { matchesLauncherApp($0) }

            guard !appeared.isEmpty else { return nil }

            let candidate = appeared
                .sorted { ($0.zOrderIndex ?? Int.max) < ($1.zOrderIndex ?? Int.max) }
                .first

            guard let candidate else { return nil }

            return ExpWindowMatch(
                window: candidate,
                confidence: .low,
                method: .bundleIdOnly,
                matchedValue: candidate.title
            )
        }

        func snapshotForNewWindows(_ snapshot: SystemSnapshot) -> SystemSnapshot {
            guard !allowReuseExisting else { return snapshot }
            let existingIds = Set(existingSnapshot.windows.map { $0.id })
            let filteredWindows = snapshot.windows.filter { !existingIds.contains($0.id) }
            return SystemSnapshot(
                captureTime: snapshot.captureTime,
                captureDurationMs: snapshot.captureDurationMs,
                runId: snapshot.runId,
                timing: snapshot.timing,
                displays: snapshot.displays,
                windows: filteredWindows,
                chromeCaptures: snapshot.chromeCaptures
            )
        }

        // 3. Wait for the launched window to appear.
        // Early-exit poll (launch-02): instead of always sleeping the full
        // `resolvedWindowWaitMs`, poll at short intervals and stop as soon as an
        // acceptable (path-strict-confirmed) match exists. This returns fast for
        // the common case (window appears quickly) while keeping the same
        // worst-case ceiling. The match acceptance + return logic in step 5 below
        // is intentionally unchanged, so matching semantics are identical.
        DeskJigLog.debug(.restorationTrace, "Waiting for window to appear", fields: [
            "taskId": task.taskId,
            "taskType": task.taskType.rawValue,
            "waitMs": resolvedWindowWaitMs,
            "waitPolicy": windowWaitMs == nil ? "adaptive" : "explicit",
            "alreadyRunning": wasAlreadyRunning
        ], runId: task.runId)

        func hasAcceptableMatch(_ snapshot: SystemSnapshot) -> Bool {
            let matchSnapshot = snapshotForNewWindows(snapshot)
            if !allowReuseExisting,
               let candidate = matchNewlyAppearedWindow(snapshot),
               shouldAcceptPathStrictMatch(candidate) {
                return true
            }
            if let candidate = launcher.matchWindow(in: matchSnapshot, directory: directory, title: title, task: task, trustDeskJigTitle: true),
               shouldAcceptPathStrictMatch(candidate) {
                return true
            }
            return false
        }

        let windowPollIntervalMs = 120
        var waitedMs = 0
        // 4. Capture fresh snapshot (re-captured each poll iteration).
        var snapshot = await SystemSnapshotCapture.captureQuick(runId: runId)
        while !hasAcceptableMatch(snapshot) && waitedMs < resolvedWindowWaitMs {
            let step = min(windowPollIntervalMs, resolvedWindowWaitMs - waitedMs)
            guard await Task.sleepUnlessCancelled(for: .milliseconds(step)) else { break }
            waitedMs += step
            snapshot = await SystemSnapshotCapture.captureQuick(runId: runId)
        }
        DeskJigLog.debug(.restorationTrace, "Window appearance wait complete", fields: [
            "taskId": task.taskId,
            "taskType": task.taskType.rawValue,
            "actualWaitMs": waitedMs,
            "ceilingMs": resolvedWindowWaitMs
        ], runId: task.runId)

        // 5. Match the window, trusting the legacy title token because it was just launched.
        let matchSnapshot = snapshotForNewWindows(snapshot)
        if !allowReuseExisting, let match = matchNewlyAppearedWindow(snapshot) {
            if shouldAcceptPathStrictMatch(match) {
                DeskJigLog.debug(.restorationTrace, "Window matched after launch (new window diff)", fields: [
                    "taskId": task.taskId,
                    "taskType": task.taskType.rawValue,
                    "windowId": Int(match.window.windowId),
                    "confidence": match.confidence.rawValue,
                    "method": match.method.rawValue,
                    "matchedValue": match.matchedValue ?? "n/a"
                ], runId: task.runId)
                return Result(
                    match: match,
                    matchSource: .launchedWindow,
                    launchResult: launchResult,
                    snapshot: snapshot,
                    wasSupplemented: false
                )
            }

            DeskJigLog.debug(.restorationTrace, "Ignoring weak Xcode match from new-window diff", fields: [
                "taskId": task.taskId,
                "taskType": task.taskType.rawValue,
                "xcodePathStrict": true,
                "ambiguousReason": "newWindowDiffNotPathConfirmed",
                "candidateCounts": "newlyAppeared=1",
                "method": match.method.rawValue,
                "waitMs": resolvedWindowWaitMs
            ], runId: task.runId)
        }
        if let match = launcher.matchWindow(in: matchSnapshot, directory: directory, title: title, task: task, trustDeskJigTitle: true) {
            if shouldAcceptPathStrictMatch(match) {
                DeskJigLog.debug(.restorationTrace, "Window matched after launch (pre-supplementation)", fields: [
                    "taskId": task.taskId,
                    "taskType": task.taskType.rawValue,
                    "windowId": Int(match.window.windowId),
                    "confidence": match.confidence.rawValue,
                    "method": match.method.rawValue,
                    "matchedValue": match.matchedValue ?? "n/a"
                ], runId: task.runId)
                return Result(
                    match: match,
                    matchSource: .launchedWindow,
                    launchResult: launchResult,
                    snapshot: snapshot,
                    wasSupplemented: false
                )
            }

            DeskJigLog.debug(.restorationTrace, "Deferring weak Xcode pre-supplement match", fields: [
                "taskId": task.taskId,
                "taskType": task.taskType.rawValue,
                "xcodePathStrict": true,
                "ambiguousReason": "preSupplementMatchNotPathConfirmed",
                "candidateCounts": "preSupplement=1",
                "method": match.method.rawValue,
                "waitMs": resolvedWindowWaitMs
            ], runId: task.runId)
        }

        // 6. Supplement terminal windows if enabled
        var wasSupplemented = false
        if BundleRegistry.isTerminal(launcher.bundleId) && enableSupplementation {
            DeskJigLog.debug(.restorationTrace, "Starting post-launch terminal supplementation", fields: [
                "taskId": task.taskId,
                "taskType": task.taskType.rawValue,
                "method": supplementationMethod.rawValue,
                "bundleId": launcher.bundleId
            ], runId: task.runId)

            let supplementationService = TerminalSupplementationService()
            snapshot = await supplementationService.supplementTerminalWindows(
                in: snapshot,
                method: supplementationMethod,
                runId: runId
            )
            wasSupplemented = true

            DeskJigLog.debug(.restorationTrace, "Post-launch terminal supplementation complete", fields: [
                "taskId": task.taskId,
                "taskType": task.taskType.rawValue
            ], runId: task.runId)
        }

        // 6b. Supplement IDE windows if enabled
        if BundleRegistry.isIDE(launcher.bundleId) && enableIDESupplementation {
            DeskJigLog.debug(.restorationTrace, "Starting post-launch IDE supplementation", fields: [
                "taskId": task.taskId,
                "taskType": task.taskType.rawValue,
                "method": ideSupplementationMethod.rawValue,
                "bundleId": launcher.bundleId
            ], runId: task.runId)

            let ideSupplementationService = IDESupplementationService()
            snapshot = await ideSupplementationService.supplementIDEWindows(
                in: snapshot,
                method: ideSupplementationMethod,
                runId: runId
            )
            wasSupplemented = true

            DeskJigLog.debug(.restorationTrace, "Post-launch IDE supplementation complete", fields: [
                "taskId": task.taskId,
                "taskType": task.taskType.rawValue
            ], runId: task.runId)
        }

        // 7. Match the window after supplementation
        let matchSnapshotAfterSupplement = snapshotForNewWindows(snapshot)
        let rawMatch = launcher.matchWindow(in: matchSnapshotAfterSupplement, directory: directory, title: title, task: task, trustDeskJigTitle: true)
        let match = rawMatch.flatMap { shouldAcceptPathStrictMatch($0) ? $0 : nil }

        if let match {
            DeskJigLog.debug(.restorationTrace, "Window matched after launch", fields: [
                "taskId": task.taskId,
                "taskType": task.taskType.rawValue,
                "windowId": Int(match.window.windowId),
                "confidence": match.confidence.rawValue,
                "method": match.method.rawValue,
                "matchedValue": match.matchedValue ?? "n/a"
            ], runId: task.runId)
        } else {
            if let rawMatch, isPathStrictXcode {
                DeskJigLog.debug(.restorationTrace, "Rejecting weak Xcode post-supplement match", fields: [
                    "taskId": task.taskId,
                    "taskType": task.taskType.rawValue,
                    "xcodePathStrict": true,
                    "ambiguousReason": "postSupplementMatchNotPathConfirmed",
                    "candidateCounts": "postSupplement=1",
                    "method": rawMatch.method.rawValue,
                    "waitMs": resolvedWindowWaitMs
                ], runId: task.runId)
            }

            if !allowReuseExisting, let diffMatch = matchNewlyAppearedWindow(snapshot) {
                if shouldAcceptPathStrictMatch(diffMatch) {
                    DeskJigLog.debug(.restorationTrace, "Window matched after launch (new window diff, post-supplement)", fields: [
                        "taskId": task.taskId,
                        "taskType": task.taskType.rawValue,
                        "windowId": Int(diffMatch.window.windowId),
                        "confidence": diffMatch.confidence.rawValue,
                        "method": diffMatch.method.rawValue,
                        "matchedValue": diffMatch.matchedValue ?? "n/a"
                    ], runId: task.runId)
                    return Result(
                        match: diffMatch,
                        matchSource: .launchedWindow,
                        launchResult: launchResult,
                        snapshot: snapshot,
                        wasSupplemented: wasSupplemented
                    )
                }

                DeskJigLog.debug(.restorationTrace, "Ignoring weak Xcode post-supplement diff match", fields: [
                    "taskId": task.taskId,
                    "taskType": task.taskType.rawValue,
                    "xcodePathStrict": true,
                    "ambiguousReason": "postSupplementNewWindowDiffNotPathConfirmed",
                    "candidateCounts": "newlyAppeared=1",
                    "method": diffMatch.method.rawValue,
                    "waitMs": resolvedWindowWaitMs
                ], runId: task.runId)
            }
            DeskJigLog.debug(.restorationTrace, "No matching window found after launch", fields: [
                "taskId": task.taskId,
                "taskType": task.taskType.rawValue,
                "found": false
            ], runId: task.runId)
        }

        return Result(
            match: match,
            matchSource: match != nil ? .launchedWindow : nil,
            launchResult: launchResult,
            snapshot: snapshot,
            wasSupplemented: wasSupplemented
        )
    }

    private static func resolveWindowWaitMs(
        explicitWaitMs: Int?,
        bundleId: String,
        wasAlreadyRunning: Bool
    ) -> Int {
        if let explicitWaitMs {
            return max(0, explicitWaitMs)
        }
        if wasAlreadyRunning {
            if bundleId == OpenByPathBundleIdentifiers.cursor ||
                bundleId == OpenByPathBundleIdentifiers.codex ||
                bundleId == OpenByPathBundleIdentifiers.vscode {
                return 250
            }
            if bundleId == OpenByPathBundleIdentifiers.xcode {
                return 400
            }
        }
        return 800
    }
}
