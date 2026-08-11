//  RestorationExecutor+QuickSwitchPreflight.swift
//  DeskJigShared

import Foundation
import CoreGraphics
import AppKit

enum QuickSwitchTmuxPreflightAction: String, Sendable {
    case noOp
    case switchOnly
    case repositionOnly
    case titleOnly
    case multiAction
    case bootstrap
}

extension RestorationExecutor {

    // MARK: - Quick-Switch Tmux Preflight

    static let quickSwitchLaunchSource = "quick-switch"

    private var quickSwitchTmuxPreflightEnabled: Bool {
        Self.shouldUseQuickSwitchTmuxPreflight(launchSource: config.launchSource)
    }

    static func shouldUseQuickSwitchTmuxPreflight(launchSource: String) -> Bool {
        launchSource == quickSwitchLaunchSource
    }

    static func shouldUseSingleProcessTerminalWindowResolver(bundleId: String) -> Bool {
        // Wire the strict AX/title resolver to Terminal.app first. Other
        // single-process terminals can opt in once they have equivalent
        // post-launch title stability and regression coverage.
        bundleId == BundleRegistry.terminal
    }

    private static func shouldTreatQuickSwitchTerminalFrameAsPositioned(
        bundleId: String,
        snapshotWindow: SnapshotWindow,
        targetFrame: CGRect,
        expectedScreenIndex: Int?,
        sessionMatches: Bool,
        titleMatches: Bool
    ) -> Bool {
        guard BundleRegistry.isTerminal(bundleId),
              titleMatches else {
            return false
        }

        if let expectedScreenIndex,
           let actualScreenIndex = snapshotWindow.displayIndex,
           actualScreenIndex != expectedScreenIndex {
            return false
        }

        // Terminal apps can enforce grid sizing/reflow that causes stable x/width
        // drift versus the desired frame while still preserving the intended
        // row/screen layout. Treat these as already positioned to avoid repetitive
        // move/reflow churn on repeated quick-switch restores.
        let frame = snapshotWindow.frame
        let yDelta = abs(frame.origin.y - targetFrame.origin.y)
        let heightDelta = abs(frame.height - targetFrame.height)
        guard yDelta <= 12, heightDelta <= 12 else {
            return false
        }

        // Width must be roughly correct — grid reflow causes small drift (±30px)
        // but a large delta (e.g. 980 vs 1344) means a different layout, not reflow.
        let widthDelta = abs(frame.width - targetFrame.width)
        guard widthDelta <= max(80, targetFrame.width * 0.1) else {
            return false
        }

        // Keep the current window horizontally near its intended slot. During
        // quick-switch session swaps, allow more horizontal drift because some
        // terminals (notably iTerm) preserve user slot ordering and then reflow.
        let frameMidX = frame.midX
        let targetMidX = targetFrame.midX
        let midXDelta = abs(frameMidX - targetMidX)
        let toleranceMultiplier: CGFloat = sessionMatches ? 0.5 : 0.75
        let horizontalTolerance = min(max(140, targetFrame.width * toleranceMultiplier), targetFrame.width)
        guard midXDelta <= horizontalTolerance else {
            return false
        }

        return true
    }

    func shouldSkipTmuxIndexCoverageEnforcement(
        bundleId: String,
        expectedWindowCount: Int
    ) -> Bool {
        guard quickSwitchTmuxPreflightEnabled,
              BundleRegistry.isTerminal(bundleId),
              expectedWindowCount <= 1 else {
            return false
        }
        return true
    }

    static func shouldFallbackToTmuxLaunchAfterSwitchPositionFailure(
        positioningSucceeded: Bool,
        finalFramePresent: Bool,
        hasTmuxState: Bool
    ) -> Bool {
        guard hasTmuxState else { return false }
        return !positioningSucceeded && !finalFramePresent
    }

    static func classifyQuickSwitchTmuxPreflightAction(
        hasSelectedClient: Bool,
        hasSnapshotWindow: Bool,
        requiresSwitch: Bool,
        requiresTitleUpdate: Bool,
        requiresReposition: Bool,
        requiresPathUpdate: Bool
    ) -> QuickSwitchTmuxPreflightAction {
        guard hasSelectedClient, hasSnapshotWindow else {
            return .bootstrap
        }

        if !requiresSwitch && !requiresTitleUpdate && !requiresReposition && !requiresPathUpdate {
            return .noOp
        }

        if requiresReposition && !requiresSwitch && !requiresTitleUpdate && !requiresPathUpdate {
            return .repositionOnly
        }

        if requiresTitleUpdate && !requiresSwitch && !requiresReposition && !requiresPathUpdate {
            return .titleOnly
        }

        if (requiresSwitch || requiresPathUpdate) && !requiresTitleUpdate && !requiresReposition {
            return .switchOnly
        }

        return .multiAction
    }

    static func shouldTreatTTYMappedSessionAsManagedEvidence(
        bundleId: String,
        windowTitle: String?,
        mappedSessionName: String?,
        expectedSessionName: String
    ) -> Bool {
        guard bundleId == BundleRegistry.iterm2,
              let mappedSessionName,
              mappedSessionName == expectedSessionName else {
            return false
        }

        let normalizedTitle = (windowTitle ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return normalizedTitle.isEmpty || !normalizedTitle.contains(BundleRegistry.managedTmuxWindowTitle)
    }

    static func shouldSetIndexedTitleForQuickSwitchPreflight(
        requiresSwitch: Bool,
        requiresTitleUpdate: Bool
    ) -> Bool {
        requiresSwitch || requiresTitleUpdate
    }

    static func shouldEnforceSessionMatchForITermTTYMappedSelection(
        bundleId: String,
        launchSource: String,
        expectedWindowCount: Int
    ) -> Bool {
        guard bundleId == BundleRegistry.iterm2, expectedWindowCount > 1 else {
            return true
        }

        // Quick-switch should keep the mapped iTerm window identity (TTY) and
        // allow switch-client from old session -> target session.
        return !shouldUseQuickSwitchTmuxPreflight(launchSource: launchSource)
    }

    static func shouldMutateExistingTmuxSessionPathForQuickSwitch() -> Bool {
        false
    }

    struct QuickSwitchTmuxPreflightDecision {
        let action: QuickSwitchTmuxPreflightAction
        let shouldSwitchSession: Bool
        let shouldSetIndexedTitle: Bool
        let shouldRepositionWindow: Bool

        static let disabled = QuickSwitchTmuxPreflightDecision(
            action: .multiAction,
            shouldSwitchSession: true,
            shouldSetIndexedTitle: true,
            shouldRepositionWindow: true
        )
    }

    func buildQuickSwitchTmuxPreflightDecision(
        bundleId: String,
        sessionName: String,
        currentSessionName: String?,
        snapshotWindow: SnapshotWindow?,
        targetFrame: CGRect,
        expectedScreenIndex: Int?,
        tmuxIndex: Int?,
        openPath: String?,
        hasSelectedClient: Bool,
        hasStrongManagedEvidence: Bool,
        taskContext: RestorationTaskContext
    ) async -> QuickSwitchTmuxPreflightDecision? {
        guard quickSwitchTmuxPreflightEnabled else {
            return nil
        }

        guard let snapshotWindow else {
            let action = Self.classifyQuickSwitchTmuxPreflightAction(
                hasSelectedClient: hasSelectedClient || hasStrongManagedEvidence,
                hasSnapshotWindow: false,
                requiresSwitch: true,
                requiresTitleUpdate: true,
                requiresReposition: true,
                requiresPathUpdate: false
            )
            logRC10Diag(
                "quick-switch-tmux-preflight",
                runId: taskContext.runId,
                data: [
                    "action": action.rawValue,
                    "bundleId": bundleId,
                    "hasSelectedClient": hasSelectedClient,
                    "hasStrongManagedEvidence": hasStrongManagedEvidence,
                    "hasSnapshotWindow": "false",
                    "sessionName": sessionName
                ]
            )
            return QuickSwitchTmuxPreflightDecision.disabled
        }

        let sessionMatches = currentSessionName == sessionName
        let strictFrameMatches = snapshotWindow.frameMatches(targetFrame, tolerance: 12)
        let titleMatches: Bool = {
            guard let tmuxIndex else { return true }
            let indexedTitle = BundleRegistry.managedTmuxWindowTitle(bundleId: bundleId, index: tmuxIndex).lowercased()
            return (snapshotWindow.title ?? "").lowercased().contains(indexedTitle)
        }()
        let relaxedTerminalFrameMatch = Self.shouldTreatQuickSwitchTerminalFrameAsPositioned(
            bundleId: bundleId,
            snapshotWindow: snapshotWindow,
            targetFrame: targetFrame,
            expectedScreenIndex: expectedScreenIndex,
            sessionMatches: sessionMatches,
            titleMatches: titleMatches
        )
        let frameMatches = strictFrameMatches || relaxedTerminalFrameMatch

        let expectedPath = openPath.map {
            let expanded = ($0 as NSString).expandingTildeInPath
            return URL(fileURLWithPath: expanded).standardizedFileURL.path
        }

        let requiresSwitch = !sessionMatches
        let requiresTitleUpdate = !titleMatches
        let shouldSetIndexedTitle = Self.shouldSetIndexedTitleForQuickSwitchPreflight(
            requiresSwitch: requiresSwitch,
            requiresTitleUpdate: requiresTitleUpdate
        )
        // Minimized windows report their pre-minimize frame to CGWindowList,
        // so frameMatches may be true even though the window is in the dock.
        // Force repositioning to unminimize it.
        let isMinimized = snapshotWindow.isMinimized == true
        let requiresReposition = !frameMatches || isMinimized
        let requiresPathUpdate = Self.shouldMutateExistingTmuxSessionPathForQuickSwitch()
        let action = Self.classifyQuickSwitchTmuxPreflightAction(
            hasSelectedClient: hasSelectedClient || hasStrongManagedEvidence,
            hasSnapshotWindow: true,
            requiresSwitch: requiresSwitch,
            requiresTitleUpdate: requiresTitleUpdate,
            requiresReposition: requiresReposition,
            requiresPathUpdate: requiresPathUpdate
        )

        let sf = snapshotWindow.frame
        let tf = targetFrame
        DeskJigLog.debug(.restorationTrace, "Preflight frame comparison", fields: [
            "taskId": taskContext.taskId,
            "bundleId": bundleId,
            "windowId": snapshotWindow.windowId,
            "snapshotFrame": "\(Int(sf.origin.x)),\(Int(sf.origin.y)) \(Int(sf.width))x\(Int(sf.height))",
            "targetFrame": "\(Int(tf.origin.x)),\(Int(tf.origin.y)) \(Int(tf.width))x\(Int(tf.height))",
            "xDelta": String(format: "%.1f", abs(sf.origin.x - tf.origin.x)),
            "yDelta": String(format: "%.1f", abs(sf.origin.y - tf.origin.y)),
            "wDelta": String(format: "%.1f", abs(sf.width - tf.width)),
            "hDelta": String(format: "%.1f", abs(sf.height - tf.height)),
            "strictFrameMatches": strictFrameMatches,
            "relaxedFrameMatch": relaxedTerminalFrameMatch,
            "frameMatches": frameMatches,
            "sessionMatches": sessionMatches,
            "titleMatches": titleMatches,
            "action": action.rawValue,
            "requiresReposition": requiresReposition
        ], runId: taskContext.runId)

        logRC10Diag(
            "quick-switch-tmux-preflight",
            runId: taskContext.runId,
            data: [
                "action": action.rawValue,
                "bundleId": bundleId,
                "currentSession": currentSessionName ?? "nil",
                "expectedPath": expectedPath ?? "nil",
                "frameMatches": frameMatches,
                "strictFrameMatches": strictFrameMatches,
                "relaxedTerminalFrameMatch": relaxedTerminalFrameMatch,
                "relaxedITermFrameMatch": relaxedTerminalFrameMatch,
                "hasSelectedClient": hasSelectedClient,
                "hasStrongManagedEvidence": hasStrongManagedEvidence,
                "hasSnapshotWindow": "true",
                "sessionMatches": sessionMatches,
                "sessionName": sessionName,
                "shouldSendCDCurrent": Self.shouldMutateExistingTmuxSessionPathForQuickSwitch(),
                "shouldSendCDTarget": Self.shouldMutateExistingTmuxSessionPathForQuickSwitch(),
                "targetSessionPath": "nil",
                "currentSessionPath": "nil",
                "titleMatches": titleMatches,
                "shouldSetIndexedTitle": shouldSetIndexedTitle,
                "tmuxIndex": tmuxIndex.map(String.init) ?? "nil",
                "windowId": snapshotWindow.windowId
            ]
        )

        if action == .bootstrap {
            return QuickSwitchTmuxPreflightDecision.disabled
        }

        return QuickSwitchTmuxPreflightDecision(
            action: action,
            shouldSwitchSession: requiresSwitch,
            shouldSetIndexedTitle: shouldSetIndexedTitle,
            shouldRepositionWindow: requiresReposition
        )
    }
}
