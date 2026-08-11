//  RestorationExecutor+ChromeExecutors.swift
//  DeskJigShared

import Foundation
import CoreGraphics
import AppKit

extension RestorationExecutor {

    // MARK: - Chrome Decision Executors

    func executeCreateChromeWindow(
        task: RestorationTask,
        profile: String,
        tabs: [String],
        targetFrame: CGRect,
        taskContext: RestorationTaskContext,
        startTime: Date
    ) async -> TaskResult {
        let tccVerified = ChromeAutomationService.verifyTCCPermission()
        DeskJigLog.debug(.restorationTrace, "TCC verification state at Chrome window create start", fields: [
            "taskId": taskContext.taskId,
            "tccVerified": tccVerified
        ], runId: taskContext.runId)

        let resolvedProfile = task.chromeTargetProfile ?? chromeMatcher.resolveTargetProfile(for: task.workspaceWindow.chromeState)
        let profileDisplayName = resolvedProfile?.targetProfileName ?? ""
        let resolvedBy = resolvedProfile?.resolvedBy ?? "none"
        let fallbackReason = resolvedProfile?.fallbackReason ?? "none"
        let storedProfileDirectory = resolvedProfile?.storedProfileDirectory
            ?? normalizedChromeIdentity(task.workspaceWindow.chromeState?.profileDirectory)
        let resolvedProfileDirectory = resolvedProfile?.resolvedProfileDirectory ?? profile
        let storedHostedDomain = resolvedProfile?.storedHostedDomain
            ?? normalizedChromeIdentity(task.workspaceWindow.chromeState?.profileHostedDomain)
        let storedProfileDisplayName = task.workspaceWindow.chromeState?.appleScriptProfileName ?? "none"
        let launchProfileDirectory = resolvedProfileDirectory
        // exec-12: build the stable profile-diagnostic fields once and merge them into each
        // Chrome create/reuse trace call instead of re-listing them across 4 sites. The merged
        // key sets stay byte-identical to the originals (I-4).
        let chromeTraceBase: [String: any Sendable] = [
            "storedProfileDirectory": storedProfileDirectory ?? "none",
            "resolvedProfileDirectory": resolvedProfileDirectory,
            "storedHostedDomain": storedHostedDomain ?? "none",
            "resolvedBy": resolvedBy,
            "fallbackReason": fallbackReason
        ]
        // chrome-11: pre-launch captures are consumed ONLY for their chromeWindowId (the
        // preLaunchIds dedup set in selectPostLaunchCapture), so use the descriptor-only capture
        // to skip the System Events fetch + correlation merge. Trade-off: the "profiles" trace
        // field below renders empty here (profile derives from the System Events titlebar this
        // path skips); that field is diagnostic-only and is not part of the audit-logging contract.
        let preLaunchCaptures = ChromeAutomationService.captureChromeDescriptorCaptures(includeTabURLs: false)

        DeskJigLog.debug(.restorationTrace, "Captured pre-launch Chrome windows", fields: chromeTraceBase.merging([
            "taskId": taskContext.taskId,
            "captureCount": preLaunchCaptures.count,
            "profiles": preLaunchCaptures.compactMap { $0.profileAppleScriptName }.joined(separator: "|"),
            "chromeWindowIds": preLaunchCaptures.compactMap { $0.chromeWindowId.map { "\($0)" } }.joined(separator: ","),
            "targetProfile": profileDisplayName.isEmpty ? "none" : profileDisplayName,
            "storedProfileDisplayName": storedProfileDisplayName,
            "windows": ChromeWindowMatcher.formatCapturesForTrace(preLaunchCaptures)
        ]) { $1 }, runId: taskContext.runId)

        // Seed from config on first use
        if launchedChromeProfiles.isEmpty && !config.previouslyLaunchedChromeProfiles.isEmpty {
            launchedChromeProfiles = config.previouslyLaunchedChromeProfiles
        }

        // Create Chrome window with profile (defer full tab set for faster cold-start)
        if launchedChromeProfiles.contains(launchProfileDirectory) {
            DeskJigLog.debug(.restorationTrace, "Skipping Chrome launch — already launched in previous attempt", fields: [
                "taskId": taskContext.taskId,
                "profile": launchProfileDirectory
            ], runId: taskContext.runId)
            // Fall through to window-finding poll loop
        } else {
            let launchUrls: [String]
            if tabs.isEmpty {
                launchUrls = []
            } else {
                launchUrls = ["about:blank"]
                DeskJigLog.debug(.restorationTrace, "Deferring tab launch until window detected", fields: [
                    "taskId": taskContext.taskId,
                    "tabCount": tabs.count
                ], runId: taskContext.runId)
            }
            let success = await ChromeOperations.launchWindow(
                profileDirectory: launchProfileDirectory,
                urls: launchUrls
            )

            guard success else {
                return TaskResult(
                    taskId: task.id,
                    success: false,
                    decision: task.decision,
                    durationMs: durationMs(from: startTime),
                    notes: ["Failed to create Chrome window"]
                )
            }
            launchedChromeProfiles.insert(launchProfileDirectory)
        }

        let timeoutMs = 8_000
        let pollIntervalNs: UInt64 = 350_000_000
        let deadline = Date().addingTimeInterval(Double(timeoutMs) / 1000)

        DeskJigLog.debug(.restorationTrace, "Waiting for Chrome window to appear", fields: chromeTraceBase.merging([
            "taskId": taskContext.taskId,
            "profileDirectory": resolvedProfileDirectory,
            "profileDisplayName": profileDisplayName.isEmpty ? "none" : profileDisplayName,
            "timeoutMs": timeoutMs
        ]) { $1 }, runId: taskContext.runId)

        var selectedCapture: ChromeAppleScriptWindowCapture?
        var matchedSnapshotWindow: SnapshotWindow?
        var chromeWindowId: Int?
        var lastCaptureSummary: [String: any Sendable] = [:]

        while Date() < deadline {
            // exec-02: run the Chrome capture osascript off the actor so non-Chrome sibling
            // tasks proceed during the System Events / Chrome AppleScript. osascript runs in
            // independent subprocesses (no shared-state race) and concurrent Chrome captures
            // serialize at Chrome's Apple-event queue, so detaching does not spawn wasteful
            // parallel work — it just stops blocking the whole executor on each poll tick.
            let captures = await Task.detached(priority: .userInitiated) {
                ChromeAutomationService.captureOpenWindows(includeTabURLs: false)
            }.value
            lastCaptureSummary = [
                "captureCount": captures.count,
                "profiles": captures.compactMap { $0.profileAppleScriptName }.joined(separator: "|"),
                "chromeWindowIds": captures.compactMap { $0.chromeWindowId.map { "\($0)" } }.joined(separator: ","),
                "windows": ChromeWindowMatcher.formatCapturesForTrace(captures)
            ]

            selectedCapture = chromeMatcher.selectPostLaunchCapture(
                from: captures,
                preLaunchCaptures: preLaunchCaptures,
                targetProfile: profileDisplayName,
                profileDirectory: resolvedProfileDirectory,
                taskContext: taskContext
            )

            if let capture = selectedCapture {
                chromeWindowId = capture.chromeWindowId
                let snapshot = await SystemSnapshotCapture.captureQuick(runId: taskContext.runId)
                // Filter out zombie windows (exist in CGWindowList but not accessible via AX API)
                let chromeCandidates = snapshot.windows.filter { $0.bundleId == task.workspaceWindow.bundleIdentifier && $0.isAXAccessible != false }
                matchedSnapshotWindow = chromeMatcher.matchSnapshotWindow(for: capture, candidates: chromeCandidates)
                if matchedSnapshotWindow != nil {
                    break
                }
            }

            guard await Task.sleepUnlessCancelled(nanoseconds: pollIntervalNs) else { break }
        }

        guard let window = matchedSnapshotWindow else {
            // Diagnostic: check System Events accessibility to distinguish "SE not responding" from "matching failed"
            let diagnosticCaptures = await Task.detached(priority: .userInitiated) {
                ChromeAutomationService.captureOpenWindows(includeTabURLs: false)
            }.value
            let seWindowCount = diagnosticCaptures.count

            var traceFields: [String: any Sendable] = chromeTraceBase
            traceFields["taskId"] = taskContext.taskId
            traceFields["profileDirectory"] = resolvedProfileDirectory
            traceFields["profileDisplayName"] = profileDisplayName.isEmpty ? "none" : profileDisplayName
            traceFields["captureProfile"] = selectedCapture?.profileAppleScriptName ?? "none"
            traceFields["chromeWindowId"] = chromeWindowId.map { "\($0)" } ?? "none"
            traceFields["error"] = "WINDOW_NOT_FOUND_AFTER_CREATE"
            traceFields["diagnosticSEWindowCount"] = seWindowCount
            traceFields["hadSelectedCapture"] = selectedCapture != nil
            traceFields["tccVerifiedAtFailure"] = ChromeAutomationService.verifyTCCPermission()
            for (key, value) in lastCaptureSummary {
                traceFields[key] = value
            }
            DeskJigLog.debug(.restorationTrace, "FAILED: Chrome window created but not found after launch", fields: traceFields, runId: taskContext.runId)
            return TaskResult(
                taskId: task.id,
                success: false,
                decision: task.decision,
                durationMs: durationMs(from: startTime),
                notes: ["Chrome window created but couldn't find for positioning"]
            )
        }

        DeskJigLog.debug(.restorationTrace, "Chrome window found after launch", fields: chromeTraceBase.merging([
            "taskId": taskContext.taskId,
            "profileDirectory": resolvedProfileDirectory,
            "profileDisplayName": profileDisplayName.isEmpty ? "none" : profileDisplayName,
            "captureProfile": selectedCapture?.profileAppleScriptName ?? "none",
            "windowId": window.windowId,
            "chromeWindowId": chromeWindowId.map { "\($0)" } ?? "none"
        ]) { $1 }, runId: taskContext.runId)

        let preferredStrategy = WindowHandleResolver.preferredStrategy(
            workspaceWindow: task.workspaceWindow,
            snapshotWindow: window
        )
        let positioningResult = await positioningService.positionSnapshotWindow(
            snapshotWindow: window,
            targetFrame: targetFrame,
            taskContext: taskContext,
            requesterId: task.id,
            lockPriority: task.requiredPriority,
            useWindowLocks: config.useWindowLocks,
            lockTimeout: config.lockTimeout,
            preferredStrategy: preferredStrategy
        )
        let positionedWindowId = positioningResult.resolvedWindowId ?? window.windowId

        guard positioningResult.success else {
            return TaskResult(
                taskId: task.id,
                success: false,
                windowId: positionedWindowId,
                decision: task.decision,
                durationMs: durationMs(from: startTime),
                notes: ["Failed to position Chrome window"]
            )
        }

        if !tabs.isEmpty {
            if let chromeWindowId {
                DeskJigLog.debug(.restorationTrace, "Restoring missing tabs", fields: [
                    "taskId": taskContext.taskId,
                    "windowId": positionedWindowId,
                    "chromeWindowId": chromeWindowId,
                    "tabCount": tabs.count,
                    "method": "chromeWindowId"
                ], runId: taskContext.runId)
                ChromeAutomationService.openMissingTabs(tabs, inWindowWithChromeId: chromeWindowId)
                if let focusedIndex = task.workspaceWindow.chromeState?.focusedTabIndex {
                    ChromeAutomationService.setActiveTab(index: focusedIndex, inWindowWithChromeId: chromeWindowId)
                }
            } else {
                DeskJigLog.debug(.restorationTrace, "Skipping tab restore (no Chrome window ID)", fields: [
                    "taskId": taskContext.taskId,
                    "windowId": positionedWindowId,
                    "tabCount": tabs.count,
                    "method": "missingChromeWindowId"
                ], runId: taskContext.runId)
            }
        }

        var notes = ["Created Chrome window with \(tabs.count) tabs"]
        if !positioningResult.matchesTarget {
            notes.append(Self.frameMismatchNote)
        }

        return TaskResult(
            taskId: task.id,
            success: true,
            windowId: positionedWindowId,
            decision: task.decision,
            durationMs: durationMs(from: startTime),
            notes: notes,
            plannedWindowId: positionedWindowId != window.windowId ? window.windowId : nil
        )
    }

    func executeReuseChromeWindow(
        task: RestorationTask,
        snapshot: EnhancedSnapshot,
        snapshotWindow: SnapshotWindow?,
        windowId: CGWindowID,
        tabs: [String],
        targetFrame: CGRect,
        taskContext: RestorationTaskContext,
        startTime: Date
    ) async -> TaskResult {
        let useWindowLocks = config.useWindowLocks && !task.hasLock

        let positioningResult: WindowPositioningResult?
        if let snapshotWindow {
            let preferredStrategy = WindowHandleResolver.preferredStrategy(
                workspaceWindow: task.workspaceWindow,
                snapshotWindow: snapshotWindow
            )
            positioningResult = await positioningService.positionSnapshotWindow(
                snapshotWindow: snapshotWindow,
                targetFrame: targetFrame,
                taskContext: taskContext,
                requesterId: task.id,
                lockPriority: task.requiredPriority,
                useWindowLocks: useWindowLocks,
                lockTimeout: config.lockTimeout,
                preferredStrategy: preferredStrategy
            )
        } else if let handle = await findWindowHandle(for: windowId) {
            positioningResult = await positioningService.positionHandle(
                handle: handle,
                windowId: windowId,
                targetFrame: targetFrame,
                taskContext: taskContext,
                requesterId: task.id,
                lockPriority: task.requiredPriority,
                useWindowLocks: useWindowLocks,
                lockTimeout: config.lockTimeout
            )
        } else {
            positioningResult = nil
        }

        guard let positioningResult else {
            return TaskResult(
                taskId: task.id,
                success: false,
                windowId: windowId,
                decision: task.decision,
                durationMs: durationMs(from: startTime),
                notes: ["Chrome window not found: \(windowId)"],
                lockAcquired: task.hasLock
            )
        }
        let positionedWindowId = positioningResult.resolvedWindowId
            ?? snapshotWindow?.windowId
            ?? windowId

        guard positioningResult.success else {
            // Fallback: if positioning the matched window failed, try creating a new
            // Chrome window instead. This handles stale/invalid matched windows.
            if let profile = task.chromeTargetProfile?.profileDirectory ?? task.chromeTargetProfile?.storedProfileDirectory,
               case .reuseChromeWindow(_, let fallbackTabs, let fallbackFrame) = task.decision {
                DeskJigLog.debug(.restorationTrace, "Chrome reuse positioning failed, falling back to create new window", fields: [
                    "taskId": taskContext.taskId,
                    "failedWindowId": "\(windowId)",
                    "profile": profile,
                    "tabCount": "\(fallbackTabs.count)"
                ], runId: taskContext.runId)
                return await executeCreateChromeWindow(
                    task: task,
                    profile: profile,
                    tabs: fallbackTabs,
                    targetFrame: fallbackFrame,
                    taskContext: taskContext,
                    startTime: startTime
                )
            }
            return TaskResult(
                taskId: task.id,
                success: false,
                windowId: positionedWindowId,
                decision: task.decision,
                durationMs: durationMs(from: startTime),
                notes: ["Failed to position Chrome window"],
                lockAcquired: task.hasLock
            )
        }

        if !tabs.isEmpty {
            let chromeWindowId = resolveChromeWindowId(
                task: task,
                snapshot: snapshot,
                expectedWindowId: positionedWindowId,
                taskContext: taskContext
            )

            if let chromeWindowId {
                DeskJigLog.debug(.restorationTrace, "Restoring missing tabs", fields: [
                    "taskId": taskContext.taskId,
                    "windowId": positionedWindowId,
                    "chromeWindowId": chromeWindowId,
                    "tabCount": tabs.count,
                    "method": "chromeWindowId",
                    "matchMethod": task.chromeMatchMethod?.rawValue ?? "unknown"
                ], runId: taskContext.runId)
                ChromeAutomationService.openMissingTabs(tabs, inWindowWithChromeId: chromeWindowId)
            } else {
                DeskJigLog.debug(.restorationTrace, "Skipping tab restore (no Chrome window ID)", fields: [
                    "taskId": taskContext.taskId,
                    "windowId": positionedWindowId,
                    "tabCount": tabs.count,
                    "matchMethod": task.chromeMatchMethod?.rawValue ?? "unknown"
                ], runId: taskContext.runId)
            }
        }

        var notes = ["Reused Chrome window"]
        if !positioningResult.matchesTarget {
            notes.append(Self.frameMismatchNote)
        }

        return TaskResult(
            taskId: task.id,
            success: true,
            windowId: positionedWindowId,
            decision: task.decision,
            durationMs: durationMs(from: startTime),
            notes: notes,
            lockAcquired: task.hasLock,
            plannedWindowId: positionedWindowId != windowId ? windowId : nil
        )
    }

    private func resolveChromeWindowId(
        task: RestorationTask,
        snapshot: EnhancedSnapshot,
        expectedWindowId: CGWindowID,
        taskContext: RestorationTaskContext
    ) -> Int? {
        if let chromeWindowId = task.chromeWindowId,
           task.chromeMatchMethod != .appleScriptBounds {
            return chromeWindowId
        }

        let captures = chromeMatcher.captureOpenWindows(includeTabURLs: false)
        let match = chromeMatcher.matchExistingWindow(
            workspaceWindow: task.workspaceWindow,
            snapshot: snapshot.base,
            chromeCaptures: captures,
            matchMethod: config.chromeMatchMethod,
            taskContext: taskContext,
            allowAppleScriptBounds: false,
            workspaceProfileDirectories: chromeWorkspaceProfileDirectories
        )

        if match.method == .appleScriptBounds {
            DeskJigLog.debug(.restorationTrace, "Skipping Chrome window ID from bounds match", fields: [
                "taskId": taskContext.taskId,
                "expectedWindowId": Int(expectedWindowId)
            ], runId: taskContext.runId)
            return nil
        }

        if let matchedWindowId = match.window?.windowId, matchedWindowId != expectedWindowId {
            DeskJigLog.debug(.restorationTrace, "Chrome match window mismatch", fields: [
                "taskId": taskContext.taskId,
                "expectedWindowId": Int(expectedWindowId),
                "matchedWindowId": Int(matchedWindowId),
                "matchMethod": match.method.rawValue
            ], runId: taskContext.runId)
            return nil
        }

        return match.chromeWindowId
    }

    private func normalizedChromeIdentity(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != "NO_HOSTED_DOMAIN" else { return nil }
        return trimmed
    }
}
