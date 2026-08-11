//  RestorationExecutor+IDEExecutors.swift
//  DeskJigShared

import Foundation
import CoreGraphics
import AppKit

extension RestorationExecutor {

    // MARK: - IDE Decision Helpers

    func selectStrictXcodeHandle(
        bundleId: String,
        openPath: String,
        expectedTitle: String?,
        workspaceWindowId: UUID,
        expectedDirectory: String,
        targetFrame: CGRect,
        preferredWindowId: CGWindowID,
        taskContext: RestorationTaskContext
    ) async -> WindowHandle? {
        let maxAttempts = 5
        let retryDelayNs: UInt64 = 300_000_000
        var preferredFallbackHandle: WindowHandle?

        for attempt in 1...maxAttempts {
            let candidates = await MainActor.run {
                OpenByPathMatcher.findMatches(
                    bundleID: bundleId,
                    directoryPath: openPath,
                    expectedTitle: expectedTitle,
                    targetFrame: targetFrame,
                    windowID: workspaceWindowId
                )
            }
            let strictCandidates = candidates.filter { candidate in
                Self.isExactXcodeDirectoryMatch(
                    documentPath: candidate.documentPath,
                    expectedDirectory: expectedDirectory
                )
            }

            if preferredFallbackHandle == nil {
                preferredFallbackHandle = candidates.first(where: {
                    Self.cgWindowId(fromAXWindowNumber: $0.windowId) == preferredWindowId
                })
            }

            DeskJigLog.debug(.restorationTrace, "Xcode path-strict candidate evaluation", fields: [
                "taskId": taskContext.taskId,
                "expectedDirectory": expectedDirectory,
                "attempt": attempt,
                "candidateCounts": "total=\(candidates.count),exactPath=\(strictCandidates.count)"
            ], runId: taskContext.runId)

            if strictCandidates.count == 1 {
                return strictCandidates.first
            }

            if strictCandidates.count > 1 {
                if let byWindowId = strictCandidates.first(where: {
                    Self.cgWindowId(fromAXWindowNumber: $0.windowId) == preferredWindowId
                }) {
                    DeskJigLog.debug(.restorationTrace, "Xcode path-strict resolved by planned window ID", fields: [
                        "taskId": taskContext.taskId,
                        "expectedDirectory": expectedDirectory,
                        "resolvedWindowId": Int(preferredWindowId),
                        "candidateCount": strictCandidates.count
                    ], runId: taskContext.runId)
                    return byWindowId
                }

                let deterministic = strictCandidates.sorted { lhs, rhs in
                    let lhsDistance = Self.frameDistance(lhs.frame, targetFrame)
                    let rhsDistance = Self.frameDistance(rhs.frame, targetFrame)
                    if lhsDistance != rhsDistance {
                        return lhsDistance < rhsDistance
                    }

                    let lhsId = lhs.windowId ?? Int.max
                    let rhsId = rhs.windowId ?? Int.max
                    return lhsId < rhsId
                }.first

                if let deterministic {
                    DeskJigLog.debug(.restorationTrace, "Xcode path-strict resolved deterministically", fields: [
                        "taskId": taskContext.taskId,
                        "expectedDirectory": expectedDirectory,
                        "candidateCount": strictCandidates.count,
                        "resolvedWindowId": deterministic.windowId ?? -1
                    ], runId: taskContext.runId)
                    return deterministic
                }
            }

            if attempt < maxAttempts {
                // Cancelled: fail closed instead of falling through to the
                // planned-window fallback below.
                guard await Task.sleepUnlessCancelled(nanoseconds: retryDelayNs) else { return nil }
            }
        }

        if let preferredFallbackHandle {
            DeskJigLog.debug(.restorationTrace, "Xcode path-strict fallback to planned window ID", fields: [
                "taskId": taskContext.taskId,
                "expectedDirectory": expectedDirectory,
                "windowId": preferredFallbackHandle.windowId ?? -1
            ], runId: taskContext.runId)
            return preferredFallbackHandle
        }

        DeskJigLog.debug(.restorationTrace, "Xcode path-strict selection unresolved (fail closed)", fields: [
            "taskId": taskContext.taskId,
            "expectedDirectory": expectedDirectory,
            "reason": "no-strict-match-after-retries"
        ], runId: taskContext.runId)
        return nil
    }

    static func normalizeXcodeComparablePath(_ path: String?) -> String? {
        XcodePathMatching.normalizeComparable(path)
    }

    private static func isExactXcodeDirectoryMatch(documentPath: String?, expectedDirectory: String) -> Bool {
        guard let normalized = normalizeXcodeComparablePath(documentPath) else { return false }
        return normalized == expectedDirectory || normalized.hasPrefix("\(expectedDirectory)/")
    }
}
