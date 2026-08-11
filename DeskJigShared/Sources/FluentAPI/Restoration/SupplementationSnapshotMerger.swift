//  SupplementationSnapshotMerger.swift
//  DeskJigShared

import Foundation
import CoreGraphics

enum SupplementationSnapshotMerger {
    static func mergeSupplementationSnapshot(base: SystemSnapshot, overlay: SystemSnapshot) -> SystemSnapshot {
        var windowById: [CGWindowID: SnapshotWindow] = [:]
        for window in base.windows {
            windowById[window.windowId] = window
        }
        for window in overlay.windows {
            windowById[window.windowId] = window
        }

        let baseIds = Set(base.windows.map { $0.windowId })
        var mergedWindows: [SnapshotWindow] = []
        mergedWindows.reserveCapacity(windowById.count)

        for window in base.windows {
            mergedWindows.append(windowById[window.windowId] ?? window)
        }

        if mergedWindows.count < windowById.count {
            for (windowId, window) in windowById where !baseIds.contains(windowId) {
                mergedWindows.append(window)
            }
        }

        return SystemSnapshot(
            captureTime: base.captureTime,
            captureDurationMs: base.captureDurationMs,
            runId: base.runId,
            timing: base.timing,
            displays: base.displays,
            windows: mergedWindows,
            chromeCaptures: base.chromeCaptures
        )
    }

    static func supplementationSnapshot(from base: SystemSnapshot, windows: [SnapshotWindow]) -> SystemSnapshot {
        SystemSnapshot(
            captureTime: base.captureTime,
            captureDurationMs: base.captureDurationMs,
            runId: base.runId,
            timing: base.timing,
            displays: base.displays,
            windows: windows,
            chromeCaptures: base.chromeCaptures
        )
    }
}

// MARK: - Post-Restore Snapshot Store

extension FluentWorkspaceRestorer {
    actor PostRestoreSnapshotStore {
        private let baseSnapshot: SystemSnapshot
        private var terminalSnapshot: SystemSnapshot?
        private var ideSnapshot: SystemSnapshot?

        init(baseSnapshot: SystemSnapshot) {
            self.baseSnapshot = baseSnapshot
        }

        func recordTerminal(snapshot: SystemSnapshot) {
            terminalSnapshot = snapshot
        }

        func recordIDE(snapshot: SystemSnapshot) {
            ideSnapshot = snapshot
        }

        func mergedSnapshot() -> SystemSnapshot {
            var windowById: [CGWindowID: SnapshotWindow] = [:]
            for window in baseSnapshot.windows {
                windowById[window.windowId] = window
            }

            if let terminalSnapshot {
                for window in terminalSnapshot.windows {
                    windowById[window.windowId] = window
                }
            }

            if let ideSnapshot {
                for window in ideSnapshot.windows {
                    windowById[window.windowId] = window
                }
            }

            let baseIds = Set(baseSnapshot.windows.map { $0.windowId })
            var mergedWindows: [SnapshotWindow] = []
            mergedWindows.reserveCapacity(windowById.count)

            for window in baseSnapshot.windows {
                mergedWindows.append(windowById[window.windowId] ?? window)
            }

            if mergedWindows.count < windowById.count {
                for (windowId, window) in windowById where !baseIds.contains(windowId) {
                    mergedWindows.append(window)
                }
            }

            return SystemSnapshot(
                captureTime: baseSnapshot.captureTime,
                captureDurationMs: baseSnapshot.captureDurationMs,
                runId: baseSnapshot.runId,
                timing: baseSnapshot.timing,
                displays: baseSnapshot.displays,
                windows: mergedWindows,
                chromeCaptures: baseSnapshot.chromeCaptures
            )
        }
    }
}
