//  WorkspacePortability.swift
//  DeskJigShared

import AppKit
import Foundation

// MARK: - Capability protocols (injected for testability, see CLAUDE.md DI pattern)

/// Narrow capability protocol: "is this app present on the machine?".
public protocol PortabilityAppAvailabilityChecking: Sendable {
    func isAppAvailable(bundleIdentifier: String, applicationPath: String?) -> Bool
}

/// Narrow capability protocol: "does this filesystem path exist?".
public protocol PortabilityPathChecking: Sendable {
    func pathExists(_ path: String) -> Bool
}

/// Production checker mirroring the availability semantics of
/// `FluentWorkspaceRestorer.isAppAvailableStatic`: a running app is always
/// available; otherwise the saved application path or the LaunchServices
/// bundle-identifier lookup must resolve to an existing bundle.
public final class SystemPortabilityAppAvailabilityChecker: PortabilityAppAvailabilityChecking {
    public static let shared = SystemPortabilityAppAvailabilityChecker()

    private init() {}

    public func isAppAvailable(bundleIdentifier: String, applicationPath: String?) -> Bool {
        if !NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).isEmpty {
            return true
        }
        if let applicationPath, FileManager.default.fileExists(atPath: applicationPath) {
            return true
        }
        if let appUrl = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier),
           FileManager.default.fileExists(atPath: appUrl.path) {
            return true
        }
        return false
    }
}

/// Production path checker backed by `FileManager`.
public final class FileSystemPortabilityPathChecker: PortabilityPathChecking {
    public static let shared = FileSystemPortabilityPathChecker()

    private init() {}

    public func pathExists(_ path: String) -> Bool {
        let expanded = (path as NSString).expandingTildeInPath
        return FileManager.default.fileExists(atPath: expanded)
    }
}

// MARK: - Report model

/// Pre-restore portability findings for one workspace, plus the degradation
/// each finding implies. Codable so the CLI can emit it in JSON envelopes.
public struct WorkspacePortabilityReport: Codable, Equatable, Sendable {

    public struct MissingApp: Codable, Equatable, Sendable {
        public let bundleIdentifier: String
        public let appName: String
        /// Number of saved windows that will be skipped because the app is missing.
        public let windowCount: Int

        public init(bundleIdentifier: String, appName: String, windowCount: Int) {
            self.bundleIdentifier = bundleIdentifier
            self.appName = appName
            self.windowCount = windowCount
        }
    }

    public struct MissingPath: Codable, Equatable, Sendable {
        public let path: String
        /// App names of the windows referencing the missing path (sorted, unique).
        public let appNames: [String]
        public let windowCount: Int

        public init(path: String, appNames: [String], windowCount: Int) {
            self.path = path
            self.appNames = appNames
            self.windowCount = windowCount
        }
    }

    public struct DisplayRemap: Codable, Equatable, Sendable {
        public let savedDisplayCount: Int
        public let currentDisplayCount: Int
        /// Windows whose saved display slot exceeds the available displays and
        /// will be remapped to the highest available display index.
        public let remappedWindowCount: Int

        public init(savedDisplayCount: Int, currentDisplayCount: Int, remappedWindowCount: Int) {
            self.savedDisplayCount = savedDisplayCount
            self.currentDisplayCount = currentDisplayCount
            self.remappedWindowCount = remappedWindowCount
        }
    }

    public let workspaceName: String
    public let savedDisplayCount: Int
    public let currentDisplayCount: Int
    /// Sorted by app name, then bundle identifier.
    public let missingApps: [MissingApp]
    /// Sorted by path.
    public let missingPaths: [MissingPath]
    /// Present only when the saved display count differs from the current one.
    public let displayRemap: DisplayRemap?
    /// Human-readable explanation of every finding and its degradation, in a
    /// deterministic order. Shared verbatim by the CLI and the app toast.
    public let warnings: [String]

    public init(
        workspaceName: String,
        savedDisplayCount: Int,
        currentDisplayCount: Int,
        missingApps: [MissingApp],
        missingPaths: [MissingPath],
        displayRemap: DisplayRemap?
    ) {
        self.workspaceName = workspaceName
        self.savedDisplayCount = savedDisplayCount
        self.currentDisplayCount = currentDisplayCount
        self.missingApps = missingApps
        self.missingPaths = missingPaths
        self.displayRemap = displayRemap
        self.warnings = Self.buildWarnings(
            missingApps: missingApps,
            missingPaths: missingPaths,
            displayRemap: displayRemap
        )
    }

    public var hasFindings: Bool {
        !missingApps.isEmpty || !missingPaths.isEmpty || displayRemap != nil
    }

    /// Total number of saved windows that will be skipped (missing apps).
    public var skippedWindowCount: Int {
        missingApps.reduce(0) { $0 + $1.windowCount }
    }

    private static func buildWarnings(
        missingApps: [MissingApp],
        missingPaths: [MissingPath],
        displayRemap: DisplayRemap?
    ) -> [String] {
        var lines: [String] = []

        if let remap = displayRemap {
            if remap.savedDisplayCount > remap.currentDisplayCount {
                lines.append(
                    "Saved on \(remap.savedDisplayCount) displays but only \(remap.currentDisplayCount) connected — " +
                    "\(remap.remappedWindowCount) window(s) will be remapped to display \(remap.currentDisplayCount)."
                )
            } else {
                lines.append(
                    "Saved on \(remap.savedDisplayCount) display(s) with \(remap.currentDisplayCount) connected — " +
                    "layout restores onto \(remap.savedDisplayCount) matching or first-available display(s)."
                )
            }
        }

        for app in missingApps {
            lines.append(
                "App '\(app.appName)' (\(app.bundleIdentifier)) is not installed — " +
                "\(app.windowCount) window(s) will be skipped."
            )
        }

        for missingPath in missingPaths {
            let apps = missingPath.appNames.joined(separator: ", ")
            lines.append(
                "Folder '\(missingPath.path)' no longer exists — referenced by \(apps) " +
                "(\(missingPath.windowCount) window(s)); the window(s) may open without their saved location."
            )
        }

        return lines
    }
}

// MARK: - Degradation result

/// Deterministically-degraded restore payload derived from a portability report.
public struct WorkspacePortabilityDegradation: Sendable {
    /// Workspace to restore: missing-app windows removed, overflow windows
    /// remapped to the highest available display slot. Display slots are never
    /// truncated so the saved multi-display layout survives on disk.
    public let workspace: Workspace
    /// Windows removed because their app is not installed.
    public let skippedWindows: [WorkspaceWindow]
    /// Deterministic slot→display assignments (identity matches first, then
    /// remaining displays in geometry-sorted order). Non-empty only when the
    /// saved display count differs from the current one; pass through to the
    /// restore call so non-interactive preparation cannot fail with
    /// `assignmentRequired`.
    public let displayAssignments: [WorkspaceDisplayAssignment]
    /// Number of windows remapped from an unavailable display slot.
    public let remappedWindowCount: Int
}

// MARK: - Analyzer

/// Computes portability findings for a workspace against the current machine
/// and derives the deterministic degradation payload. Stateless; dependencies
/// are injected with production defaults.
public struct WorkspacePortabilityAnalyzer: Sendable {

    private let appChecker: PortabilityAppAvailabilityChecking
    private let pathChecker: PortabilityPathChecking

    public init(
        appChecker: PortabilityAppAvailabilityChecking = SystemPortabilityAppAvailabilityChecker.shared,
        pathChecker: PortabilityPathChecking = FileSystemPortabilityPathChecker.shared
    ) {
        self.appChecker = appChecker
        self.pathChecker = pathChecker
    }

    /// Analyzes the workspace against the current display count and the local
    /// app/filesystem state. Pure inspection: never mutates the workspace.
    public func analyze(workspace: Workspace, currentDisplayCount: Int) -> WorkspacePortabilityReport {
        let normalized = normalizedIfPossible(workspace)
        let savedDisplayCount = Self.savedDisplayCount(for: workspace, normalized: normalized)
        let effectiveCurrentCount = max(currentDisplayCount, 1)

        let missingApps = findMissingApps(in: workspace)
        let missingPaths = findMissingPaths(in: workspace)

        var displayRemap: WorkspacePortabilityReport.DisplayRemap?
        if savedDisplayCount != effectiveCurrentCount {
            let missingBundleIDs = Set(missingApps.map(\.bundleIdentifier))
            let analysisWindows = (normalized ?? workspace).windows
                .filter { !missingBundleIDs.contains($0.bundleIdentifier) }
            let remappedWindowCount = analysisWindows
                .filter { ($0.screenIndex ?? 0) >= effectiveCurrentCount }
                .count
            displayRemap = WorkspacePortabilityReport.DisplayRemap(
                savedDisplayCount: savedDisplayCount,
                currentDisplayCount: effectiveCurrentCount,
                remappedWindowCount: remappedWindowCount
            )
        }

        return WorkspacePortabilityReport(
            workspaceName: workspace.name,
            savedDisplayCount: savedDisplayCount,
            currentDisplayCount: effectiveCurrentCount,
            missingApps: missingApps,
            missingPaths: missingPaths,
            displayRemap: displayRemap
        )
    }

    /// Builds the deterministically-degraded restore payload for a report.
    ///
    /// Missing-app windows are removed. When the saved display count differs
    /// from the connected display count, windows on unavailable slots are
    /// remapped to the highest available slot and explicit slot→display
    /// assignments are produced (identity matches first, then remaining
    /// displays in sorted order — see `deterministicAssignments`) so the
    /// restore is deterministic instead of failing with `assignmentRequired`.
    public func applyDegradations(
        to workspace: Workspace,
        currentScreens: [FullScreenInfo],
        report: WorkspacePortabilityReport
    ) -> WorkspacePortabilityDegradation {
        let missingBundleIDs = Set(report.missingApps.map(\.bundleIdentifier))
        let skippedWindows = workspace.windows.filter { missingBundleIDs.contains($0.bundleIdentifier) }

        // Display degradation needs normalized (sorted, slot-bound) geometry.
        // If normalization fails the workspace is structurally broken beyond
        // this feature's scope — degrade apps only and let the restore surface
        // the structural error.
        guard let normalized = normalizedIfPossible(workspace),
              let sortedSlots = normalized.displaySlots, !sortedSlots.isEmpty else {
            let keptWindows = workspace.windows.filter { !missingBundleIDs.contains($0.bundleIdentifier) }
            return WorkspacePortabilityDegradation(
                workspace: workspace.withNewWindows(keptWindows),
                skippedWindows: skippedWindows,
                displayAssignments: [],
                remappedWindowCount: 0
            )
        }

        let sortedCurrentScreens = WorkspaceDisplayTopology.sortScreens(currentScreens)
        let keptSlotCount = min(sortedSlots.count, max(sortedCurrentScreens.count, 1))
        let needsDisplayDegradation = report.displayRemap != nil && !sortedCurrentScreens.isEmpty

        var remappedWindowCount = 0
        let degradedWindows: [WorkspaceWindow] = normalized.windows.compactMap { window in
            guard !missingBundleIDs.contains(window.bundleIdentifier) else {
                return nil
            }
            guard needsDisplayDegradation, (window.screenIndex ?? 0) >= keptSlotCount else {
                return window
            }
            remappedWindowCount += 1
            let targetSlotIndex = keptSlotCount - 1
            return window
                .withDisplaySlotID(sortedSlots[targetSlotIndex].id)
                .withScreenMapping(screenIndex: targetSlotIndex)
        }

        let displayAssignments: [WorkspaceDisplayAssignment]
        if needsDisplayDegradation {
            displayAssignments = Self.deterministicAssignments(
                participatingSlots: Array(sortedSlots.prefix(keptSlotCount)),
                sortedCurrentScreens: sortedCurrentScreens
            )
        } else {
            displayAssignments = []
        }

        // Slots (and screens) are deliberately preserved in full — including
        // slots with no assigned display — so a successful degraded restore
        // never flattens the saved multi-display layout on disk.
        let degradedWorkspace = normalized.withNewWindowsAndScreens(
            degradedWindows,
            screens: normalized.screens,
            displaySlots: normalized.displaySlots
        )

        return WorkspacePortabilityDegradation(
            workspace: degradedWorkspace,
            skippedWindows: skippedWindows,
            displayAssignments: displayAssignments,
            remappedWindowCount: remappedWindowCount
        )
    }

    // MARK: - Private helpers

    /// Deterministic slot→display assignment. Two passes over the
    /// geometry-sorted inputs: (1) each slot claims a connected display it
    /// identifies (saved displayID or fingerprint via
    /// `WorkspaceDisplaySlot.matches`), so a workspace restored on its own
    /// machine keeps its displays; (2) remaining slots claim the remaining
    /// displays in sorted order. Both passes are order-stable, so the result
    /// is a pure function of the inputs.
    private static func deterministicAssignments(
        participatingSlots: [WorkspaceDisplaySlot],
        sortedCurrentScreens: [FullScreenInfo]
    ) -> [WorkspaceDisplayAssignment] {
        var claimedScreenIndices = Set<Int>()
        var displayIDBySlotID: [UUID: Int] = [:]

        // Pass 1: identity matches (saved displayID / display fingerprint).
        for slot in participatingSlots {
            let matchIndex = sortedCurrentScreens.indices.first { index in
                !claimedScreenIndices.contains(index) && slot.matches(sortedCurrentScreens[index])
            }
            if let matchIndex {
                claimedScreenIndices.insert(matchIndex)
                displayIDBySlotID[slot.id] = sortedCurrentScreens[matchIndex].displayID
            }
        }

        // Pass 2: fill unmatched slots with remaining displays in sorted order.
        for slot in participatingSlots where displayIDBySlotID[slot.id] == nil {
            let freeIndex = sortedCurrentScreens.indices.first { !claimedScreenIndices.contains($0) }
            if let freeIndex {
                claimedScreenIndices.insert(freeIndex)
                displayIDBySlotID[slot.id] = sortedCurrentScreens[freeIndex].displayID
            }
        }

        return participatingSlots.compactMap { slot in
            displayIDBySlotID[slot.id].map {
                WorkspaceDisplayAssignment(slotID: slot.id, displayID: $0)
            }
        }
    }

    private func normalizedIfPossible(_ workspace: Workspace) -> Workspace? {
        try? WorkspaceDisplayResolutionService.normalizeWorkspace(
            workspace,
            repairPolicy: .synthesizeMissingGeometry
        )
    }

    private static func savedDisplayCount(for workspace: Workspace, normalized: Workspace?) -> Int {
        if let slotCount = normalized?.displaySlots?.count, slotCount > 0 {
            return slotCount
        }
        if let slotCount = workspace.displaySlots?.count, slotCount > 0 {
            return slotCount
        }
        if let screenCount = workspace.screens?.count, screenCount > 0 {
            return screenCount
        }
        let maxIndex = workspace.windows.compactMap(\.screenIndex).max() ?? 0
        return max(maxIndex + 1, 1)
    }

    private func findMissingApps(in workspace: Workspace) -> [WorkspacePortabilityReport.MissingApp] {
        var windowCountByBundleID: [String: Int] = [:]
        var appNameByBundleID: [String: String] = [:]
        var applicationPathByBundleID: [String: String] = [:]

        for window in workspace.windows {
            windowCountByBundleID[window.bundleIdentifier, default: 0] += 1
            if appNameByBundleID[window.bundleIdentifier] == nil {
                appNameByBundleID[window.bundleIdentifier] = window.appName
            }
            if let applicationPath = window.applicationPath,
               applicationPathByBundleID[window.bundleIdentifier] == nil {
                applicationPathByBundleID[window.bundleIdentifier] = applicationPath
            }
        }

        return windowCountByBundleID
            .filter { bundleID, _ in
                !appChecker.isAppAvailable(
                    bundleIdentifier: bundleID,
                    applicationPath: applicationPathByBundleID[bundleID]
                )
            }
            .map { bundleID, count in
                WorkspacePortabilityReport.MissingApp(
                    bundleIdentifier: bundleID,
                    appName: appNameByBundleID[bundleID] ?? bundleID,
                    windowCount: count
                )
            }
            .sorted {
                if $0.appName != $1.appName { return $0.appName < $1.appName }
                return $0.bundleIdentifier < $1.bundleIdentifier
            }
    }

    private func findMissingPaths(in workspace: Workspace) -> [WorkspacePortabilityReport.MissingPath] {
        var windowCountByPath: [String: Int] = [:]
        var appNamesByPath: [String: Set<String>] = [:]

        for window in workspace.windows {
            guard let openPath = window.openPath, !openPath.isEmpty else { continue }
            windowCountByPath[openPath, default: 0] += 1
            appNamesByPath[openPath, default: []].insert(window.appName)
        }

        return windowCountByPath
            .filter { path, _ in !pathChecker.pathExists(path) }
            .map { path, count in
                WorkspacePortabilityReport.MissingPath(
                    path: path,
                    appNames: (appNamesByPath[path] ?? []).sorted(),
                    windowCount: count
                )
            }
            .sorted { $0.path < $1.path }
    }
}

