//  TmuxManagedIndexTopology.swift
//  DeskJigShared

import Foundation
import CoreGraphics

enum TmuxIndexEnforcementPolicy: Sendable {
    case strictCoverage
}

enum TmuxIndexTraceReason: String, Sendable {
    case missingIndexedManagedWindow
    case duplicateIndexedManagedWindow
    case indexCoverageBootstrap
    case indexCoverageRepairAttempt
    case indexCoverageRepairRecovered
    case indexCoverageRepairFailed
    case itermWindowTTYMappedSelection
    case itermWindowTTYMappingUnavailable
}

enum TmuxIndexDecisionPath: String, Sendable {
    case indexedMatch = "indexed-match"
    case bootstrapMissingIndex = "bootstrap-missing-index"
    case duplicateIndexSelected = "duplicate-index-selected"
}

struct TmuxManagedIndexTopology {
    let bundleId: String
    let expectedIndices: Set<Int>
    let observedWindowsByIndex: [Int: [SnapshotWindow]]

    /// - Parameters:
    ///   - bundleId: The terminal bundle identifier
    ///   - expectedIndices: Set of indices the workspace requires
    ///   - windows: Snapshot windows for this bundle
    ///   - axTitlesByWindowId: Optional AX-sourced titles keyed by CG window ID.
    ///     CGWindowList often returns nil titles for Ghostty/kitty; this fallback
    ///     ensures managed titles are discoverable even when kCGWindowName is nil.
    init(
        bundleId: String,
        expectedIndices: Set<Int>,
        windows: [SnapshotWindow],
        axTitlesByWindowId: [CGWindowID: String] = [:]
    ) {
        self.bundleId = bundleId
        self.expectedIndices = expectedIndices

        var indexed: [Int: [SnapshotWindow]] = [:]
        // Include ALL windows with managed titles, even minimized/AX-inaccessible ones.
        // Minimized windows from a previous workspace still have valid managed titles
        // and should be discovered so the planner can reuse them instead of launching
        // new windows with duplicate indices.
        for window in windows {
            // Try CGWindowList title first, fall back to AX title
            let effectiveTitle = window.title ?? axTitlesByWindowId[window.windowId]
            guard let index = ManagedTmuxWindowTitleMatcher.managedIndex(from: effectiveTitle) else { continue }
            indexed[index, default: []].append(window)
        }
        self.observedWindowsByIndex = indexed
    }

    var observedIndices: Set<Int> {
        Set(observedWindowsByIndex.keys)
    }

    var missingIndices: Set<Int> {
        expectedIndices.subtracting(observedIndices)
    }

    var duplicateIndices: Set<Int> {
        Set(observedWindowsByIndex.compactMap { key, windows in
            windows.count > 1 ? key : nil
        })
    }

    func windows(for index: Int) -> [SnapshotWindow] {
        observedWindowsByIndex[index] ?? []
    }

    var expectedIndicesDescription: String { Self.describe(expectedIndices) }
    var observedIndicesDescription: String { Self.describe(observedIndices) }
    var missingIndicesDescription: String { Self.describe(missingIndices) }
    var duplicateIndicesDescription: String { Self.describe(duplicateIndices) }
    private static func describe(_ indices: Set<Int>) -> String {
        indices.sorted().map(String.init).joined(separator: ",")
    }
}
