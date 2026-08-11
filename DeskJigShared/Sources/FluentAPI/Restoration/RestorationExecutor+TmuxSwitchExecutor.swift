//  RestorationExecutor+TmuxSwitchExecutor.swift
//  DeskJigShared

import Foundation
import CoreGraphics
import AppKit

extension RestorationExecutor {

    // MARK: - Tmux Switch Decision Executor

    func executeSwitchTmuxSession(
        task: RestorationTask,
        snapshot: EnhancedSnapshot,
        windowId: CGWindowID,
        sessionName: String,
        targetFrame: CGRect,
        taskContext: RestorationTaskContext,
        startTime: Date
    ) async -> TaskResult {
        guard let tmux = tmuxCommandService else {
            return TaskResult(
                taskId: task.id,
                success: false,
                windowId: windowId,
                decision: task.decision,
                durationMs: durationMs(from: startTime),
                notes: ["tmux command service not available"],
                lockAcquired: task.hasLock
            )
        }

        let bundleId = task.workspaceWindow.bundleIdentifier
        let bindingPlan = task.tmuxBindingPlan

        // Terminal.app is single-process: repositioning one window can trigger
        // auto-cascading of all Terminal windows. Serialize switch+position to
        // prevent the second window from being moved by the first's reposition.
        let holdingTerminalSemaphore = await acquireTerminalSerializationIfNeeded(bundleId: bundleId)
        defer { if holdingTerminalSemaphore { releaseTerminalSerialization() } }

        // Fast path: If the planned window exists in the snapshot and has a
        // managed tmux title, it's already displaying a DeskJig-managed session. We can
        // position it without going through the full client detection loop.
        //
        // The window may be displaying a session from a DIFFERENT workspace
        // (cross-workspace switch) or a stale session from the same workspace
        // (terminal-key change). We handle both by:
        // 1. Finding the tmux client for this window (PID matching)
        // 2. Sending cd to the client's CURRENT session (the visible one)
        // 3. Trying switch-client to the target session (works for non-CC
        //    terminals like Ghostty; harmless if it fails for CC mode)
        let requestedSnapshotWindow = resolvedSwitchSnapshotWindow(
            task: task,
            snapshot: snapshot.base,
            plannedWindowId: windowId,
            bundleId: bundleId,
            taskContext: taskContext
        )
        let snapshotWindowForFastPath = requestedSnapshotWindow
        let windowHasManagedTitle = snapshotWindowForFastPath?.title?.contains(BundleRegistry.managedTmuxWindowTitle) == true
        let hasTTYMappedManagedEvidence: Bool
        if let snapshotWindow = snapshotWindowForFastPath,
           !windowHasManagedTitle {
            hasTTYMappedManagedEvidence = await hasStrongManagedTmuxEvidenceFromTTYMapping(
                bundleId: bundleId,
                plannedWindowId: snapshotWindow.windowId,
                expectedSessionName: sessionName,
                snapshotWindowTitle: snapshotWindow.title,
                taskContext: taskContext
            )
        } else {
            hasTTYMappedManagedEvidence = false
        }

        if (windowHasManagedTitle || hasTTYMappedManagedEvidence), let snapshotWindow = snapshotWindowForFastPath {
            var clients: [TmuxClientInfo] = []
            do {
                clients = try await tmux.listClients()
            } catch {
                // Distinguish a tmux failure from "no clients attached" in the trace;
                // the fast path continues client-less (falls back to positioning only).
                DeskJigLog.debug(.restorationTrace, "fast-path list-clients failed — continuing without client", fields: [
                    "taskId": taskContext.taskId,
                    "sessionName": sessionName,
                    "error": error.localizedDescription
                ], runId: taskContext.runId)
            }
            let expectedWindowCount = expectedTmuxWindowCount(for: bundleId)
            let shouldForceSwitchForITerm = bundleId == BundleRegistry.iterm2 && expectedWindowCount > 1
            let selectedClient = await selectTmuxClientForWindow(
                bundleId: bundleId,
                plannedWindowId: windowId,
                requestedSnapshotWindow: snapshotWindow,
                clients: clients,
                snapshot: snapshot.base,
                taskContext: taskContext,
                sessionName: sessionName,
                launchSource: config.launchSource,
                bindingEvidence: bindingPlan?.evidence
            )
            let windowClient = selectedClient?.client
            let clientCurrentSession = windowClient?.sessionName
            let alreadyOnTarget = clientCurrentSession == sessionName

            DeskJigLog.debug(.restorationTrace, "Window has managed tmux title — fast path", fields: [
                "taskId": taskContext.taskId,
                "sessionName": sessionName,
                "windowId": windowId,
                "windowTitle": snapshotWindow.title ?? "nil",
                "tmuxIndex": task.tmuxManagedIndex.map { "\($0)" } ?? "nil",
                "managedEvidence": windowHasManagedTitle ? "title" : "tty-session-map",
                "bindingEvidence": bindingPlan?.evidence.rawValue ?? "nil",
                "clientFound": windowClient != nil,
                "selectionReason": selectedClient?.reason ?? "none",
                "clientCurrentSession": clientCurrentSession ?? "nil",
                "alreadyOnTarget": alreadyOnTarget,
                "expectedWindowCount": expectedWindowCount
            ], runId: taskContext.runId)

            let openPath = task.workspaceWindow.openPath ?? task.workspaceWindow.tmuxState?.initialWorkingDirectory
            let quickSwitchPreflight = await buildQuickSwitchTmuxPreflightDecision(
                bundleId: bundleId,
                sessionName: sessionName,
                currentSessionName: clientCurrentSession,
                snapshotWindow: snapshotWindow,
                targetFrame: targetFrame,
                expectedScreenIndex: task.workspaceWindow.screenIndex,
                tmuxIndex: task.tmuxManagedIndex,
                openPath: openPath,
                hasSelectedClient: windowClient != nil,
                hasStrongManagedEvidence: hasTTYMappedManagedEvidence,
                taskContext: taskContext
            )

            // Try switch-client to move the window to the target session.
            // Keep iTerm skip optimization only when one managed iTerm window is
            // expected; multi-window restores must switch deterministically.
            let shouldSkipSwitch = bundleId == BundleRegistry.iterm2 && !shouldForceSwitchForITerm
            let shouldSwitchSession = quickSwitchPreflight?.shouldSwitchSession ?? !alreadyOnTarget
            var switchedSession = false
            if let client = windowClient, !alreadyOnTarget, shouldSwitchSession, !shouldSkipSwitch {
                do {
                    try await tmux.switchClient(clientTTY: client.clientTTY, toSession: sessionName)
                    switchedSession = true
                    DeskJigLog.debug(.restorationTrace, "fast-path switch-client succeeded", fields: [
                        "taskId": taskContext.taskId,
                        "clientTTY": client.clientTTY,
                        "fromSession": client.sessionName,
                        "toSession": sessionName,
                        "selectionReason": selectedClient?.reason ?? "none"
                    ], runId: taskContext.runId)
                } catch {
                    // Non-fatal — window still shows old session.
                    DeskJigLog.debug(.restorationTrace, "fast-path switch-client failed (non-fatal)", fields: [
                        "taskId": taskContext.taskId,
                        "clientTTY": client.clientTTY,
                        "selectionReason": selectedClient?.reason ?? "none",
                        "error": error.localizedDescription
                    ], runId: taskContext.runId)
                }
            } else if shouldSkipSwitch && !alreadyOnTarget && shouldSwitchSession {
                DeskJigLog.debug(.restorationTrace, "Skipping switch-client for iTerm CC mode", fields: [
                    "taskId": taskContext.taskId,
                    "clientTTY": windowClient?.clientTTY ?? "nil",
                    "currentSession": clientCurrentSession ?? "nil",
                    "targetSession": sessionName,
                    "expectedWindowCount": expectedWindowCount
                ], runId: taskContext.runId)
            }

            // Set indexed pane title on the TARGET session for future matching
            let shouldSetIndexedTitle = quickSwitchPreflight?.shouldSetIndexedTitle ?? true
            if shouldSetIndexedTitle, let tmuxIndex = task.tmuxManagedIndex {
                let indexedTitle = BundleRegistry.managedTmuxWindowTitle(
                    bundleId: bundleId,
                    index: tmuxIndex
                )
                do {
                    try await setIndexedPaneTitleIfNeeded(tmux: tmux, session: sessionName, title: indexedTitle)
                } catch {
                    // Non-fatal
                }
            }

            if quickSwitchPreflight?.action != .noOp {
                if let bootstrapResult = await bootstrapMissingTmuxIndexIfNeeded(
                    task: task,
                    snapshot: snapshot,
                    targetFrame: targetFrame,
                    taskContext: taskContext,
                    startTime: startTime,
                    phase: "post-switch-fast-path",
                    allowRetryLaunch: false
                ) {
                    return bootstrapResult
                }
            }

            let shouldRepositionWindow = quickSwitchPreflight?.shouldRepositionWindow ?? true
            if !shouldRepositionWindow {
                // Terminal.app auto-cascades when multiple windows are positioned in sequence.
                // Anchor the window to its target frame even on the switchOnly path to prevent
                // the next window's positioning from displacing this one to a different screen.
                if bundleId == BundleRegistry.terminal && task.hasLock {
                    let anchorStrategy = Self.positioningStrategy(
                        switchedSession: switchedSession,
                        bundleId: bundleId,
                        workspaceWindow: task.workspaceWindow,
                        snapshotWindow: snapshotWindow
                    )
                    let anchorLocks = config.useWindowLocks && !task.hasLock
                    let _ = await positioningService.positionSnapshotWindow(
                        snapshotWindow: snapshotWindow,
                        targetFrame: targetFrame,
                        taskContext: taskContext,
                        requesterId: task.id,
                        lockPriority: task.requiredPriority,
                        useWindowLocks: anchorLocks,
                        lockTimeout: config.lockTimeout,
                        preferredStrategy: anchorStrategy
                    )
                    DeskJigLog.debug(.restorationTrace, "Terminal.app anchored on switchOnly path", fields: [
                        "taskId": taskContext.taskId,
                        "windowId": snapshotWindow.windowId,
                        "targetFrame": "\(Int(targetFrame.origin.x)),\(Int(targetFrame.origin.y)) \(Int(targetFrame.width))x\(Int(targetFrame.height))"
                    ], runId: taskContext.runId)
                }

                var notes = ["fast-path: managed window kept-in-place"]
                if let quickSwitchPreflight {
                    notes.append("preflight=\(quickSwitchPreflight.action.rawValue)")
                }
                if switchedSession {
                    notes.append("session-switched")
                }
                return TaskResult(
                    taskId: task.id,
                    success: true,
                    windowId: snapshotWindow.windowId,
                    decision: task.decision,
                    durationMs: durationMs(from: startTime),
                    notes: notes,
                    lockAcquired: task.hasLock,
                    terminalBinding: makeTerminalBindingResult(
                        task: task,
                        selectedWindowId: windowId,
                        finalWindowId: snapshotWindow.windowId,
                        selectedClientTTY: windowClient?.clientTTY,
                        wasLaunched: false
                    )
                )
            }

            // Position the window
            let positioningSnapshotWindow = snapshotWindow
            let preferredStrategy = Self.positioningStrategy(
                switchedSession: switchedSession,
                bundleId: bundleId,
                workspaceWindow: task.workspaceWindow,
                snapshotWindow: positioningSnapshotWindow
            )
            let useWindowLocks = config.useWindowLocks && !task.hasLock
            let positioningResult = await positioningService.positionSnapshotWindow(
                snapshotWindow: positioningSnapshotWindow,
                targetFrame: targetFrame,
                taskContext: taskContext,
                requesterId: task.id,
                lockPriority: task.requiredPriority,
                useWindowLocks: useWindowLocks,
                lockTimeout: config.lockTimeout,
                preferredStrategy: preferredStrategy
            )

            if let fallbackResult = await handleSwitchPositionFailureFallback(
                task: task,
                positioningResult: positioningResult,
                snapshot: snapshot,
                snapshotWindow: snapshotWindow,
                windowId: windowId,
                sessionName: sessionName,
                bundleId: bundleId,
                selectedClientTTY: windowClient?.clientTTY,
                targetFrame: targetFrame,
                taskContext: taskContext,
                startTime: startTime,
                phase: "fast-path-position-failure",
                denialReason: "launch denied after fast-path positioning failure",
                fallbackLogMessage: "Managed switch fast-path positioning unresolved — falling back to launch"
            ) {
                return fallbackResult
            }

            let actualWindowId = positioningResult.resolvedWindowId ?? positioningSnapshotWindow.windowId
            var notes = ["fast-path: managed window positioned"]
            if let quickSwitchPreflight {
                notes.append("preflight=\(quickSwitchPreflight.action.rawValue)")
            }
            if switchedSession {
                notes.append("session-switched")
            }
            return TaskResult(
                taskId: task.id,
                success: positioningResult.success,
                windowId: actualWindowId,
                decision: task.decision,
                durationMs: durationMs(from: startTime),
                notes: notes,
                lockAcquired: task.hasLock,
                plannedWindowId: actualWindowId != windowId ? windowId : nil,
                terminalBinding: makeTerminalBindingResult(
                    task: task,
                    selectedWindowId: windowId,
                    finalWindowId: actualWindowId,
                    selectedClientTTY: windowClient?.clientTTY,
                    wasLaunched: false
                )
            )
        }

        // If the planned window doesn't have a managed title, it may have
        // disappeared or never existed. Fall through to switch-client logic
        // which includes bootstrap fallbacks.
        DeskJigLog.debug(.restorationTrace, "Window not managed — falling through to switch-client", fields: [
            "taskId": taskContext.taskId,
            "sessionName": sessionName,
            "windowId": windowId,
            "windowTitle": snapshotWindowForFastPath?.title ?? "nil",
            "windowExists": snapshotWindowForFastPath != nil
        ], runId: taskContext.runId)

        // Step 1: Resolve current tmux clients.
        // With the synchronous-wait pipe fix in TmuxCommandService, listClients()
        // reliably returns data on the first call. A single 500ms retry is kept as
        // a safety net for genuine startup timing edge cases.
        var clients: [TmuxClientInfo] = []
        var pollAttempts = 0
        do {
            clients = try await tmux.listClients()
            pollAttempts = 1
            if clients.isEmpty {
                await Task.sleepUnlessCancelled(nanoseconds: 500_000_000) // 500ms safety retry
                clients = try await tmux.listClients()
                pollAttempts = 2
            }
        } catch {
            DeskJigLog.debug(.restorationTrace, "Failed to list tmux clients", fields: [
                "taskId": taskContext.taskId,
                "error": error.localizedDescription
            ], runId: taskContext.runId)
            return TaskResult(
                taskId: task.id,
                success: false,
                windowId: windowId,
                decision: task.decision,
                durationMs: durationMs(from: startTime),
                notes: ["Failed to list tmux clients: \(error.localizedDescription)"],
                lockAcquired: task.hasLock
            )
        }

        DeskJigLog.debug(.restorationTrace, "tmux client detection complete", fields: [
            "taskId": taskContext.taskId,
            "clientCount": clients.count,
            "pollAttempts": pollAttempts,
            "windowId": windowId
        ], runId: taskContext.runId)

        // Fallback: if unfiltered list-clients returned empty, try session-filtered
        // listing and collect diagnostics. The unfiltered call has been observed to
        // return empty in GUI-app contexts despite clients being attached.
        if clients.isEmpty {
            let diagnostic = await tmux.listClientsDiagnostic()
            DeskJigLog.debug(.restorationTrace, "list-clients returned empty — running diagnostics", fields: [
                "taskId": taskContext.taskId,
                "diagnostic": diagnostic,
                "sessionName": sessionName,
                "windowId": windowId
            ], runId: taskContext.runId)

            // Try session-filtered listing as fallback
            do {
                let sessionClients = try await tmux.listClientsForSession(sessionName)
                if !sessionClients.isEmpty {
                    clients = sessionClients
                    DeskJigLog.debug(.restorationTrace, "Session-filtered list-clients found clients", fields: [
                        "taskId": taskContext.taskId,
                        "clientCount": clients.count,
                        "sessionName": sessionName,
                        "fallbackMethod": "list-clients-t"
                    ], runId: taskContext.runId)
                }
            } catch {
                DeskJigLog.debug(.restorationTrace, "Session-filtered list-clients failed", fields: [
                    "taskId": taskContext.taskId,
                    "sessionName": sessionName,
                    "fallbackMethod": "list-clients-t",
                    "error": error.localizedDescription
                ], runId: taskContext.runId)
            }

            // Second fallback: try listing clients for ALL known sessions
            if clients.isEmpty {
                var sessions: [TmuxSessionInfo] = []
                do {
                    sessions = try await tmux.listSessions()
                } catch {
                    // A list-sessions failure must read differently in the trace
                    // than "tmux has no sessions".
                    DeskJigLog.debug(.restorationTrace, "list-sessions failed during attached session scan", fields: [
                        "taskId": taskContext.taskId,
                        "targetSession": sessionName,
                        "fallbackMethod": "session-scan",
                        "error": error.localizedDescription
                    ], runId: taskContext.runId)
                }
                for session in sessions where session.isAttached {
                    do {
                        let sessionClients = try await tmux.listClientsForSession(session.sessionName)
                        guard !sessionClients.isEmpty else { continue }
                        clients = sessionClients
                        DeskJigLog.debug(.restorationTrace, "Found clients via attached session scan", fields: [
                            "taskId": taskContext.taskId,
                            "clientCount": clients.count,
                            "sourceSession": session.sessionName,
                            "targetSession": sessionName,
                            "fallbackMethod": "session-scan"
                        ], runId: taskContext.runId)
                        break
                    } catch {
                        DeskJigLog.debug(.restorationTrace, "list-clients failed for attached session", fields: [
                            "taskId": taskContext.taskId,
                            "sourceSession": session.sessionName,
                            "targetSession": sessionName,
                            "fallbackMethod": "session-scan",
                            "error": error.localizedDescription
                        ], runId: taskContext.runId)
                    }
                }

                if clients.isEmpty {
                    let sessionInfo = sessions.map { "\($0.sessionName):\($0.isAttached ? "attached" : "detached")" }.joined(separator: ",")
                    DeskJigLog.debug(.restorationTrace, "All fallback client detection methods exhausted", fields: [
                        "taskId": taskContext.taskId,
                        "sessions": sessionInfo,
                        "sessionCount": sessions.count,
                        "attachedCount": "\(sessions.filter(\.isAttached).count)"
                    ], runId: taskContext.runId)
                }
            }
        }

        guard !clients.isEmpty else {
            DeskJigLog.debug(.restorationTrace, "No tmux clients available for switch after all detection methods", fields: [
                "taskId": taskContext.taskId,
                "windowId": windowId,
                "pollAttempts": pollAttempts
            ], runId: taskContext.runId)
            if !(await shouldAllowTmuxBootstrapLaunch(
                task: task,
                snapshot: snapshot.base,
                bundleId: bundleId,
                taskContext: taskContext,
                phase: "no-clients"
            )),
            let resolvedWindow = snapshotWindowForFastPath
                ?? resolvedTmuxBindingSnapshotWindow(for: task, snapshot: snapshot.base, plannedWindowId: windowId)?.window {
                return await handleTmuxReuseFailed(
                    task: task,
                    snapshotWindow: resolvedWindow,
                    selectedClientTTY: nil,
                    windowId: windowId,
                    reason: "launch denied because bundle coverage is already satisfied",
                    targetFrame: targetFrame,
                    taskContext: taskContext,
                    startTime: startTime,
                    plannedWindowId: windowId
                )
            }
            // Fall back to launching tmux inside the existing terminal window.
            // This handles the post-kill-server case where the terminal window exists
            // but is no longer a tmux client (bare shell after server was killed).
            if let tmuxState = task.workspaceWindow.tmuxState {
                DeskJigLog.debug(.restorationTrace, "No clients at all — falling back to tmux launch in existing window", fields: [
                    "taskId": taskContext.taskId,
                    "windowId": windowId,
                    "sessionName": sessionName,
                    "bundleId": task.workspaceWindow.bundleIdentifier,
                    "fallbackReason": "zero-clients-post-reset"
                ], runId: taskContext.runId)
                let path = task.workspaceWindow.openPath ?? tmuxState.initialWorkingDirectory
                return await executeLaunchTerminalWithTmux(
                    task: task,
                    tmuxState: tmuxState,
                    path: path,
                    snapshot: snapshot,
                    taskContext: taskContext,
                    targetFrame: targetFrame,
                    startTime: startTime
                )
            }
            return TaskResult(
                taskId: task.id,
                success: false,
                windowId: windowId,
                decision: task.decision,
                durationMs: durationMs(from: startTime),
                notes: ["No tmux clients available after \(pollAttempts) poll attempts and fallback detection"],
                lockAcquired: task.hasLock
            )
        }

        let clientSelection = await selectTmuxClientForWindow(
            bundleId: task.workspaceWindow.bundleIdentifier,
            plannedWindowId: windowId,
            requestedSnapshotWindow: requestedSnapshotWindow,
            clients: clients,
            snapshot: snapshot.base,
            taskContext: taskContext,
            sessionName: sessionName,
            launchSource: config.launchSource,
            bindingEvidence: bindingPlan?.evidence
        )
        let selectedClient = clientSelection?.client
        let selectionReason = clientSelection?.reason ?? "none"
        let selectedWindow = requestedSnapshotWindow ?? selectedClient.flatMap {
            self.snapshotWindowForClient($0, in: snapshot.base)
        }

        DeskJigLog.debug(.restorationTrace, "tmux client selection result", fields: [
            "taskId": taskContext.taskId,
            "taskBundleId": task.workspaceWindow.bundleIdentifier,
            "clientCount": clients.count,
            "selectionReason": selectionReason,
            "selectedClientTTY": selectedClient?.clientTTY ?? "none",
            "selectedWindowId": selectedWindow.map { "\($0.windowId)" } ?? "none",
            "selectedWindowBundle": selectedWindow?.bundleId ?? "none",
            "bindingEvidence": bindingPlan?.evidence.rawValue ?? "nil"
        ], runId: taskContext.runId)

        guard let client = selectedClient else {
            if let tmuxState = task.workspaceWindow.tmuxState,
               shouldForceBootstrapForMissingTargetClient(
                clients: clients,
                sessionName: sessionName,
                task: task
               ) {
                DeskJigLog.debug(.restorationTrace, "No tmux client selected for target quick-switch session — forcing bootstrap launch", fields: [
                    "taskId": taskContext.taskId,
                    "bundleId": bundleId,
                    "sessionName": sessionName,
                    "windowId": windowId,
                    "clientCount": clients.count,
                    "selectionReason": selectionReason
                ], runId: taskContext.runId)
                let path = task.workspaceWindow.openPath ?? tmuxState.initialWorkingDirectory
                return await executeLaunchTerminalWithTmux(
                    task: task,
                    tmuxState: tmuxState,
                    path: path,
                    snapshot: snapshot,
                    taskContext: taskContext,
                    targetFrame: targetFrame,
                    startTime: startTime
                )
            }
            if let tmuxState = task.workspaceWindow.tmuxState,
               config.launchSource == Self.quickSwitchLaunchSource,
               task.workspaceWindow.bundleIdentifier == BundleRegistry.ghostty {
                DeskJigLog.debug(.restorationTrace, "No tmux client selected for Ghostty quick-switch slot — forcing bootstrap launch", fields: [
                    "taskId": taskContext.taskId,
                    "bundleId": bundleId,
                    "sessionName": sessionName,
                    "windowId": windowId,
                    "clientCount": clients.count,
                    "selectionReason": selectionReason
                ], runId: taskContext.runId)
                let path = task.workspaceWindow.openPath ?? tmuxState.initialWorkingDirectory
                return await executeLaunchTerminalWithTmux(
                    task: task,
                    tmuxState: tmuxState,
                    path: path,
                    snapshot: snapshot,
                    taskContext: taskContext,
                    targetFrame: targetFrame,
                    startTime: startTime
                )
            }
            if !(await shouldAllowTmuxBootstrapLaunch(
                task: task,
                snapshot: snapshot.base,
                bundleId: bundleId,
                taskContext: taskContext,
                phase: "no-client-selection"
            )),
            let resolvedWindow = selectedWindow
                ?? snapshotWindowForFastPath
                ?? resolvedTmuxBindingSnapshotWindow(for: task, snapshot: snapshot.base, plannedWindowId: windowId)?.window {
                return await handleTmuxReuseFailed(
                    task: task,
                    snapshotWindow: resolvedWindow,
                    selectedClientTTY: nil,
                    windowId: windowId,
                    reason: "launch denied because tmux bundle already has enough windows",
                    targetFrame: targetFrame,
                    taskContext: taskContext,
                    startTime: startTime,
                    plannedWindowId: windowId
                )
            }
            // No tmux client found for this terminal window. Fall back to launching
            // tmux in the existing window via the terminal launcher. This handles the
            // case where Terminal.app (or another terminal) is running but hasn't had
            // tmux started in it yet — common when the plan builder chose switchTmuxSession
            // based on tmux clients from OTHER terminal bundles.
            if let tmuxState = task.workspaceWindow.tmuxState {
                DeskJigLog.debug(.restorationTrace, "No tmux client for switch — falling back to tmux launch", fields: [
                    "taskId": taskContext.taskId,
                    "windowId": windowId,
                    "sessionName": sessionName,
                    "bundleId": task.workspaceWindow.bundleIdentifier,
                    "clientCount": clients.count,
                    "fallbackReason": "no-client-for-switch"
                ], runId: taskContext.runId)
                let path = task.workspaceWindow.openPath ?? tmuxState.initialWorkingDirectory
                return await executeLaunchTerminalWithTmux(
                    task: task,
                    tmuxState: tmuxState,
                    path: path,
                    snapshot: snapshot,
                    taskContext: taskContext,
                    targetFrame: targetFrame,
                    startTime: startTime
                )
            }
            return TaskResult(
                taskId: task.id,
                success: false,
                windowId: windowId,
                decision: task.decision,
                durationMs: durationMs(from: startTime),
                notes: ["Unable to choose a tmux client for switch and no tmuxState for fallback launch"],
                lockAcquired: task.hasLock
            )
        }

        guard let snapshotWindow = selectedWindow ?? self.snapshotWindowForClient(client, in: snapshot.base) else {
            DeskJigLog.debug(.restorationTrace, "Selected tmux client has no terminal window match", fields: [
                "taskId": taskContext.taskId,
                "clientTTY": client.clientTTY,
                "clientPID": client.clientPID,
                "selectionReason": selectionReason,
                "requestedWindowId": windowId
            ], runId: taskContext.runId)
            return TaskResult(
                taskId: task.id,
                success: false,
                windowId: windowId,
                decision: task.decision,
                durationMs: durationMs(from: startTime),
                notes: ["No terminal window matched the selected tmux client"],
                lockAcquired: task.hasLock
            )
        }

        let openPath = task.workspaceWindow.openPath ?? task.workspaceWindow.tmuxState?.initialWorkingDirectory
        let quickSwitchPreflight = await buildQuickSwitchTmuxPreflightDecision(
            bundleId: task.workspaceWindow.bundleIdentifier,
            sessionName: sessionName,
            currentSessionName: client.sessionName,
            snapshotWindow: snapshotWindow,
            targetFrame: targetFrame,
            expectedScreenIndex: task.workspaceWindow.screenIndex,
            tmuxIndex: task.tmuxManagedIndex,
            openPath: openPath,
            hasSelectedClient: true,
            hasStrongManagedEvidence: false,
            taskContext: taskContext
        )

        // Step 2: Switch the client to the target session
        let shouldSwitchSession = quickSwitchPreflight?.shouldSwitchSession ?? true
        var switchedSession = false
        if shouldSwitchSession {
            let switchStart = Date()
            do {
                try await tmux.switchClient(clientTTY: client.clientTTY, toSession: sessionName)
                switchedSession = true
                let switchMs = Int(Date().timeIntervalSince(switchStart) * 1000)
                DeskJigLog.debug(.restorationTrace, "Session switched", fields: [
                    "taskId": taskContext.taskId,
                    "clientTTY": client.clientTTY,
                    "fromSession": client.sessionName,
                    "toSession": sessionName,
                    "selectionReason": selectionReason,
                    "windowId": snapshotWindow.windowId,
                    "switchMs": switchMs
                ], runId: taskContext.runId)
            } catch {
                DeskJigLog.debug(.restorationTrace, "Failed to switch session", fields: [
                    "taskId": taskContext.taskId,
                    "clientTTY": client.clientTTY,
                    "targetSession": sessionName,
                    "error": error.localizedDescription
                ], runId: taskContext.runId)
                return TaskResult(
                    taskId: task.id,
                    success: false,
                    windowId: windowId,
                    decision: task.decision,
                    durationMs: durationMs(from: startTime),
                    notes: ["tmux switch-client failed: \(error.localizedDescription)"],
                    lockAcquired: task.hasLock
                )
            }
        }

        // Step 2b: Update window title to indexed managed title for reliable matching
        let shouldSetIndexedTitle = quickSwitchPreflight?.shouldSetIndexedTitle ?? true
        if shouldSetIndexedTitle, let tmuxIndex = task.tmuxManagedIndex {
            let indexedTitle = BundleRegistry.managedTmuxWindowTitle(
                bundleId: task.workspaceWindow.bundleIdentifier,
                index: tmuxIndex
            )
            do {
                try await setIndexedPaneTitleIfNeeded(tmux: tmux, session: sessionName, title: indexedTitle)
                DeskJigLog.debug(.restorationTrace, "Set indexed pane title after switch", fields: [
                    "taskId": taskContext.taskId,
                    "sessionName": sessionName,
                    "title": indexedTitle,
                    "tmuxIndex": tmuxIndex
                ], runId: taskContext.runId)
            } catch {
                // Non-fatal — log warning but don't fail the task
                DeskJigLog.debug(.restorationTrace, "Failed to set indexed pane title", fields: [
                    "taskId": taskContext.taskId,
                    "error": error.localizedDescription,
                    "title": indexedTitle,
                    "sessionName": sessionName
                ], runId: taskContext.runId)
            }
        }

        if quickSwitchPreflight?.action != .noOp {
            if let bootstrapResult = await bootstrapMissingTmuxIndexIfNeeded(
                task: task,
                snapshot: snapshot,
                targetFrame: targetFrame,
                taskContext: taskContext,
                startTime: startTime,
                phase: "post-switch",
                allowRetryLaunch: false
            ) {
                return bootstrapResult
            }
        }

        let shouldRepositionWindow = quickSwitchPreflight?.shouldRepositionWindow ?? true
        if !shouldRepositionWindow {
            // Anchor Terminal.app windows to prevent auto-cascade displacement
            let bundleId = task.workspaceWindow.bundleIdentifier
            if bundleId == BundleRegistry.terminal && task.hasLock {
                let anchorStrategy = Self.positioningStrategy(
                    switchedSession: switchedSession,
                    bundleId: bundleId,
                    workspaceWindow: task.workspaceWindow,
                    snapshotWindow: snapshotWindow
                )
                let anchorLocks = config.useWindowLocks && !task.hasLock
                let _ = await positioningService.positionSnapshotWindow(
                    snapshotWindow: snapshotWindow,
                    targetFrame: targetFrame,
                    taskContext: taskContext,
                    requesterId: task.id,
                    lockPriority: task.requiredPriority,
                    useWindowLocks: anchorLocks,
                    lockTimeout: config.lockTimeout,
                    preferredStrategy: anchorStrategy
                )
                DeskJigLog.debug(.restorationTrace, "Terminal.app anchored on switchOnly path", fields: [
                    "taskId": taskContext.taskId,
                    "windowId": snapshotWindow.windowId,
                    "targetFrame": "\(Int(targetFrame.origin.x)),\(Int(targetFrame.origin.y)) \(Int(targetFrame.width))x\(Int(targetFrame.height))"
                ], runId: taskContext.runId)
            }

            var notes: [String] = []
            if switchedSession {
                notes.append("tmux switch: \(client.sessionName) -> \(sessionName)")
            } else {
                notes.append("tmux switch skipped")
            }
            if selectionReason != "pid-tree-match" {
                notes.append("client selection=\(selectionReason)")
            }
            if let quickSwitchPreflight {
                notes.append("preflight=\(quickSwitchPreflight.action.rawValue)")
            }
            return TaskResult(
                taskId: task.id,
                success: true,
                windowId: snapshotWindow.windowId,
                decision: task.decision,
                durationMs: durationMs(from: startTime),
                notes: notes,
                lockAcquired: task.hasLock,
                plannedWindowId: snapshotWindow.windowId != windowId ? windowId : nil,
                terminalBinding: makeTerminalBindingResult(
                    task: task,
                    selectedWindowId: windowId,
                    finalWindowId: snapshotWindow.windowId,
                    selectedClientTTY: client.clientTTY,
                    wasLaunched: false
                )
            )
        }

        // Step 3: Position the window
        let positioningSnapshotWindow = snapshotWindow
        let nonFastPathPreferredStrategy = Self.positioningStrategy(
            switchedSession: switchedSession,
            bundleId: bundleId,
            workspaceWindow: task.workspaceWindow,
            snapshotWindow: positioningSnapshotWindow
        )
        let useWindowLocks = config.useWindowLocks && !task.hasLock
        let positioningResult = await positioningService.positionSnapshotWindow(
            snapshotWindow: positioningSnapshotWindow,
            targetFrame: targetFrame,
            taskContext: taskContext,
            requesterId: task.id,
            lockPriority: task.requiredPriority,
            useWindowLocks: useWindowLocks,
            lockTimeout: config.lockTimeout,
            preferredStrategy: nonFastPathPreferredStrategy
        )

        if let fallbackResult = await handleSwitchPositionFailureFallback(
            task: task,
            positioningResult: positioningResult,
            snapshot: snapshot,
            snapshotWindow: snapshotWindow,
            windowId: windowId,
            sessionName: sessionName,
            bundleId: bundleId,
            selectedClientTTY: client.clientTTY,
            targetFrame: targetFrame,
            taskContext: taskContext,
            startTime: startTime,
            phase: "position-failure",
            denialReason: "launch denied after switch positioning failure",
            fallbackLogMessage: "Switch-client positioning unresolved — falling back to launch"
        ) {
            return fallbackResult
        }

        var notes = switchedSession
            ? ["tmux switch: \(client.sessionName) -> \(sessionName)"]
            : ["tmux switch skipped"]
        if selectionReason != "pid-tree-match" {
            notes.append("client selection=\(selectionReason)")
        }
        if let quickSwitchPreflight {
            notes.append("preflight=\(quickSwitchPreflight.action.rawValue)")
        }
        if !positioningResult.matchesTarget {
            notes.append(Self.frameMismatchNote)
        }

        // If the fallback selected a different window than originally planned,
        // record the planned windowId so it can still be protected from post-restore cleanup.
        let actualWindowId = positioningResult.resolvedWindowId ?? positioningSnapshotWindow.windowId
        let plannedId: CGWindowID? = (actualWindowId != windowId) ? windowId : nil

        return TaskResult(
            taskId: task.id,
            success: positioningResult.success,
            windowId: actualWindowId,
            decision: task.decision,
            durationMs: durationMs(from: startTime),
            notes: notes,
            lockAcquired: task.hasLock,
            plannedWindowId: plannedId,
            terminalBinding: makeTerminalBindingResult(
                task: task,
                selectedWindowId: windowId,
                finalWindowId: actualWindowId,
                selectedClientTTY: client.clientTTY,
                wasLaunched: false
            )
        )
    }

    private func resolvedSwitchSnapshotWindow(
        task: RestorationTask,
        snapshot: SystemSnapshot,
        plannedWindowId: CGWindowID,
        bundleId: String,
        taskContext: RestorationTaskContext
    ) -> SnapshotWindow? {
        let requestedSnapshotWindow = snapshot.windows.first { $0.windowId == plannedWindowId }

        if let requestedSnapshotWindow,
           let tmuxIndex = task.tmuxManagedIndex,
           ManagedTmuxWindowTitleMatcher.matchesManagedIndex(
            requestedSnapshotWindow.title,
            bundleId: bundleId,
            index: tmuxIndex
           ) {
            return requestedSnapshotWindow
        }

        if Self.shouldUseSingleProcessTerminalWindowResolver(bundleId: bundleId),
           let tmuxIndex = task.tmuxManagedIndex {
            let bundleWindows = snapshot.windows.filter { $0.bundleId == bundleId }
            let indexedMatches = bundleWindows.filter {
                ManagedTmuxWindowTitleMatcher.matchesManagedIndex(
                    $0.title,
                    bundleId: bundleId,
                    index: tmuxIndex
                )
            }

            if indexedMatches.count == 1, let indexedMatch = indexedMatches.first {
                if indexedMatch.windowId != plannedWindowId {
                    DeskJigLog.debug(.restorationTrace, "Resolved switch snapshot window via indexed title override", fields: [
                        "taskId": taskContext.taskId,
                        "bundleId": bundleId,
                        "tmuxIndex": tmuxIndex,
                        "plannedWindowId": plannedWindowId,
                        "resolvedWindowId": indexedMatch.windowId,
                        "resolvedTitle": indexedMatch.title ?? "nil"
                    ], runId: taskContext.runId)
                }
                return indexedMatch
            }
        }

        return requestedSnapshotWindow ?? resolvedTmuxBindingSnapshotWindow(
            for: task,
            snapshot: snapshot,
            plannedWindowId: plannedWindowId
        )?.window
    }
}
