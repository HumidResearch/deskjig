//  OpenByPathRestorationService.swift
//  DeskJigShared

import Foundation
import CoreGraphics
import AppKit

public struct OpenByPathRestorationConfig: Sendable {
    public let terminalFetchMethod: TerminalFetchMethod
    public let enableTerminalSupplementation: Bool
    public let ideFetchMethod: IDEFetchMethod
    public let enableIDESupplementation: Bool
    public let useWindowLocks: Bool
    public let lockTimeout: Duration

    public init(
        terminalFetchMethod: TerminalFetchMethod,
        enableTerminalSupplementation: Bool,
        ideFetchMethod: IDEFetchMethod,
        enableIDESupplementation: Bool,
        useWindowLocks: Bool,
        lockTimeout: Duration
    ) {
        self.terminalFetchMethod = terminalFetchMethod
        self.enableTerminalSupplementation = enableTerminalSupplementation
        self.ideFetchMethod = ideFetchMethod
        self.enableIDESupplementation = enableIDESupplementation
        self.useWindowLocks = useWindowLocks
        self.lockTimeout = lockTimeout
    }
}

/// Result of an OpenByPath restoration, including the restored window ID.
public struct OpenByPathRestoreResult: Sendable {
    public let success: Bool
    public let windowId: CGWindowID?

    public init(success: Bool, windowId: CGWindowID? = nil) {
        self.success = success
        self.windowId = windowId
    }
}

public final class OpenByPathRestorationService: @unchecked Sendable {
    private let orchestrator = LaunchOrchestrator()
    private let positioningService: WindowPositioningService

    public init(positioningService: WindowPositioningService) {
        self.positioningService = positioningService
    }

    public func restore(
        window: WorkspaceWindow,
        targetFrame: CGRect,
        snapshot: SystemSnapshot,
        taskContext: RestorationTaskContext,
        config: OpenByPathRestorationConfig
    ) async -> OpenByPathRestoreResult {
        guard let openPath = window.openPath else {
            return OpenByPathRestoreResult(success: false)
        }

        let expandedOpenPath = (openPath as NSString).expandingTildeInPath
        let directoryURL = URL(fileURLWithPath: expandedOpenPath).standardizedFileURL

        if BundleRegistry.isIDE(window.bundleIdentifier) {
            return await restoreIDE(
                window: window,
                directoryURL: directoryURL,
                snapshot: snapshot,
                targetFrame: targetFrame,
                taskContext: taskContext,
                config: config
            )
        }

        guard let launcher = FluentLauncherFactory.launcher(for: window.bundleIdentifier) else {
            DeskJigLog.debug(.restorationTrace, "No launcher for OpenByPath window", fields: [
                "taskId": taskContext.taskId,
                "taskType": taskContext.taskType.rawValue,
                "bundleId": window.bundleIdentifier,
                "success": "false",
            ], runId: taskContext.runId)
            return OpenByPathRestoreResult(success: false)
        }

        let result = await orchestrator.findOrLaunch(
            launcher: launcher,
            directory: openPath,
            title: window.windowTitle,
            existingSnapshot: snapshot,
            task: taskContext,
            runId: taskContext.runId,
            supplementationMethod: config.terminalFetchMethod,
            enableSupplementation: config.enableTerminalSupplementation,
            ideSupplementationMethod: config.ideFetchMethod,
            enableIDESupplementation: config.enableIDESupplementation
        )

        guard let match = result.match else {
            return OpenByPathRestoreResult(success: false)
        }

        let lockPriority = WindowPositioningService.lockPriority(for: match.confidence)
        let preferredStrategy = WindowHandleResolver.preferredStrategy(for: match)
        let positioned = await positioningService.positionSnapshotWindow(
            snapshotWindow: match.window,
            targetFrame: targetFrame,
            taskContext: taskContext,
            requesterId: taskContext.taskId,
            lockPriority: lockPriority,
            useWindowLocks: config.useWindowLocks,
            lockTimeout: config.lockTimeout,
            preferredStrategy: preferredStrategy
        )

        DeskJigLog.debug(.restorationTrace, "Window restoration complete", fields: [
            "taskId": taskContext.taskId,
            "taskType": taskContext.taskType.rawValue,
            "success": "\(positioned.success)",
        ], runId: taskContext.runId)

        return OpenByPathRestoreResult(success: positioned.success, windowId: match.window.windowId)
    }

    private func restoreIDE(
        window: WorkspaceWindow,
        directoryURL: URL,
        snapshot: SystemSnapshot,
        targetFrame: CGRect,
        taskContext: RestorationTaskContext,
        config: OpenByPathRestorationConfig
    ) async -> OpenByPathRestoreResult {
        let expectedTitle = window.windowTitle.isEmpty ? nil : window.windowTitle
        let isPathStrictXcode = window.bundleIdentifier == OpenByPathBundleIdentifiers.xcode
        let isAlreadyRunning = !NSRunningApplication.runningApplications(withBundleIdentifier: window.bundleIdentifier).isEmpty
        let normalizedExpectedDirectory = Self.normalizeXcodeComparablePath(directoryURL.path) ?? directoryURL.path

        let matches = OpenByPathMatcher.findMatches(
            bundleID: window.bundleIdentifier,
            directoryPath: directoryURL.path,
            expectedTitle: expectedTitle,
            targetFrame: targetFrame,
            windowID: window.id
        )

        if isPathStrictXcode {
            let exactPathMatches = matches.filter {
                Self.isExactXcodeDirectoryMatch(documentPath: $0.documentPath, expectedDirectory: normalizedExpectedDirectory)
            }

            if exactPathMatches.count > 1 {
                DeskJigLog.debug(.restorationTrace, "Xcode path-confirmed candidates are ambiguous", fields: [
                    "taskId": taskContext.taskId,
                    "taskType": taskContext.taskType.rawValue,
                    "reason": XcodeIdentityTraceReason.pathConfirmedSelectionAmbiguous.rawValue,
                    "bundleId": window.bundleIdentifier,
                    "candidateCount": "\(exactPathMatches.count)",
                    "expectedDirectory": normalizedExpectedDirectory,
                ], runId: taskContext.runId)
            }

            if let handle = exactPathMatches.first {
                DeskJigLog.info(.restorationPlanner, "IDE openByPath: reusing path-confirmed window wid:\(handle.title ?? "nil") docPath=\(handle.documentPath ?? "nil")", runId: taskContext.runId)
                DeskJigLog.debug(.restorationTrace, "Reusing existing Xcode window (path-confirmed)", fields: [
                    "taskId": taskContext.taskId,
                    "taskType": taskContext.taskType.rawValue,
                    "bundleId": window.bundleIdentifier,
                    "title": handle.title ?? "nil",
                    "docPath": handle.documentPath ?? "nil",
                    "xcodePathStrict": true,
                    "candidateCounts": "total=\(matches.count),exactPath=\(exactPathMatches.count)",
                    "waitMs": 0,
                ], runId: taskContext.runId)
                return await positionIDEHandle(
                    window: window,
                    handle: handle,
                    targetFrame: targetFrame,
                    taskContext: taskContext,
                    config: config,
                    xcodePathStrict: true,
                    expectedXcodeDirectory: normalizedExpectedDirectory
                )
            }

            if !matches.isEmpty {
                DeskJigLog.info(.restorationPlanner, "IDE openByPath: candidates found but none path-confirmed total=\(matches.count) dir=\(normalizedExpectedDirectory)", runId: taskContext.runId)
                DeskJigLog.debug(.restorationTrace, "Xcode existing candidates found but none path-confirmed", fields: [
                    "taskId": taskContext.taskId,
                    "taskType": taskContext.taskType.rawValue,
                    "bundleId": window.bundleIdentifier,
                    "xcodePathStrict": true,
                    "ambiguousReason": "existingCandidatesWithoutExactPath",
                    "candidateCounts": "total=\(matches.count),exactPath=0",
                    "waitMs": 0,
                ], runId: taskContext.runId)
            }
        } else if let handle = matches.first {
            DeskJigLog.debug(.restorationTrace, "Reusing existing IDE window", fields: [
                "taskId": taskContext.taskId,
                "taskType": taskContext.taskType.rawValue,
                "bundleId": window.bundleIdentifier,
                "title": handle.title ?? "nil",
                "docPath": handle.documentPath ?? "nil",
            ], runId: taskContext.runId)
            return await positionIDEHandle(
                window: window,
                handle: handle,
                targetFrame: targetFrame,
                taskContext: taskContext,
                config: config
            )
        }

        guard let launcher = FluentLauncherFactory.launcher(for: window.bundleIdentifier) else {
            DeskJigLog.debug(.restorationTrace, "Unsupported IDE bundle for OpenByPath", fields: [
                "taskId": taskContext.taskId,
                "taskType": taskContext.taskType.rawValue,
                "bundleId": window.bundleIdentifier,
            ], runId: taskContext.runId)
            return OpenByPathRestoreResult(success: false)
        }

        DeskJigLog.info(.restorationPlanner, "IDE openByPath: launching via findOrLaunch bundleId=\(window.bundleIdentifier) path=\(directoryURL.path)", runId: taskContext.runId)
        DeskJigLog.debug(.restorationTrace, "Launching IDE via Fluent launcher", fields: [
            "taskId": taskContext.taskId,
            "taskType": taskContext.taskType.rawValue,
            "bundleId": window.bundleIdentifier,
            "path": directoryURL.path,
            "alreadyRunning": isAlreadyRunning
        ], runId: taskContext.runId)

        let launchWaitMs = ideLaunchWindowWaitMs(bundleId: window.bundleIdentifier, isAlreadyRunning: isAlreadyRunning)
        let result = await orchestrator.findOrLaunch(
            launcher: launcher,
            directory: directoryURL.path,
            title: expectedTitle,
            existingSnapshot: snapshot,
            task: taskContext,
            runId: taskContext.runId,
            supplementationMethod: config.terminalFetchMethod,
            enableSupplementation: config.enableTerminalSupplementation,
            ideSupplementationMethod: config.ideFetchMethod,
            enableIDESupplementation: config.enableIDESupplementation,
            windowWaitMs: launchWaitMs
        )

        if isPathStrictXcode {
            let pollingConfig = xcodePathStrictPollingConfig(isAlreadyRunning: isAlreadyRunning)
            DeskJigLog.info(.restorationPlanner, "IDE openByPath: findOrLaunch result method=\(result.match?.method.rawValue ?? "nil") confidence=\(result.match?.confidence.rawValue ?? "nil")", runId: taskContext.runId)
            if let match = result.match,
               match.method == .documentPath,
               Self.isExactXcodeDirectoryMatch(
                documentPath: match.window.ideDocumentPath ?? match.window.documentPath,
                expectedDirectory: normalizedExpectedDirectory
               ) {
                let lockPriority = WindowPositioningService.lockPriority(for: match.confidence)
                let preferredStrategy = WindowHandleResolver.preferredStrategy(for: match)
                let positioned = await positioningService.positionSnapshotWindow(
                    snapshotWindow: match.window,
                    targetFrame: targetFrame,
                    taskContext: taskContext,
                    requesterId: taskContext.taskId,
                    lockPriority: lockPriority,
                    useWindowLocks: config.useWindowLocks,
                    lockTimeout: config.lockTimeout,
                    preferredStrategy: preferredStrategy
                )

                DeskJigLog.debug(.restorationTrace, "Window restoration complete", fields: [
                    "taskId": taskContext.taskId,
                    "taskType": taskContext.taskType.rawValue,
                    "success": "\(positioned.success)",
                ], runId: taskContext.runId)

                return OpenByPathRestoreResult(success: positioned.success, windowId: match.window.windowId)
            }

            DeskJigLog.info(.restorationPlanner, "IDE openByPath: polling for path-strict handle dir=\(normalizedExpectedDirectory)", runId: taskContext.runId)
            if let pathConfirmedHandle = await waitForPathStrictXcodeHandle(
                window: window,
                directoryPath: directoryURL.path,
                expectedTitle: expectedTitle,
                targetFrame: targetFrame,
                taskContext: taskContext,
                timeoutMs: pollingConfig.timeoutMs,
                pollIntervalMs: pollingConfig.pollIntervalMs,
                expectedDirectory: normalizedExpectedDirectory
            ) {
                return await positionIDEHandle(
                    window: window,
                    handle: pathConfirmedHandle,
                    targetFrame: targetFrame,
                    taskContext: taskContext,
                    config: config,
                    xcodePathStrict: true,
                    expectedXcodeDirectory: normalizedExpectedDirectory
                )
            }

            DeskJigLog.info(.restorationPlanner, "IDE openByPath: path-strict timeout, failing closed dir=\(normalizedExpectedDirectory)", runId: taskContext.runId)
            DeskJigLog.debug(.restorationTrace, "Xcode path-strict match unresolved after timeout (fail closed)", fields: [
                "taskId": taskContext.taskId,
                "taskType": taskContext.taskType.rawValue,
                "bundleId": window.bundleIdentifier,
                "xcodePathStrict": true,
                "ambiguousReason": "timedOutWithoutPathConfirmation",
                "candidateCounts": "unknown",
                "waitMs": pollingConfig.timeoutMs,
            ], runId: taskContext.runId)
            return OpenByPathRestoreResult(success: false)
        }

        guard let match = result.match else {
            DeskJigLog.debug(.restorationTrace, "IDE launch succeeded but no window detected", fields: [
                "taskId": taskContext.taskId,
                "taskType": taskContext.taskType.rawValue,
                "bundleId": window.bundleIdentifier,
                "launchSuccess": "\(result.launchResult?.success ?? false)",
            ], runId: taskContext.runId)
            return OpenByPathRestoreResult(success: false)
        }

        let lockPriority = WindowPositioningService.lockPriority(for: match.confidence)
        let preferredStrategy = WindowHandleResolver.preferredStrategy(for: match)
        let positioned = await positioningService.positionSnapshotWindow(
            snapshotWindow: match.window,
            targetFrame: targetFrame,
            taskContext: taskContext,
            requesterId: taskContext.taskId,
            lockPriority: lockPriority,
            useWindowLocks: config.useWindowLocks,
            lockTimeout: config.lockTimeout,
            preferredStrategy: preferredStrategy
        )

        DeskJigLog.debug(.restorationTrace, "Window restoration complete", fields: [
            "taskId": taskContext.taskId,
            "taskType": taskContext.taskType.rawValue,
            "success": "\(positioned.success)",
        ], runId: taskContext.runId)

        return OpenByPathRestoreResult(success: positioned.success, windowId: match.window.windowId)
    }

    private func ideLaunchWindowWaitMs(bundleId: String, isAlreadyRunning: Bool) -> Int {
        guard isAlreadyRunning else { return 800 }
        if bundleId == OpenByPathBundleIdentifiers.cursor ||
            bundleId == OpenByPathBundleIdentifiers.codex ||
            bundleId == OpenByPathBundleIdentifiers.vscode {
            return 250
        }
        if bundleId == OpenByPathBundleIdentifiers.xcode {
            return 400
        }
        return 800
    }

    private func xcodePathStrictPollingConfig(isAlreadyRunning: Bool) -> (timeoutMs: Int, pollIntervalMs: Int) {
        if isAlreadyRunning {
            return (timeoutMs: 1400, pollIntervalMs: 120)
        }
        return (timeoutMs: 2500, pollIntervalMs: 150)
    }

    private func positionIDEHandle(
        window: WorkspaceWindow,
        handle: WindowHandle,
        targetFrame: CGRect,
        taskContext: RestorationTaskContext,
        config: OpenByPathRestorationConfig,
        xcodePathStrict: Bool = false,
        expectedXcodeDirectory: String? = nil
    ) async -> OpenByPathRestoreResult {
        let lockPriority = WindowPositioningService.lockPriority(for: .high)

        if xcodePathStrict, window.bundleIdentifier == OpenByPathBundleIdentifiers.xcode {
            let selectedIdentity = xcodeIdentity(from: handle)
            DeskJigLog.debug(.restorationTrace, "Xcode path-strict window selected", fields: [
                "taskId": taskContext.taskId,
                "taskType": taskContext.taskType.rawValue,
                "reason": XcodeIdentityTraceReason.pathConfirmedSelection.rawValue,
                "selectedXcodeIdentity": selectedIdentity.identityKey,
                "title": handle.title ?? "nil",
                "docPath": handle.documentPath ?? "nil",
            ], runId: taskContext.runId)

            if let axWindowNumber = handle.windowId {
                let snapshot = await SystemSnapshotCapture.captureQuick(runId: taskContext.runId)
                let directIdMatches = snapshot.windows.filter { snapshotWindow in
                    snapshotWindow.bundleId == window.bundleIdentifier &&
                    Int(snapshotWindow.windowId) == axWindowNumber &&
                    snapshotWindow.isAXAccessible != false
                }

                if directIdMatches.count == 1, let snapshotWindow = directIdMatches.first {
                    DeskJigLog.debug(.restorationTrace, "Mapped Xcode handle via unique AXWindowNumber", fields: [
                        "taskId": taskContext.taskId,
                        "taskType": taskContext.taskType.rawValue,
                        "axWindowNumber": "\(axWindowNumber)",
                        "windowId": "\(snapshotWindow.windowId)",
                        "title": snapshotWindow.title ?? "nil",
                    ], runId: taskContext.runId)
                    let preferredStrategy = WindowHandleResolver.preferredStrategy(
                        workspaceWindow: window,
                        snapshotWindow: snapshotWindow
                    )
                    let positioned = await positioningService.positionSnapshotWindow(
                        snapshotWindow: snapshotWindow,
                        targetFrame: targetFrame,
                        taskContext: taskContext,
                        requesterId: taskContext.taskId,
                        lockPriority: lockPriority,
                        useWindowLocks: config.useWindowLocks,
                        lockTimeout: config.lockTimeout,
                        preferredStrategy: preferredStrategy
                    )
                    return OpenByPathRestoreResult(success: positioned.success, windowId: snapshotWindow.windowId)
                }

                if directIdMatches.count > 1 {
                    DeskJigLog.debug(.restorationTrace, "Xcode path-strict AXWindowNumber mapping ambiguous", fields: [
                        "taskId": taskContext.taskId,
                        "taskType": taskContext.taskType.rawValue,
                        "reason": XcodeIdentityTraceReason.pathConfirmedSelectionAmbiguous.rawValue,
                        "axWindowNumber": "\(axWindowNumber)",
                        "candidateCount": "\(directIdMatches.count)",
                    ], runId: taskContext.runId)
                }
            }

            DeskJigLog.debug(.restorationTrace, "Xcode path-strict positioning via direct handle", fields: [
                "taskId": taskContext.taskId,
                "taskType": taskContext.taskType.rawValue,
                "reason": XcodeIdentityTraceReason.pathConfirmedSelectionAmbiguous.rawValue,
                "selectedXcodeIdentity": selectedIdentity.identityKey,
                "expectedDirectory": expectedXcodeDirectory ?? "nil",
            ], runId: taskContext.runId)

            let selectedWindowId = Self.cgWindowId(fromAXWindowNumber: handle.windowId)
            let positioned = await positioningService.positionHandle(
                handle: handle,
                windowId: selectedWindowId,
                targetFrame: targetFrame,
                taskContext: taskContext,
                requesterId: taskContext.taskId,
                lockPriority: lockPriority,
                useWindowLocks: config.useWindowLocks,
                lockTimeout: config.lockTimeout
            )
            let resolvedWindowId = positioned.resolvedWindowId ?? selectedWindowId

            if let expectedXcodeDirectory {
                let activatedIdentity = await resolveActivatedXcodeIdentity(
                    preferredWindowId: resolvedWindowId,
                    fallbackHandle: handle,
                    runId: taskContext.runId
                )
                let activatedDirectory = activatedIdentity?.normalizedDirectory
                if let activatedDirectory,
                   !Self.pathMatchesExpectedDirectory(observedPath: activatedDirectory, expectedDirectory: expectedXcodeDirectory) {
                    DeskJigLog.debug(.restorationTrace, "Xcode path-strict contradiction: selected path differs from activated path", fields: [
                        "taskId": taskContext.taskId,
                        "taskType": taskContext.taskType.rawValue,
                        "reason": XcodeIdentityTraceReason.pathConfirmedButActivatedDifferentWindow.rawValue,
                        "expectedDirectory": expectedXcodeDirectory,
                        "selectedXcodeIdentity": selectedIdentity.identityKey,
                        "activatedXcodeIdentity": activatedIdentity?.identityKey ?? "nil",
                    ], runId: taskContext.runId)
                    return OpenByPathRestoreResult(success: false, windowId: resolvedWindowId)
                }
            }

            DeskJigLog.debug(.restorationTrace, "Window restoration complete", fields: [
                "taskId": taskContext.taskId,
                "taskType": taskContext.taskType.rawValue,
                "success": "\(positioned.success)",
            ], runId: taskContext.runId)
            return OpenByPathRestoreResult(success: positioned.success, windowId: resolvedWindowId)
        }

        let snapshot = await SystemSnapshotCapture.captureQuick(runId: taskContext.runId)
        if let snapshotWindow = matchSnapshotWindow(for: handle, in: snapshot, bundleId: window.bundleIdentifier) {
            DeskJigLog.debug(.restorationTrace, "Mapped IDE handle to snapshot window", fields: [
                "taskId": taskContext.taskId,
                "taskType": taskContext.taskType.rawValue,
                "bundleId": window.bundleIdentifier,
                "windowId": "\(snapshotWindow.windowId)",
                "title": snapshotWindow.title ?? "nil",
            ], runId: taskContext.runId)

            let preferredStrategy = WindowHandleResolver.preferredStrategy(
                workspaceWindow: window,
                snapshotWindow: snapshotWindow
            )
            let positioned = await positioningService.positionSnapshotWindow(
                snapshotWindow: snapshotWindow,
                targetFrame: targetFrame,
                taskContext: taskContext,
                requesterId: taskContext.taskId,
                lockPriority: lockPriority,
                useWindowLocks: config.useWindowLocks,
                lockTimeout: config.lockTimeout,
                preferredStrategy: preferredStrategy
            )
            DeskJigLog.debug(.restorationTrace, "Window restoration complete", fields: [
                "taskId": taskContext.taskId,
                "taskType": taskContext.taskType.rawValue,
                "success": "\(positioned.success)",
            ], runId: taskContext.runId)
            return OpenByPathRestoreResult(success: positioned.success, windowId: snapshotWindow.windowId)
        }

        DeskJigLog.debug(.restorationTrace, "No snapshot match for IDE handle; positioning via AX only", fields: [
            "taskId": taskContext.taskId,
            "taskType": taskContext.taskType.rawValue,
            "bundleId": window.bundleIdentifier,
            "title": handle.title ?? "nil",
        ], runId: taskContext.runId)

        let positioned = await positioningService.positionHandle(
            handle: handle,
            windowId: nil,
            targetFrame: targetFrame,
            taskContext: taskContext,
            requesterId: taskContext.taskId,
            lockPriority: lockPriority,
            useWindowLocks: config.useWindowLocks,
            lockTimeout: config.lockTimeout
        )
        DeskJigLog.debug(.restorationTrace, "Window restoration complete", fields: [
            "taskId": taskContext.taskId,
            "taskType": taskContext.taskType.rawValue,
            "success": "\(positioned.success)",
        ], runId: taskContext.runId)
        // No windowId available when positioning via AX only (no snapshot match)
        return OpenByPathRestoreResult(success: positioned.success, windowId: nil)
    }

    private func waitForPathStrictXcodeHandle(
        window: WorkspaceWindow,
        directoryPath: String,
        expectedTitle: String?,
        targetFrame: CGRect,
        taskContext: RestorationTaskContext,
        timeoutMs: Int,
        pollIntervalMs: Int,
        expectedDirectory: String
    ) async -> WindowHandle? {
        var elapsedMs = 0
        var lastTotalCandidates = 0
        var lastExactPathCandidates = 0
        var sawAnyCandidates = false

        while elapsedMs <= timeoutMs {
            let matches = OpenByPathMatcher.findMatches(
                bundleID: window.bundleIdentifier,
                directoryPath: directoryPath,
                expectedTitle: expectedTitle,
                targetFrame: targetFrame,
                windowID: window.id
            )

            lastTotalCandidates = matches.count
            let exactPathMatches = matches.filter {
                Self.isExactXcodeDirectoryMatch(documentPath: $0.documentPath, expectedDirectory: expectedDirectory)
            }
            lastExactPathCandidates = exactPathMatches.count
            sawAnyCandidates = sawAnyCandidates || !matches.isEmpty

            if let handle = exactPathMatches.first {
                DeskJigLog.debug(.restorationTrace, "Xcode path-strict match confirmed", fields: [
                    "taskId": taskContext.taskId,
                    "taskType": taskContext.taskType.rawValue,
                    "bundleId": window.bundleIdentifier,
                    "xcodePathStrict": true,
                    "candidateCounts": "total=\(lastTotalCandidates),exactPath=\(lastExactPathCandidates)",
                    "waitMs": elapsedMs,
                    "docPath": handle.documentPath ?? "nil",
                ], runId: taskContext.runId)
                return handle
            }

            if elapsedMs >= timeoutMs {
                break
            }

            guard await Task.sleepUnlessCancelled(for: .milliseconds(pollIntervalMs)) else { break }
            elapsedMs += pollIntervalMs
        }

        let ambiguousReason = sawAnyCandidates ? "noPathConfirmedCandidate" : "noCandidates"
        DeskJigLog.debug(.restorationTrace, "Xcode path-strict match unresolved in polling window", fields: [
            "taskId": taskContext.taskId,
            "taskType": taskContext.taskType.rawValue,
            "bundleId": window.bundleIdentifier,
            "xcodePathStrict": true,
            "ambiguousReason": ambiguousReason,
            "candidateCounts": "total=\(lastTotalCandidates),exactPath=\(lastExactPathCandidates)",
            "waitMs": timeoutMs,
        ], runId: taskContext.runId)
        return nil
    }

    private static func normalizeXcodeComparablePath(_ path: String?) -> String? {
        XcodePathMatching.normalizeComparable(path)
    }

    private static func isExactXcodeDirectoryMatch(documentPath: String?, expectedDirectory: String) -> Bool {
        guard let normalized = normalizeXcodeComparablePath(documentPath) else { return false }
        return pathMatchesExpectedDirectory(observedPath: normalized, expectedDirectory: expectedDirectory)
    }

    private static func pathMatchesExpectedDirectory(observedPath: String, expectedDirectory: String) -> Bool {
        XcodePathMatching.pathMatchesDirectory(observedPath: observedPath, expectedDirectory: expectedDirectory)
    }

    private static func cgWindowId(fromAXWindowNumber value: Int?) -> CGWindowID? {
        guard let value, value >= 0, value <= Int(UInt32.max) else { return nil }
        return CGWindowID(value)
    }

    private func xcodeIdentity(from handle: WindowHandle) -> XcodeWindowIdentity {
        XcodeWindowIdentity(
            normalizedDirectory: Self.normalizeXcodeComparablePath(handle.documentPath),
            axElementHash: handle.axElementHash,
            axWindowNumber: handle.windowId,
            cgWindowId: Self.cgWindowId(fromAXWindowNumber: handle.windowId),
            title: handle.title,
            frame: handle.frame,
            pid: handle.processID
        )
    }

    private func xcodeIdentity(from snapshotWindow: SnapshotWindow) -> XcodeWindowIdentity {
        XcodeWindowIdentity(
            normalizedDirectory: Self.normalizeXcodeComparablePath(snapshotWindow.ideDocumentPath ?? snapshotWindow.documentPath),
            axElementHash: nil,
            axWindowNumber: Int(snapshotWindow.windowId),
            cgWindowId: snapshotWindow.windowId,
            title: snapshotWindow.title,
            frame: snapshotWindow.frame,
            pid: snapshotWindow.pid
        )
    }

    private func resolveActivatedXcodeIdentity(
        preferredWindowId: CGWindowID?,
        fallbackHandle: WindowHandle,
        runId: String
    ) async -> XcodeWindowIdentity? {
        if let preferredWindowId {
            let snapshot = await SystemSnapshotCapture.captureQuick(runId: runId)
            if let snapshotWindow = snapshot.windows.first(where: {
                $0.bundleId == OpenByPathBundleIdentifiers.xcode &&
                $0.windowId == preferredWindowId
            }) {
                return xcodeIdentity(from: snapshotWindow)
            }
        }

        if let refreshed = fallbackHandle.refresh() {
            return xcodeIdentity(from: refreshed)
        }
        return xcodeIdentity(from: fallbackHandle)
    }

    private func matchSnapshotWindow(
        for handle: WindowHandle,
        in snapshot: SystemSnapshot,
        bundleId: String
    ) -> SnapshotWindow? {
        guard let pid = handle.processID else { return nil }
        // Filter out zombie windows (exist in CGWindowList but not accessible via AX API)
        let candidates = snapshot.windows.filter { $0.pid == pid && $0.bundleId == bundleId && $0.isAXAccessible != false }
        guard !candidates.isEmpty else { return nil }

        if let frame = handle.frame {
            let frameMatches = candidates.filter { $0.frameMatches(frame) }
            if frameMatches.count == 1 {
                return frameMatches[0]
            }

            if frameMatches.count > 1, let title = handle.title {
                if let titleMatch = frameMatches.first(where: { $0.title == title }) {
                    return titleMatch
                }
            }

            if let frontmost = frameMatches.sorted(by: { ($0.zOrderIndex ?? Int.max) < ($1.zOrderIndex ?? Int.max) }).first {
                return frontmost
            }
        }

        if let title = handle.title,
           let titleMatch = candidates.first(where: { $0.title == title }) {
            return titleMatch
        }

        return candidates.sorted(by: { ($0.zOrderIndex ?? Int.max) < ($1.zOrderIndex ?? Int.max) }).first
    }
}

