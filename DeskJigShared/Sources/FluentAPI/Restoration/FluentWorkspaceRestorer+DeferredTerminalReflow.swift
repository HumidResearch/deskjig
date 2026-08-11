//  FluentWorkspaceRestorer+DeferredTerminalReflow.swift
//  DeskJigShared

import Foundation
import CoreGraphics

extension FluentWorkspaceRestorer {

    private struct DeferredTerminalReflowTarget {
        let workspaceWindow: WorkspaceWindow
        var targetFrame: CGRect
        let expectedIndexedTitle: String?
    }

    struct DeferredTerminalReflowResult {
        let applied: Bool
        let movedWindowIds: Set<CGWindowID>
        let unresolvedWindowIds: Set<UUID>
        let durationMs: Int
    }

    func runDeferredTerminalReflowPass(
        runId: String,
        workspace: Workspace,
        currentScreens: [FullScreenInfo],
        lockTimeout: Duration,
        triggerReason: String
    ) async -> DeferredTerminalReflowResult {
        let startedAt = Date()
        let initialTargets = buildDeferredTerminalReflowTargets(
            workspace: workspace,
            currentScreens: currentScreens
        )
        let targets = await prepareDeferredTerminalReflowTargets(
            targets: initialTargets,
            runId: runId
        )

        guard !targets.isEmpty else {
            DeskJigLog.trace(
                .restorationPostRestore,
                "RC10_DIAG deferred-terminal-reflow-skipped reason=no-targets triggerReason=\(triggerReason)",
                runId: runId
            )
            return DeferredTerminalReflowResult(
                applied: false,
                movedWindowIds: [],
                unresolvedWindowIds: [],
                durationMs: 0
            )
        }

        DeskJigLog.trace(
            .restorationPostRestore,
            "RC10_DIAG deferred-terminal-reflow-start triggerReason=\(triggerReason) targetCount=\(targets.count)",
            runId: runId
        )

        let positioningService = WindowPositioningService(
            lockManager: lockManager,
            defaultLockTimeout: lockTimeout
        )
        let maxPasses = 2
        var unresolvedWindowIds = Set(targets.map(\.workspaceWindow.id))
        var movedWindowIds = Set<CGWindowID>()

        for pass in 1...maxPasses {
            guard !unresolvedWindowIds.isEmpty else { break }

            let snapshot = await SystemSnapshotCapture.captureQuick(runId: runId)
            var claimedWindowIds = Set<CGWindowID>()
            var nextUnresolved = Set<UUID>()
            var passMovedWindowIds: [CGWindowID] = []

            for target in targets where unresolvedWindowIds.contains(target.workspaceWindow.id) {
                guard let selectedWindow = selectDeferredTerminalCandidate(
                    for: target,
                    in: snapshot,
                    claimedWindowIds: claimedWindowIds
                ) else {
                    nextUnresolved.insert(target.workspaceWindow.id)
                    continue
                }
                claimedWindowIds.insert(selectedWindow.windowId)

                let taskContext = RestorationTaskContext(
                    taskId: "deferred-reflow-\(target.workspaceWindow.id.uuidString.prefix(8))-p\(pass)",
                    taskType: .terminal,
                    runId: runId
                )
                let result = await positioningService.positionSnapshotWindow(
                    snapshotWindow: selectedWindow,
                    targetFrame: target.targetFrame,
                    taskContext: taskContext,
                    requesterId: taskContext.taskId,
                    lockPriority: .high,
                    useWindowLocks: false,
                    lockTimeout: lockTimeout,
                    preferredStrategy: .frameOnly,
                    applyClampCompensation: false
                )

                if result.success {
                    movedWindowIds.insert(selectedWindow.windowId)
                    passMovedWindowIds.append(selectedWindow.windowId)
                }

                let matchesTarget: Bool
                if let finalFrame = result.finalFrame {
                    matchesTarget =
                        Self.framesMatch(finalFrame, target.targetFrame, tolerance: 12) ||
                        WindowLayoutFrameMatcher.matchesLayout(
                            actualFrame: finalFrame,
                            targetFrame: target.targetFrame,
                            screens: currentScreens
                        )
                } else {
                    matchesTarget = result.matchesTarget
                }

                if !(result.success && matchesTarget) {
                    nextUnresolved.insert(target.workspaceWindow.id)
                }
            }

            unresolvedWindowIds = nextUnresolved
            DeskJigLog.trace(
                .restorationPostRestore,
                "RC10_DIAG deferred-terminal-reflow-pass pass=\(pass) movedCount=\(passMovedWindowIds.count) unresolvedCount=\(unresolvedWindowIds.count) movedWindowIds=\(passMovedWindowIds.map(String.init).joined(separator: ","))",
                runId: runId
            )

            if !unresolvedWindowIds.isEmpty, pass < maxPasses {
                guard await Task.sleepUnlessCancelled(nanoseconds: 200_000_000) else { break }
            }
        }

        let durationMs = max(0, Int(Date().timeIntervalSince(startedAt) * 1000))
        DeskJigLog.trace(
            .restorationPostRestore,
            "RC10_DIAG deferred-terminal-reflow-complete movedCount=\(movedWindowIds.count) unresolvedCount=\(unresolvedWindowIds.count) totalMs=\(durationMs) unresolvedWindowIds=\(unresolvedWindowIds.map { $0.uuidString }.joined(separator: ","))",
            runId: runId
        )

        return DeferredTerminalReflowResult(
            applied: true,
            movedWindowIds: movedWindowIds,
            unresolvedWindowIds: unresolvedWindowIds,
            durationMs: durationMs
        )
    }

    private func buildDeferredTerminalReflowTargets(
        workspace: Workspace,
        currentScreens: [FullScreenInfo]
    ) -> [DeferredTerminalReflowTarget] {
        var targets: [DeferredTerminalReflowTarget] = []
        var tmuxIndexCounterByBundle: [String: Int] = [:]

        for window in workspace.windows where BundleRegistry.isTerminal(window.bundleIdentifier) {
            guard let relativeFrame = window.relativeFrame,
                  let screenIndex = window.screenIndex,
                  screenIndex >= 0,
                  screenIndex < currentScreens.count else {
                continue
            }

            let targetFrame = WindowFrameConverter.toAbsolute(
                relativeFrame: relativeFrame,
                screen: currentScreens[screenIndex],
                allScreens: currentScreens
            )

            var expectedIndexedTitle: String?
            if window.tmuxState != nil {
                let index = tmuxIndexCounterByBundle[window.bundleIdentifier, default: 0]
                tmuxIndexCounterByBundle[window.bundleIdentifier] = index + 1
                expectedIndexedTitle = BundleRegistry.managedTmuxWindowTitle(
                    bundleId: window.bundleIdentifier,
                    index: index
                )
            }

            targets.append(
                DeferredTerminalReflowTarget(
                    workspaceWindow: window,
                    targetFrame: targetFrame,
                    expectedIndexedTitle: expectedIndexedTitle
                )
            )
        }

        return targets
    }

    private func prepareDeferredTerminalReflowTargets(
        targets: [DeferredTerminalReflowTarget],
        runId: String
    ) async -> [DeferredTerminalReflowTarget] {
        let clampedFrames = Self.latestDeferredReflowClampedFrames(
            await lockManager.getClampedFrames(for: runId)
        )
        guard !clampedFrames.isEmpty else { return targets }

        var adjustedTargets = targets
        var compensationAdjustedCount = 0

        for index in adjustedTargets.indices {
            let originalTarget = adjustedTargets[index].targetFrame
            var compensatedTarget = originalTarget
            for clampedFrame in clampedFrames {
                compensatedTarget = WindowPositioningService.compensatedFrame(
                    for: compensatedTarget,
                    clampedOriginal: clampedFrame.originalTarget,
                    clampedActual: clampedFrame.actualFrame
                )
            }

            if !Self.framesMatch(originalTarget, compensatedTarget, tolerance: 0.5) {
                adjustedTargets[index].targetFrame = compensatedTarget
                compensationAdjustedCount += 1
            }
        }

        let redistributedCount = Self.redistributeDeferredTerminalRows(
            baselineTargets: targets,
            adjustedTargets: &adjustedTargets
        )

        DeskJigLog.trace(
            .restorationPostRestore,
            "RC10_DIAG deferred-terminal-reflow-target-prep clampedFrameCount=\(clampedFrames.count) compensationAdjustedCount=\(compensationAdjustedCount) redistributedCount=\(redistributedCount)",
            runId: runId
        )

        return adjustedTargets
    }

    private static func latestDeferredReflowClampedFrames(
        _ clampedFrames: [WindowLockManager.ClampedFrame]
    ) -> [WindowLockManager.ClampedFrame] {
        guard !clampedFrames.isEmpty else { return [] }

        var anonymousFrames: [WindowLockManager.ClampedFrame] = []
        var latestByWindowId: [CGWindowID: WindowLockManager.ClampedFrame] = [:]
        var orderedWindowIds: [CGWindowID] = []

        for clampedFrame in clampedFrames {
            guard let windowId = clampedFrame.windowId else {
                anonymousFrames.append(clampedFrame)
                continue
            }
            if latestByWindowId[windowId] == nil {
                orderedWindowIds.append(windowId)
            }
            latestByWindowId[windowId] = clampedFrame
        }

        let perWindowFrames = orderedWindowIds.compactMap { latestByWindowId[$0] }
        return anonymousFrames + perWindowFrames
    }

    private static func redistributeDeferredTerminalRows(
        baselineTargets: [DeferredTerminalReflowTarget],
        adjustedTargets: inout [DeferredTerminalReflowTarget]
    ) -> Int {
        guard baselineTargets.count == adjustedTargets.count else { return 0 }

        let baselineFrames = baselineTargets.map(\.targetFrame)
        let adjustedFrames = adjustedTargets.map(\.targetFrame)
        let screenIndices = adjustedTargets.map(\.workspaceWindow.screenIndex)
        let redistributedFrames = Self.redistributeDeferredTerminalRowFrames(
            baselineFrames: baselineFrames,
            adjustedFrames: adjustedFrames,
            screenIndices: screenIndices
        )

        var redistributedCount = 0
        for index in adjustedTargets.indices {
            let redistributedFrame = redistributedFrames[index]
            if !framesMatch(redistributedFrame, adjustedTargets[index].targetFrame, tolerance: 0.5) {
                adjustedTargets[index].targetFrame = redistributedFrame
                redistributedCount += 1
            }
        }
        return redistributedCount
    }

    static func redistributeDeferredTerminalRowFrames(
        baselineFrames: [CGRect],
        adjustedFrames: [CGRect],
        screenIndices: [Int?]
    ) -> [CGRect] {
        guard baselineFrames.count == adjustedFrames.count,
              adjustedFrames.count == screenIndices.count else {
            return adjustedFrames
        }

        let yTolerance: CGFloat = 5
        var redistributedFrames = adjustedFrames
        var visited = Set<Int>()

        for index in redistributedFrames.indices {
            guard !visited.contains(index) else { continue }
            visited.insert(index)

            let anchorBaseline = baselineFrames[index]
            let anchorScreenIndex = screenIndices[index]
            let rowIndices = redistributedFrames.indices.filter { candidateIndex in
                guard screenIndices[candidateIndex] == anchorScreenIndex else {
                    return false
                }
                let candidateBaseline = baselineFrames[candidateIndex]
                return abs(candidateBaseline.minY - anchorBaseline.minY) < yTolerance &&
                       abs(candidateBaseline.maxY - anchorBaseline.maxY) < yTolerance
            }

            rowIndices.forEach { visited.insert($0) }
            guard rowIndices.count > 1 else { continue }

            let rowWasCompensated = rowIndices.contains { rowIndex in
                !framesMatch(
                    baselineFrames[rowIndex],
                    redistributedFrames[rowIndex],
                    tolerance: 0.5
                )
            }
            guard rowWasCompensated else { continue }

            let totalBaselineWidth = rowIndices.reduce(CGFloat(0)) { partial, rowIndex in
                partial + baselineFrames[rowIndex].width
            }
            let availableWidth = rowIndices.reduce(CGFloat(0)) { partial, rowIndex in
                partial + redistributedFrames[rowIndex].width
            }
            let rowMinX = rowIndices.reduce(CGFloat.greatestFiniteMagnitude) { partial, rowIndex in
                min(partial, baselineFrames[rowIndex].minX)
            }

            guard totalBaselineWidth > 0, availableWidth > 0, rowMinX.isFinite else { continue }

            let sortedRowIndices = rowIndices.sorted {
                baselineFrames[$0].minX < baselineFrames[$1].minX
            }

            var currentX = rowMinX
            for (offset, rowIndex) in sortedRowIndices.enumerated() {
                let proportion = baselineFrames[rowIndex].width / totalBaselineWidth
                var newWidth = round(proportion * availableWidth)
                if offset == sortedRowIndices.count - 1 {
                    newWidth = max(1, (rowMinX + availableWidth) - currentX)
                }

                redistributedFrames[rowIndex].origin.x = currentX
                redistributedFrames[rowIndex].size.width = max(1, newWidth)
                currentX += newWidth
            }
        }

        return redistributedFrames
    }

    private func selectDeferredTerminalCandidate(
        for target: DeferredTerminalReflowTarget,
        in snapshot: SystemSnapshot,
        claimedWindowIds: Set<CGWindowID>
    ) -> SnapshotWindow? {
        let bundleCandidates = snapshot.windows.filter { window in
            window.bundleId == target.workspaceWindow.bundleIdentifier &&
            !claimedWindowIds.contains(window.windowId)
        }
        guard !bundleCandidates.isEmpty else { return nil }

        let axCandidates = bundleCandidates.filter { $0.isAXAccessible != false }
        let candidatePool = axCandidates.isEmpty ? bundleCandidates : axCandidates

        let indexedCandidates: [SnapshotWindow]
        if let expectedIndexedTitle = target.expectedIndexedTitle?.lowercased() {
            indexedCandidates = candidatePool.filter { window in
                (window.title ?? "").lowercased().contains(expectedIndexedTitle)
            }
        } else {
            indexedCandidates = []
        }

        if let indexedMatch = Self.sortDeferredTerminalCandidates(indexedCandidates).first {
            return indexedMatch
        }

        return Self.sortDeferredTerminalCandidates(candidatePool).first
    }

    private static func sortDeferredTerminalCandidates(_ candidates: [SnapshotWindow]) -> [SnapshotWindow] {
        candidates.sorted { lhs, rhs in
            let lhsAXRank = lhs.isAXAccessible == true ? 0 : 1
            let rhsAXRank = rhs.isAXAccessible == true ? 0 : 1
            if lhsAXRank != rhsAXRank {
                return lhsAXRank < rhsAXRank
            }

            let lhsZ = lhs.zOrderIndex ?? Int.max
            let rhsZ = rhs.zOrderIndex ?? Int.max
            if lhsZ != rhsZ {
                return lhsZ < rhsZ
            }

            return lhs.windowId < rhs.windowId
        }
    }

    private static func framesMatch(_ lhs: CGRect, _ rhs: CGRect, tolerance: CGFloat) -> Bool {
        abs(lhs.origin.x - rhs.origin.x) <= tolerance &&
        abs(lhs.origin.y - rhs.origin.y) <= tolerance &&
        abs(lhs.width - rhs.width) <= tolerance &&
        abs(lhs.height - rhs.height) <= tolerance
    }
}
