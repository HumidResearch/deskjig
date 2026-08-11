//  FluentWorkspaceRestorer+Phases.swift
//  DeskJigShared

import Foundation
import CoreGraphics

extension FluentWorkspaceRestorer {

    struct PhaseExecutionResult {
        let phaseName: String
        let plan: RestorationPlan
        let result: RestorationResult
        let planDurationMs: Int
        let executeDurationMs: Int
    }

    struct ExecutionProfileDecision: Equatable {
        let phaseExecutionMode: RestorationPhaseExecutionMode
        let sharedConcurrency: Int
        let singleTargetFastPathEnabled: Bool
        let reason: String
        let targetScreenCardinality: Int
    }

    func fetchITermWindowTTYBindings(runId: String) -> [CGWindowID: String] {
        let script = """
        tell application "iTerm2"
            set outputText to ""
            repeat with w in windows
                try
                    set sessionRef to current session of current tab of w
                    set outputText to outputText & (id of w as text) & "|" & (tty of sessionRef) & "\\n"
                end try
            end repeat
            return outputText
        end tell
        """

        let result = AppleScriptRunner.runOsascript(script, timeout: 1.8)
        guard result.exitCode == 0, !result.trimmedOutput.isEmpty else {
            return [:]
        }

        var bindings: [CGWindowID: String] = [:]
        for line in result.trimmedOutput.split(separator: "\n", omittingEmptySubsequences: true) {
            let parts = line.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false)
            let windowIdRaw = parts.count > 0 ? String(parts[0]).trimmingCharacters(in: .whitespacesAndNewlines) : ""
            let tty = parts.count > 1 ? String(parts[1]).trimmingCharacters(in: .whitespacesAndNewlines) : ""
            guard parts.count == 2,
                  let windowIdValue = UInt32(windowIdRaw),
                  !tty.isEmpty else {
                continue
            }
            bindings[CGWindowID(windowIdValue)] = tty
        }

        if !bindings.isEmpty {
            DeskJigLog.debug(.restorationTrace, "Fetched iTerm tty bindings for planning", fields: [
                "runId": runId,
                "bindingCount": "\(bindings.count)"
            ])
        }

        return bindings
    }

    func reconcileITermQuickSwitchClients(
        phaseResult: PhaseExecutionResult,
        runId: String,
        tmuxCommandService: TmuxCommandService
    ) async {
        let taskById = Dictionary(uniqueKeysWithValues: phaseResult.plan.tasks.map { ($0.id, $0) })
        let successfulITermResults = phaseResult.result.taskResults.filter { taskResult in
            guard taskResult.success,
                  let task = taskById[taskResult.taskId] else { return false }
            return task.workspaceWindow.bundleIdentifier == BundleRegistry.iterm2
        }

        guard !successfulITermResults.isEmpty else { return }

        guard await Task.sleepUnlessCancelled(for: .milliseconds(250)) else { return }

        let bindings = fetchITermWindowTTYBindings(runId: runId)
        guard !bindings.isEmpty else { return }
        guard let clients = try? await tmuxCommandService.listClients(),
              !clients.isEmpty else { return }

        for taskResult in successfulITermResults {
            guard let task = taskById[taskResult.taskId],
                  let targetSession = task.workspaceWindow.tmuxState?.sessionName else {
                continue
            }

            let resolvedWindowId = taskResult.terminalBinding?.finalWindowId
                ?? taskResult.windowId
                ?? taskResult.terminalBinding?.selectedWindowId
            guard let resolvedWindowId,
                  let mappedTTY = bindings[resolvedWindowId],
                  let client = clients.first(where: {
                    $0.clientTTY.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines) ==
                        mappedTTY.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
                  }) else {
                continue
            }

            guard client.sessionName != targetSession else { continue }

            DeskJigLog.debug(.restorationTrace, "Post-terminal iTerm client reconciliation", fields: [
                "runId": runId,
                "taskId": task.id,
                "windowId": "\(resolvedWindowId)",
                "mappedTTY": mappedTTY,
                "fromSession": client.sessionName,
                "toSession": targetSession,
                "tmuxIndex": task.tmuxManagedIndex.map(String.init) ?? "nil"
            ])

            do {
                try await tmuxCommandService.switchClient(clientTTY: client.clientTTY, toSession: targetSession)
                if let tmuxIndex = task.tmuxManagedIndex {
                    // Only set pane title if this session doesn't have extra clients
                    // from a previous workspace. Tmux pane titles are per-session, so
                    // setting it here would contaminate other windows still attached
                    // to the same session (causing duplicate iterm:0 titles).
                    let postSwitchClients = (try? await tmuxCommandService.listClients()) ?? []
                    let sessionClientCount = postSwitchClients.filter { $0.sessionName == targetSession }.count
                    if sessionClientCount <= 1 {
                        try await tmuxCommandService.ensureTitlePropagation()
                        try await tmuxCommandService.setPaneTitle(
                            session: targetSession,
                            title: BundleRegistry.managedTmuxWindowTitle(
                                bundleId: task.workspaceWindow.bundleIdentifier,
                                index: tmuxIndex
                            )
                        )
                    }
                }
            } catch {
                DeskJigLog.debug(.restorationTrace, "Post-terminal iTerm reconciliation failed", fields: [
                    "runId": runId,
                    "taskId": task.id,
                    "windowId": "\(resolvedWindowId)",
                    "mappedTTY": mappedTTY,
                    "fromSession": client.sessionName,
                    "toSession": targetSession,
                    "error": error.localizedDescription
                ])
            }
        }
    }

    func awaitSupplementation(
        task: Task<SystemSnapshot, Never>?,
        fallback: SystemSnapshot,
        runId: String,
        label: String,
        timeout: Duration
    ) async -> SystemSnapshot {
        guard let task else { return fallback }

        return await withTaskGroup(of: SystemSnapshot.self) { group in
            group.addTask {
                await task.value
            }
            group.addTask {
                do {
                    try await Task.sleep(for: timeout)
                } catch {
                    // Cancelled because supplementation finished first.
                    return fallback
                }
                DeskJigLog.debug(.restorationTrace, "Supplementation timeout", fields: [
                    "runId": runId,
                    "phase": label,
                    "timeoutMs": "\(Int(timeout.components.seconds * 1000))"
                ])
                return fallback
            }

            let result = await group.next() ?? fallback
            group.cancelAll()
            return result
        }
    }

    func partitionWindows(
        _ windows: [WorkspaceWindow]
    ) -> (other: [WorkspaceWindow], slowStarts: [WorkspaceWindow], terminals: [WorkspaceWindow], ides: [WorkspaceWindow], chromes: [WorkspaceWindow]) {
        var other: [WorkspaceWindow] = []
        var slowStarts: [WorkspaceWindow] = []
        var terminals: [WorkspaceWindow] = []
        var ides: [WorkspaceWindow] = []
        var chromes: [WorkspaceWindow] = []

        for window in windows {
            let bundleId = window.bundleIdentifier
            if isChromeBundleId(bundleId) {
                chromes.append(window)
                continue
            }
            if BundleRegistry.isTerminal(bundleId) {
                terminals.append(window)
                continue
            }
            if BundleRegistry.isIDE(bundleId) {
                ides.append(window)
                continue
            }
            if BundleRegistry.isSlowStart(bundleId) {
                slowStarts.append(window)
                continue
            }
            other.append(window)
        }

        return (other: other, slowStarts: slowStarts, terminals: terminals, ides: ides, chromes: chromes)
    }

    func workspaceForPhase(base: Workspace, windows: [WorkspaceWindow]) -> Workspace {
        Workspace(
            id: base.id,
            name: base.name,
            icon: base.icon,
            keyboardShortcut: base.keyboardShortcut,
            workspaceWindows: windows,
            screens: base.screens
        )
    }

    func executePhase(
        phaseName: String,
        runId: String,
        workspace: Workspace,
        snapshot: EnhancedSnapshot,
        currentScreens: [FullScreenInfo],
        resolvedWindowTargets: [UUID: ResolvedWorkspaceWindowTarget],
        options: RestorationOptions,
        chromeCaptures: [ChromeAppleScriptWindowCapture],
        executor: RestorationExecutor,
        tmuxSessionManager: TmuxSessionManager? = nil,
        tmuxClientWindowMap: [pid_t: CGWindowID] = [:],
        tmuxClients: [TmuxClientInfo] = [],
        tmuxTerminalRestoreContext: TmuxTerminalRestoreContext? = nil
    ) async -> PhaseExecutionResult {
        guard !workspace.windows.isEmpty else {
            let plan = RestorationPlan(
                runId: runId,
                workspace: workspace,
                snapshot: snapshot,
                tasks: [],
                tmuxTerminalRestoreContext: tmuxTerminalRestoreContext,
                createdAt: Date(),
                buildDurationMs: 0
            )
            let result = RestorationResult(
                runId: runId,
                success: true,
                totalDurationMs: 0,
                successCount: 0,
                failureCount: 0,
                skippedCount: 0,
                taskResults: []
            )
            return PhaseExecutionResult(
                phaseName: phaseName,
                plan: plan,
                result: result,
                planDurationMs: 0,
                executeDurationMs: 0
            )
        }

        DeskJigLog.debug(.restorationTrace, "Phase \(phaseName): Building plan", fields: [
            "windowCount": "\(workspace.windows.count)"
        ])

        let plan = await RestorationPlanBuilder(runId: runId)
            .forWorkspace(workspace)
            .withSnapshot(snapshot)
            .withLockManager(lockManager)
            .withLockTimeout(options.lockTimeout)
            .withCurrentScreens(currentScreens)
            .withResolvedWindowTargets(resolvedWindowTargets)
            .withMatchConfiguration(options.matchConfiguration)
            .withChromeCaptures(chromeCaptures)
            .withChromeMatchMethod(options.chromeMatchMethod)
            .withTmuxSessionManager(tmuxSessionManager)
            .withTmuxClientWindowMap(tmuxClientWindowMap)
            .withTmuxClients(tmuxClients)
            .withTmuxTerminalRestoreContext(tmuxTerminalRestoreContext)
            .analyze()
            .acquireLocks()
            .build()

        DeskJigLog.debug(.restorationTrace, "Phase \(phaseName): Plan built: \(plan.readyCount) ready, \(plan.blockedCount) blocked", fields: [
            "durationMs": "\(plan.buildDurationMs)",
            "positionTasks": "\(plan.positionTasks.count)",
            "launchTasks": "\(plan.launchTasks.count)"
        ])

        return await logAndExecutePlan(phaseName: phaseName, plan: plan, executor: executor)
    }

    /// Executes an existing plan without rebuilding it.
    /// Used by slowStart phase to avoid lock conflicts from plan rebuilds.
    func executePlan(
        phaseName: String,
        plan: RestorationPlan,
        executor: RestorationExecutor
    ) async -> PhaseExecutionResult {
        DeskJigLog.debug(.restorationTrace, "Phase \(phaseName): Executing existing plan: \(plan.readyCount) ready, \(plan.blockedCount) blocked", fields: [
            "durationMs": "\(plan.buildDurationMs)",
            "positionTasks": "\(plan.positionTasks.count)",
            "launchTasks": "\(plan.launchTasks.count)"
        ])

        return await logAndExecutePlan(phaseName: phaseName, plan: plan, executor: executor)
    }

    /// Shared plan logging, execution, and result logging.
    /// Used by both `executePhase()` (after building a plan) and `executePlan()` (with a pre-built plan).
    private func logAndExecutePlan(
        phaseName: String,
        plan: RestorationPlan,
        executor: RestorationExecutor
    ) async -> PhaseExecutionResult {
        // Mirror plan summary to main log for production diagnostics
        DeskJigLog.info(.restorationPlanner, "Phase \(phaseName): \(plan.readyCount) ready, \(plan.blockedCount) blocked (\(plan.buildDurationMs)ms)", runId: plan.runId)
        for task in plan.tasks {
            let decisionDesc = describeDecision(task.decision)
            let match = task.matchResult
            let methodName = match.method.description
            let conf = String(format: "%.0f%%", match.confidence * 100)
            let windowInfo = match.window.map { "wid:\($0.windowId) '\($0.title ?? "?")'" } ?? "no-match"
            DeskJigLog.info(.restorationPlanner, "\(phaseName): \(task.workspaceWindow.appName) → \(decisionDesc) match=\(methodName)(\(conf)) \(windowInfo) openPath=\(task.workspaceWindow.openPath ?? "none")", runId: plan.runId)
        }

        let lockedTasks = plan.tasks.filter { $0.hasLock }
        if !lockedTasks.isEmpty {
            let lockDetails = lockedTasks.map { task in
                let appName = task.workspaceWindow.appName
                let windowId = String(task.lock?.windowId ?? 0)
                return appName + "(windowId:" + windowId + ")"
            }.joined(separator: ", ")
            let lockMsg = "Phase " + phaseName + " Locks acquired: " +
                String(lockedTasks.count) + "/" + String(plan.positionTasks.count) + " - " + lockDetails
            DeskJigLog.debug(.restorationTrace, lockMsg)
        }

        let executeStartTime = Date()
        let result = await executor.execute(plan)
        let executeDurationMs = Int(Date().timeIntervalSince(executeStartTime) * 1000)

        DeskJigLog.debug(.restorationTrace, "Phase \(phaseName): Execution complete: \(result.successCount) success, \(result.failureCount) failed", fields: ["durationMs": "\(executeDurationMs)"])

        for taskResult in result.taskResults where !taskResult.success {
            let notes = taskResult.notes.joined(separator: ", ")
            DeskJigLog.debug(.restorationTrace, "Phase \(phaseName) FAILED[\(taskResult.taskId.prefix(8))]: \(describeDecision(taskResult.decision)) - \(notes)", fields: ["windowId": taskResult.windowId.map { String($0) } ?? "none"])
        }

        return PhaseExecutionResult(
            phaseName: phaseName,
            plan: plan,
            result: result,
            planDurationMs: plan.buildDurationMs,
            executeDurationMs: executeDurationMs
        )
    }

    static func resolveExecutionProfile(
        deterministicPositioningEnabled: Bool,
        requestedPhaseExecutionMode: RestorationPhaseExecutionMode,
        requestedMaxConcurrency: Int,
        mappedWindowCount: Int,
        mappedWindowScreenIndices: [Int],
        hasTerminalWindows: Bool,
        hasIDEWindows: Bool,
        launchSource: String
    ) -> ExecutionProfileDecision {
        let targetScreenCardinality = Set(mappedWindowScreenIndices).count
        let hasCompleteTargetScreens = mappedWindowCount > 0 && mappedWindowScreenIndices.count == mappedWindowCount
        let hasSingleTargetDisplay = hasCompleteTargetScreens && targetScreenCardinality == 1

        if deterministicPositioningEnabled {
            // Handle cases where we can't determine display targets
            if mappedWindowCount == 0 {
                return ExecutionProfileDecision(
                    phaseExecutionMode: .sequential,
                    sharedConcurrency: 1,
                    singleTargetFastPathEnabled: false,
                    reason: "no-mapped-windows",
                    targetScreenCardinality: targetScreenCardinality
                )
            }
            if mappedWindowScreenIndices.isEmpty {
                return ExecutionProfileDecision(
                    phaseExecutionMode: .sequential,
                    sharedConcurrency: 1,
                    singleTargetFastPathEnabled: false,
                    reason: "no-target-screens",
                    targetScreenCardinality: targetScreenCardinality
                )
            }
            if mappedWindowScreenIndices.count != mappedWindowCount {
                return ExecutionProfileDecision(
                    phaseExecutionMode: .sequential,
                    sharedConcurrency: 1,
                    singleTargetFastPathEnabled: false,
                    reason: "missing-target-screens",
                    targetScreenCardinality: targetScreenCardinality
                )
            }

            // Multi-display: allow per-display parallelism.
            // Clamp compensation uses 5px adjacency tolerance, so windows on different
            // displays (thousands of pixels apart) can never be clamp neighbors.
            if !hasSingleTargetDisplay && targetScreenCardinality > 1 {
                if launchSource == quickSwitchLaunchSource {
                    return ExecutionProfileDecision(
                        phaseExecutionMode: .parallel,
                        sharedConcurrency: max(2, targetScreenCardinality),
                        singleTargetFastPathEnabled: false,
                        reason: "multi-display-lane-parallel",
                        targetScreenCardinality: targetScreenCardinality
                    )
                }
                return ExecutionProfileDecision(
                    phaseExecutionMode: .sequential,
                    sharedConcurrency: targetScreenCardinality,
                    singleTargetFastPathEnabled: false,
                    reason: "multi-display-lane-sequential",
                    targetScreenCardinality: targetScreenCardinality
                )
            }

            // Single display: require both terminal and IDE phases for fast-path
            guard hasTerminalWindows else {
                return ExecutionProfileDecision(
                    phaseExecutionMode: .sequential,
                    sharedConcurrency: 1,
                    singleTargetFastPathEnabled: false,
                    reason: "missing-terminal-phase",
                    targetScreenCardinality: targetScreenCardinality
                )
            }

            guard hasIDEWindows else {
                // Terminal-only single display: allow parallel execution.
                // Clamp compensation adjusts neighbors retroactively.
                return ExecutionProfileDecision(
                    phaseExecutionMode: .parallel,
                    sharedConcurrency: min(mappedWindowCount, 4),
                    singleTargetFastPathEnabled: false,
                    reason: "terminal-only-parallel",
                    targetScreenCardinality: targetScreenCardinality
                )
            }

            return ExecutionProfileDecision(
                phaseExecutionMode: .parallel,
                sharedConcurrency: 3,
                singleTargetFastPathEnabled: true,
                reason: "single-target-fast-path",
                targetScreenCardinality: targetScreenCardinality
            )
        }

        let sharedConcurrency = max(1, requestedMaxConcurrency)
        let phaseExecutionMode: RestorationPhaseExecutionMode
        switch requestedPhaseExecutionMode {
        case .automatic:
            phaseExecutionMode = sharedConcurrency > 1 ? .parallel : .sequential
        case .sequential, .parallel:
            phaseExecutionMode = requestedPhaseExecutionMode
        }

        return ExecutionProfileDecision(
            phaseExecutionMode: phaseExecutionMode,
            sharedConcurrency: sharedConcurrency,
            singleTargetFastPathEnabled: false,
            reason: "deterministic-disabled",
            targetScreenCardinality: targetScreenCardinality
        )
    }

    static func phaseExecutionOrder(for mode: RestorationPhaseExecutionMode) -> [String] {
        switch mode {
        case .parallel:
            return ["other", "terminal", "ide", "chrome", "slowStart"]
        case .sequential, .automatic:
            return ["other", "slowStart", "terminal", "ide", "chrome"]
        }
    }

    func mergePlans(
        runId: String,
        workspace: Workspace,
        snapshot: EnhancedSnapshot,
        phases: [PhaseExecutionResult],
        buildDurationMs: Int
    ) -> RestorationPlan {
        let tasks = phases.flatMap { $0.plan.tasks }
        return RestorationPlan(
            runId: runId,
            workspace: workspace,
            snapshot: snapshot,
            tasks: tasks,
            tmuxTerminalRestoreContext: phases.compactMap(\.plan.tmuxTerminalRestoreContext).last,
            createdAt: Date(),
            buildDurationMs: buildDurationMs
        )
    }

    func isChromeBundleId(_ bundleId: String) -> Bool {
        bundleId == "com.google.Chrome" || bundleId == "com.google.Chrome.canary"
    }

    func isSkipped(_ decision: RestorationDecision) -> Bool {
        if case .skip = decision { return true }
        return false
    }

    private func describeDecision(_ decision: RestorationDecision) -> String {
        switch decision {
        case .positionExisting(let windowId, let targetFrame):
            return "positionExisting(windowId:\(windowId), frame:\(Int(targetFrame.origin.x)),\(Int(targetFrame.origin.y)) \(Int(targetFrame.width))x\(Int(targetFrame.height)))"
        case .openNewWithPath(let bundleId, let path, _):
            return "openNewWithPath(bundle:\(bundleId.split(separator: ".").last ?? ""), path:\(path))"
        case .launchApp(let bundleId, let then):
            let thenDesc = then.map { " then:\(describeDecision($0))" } ?? ""
            return "launchApp(bundle:\(bundleId.split(separator: ".").last ?? ""))\(thenDesc)"
        case .createChromeWindow(let profile, let tabs, _):
            return "createChromeWindow(profile:\(profile), tabs:\(tabs.count))"
        case .reuseChromeWindow(let windowId, let tabs, _):
            return "reuseChromeWindow(windowId:\(windowId), tabs:\(tabs.count))"
        case .switchTmuxSession(let windowId, let sessionName, _):
            return "switchTmuxSession(windowId:\(windowId), session:\(sessionName))"
        case .skip(let reason):
            return "skip(\(reason))"
        case .failed(let reason):
            return "failed(\(reason))"
        }
    }
}
