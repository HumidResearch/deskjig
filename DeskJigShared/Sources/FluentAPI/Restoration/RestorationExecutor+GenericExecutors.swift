//  RestorationExecutor+GenericExecutors.swift
//  DeskJigShared

import Foundation
import CoreGraphics
import AppKit

extension RestorationExecutor {

    // MARK: - Generic Decision Executors

    func executePositionExisting(
        task: RestorationTask,
        snapshotWindow: SnapshotWindow?,
        taskContext: RestorationTaskContext,
        targetFrame: CGRect,
        startTime: Date
    ) async -> TaskResult {
        guard let snapshotWindow else {
            return TaskResult(
                taskId: task.id,
                success: false,
                windowId: nil,
                decision: task.decision,
                durationMs: durationMs(from: startTime),
                notes: ["Window not found in match result"],
                lockAcquired: task.hasLock
            )
        }

        if task.workspaceWindow.bundleIdentifier == OpenByPathBundleIdentifiers.xcode,
           let openPath = task.workspaceWindow.openPath {
            guard let expectedDirectory = Self.normalizeXcodeComparablePath(openPath) else {
                DeskJigLog.debug(.restorationTrace, "Xcode path-strict selection unresolved (fail closed)", fields: [
                    "taskId": taskContext.taskId,
                    "reason": "invalidExpectedPath",
                    "openPath": openPath
                ], runId: taskContext.runId)
                return TaskResult(
                    taskId: task.id,
                    success: false,
                    windowId: nil,
                    decision: task.decision,
                    durationMs: durationMs(from: startTime),
                    notes: ["Xcode path-strict selection failed: invalid expected path"],
                    lockAcquired: task.hasLock
                )
            }

            let expectedTitle = task.workspaceWindow.windowTitle.isEmpty ? nil : task.workspaceWindow.windowTitle
            guard let strictHandle = await selectStrictXcodeHandle(
                bundleId: task.workspaceWindow.bundleIdentifier,
                openPath: openPath,
                expectedTitle: expectedTitle,
                workspaceWindowId: task.workspaceWindow.id,
                expectedDirectory: expectedDirectory,
                targetFrame: targetFrame,
                preferredWindowId: snapshotWindow.windowId,
                taskContext: taskContext
            ) else {
                return TaskResult(
                    taskId: task.id,
                    success: false,
                    windowId: nil,
                    decision: task.decision,
                    durationMs: durationMs(from: startTime),
                    notes: ["Xcode path-strict selection unresolved after retry window"],
                    lockAcquired: task.hasLock
                )
            }

            let selectedWindowId = Self.cgWindowId(fromAXWindowNumber: strictHandle.windowId)
            let useWindowLocks = config.useWindowLocks && !task.hasLock
            let positioningResult = await positioningService.positionHandle(
                handle: strictHandle,
                windowId: selectedWindowId,
                targetFrame: targetFrame,
                taskContext: taskContext,
                requesterId: task.id,
                lockPriority: task.requiredPriority,
                useWindowLocks: useWindowLocks,
                lockTimeout: config.lockTimeout
            )

            let actualWindowId = positioningResult.resolvedWindowId ?? selectedWindowId ?? snapshotWindow.windowId
            let plannedWindowId: CGWindowID? = actualWindowId != snapshotWindow.windowId
                ? snapshotWindow.windowId
                : nil
            var notes: [String] = []
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
                plannedWindowId: plannedWindowId
            )
        }

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
        let plannedWindowId: CGWindowID? = actualWindowId != snapshotWindow.windowId
            ? snapshotWindow.windowId
            : nil

        return TaskResult(
            taskId: task.id,
            success: positioningResult.success,
            windowId: actualWindowId,
            decision: task.decision,
            durationMs: durationMs(from: startTime),
            notes: positioningResult.matchesTarget ? [] : [Self.frameMismatchNote],
            lockAcquired: task.hasLock,
            plannedWindowId: plannedWindowId
        )
    }

    func executeLaunchApp(
        task: RestorationTask,
        bundleId: String,
        snapshot: EnhancedSnapshot,
        taskContext: RestorationTaskContext,
        startTime: Date
    ) async -> TaskResult {
        // Use extended timeout for slow-start apps (Zoom, Discord, Slack)
        let genericConfig = BundleRegistry.isSlowStart(bundleId)
            ? GenericWindowRestorationConfig.forSlowStartApp(
                useWindowLocks: config.useWindowLocks,
                lockTimeout: config.lockTimeout
            )
            : GenericWindowRestorationConfig(
                useWindowLocks: config.useWindowLocks,
                lockTimeout: config.lockTimeout
            )
        let success = await genericRestorationService.restore(
            window: task.workspaceWindow,
            targetFrame: task.targetFrame,
            snapshot: snapshot.base,
            taskContext: taskContext,
            config: genericConfig
        )

        return TaskResult(
            taskId: task.id,
            success: success,
            decision: task.decision,
            durationMs: durationMs(from: startTime),
            notes: success ? [] : ["Generic app launch failed"]
        )
    }
}
