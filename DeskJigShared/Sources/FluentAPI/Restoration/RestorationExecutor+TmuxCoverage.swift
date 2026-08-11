//  RestorationExecutor+TmuxCoverage.swift
//  DeskJigShared

import Foundation
import CoreGraphics
import AppKit

extension RestorationExecutor {

    // MARK: - Tmux Index Coverage

    func bootstrapMissingTmuxIndexIfNeeded(
        task: RestorationTask,
        snapshot: EnhancedSnapshot,
        targetFrame: CGRect,
        taskContext: RestorationTaskContext,
        startTime: Date,
        phase: String,
        allowRetryLaunch: Bool = true
    ) async -> TaskResult? {
        guard tmuxIndexEnforcementPolicy == .strictCoverage,
              let tmuxIndex = task.tmuxManagedIndex,
              let tmuxState = task.workspaceWindow.tmuxState else {
            return nil
        }

        let bundleId = task.workspaceWindow.bundleIdentifier
        let expectedWindowCount = max(expectedTmuxWindowCount(for: bundleId), 1)
        if shouldSkipTmuxIndexCoverageEnforcement(
            bundleId: bundleId,
            expectedWindowCount: expectedWindowCount
        ) {
            DeskJigLog.trace(.restorationTrace, "Skipping tmux index coverage enforcement for quick-switch single-window bundle", fields: [
                "taskId": taskContext.taskId,
                "bundleId": bundleId,
                "tmuxIndex": tmuxIndex,
                "phase": phase,
                "expectedWindowCount": expectedWindowCount
            ], runId: taskContext.runId)
            return nil
        }

        let preflightVisibilityReadStart = Date()
        let visibilityState = await waitForManagedTmuxIndexVisibility(
            bundleId: bundleId,
            index: tmuxIndex,
            runId: taskContext.runId,
            timeoutMs: 700,
            pollMs: 150
        )
        let preflightVisibilityReadMs = max(0, Int(Date().timeIntervalSince(preflightVisibilityReadStart) * 1000))
        var topologyUnavailable = false
        switch visibilityState {
        case .visible:
            return nil
        case .topologyUnavailable(let bundleWindowCount):
            topologyUnavailable = true
            DeskJigLog.debug(.restorationTrace, "Skipping tmux index bootstrap - indexed topology unavailable", fields: [
                "taskId": taskContext.taskId,
                "reason": "indexed-topology-unavailable",
                "bundleId": bundleId,
                "tmuxIndex": tmuxIndex,
                "phase": phase,
                "bundleWindowCount": bundleWindowCount,
                "expectedWindowCount": expectedWindowCount,
                "topologyUnavailable": "true",
                "repairBudgetMs": "\(tmuxRepairBudgetSpentMs(for: bundleId))/\(tmuxRepairBudgetLimitMs)",
                "topologyReadMs": preflightVisibilityReadMs
            ], runId: taskContext.runId)
            if bundleWindowCount >= expectedWindowCount,
               await attemptTmuxIndexCoverageRepair(
                task: task,
                missingIndex: tmuxIndex,
                snapshot: snapshot.base,
                taskContext: taskContext,
                phase: "\(phase)-topology-unavailable"
               ) {
                return nil
            }
        case .missing:
            if await attemptTmuxIndexCoverageRepair(
                task: task,
                missingIndex: tmuxIndex,
                snapshot: snapshot.base,
                taskContext: taskContext,
                phase: phase
            ) {
                return nil
            }
        }

        let postRepairVisibilityReadStart = Date()
        let postRepairVisibilityState = await waitForManagedTmuxIndexVisibility(
            bundleId: bundleId,
            index: tmuxIndex,
            runId: taskContext.runId,
            timeoutMs: 850,
            pollMs: 150
        )
        let postRepairVisibilityReadMs = max(0, Int(Date().timeIntervalSince(postRepairVisibilityReadStart) * 1000))
        var postRepairTopologyWindowCount: Int?
        switch postRepairVisibilityState {
        case .visible:
            return nil
        case .topologyUnavailable(let bundleWindowCount):
            topologyUnavailable = true
            postRepairTopologyWindowCount = bundleWindowCount
        case .missing:
            break
        }

        if let bundleWindowCount = postRepairTopologyWindowCount,
           bundleWindowCount >= expectedWindowCount {
            DeskJigLog.debug(.restorationTrace, "Suppressing tmux index bootstrap launch", fields: [
                "taskId": taskContext.taskId,
                "reason": TmuxIndexTraceReason.indexCoverageBootstrap.rawValue,
                "bundleId": bundleId,
                "tmuxIndex": tmuxIndex,
                "phase": phase,
                "topologyUnavailable": "true",
                "bundleWindowCount": bundleWindowCount,
                "expectedWindowCount": expectedWindowCount,
                "repairBudgetMs": "\(tmuxRepairBudgetSpentMs(for: bundleId))/\(tmuxRepairBudgetLimitMs)",
                "bootstrapCount": tmuxBootstrapCount(bundleId: bundleId, index: tmuxIndex),
                "bootstrapSuppressedReason": "topology-unavailable-sufficient-windows",
                "topologyReadMs": preflightVisibilityReadMs,
                "postRepairTopologyReadMs": postRepairVisibilityReadMs
            ], runId: taskContext.runId)
            return nil
        }

        if let suppressedReason = shouldSuppressBootstrapLaunch(
            bundleId: bundleId,
            index: tmuxIndex,
            allowRetryLaunch: allowRetryLaunch
        ) {
            DeskJigLog.debug(.restorationTrace, "Suppressing tmux index bootstrap launch", fields: [
                "taskId": taskContext.taskId,
                "reason": TmuxIndexTraceReason.indexCoverageBootstrap.rawValue,
                "bundleId": bundleId,
                "tmuxIndex": tmuxIndex,
                "phase": phase,
                "topologyUnavailable": topologyUnavailable,
                "repairBudgetMs": "\(tmuxRepairBudgetSpentMs(for: bundleId))/\(tmuxRepairBudgetLimitMs)",
                "bootstrapCount": tmuxBootstrapCount(bundleId: bundleId, index: tmuxIndex),
                "bootstrapSuppressedReason": suppressedReason,
                "topologyReadMs": preflightVisibilityReadMs,
                "postRepairTopologyReadMs": postRepairVisibilityReadMs
            ], runId: taskContext.runId)
            return nil
        }

        let path = task.workspaceWindow.openPath ?? tmuxState.initialWorkingDirectory
        markTmuxBootstrapLaunch(bundleId: bundleId, index: tmuxIndex)
        DeskJigLog.debug(.restorationTrace, "Missing indexed managed title after switch/launch - bootstrapping index coverage", fields: [
            "taskId": taskContext.taskId,
            "reason": TmuxIndexTraceReason.indexCoverageBootstrap.rawValue,
            "decisionPath": TmuxIndexDecisionPath.bootstrapMissingIndex.rawValue,
            "bundleId": bundleId,
            "tmuxIndex": tmuxIndex,
            "indexedTitle": BundleRegistry.managedTmuxWindowTitle(bundleId: bundleId, index: tmuxIndex),
            "phase": phase,
            "path": path,
            "topologyUnavailable": topologyUnavailable,
            "repairBudgetMs": "\(tmuxRepairBudgetSpentMs(for: bundleId))/\(tmuxRepairBudgetLimitMs)",
            "bootstrapCount": tmuxBootstrapCount(bundleId: bundleId, index: tmuxIndex),
            "bootstrapSuppressedReason": "none",
            "topologyReadMs": preflightVisibilityReadMs,
            "postRepairTopologyReadMs": postRepairVisibilityReadMs
        ], runId: taskContext.runId)

        return await executeLaunchTerminalWithTmux(
            task: task,
            tmuxState: tmuxState,
            path: path,
            snapshot: snapshot,
            taskContext: taskContext,
            targetFrame: targetFrame,
            startTime: startTime,
            allowBootstrapRetry: allowRetryLaunch
        )
    }

    private func attemptTmuxIndexCoverageRepair(
        task: RestorationTask,
        missingIndex: Int,
        snapshot: SystemSnapshot,
        taskContext: RestorationTaskContext,
        phase: String
    ) async -> Bool {
        guard tmuxIndexEnforcementPolicy == .strictCoverage,
              let tmux = tmuxCommandService,
              let tmuxState = task.workspaceWindow.tmuxState else {
            return false
        }

        let bundleId = task.workspaceWindow.bundleIdentifier
        let repairBudgetSpentMs = tmuxRepairBudgetSpentMs(for: bundleId)
        guard repairBudgetSpentMs < tmuxRepairBudgetLimitMs else {
            DeskJigLog.debug(.restorationTrace, "tmux index coverage repair skipped (budget exhausted)", fields: [
                "taskId": taskContext.taskId,
                "reason": TmuxIndexTraceReason.indexCoverageRepairFailed.rawValue,
                "bundleId": bundleId,
                "missingIndex": missingIndex,
                "phase": phase,
                "failureReason": "repair-budget-exhausted",
                "repairBudgetMs": "\(repairBudgetSpentMs)/\(tmuxRepairBudgetLimitMs)"
            ], runId: taskContext.runId)
            return false
        }
        let repairStart = Date()
        defer {
            recordTmuxRepairBudget(bundleId: bundleId, startedAt: repairStart)
        }

        let expectedIndices = tmuxExpectedIndicesByBundle[bundleId] ?? [missingIndex]
        let bundleWindows = snapshot.windows
            .filter { $0.bundleId == bundleId && $0.isAXAccessible != false }
        let topology = TmuxManagedIndexTopology(
            bundleId: bundleId,
            expectedIndices: expectedIndices,
            windows: bundleWindows
        )

        let expectedWindowCount = max(expectedIndices.count, 1)
        let hasEnoughWindowsForRepair = bundleWindows.count >= expectedWindowCount
        let selectedRepairWindowId = selectRepairWindowId(
            task: task,
            topology: topology,
            bundleWindows: bundleWindows
        )

        DeskJigLog.debug(.restorationTrace, "tmux index coverage repair attempt", fields: [
            "taskId": taskContext.taskId,
            "reason": TmuxIndexTraceReason.indexCoverageRepairAttempt.rawValue,
            "bundleId": bundleId,
            "missingIndex": missingIndex,
            "phase": phase,
            "expectedIndices": topology.expectedIndicesDescription,
            "observedIndices": topology.observedIndicesDescription,
            "missingIndices": topology.missingIndicesDescription,
            "duplicateIndices": topology.duplicateIndicesDescription,
            "bundleWindowCount": bundleWindows.count,
            "expectedWindowCount": expectedWindowCount,
            "selectedRepairWindowId": selectedRepairWindowId.map { "\($0)" } ?? "nil",
            "topologyUnavailable": topology.observedIndices.isEmpty && !bundleWindows.isEmpty,
            "repairBudgetMs": "\(repairBudgetSpentMs)/\(tmuxRepairBudgetLimitMs)"
        ], runId: taskContext.runId)

        if !topology.missingIndices.contains(missingIndex) {
            DeskJigLog.debug(.restorationTrace, "tmux index coverage repair already satisfied", fields: [
                "taskId": taskContext.taskId,
                "reason": TmuxIndexTraceReason.indexCoverageRepairRecovered.rawValue,
                "bundleId": bundleId,
                "missingIndex": missingIndex,
                "phase": phase
            ], runId: taskContext.runId)
            return true
        }

        guard hasEnoughWindowsForRepair else {
            DeskJigLog.debug(.restorationTrace, "tmux index coverage repair skipped (insufficient windows)", fields: [
                "taskId": taskContext.taskId,
                "reason": TmuxIndexTraceReason.indexCoverageRepairFailed.rawValue,
                "bundleId": bundleId,
                "missingIndex": missingIndex,
                "phase": phase,
                "bundleWindowCount": bundleWindows.count,
                "expectedWindowCount": expectedWindowCount,
                "failureReason": "insufficient-windows",
                "repairBudgetMs": "\(repairBudgetSpentMs)/\(tmuxRepairBudgetLimitMs)"
            ], runId: taskContext.runId)
            return false
        }

        let clients: [TmuxClientInfo]
        do {
            clients = try await tmux.listClients()
        } catch {
            DeskJigLog.debug(.restorationTrace, "tmux index coverage repair skipped (list-clients failed)", fields: [
                "taskId": taskContext.taskId,
                "reason": TmuxIndexTraceReason.indexCoverageRepairFailed.rawValue,
                "bundleId": bundleId,
                "missingIndex": missingIndex,
                "phase": phase,
                "failureReason": "list-clients-error",
                "error": error.localizedDescription,
                "repairBudgetMs": "\(repairBudgetSpentMs)/\(tmuxRepairBudgetLimitMs)"
            ], runId: taskContext.runId)
            return false
        }
        guard !clients.isEmpty else {
            DeskJigLog.debug(.restorationTrace, "tmux index coverage repair skipped (no clients)", fields: [
                "taskId": taskContext.taskId,
                "reason": TmuxIndexTraceReason.indexCoverageRepairFailed.rawValue,
                "bundleId": bundleId,
                "missingIndex": missingIndex,
                "phase": phase,
                "failureReason": "no-clients",
                "repairBudgetMs": "\(repairBudgetSpentMs)/\(tmuxRepairBudgetLimitMs)"
            ], runId: taskContext.runId)
            return false
        }

        let requestedSnapshotWindow = selectedRepairWindowId.flatMap { windowId in
            bundleWindows.first(where: { $0.windowId == windowId })
        }
        let clientSelection = await selectTmuxClientForWindow(
            bundleId: bundleId,
            plannedWindowId: selectedRepairWindowId,
            requestedSnapshotWindow: requestedSnapshotWindow,
            clients: clients,
            snapshot: snapshot,
            taskContext: taskContext,
            sessionName: tmuxState.sessionName,
            launchSource: config.launchSource
        )

        guard let selectedClient = clientSelection?.client else {
            DeskJigLog.debug(.restorationTrace, "tmux index coverage repair could not select client", fields: [
                "taskId": taskContext.taskId,
                "reason": TmuxIndexTraceReason.indexCoverageRepairFailed.rawValue,
                "bundleId": bundleId,
                "missingIndex": missingIndex,
                "phase": phase,
                "failureReason": "no-client-selection",
                "selectedRepairWindowId": selectedRepairWindowId.map { "\($0)" } ?? "nil",
                "repairBudgetMs": "\(repairBudgetSpentMs)/\(tmuxRepairBudgetLimitMs)"
            ], runId: taskContext.runId)
            return false
        }

        do {
            try await tmux.switchClient(clientTTY: selectedClient.clientTTY, toSession: tmuxState.sessionName)
        } catch {
            DeskJigLog.debug(.restorationTrace, "tmux index coverage repair switch-client failed", fields: [
                "taskId": taskContext.taskId,
                "reason": TmuxIndexTraceReason.indexCoverageRepairFailed.rawValue,
                "bundleId": bundleId,
                "missingIndex": missingIndex,
                "phase": phase,
                "failureReason": "switch-client-failed",
                "clientTTY": selectedClient.clientTTY,
                "targetSession": tmuxState.sessionName,
                "error": error.localizedDescription,
                "repairBudgetMs": "\(repairBudgetSpentMs)/\(tmuxRepairBudgetLimitMs)"
            ], runId: taskContext.runId)
            return false
        }

        let indexedTitle = BundleRegistry.managedTmuxWindowTitle(bundleId: bundleId, index: missingIndex)
        do {
            try await setIndexedPaneTitleIfNeeded(tmux: tmux, session: tmuxState.sessionName, title: indexedTitle)
        } catch {
            DeskJigLog.debug(.restorationTrace, "tmux index coverage repair title set failed", fields: [
                "taskId": taskContext.taskId,
                "reason": TmuxIndexTraceReason.indexCoverageRepairFailed.rawValue,
                "bundleId": bundleId,
                "missingIndex": missingIndex,
                "phase": phase,
                "failureReason": "set-title-failed",
                "targetSession": tmuxState.sessionName,
                "title": indexedTitle,
                "error": error.localizedDescription,
                "repairBudgetMs": "\(repairBudgetSpentMs)/\(tmuxRepairBudgetLimitMs)"
            ], runId: taskContext.runId)
        }

        let visibilityState = await waitForManagedTmuxIndexVisibility(
            bundleId: bundleId,
            index: missingIndex,
            runId: taskContext.runId,
            timeoutMs: 650,
            pollMs: 150
        )

        switch visibilityState {
        case .visible:
            DeskJigLog.debug(.restorationTrace, "tmux index coverage repair recovered", fields: [
                "taskId": taskContext.taskId,
                "reason": TmuxIndexTraceReason.indexCoverageRepairRecovered.rawValue,
                "bundleId": bundleId,
                "missingIndex": missingIndex,
                "phase": phase,
                "clientTTY": selectedClient.clientTTY,
                "selectionReason": clientSelection?.reason ?? "none",
                "repairBudgetMs": "\(repairBudgetSpentMs)/\(tmuxRepairBudgetLimitMs)"
            ], runId: taskContext.runId)
            return true
        case .topologyUnavailable(let bundleWindowCount):
            DeskJigLog.debug(.restorationTrace, "tmux index coverage repair inconclusive (topology unavailable)", fields: [
                "taskId": taskContext.taskId,
                "reason": TmuxIndexTraceReason.indexCoverageRepairRecovered.rawValue,
                "bundleId": bundleId,
                "missingIndex": missingIndex,
                "phase": phase,
                "clientTTY": selectedClient.clientTTY,
                "selectionReason": clientSelection?.reason ?? "none",
                "bundleWindowCount": bundleWindowCount,
                "visibilityState": describeManagedTmuxVisibilityState(visibilityState),
                "topologyUnavailable": true,
                "repairBudgetMs": "\(repairBudgetSpentMs)/\(tmuxRepairBudgetLimitMs)"
            ], runId: taskContext.runId)
            return true
        case .missing:
            break
        }

        DeskJigLog.debug(.restorationTrace, "tmux index coverage repair failed", fields: [
            "taskId": taskContext.taskId,
            "reason": TmuxIndexTraceReason.indexCoverageRepairFailed.rawValue,
            "bundleId": bundleId,
            "missingIndex": missingIndex,
            "phase": phase,
            "clientTTY": selectedClient.clientTTY,
            "selectionReason": clientSelection?.reason ?? "none",
            "visibilityState": describeManagedTmuxVisibilityState(visibilityState),
            "repairBudgetMs": "\(repairBudgetSpentMs)/\(tmuxRepairBudgetLimitMs)"
        ], runId: taskContext.runId)
        return false
    }

    private func selectRepairWindowId(
        task: RestorationTask,
        topology: TmuxManagedIndexTopology,
        bundleWindows: [SnapshotWindow]
    ) -> CGWindowID? {
        if let plannedWindowId = task.decision.existingWindowId {
            return plannedWindowId
        }

        var duplicateExtras: [SnapshotWindow] = []
        for index in topology.duplicateIndices.sorted() {
            let sortedForIndex = topology.windows(for: index).sorted(by: Self.preferredSnapshotWindowOrder)
            if sortedForIndex.count > 1 {
                duplicateExtras.append(contentsOf: sortedForIndex.dropFirst())
            }
        }

        if let duplicateWindow = duplicateExtras.sorted(by: Self.preferredSnapshotWindowOrder).first {
            return duplicateWindow.windowId
        }

        return bundleWindows.sorted(by: Self.preferredSnapshotWindowOrder).first?.windowId
    }

    func describeManagedTmuxVisibilityState(_ state: ManagedTmuxIndexVisibilityState) -> String {
        switch state {
        case .visible:
            return "visible"
        case .missing:
            return "missing"
        case .topologyUnavailable(let bundleWindowCount):
            return "topology-unavailable(\(bundleWindowCount))"
        }
    }

    private static func preferredSnapshotWindowOrder(_ lhs: SnapshotWindow, _ rhs: SnapshotWindow) -> Bool {
        let lhsZ = lhs.zOrderIndex ?? Int.max
        let rhsZ = rhs.zOrderIndex ?? Int.max
        if lhsZ != rhsZ {
            return lhsZ < rhsZ
        }
        return lhs.windowId < rhs.windowId
    }

    enum ManagedTmuxIndexVisibilityState {
        case visible
        case missing
        case topologyUnavailable(bundleWindowCount: Int)
    }

    func waitForManagedTmuxIndexVisibility(
        bundleId: String,
        index: Int,
        runId: String,
        timeoutMs: Int = 1_600,
        pollMs: UInt64 = 200
    ) async -> ManagedTmuxIndexVisibilityState {
        let cacheMaxAgeMs = min(max(timeoutMs / 3, 120), 450)
        if let cached = cachedManagedVisibilityState(
            bundleId: bundleId,
            index: index,
            maxAgeMs: cacheMaxAgeMs
        ) {
            return cached
        }

        let deadline = Date().addingTimeInterval(Double(timeoutMs) / 1000.0)
        let expectedIndices: Set<Int> = [index]

        while Date() < deadline {
            let snapshot = await SystemSnapshotCapture.captureQuick(runId: runId)
            let bundleWindows = snapshot.windows.filter { $0.bundleId == bundleId }
            let topology = TmuxManagedIndexTopology(
                bundleId: bundleId,
                expectedIndices: expectedIndices,
                windows: bundleWindows
            )
            if topology.observedIndices.contains(index) {
                cacheManagedVisibilityState(bundleId: bundleId, index: index, state: .visible)
                return .visible
            }
            guard await Task.sleepUnlessCancelled(nanoseconds: pollMs * 1_000_000) else { break }
        }

        let finalSnapshot = await SystemSnapshotCapture.captureQuick(runId: runId)
        let finalBundleWindows = finalSnapshot.windows.filter { $0.bundleId == bundleId }
        let finalTopology = TmuxManagedIndexTopology(
            bundleId: bundleId,
            expectedIndices: expectedIndices,
            windows: finalBundleWindows
        )

        if finalTopology.observedIndices.contains(index) {
            let visible: ManagedTmuxIndexVisibilityState = .visible
            cacheManagedVisibilityState(bundleId: bundleId, index: index, state: visible)
            return visible
        }
        if finalTopology.observedIndices.isEmpty && !finalBundleWindows.isEmpty {
            let unavailable: ManagedTmuxIndexVisibilityState = .topologyUnavailable(bundleWindowCount: finalBundleWindows.count)
            cacheManagedVisibilityState(bundleId: bundleId, index: index, state: unavailable)
            return unavailable
        }

        let missing: ManagedTmuxIndexVisibilityState = .missing
        cacheManagedVisibilityState(bundleId: bundleId, index: index, state: missing)
        return missing
    }

    func reconcileTmuxManagedIndexCoverage(
        plan: RestorationPlan
    ) async -> [TaskResult] {
        guard tmuxIndexEnforcementPolicy == .strictCoverage else { return [] }
        let expectedIndicesByBundle = tmuxExpectedIndicesByBundle
        let tasksByBundleAndIndex = tmuxTaskByBundleAndIndex
        guard !expectedIndicesByBundle.isEmpty else { return [] }

        var reconciliationResults: [TaskResult] = []

        for bundleId in expectedIndicesByBundle.keys.sorted() {
            guard let expectedIndices = expectedIndicesByBundle[bundleId] else { continue }
            if shouldSkipTmuxIndexCoverageEnforcement(
                bundleId: bundleId,
                expectedWindowCount: expectedIndices.count
            ) {
                DeskJigLog.trace(.restorationTrace, "Skipping tmux index reconciliation for quick-switch single-window bundle", fields: [
                    "bundleId": bundleId,
                    "expectedIndices": expectedIndices.sorted().map(String.init).joined(separator: ",")
                ], runId: plan.runId)
                continue
            }
            // exec-07: scope the coverage snapshot to this bundle only. captureForBundle returns
            // identical windows for the bundle as captureQuick+filter (same CGWindowList titles,
            // same bundle-scoped AX zombie verification) while skipping the AX round-trips for
            // every other app's off-screen windows; the per-repair re-captures below stay scoped
            // too. Only this bundle's windows are ever read here and in attemptTmuxIndexCoverageRepair.
            var bundleSnapshot = await SystemSnapshotCapture.captureForBundle(bundleId: bundleId, runId: plan.runId)
            let bundleWindows = bundleSnapshot.windows
            var topology = TmuxManagedIndexTopology(
                bundleId: bundleId,
                expectedIndices: expectedIndices,
                windows: bundleWindows
            )

            DeskJigLog.trace(.restorationTrace, "tmux index topology reconciliation", fields: [
                "bundleId": bundleId,
                "expectedIndices": topology.expectedIndicesDescription,
                "observedIndices": topology.observedIndicesDescription,
                "missingIndices": topology.missingIndicesDescription,
                "duplicateIndices": topology.duplicateIndicesDescription
            ], runId: plan.runId)

            if topology.observedIndices.isEmpty && !bundleWindows.isEmpty {
                DeskJigLog.debug(.restorationTrace, "tmux index reconciliation skipped - indexed topology unavailable", fields: [
                    "bundleId": bundleId,
                    "expectedIndices": topology.expectedIndicesDescription,
                    "bundleWindowCount": bundleWindows.count,
                    "repairBudgetMs": "\(tmuxRepairBudgetSpentMs(for: bundleId))/\(tmuxRepairBudgetLimitMs)"
                ], runId: plan.runId)
                let canAttemptRepair = bundleWindows.count >= expectedIndices.count
                if canAttemptRepair,
                   tmuxRepairBudgetSpentMs(for: bundleId) < tmuxRepairBudgetLimitMs,
                   let repairIndex = expectedIndices.sorted().first,
                   let repairTask = tasksByBundleAndIndex[bundleId]?[repairIndex] {
                    let repairContext = RestorationTaskContext(
                        taskId: "\(repairTask.id)-reconcile-topology-\(repairIndex)",
                        taskType: .terminal,
                        runId: plan.runId
                    )
                    _ = await attemptTmuxIndexCoverageRepair(
                        task: repairTask,
                        missingIndex: repairIndex,
                        snapshot: bundleSnapshot,
                        taskContext: repairContext,
                        phase: "reconcile-topology-unavailable"
                    )

                    bundleSnapshot = await SystemSnapshotCapture.captureForBundle(bundleId: bundleId, runId: plan.runId)
                    let refreshedBundleWindows = bundleSnapshot.windows
                    topology = TmuxManagedIndexTopology(
                        bundleId: bundleId,
                        expectedIndices: expectedIndices,
                        windows: refreshedBundleWindows
                    )
                }

                // If indexed topology is still unavailable after repair attempts,
                // avoid bootstrap launches to prevent duplicate-window storms.
                if topology.observedIndices.isEmpty {
                    DeskJigLog.debug(.restorationTrace, "tmux index reconciliation deferred - topology still unavailable", fields: [
                        "bundleId": bundleId,
                        "bundleWindowCount": bundleWindows.count,
                        "expectedIndices": topology.expectedIndicesDescription,
                        "repairBudgetMs": "\(tmuxRepairBudgetSpentMs(for: bundleId))/\(tmuxRepairBudgetLimitMs)"
                    ], runId: plan.runId)
                    continue
                }
            }

            for missingIndex in topology.missingIndices.sorted() {
                if tmuxRepairBudgetSpentMs(for: bundleId) >= tmuxRepairBudgetLimitMs {
                    DeskJigLog.debug(.restorationTrace, "tmux index reconciliation repair budget exhausted", fields: [
                        "bundleId": bundleId,
                        "missingIndex": missingIndex,
                        "repairBudgetMs": "\(tmuxRepairBudgetSpentMs(for: bundleId))/\(tmuxRepairBudgetLimitMs)"
                    ], runId: plan.runId)
                    break
                }
                guard let task = tasksByBundleAndIndex[bundleId]?[missingIndex],
                      let tmuxState = task.workspaceWindow.tmuxState else {
                    continue
                }

                // Skip if this session was already claimed by a successful task.
                // The index appears "missing" only because the title hasn't propagated
                // from tmux to the terminal's AX title yet.
                let claimedSessions = tmuxClaimedSessionsByBundle[bundleId] ?? []
                if claimedSessions.contains(tmuxState.sessionName) {
                    DeskJigLog.debug(.restorationTrace, "tmux index reconciliation skipped — session already claimed", fields: [
                        "bundleId": bundleId,
                        "missingIndex": missingIndex,
                        "sessionName": tmuxState.sessionName,
                        "reason": "session-claimed-title-propagation-pending"
                    ], runId: plan.runId)
                    continue
                }

                let path = task.workspaceWindow.openPath ?? tmuxState.initialWorkingDirectory
                let context = RestorationTaskContext(
                    taskId: "\(task.id)-reconcile-\(missingIndex)",
                    taskType: .terminal,
                    runId: plan.runId
                )

                if await attemptTmuxIndexCoverageRepair(
                    task: task,
                    missingIndex: missingIndex,
                    snapshot: bundleSnapshot,
                    taskContext: context,
                    phase: "reconcile"
                ) {
                    bundleSnapshot = await SystemSnapshotCapture.captureForBundle(bundleId: bundleId, runId: plan.runId)
                    let refreshedBundleWindows = bundleSnapshot.windows
                    topology = TmuxManagedIndexTopology(
                        bundleId: bundleId,
                        expectedIndices: expectedIndices,
                        windows: refreshedBundleWindows
                    )
                    continue
                }

                if let suppressedReason = shouldSuppressBootstrapLaunch(
                    bundleId: bundleId,
                    index: missingIndex,
                    allowRetryLaunch: false
                ) {
                    DeskJigLog.debug(.restorationTrace, "tmux topology missing index bootstrap suppressed", fields: [
                        "taskId": context.taskId,
                        "reason": TmuxIndexTraceReason.indexCoverageBootstrap.rawValue,
                        "bundleId": bundleId,
                        "missingIndex": missingIndex,
                        "expectedIndices": topology.expectedIndicesDescription,
                        "observedIndices": topology.observedIndicesDescription,
                        "duplicateIndices": topology.duplicateIndicesDescription,
                        "repairBudgetMs": "\(tmuxRepairBudgetSpentMs(for: bundleId))/\(tmuxRepairBudgetLimitMs)",
                        "bootstrapCount": tmuxBootstrapCount(bundleId: bundleId, index: missingIndex),
                        "bootstrapSuppressedReason": suppressedReason
                    ], runId: context.runId)
                    continue
                }

                markTmuxBootstrapLaunch(bundleId: bundleId, index: missingIndex)
                DeskJigLog.debug(.restorationTrace, "tmux topology missing index bootstrap", fields: [
                    "taskId": context.taskId,
                    "reason": TmuxIndexTraceReason.missingIndexedManagedWindow.rawValue,
                    "decisionPath": TmuxIndexDecisionPath.bootstrapMissingIndex.rawValue,
                    "bundleId": bundleId,
                    "missingIndex": missingIndex,
                    "expectedIndices": topology.expectedIndicesDescription,
                    "observedIndices": topology.observedIndicesDescription,
                    "duplicateIndices": topology.duplicateIndicesDescription,
                    "repairBudgetMs": "\(tmuxRepairBudgetSpentMs(for: bundleId))/\(tmuxRepairBudgetLimitMs)",
                    "bootstrapCount": tmuxBootstrapCount(bundleId: bundleId, index: missingIndex),
                    "bootstrapSuppressedReason": "none"
                ], runId: context.runId)

                let bootstrapResult = await executeLaunchTerminalWithTmux(
                    task: task,
                    tmuxState: tmuxState,
                    path: path,
                    snapshot: plan.snapshot,
                    taskContext: context,
                    targetFrame: task.targetFrame,
                    startTime: Date(),
                    allowBootstrapRetry: false
                )
                reconciliationResults.append(bootstrapResult)

                bundleSnapshot = await SystemSnapshotCapture.captureForBundle(bundleId: bundleId, runId: plan.runId)
                let refreshedBundleWindows = bundleSnapshot.windows
                topology = TmuxManagedIndexTopology(
                    bundleId: bundleId,
                    expectedIndices: expectedIndices,
                    windows: refreshedBundleWindows
                )
            }

            if !topology.duplicateIndices.isEmpty {
                runTmuxDuplicateCleanupIfEligible(
                    bundleId: bundleId,
                    expectedIndices: expectedIndices,
                    runId: plan.runId
                )
            }
        }

        return reconciliationResults
    }

    private func runTmuxDuplicateCleanupIfEligible(
        bundleId: String,
        expectedIndices: Set<Int>,
        runId: String
    ) {
        guard bundleId == OpenByPathBundleIdentifiers.terminal ||
              bundleId == OpenByPathBundleIdentifiers.iterm2 else {
            return
        }

        let expectedTitles = expectedIndices
            .sorted()
            .map { BundleRegistry.managedTmuxWindowTitle(bundleId: bundleId, index: $0) }
        _ = FluentTerminalLauncher.closeExtraWindowsIfIdle(
            bundleId: bundleId,
            expectedTitles: expectedTitles,
            runId: runId
        )
    }
}
