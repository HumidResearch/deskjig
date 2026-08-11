//  RestorationExecutor+TerminalExecutors.swift
//  DeskJigShared

import Foundation
import CoreGraphics
import AppKit

extension RestorationExecutor {

    // MARK: - Terminal Decision Executors

    func makeTerminalBindingResult(
        task: RestorationTask,
        selectedWindowId: CGWindowID?,
        finalWindowId: CGWindowID?,
        selectedClientTTY: String?,
        wasLaunched: Bool
    ) -> TerminalBindingResult? {
        guard BundleRegistry.isTerminal(task.workspaceWindow.bundleIdentifier),
              task.workspaceWindow.tmuxState != nil else {
            return nil
        }

        let bindingPlan = task.tmuxBindingPlan
        return TerminalBindingResult(
            bundleId: task.workspaceWindow.bundleIdentifier,
            tmuxIndex: task.tmuxManagedIndex,
            selectedWindowId: selectedWindowId ?? bindingPlan?.selectedWindowId,
            finalWindowId: finalWindowId,
            selectedClientTTY: selectedClientTTY,
            sessionName: task.workspaceWindow.tmuxState?.sessionName,
            staleWindowIds: bindingPlan?.staleWindowIds ?? [],
            wasLaunched: wasLaunched,
            launchAllowed: bindingPlan?.launchAllowed ?? false
        )
    }

    func shouldAllowTmuxBootstrapLaunch(
        task: RestorationTask,
        snapshot: SystemSnapshot,
        bundleId: String,
        taskContext: RestorationTaskContext,
        phase: String
    ) async -> Bool {
        guard let bindingPlan = task.tmuxBindingPlan else { return true }

        // Trust the planner's decision. The planner has full visibility into
        // topology, client-backed coverage, and claimed windows. The executor
        // should not second-guess it — doing so causes failures during
        // cross-workspace switches where old sessions/windows persist.
        if bindingPlan.launchAllowed {
            DeskJigLog.debug(.restorationTrace, "tmux launch allowed — planner authorized", fields: [
                "taskId": taskContext.taskId,
                "bundleId": bundleId,
                "phase": phase,
                "tmuxIndex": bindingPlan.tmuxIndex,
                "evidence": bindingPlan.evidence.rawValue,
                "selectedWindowId": bindingPlan.selectedWindowId.map(String.init) ?? "nil"
            ], runId: taskContext.runId)
            return true
        }

        DeskJigLog.debug(.restorationTrace, "tmux launch suppressed — planner disallowed", fields: [
            "taskId": taskContext.taskId,
            "bundleId": bundleId,
            "phase": phase,
            "tmuxIndex": bindingPlan.tmuxIndex,
            "evidence": bindingPlan.evidence.rawValue,
            "selectedWindowId": bindingPlan.selectedWindowId.map(String.init) ?? "nil"
        ], runId: taskContext.runId)
        return false
    }

    func shouldForceBootstrapForMissingTargetClient(
        clients: [TmuxClientInfo],
        sessionName: String,
        task: RestorationTask
    ) -> Bool {
        guard config.launchSource == Self.quickSwitchLaunchSource,
              let tmuxState = task.workspaceWindow.tmuxState,
              tmuxState.sessionName == sessionName else {
            return false
        }

        return !clients.contains(where: { $0.sessionName == sessionName })
    }

    func resolvedTmuxBindingSnapshotWindow(
        for task: RestorationTask,
        snapshot: SystemSnapshot,
        plannedWindowId: CGWindowID
    ) -> TerminalWindowIdentityResolver.SnapshotResolution? {
        let bundleId = task.workspaceWindow.bundleIdentifier
        let bundleWindows = snapshot.windows.filter { $0.bundleId == bundleId }
        let preferredPath = task.workspaceWindow.openPath ?? task.workspaceWindow.tmuxState?.initialWorkingDirectory
        let preferredPID = snapshot.windows.first(where: { $0.windowId == plannedWindowId })?.pid
        return TerminalWindowIdentityResolver.resolveSnapshotWindow(
            bundleId: bundleId,
            plannedWindowId: task.tmuxBindingPlan?.selectedWindowId ?? plannedWindowId,
            preferredPID: preferredPID,
            preferredPath: preferredPath,
            preferredFrame: task.targetFrame,
            bundleWindows: bundleWindows
        )
    }

    private func finishTmuxReuseWithoutSwitch(
        task: RestorationTask,
        snapshotWindow: SnapshotWindow,
        selectedClientTTY: String?,
        reason: String,
        targetFrame: CGRect,
        taskContext: RestorationTaskContext,
        startTime: Date,
        plannedWindowId: CGWindowID
    ) async -> TaskResult {
        let preferredStrategy = WindowHandleResolver.preferredStrategy(
            workspaceWindow: task.workspaceWindow,
            snapshotWindow: snapshotWindow
        )
        let useWindowLocks = config.useWindowLocks && !task.hasLock
        let positioningResult = await positioningService.positionSnapshotWindow(
            snapshotWindow: snapshotWindow,
            targetFrame: targetFrame,
            taskContext: taskContext,
            requesterId: task.id,
            lockPriority: task.requiredPriority,
            useWindowLocks: useWindowLocks,
            lockTimeout: config.lockTimeout,
            preferredStrategy: preferredStrategy
        )

        let actualWindowId = positioningResult.resolvedWindowId ?? snapshotWindow.windowId
        var notes = ["tmux reuse without switch: \(reason)"]
        if !positioningResult.matchesTarget {
            notes.append(Self.frameMismatchNote)
        }

        return TaskResult(
            taskId: task.id,
            success: positioningResult.success,
            windowId: actualWindowId,
            decision: task.decision,
            durationMs: durationMs(from: startTime),
            notes: notes,
            lockAcquired: task.hasLock,
            plannedWindowId: actualWindowId != plannedWindowId ? plannedWindowId : nil,
            terminalBinding: makeTerminalBindingResult(
                task: task,
                selectedWindowId: plannedWindowId,
                finalWindowId: actualWindowId,
                selectedClientTTY: selectedClientTTY,
                wasLaunched: false
            )
        )
    }

    /// Logs a diagnostic message and finishes a tmux reuse path without performing a session switch.
    /// Used at multiple call sites where `shouldAllowTmuxBootstrapLaunch` denied the launch
    /// and the task should fall back to positioning an existing window.
    func handleTmuxReuseFailed(
        task: RestorationTask,
        snapshotWindow: SnapshotWindow,
        selectedClientTTY: String?,
        windowId: CGWindowID?,
        reason: String,
        targetFrame: CGRect,
        taskContext: RestorationTaskContext,
        startTime: Date,
        plannedWindowId: CGWindowID
    ) async -> TaskResult {
        DeskJigLog.debug(.restorationTrace, "Tmux reuse failed, launch denied by plan", fields: [
            "taskId": task.id,
            "bundleId": task.workspaceWindow.bundleIdentifier,
            "windowId": windowId.map { "\($0)" } ?? "nil",
            "sessionName": task.workspaceWindow.tmuxState?.sessionName ?? "nil",
            "reason": reason,
            "launchAllowed": "\(task.tmuxBindingPlan?.launchAllowed ?? true)"
        ], runId: taskContext.runId)
        return await finishTmuxReuseWithoutSwitch(
            task: task,
            snapshotWindow: snapshotWindow,
            selectedClientTTY: selectedClientTTY,
            reason: reason,
            targetFrame: targetFrame,
            taskContext: taskContext,
            startTime: startTime,
            plannedWindowId: plannedWindowId
        )
    }

    /// Configure tmux title propagation once per run (guarded by `titlePropagationConfigured`),
    /// then set the indexed pane title on `session`. Throws on tmux failure so each call site
    /// keeps its own do/catch + diagnostic logging.
    func setIndexedPaneTitleIfNeeded(
        tmux: TmuxCommandService,
        session: String,
        title: String
    ) async throws {
        if !titlePropagationConfigured {
            try await tmux.ensureTitlePropagation()
            titlePropagationConfigured = true
        }
        try await tmux.setPaneTitle(session: session, title: title)
    }

    /// Shared fallback for both switch paths: when positioning a managed/switched tmux window
    /// did not resolve, either deny the relaunch (returning a handleTmuxReuseFailed result) or
    /// fall back to launching the terminal with its tmux session. Returns nil when no fallback
    /// is warranted, so the caller proceeds to build its normal success result. The two call
    /// sites differ only in the phase/reason/log-message strings and the selected client TTY.
    func handleSwitchPositionFailureFallback(
        task: RestorationTask,
        positioningResult: WindowPositioningResult,
        snapshot: EnhancedSnapshot,
        snapshotWindow: SnapshotWindow,
        windowId: CGWindowID,
        sessionName: String,
        bundleId: String,
        selectedClientTTY: String?,
        targetFrame: CGRect,
        taskContext: RestorationTaskContext,
        startTime: Date,
        phase: String,
        denialReason: String,
        fallbackLogMessage: String
    ) async -> TaskResult? {
        guard Self.shouldFallbackToTmuxLaunchAfterSwitchPositionFailure(
            positioningSucceeded: positioningResult.success,
            finalFramePresent: positioningResult.finalFrame != nil,
            hasTmuxState: task.workspaceWindow.tmuxState != nil
        ),
        let tmuxState = task.workspaceWindow.tmuxState else {
            return nil
        }

        if !(await shouldAllowTmuxBootstrapLaunch(
            task: task,
            snapshot: snapshot.base,
            bundleId: bundleId,
            taskContext: taskContext,
            phase: phase
        )) {
            return await handleTmuxReuseFailed(
                task: task,
                snapshotWindow: snapshotWindow,
                selectedClientTTY: selectedClientTTY,
                windowId: windowId,
                reason: denialReason,
                targetFrame: targetFrame,
                taskContext: taskContext,
                startTime: startTime,
                plannedWindowId: windowId
            )
        }
        let path = task.workspaceWindow.openPath ?? tmuxState.initialWorkingDirectory
        DeskJigLog.debug(.restorationTrace, fallbackLogMessage, fields: [
            "taskId": taskContext.taskId,
            "windowId": snapshotWindow.windowId,
            "sessionName": sessionName,
            "bundleId": task.workspaceWindow.bundleIdentifier,
            "positioningSuccess": positioningResult.success,
            "hasFinalFrame": positioningResult.finalFrame != nil
        ], runId: taskContext.runId)
        return await executeLaunchTerminalWithTmux(
            task: task,
            tmuxState: tmuxState,
            path: path,
            snapshot: snapshot,
            taskContext: taskContext,
            targetFrame: targetFrame,
            startTime: startTime,
            allowBootstrapRetry: false
        )
    }

    func executeLaunchTerminalWithTmux(
        task: RestorationTask,
        tmuxState: TmuxSessionState,
        path: String,
        snapshot: EnhancedSnapshot,
        taskContext: RestorationTaskContext,
        targetFrame: CGRect,
        startTime: Date,
        allowBootstrapRetry: Bool = true
    ) async -> TaskResult {
        let sessionName = tmuxState.sessionName
        let workingDirectory = tmuxState.initialWorkingDirectory
        guard let tmux = tmuxCommandService else {
            return TaskResult(
                taskId: task.id,
                success: false,
                decision: task.decision,
                durationMs: durationMs(from: startTime),
                notes: ["tmux command service not available for launch bootstrap"]
            )
        }

        let bundleId = task.workspaceWindow.bundleIdentifier

        // Terminal.app is single-process: concurrent `open -a Terminal` calls cause
        // auto-cascading of all windows, breaking already-positioned windows.
        // Serialize the full launch→detect→position cycle for Terminal.app only.
        let holdingTerminalSemaphore = await acquireTerminalSerializationIfNeeded(bundleId: bundleId)
        if holdingTerminalSemaphore {
            DeskJigLog.debug(.restorationTrace, "Terminal.app launch serialization: acquired semaphore", fields: [
                "taskId": taskContext.taskId,
                "sessionName": sessionName
            ], runId: taskContext.runId)
        }
        defer { if holdingTerminalSemaphore { releaseTerminalSerialization() } }

        DeskJigLog.debug(.restorationTrace, "Launching terminal with tmux session", fields: [
            "taskId": taskContext.taskId,
            "bundleId": bundleId,
            "sessionName": sessionName,
            "workingDirectory": workingDirectory,
            "path": path,
            "bindingEvidence": task.tmuxBindingPlan?.evidence.rawValue ?? "nil",
            "launchAllowed": task.tmuxBindingPlan?.launchAllowed ?? false
        ], runId: taskContext.runId)

        if !(await shouldAllowTmuxBootstrapLaunch(
            task: task,
            snapshot: snapshot.base,
            bundleId: bundleId,
            taskContext: taskContext,
            phase: "launch-entry"
        )) {
            let bundleWindows = snapshot.base.windows.filter { $0.bundleId == bundleId }
            if let resolvedWindow = TerminalWindowIdentityResolver.resolveSnapshotWindow(
                bundleId: bundleId,
                plannedWindowId: task.tmuxBindingPlan?.selectedWindowId,
                preferredPID: nil,
                preferredPath: path,
                preferredFrame: targetFrame,
                bundleWindows: bundleWindows
            )?.window {
                return await handleTmuxReuseFailed(
                    task: task,
                    snapshotWindow: resolvedWindow,
                    selectedClientTTY: nil,
                    windowId: task.tmuxBindingPlan?.selectedWindowId ?? resolvedWindow.windowId,
                    reason: "planner denied launch because bundle coverage is already satisfied",
                    targetFrame: targetFrame,
                    taskContext: taskContext,
                    startTime: startTime,
                    plannedWindowId: task.tmuxBindingPlan?.selectedWindowId ?? resolvedWindow.windowId
                )
            }
            return TaskResult(
                taskId: task.id,
                success: false,
                decision: task.decision,
                durationMs: durationMs(from: startTime),
                notes: ["tmux launch denied and no reusable terminal window could be resolved"],
                terminalBinding: makeTerminalBindingResult(
                    task: task,
                    selectedWindowId: task.tmuxBindingPlan?.selectedWindowId,
                    finalWindowId: nil,
                    selectedClientTTY: nil,
                    wasLaunched: false
                )
            )
        }

        let initialClients: [TmuxClientInfo]
        do {
            initialClients = try await tmux.listClients()
        } catch {
            DeskJigLog.debug(.restorationTrace, "Failed to list tmux clients before launch", fields: [
                "taskId": taskContext.taskId,
                "error": error.localizedDescription
            ], runId: taskContext.runId)
            return TaskResult(
                taskId: task.id,
                success: false,
                decision: task.decision,
                durationMs: durationMs(from: startTime),
                notes: ["Failed to list tmux clients before launch: \(error.localizedDescription)"]
            )
        }

        var resetStats = ManagedTmuxResetStats.empty
        if initialClients.isEmpty {
            resetStats = await observeTerminalBootstrapState(
                taskContext: taskContext,
                resetReason: "no-initial-clients"
            )
            DeskJigLog.debug(.restorationTrace, "No tmux clients found; bootstrap reset performed", fields: [
                "taskId": taskContext.taskId,
                "reason": "bootstrap-reset-observe-only",
                "resetMode": resetStats.resetMode,
                "resetReason": resetStats.resetReason,
                "managedWindowResetCount": resetStats.resetCount,
                "targetCount": resetStats.targetCount,
                "preResetTerminalWindowCount": resetStats.preResetTerminalWindowCount,
                "managedWindowCount": resetStats.managedWindowCount,
                "destructiveActions": resetStats.destructiveActions,
                "managedTitle": BundleRegistry.managedTmuxWindowTitle
            ], runId: taskContext.runId)
        }

        // Capture pre-launch managed tmux window IDs for diff-based detection
        let preLaunchSnapshot = await SystemSnapshotCapture.captureQuick(runId: taskContext.runId)
        let preLaunchManagedIds = Set(
            managedTmuxWindows(in: preLaunchSnapshot, forBundleId: bundleId)
                .map(\.windowId)
        )

        // Capture ALL pre-launch windows for this bundle to exclude from PID fallback.
        // Single-process terminals (e.g. Ghostty) share one PID across all windows,
        // so PID-based detection can match old windows unless we exclude them.
        let preLaunchBundleWindowIds = Set(
            preLaunchSnapshot.windows
                .filter { $0.bundleId == bundleId }
                .map(\.windowId)
        )

        DeskJigLog.debug(.restorationTrace, "Pre-launch managed tmux windows captured", fields: [
            "taskId": taskContext.taskId,
            "managedWindowCount": preLaunchManagedIds.count,
            "bundleWindowCount": preLaunchBundleWindowIds.count,
            "windowIds": preLaunchManagedIds.map { "\($0)" }.joined(separator: ","),
            "bundleWindowIds": preLaunchBundleWindowIds.map { "\($0)" }.joined(separator: ",")
        ], runId: taskContext.runId)

        // Surplus guard: use fresh snapshot count to prevent window accumulation.
        // If we already have at least as many windows as expected, don't launch more —
        // the switch path should be finding clients, not creating new windows.
        let freshBundleWindowCount = preLaunchBundleWindowIds.count
        let expectedCount = max(expectedTmuxWindowCount(for: bundleId), 1)
        let freshBundleAXWindowCount: Int? = bundleId == BundleRegistry.ghostty
            ? await MainActor.run {
                Window.allAcrossProcesses(forBundleID: bundleId, filter: .all).count
            }
            : nil
        let shouldSuppressForSurplus: Bool
        let surplusReason: String
        shouldSuppressForSurplus = Self.shouldSuppressTmuxLaunchForBundleSurplus(
            expectedCount: expectedCount,
            freshBundleWindowCount: freshBundleWindowCount,
            freshBundleAXWindowCount: freshBundleAXWindowCount,
            managedWindowCount: preLaunchManagedIds.count
        )
        surplusReason = freshBundleAXWindowCount != nil ? "surplus-guard-fresh-ax" : "surplus-guard-fresh"
        if shouldSuppressForSurplus {
            DeskJigLog.debug(.restorationTrace, "Skipping tmux launch — window surplus", fields: [
                "taskId": taskContext.taskId,
                "bundleId": bundleId,
                "freshBundleWindowCount": "\(freshBundleWindowCount)",
                "freshBundleAXWindowCount": freshBundleAXWindowCount.map(String.init) ?? "n/a",
                "expectedCount": "\(expectedCount)",
                "managedWindowCount": "\(preLaunchManagedIds.count)",
                "reason": surplusReason
            ], runId: taskContext.runId)
            return TaskResult(
                taskId: task.id,
                success: false,
                decision: task.decision,
                durationMs: durationMs(from: startTime),
                notes: ["Surplus guard: \(freshBundleWindowCount) windows exist (fresh), \(freshBundleAXWindowCount.map(String.init) ?? "n/a") AX windows, \(expectedCount) expected"],
                terminalBinding: makeTerminalBindingResult(
                    task: task,
                    selectedWindowId: task.tmuxBindingPlan?.selectedWindowId,
                    finalWindowId: nil,
                    selectedClientTTY: nil,
                    wasLaunched: false
                )
            )
        }

        // Launch terminal with tmux session via the appropriate launcher
        guard let launcher = FluentLauncherFactory.launcher(for: bundleId) else {
            return TaskResult(
                taskId: task.id,
                success: false,
                decision: task.decision,
                durationMs: durationMs(from: startTime),
                notes: ["No launcher found for \(bundleId)"]
            )
        }
        let launchResult: ExpLaunchResult
        do {
            launchResult = try await launcher.launchWithTmuxSession(
                sessionName: sessionName,
                workingDirectory: workingDirectory,
                task: taskContext,
                tmuxManagedIndex: task.tmuxManagedIndex
            )
        } catch {
            DeskJigLog.debug(.restorationTrace, "Terminal tmux launch failed", fields: [
                "taskId": taskContext.taskId,
                "bundleId": bundleId,
                "error": error.localizedDescription,
                "sessionName": sessionName
            ], runId: taskContext.runId)
            return TaskResult(
                taskId: task.id,
                success: false,
                decision: task.decision,
                durationMs: durationMs(from: startTime),
                notes: ["\(bundleId) tmux launch failed: \(error.localizedDescription)"]
            )
        }

        guard launchResult.success else {
            return TaskResult(
                taskId: task.id,
                success: false,
                decision: task.decision,
                durationMs: durationMs(from: startTime),
                notes: ["Terminal tmux launch returned failure"]
            )
        }

        // Combined readiness poll: look for managed window AND tmux client simultaneously.
        // The managed window typically appears first (within seconds); the tmux client
        // may take longer in GUI context where --initial-command must wait for shell
        // initialization after app startup.
        // exec-03: this deadline only bounds the FAILURE path (a window/client that never
        // appears); successful launches short-circuit far sooner. Lowered 15s -> 10s to cut
        // dead wait on failed tmux launches while staying ~5x a normal appearance time.
        let combinedTimeoutMs = 10_000
        let combinedPollMs: UInt64 = 200
        let combinedDeadline = Date().addingTimeInterval(Double(combinedTimeoutMs) / 1000.0)
        var readyClient: TmuxClientInfo?
        var detectedWindow: SnapshotWindow?
        var detectedViaClient = false
        var detectedViaSingleProcessResolver = false
        let expectedIndexedTitle = task.tmuxManagedIndex.map {
            BundleRegistry.managedTmuxWindowTitle(
                bundleId: bundleId,
                index: $0
            )
        }
        let shouldUseSingleProcessResolver = Self.shouldUseSingleProcessTerminalWindowResolver(
            bundleId: bundleId
        )
        var singleProcessCandidateTitles = "not-run"
        var singleProcessRejectionReason = "not-run"
        var pollListClientsErrorLogged = false

        if shouldUseSingleProcessResolver,
           let tmuxIndex = task.tmuxManagedIndex,
           let expectedIndexedTitle {
            do {
                try await setIndexedPaneTitleIfNeeded(tmux: tmux, session: sessionName, title: expectedIndexedTitle)
                DeskJigLog.debug(.restorationTrace, "Set indexed pane title before single-process detection", fields: [
                    "taskId": taskContext.taskId,
                    "sessionName": sessionName,
                    "title": expectedIndexedTitle,
                    "tmuxIndex": tmuxIndex
                ], runId: taskContext.runId)
            } catch {
                DeskJigLog.debug(.restorationTrace, "Failed to set indexed pane title before single-process detection", fields: [
                    "taskId": taskContext.taskId,
                    "error": error.localizedDescription,
                    "title": expectedIndexedTitle,
                    "sessionName": sessionName,
                    "tmuxIndex": tmuxIndex
                ], runId: taskContext.runId)
            }
        }

        markTmuxLaunchObserved(bundleId: bundleId, index: task.tmuxManagedIndex)

        // No fixed pre-poll delay (exec-08): the poll loop below checks immediately so a
        // fast-appearing window short-circuits; it sleeps combinedPollMs between subsequent
        // iterations, keeping the same overall deadline.
        var pollCount = 0
        while Date() < combinedDeadline {
            pollCount += 1
            let currentSnapshot = await SystemSnapshotCapture.captureQuick(runId: taskContext.runId)
            let currentBundleWindows = currentSnapshot.windows.filter { $0.bundleId == bundleId }

            // Check for new managed tmux window (by title)
            if detectedWindow == nil {
                if shouldUseSingleProcessResolver,
                   let expectedIndexedTitle {
                    let resolverAttempt = SingleProcessTerminalWindowResolver.resolve(
                        bundleId: bundleId,
                        expectedIndexedTitle: expectedIndexedTitle,
                        bundleWindows: currentBundleWindows,
                        preLaunchBundleWindowIds: preLaunchBundleWindowIds,
                        claimedWindowIds: postLaunchClaimedWindowIds,
                        targetFrame: targetFrame
                    )
                    singleProcessCandidateTitles = resolverAttempt.candidateTitlesDescription
                    singleProcessRejectionReason = resolverAttempt.rejectionReason

                    if let resolvedWindow = resolverAttempt.resolution {
                        detectedWindow = resolvedWindow.window
                        detectedViaSingleProcessResolver = true
                        DeskJigLog.debug(.restorationTrace, "Terminal tmux window detected via single-process AX title resolver", fields: [
                            "taskId": taskContext.taskId,
                            "windowId": resolvedWindow.window.windowId,
                            "pid": resolvedWindow.window.pid,
                            "title": resolvedWindow.window.title ?? "nil",
                            "expectedIndexedTitle": expectedIndexedTitle,
                            "evidence": resolvedWindow.evidence.rawValue,
                            "candidateTitles": resolverAttempt.candidateTitlesDescription,
                            "tmuxClientDetected": readyClient != nil,
                            "detectMs": durationMs(from: startTime)
                        ], runId: taskContext.runId)
                        break
                    }
                }

                let managedWindows = managedTmuxWindows(in: currentSnapshot, forBundleId: bundleId)
                let newManagedWindows = managedWindows.filter {
                    !preLaunchManagedIds.contains($0.windowId) &&
                    !postLaunchClaimedWindowIds.contains($0.windowId)
                }
                let titleMatchedWindow = task.tmuxManagedIndex.flatMap { tmuxIndex in
                    newManagedWindows.first {
                        ManagedTmuxWindowTitleMatcher.matchesManagedIndex(
                            $0.title,
                            bundleId: bundleId,
                            index: tmuxIndex
                        )
                    }
                }
                let newWindow = titleMatchedWindow
                    ?? (expectedIndexedTitle == nil ? newManagedWindows.first : nil)

                if let newWindow {
                    detectedWindow = newWindow
                    DeskJigLog.debug(.restorationTrace, "Terminal tmux window detected via managed title", fields: [
                        "taskId": taskContext.taskId,
                        "windowId": newWindow.windowId,
                        "pid": newWindow.pid,
                        "title": newWindow.title ?? "nil",
                        "expectedIndexedTitle": expectedIndexedTitle ?? "nil",
                        "tmuxClientDetected": readyClient != nil,
                        "detectMs": durationMs(from: startTime)
                    ], runId: taskContext.runId)
                    break
                }
            }

            // Check for a tmux client on the DeskJig-managed socket
            if readyClient == nil {
                do {
                    let clients = try await tmux.listClients()
                    if let client = clients.first(where: { $0.sessionName == sessionName }) {
                        readyClient = client
                    }
                } catch {
                    // Log once per detection attempt (not per poll iteration) so a
                    // broken tmux socket is distinguishable from "client not yet up".
                    if !pollListClientsErrorLogged {
                        pollListClientsErrorLogged = true
                        DeskJigLog.debug(.restorationTrace, "list-clients failed during readiness poll", fields: [
                            "taskId": taskContext.taskId,
                            "sessionName": sessionName,
                            "error": error.localizedDescription
                        ], runId: taskContext.runId)
                    }
                }
            }

            // Fallback: if client found, try PID-based window match.
            // Exclude windows already claimed by other tasks to prevent
            // single-process terminals (Terminal.app) from mapping two tasks
            // to the same window via PID.
            if let client = readyClient, detectedWindow == nil {
                let excludedIds = preLaunchBundleWindowIds.union(postLaunchClaimedWindowIds)
                if shouldUseSingleProcessResolver {
                    singleProcessRejectionReason = "\(singleProcessRejectionReason)-client-present"
                } else if let mappedWindow = snapshotWindowForClient(client, in: currentSnapshot, managedOnly: false, excludingWindowIds: excludedIds) {
                    detectedWindow = mappedWindow
                    detectedViaClient = true
                    DeskJigLog.debug(.restorationTrace, "Terminal window detected via tmux client PID", fields: [
                        "taskId": taskContext.taskId,
                        "windowId": mappedWindow.windowId,
                        "clientTTY": client.clientTTY,
                        "pid": mappedWindow.pid,
                        "title": mappedWindow.title ?? "nil",
                        "managedWindowDetected": "false",
                        "tmuxClientDetected": "true",
                        "detectMs": durationMs(from: startTime),
                        "excludedClaimedCount": postLaunchClaimedWindowIds.count
                    ], runId: taskContext.runId)
                    break
                } else if let resolvedWindow = TerminalWindowIdentityResolver.resolveSnapshotWindow(
                    bundleId: bundleId,
                    plannedWindowId: nil,
                    preferredPID: client.clientPID,
                    preferredPath: path,
                    preferredFrame: targetFrame,
                    bundleWindows: currentBundleWindows
                        .filter { !excludedIds.contains($0.windowId) }
                )?.window {
                    detectedWindow = resolvedWindow
                    detectedViaClient = true
                    break
                }
            }

            guard await Task.sleepUnlessCancelled(nanoseconds: combinedPollMs * 1_000_000) else { break }
        }

        // Summary log: one line per detection attempt instead of per-poll spam
        let detectionMethod: String
        if detectedWindow != nil && detectedViaSingleProcessResolver {
            detectionMethod = "single-process-ax-title"
        } else if detectedWindow != nil && detectedViaClient {
            detectionMethod = "tmux-client"
        } else if detectedWindow != nil {
            detectionMethod = "managed-title"
        } else {
            detectionMethod = "timeout"
        }
        DeskJigLog.debug(.restorationTrace, "Terminal window detection summary", fields: [
            "taskId": taskContext.taskId,
            "bundleId": bundleId,
            "pollIterations": "\(pollCount)",
            "durationMs": durationMs(from: startTime),
            "detectedVia": detectionMethod,
            "sessionName": sessionName,
            "expectedIndexedTitle": expectedIndexedTitle ?? "nil",
            "singleProcessResolverEnabled": shouldUseSingleProcessResolver,
            "singleProcessCandidateTitles": singleProcessCandidateTitles,
            "singleProcessRejectionReason": singleProcessRejectionReason
        ], runId: taskContext.runId)

        // Claim the detected window so concurrent tasks for the same
        // single-process terminal don't resolve to this same window.
        if let detected = detectedWindow {
            postLaunchClaimedWindowIds.insert(detected.windowId)
        }

        guard let newWindow = detectedWindow else {
            // Failure diagnostics: record a tmux command error explicitly instead of
            // letting it masquerade as an empty ("none") client/session snapshot.
            var clientsAtFailure: [TmuxClientInfo] = []
            let clientSnapshot: String
            do {
                clientsAtFailure = try await tmux.listClients()
                clientSnapshot = clientsAtFailure
                    .map { "\($0.clientTTY)|\($0.sessionName)|\($0.clientPID)" }
                    .joined(separator: ",")
            } catch {
                clientSnapshot = "list-clients-error: \(error.localizedDescription)"
            }
            let sessionSnapshot: String
            do {
                sessionSnapshot = try await tmux.listSessions()
                    .map { "\($0.sessionName)|\($0.sessionPath)" }
                    .joined(separator: ",")
            } catch {
                sessionSnapshot = "list-sessions-error: \(error.localizedDescription)"
            }
            let failureSnapshot = await SystemSnapshotCapture.captureQuick(runId: taskContext.runId)
            let terminalWindowCountAtFailure = failureSnapshot.windows.filter { BundleRegistry.isTerminal($0.bundleId ?? "") }.count
            let cleanupStats = await observeTerminalBootstrapState(
                taskContext: taskContext,
                resetReason: "readiness-failure"
            )

            DeskJigLog.debug(.restorationTrace, "Terminal bootstrap failure cleanup complete", fields: [
                "taskId": taskContext.taskId,
                "bootstrapFailureCleanup": "observe-only",
                "managedWindowResetCount": cleanupStats.resetCount,
                "targetCount": cleanupStats.targetCount,
                "preResetTerminalWindowCount": cleanupStats.preResetTerminalWindowCount,
                "managedWindowCount": cleanupStats.managedWindowCount,
                "destructiveActions": cleanupStats.destructiveActions,
                "resetMode": cleanupStats.resetMode,
                "resetReason": cleanupStats.resetReason
            ], runId: taskContext.runId)

            DeskJigLog.debug(.restorationTrace, "FAILED: no managed window or tmux client detected after launch", fields: [
                "taskId": taskContext.taskId,
                "reason": shouldUseSingleProcessResolver && expectedIndexedTitle != nil
                    ? "single-process-managed-title-timeout"
                    : "combined-readiness-failed",
                "sessionName": sessionName,
                "timeoutMs": combinedTimeoutMs,
                "tmuxSocket": TmuxCommandService.deskJigSocketPath,
                "managedWindowDetected": "false",
                "tmuxClientDetected": readyClient != nil,
                "expectedIndexedTitle": expectedIndexedTitle ?? "nil",
                "clientCount": clientsAtFailure.count,
                "clientSnapshot": clientSnapshot.isEmpty ? "none" : clientSnapshot,
                "sessionSnapshot": sessionSnapshot.isEmpty ? "none" : sessionSnapshot,
                "singleProcessResolverEnabled": shouldUseSingleProcessResolver,
                "singleProcessCandidateTitles": singleProcessCandidateTitles,
                "singleProcessRejectionReason": singleProcessRejectionReason,
                "terminalWindowCountAtFailure": terminalWindowCountAtFailure,
                "preLaunchManagedCount": preLaunchManagedIds.count,
                "managedWindowResetCount": cleanupStats.resetCount,
                "targetCount": cleanupStats.targetCount,
                "preResetTerminalWindowCount": cleanupStats.preResetTerminalWindowCount,
                "managedWindowCount": cleanupStats.managedWindowCount,
                "destructiveActions": cleanupStats.destructiveActions,
                "resetMode": cleanupStats.resetMode,
                "resetReason": cleanupStats.resetReason
            ], runId: taskContext.runId)
            return TaskResult(
                taskId: task.id,
                success: false,
                decision: task.decision,
                durationMs: durationMs(from: startTime),
                notes: [shouldUseSingleProcessResolver && expectedIndexedTitle != nil
                    ? "No titled Terminal.app window matched \(expectedIndexedTitle!) after launch (clientDetected=\(readyClient != nil), rejection=\(singleProcessRejectionReason))"
                    : "No managed terminal window or tmux client detected for session \(sessionName) after launch (clientDetected=\(readyClient != nil))"]
            )
        }

        if let tmuxIndex = task.tmuxManagedIndex {
            let indexedTitle = BundleRegistry.managedTmuxWindowTitle(
                bundleId: bundleId,
                index: tmuxIndex
            )
            var titleSetOutcome = "success"
            do {
                try await setIndexedPaneTitleIfNeeded(tmux: tmux, session: sessionName, title: indexedTitle)
                DeskJigLog.debug(.restorationTrace, "Set indexed pane title after launch", fields: [
                    "taskId": taskContext.taskId,
                    "sessionName": sessionName,
                    "title": indexedTitle,
                    "tmuxIndex": tmuxIndex,
                    "windowId": newWindow.windowId
                ], runId: taskContext.runId)
            } catch {
                titleSetOutcome = "set-title-failed"
                DeskJigLog.debug(.restorationTrace, "Failed to set indexed pane title after launch", fields: [
                    "taskId": taskContext.taskId,
                    "error": error.localizedDescription,
                    "title": indexedTitle,
                    "sessionName": sessionName,
                    "tmuxIndex": tmuxIndex
                ], runId: taskContext.runId)
            }

            let settleStart = Date()
            let visibilityState = await waitForManagedTmuxIndexVisibility(
                bundleId: bundleId,
                index: tmuxIndex,
                runId: taskContext.runId,
                timeoutMs: 850,
                pollMs: 120
            )
            let settleMs = max(0, Int(Date().timeIntervalSince(settleStart) * 1000))
            let visibilityDescription = describeManagedTmuxVisibilityState(visibilityState)

            logRC10Diag(
                "launch-indexed-title-enforcement",
                runId: taskContext.runId,
                data: [
                    "bundleId": bundleId,
                    "sessionName": sessionName,
                    "tmuxIndex": tmuxIndex,
                    "indexedTitle": indexedTitle,
                    "windowId": newWindow.windowId,
                    "detectedViaClient": detectedViaClient,
                    "titleSetOutcome": titleSetOutcome,
                    "visibilityState": visibilityDescription,
                    "settleMs": settleMs
                ]
            )
        }

        if allowBootstrapRetry,
           let bootstrapResult = await bootstrapMissingTmuxIndexIfNeeded(
               task: task,
               snapshot: snapshot,
               targetFrame: targetFrame,
               taskContext: taskContext,
               startTime: startTime,
               phase: "post-launch",
               allowRetryLaunch: false
           ) {
            return bootstrapResult
        }

        // Position the window
        let preferredStrategy = WindowHandleResolver.preferredStrategy(
            workspaceWindow: task.workspaceWindow,
            snapshotWindow: newWindow
        )
        DeskJigLog.debug(.restorationTrace, "Terminal managed window positioning attempt", fields: [
            "taskId": taskContext.taskId,
            "windowId": newWindow.windowId,
            "targetFrame": targetFrame.debugDescription,
            "detectedViaClient": detectedViaClient,
            "tmuxClientDetected": readyClient != nil
        ], runId: taskContext.runId)
        let positioningResult = await positioningService.positionSnapshotWindow(
            snapshotWindow: newWindow,
            targetFrame: targetFrame,
            taskContext: taskContext,
            requesterId: task.id,
            lockPriority: task.requiredPriority,
            useWindowLocks: config.useWindowLocks,
            lockTimeout: config.lockTimeout,
            preferredStrategy: preferredStrategy
        )
        DeskJigLog.debug(.restorationTrace, "Terminal managed window positioning result", fields: [
            "taskId": taskContext.taskId,
            "windowId": newWindow.windowId,
            "success": positioningResult.success,
            "matchesTarget": positioningResult.matchesTarget
        ], runId: taskContext.runId)

        var notes = ["Launched terminal with tmux session \(sessionName)"]
        if !positioningResult.matchesTarget {
            notes.append(Self.frameMismatchNote)
        }
        let actualWindowId = positioningResult.resolvedWindowId ?? newWindow.windowId

        return TaskResult(
            taskId: task.id,
            success: positioningResult.success,
            windowId: actualWindowId,
            decision: task.decision,
            durationMs: durationMs(from: startTime),
            notes: notes,
            plannedWindowId: actualWindowId != newWindow.windowId ? newWindow.windowId : nil,
            terminalBinding: makeTerminalBindingResult(
                task: task,
                selectedWindowId: task.tmuxBindingPlan?.selectedWindowId,
                finalWindowId: actualWindowId,
                selectedClientTTY: readyClient?.clientTTY,
                wasLaunched: true
            )
        )
    }
}
