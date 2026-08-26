//  GenericWindowRestorationService.swift
//  DeskJigShared

import Foundation
import AppKit
import CoreGraphics

public struct GenericWindowRestorationConfig: Sendable {
    public let useWindowLocks: Bool
    public let lockTimeout: Duration
    public let launchWindowTimeout: Duration
    public let launchPollInterval: Duration
    public let minimumSizeRatio: CGFloat
    public let verificationDelay: Duration
    public let verificationTolerance: CGFloat
    /// Extra settle time after a launching app reports `isFinishedLaunching` before the first
    /// AX positioning attempt. Positioning a window while the app is still in its launch-time
    /// layout pass can raise an uncaught layout exception inside the target app and crash it
    /// (observed with Apple Notes, deskjig#52).
    public let launchSettleDelay: Duration

    public init(
        useWindowLocks: Bool,
        lockTimeout: Duration,
        launchWindowTimeout: Duration = .seconds(10),
        launchPollInterval: Duration = .milliseconds(500),
        minimumSizeRatio: CGFloat = 0.6,
        verificationDelay: Duration = .milliseconds(50),
        verificationTolerance: CGFloat = 5.0,
        launchSettleDelay: Duration = .milliseconds(500)
    ) {
        self.useWindowLocks = useWindowLocks
        self.lockTimeout = lockTimeout
        self.launchWindowTimeout = launchWindowTimeout
        self.launchPollInterval = launchPollInterval
        self.minimumSizeRatio = minimumSizeRatio
        self.verificationDelay = verificationDelay
        self.verificationTolerance = verificationTolerance
        self.launchSettleDelay = launchSettleDelay
    }

    /// Creates a config for slow-start apps (Zoom, Discord, Slack).
    ///
    /// Slow-start apps show loading modals or splash screens on cold start,
    /// which prevent AX window handle acquisition. This config uses extended
    /// timeouts (30s instead of 10s) to accommodate the longer startup time.
    ///
    /// - Parameters:
    ///   - useWindowLocks: Whether to use window locks
    ///   - lockTimeout: Timeout for lock acquisition
    /// - Returns: A config with extended timeouts for slow-start apps
    public static func forSlowStartApp(
        useWindowLocks: Bool,
        lockTimeout: Duration
    ) -> GenericWindowRestorationConfig {
        GenericWindowRestorationConfig(
            useWindowLocks: useWindowLocks,
            lockTimeout: lockTimeout,
            launchWindowTimeout: .seconds(30),  // 3x normal timeout
            launchPollInterval: .milliseconds(500),
            minimumSizeRatio: 0.6,
            verificationDelay: .milliseconds(150),
            verificationTolerance: 5.0
        )
    }
}

public final class GenericWindowRestorationService: @unchecked Sendable {
    private let positioningService: WindowPositioningService
    private let launchSettlePolicy = LaunchSettlePolicy()

    public init(positioningService: WindowPositioningService) {
        self.positioningService = positioningService
    }

    public func restore(
        window: WorkspaceWindow,
        targetFrame: CGRect,
        snapshot: SystemSnapshot,
        taskContext: RestorationTaskContext,
        config: GenericWindowRestorationConfig
    ) async -> Bool {

        let bundleId = window.bundleIdentifier
        // Filter out zombie windows (exist in CGWindowList but not accessible via AX API)
        let appWindows = snapshot.windows.filter { $0.bundleId == bundleId && $0.isAXAccessible != false }
        let selection = await selectCandidate(from: appWindows, targetFrame: targetFrame, config: config)

        if let existingWindow = selection.candidate {
            DeskJigLog.debug(.restorationTrace, "Reusing existing window", fields: ["taskId": taskContext.taskId, "taskType": taskContext.taskType.rawValue,
                "reused": "true",
                "windowId": existingWindow.windowId,
                "title": existingWindow.title ?? "untitled",
                "candidates": "\(selection.totalCount)",
                "eligible": "\(selection.eligibleCount)",
                "filteredSmall": "\(selection.filteredCount)"
            ], runId: taskContext.runId)

            let isFinishedLaunching = NSRunningApplication.runningApplications(
                withBundleIdentifier: bundleId
            ).first?.isFinishedLaunching
            if launchSettlePolicy.needsSettle(
                launchedByThisRestore: false,
                isFinishedLaunching: isFinishedLaunching
            ) {
                let deadline = ContinuousClock().now.advanced(by: config.launchWindowTimeout)
                DeskJigLog.debug(.restorationTrace, "Launch settle before first positioning", fields: [
                    "taskId": taskContext.taskId,
                    "bundleId": bundleId,
                    "settleMs": "\(durationMillis(config.launchSettleDelay))"
                ], runId: taskContext.runId)
                guard await awaitLaunchSettle(bundleId: bundleId, deadline: deadline, config: config) else {
                    return false
                }
            }

            let positioned = await positionWindow(
                snapshotWindow: existingWindow,
                window: window,
                targetFrame: targetFrame,
                taskContext: taskContext,
                config: config
            )

            DeskJigLog.debug(.restorationTrace, "Window restoration complete", fields: ["taskId": taskContext.taskId, "taskType": taskContext.taskType.rawValue,
                "success": "\(positioned.matchesTarget)",
                "reused": "true"
            ], runId: taskContext.runId)

            return positioned.matchesTarget
        }

        let appUrl: URL?
        if let appPath = window.applicationPath {
            appUrl = URL(fileURLWithPath: appPath)
        } else {
            appUrl = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId)
        }

        let isRunning = !NSRunningApplication.runningApplications(withBundleIdentifier: bundleId).isEmpty
        if isRunning {
            DeskJigLog.debug(.restorationTrace, "App running - waiting for eligible window", fields: ["taskId": taskContext.taskId, "taskType": taskContext.taskType.rawValue,
                "bundleId": bundleId,
                "timeoutMs": "\(durationMillis(config.launchWindowTimeout))"
            ], runId: taskContext.runId)
            let positioned = await waitForWindowAndPosition(
                bundleId: bundleId,
                window: window,
                targetFrame: targetFrame,
                taskContext: taskContext,
                config: config
            )
            DeskJigLog.debug(.restorationTrace, "Window restoration complete", fields: ["taskId": taskContext.taskId, "taskType": taskContext.taskType.rawValue,
                "success": "\(positioned)",
                "reused": "false"
            ], runId: taskContext.runId)
            return positioned
        }

        guard let appUrl else {
            DeskJigLog.debug(.restorationTrace, "No application path or bundle URL", fields: ["taskId": taskContext.taskId, "taskType": taskContext.taskType.rawValue,
                "bundleId": bundleId,
                "success": false
            ], runId: taskContext.runId)
            return false
        }

        DeskJigLog.debug(.restorationTrace, "Launching application", fields: ["taskId": taskContext.taskId, "taskType": taskContext.taskType.rawValue,
            "path": appUrl.path,
            "bundleId": bundleId
        ], runId: taskContext.runId)

        let launchConfig = NSWorkspace.OpenConfiguration()
        launchConfig.activates = true
        do {
            _ = try await NSWorkspace.shared.openApplication(at: appUrl, configuration: launchConfig)
        } catch {
            DeskJigLog.warn(.restorationTrace, "Application launch failed", fields: [
                "taskId": taskContext.taskId,
                "taskType": taskContext.taskType.rawValue,
                "error": "\(error.localizedDescription)",
                "success": false
            ], runId: taskContext.runId)
        }

        let positioned = await waitForWindowAndPosition(
            bundleId: bundleId,
            window: window,
            targetFrame: targetFrame,
            taskContext: taskContext,
            config: config,
            settleAfterLaunch: true
        )

        DeskJigLog.debug(.restorationTrace, "Window restoration complete", fields: ["taskId": taskContext.taskId, "taskType": taskContext.taskType.rawValue,
            "success": "\(positioned)"
        ], runId: taskContext.runId)

        return positioned
    }

    private struct CandidateSelection {
        let candidate: SnapshotWindow?
        let totalCount: Int
        let eligibleCount: Int
        let filteredCount: Int
        let unresponsiveCount: Int
    }

    private struct PositionAttemptResult {
        let success: Bool
        let matchesTarget: Bool
        let windowId: CGWindowID
    }

    private struct FrameVerificationResult {
        let matches: Bool
        let actualFrame: CGRect?
    }

    private func waitForWindowAndPosition(
        bundleId: String,
        window: WorkspaceWindow,
        targetFrame: CGRect,
        taskContext: RestorationTaskContext,
        config: GenericWindowRestorationConfig,
        settleAfterLaunch: Bool = false
    ) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: config.launchWindowTimeout)
        var attempt = 0
        var reopenAttempted = false

        let isFinishedLaunching = NSRunningApplication.runningApplications(
            withBundleIdentifier: bundleId
        ).first?.isFinishedLaunching
        if launchSettlePolicy.needsSettle(
            launchedByThisRestore: settleAfterLaunch,
            isFinishedLaunching: isFinishedLaunching
        ) {
            DeskJigLog.debug(.restorationTrace, "Launch settle before first positioning", fields: [
                "taskId": taskContext.taskId,
                "bundleId": bundleId,
                "settleMs": "\(durationMillis(config.launchSettleDelay))"
            ], runId: taskContext.runId)
            guard await awaitLaunchSettle(bundleId: bundleId, deadline: deadline, config: config) else {
                return false
            }
        }

        // Track consecutive handle failures for the same window to avoid infinite retry loops
        // when a window's AX APIs are unresponsive (e.g., Zoom login dialogs)
        var consecutiveHandleFailures = 0
        var lastFailedWindowId: CGWindowID?
        let maxConsecutiveHandleFailures = 10

        // Track window IDs that have been marked as unresponsive - skip them in candidate selection
        var unresponsiveWindowIds: Set<CGWindowID> = []

        DeskJigLog.debug(.restorationTrace, "Waiting for launch window", fields: ["taskId": taskContext.taskId, "taskType": taskContext.taskType.rawValue,
            "bundleId": bundleId,
            "timeoutMs": "\(durationMillis(config.launchWindowTimeout))",
            "pollMs": "\(durationMillis(config.launchPollInterval))",
            "minSizeRatio": "\(config.minimumSizeRatio)"
        ], runId: taskContext.runId)

        while clock.now < deadline {
            let attemptSnapshot = await SystemSnapshotCapture.captureForBundle(bundleId: bundleId, runId: taskContext.runId)
            // Filter out zombie windows (exist in CGWindowList but not accessible via AX API)
            let appWindows = attemptSnapshot.windows.filter { $0.bundleId == bundleId && $0.isAXAccessible != false }
            let selection = await selectCandidate(from: appWindows, targetFrame: targetFrame, config: config, excludeWindowIds: unresponsiveWindowIds)

            if selection.totalCount == 0, !reopenAttempted {
                let didReopen = await attemptReopenApp(bundleId: bundleId, taskContext: taskContext)
                reopenAttempted = didReopen
                if didReopen {
                    guard await Task.sleepUnlessCancelled(for: .milliseconds(300)) else { break }
                }
            }

            if let candidate = selection.candidate {
                DeskJigLog.debug(.restorationTrace, "Launch window candidate selected", fields: ["taskId": taskContext.taskId, "taskType": taskContext.taskType.rawValue,
                    "windowId": "\(candidate.windowId)",
                    "title": candidate.title ?? "untitled",
                    "frame": frameDescription(candidate.frame),
                    "candidates": "\(selection.totalCount)",
                    "eligible": "\(selection.eligibleCount)",
                    "filteredSmall": "\(selection.filteredCount)",
                    "unresponsive": "\(selection.unresponsiveCount)"
                ], runId: taskContext.runId)

                let attemptResult = await positionWindow(
                    snapshotWindow: candidate,
                    window: window,
                    targetFrame: targetFrame,
                    taskContext: taskContext,
                    config: config
                )

                if attemptResult.matchesTarget {
                    await positioningService.claimWindow(candidate.windowId)
                    return true
                }

                // Track consecutive handle failures for the same window
                if !attemptResult.success {
                    if lastFailedWindowId == attemptResult.windowId {
                        consecutiveHandleFailures += 1
                    } else {
                        consecutiveHandleFailures = 1
                        lastFailedWindowId = attemptResult.windowId
                    }

                    if consecutiveHandleFailures >= maxConsecutiveHandleFailures {
                        // Mark this window as unresponsive - skip it in future candidate selection
                        unresponsiveWindowIds.insert(attemptResult.windowId)
                        DeskJigLog.debug(.restorationTrace, "Marking window as unresponsive", fields: ["taskId": taskContext.taskId, "taskType": taskContext.taskType.rawValue,
                            "windowId": "\(attemptResult.windowId)",
                            "failures": "\(consecutiveHandleFailures)",
                            "unresponsiveCount": "\(unresponsiveWindowIds.count)",
                            "reason": "Window AX APIs unresponsive - will skip in future polls"
                        ], runId: taskContext.runId)
                        // Reset for next window
                        consecutiveHandleFailures = 0
                        lastFailedWindowId = nil
                        // Continue polling - don't return false!

                        // Safety: give up if too many windows are unresponsive
                        let maxUnresponsiveWindows = 5
                        if unresponsiveWindowIds.count >= maxUnresponsiveWindows {
                            DeskJigLog.debug(.restorationTrace, "Too many unresponsive windows", fields: ["taskId": taskContext.taskId, "taskType": taskContext.taskType.rawValue,
                                "bundleId": bundleId,
                                "unresponsiveCount": "\(unresponsiveWindowIds.count)"
                            ], runId: taskContext.runId)
                            return false
                        }
                    }
                } else {
                    // Position was successful but didn't match target - reset failure counter
                    consecutiveHandleFailures = 0
                    lastFailedWindowId = nil
                }

                DeskJigLog.debug(.restorationTrace, "Launch window did not reach target - retrying", fields: ["taskId": taskContext.taskId, "taskType": taskContext.taskType.rawValue,
                    "windowId": "\(attemptResult.windowId)",
                    "success": "\(attemptResult.success)",
                    "handleFailures": "\(consecutiveHandleFailures)",
                    "unresponsiveWindows": "\(unresponsiveWindowIds.count)"
                ], runId: taskContext.runId)
            } else if attempt == 0 || attempt % 4 == 0 {
                DeskJigLog.debug(.restorationTrace, "Waiting for eligible window", fields: ["taskId": taskContext.taskId, "taskType": taskContext.taskType.rawValue,
                    "candidates": "\(selection.totalCount)",
                    "eligible": "\(selection.eligibleCount)",
                    "filteredSmall": "\(selection.filteredCount)",
                    "unresponsive": "\(selection.unresponsiveCount)"
                ], runId: taskContext.runId)
            }

            attempt += 1
            guard await Task.sleepUnlessCancelled(for: config.launchPollInterval) else { break }
        }

        DeskJigLog.debug(.restorationTrace, "Window not ready before timeout", fields: ["taskId": taskContext.taskId, "taskType": taskContext.taskType.rawValue,
            "bundleId": bundleId,
            "success": "false"
        ], runId: taskContext.runId)

        return false
    }

    private func awaitLaunchSettle(
        bundleId: String,
        deadline: ContinuousClock.Instant,
        config: GenericWindowRestorationConfig
    ) async -> Bool {
        let clock = ContinuousClock()
        while clock.now < deadline {
            let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleId).first
            if app?.isFinishedLaunching == true {
                guard await Task.sleepUnlessCancelled(for: config.launchSettleDelay) else { return false }
                return clock.now < deadline
            }
            guard await Task.sleepUnlessCancelled(for: config.launchPollInterval) else { return false }
        }
        return false
    }

    private func attemptReopenApp(
        bundleId: String,
        taskContext: RestorationTaskContext
    ) async -> Bool {
        await MainActor.run {
            guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleId).first else {
                return false
            }

            if app.isHidden {
                _ = app.unhide()
            }

            let activated: Bool
            if #available(macOS 14.0, *) {
                activated = app.activate()
            } else {
                activated = app.activate(options: [.activateIgnoringOtherApps, .activateAllWindows])
            }
            let allowReopen = WindowPositioningService.shouldSendReopenEvent(bundleId: bundleId)
            let reopenSent = allowReopen
                ? WindowPositioningService.sendReopenEvent(to: app, taskContext: taskContext)
                : false

            DeskJigLog.debug(.restorationTrace, "Reopen requested for app", fields: ["taskId": taskContext.taskId, "taskType": taskContext.taskType.rawValue,
                "bundleId": bundleId,
                "pid": "\(app.processIdentifier)",
                "activated": "\(activated)",
                "allowReopen": "\(allowReopen)",
                "reopenSent": "\(reopenSent)"
            ], runId: taskContext.runId)

            return activated || reopenSent
        }
    }

    private func positionWindow(
        snapshotWindow: SnapshotWindow,
        window: WorkspaceWindow,
        targetFrame: CGRect,
        taskContext: RestorationTaskContext,
        config: GenericWindowRestorationConfig
    ) async -> PositionAttemptResult {
        let preferredStrategy = WindowHandleResolver.preferredStrategy(
            workspaceWindow: window,
            snapshotWindow: snapshotWindow
        )

        let positioned = await positioningService.positionSnapshotWindow(
            snapshotWindow: snapshotWindow,
            targetFrame: targetFrame,
            taskContext: taskContext,
            requesterId: taskContext.taskId,
            lockPriority: .medium,
            useWindowLocks: config.useWindowLocks,
            lockTimeout: config.lockTimeout,
            preferredStrategy: preferredStrategy
        )

        var matchesTarget = positioned.matchesTarget
        if positioned.success, !matchesTarget {
            let verification = await verifyFrameMatch(
                windowId: snapshotWindow.windowId,
                targetFrame: targetFrame,
                config: config
            )
            matchesTarget = verification.matches
            if let actualFrame = verification.actualFrame, !verification.matches {
                DeskJigLog.debug(.restorationTrace, "Verification mismatch after positioning", fields: ["taskId": taskContext.taskId, "taskType": taskContext.taskType.rawValue,
                    "windowId": "\(snapshotWindow.windowId)",
                    "targetFrame": frameDescription(targetFrame),
                    "actualFrame": frameDescription(actualFrame)
                ], runId: taskContext.runId)
            }
        }

        return PositionAttemptResult(
            success: positioned.success,
            matchesTarget: matchesTarget,
            windowId: snapshotWindow.windowId
        )
    }

    private func selectCandidate(
        from windows: [SnapshotWindow],
        targetFrame: CGRect,
        config: GenericWindowRestorationConfig,
        excludeWindowIds: Set<CGWindowID> = []
    ) async -> CandidateSelection {
        guard !windows.isEmpty else {
            return CandidateSelection(candidate: nil, totalCount: 0, eligibleCount: 0, filteredCount: 0, unresponsiveCount: 0)
        }

        let hasTargetSize = targetFrame.width > 0 && targetFrame.height > 0

        // Filter by size
        let sizeEligible = windows.filter { window in
            guard hasTargetSize else { return true }
            let widthRatio = window.frame.width / targetFrame.width
            let heightRatio = window.frame.height / targetFrame.height
            return widthRatio >= config.minimumSizeRatio && heightRatio >= config.minimumSizeRatio
        }

        // Filter out unresponsive windows (those with failed AX handle acquisition)
        let responsive = sizeEligible.filter { !excludeWindowIds.contains($0.windowId) }

        // Filter by claim status
        var unclaimed: [SnapshotWindow] = []
        for window in responsive {
            if await !positioningService.isWindowClaimed(window.windowId) {
                unclaimed.append(window)
            }
        }

        let candidate = selectBestCandidate(from: unclaimed, targetFrame: targetFrame)

        return CandidateSelection(
            candidate: candidate,
            totalCount: windows.count,
            eligibleCount: sizeEligible.count,
            filteredCount: max(0, windows.count - sizeEligible.count),
            unresponsiveCount: sizeEligible.count - responsive.count
        )
    }

    private func selectBestCandidate(
        from windows: [SnapshotWindow],
        targetFrame: CGRect
    ) -> SnapshotWindow? {
        guard !windows.isEmpty else { return nil }

        let hasTargetFrame = targetFrame.width > 0 && targetFrame.height > 0
        if !hasTargetFrame {
            return windows.sorted {
                ($0.zOrderIndex ?? Int.max) < ($1.zOrderIndex ?? Int.max)
            }.first
        }

        return windows.sorted { lhs, rhs in
            let leftDistance = frameDistance(lhs.frame, targetFrame)
            let rightDistance = frameDistance(rhs.frame, targetFrame)
            if leftDistance != rightDistance {
                return leftDistance < rightDistance
            }
            return (lhs.zOrderIndex ?? Int.max) < (rhs.zOrderIndex ?? Int.max)
        }.first
    }

    private func frameDistance(_ lhs: CGRect, _ rhs: CGRect) -> CGFloat {
        lhs.manhattanDistance(to: rhs)
    }

    private func verifyFrameMatch(
        windowId: CGWindowID,
        targetFrame: CGRect,
        config: GenericWindowRestorationConfig
    ) async -> FrameVerificationResult {
        guard targetFrame.width > 0 && targetFrame.height > 0 else {
            return FrameVerificationResult(matches: true, actualFrame: nil)
        }

        if config.verificationDelay > .zero {
            await Task.sleepUnlessCancelled(for: config.verificationDelay)
        }

        guard let refreshed = Window.info(windowId: windowId) else {
            return FrameVerificationResult(matches: false, actualFrame: nil)
        }

        let rawMatches = refreshed.frameMatches(targetFrame, tolerance: config.verificationTolerance)
        let layoutScreens = await MainActor.run {
            WindowLayoutFrameMatcher.liveScreens()
        }
        let matches = rawMatches || WindowLayoutFrameMatcher.matchesLayout(
            actualFrame: refreshed.frame,
            targetFrame: targetFrame,
            screens: layoutScreens
        )
        return FrameVerificationResult(matches: matches, actualFrame: refreshed.frame)
    }

    private func frameDescription(_ frame: CGRect) -> String {
        frame.traceDescription
    }

    private func durationMillis(_ duration: Duration) -> Int {
        let components = duration.components
        let secondsMs = components.seconds * 1000
        let attosMs = components.attoseconds / 1_000_000_000_000_000
        return Int(secondsMs + attosMs)
    }
}
