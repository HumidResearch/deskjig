//  RestorationExecutor+OpenByPathExecutor.swift
//  DeskJigShared

import Foundation
import CoreGraphics
import AppKit

extension RestorationExecutor {

    // MARK: - Open-by-Path Decision Executor

    func executeOpenNewWithPath(
        task: RestorationTask,
        bundleId: String,
        path: String,
        snapshot: EnhancedSnapshot,
        taskContext: RestorationTaskContext,
        targetFrame: CGRect,
        startTime: Date
    ) async -> TaskResult {
        // Tmux-aware launch for terminals with tmuxState
        if let tmuxState = task.workspaceWindow.tmuxState,
           BundleRegistry.isTerminal(bundleId) {
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

        let openByPathWindow = task.workspaceWindow.openPath == nil
            ? task.workspaceWindow.withOpenPath(path)
            : task.workspaceWindow
        let openByPathConfig = OpenByPathRestorationConfig(
            terminalFetchMethod: config.terminalFetchMethod,
            enableTerminalSupplementation: config.enableTerminalSupplementation && BundleRegistry.isTerminal(bundleId),
            ideFetchMethod: config.ideFetchMethod,
            enableIDESupplementation: config.enableIDESupplementation && BundleRegistry.isIDE(bundleId),
            useWindowLocks: config.useWindowLocks,
            lockTimeout: config.lockTimeout
        )
        let result = await openByPathRestorationService.restore(
            window: openByPathWindow,
            targetFrame: targetFrame,
            snapshot: snapshot.base,
            taskContext: taskContext,
            config: openByPathConfig
        )

        return TaskResult(
            taskId: task.id,
            success: result.success,
            windowId: result.windowId,
            decision: task.decision,
            durationMs: durationMs(from: startTime),
            notes: result.success ? [] : ["OpenByPath restoration failed"]
        )
    }
}
