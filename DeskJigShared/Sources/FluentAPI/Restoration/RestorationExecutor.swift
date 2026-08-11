//  RestorationExecutor.swift
//  DeskJigShared

import Foundation
import CoreGraphics
import AppKit

public struct RestorationExecutorConfig: Sendable {
    public let lockTimeout: Duration
    public let useWindowLocks: Bool
    public let terminalFetchMethod: TerminalFetchMethod
    public let ideFetchMethod: IDEFetchMethod
    public let chromeMatchMethod: MatchMethod
    public let launchSource: String
    public var previouslyLaunchedChromeProfiles: Set<String> = []

    public var enableTerminalSupplementation: Bool {
        terminalFetchMethod != .disabled
    }

    public var enableIDESupplementation: Bool {
        ideFetchMethod != .disabled
    }

    public init(
        lockTimeout: Duration = .seconds(10),
        useWindowLocks: Bool = true,
        terminalFetchMethod: TerminalFetchMethod = .axWithLsofFallback,
        ideFetchMethod: IDEFetchMethod = .cursorStateWithAXFallback,
        chromeMatchMethod: MatchMethod = .chromeProfile,
        launchSource: String = "unknown",
        previouslyLaunchedChromeProfiles: Set<String> = []
    ) {
        self.lockTimeout = lockTimeout
        self.useWindowLocks = useWindowLocks
        self.terminalFetchMethod = terminalFetchMethod
        self.ideFetchMethod = ideFetchMethod
        self.chromeMatchMethod = chromeMatchMethod
        self.launchSource = launchSource
        self.previouslyLaunchedChromeProfiles = previouslyLaunchedChromeProfiles
    }
}

// MARK: - Restoration Executor

/// Executes restoration tasks using the Queue system.
///
/// `RestorationExecutor` takes a ``RestorationPlan`` and executes all tasks,
/// handling:
/// - Parallel execution of independent tasks
/// - Window positioning via WindowHandle
/// - App launching for new windows
/// - Chrome window creation and tab restoration
/// - Lock release after task completion
///
/// ## Overview
///
/// The executor uses the Fluent API Queue system for parallel execution
/// with configurable concurrency. Tasks are executed based on their
/// decision type:
/// - `.positionExisting`: Move existing window to target frame
/// - `.openNewWithPath`: Launch app with directory
/// - `.launchApp`: Launch app and wait for window
/// - `.createChromeWindow`: Create Chrome window with tabs
/// - `.reuseChromeWindow`: Restore tabs to existing window
///
/// ## Example
///
/// ```swift
/// let executor = RestorationExecutor(lockManager: lockManager)
///
/// let result = await executor.execute(plan)
///
/// print("Success: \(result.successCount)/\(result.totalCount)")
/// print("Duration: \(result.totalDurationMs)ms")
/// ```
///
/// ## See Also
/// - ``RestorationPlan``
/// - ``RestorationTask``
/// - ``WindowLockManager``
public actor RestorationExecutor {

    // MARK: - Properties

    let lockManager: WindowLockManager
    let maxConcurrency: Int
    let taskTimeout: Duration
    let config: RestorationExecutorConfig
    let positioningService: WindowPositioningService
    let openByPathRestorationService: OpenByPathRestorationService
    let genericRestorationService: GenericWindowRestorationService
    let laneCoordinator: DisplayLaneCoordinator?
    let chromeMatcher = ChromeWindowMatcher()
    var chromeWorkspaceProfileDirectories: Set<String> = []
    var launchedChromeProfiles: Set<String> = []
    let tmuxCommandService: TmuxCommandService?
    let tmuxIndexEnforcementPolicy: TmuxIndexEnforcementPolicy = .strictCoverage
    var tmuxExpectedIndicesByBundle: [String: Set<Int>] = [:]
    var tmuxTaskByBundleAndIndex: [String: [Int: RestorationTask]] = [:]
    var tmuxRepairBudgetSpentMsByBundle: [String: Int] = [:]
    var tmuxBootstrapCountByBundleAndIndex: [String: [Int: Int]] = [:]
    var tmuxLastLaunchAtByBundleAndIndex: [String: [Int: Date]] = [:]
    var tmuxManagedVisibilityCache: [String: (state: ManagedTmuxIndexVisibilityState, timestamp: Date)] = [:]
    var tmuxClaimedClientTTYsByBundle: [String: Set<String>] = [:]
    var tmuxClaimedSessionsByBundle: [String: Set<String>] = [:]
    /// Window IDs claimed by tasks during post-launch detection. Prevents
    /// single-process terminals (Terminal.app) from having two tasks resolve
    /// to the same window via PID-based fallback.
    var postLaunchClaimedWindowIds: Set<CGWindowID> = []
    /// Serializes the full launch→detect→position cycle for Terminal.app.
    /// Terminal.app is a single-process app; concurrent `open -a Terminal` calls
    /// cause it to auto-cascade all windows, breaking positioning of already-placed
    /// windows. Other terminals (Ghostty, Kitty, iTerm, Alacritty) use independent
    /// processes and remain fully concurrent.
    let terminalAppLaunchSemaphore = AsyncSemaphore(permits: 1)
    var iTermTTYBindingCacheByRun: [String: (rows: [String], timestamp: Date)] = [:]
    /// In-flight iTerm TTY-binding fetch per run. Detaching the osascript off the actor
    /// (exec-01) removes the implicit serialization that previously prevented concurrent
    /// terminal tasks from each launching their own osascript; this map coalesces same-run
    /// callers onto a single fetch (no thundering herd).
    var iTermFetchInFlightByRun: [String: Task<[ITermWindowTTYBinding], Never>] = [:]
    /// Tracks whether `ensureTitlePropagation()` has been called this run to avoid redundant tmux calls.
    var titlePropagationConfigured = false
    let tmuxRepairBudgetLimitMs = 2_400
    let tmuxBootstrapLaunchGraceMs = 2_500

    struct ManagedTmuxResetStats {
        let targetCount: Int
        let preResetTerminalWindowCount: Int
        let managedWindowCount: Int
        let destructiveActions: Int
        let resetMode: String
        let resetReason: String

        var resetCount: Int { destructiveActions }

        static let empty = ManagedTmuxResetStats(
            targetCount: 0,
            preResetTerminalWindowCount: 0,
            managedWindowCount: 0,
            destructiveActions: 0,
            resetMode: "none",
            resetReason: "not-required"
        )
    }

    // MARK: - Initialization

    /// Creates a new restoration executor.
    ///
    /// - Parameters:
    ///   - lockManager: The lock manager for releasing locks
    ///   - maxConcurrency: Maximum parallel tasks (defaults to 4)
    ///   - taskTimeout: Timeout per task (defaults to 30 seconds)
    ///   - config: Execution configuration for open-by-path and positioning behavior
    public init(
        lockManager: WindowLockManager,
        maxConcurrency: Int = 4,
        taskTimeout: Duration = .seconds(30),
        config: RestorationExecutorConfig = RestorationExecutorConfig(),
        laneCoordinator: DisplayLaneCoordinator? = nil,
        tmuxCommandService: TmuxCommandService? = nil
    ) {
        self.lockManager = lockManager
        self.maxConcurrency = maxConcurrency
        self.taskTimeout = taskTimeout
        self.config = config
        self.laneCoordinator = laneCoordinator
        self.tmuxCommandService = tmuxCommandService
        let positioningService = WindowPositioningService(
            lockManager: lockManager,
            defaultLockTimeout: config.lockTimeout
        )
        self.positioningService = positioningService
        self.openByPathRestorationService = OpenByPathRestorationService(positioningService: positioningService)
        self.genericRestorationService = GenericWindowRestorationService(positioningService: positioningService)
    }

    // MARK: - Execution

    /// Executes a restoration plan.
    ///
    /// Runs all ready tasks in parallel (up to maxConcurrency) and
    /// releases locks after completion.
    ///
    /// - Parameter plan: The restoration plan to execute
    /// - Returns: Aggregate result of all task executions
    ///
    /// ## Example
    ///
    /// ```swift
    /// let result = await executor.execute(plan)
    ///
    /// for taskResult in result.taskResults {
    ///     if taskResult.success {
    ///         print("[\(taskResult.taskId)] Restored in \(taskResult.durationMs)ms")
    ///     } else {
    ///         print("[\(taskResult.taskId)] Failed: \(taskResult.notes)")
    ///     }
    /// }
    /// ```
    public func execute(_ plan: RestorationPlan) async -> RestorationResult {
        let startTime = Date()
        var taskResults: [TaskResult] = []
        var additionalLocks: [WindowLock] = []
        chromeWorkspaceProfileDirectories = chromeProfileDirectories(in: plan.workspace)
        rebuildTmuxCoverageContext(from: plan)

        // Execute ready tasks using Queue system
        let readyTasks = plan.readyTasks

        taskResults.append(contentsOf: await executeTasks(readyTasks, snapshot: plan.snapshot))

        let awaitingTasks = plan.tasks.filter { $0.lockResult?.isAwaitingSupplementation == true }
        if !awaitingTasks.isEmpty {
            DeskJigLog.debug(.restorationTrace, "Retrying locks awaiting Chrome supplementation", fields: [
                "taskCount": awaitingTasks.count
            ], runId: plan.runId)
            await Task.sleepUnlessCancelled(nanoseconds: 100_000_000)
            let retryOutcome = await retryAwaitingSupplementationLocks(awaitingTasks)
            additionalLocks.append(contentsOf: retryOutcome.acquiredLocks)
            taskResults.append(contentsOf: await executeTasks(retryOutcome.readyTasks, snapshot: plan.snapshot))
            taskResults.append(contentsOf: retryOutcome.failedResults)
        }

        let tmuxReconciliationResults = await reconcileTmuxManagedIndexCoverage(
            plan: plan
        )
        taskResults.append(contentsOf: tmuxReconciliationResults)

        // Add skipped/failed tasks from planning
        for task in plan.skippedTasks {
            taskResults.append(TaskResult(
                taskId: task.id,
                success: false,
                decision: task.decision,
                durationMs: 0,
                notes: ["Skipped during planning"]
            ))
        }

        for task in plan.failedTasks {
            taskResults.append(TaskResult(
                taskId: task.id,
                success: false,
                decision: task.decision,
                durationMs: 0,
                notes: ["Failed during planning"]
            ))
        }

        // Add blocked tasks (lock-denied) that were never executed.
        // Previously these silently disappeared from the results, making
        // the summary report success when tasks actually never ran.
        let executedTaskIds = Set(taskResults.map(\.taskId))
        for task in plan.blockedTasks where !executedTaskIds.contains(task.id) {
            let lockReason: String
            if case .denied(let reason, let holder) = task.lockResult {
                lockReason = "Lock denied: \(reason) (holder: \(holder ?? "unknown"))"
            } else {
                lockReason = "Blocked waiting for lock"
            }
            taskResults.append(TaskResult(
                taskId: task.id,
                success: false,
                decision: task.decision,
                durationMs: 0,
                notes: [lockReason]
            ))
        }

        // Release all locks
        let locksToRelease = plan.tasks.compactMap { $0.lock } + additionalLocks
        for lock in locksToRelease {
            await lockManager.releaseLock(lock)
        }

        // Calculate statistics
        let successCount = taskResults.filter { $0.success }.count
        let failureCount = taskResults.filter { !$0.success && !isSkipped($0.decision) }.count
        let skippedCount = taskResults.filter { isSkipped($0.decision) }.count
        let totalDurationMs = Int(Date().timeIntervalSince(startTime) * 1000)

        return RestorationResult(
            runId: plan.runId,
            success: failureCount == 0,
            totalDurationMs: totalDurationMs,
            successCount: successCount,
            failureCount: failureCount,
            skippedCount: skippedCount,
            taskResults: taskResults
        )
    }

    // MARK: - Task Execution

    /// Executes a single restoration task.
    ///
    /// - Parameters:
    ///   - task: The task to execute
    ///   - snapshot: The system snapshot for reference
    /// - Returns: The task result
    public func executeTask(
        _ task: RestorationTask,
        snapshot: EnhancedSnapshot
    ) async -> TaskResult {
        let startTime = Date()
        let runId = snapshot.base.runId
        let taskContext = RestorationTaskContext(
            taskId: task.id,
            taskType: taskType(for: task.workspaceWindow.bundleIdentifier),
            startTime: startTime,
            runId: runId
        )

        DeskJigLog.debug(.restorationTrace, "Task start", fields: taskStartFields(for: task, taskContext: taskContext), runId: runId)

        let result: TaskResult

        switch task.decision {
        case .positionExisting(_, let targetFrame):
            result = await executePositionExisting(
                task: task,
                snapshotWindow: task.matchResult.window,
                taskContext: taskContext,
                targetFrame: targetFrame,
                startTime: startTime
            )

        case .openNewWithPath(let bundleId, let path, let targetFrame):
            DeskJigLog.info(.restorationPlanner, "Executing openNewWithPath", fields: ["app": task.workspaceWindow.appName, "bundleId": bundleId, "path": path], runId: runId)
            result = await executeOpenNewWithPath(
                task: task,
                bundleId: bundleId,
                path: path,
                snapshot: snapshot,
                taskContext: taskContext,
                targetFrame: targetFrame,
                startTime: startTime
            )

        case .launchApp(let bundleId, _):
            result = await executeLaunchApp(
                task: task,
                bundleId: bundleId,
                snapshot: snapshot,
                taskContext: taskContext,
                startTime: startTime
            )

        case .createChromeWindow(let profile, let tabs, let targetFrame):
            result = await executeCreateChromeWindow(
                task: task,
                profile: profile,
                tabs: tabs,
                targetFrame: targetFrame,
                taskContext: taskContext,
                startTime: startTime
            )

        case .reuseChromeWindow(let windowId, let tabs, let targetFrame):
            result = await executeReuseChromeWindow(
                task: task,
                snapshot: snapshot,
                snapshotWindow: task.matchResult.window,
                windowId: windowId,
                tabs: tabs,
                targetFrame: targetFrame,
                taskContext: taskContext,
                startTime: startTime
            )

        case .switchTmuxSession(let windowId, let sessionName, let targetFrame):
            result = await executeSwitchTmuxSession(
                task: task,
                snapshot: snapshot,
                windowId: windowId,
                sessionName: sessionName,
                targetFrame: targetFrame,
                taskContext: taskContext,
                startTime: startTime
            )

        case .skip(let reason):
            result = TaskResult(
                taskId: task.id,
                success: false,
                decision: task.decision,
                durationMs: 0,
                notes: ["Skipped: \(reason)"]
            )

        case .failed(let reason):
            result = TaskResult(
                taskId: task.id,
                success: false,
                decision: task.decision,
                durationMs: 0,
                notes: ["Failed: \(reason)"]
            )
        }

        let visibility = await captureAppVisibilityIfNeeded(
            bundleId: task.workspaceWindow.bundleIdentifier,
            taskType: taskContext.taskType
        )
        DeskJigLog.debug(.restorationTrace, "Task complete", fields: taskCompletionFields(for: task, result: result, visibility: visibility, taskContext: taskContext), runId: taskContext.runId)

        return result
    }

    // MARK: - Strategy Helpers

    /// After a tmux session switch the window title reflects the new session,
    /// but the snapshot still has the OLD title. Title-based matching fails,
    /// so fall back to PID (Terminal.app) or frame-only (others).
    static func positioningStrategy(
        switchedSession: Bool,
        bundleId: String,
        workspaceWindow: WorkspaceWindow,
        snapshotWindow: SnapshotWindow
    ) -> AXMatchingStrategy {
        guard switchedSession else {
            return WindowHandleResolver.preferredStrategy(
                workspaceWindow: workspaceWindow,
                snapshotWindow: snapshotWindow
            )
        }
        return bundleId == BundleRegistry.terminal ? .pidFirstWindow : .frameOnly
    }

    // MARK: - Helpers

    /// Single source of truth for the post-positioning frame-mismatch note. Appears in
    /// taskCompletionFields, so the string must stay byte-identical (I-8) — centralizing it
    /// here keeps the 7 emission sites from drifting.
    static let frameMismatchNote = "Frame mismatch after positioning"

    func findWindowHandle(for windowId: CGWindowID) async -> WindowHandle? {
        // Use Window.find with windowId to get a handle
        return await MainActor.run {
            let result = Window.findWithResult(windowId: windowId)
            return result.window
        }
    }

    static func cgWindowId(fromAXWindowNumber value: Int?) -> CGWindowID? {
        guard let value, value >= 0, value <= Int(UInt32.max) else { return nil }
        return CGWindowID(value)
    }

    static func frameDistance(_ lhs: CGRect?, _ rhs: CGRect) -> CGFloat {
        guard let lhs else { return .greatestFiniteMagnitude }
        return lhs.manhattanDistance(to: rhs)
    }

    private struct AppVisibility: Sendable {
        let pid: pid_t?
        let isHidden: Bool
        let visibleWindowCount: Int
        let isRunning: Bool
    }

    private func taskStartFields(for task: RestorationTask, taskContext: RestorationTaskContext) -> [String: any Sendable] {
        let screenLabel = task.targetScreenIndex.map(String.init) ?? "unassigned"
        var fields: [String: any Sendable] = [
            "taskId": taskContext.taskId,
            "app": task.workspaceWindow.appName,
            "bundleId": task.workspaceWindow.bundleIdentifier,
            "decision": task.decision.description,
            "screenIndex": screenLabel,
            "lockRequired": task.requiresLock,
            "lockAcquired": task.hasLock
        ]

        if let openPath = task.workspaceWindow.openPath {
            fields["openPath"] = openPath
        }

        let targetFrame = task.decision.targetFrame ?? task.targetFrame
        fields["targetFrame"] = targetFrame

        if let existingWindowId = task.decision.existingWindowId {
            fields["existingWindowId"] = Int(existingWindowId)
        }

        if let lockResult = task.lockResult {
            fields["lockResult"] = lockResultSummary(lockResult)
        }

        if let chromeTargetProfile = task.chromeTargetProfile {
            fields["storedProfileDirectory"] = chromeTargetProfile.storedProfileDirectory ?? "none"
            fields["resolvedProfileDirectory"] = chromeTargetProfile.resolvedProfileDirectory ?? "none"
            fields["storedHostedDomain"] = chromeTargetProfile.storedHostedDomain ?? "none"
            fields["resolvedBy"] = chromeTargetProfile.resolvedBy
            fields["fallbackReason"] = chromeTargetProfile.fallbackReason ?? "none"
        }

        return fields
    }

    static func laneKey(for targetScreenIndex: Int?) -> RestorationLaneKey {
        if let targetScreenIndex {
            return .screen(targetScreenIndex)
        }
        return .unassigned
    }

    private func taskCompletionFields(
        for task: RestorationTask,
        result: TaskResult,
        visibility: AppVisibility?,
        taskContext: RestorationTaskContext
    ) -> [String: any Sendable] {
        var fields: [String: any Sendable] = [
            "taskId": taskContext.taskId,
            "app": task.workspaceWindow.appName,
            "bundleId": task.workspaceWindow.bundleIdentifier,
            "decision": result.decision.description,
            "durationMs": result.durationMs,
            "success": result.success
        ]

        if let windowId = result.windowId {
            fields["windowId"] = Int(windowId)
        }

        if !result.notes.isEmpty {
            fields["notes"] = result.notes.joined(separator: " | ")
        }

        if let visibility {
            fields["appRunning"] = visibility.isRunning
            if let pid = visibility.pid {
                fields["pid"] = Int(pid)
            }
            fields["appHidden"] = visibility.isHidden
            fields["visibleWindows"] = visibility.visibleWindowCount
        }

        return fields
    }

    private func captureAppVisibilityIfNeeded(
        bundleId: String,
        taskType: RestorationTaskType
    ) async -> AppVisibility? {
        guard taskType == .defaultApp else { return nil }
        return await captureAppVisibility(bundleId: bundleId)
    }

    private func captureAppVisibility(bundleId: String) async -> AppVisibility {
        let runningApp = await MainActor.run { () -> NSRunningApplication? in
            NSWorkspace.shared.runningApplications.first { $0.bundleIdentifier == bundleId }
        }

        guard let runningApp else {
            return AppVisibility(pid: nil, isHidden: false, visibleWindowCount: 0, isRunning: false)
        }

        let pid = runningApp.processIdentifier
        let isHidden = runningApp.isHidden
        let visibleCount = Self.visibleWindowCount(for: pid)

        return AppVisibility(pid: pid, isHidden: isHidden, visibleWindowCount: visibleCount, isRunning: true)
    }

    private nonisolated static func visibleWindowCount(
        for pid: pid_t,
        minSize: CGSize = CGSize(width: 64, height: 64)
    ) -> Int {
        guard let windowList = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] else {
            return 0
        }

        var count = 0
        for dict in windowList {
            guard let windowPid = dict[kCGWindowOwnerPID as String] as? pid_t,
                  windowPid == pid,
                  let layer = dict[kCGWindowLayer as String] as? Int,
                  layer == 0,
                  let isOnScreen = dict[kCGWindowIsOnscreen as String] as? Bool,
                  isOnScreen,
                  let bounds = dict[kCGWindowBounds as String] as? [String: CGFloat],
                  let width = bounds["Width"], let height = bounds["Height"],
                  width >= minSize.width, height >= minSize.height else {
                continue
            }
            count += 1
        }

        return count
    }

    func taskType(for bundleId: String) -> RestorationTaskType {
        BundleRegistry.taskType(for: bundleId)
    }

    private func chromeProfileDirectories(in workspace: Workspace) -> Set<String> {
        let directories = workspace.windows.compactMap { window in
            let dir = window.chromeState?.profileDirectory ?? ""
            return dir.isEmpty ? nil : dir
        }
        return Set(directories)
    }

    func durationMs(from startTime: Date) -> Int {
        Int(Date().timeIntervalSince(startTime) * 1000)
    }

    private func isSkipped(_ decision: RestorationDecision) -> Bool {
        if case .skip = decision { return true }
        return false
    }
}
