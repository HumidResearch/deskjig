//  WindowPositioningService.swift
//  DeskJigShared

import Foundation
import AppKit
import CoreGraphics
import Carbon

public struct WindowPositioningResult: Sendable {
    public let success: Bool
    public let matchesTarget: Bool
    public let finalFrame: CGRect?
    public let resolvedWindowId: CGWindowID?

    public init(
        success: Bool,
        matchesTarget: Bool,
        finalFrame: CGRect?,
        resolvedWindowId: CGWindowID? = nil
    ) {
        self.success = success
        self.matchesTarget = matchesTarget
        self.finalFrame = finalFrame
        self.resolvedWindowId = resolvedWindowId
    }
}

public struct WindowPositioningTelemetry: Sendable {
    public var windowHandleDirectResolveCount: Int
    public var windowHandleFallbackResolveCount: Int
    public var activationPollCount: Int
    public var activationPollSkippedCount: Int

    public init(
        windowHandleDirectResolveCount: Int = 0,
        windowHandleFallbackResolveCount: Int = 0,
        activationPollCount: Int = 0,
        activationPollSkippedCount: Int = 0
    ) {
        self.windowHandleDirectResolveCount = windowHandleDirectResolveCount
        self.windowHandleFallbackResolveCount = windowHandleFallbackResolveCount
        self.activationPollCount = activationPollCount
        self.activationPollSkippedCount = activationPollSkippedCount
    }
}

private actor WindowPositioningTelemetryStore {
    static let shared = WindowPositioningTelemetryStore()
    private var telemetryByRunId: [String: WindowPositioningTelemetry] = [:]

    func incrementDirectResolve(runId: String) {
        var telemetry = telemetryByRunId[runId, default: WindowPositioningTelemetry()]
        telemetry.windowHandleDirectResolveCount += 1
        telemetryByRunId[runId] = telemetry
    }

    func incrementFallbackResolve(runId: String) {
        var telemetry = telemetryByRunId[runId, default: WindowPositioningTelemetry()]
        telemetry.windowHandleFallbackResolveCount += 1
        telemetryByRunId[runId] = telemetry
    }

    func incrementActivationPoll(runId: String) {
        var telemetry = telemetryByRunId[runId, default: WindowPositioningTelemetry()]
        telemetry.activationPollCount += 1
        telemetryByRunId[runId] = telemetry
    }

    func incrementActivationPollSkipped(runId: String) {
        var telemetry = telemetryByRunId[runId, default: WindowPositioningTelemetry()]
        telemetry.activationPollSkippedCount += 1
        telemetryByRunId[runId] = telemetry
    }

    func telemetry(for runId: String) -> WindowPositioningTelemetry {
        telemetryByRunId[runId, default: WindowPositioningTelemetry()]
    }
}

public final class WindowPositioningService: @unchecked Sendable {
    private let lockManager: WindowLockManager
    private let defaultLockTimeout: Duration
    private static let xcodeMinimumWidth: CGFloat = 940
    private struct ActivationAttemptOutcome: Sendable {
        let attempted: Bool
        let activated: Bool
        let reopenSent: Bool
        let axWindowCount: Int

        static let unavailable = ActivationAttemptOutcome(
            attempted: false,
            activated: false,
            reopenSent: false,
            axWindowCount: 0
        )
    }

    public static func telemetry(forRunId runId: String) async -> WindowPositioningTelemetry {
        await WindowPositioningTelemetryStore.shared.telemetry(for: runId)
    }

    public init(lockManager: WindowLockManager, defaultLockTimeout: Duration = .seconds(10)) {
        self.lockManager = lockManager
        self.defaultLockTimeout = defaultLockTimeout
    }

    public static func lockPriority(for confidence: ExpMatchConfidence) -> LockPriority {
        switch confidence {
        case .exact: return .critical
        case .high: return .high
        case .medium: return .medium
        case .low: return .low
        }
    }

    public func positionSnapshotWindow(
        snapshotWindow: SnapshotWindow,
        targetFrame: CGRect,
        taskContext: RestorationTaskContext,
        requesterId: String,
        lockPriority: LockPriority,
        useWindowLocks: Bool,
        lockTimeout: Duration? = nil,
        preferredStrategy: AXMatchingStrategy,
        applyClampCompensation: Bool = true
    ) async -> WindowPositioningResult {
        var resolvedHandle = await MainActor.run {
            WindowHandleResolver.resolve(
                windowId: snapshotWindow.windowId,
                preferredStrategy: preferredStrategy,
                filter: .all
            )
        }
        if resolvedHandle != nil {
            await WindowPositioningTelemetryStore.shared.incrementDirectResolve(runId: taskContext.runId)
        }

        if resolvedHandle == nil {
            resolvedHandle = await MainActor.run {
                fallbackHandle(
                    snapshotWindow: snapshotWindow,
                    preferredStrategy: preferredStrategy
                )
            }
            if resolvedHandle != nil {
                await WindowPositioningTelemetryStore.shared.incrementFallbackResolve(runId: taskContext.runId)
                DeskJigLog.debug(.restorationTrace, "Resolved window handle via bundle fallback", fields: [
                    "taskId": taskContext.taskId,
                    "taskType": taskContext.taskType.rawValue,
                    "windowId": "\(snapshotWindow.windowId)",
                    "bundleId": snapshotWindow.bundleId ?? "nil",
                    "title": snapshotWindow.title ?? "(empty)"
                ], runId: taskContext.runId)
            }
        }

        if resolvedHandle == nil {
            let activationOutcome = await attemptActivateApp(
                pid: snapshotWindow.pid,
                bundleId: snapshotWindow.bundleId,
                taskContext: taskContext
            )
            let shouldPoll = Self.shouldPollAfterActivation(
                activated: activationOutcome.activated,
                reopenSent: activationOutcome.reopenSent,
                axWindowCount: activationOutcome.axWindowCount,
                attempted: activationOutcome.attempted
            )
            let pollSkipReason = Self.activationPollSkipReason(
                activated: activationOutcome.activated,
                reopenSent: activationOutcome.reopenSent,
                axWindowCount: activationOutcome.axWindowCount,
                attempted: activationOutcome.attempted
            )

            DeskJigLog.debug(.restorationTrace, "Activation poll decision", fields: [
                "taskId": taskContext.taskId,
                "taskType": taskContext.taskType.rawValue,
                "windowId": "\(snapshotWindow.windowId)",
                "activationPollSkipped": "\(!shouldPoll)",
                "activationPollReason": pollSkipReason
            ], runId: taskContext.runId)

            if shouldPoll {
                await WindowPositioningTelemetryStore.shared.incrementActivationPoll(runId: taskContext.runId)
                let deadline = Date().addingTimeInterval(1.0)
                repeat {
                    guard await Task.sleepUnlessCancelled(nanoseconds: 150_000_000) else { break }
                    resolvedHandle = await MainActor.run {
                        WindowHandleResolver.resolve(
                            windowId: snapshotWindow.windowId,
                            preferredStrategy: preferredStrategy,
                            filter: .all
                        )
                    }
                    if resolvedHandle != nil {
                        await WindowPositioningTelemetryStore.shared.incrementDirectResolve(runId: taskContext.runId)
                    }
                } while resolvedHandle == nil && Date() < deadline
            } else {
                await WindowPositioningTelemetryStore.shared.incrementActivationPollSkipped(runId: taskContext.runId)
            }
        }

        if resolvedHandle == nil {
            resolvedHandle = await MainActor.run {
                fallbackHandle(
                    snapshotWindow: snapshotWindow,
                    preferredStrategy: preferredStrategy
                )
            }
            if resolvedHandle != nil {
                await WindowPositioningTelemetryStore.shared.incrementFallbackResolve(runId: taskContext.runId)
                DeskJigLog.debug(.restorationTrace, "Resolved window handle via bundle fallback", fields: [
                    "taskId": taskContext.taskId,
                    "taskType": taskContext.taskType.rawValue,
                    "windowId": "\(snapshotWindow.windowId)",
                    "bundleId": snapshotWindow.bundleId ?? "nil",
                    "title": snapshotWindow.title ?? "(empty)"
                ], runId: taskContext.runId)
            }
        }

        guard let handle = resolvedHandle else {
            DeskJigLog.debug(.restorationTrace, "Could not get window handle", fields: [
                "taskId": taskContext.taskId,
                "taskType": taskContext.taskType.rawValue,
                "windowId": "\(snapshotWindow.windowId)",
                "title": snapshotWindow.title ?? "(empty)"
            ], runId: taskContext.runId)
            return WindowPositioningResult(success: false, matchesTarget: false, finalFrame: nil)
        }

        let shouldRestore = snapshotWindow.isMinimized == true || handle.isMinimized

        return await positionResolvedHandle(
            handle: handle,
            windowId: snapshotWindow.windowId,
            windowTitle: snapshotWindow.title,
            bundleId: snapshotWindow.bundleId,
            pid: snapshotWindow.pid,
            shouldRestore: shouldRestore,
            targetFrame: targetFrame,
            taskContext: taskContext,
            requesterId: requesterId,
            lockPriority: lockPriority,
            useWindowLocks: useWindowLocks,
            lockTimeout: lockTimeout,
            applyClampCompensation: applyClampCompensation
        )
    }

    public func positionHandle(
        handle: WindowHandle,
        windowId: CGWindowID?,
        targetFrame: CGRect,
        taskContext: RestorationTaskContext,
        requesterId: String,
        lockPriority: LockPriority,
        useWindowLocks: Bool,
        lockTimeout: Duration? = nil,
        applyClampCompensation: Bool = true
    ) async -> WindowPositioningResult {
        await positionResolvedHandle(
            handle: handle,
            windowId: windowId,
            windowTitle: handle.title,
            bundleId: handle.bundleIdentifier,
            pid: handle.processID,
            shouldRestore: handle.isMinimized,
            targetFrame: targetFrame,
            taskContext: taskContext,
            requesterId: requesterId,
            lockPriority: lockPriority,
            useWindowLocks: useWindowLocks,
            lockTimeout: lockTimeout,
            applyClampCompensation: applyClampCompensation
        )
    }

    public func raiseWindow(
        windowId: CGWindowID,
        preferredStrategy: AXMatchingStrategy
    ) async -> WindowHandle? {
        let resolvedHandle = await MainActor.run {
            WindowHandleResolver.resolve(windowId: windowId, preferredStrategy: preferredStrategy, filter: .all)
        }

        guard let handle = resolvedHandle else {
            return nil
        }

        _ = await MainActor.run {
            handle.raise()?.activate()
        }

        return handle
    }

    public func claimWindow(_ windowId: CGWindowID) async {
        await lockManager.claim(windowId)
    }

    public func isWindowClaimed(_ windowId: CGWindowID) async -> Bool {
        await lockManager.isClaimed(windowId)
    }

    private func positionResolvedHandle(
        handle: WindowHandle,
        windowId: CGWindowID?,
        windowTitle: String?,
        bundleId: String?,
        pid: pid_t?,
        shouldRestore: Bool,
        targetFrame: CGRect,
        taskContext: RestorationTaskContext,
        requesterId: String,
        lockPriority: LockPriority,
        useWindowLocks: Bool,
        lockTimeout: Duration?,
        applyClampCompensation: Bool
    ) async -> WindowPositioningResult {
        var acquiredLock: WindowLock?
        let lockRequestId = String(UUID().uuidString.prefix(8))
        let windowIdString = windowId.map(String.init) ?? "unknown"
        let resolvedWindowId = await MainActor.run {
            Self.cgWindowId(fromAXWindowNumber: handle.windowId)
        } ?? windowId

        if useWindowLocks, let lockWindowId = windowId {
            DeskJigLog.trace(.restorationTrace, "Requesting lock", fields: [
                "taskId": taskContext.taskId,
                "taskType": taskContext.taskType.rawValue,
                "lockRequestId": lockRequestId,
                "windowId": "\(lockWindowId)",
                "requesterId": requesterId,
                "priority": lockPriority.description,
                "useWindowLocks": "\(useWindowLocks)"
            ], runId: taskContext.runId)

            let lockResult = await lockManager.requestLock(
                for: lockWindowId,
                requesterId: requesterId,
                priority: lockPriority,
                timeout: lockTimeout ?? defaultLockTimeout
            )

            switch lockResult {
            case .acquired(let lock):
                acquiredLock = lock
                DeskJigLog.debug(.restorationTrace, "Lock ACQUIRED", fields: [
                    "taskId": taskContext.taskId,
                    "taskType": taskContext.taskType.rawValue,
                    "lockRequestId": lockRequestId,
                    "windowId": "\(lock.windowId)",
                    "holderId": lock.holderId,
                    "priority": lock.priority.description,
                    "expiresAt": lock.expiresAt?.description ?? "never"
                ], runId: taskContext.runId)
            case .denied(let reason, let currentHolder):
                DeskJigLog.debug(.restorationTrace, "Lock DENIED", fields: [
                    "taskId": taskContext.taskId,
                    "taskType": taskContext.taskType.rawValue,
                    "lockRequestId": lockRequestId,
                    "windowId": "\(lockWindowId)",
                    "reason": reason,
                    "currentHolder": currentHolder ?? "unknown"
                ], runId: taskContext.runId)
                return WindowPositioningResult(
                    success: false,
                    matchesTarget: false,
                    finalFrame: nil,
                    resolvedWindowId: resolvedWindowId
                )
            case .queued(let position):
                DeskJigLog.debug(.restorationTrace, "Lock QUEUED", fields: [
                    "taskId": taskContext.taskId,
                    "taskType": taskContext.taskType.rawValue,
                    "lockRequestId": lockRequestId,
                    "windowId": "\(lockWindowId)",
                    "queuePosition": "\(position)"
                ], runId: taskContext.runId)
                return WindowPositioningResult(
                    success: false,
                    matchesTarget: false,
                    finalFrame: nil,
                    resolvedWindowId: resolvedWindowId
                )
            case .timedOut:
                DeskJigLog.debug(.restorationTrace, "Lock TIMEOUT", fields: [
                    "taskId": taskContext.taskId,
                    "taskType": taskContext.taskType.rawValue,
                    "lockRequestId": lockRequestId,
                    "windowId": "\(lockWindowId)"
                ], runId: taskContext.runId)
                return WindowPositioningResult(
                    success: false,
                    matchesTarget: false,
                    finalFrame: nil,
                    resolvedWindowId: resolvedWindowId
                )
            case .awaitingChromeSupplementation:
                DeskJigLog.debug(.restorationTrace, "Lock AWAITING_SUPPLEMENTATION", fields: [
                    "taskId": taskContext.taskId,
                    "taskType": taskContext.taskType.rawValue,
                    "lockRequestId": lockRequestId,
                    "windowId": "\(lockWindowId)"
                ], runId: taskContext.runId)
                return WindowPositioningResult(
                    success: false,
                    matchesTarget: false,
                    finalFrame: nil,
                    resolvedWindowId: resolvedWindowId
                )
            }
        } else if useWindowLocks {
            DeskJigLog.debug(.restorationTrace, "Lock SKIPPED (missing windowId)", fields: [
                "taskId": taskContext.taskId,
                "taskType": taskContext.taskType.rawValue,
                "lockRequestId": lockRequestId,
                "windowId": windowIdString,
                "requesterId": requesterId,
                "priority": lockPriority.description,
                "useWindowLocks": "\(useWindowLocks)"
            ], runId: taskContext.runId)
        }

        let resolvedBundleId = bundleId ?? handle.bundleIdentifier

        // Coalesced MainActor hop (fluent-01 / pos-06): unhide -> restore -> read the current
        // frame and current/target screen indices in a single actor block instead of ~6
        // separate `await MainActor.run` round-trips. No non-MainActor await occurs between
        // these operations, so ordering and behavior are identical — this removes the
        // redundant executor hops that prevented positioning from scaling with concurrency.
        let (currentFrame, currentScreenIndex, initialTargetScreenIndex): (CGRect, Int, Int) = await MainActor.run {
            if let pid, pid != 0 {
                if let app = NSWorkspace.shared.runningApplications.first(where: { $0.processIdentifier == pid }),
                   app.isHidden {
                    DeskJigLog.trace(.restorationTrace, "Unhiding app", fields: [
                        "taskId": taskContext.taskId,
                        "taskType": taskContext.taskType.rawValue,
                        "windowId": windowIdString,
                        "appName": app.localizedName ?? "unknown"
                    ], runId: taskContext.runId)
                    _ = app.unhide()
                }
            } else if handle.isHidden {
                _ = handle.unhide()
            }

            DeskJigLog.trace(.restorationTrace, "Ensuring window is restored", fields: [
                "taskId": taskContext.taskId,
                "taskType": taskContext.taskType.rawValue,
                "windowId": windowIdString,
                "wasMinimized": "\(shouldRestore)"
            ], runId: taskContext.runId)
            _ = handle.restore()

            let cf = handle.frame ?? targetFrame
            return (cf, screenIndexForFrame(cf), screenIndexForFrame(targetFrame))
        }
        var targetScreenIndex = initialTargetScreenIndex

        // Apply compensation for previously clamped neighbors before positioning.
        var effectiveTargetFrame = targetFrame
        var didApplyCompensation = false
        if applyClampCompensation {
            let existingClamped = await lockManager.getClampedFrames(for: taskContext.runId)
            for cf in existingClamped {
                let adjusted = Self.compensatedFrame(
                    for: effectiveTargetFrame,
                    clampedOriginal: cf.originalTarget,
                    clampedActual: cf.actualFrame
                )
                if !framesMatch(adjusted, effectiveTargetFrame, tolerance: 0.5) {
                    didApplyCompensation = true
                    effectiveTargetFrame = adjusted
                }
            }
        }

        if didApplyCompensation {
            DeskJigLog.debug(.restorationTrace, "Adjusting target to avoid clamped neighbor overlap", fields: [
                "taskId": taskContext.taskId,
                "taskType": taskContext.taskType.rawValue,
                "windowId": windowIdString,
                "originalTarget": "\(Int(targetFrame.origin.x)),\(Int(targetFrame.origin.y)) \(Int(targetFrame.width))x\(Int(targetFrame.height))",
                "adjustedTarget": "\(Int(effectiveTargetFrame.origin.x)),\(Int(effectiveTargetFrame.origin.y)) \(Int(effectiveTargetFrame.width))x\(Int(effectiveTargetFrame.height))"
            ], runId: taskContext.runId)
        }

        // Xcode enforces a hard minimum width; pre-clamp so we avoid a late clamp + jump.
        var preclampedOriginalTarget: CGRect?
        if resolvedBundleId == BundleRegistry.xcode {
            let frameForPreclamp = effectiveTargetFrame
            let xcodePreclamped = await MainActor.run {
                preclampXcodeFrame(frameForPreclamp)
            }
            if !framesMatch(xcodePreclamped, effectiveTargetFrame, tolerance: 0.5) {
                let originalTarget = effectiveTargetFrame
                preclampedOriginalTarget = originalTarget
                effectiveTargetFrame = xcodePreclamped
                let effectiveFrameForScreen = effectiveTargetFrame
                targetScreenIndex = await MainActor.run { screenIndexForFrame(effectiveFrameForScreen) }
                DeskJigLog.debug(.restorationTrace, "Pre-clamping Xcode target for minimum width", fields: [
                    "taskId": taskContext.taskId,
                    "taskType": taskContext.taskType.rawValue,
                    "windowId": windowIdString,
                    "minimumWidth": "\(Int(Self.xcodeMinimumWidth))",
                    "originalTarget": "\(Int(originalTarget.origin.x)),\(Int(originalTarget.origin.y)) \(Int(originalTarget.width))x\(Int(originalTarget.height))",
                    "clampedTarget": "\(Int(effectiveTargetFrame.origin.x)),\(Int(effectiveTargetFrame.origin.y)) \(Int(effectiveTargetFrame.width))x\(Int(effectiveTargetFrame.height))",
                    "reason": "xcode-preclamp-min-width"
                ], runId: taskContext.runId)
            }
        }

        DeskJigLog.trace(.restorationTrace, "Positioning window", fields: [
            "taskId": taskContext.taskId,
            "taskType": taskContext.taskType.rawValue,
            "windowId": windowIdString,
            "title": windowTitle ?? "(empty)",
            "beforeFrame": "\(Int(currentFrame.origin.x)),\(Int(currentFrame.origin.y)) \(Int(currentFrame.width))x\(Int(currentFrame.height))",
            "targetFrame": "\(Int(effectiveTargetFrame.origin.x)),\(Int(effectiveTargetFrame.origin.y)) \(Int(effectiveTargetFrame.width))x\(Int(effectiveTargetFrame.height))",
            "beforeScreen": "\(currentScreenIndex)",
            "targetScreen": "\(targetScreenIndex)",
            "operations": "setFrame->raise->activate"
        ], runId: taskContext.runId)

        let frameToSet = effectiveTargetFrame
        _ = await MainActor.run {
            handle.setFrame(frameToSet)?.raise()?.activate()
        }

        let fallbackFrame = effectiveTargetFrame
        // Coalesced MainActor hop (fluent-01 / pos-06): read live screens + the post-position
        // frame + its screen index in one actor block instead of three round-trips.
        let (layoutMatchScreens, initialFinalFrame, initialFinalScreenIndex): ([FullScreenInfo], CGRect, Int) = await MainActor.run {
            let screens = WindowLayoutFrameMatcher.liveScreens()
            let ff = handle.frame ?? fallbackFrame
            return (screens, ff, screenIndexForFrame(ff))
        }
        var finalFrame = initialFinalFrame
        var finalScreenIndex = initialFinalScreenIndex
        var verificationTargetFrame = effectiveTargetFrame
        var matchesTarget =
            framesMatch(finalFrame, effectiveTargetFrame) ||
            WindowLayoutFrameMatcher.matchesLayout(
                actualFrame: finalFrame,
                targetFrame: effectiveTargetFrame,
                screens: layoutMatchScreens
            )
        var clampedRecord: WindowLockManager.ClampedFrame?

        // If the app enforced a minimum size (significant mismatch), retry with
        // the actual dimensions but adjust origin to stay within screen bounds.
        if !matchesTarget {
            let widthDelta = abs(finalFrame.width - effectiveTargetFrame.width)
            let heightDelta = abs(finalFrame.height - effectiveTargetFrame.height)
            if widthDelta > 10 || heightDelta > 10 {
                DeskJigLog.debug(.restorationTrace, "Detected app-enforced minimum size clamp", fields: [
                    "taskId": taskContext.taskId,
                    "taskType": taskContext.taskType.rawValue,
                    "windowId": windowIdString,
                    "targetFrame": "\(Int(effectiveTargetFrame.origin.x)),\(Int(effectiveTargetFrame.origin.y)) \(Int(effectiveTargetFrame.width))x\(Int(effectiveTargetFrame.height))",
                    "observedFrame": "\(Int(finalFrame.origin.x)),\(Int(finalFrame.origin.y)) \(Int(finalFrame.width))x\(Int(finalFrame.height))",
                    "widthDelta": "\(Int(widthDelta))",
                    "heightDelta": "\(Int(heightDelta))"
                ], runId: taskContext.runId)

                let desiredTargetForClampAdjustment = effectiveTargetFrame
                let observedFrameForClampAdjustment = finalFrame
                let adjustedFrame = await MainActor.run { () -> CGRect in
                    let currentScreens = NSScreen.screens.map { FullScreenInfo(screen: $0) }
                    return Self.adjustedFrameForObservedSizeClamp(
                        desiredTarget: desiredTargetForClampAdjustment,
                        observedFrame: observedFrameForClampAdjustment,
                        currentScreens: currentScreens
                    )
                }
                verificationTargetFrame = adjustedFrame

                DeskJigLog.debug(.restorationTrace, "Retrying position with clamped frame", fields: [
                    "taskId": taskContext.taskId,
                    "taskType": taskContext.taskType.rawValue,
                    "windowId": windowIdString,
                    "originalTarget": "\(Int(effectiveTargetFrame.origin.x)),\(Int(effectiveTargetFrame.origin.y)) \(Int(effectiveTargetFrame.width))x\(Int(effectiveTargetFrame.height))",
                    "clampedFrame": "\(Int(adjustedFrame.origin.x)),\(Int(adjustedFrame.origin.y)) \(Int(adjustedFrame.width))x\(Int(adjustedFrame.height))",
                    "widthDelta": "\(Int(widthDelta))",
                    "heightDelta": "\(Int(heightDelta))",
                    "reason": "app-enforced-minimum-size"
                ], runId: taskContext.runId)

                let adjustedFrameToSet = adjustedFrame
                _ = await MainActor.run {
                    handle.setFrame(adjustedFrameToSet)
                }

                finalFrame = await MainActor.run { handle.frame ?? adjustedFrame }
                let finalFrameForScreen = finalFrame
                finalScreenIndex = await MainActor.run { screenIndexForFrame(finalFrameForScreen) }
                matchesTarget =
                    framesMatch(finalFrame, adjustedFrame) ||
                    WindowLayoutFrameMatcher.matchesLayout(
                        actualFrame: finalFrame,
                        targetFrame: adjustedFrame,
                        screens: layoutMatchScreens
                    )

                // Register so later-positioning windows can avoid this clamped area.
                // Use finalFrame (actual window position) not adjustedFrame, since
                // macOS may further adjust coordinates (e.g. AppKit→CG coord conversion).
                await lockManager.registerClampedFrame(
                    runId: taskContext.runId,
                    windowId: resolvedWindowId,
                    originalTarget: effectiveTargetFrame,
                    actualFrame: finalFrame
                )
                clampedRecord = WindowLockManager.ClampedFrame(
                    windowId: resolvedWindowId,
                    originalTarget: effectiveTargetFrame,
                    actualFrame: finalFrame
                )
            }
        }

        if !matchesTarget,
           let correctedTarget = Self.correctedTargetFrameForObservedPositionDrift(
            desiredTarget: effectiveTargetFrame,
            observedFrame: finalFrame,
            finalScreenIndex: finalScreenIndex,
            targetScreenIndex: targetScreenIndex
           ) {
            DeskJigLog.debug(.restorationTrace, "Retrying position with learned drift correction", fields: [
                "taskId": taskContext.taskId,
                "taskType": taskContext.taskType.rawValue,
                "windowId": windowIdString,
                "desiredTarget": "\(Int(effectiveTargetFrame.origin.x)),\(Int(effectiveTargetFrame.origin.y)) \(Int(effectiveTargetFrame.width))x\(Int(effectiveTargetFrame.height))",
                "observedFrame": "\(Int(finalFrame.origin.x)),\(Int(finalFrame.origin.y)) \(Int(finalFrame.width))x\(Int(finalFrame.height))",
                "correctedTarget": "\(Int(correctedTarget.origin.x)),\(Int(correctedTarget.origin.y)) \(Int(correctedTarget.width))x\(Int(correctedTarget.height))",
                "reason": "position-drift-same-size"
            ], runId: taskContext.runId)

            let correctedTargetToSet = correctedTarget
            _ = await MainActor.run {
                handle.setFrame(correctedTargetToSet)
            }

            finalFrame = await MainActor.run { handle.frame ?? correctedTarget }
            let correctedFrameForScreen = finalFrame
            finalScreenIndex = await MainActor.run { screenIndexForFrame(correctedFrameForScreen) }
            matchesTarget =
                framesMatch(finalFrame, effectiveTargetFrame) ||
                WindowLayoutFrameMatcher.matchesLayout(
                    actualFrame: finalFrame,
                    targetFrame: effectiveTargetFrame,
                    screens: layoutMatchScreens
                )
        }

        if clampedRecord == nil, let preclampedOriginalTarget {
            await lockManager.registerClampedFrame(
                runId: taskContext.runId,
                windowId: resolvedWindowId,
                originalTarget: preclampedOriginalTarget,
                actualFrame: finalFrame
            )
            clampedRecord = WindowLockManager.ClampedFrame(
                windowId: resolvedWindowId,
                originalTarget: preclampedOriginalTarget,
                actualFrame: finalFrame
            )
        } else if clampedRecord == nil, let resolvedWindowId {
            await lockManager.clearClampedFrame(runId: taskContext.runId, windowId: resolvedWindowId)
        }

        await lockManager.registerPositionedFrame(
            runId: taskContext.runId,
            windowId: resolvedWindowId,
            bundleId: resolvedBundleId,
            originalTarget: targetFrame,
            effectiveTarget: verificationTargetFrame,
            finalFrame: finalFrame
        )

        if let clampedRecord {
            await adjustPreviouslyPositionedNeighbors(
                for: clampedRecord,
                currentWindowId: resolvedWindowId,
                currentBundleId: resolvedBundleId,
                taskContext: taskContext
            )
        }

        DeskJigLog.debug(.restorationTrace, "Window positioned", fields: [
            "taskId": taskContext.taskId,
            "taskType": taskContext.taskType.rawValue,
            "windowId": windowIdString,
            "finalFrame": "\(Int(finalFrame.origin.x)),\(Int(finalFrame.origin.y)) \(Int(finalFrame.width))x\(Int(finalFrame.height))",
            "matchesTarget": "\(matchesTarget)",
            "finalScreen": "\(finalScreenIndex)",
            "success": "true"
        ], runId: taskContext.runId)

        if let lock = acquiredLock {
            await lockManager.releaseLock(lock)
            DeskJigLog.trace(.restorationTrace, "Lock RELEASED", fields: [
                "taskId": taskContext.taskId,
                "taskType": taskContext.taskType.rawValue,
                "lockRequestId": lockRequestId,
                "windowId": "\(lock.windowId)",
                "holderId": lock.holderId,
                "heldDuration": "\(String(format: "%.3f", Date().timeIntervalSince(lock.acquiredAt)))s"
            ], runId: taskContext.runId)
        }

        return WindowPositioningResult(
            success: true,
            matchesTarget: matchesTarget,
            finalFrame: finalFrame,
            resolvedWindowId: resolvedWindowId
        )
    }

    private func adjustPreviouslyPositionedNeighbors(
        for clampedFrame: WindowLockManager.ClampedFrame,
        currentWindowId: CGWindowID?,
        currentBundleId: String?,
        taskContext: RestorationTaskContext
    ) async {
        let positioned = await lockManager.getPositionedFrames(for: taskContext.runId)

        DeskJigLog.debug(.restorationTrace, "Adjusting neighbors for clamp", fields: [
            "taskId": taskContext.taskId,
            "taskType": taskContext.taskType.rawValue,
            "positionedCount": "\(positioned.count)",
            "currentWindowId": currentWindowId.map { "\($0)" } ?? "nil",
            "currentBundleId": currentBundleId ?? "nil",
            "clampOriginal": "\(Int(clampedFrame.originalTarget.origin.x)),\(Int(clampedFrame.originalTarget.origin.y)) \(Int(clampedFrame.originalTarget.width))x\(Int(clampedFrame.originalTarget.height))",
            "clampActual": "\(Int(clampedFrame.actualFrame.origin.x)),\(Int(clampedFrame.actualFrame.origin.y)) \(Int(clampedFrame.actualFrame.width))x\(Int(clampedFrame.actualFrame.height))"
        ], runId: taskContext.runId)

        var adjustedNeighborIds = Set<CGWindowID>()

        for positionedFrame in positioned {
            guard let neighborWindowId = positionedFrame.windowId else { continue }
            if let currentWindowId, neighborWindowId == currentWindowId {
                continue
            }

            let adjustedTarget = Self.compensatedFrame(
                for: positionedFrame.effectiveTarget,
                clampedOriginal: clampedFrame.originalTarget,
                clampedActual: clampedFrame.actualFrame
            )

            let needsAdjustment = !framesMatch(adjustedTarget, positionedFrame.effectiveTarget, tolerance: 0.5)
            DeskJigLog.debug(.restorationTrace, "Neighbor compensation check", fields: [
                "taskId": taskContext.taskId,
                "taskType": taskContext.taskType.rawValue,
                "neighborWindowId": "\(neighborWindowId)",
                "effectiveTarget": "\(Int(positionedFrame.effectiveTarget.origin.x)),\(Int(positionedFrame.effectiveTarget.origin.y)) \(Int(positionedFrame.effectiveTarget.width))x\(Int(positionedFrame.effectiveTarget.height))",
                "compensated": "\(Int(adjustedTarget.origin.x)),\(Int(adjustedTarget.origin.y)) \(Int(adjustedTarget.width))x\(Int(adjustedTarget.height))",
                "needsAdjustment": "\(needsAdjustment)"
            ], runId: taskContext.runId)

            guard needsAdjustment else {
                continue
            }

            adjustedNeighborIds.insert(neighborWindowId)

            let before = positionedFrame.finalFrame
            let finalNeighborFrame = await repositionWindowWithRetry(
                windowId: neighborWindowId,
                target: adjustedTarget,
                taskContext: taskContext,
                stage: "neighbor-compensation"
            )

            guard let finalNeighborFrame else { continue }

            await lockManager.updatePositionedFrame(
                runId: taskContext.runId,
                windowId: neighborWindowId,
                effectiveTarget: adjustedTarget,
                finalFrame: finalNeighborFrame
            )

            let widthDelta = abs(finalNeighborFrame.width - adjustedTarget.width)
            let heightDelta = abs(finalNeighborFrame.height - adjustedTarget.height)
            if widthDelta > 10 || heightDelta > 10 {
                await lockManager.registerClampedFrame(
                    runId: taskContext.runId,
                    windowId: neighborWindowId,
                    originalTarget: adjustedTarget,
                    actualFrame: finalNeighborFrame
                )
                DeskJigLog.debug(.restorationTrace, "Neighbor reflow also clamped by app minimum size", fields: [
                    "taskId": taskContext.taskId,
                    "taskType": taskContext.taskType.rawValue,
                    "windowId": "\(neighborWindowId)",
                    "targetFrame": "\(Int(adjustedTarget.origin.x)),\(Int(adjustedTarget.origin.y)) \(Int(adjustedTarget.width))x\(Int(adjustedTarget.height))",
                    "actualFrame": "\(Int(finalNeighborFrame.origin.x)),\(Int(finalNeighborFrame.origin.y)) \(Int(finalNeighborFrame.width))x\(Int(finalNeighborFrame.height))",
                    "widthDelta": "\(Int(widthDelta))",
                    "heightDelta": "\(Int(heightDelta))"
                ], runId: taskContext.runId)
            } else {
                await lockManager.clearClampedFrame(runId: taskContext.runId, windowId: neighborWindowId)
            }

            DeskJigLog.debug(.restorationTrace, "Reflowed previously positioned neighbor after clamp", fields: [
                "taskId": taskContext.taskId,
                "taskType": taskContext.taskType.rawValue,
                "windowId": "\(neighborWindowId)",
                "beforeFrame": "\(Int(before.origin.x)),\(Int(before.origin.y)) \(Int(before.width))x\(Int(before.height))",
                "adjustedTarget": "\(Int(adjustedTarget.origin.x)),\(Int(adjustedTarget.origin.y)) \(Int(adjustedTarget.width))x\(Int(adjustedTarget.height))",
                "afterFrame": "\(Int(finalNeighborFrame.origin.x)),\(Int(finalNeighborFrame.origin.y)) \(Int(finalNeighborFrame.width))x\(Int(finalNeighborFrame.height))"
            ], runId: taskContext.runId)
        }

        // Row-level proportional redistribution pass:
        // When a clamp only directly affects one window in a row, the other windows
        // in the same row are untouched, producing unequal sizes. This pass finds
        // row siblings and scales them proportionally to fill the available width.
        guard !adjustedNeighborIds.isEmpty else { return }

        let allPositioned = await lockManager.getPositionedFrames(for: taskContext.runId)
        let yTolerance: CGFloat = 5
        var alreadyRedistributed = Set<CGWindowID>()

        for adjustedId in adjustedNeighborIds {
            guard !alreadyRedistributed.contains(adjustedId) else { continue }
            guard let adjustedFrame = allPositioned.first(where: { $0.windowId == adjustedId }) else { continue }
            let adjustedScreenIndex = screenIndexForFrame(adjustedFrame.effectiveTarget)

            // Find row siblings: same Y-band, not the clamped window itself
            let rowSiblings = allPositioned.filter { pf in
                guard let wid = pf.windowId, wid != currentWindowId else { return false }
                let candidateScreenIndex = screenIndexForFrame(pf.effectiveTarget)
                guard candidateScreenIndex == adjustedScreenIndex else { return false }
                return abs(pf.effectiveTarget.minY - adjustedFrame.effectiveTarget.minY) < yTolerance &&
                       abs(pf.effectiveTarget.maxY - adjustedFrame.effectiveTarget.maxY) < yTolerance
            }

            guard rowSiblings.count > 1 else { continue }

            let redistributionTargets = Self.calculateRowRedistributionTargets(
                rowSiblings: rowSiblings,
                clampedFrame: clampedFrame
            )
            for redistributionTarget in redistributionTargets {
                guard let sibling = rowSiblings.first(where: { $0.windowId == redistributionTarget.windowId }) else {
                    continue
                }
                let siblingWindowId = redistributionTarget.windowId
                let newTarget = redistributionTarget.targetFrame
                let finalFrame = await repositionWindowWithRetry(
                    windowId: siblingWindowId,
                    target: newTarget,
                    taskContext: taskContext,
                    stage: "row-redistribution"
                )

                guard let finalFrame else { continue }

                await lockManager.updatePositionedFrame(runId: taskContext.runId, windowId: siblingWindowId, effectiveTarget: newTarget, finalFrame: finalFrame)
                alreadyRedistributed.insert(siblingWindowId)

                let rowWidthDelta = abs(finalFrame.width - newTarget.width)
                let rowHeightDelta = abs(finalFrame.height - newTarget.height)
                if rowWidthDelta > 10 || rowHeightDelta > 10 {
                    await lockManager.registerClampedFrame(
                        runId: taskContext.runId,
                        windowId: siblingWindowId,
                        originalTarget: newTarget,
                        actualFrame: finalFrame
                    )
                } else {
                    await lockManager.clearClampedFrame(runId: taskContext.runId, windowId: siblingWindowId)
                }

                DeskJigLog.debug(.restorationTrace, "Row-proportional redistribution", fields: [
                    "taskId": taskContext.taskId,
                    "taskType": taskContext.taskType.rawValue,
                    "windowId": "\(siblingWindowId)",
                    "originalWidth": "\(Int(sibling.originalTarget.width))",
                    "newWidth": "\(Int(newTarget.width))",
                    "newX": "\(Int(newTarget.origin.x))",
                    "availableWidth": "\(Int(redistributionTarget.availableWidth))",
                    "proportion": String(format: "%.3f", redistributionTarget.proportion)
                ], runId: taskContext.runId)
            }
        }
    }

    struct RowRedistributionTarget: Equatable {
        let windowId: CGWindowID
        let targetFrame: CGRect
        let availableWidth: CGFloat
        let proportion: CGFloat
    }

    static func calculateRowRedistributionTargets(
        rowSiblings: [WindowLockManager.PositionedFrame],
        clampedFrame: WindowLockManager.ClampedFrame
    ) -> [RowRedistributionTarget] {
        guard rowSiblings.count > 1 else { return [] }

        let totalCurrentWidth = rowSiblings.reduce(CGFloat(0)) { $0 + $1.effectiveTarget.width }
        let rowMinX = rowSiblings.map(\.effectiveTarget.minX).min() ?? 0
        let availableWidth = clampedFrame.actualFrame.minX - rowMinX

        guard availableWidth > 0, totalCurrentWidth > 0 else { return [] }

        var currentX = rowMinX
        let sortedSiblings = rowSiblings.sorted { $0.effectiveTarget.minX < $1.effectiveTarget.minX }
        var targets: [RowRedistributionTarget] = []

        for sibling in sortedSiblings {
            guard let siblingWindowId = sibling.windowId else { continue }
            let proportion = sibling.effectiveTarget.width / totalCurrentWidth
            let newWidth = round(proportion * availableWidth)
            let newTarget = CGRect(
                x: currentX,
                y: sibling.effectiveTarget.origin.y,
                width: newWidth,
                height: sibling.effectiveTarget.height
            )
            currentX += newWidth

            // Only reposition if meaningfully different from current effective target
            guard abs(newTarget.origin.x - sibling.effectiveTarget.origin.x) > 2 ||
                  abs(newTarget.width - sibling.effectiveTarget.width) > 2 else {
                continue
            }

            targets.append(
                RowRedistributionTarget(
                    windowId: siblingWindowId,
                    targetFrame: newTarget,
                    availableWidth: availableWidth,
                    proportion: proportion
                )
            )
        }

        return targets
    }

    private func repositionWindowWithRetry(
        windowId: CGWindowID,
        target: CGRect,
        taskContext: RestorationTaskContext,
        stage: String,
        maxAttempts: Int = 3,
        retryDelayNs: UInt64 = 120_000_000
    ) async -> CGRect? {
        let attempts = max(1, maxAttempts)

        for attempt in 1...attempts {
            let frame = await MainActor.run { () -> CGRect? in
                guard let handle = WindowHandleResolver.resolve(
                    windowId: windowId,
                    preferredStrategy: .frameOnly,
                    filter: .all
                ) else {
                    return nil
                }
                handle.setFrame(target)
                return handle.frame ?? target
            }

            if let frame {
                return frame
            }

            guard attempt < attempts else { break }
            guard await Task.sleepUnlessCancelled(nanoseconds: retryDelayNs) else { break }
        }

        DeskJigLog.trace(.restorationPositioning, "RC10_DIAG unresolved-handle-retry-exhausted stage=\(stage) windowId=\(windowId) attempts=\(attempts)", runId: taskContext.runId)
        return nil
    }

    static func compensatedFrame(
        for targetFrame: CGRect,
        clampedOriginal: CGRect,
        clampedActual: CGRect,
        adjacencyTolerance: CGFloat = 5,
        minDimension: CGFloat = 1
    ) -> CGRect {
        var adjusted = targetFrame

        let xOverlap = min(targetFrame.maxX, clampedOriginal.maxX) - max(targetFrame.minX, clampedOriginal.minX)
        let yOverlap = min(targetFrame.maxY, clampedOriginal.maxY) - max(targetFrame.minY, clampedOriginal.minY)

        // Target was to the right of clamped original; shift right and reduce width.
        if abs(targetFrame.minX - clampedOriginal.maxX) < adjacencyTolerance, yOverlap > 0 {
            let rightExpansion = max(0, clampedActual.maxX - clampedOriginal.maxX)
            if rightExpansion > 0 {
                adjusted.origin.x += rightExpansion
                adjusted.size.width = max(minDimension, adjusted.width - rightExpansion)
            }
        }

        // Target was to the left of clamped original; reduce width from its right edge.
        if abs(targetFrame.maxX - clampedOriginal.minX) < adjacencyTolerance, yOverlap > 0 {
            let leftExpansion = max(0, clampedOriginal.minX - clampedActual.minX)
            if leftExpansion > 0 {
                adjusted.size.width = max(minDimension, adjusted.width - leftExpansion)
            }
        }

        // Target was below clamped original; shift down and reduce height.
        if abs(targetFrame.minY - clampedOriginal.maxY) < adjacencyTolerance, xOverlap > 0 {
            let downwardExpansion = max(0, clampedActual.maxY - clampedOriginal.maxY)
            if downwardExpansion > 0 {
                adjusted.origin.y += downwardExpansion
                adjusted.size.height = max(minDimension, adjusted.height - downwardExpansion)
            }
        }

        // Target was above clamped original; reduce height from its bottom edge.
        if abs(targetFrame.maxY - clampedOriginal.minY) < adjacencyTolerance, xOverlap > 0 {
            let upwardExpansion = max(0, clampedOriginal.minY - clampedActual.minY)
            if upwardExpansion > 0 {
                adjusted.size.height = max(minDimension, adjusted.height - upwardExpansion)
            }
        }

        return adjusted
    }

    static func correctedTargetFrameForObservedPositionDrift(
        desiredTarget: CGRect,
        observedFrame: CGRect,
        finalScreenIndex: Int,
        targetScreenIndex: Int,
        tolerance: CGFloat = 12,
        maxCorrection: CGFloat = 200,
        sizeTolerance: CGFloat = 10
    ) -> CGRect? {
        guard finalScreenIndex == targetScreenIndex else { return nil }

        let widthDelta = abs(observedFrame.width - desiredTarget.width)
        let heightDelta = abs(observedFrame.height - desiredTarget.height)
        guard widthDelta <= sizeTolerance, heightDelta <= sizeTolerance else { return nil }

        let dx = desiredTarget.minX - observedFrame.minX
        let dy = desiredTarget.minY - observedFrame.minY
        guard abs(dx) > tolerance || abs(dy) > tolerance else { return nil }
        guard abs(dx) <= maxCorrection, abs(dy) <= maxCorrection else { return nil }

        return CGRect(
            x: desiredTarget.origin.x + dx,
            y: desiredTarget.origin.y + dy,
            width: desiredTarget.width,
            height: desiredTarget.height
        )
    }

    static func adjustedFrameForObservedSizeClamp(
        desiredTarget: CGRect,
        observedFrame: CGRect,
        currentScreens: [FullScreenInfo]
    ) -> CGRect {
        let screenFrame = visibleFrameForBestMatchingScreen(
            containing: desiredTarget,
            among: currentScreens
        ) ?? desiredTarget

        var adjustedX = desiredTarget.origin.x
        var adjustedY = desiredTarget.origin.y
        let clampedWidth = observedFrame.width
        let clampedHeight = observedFrame.height

        if adjustedX + clampedWidth > screenFrame.maxX {
            adjustedX = screenFrame.maxX - clampedWidth
        }
        if adjustedY + clampedHeight > screenFrame.maxY {
            adjustedY = screenFrame.maxY - clampedHeight
        }

        adjustedX = max(adjustedX, screenFrame.minX)
        adjustedY = max(adjustedY, screenFrame.minY)

        return CGRect(
            x: adjustedX,
            y: adjustedY,
            width: clampedWidth,
            height: clampedHeight
        )
    }

    static func bestMatchingScreenIndex(
        for frame: CGRect,
        among screens: [FullScreenInfo]
    ) -> Int? {
        bestMatchingWindowCoordinateScreen(
            for: frame,
            among: windowCoordinateScreens(from: screens)
        )?.index
    }

    static func visibleFrameForBestMatchingScreen(
        containing frame: CGRect,
        among screens: [FullScreenInfo]
    ) -> CGRect? {
        bestMatchingWindowCoordinateScreen(
            for: frame,
            among: windowCoordinateScreens(from: screens)
        )?.screen.visibleFrame
    }

    private func preclampXcodeFrame(_ frame: CGRect) -> CGRect {
        guard frame.width < Self.xcodeMinimumWidth else { return frame }

        let currentScreens = NSScreen.screens.map { FullScreenInfo(screen: $0) }
        guard let visibleFrame = Self.visibleFrameForBestMatchingScreen(
            containing: frame,
            among: currentScreens
        ) else {
            return frame
        }

        var adjusted = frame
        adjusted.size.width = min(max(frame.width, Self.xcodeMinimumWidth), visibleFrame.width)

        if adjusted.maxX > visibleFrame.maxX {
            adjusted.origin.x = visibleFrame.maxX - adjusted.width
        }
        if adjusted.minX < visibleFrame.minX {
            adjusted.origin.x = visibleFrame.minX
        }
        if adjusted.maxY > visibleFrame.maxY {
            adjusted.origin.y = visibleFrame.maxY - adjusted.height
        }
        if adjusted.minY < visibleFrame.minY {
            adjusted.origin.y = visibleFrame.minY
        }

        return adjusted
    }

    static func shouldPollAfterActivation(
        activated: Bool,
        reopenSent: Bool,
        axWindowCount: Int,
        attempted: Bool
    ) -> Bool {
        guard attempted else { return false }
        return activated || reopenSent || axWindowCount == 0
    }

    static func activationPollSkipReason(
        activated: Bool,
        reopenSent: Bool,
        axWindowCount: Int,
        attempted: Bool
    ) -> String {
        if !attempted {
            return "no-running-app"
        }
        if activated {
            return "activated"
        }
        if reopenSent {
            return "reopen-sent"
        }
        if axWindowCount == 0 {
            return "ax-windows-empty"
        }
        return "activation-failed-ax-windows-present"
    }

    private func attemptActivateApp(
        pid: pid_t,
        bundleId: String?,
        taskContext: RestorationTaskContext
    ) async -> ActivationAttemptOutcome {
        await MainActor.run {
            let app = NSRunningApplication(processIdentifier: pid)
                ?? bundleId.flatMap { NSRunningApplication.runningApplications(withBundleIdentifier: $0).first }
            guard let app else { return .unavailable }

            let appName = app.localizedName ?? bundleId ?? "unknown"
            DeskJigLog.debug(.restorationTrace, "Activating app to resolve window handle", fields: [
                "taskId": taskContext.taskId,
                "taskType": taskContext.taskType.rawValue,
                "app": appName,
                "pid": "\(app.processIdentifier)"
            ], runId: taskContext.runId)

            let appElement = AXUIElementCreateApplication(app.processIdentifier)
            let axWindowCount = AXWindowService.shared.getWindowElements(from: appElement).count

            if app.isHidden {
                _ = app.unhide()
            }

            let activated: Bool
            if #available(macOS 14.0, *) {
                activated = app.activate()
            } else {
                activated = app.activate(options: [.activateIgnoringOtherApps, .activateAllWindows])
            }
            var reopenSent = false

            let allowReopen = Self.shouldSendReopenEvent(bundleId: bundleId)
            if axWindowCount == 0, allowReopen {
                reopenSent = Self.sendReopenEvent(to: app, taskContext: taskContext)
            }

            DeskJigLog.debug(.restorationTrace, "Activation attempt complete", fields: [
                "taskId": taskContext.taskId,
                "taskType": taskContext.taskType.rawValue,
                "app": appName,
                "pid": "\(app.processIdentifier)",
                "attempted": "true",
                "activated": "\(activated)",
                "axWindowCount": "\(axWindowCount)",
                "allowReopen": "\(allowReopen)",
                "reopenSent": "\(reopenSent)"
            ], runId: taskContext.runId)
            return ActivationAttemptOutcome(
                attempted: true,
                activated: activated,
                reopenSent: reopenSent,
                axWindowCount: axWindowCount
            )
        }
    }

    public static func shouldSendReopenEvent(bundleId: String?) -> Bool {
        guard let bundleId else { return true }
        // Reopen can spawn unmanaged windows in terminals when AX temporarily
        // reports zero windows during tmux attach/title updates.
        if BundleRegistry.isTerminal(bundleId) {
            return false
        }
        return true
    }

    static func sendReopenEvent(
        to app: NSRunningApplication,
        taskContext: RestorationTaskContext
    ) -> Bool {
        var targetDesc = AEAddressDesc()
        var event = AppleEvent()
        var reply = AppleEvent()

        var pid = app.processIdentifier
        let targetStatus = AECreateDesc(
            DescType(typeKernelProcessID),
            &pid,
            MemoryLayout<pid_t>.size,
            &targetDesc
        )

        guard targetStatus == noErr else {
            DeskJigLog.debug(.restorationTrace, "Reopen AppleEvent failed to create target", fields: [
                "taskId": taskContext.taskId,
                "taskType": taskContext.taskType.rawValue,
                "pid": "\(app.processIdentifier)",
                "status": "\(targetStatus)"
            ], runId: taskContext.runId)
            return false
        }

        defer {
            AEDisposeDesc(&event)
            AEDisposeDesc(&reply)
            AEDisposeDesc(&targetDesc)
        }

        let eventStatus = AECreateAppleEvent(
            AEEventClass(kCoreEventClass),
            AEEventID(kAEReopenApplication),
            &targetDesc,
            AEReturnID(kAutoGenerateReturnID),
            AETransactionID(kAnyTransactionID),
            &event
        )

        guard eventStatus == noErr else {
            DeskJigLog.debug(.restorationTrace, "Reopen AppleEvent failed to create event", fields: [
                "taskId": taskContext.taskId,
                "taskType": taskContext.taskType.rawValue,
                "pid": "\(app.processIdentifier)",
                "status": "\(eventStatus)"
            ], runId: taskContext.runId)
            return false
        }

        let sendStatus = AESendMessage(
            &event,
            &reply,
            AESendMode(kAENoReply),
            kAEDefaultTimeout
        )

        if sendStatus != noErr {
            DeskJigLog.debug(.restorationTrace, "Reopen AppleEvent failed to send", fields: [
                "taskId": taskContext.taskId,
                "taskType": taskContext.taskType.rawValue,
                "pid": "\(app.processIdentifier)",
                "status": "\(sendStatus)"
            ], runId: taskContext.runId)
            return false
        }

        return true
    }

    private func fallbackHandle(
        snapshotWindow: SnapshotWindow,
        preferredStrategy: AXMatchingStrategy
    ) -> WindowHandle? {
        guard let bundleId = snapshotWindow.bundleId else { return nil }
        let handles: [WindowHandle] = {
            let pid = snapshotWindow.pid
            if pid != 0,
               let service = FluentServices.shared.axWindowService {
                let pidWindows = service.getWindows(forProcessID: pid, bundleIdentifier: bundleId)
                if !pidWindows.isEmpty {
                    return pidWindows.map { WindowHandle(axWindow: $0) }
                }
            }
            return Window.allAcrossProcesses(forBundleID: bundleId, filter: .all)
        }()
        guard !handles.isEmpty else { return nil }

        // Prefer handles from the same PID when possible; tmux-backed Ghostty
        // launches frequently have empty titles, and bundle-wide fallback can
        // otherwise pick an unrelated terminal window.
        let pidScopedHandles = handles.filter { $0.processID == snapshotWindow.pid }
        let candidateHandles = pidScopedHandles.isEmpty ? handles : pidScopedHandles

        if let title = snapshotWindow.title, !title.isEmpty {
            let titleMatches = candidateHandles.filter { $0.title == title }
            if titleMatches.count == 1 {
                return titleMatches.first
            } else if titleMatches.count > 1 {
                // Multiple windows with the same title (e.g. Ghostty with slow title propagation).
                // Disambiguate by frame proximity to the snapshot window's last known position.
                let snapshotFrame = snapshotWindow.frame
                let byFrameProximity = titleMatches.min(by: { lhs, rhs in
                    guard let lhsFrame = lhs.frame, let rhsFrame = rhs.frame else { return lhs.frame != nil }
                    let lhsDist = abs(lhsFrame.origin.x - snapshotFrame.origin.x) + abs(lhsFrame.origin.y - snapshotFrame.origin.y)
                    let rhsDist = abs(rhsFrame.origin.x - snapshotFrame.origin.x) + abs(rhsFrame.origin.y - snapshotFrame.origin.y)
                    return lhsDist < rhsDist
                })
                if let best = byFrameProximity {
                    return best
                }
            }
        }

        let targetFrame = snapshotWindow.frame
        if let frameMatch = candidateHandles.first(where: { handle in
            guard let frame = handle.frame else { return false }
            return abs(frame.origin.x - targetFrame.origin.x) <= 5 &&
                abs(frame.origin.y - targetFrame.origin.y) <= 5 &&
                abs(frame.width - targetFrame.width) <= 5 &&
                abs(frame.height - targetFrame.height) <= 5
        }) {
            return frameMatch
        }

        // Document path matching for IDEs (Cursor, VS Code, etc.) when title is empty
        let expectedPath = snapshotWindow.ideDocumentPath ?? snapshotWindow.documentPath
        if let expectedPath = expectedPath {
            let normalizedExpected = normalizePath(expectedPath)
            if let docMatch = candidateHandles.first(where: { handle in
                guard let handleDocPath = handle.documentPath else { return false }
                return normalizePath(handleDocPath) == normalizedExpected
            }) {
                return docMatch
            }
        }

        if candidateHandles.count == 1 {
            return candidateHandles.first
        }

        if preferredStrategy == .pidFirstWindow {
            return candidateHandles.first
        }

        return nil
    }

    private func screenIndexForFrame(_ frame: CGRect) -> Int {
        Self.bestMatchingWindowCoordinateScreen(
            for: frame,
            among: currentWindowCoordinateScreens()
        )?.index ?? 0
    }

    private func framesMatch(_ lhs: CGRect, _ rhs: CGRect, tolerance: CGFloat = 2) -> Bool {
        lhs.approximatelyEquals(rhs, tolerance: tolerance, strict: true)
    }

    private func normalizePath(_ path: String) -> String {
        var normalized = path
        if normalized.hasPrefix("file://") {
            normalized = String(normalized.dropFirst(7))
        }
        // Remove trailing slashes for consistent comparison
        while normalized.hasSuffix("/") && normalized.count > 1 {
            normalized = String(normalized.dropLast())
        }
        return normalized
    }

    private static func cgWindowId(fromAXWindowNumber value: Int?) -> CGWindowID? {
        guard let value, value >= 0, value <= Int(UInt32.max) else { return nil }
        return CGWindowID(value)
    }

    private struct WindowCoordinateScreen {
        let displayID: Int
        let frame: CGRect
        let visibleFrame: CGRect
    }

    private struct WindowCoordinateScreenMatch {
        let index: Int
        let screen: WindowCoordinateScreen
    }

    private static func windowCoordinateScreens(from screens: [FullScreenInfo]) -> [WindowCoordinateScreen] {
        let currentScreens = WorkspaceDisplayTopology.sortScreens(screens)
        let anchorY = WorkspaceDisplayTopology.windowCoordinateAnchorY(from: currentScreens)
        return currentScreens.map { screen in
            WindowCoordinateScreen(
                displayID: screen.displayID,
                frame: CGRect(
                    x: screen.frame.origin.x,
                    y: anchorY - screen.frame.maxY,
                    width: screen.frame.width,
                    height: screen.frame.height
                ),
                visibleFrame: screen.visibleFrameInWindowCoordinates(globalMaxY: anchorY)
            )
        }
    }

    private static func bestMatchingWindowCoordinateScreen(
        for frame: CGRect,
        among screens: [WindowCoordinateScreen]
    ) -> WindowCoordinateScreenMatch? {
        guard !screens.isEmpty else { return nil }

        let centerPoint = CGPoint(x: frame.midX, y: frame.midY)
        if let exactMatch = screens.enumerated().first(where: { $0.element.frame.contains(centerPoint) }) {
            return WindowCoordinateScreenMatch(index: exactMatch.offset, screen: exactMatch.element)
        }

        let positiveAreaMatches = screens.enumerated().compactMap { index, screen -> (Int, WindowCoordinateScreen, CGFloat)? in
            let intersection = frame.intersection(screen.frame)
            guard !intersection.isNull, !intersection.isEmpty else { return nil }
            return (index, screen, intersection.width * intersection.height)
        }
        if let overlapMatch = positiveAreaMatches.max(by: { lhs, rhs in
            if lhs.2 != rhs.2 {
                return lhs.2 < rhs.2
            }
            return lhs.0 > rhs.0
        }) {
            return WindowCoordinateScreenMatch(index: overlapMatch.0, screen: overlapMatch.1)
        }

        let nearestMatch = screens.enumerated().min { lhs, rhs in
            let lhsCenter = CGPoint(x: lhs.element.frame.midX, y: lhs.element.frame.midY)
            let rhsCenter = CGPoint(x: rhs.element.frame.midX, y: rhs.element.frame.midY)
            let lhsDistance = hypot(centerPoint.x - lhsCenter.x, centerPoint.y - lhsCenter.y)
            let rhsDistance = hypot(centerPoint.x - rhsCenter.x, centerPoint.y - rhsCenter.y)
            if lhsDistance != rhsDistance {
                return lhsDistance < rhsDistance
            }
            return lhs.offset < rhs.offset
        }

        return nearestMatch.map { WindowCoordinateScreenMatch(index: $0.offset, screen: $0.element) }
    }

    private func currentWindowCoordinateScreens() -> [WindowCoordinateScreen] {
        Self.windowCoordinateScreens(from: NSScreen.screens.map { FullScreenInfo(screen: $0) })
    }

    // MARK: - Post-Positioning Verification

    /// Verifies all positioned windows match their original target frames and corrects any deviations.
    /// This handles transient clamping (e.g. Ghostty enforcing minimum width on first resize but
    /// accepting the same size on retry) and race conditions from parallel positioning.
    public func verifyAndCorrectPositions(
        runId: String,
        maxRetries: Int = 2
    ) async -> PositionVerificationResult {
        let positioned = await lockManager.getPositionedFrames(for: runId)
        guard !positioned.isEmpty else {
            return PositionVerificationResult(checked: 0, corrected: 0, failed: 0)
        }

        var checkedCount = 0
        var correctedCount = 0
        var failedCount = 0
        let tolerance: CGFloat = 5
        let layoutMatchScreens = await MainActor.run {
            WindowLayoutFrameMatcher.liveScreens()
        }

        recordLoop: for record in positioned {
            guard let windowId = record.windowId else { continue }

            // Coalesced MainActor hop (pos-06): resolve the handle and read its frame in one
            // actor block instead of two per-window round-trips.
            let (handle, currentFrame) = await MainActor.run { () -> (WindowHandle?, CGRect?) in
                let resolved = Window.findWithResult(windowId: windowId).window
                return (resolved, resolved?.frame)
            }
            guard let handle, let currentFrame else { continue }

            // Compare against the effective target, which incorporates any post-clamp
            // compensation needed to keep the final row layout non-overlapping.
            let targetFrame = record.effectiveTarget
            let observedFinalFrame = record.finalFrame
            let rawMatches = currentFrame.approximatelyEquals(targetFrame, tolerance: tolerance, strict: true)
            let matchesObservedFinal = currentFrame.approximatelyEquals(observedFinalFrame, tolerance: tolerance, strict: true)
            let matches =
                rawMatches ||
                WindowLayoutFrameMatcher.matchesLayout(
                    actualFrame: currentFrame,
                    targetFrame: targetFrame,
                    screens: layoutMatchScreens
                ) ||
                matchesObservedFinal ||
                WindowLayoutFrameMatcher.matchesLayout(
                    actualFrame: currentFrame,
                    targetFrame: observedFinalFrame,
                    screens: layoutMatchScreens
                )

            checkedCount += 1
            if matches { continue }

            // Window deviates — retry positioning
            var corrected = false
            for attempt in 1...maxRetries {
                _ = await MainActor.run {
                    handle.setFrame(targetFrame)
                }
                // Brief settle time for the window server
                guard await Task.sleepUnlessCancelled(for: .milliseconds(100)) else { break recordLoop }

                let retryFrame = await MainActor.run { handle.frame ?? currentFrame }
                let retryRawMatches = retryFrame.approximatelyEquals(targetFrame, tolerance: tolerance, strict: true)
                let retryMatches = retryRawMatches || WindowLayoutFrameMatcher.matchesLayout(
                    actualFrame: retryFrame,
                    targetFrame: targetFrame,
                    screens: layoutMatchScreens
                )

                DeskJigLog.debug(.restorationTrace, "Position verification retry", fields: [
                    "windowId": "\(windowId)",
                    "attempt": "\(attempt)",
                    "targetFrame": "\(Int(targetFrame.origin.x)),\(Int(targetFrame.origin.y)) \(Int(targetFrame.width))x\(Int(targetFrame.height))",
                    "beforeFrame": "\(Int(currentFrame.origin.x)),\(Int(currentFrame.origin.y)) \(Int(currentFrame.width))x\(Int(currentFrame.height))",
                    "afterFrame": "\(Int(retryFrame.origin.x)),\(Int(retryFrame.origin.y)) \(Int(retryFrame.width))x\(Int(retryFrame.height))",
                    "matched": "\(retryMatches)"
                ], runId: runId)

                if retryMatches {
                    corrected = true
                    // Update the positioned frame record so neighbor compensation uses correct data
                    await lockManager.registerPositionedFrame(
                        runId: runId,
                        windowId: windowId,
                        bundleId: record.bundleId,
                        originalTarget: record.originalTarget,
                        effectiveTarget: targetFrame,
                        finalFrame: retryFrame
                    )
                    break
                }
            }

            if corrected {
                correctedCount += 1
            } else {
                failedCount += 1
            }
        }

        if correctedCount > 0 || failedCount > 0 {
            DeskJigLog.debug(.restorationTrace, "Position verification complete", fields: [
                "checked": "\(checkedCount)",
                "corrected": "\(correctedCount)",
                "failed": "\(failedCount)"
            ], runId: runId)
        }

        return PositionVerificationResult(
            checked: checkedCount,
            corrected: correctedCount,
            failed: failedCount
        )
    }
}

public struct PositionVerificationResult: Sendable {
    public let checked: Int
    public let corrected: Int
    public let failed: Int
}

