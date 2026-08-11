//  RestorationExecutor+QueueHelpers.swift
//  DeskJigShared

import Foundation
import CoreGraphics
import AppKit

extension RestorationExecutor {

    // MARK: - Queue Helpers

    func rebuildTmuxCoverageContext(from plan: RestorationPlan) {
        tmuxExpectedIndicesByBundle = [:]
        tmuxTaskByBundleAndIndex = [:]
        tmuxRepairBudgetSpentMsByBundle = [:]
        tmuxBootstrapCountByBundleAndIndex = [:]
        tmuxLastLaunchAtByBundleAndIndex = [:]
        tmuxManagedVisibilityCache = [:]
        tmuxClaimedClientTTYsByBundle = [:]
        tmuxClaimedSessionsByBundle = [:]
        postLaunchClaimedWindowIds = []
        iTermTTYBindingCacheByRun = [:]
        iTermFetchInFlightByRun = [:]

        if let tmuxTerminalRestoreContext = plan.tmuxTerminalRestoreContext {
            tmuxExpectedIndicesByBundle = tmuxTerminalRestoreContext.expectedIndicesByBundle
        }

        for task in plan.tasks {
            guard BundleRegistry.isTerminal(task.workspaceWindow.bundleIdentifier),
                  task.workspaceWindow.tmuxState != nil,
                  let index = task.tmuxManagedIndex else {
                continue
            }

            let bundleId = task.workspaceWindow.bundleIdentifier
            tmuxExpectedIndicesByBundle[bundleId, default: []].insert(index)
            if tmuxTaskByBundleAndIndex[bundleId]?[index] == nil {
                tmuxTaskByBundleAndIndex[bundleId, default: [:]][index] = task
            }
        }
    }

    func expectedTmuxWindowCount(for bundleId: String) -> Int {
        tmuxExpectedIndicesByBundle[bundleId]?.count ?? 0
    }

    private func tmuxIndexCacheKey(bundleId: String, index: Int) -> String {
        "\(bundleId)#\(index)"
    }

    func cachedManagedVisibilityState(
        bundleId: String,
        index: Int,
        maxAgeMs: Int
    ) -> ManagedTmuxIndexVisibilityState? {
        let key = tmuxIndexCacheKey(bundleId: bundleId, index: index)
        guard let cached = tmuxManagedVisibilityCache[key] else {
            return nil
        }
        let ageMs = Int(Date().timeIntervalSince(cached.timestamp) * 1000)
        guard ageMs <= maxAgeMs else {
            return nil
        }
        return cached.state
    }

    func cacheManagedVisibilityState(
        bundleId: String,
        index: Int,
        state: ManagedTmuxIndexVisibilityState
    ) {
        let key = tmuxIndexCacheKey(bundleId: bundleId, index: index)
        tmuxManagedVisibilityCache[key] = (state: state, timestamp: Date())
    }

    func tmuxBootstrapCount(bundleId: String, index: Int) -> Int {
        tmuxBootstrapCountByBundleAndIndex[bundleId]?[index] ?? 0
    }

    func markTmuxBootstrapLaunch(bundleId: String, index: Int?) {
        guard let index else { return }
        tmuxBootstrapCountByBundleAndIndex[bundleId, default: [:]][index, default: 0] += 1
        tmuxLastLaunchAtByBundleAndIndex[bundleId, default: [:]][index] = Date()
    }

    func markTmuxLaunchObserved(bundleId: String, index: Int?) {
        guard let index else { return }
        tmuxLastLaunchAtByBundleAndIndex[bundleId, default: [:]][index] = Date()
    }

    private func recentTmuxLaunchElapsedMs(bundleId: String, index: Int) -> Int? {
        guard let launchedAt = tmuxLastLaunchAtByBundleAndIndex[bundleId]?[index] else {
            return nil
        }
        return Int(Date().timeIntervalSince(launchedAt) * 1000)
    }

    func shouldSuppressBootstrapLaunch(
        bundleId: String,
        index: Int,
        allowRetryLaunch: Bool
    ) -> String? {
        if let elapsedMs = recentTmuxLaunchElapsedMs(bundleId: bundleId, index: index),
           elapsedMs >= 0,
           elapsedMs < tmuxBootstrapLaunchGraceMs {
            return "recent-launch-grace(\(elapsedMs)ms)"
        }

        let bootstrapCount = tmuxBootstrapCount(bundleId: bundleId, index: index)
        if bootstrapCount >= 1 && !allowRetryLaunch {
            return "bootstrap-cap-reached(\(bootstrapCount))"
        }

        return nil
    }

    func tmuxRepairBudgetSpentMs(for bundleId: String) -> Int {
        tmuxRepairBudgetSpentMsByBundle[bundleId] ?? 0
    }

    func recordTmuxRepairBudget(
        bundleId: String,
        startedAt: Date
    ) {
        let elapsedMs = max(0, Int(Date().timeIntervalSince(startedAt) * 1000))
        tmuxRepairBudgetSpentMsByBundle[bundleId, default: 0] += elapsedMs
    }

    struct RetryLockOutcome {
        let readyTasks: [RestorationTask]
        let failedResults: [TaskResult]
        let acquiredLocks: [WindowLock]
    }

    func executeTasks(
        _ tasks: [RestorationTask],
        snapshot: EnhancedSnapshot
    ) async -> [TaskResult] {
        guard !tasks.isEmpty else { return [] }
        let laneCoordinator = self.laneCoordinator

        let operations = tasks.map { task in
            QueueOperation<TaskResult>(
                id: task.id,
                name: "Restore: \(task.workspaceWindow.appName)",
                timeout: taskTimeout
            ) {
                let laneKey = Self.laneKey(for: task.targetScreenIndex)
                if let laneCoordinator {
                    await laneCoordinator.acquire(laneKey)
                }
                let result = await self.executeTask(task, snapshot: snapshot)
                if let laneCoordinator {
                    await laneCoordinator.release(laneKey)
                }
                return result
            }
        }

        let queueResult = await Task { @MainActor in
            let queueBuilder = OperationQueueBuilder<TaskResult>()
                .addAll(operations)
                .concurrent(max: maxConcurrency)
                .allSettled()
                .timeout(.seconds(120))
            return await queueBuilder.execute()
        }.value

        var results: [TaskResult] = []
        results.reserveCapacity(queueResult.results.count)

        for settledResult in queueResult.results {
            switch settledResult.outcome {
            case .success(let result):
                results.append(result)
            case .failure(let error):
                results.append(TaskResult(
                    taskId: settledResult.operationId,
                    success: false,
                    decision: .failed(reason: error.localizedDescription),
                    durationMs: settledResult.durationMs,
                    notes: ["Error: \(error.localizedDescription)"]
                ))
            case .cancelled:
                results.append(TaskResult(
                    taskId: settledResult.operationId,
                    success: false,
                    decision: .skip(reason: "Cancelled"),
                    durationMs: settledResult.durationMs,
                    notes: ["Task cancelled"]
                ))
            case .timedOut:
                results.append(TaskResult(
                    taskId: settledResult.operationId,
                    success: false,
                    decision: .failed(reason: "Timeout"),
                    durationMs: settledResult.durationMs,
                    notes: ["Task timed out"]
                ))
            }
        }

        return results
    }

    func retryAwaitingSupplementationLocks(
        _ tasks: [RestorationTask]
    ) async -> RetryLockOutcome {
        var readyTasks: [RestorationTask] = []
        var failedResults: [TaskResult] = []
        var acquiredLocks: [WindowLock] = []

        for var task in tasks {
            guard task.requiresLock,
                  let windowId = task.decision.existingWindowId else {
                failedResults.append(TaskResult(
                    taskId: task.id,
                    success: false,
                    decision: .failed(reason: "Lock retry missing windowId"),
                    durationMs: 0,
                    notes: ["Missing windowId for lock retry"]
                ))
                continue
            }

            let lockResult = await lockManager.requestLock(
                for: windowId,
                requesterId: task.id,
                priority: task.requiredPriority,
                timeout: config.lockTimeout
            )

            task.lockResult = lockResult

            switch lockResult {
            case .acquired(let lock):
                task.lock = lock
                readyTasks.append(task)
                acquiredLocks.append(lock)
            default:
                failedResults.append(TaskResult(
                    taskId: task.id,
                    success: false,
                    windowId: windowId,
                    decision: .failed(reason: "Lock retry not acquired"),
                    durationMs: 0,
                    notes: ["Lock retry result: \(lockResultSummary(lockResult))"]
                ))
            }
        }

        return RetryLockOutcome(
            readyTasks: readyTasks,
            failedResults: failedResults,
            acquiredLocks: acquiredLocks
        )
    }

    func lockResultSummary(_ result: LockResult) -> String {
        switch result {
        case .acquired:
            return "acquired"
        case .queued(let position):
            return "queued(position: \(position))"
        case .denied(let reason, let holder):
            return "denied(\(reason), holder: \(holder ?? "unknown"))"
        case .timedOut:
            return "timedOut"
        case .awaitingChromeSupplementation:
            return "awaitingChromeSupplementation"
        }
    }
}
