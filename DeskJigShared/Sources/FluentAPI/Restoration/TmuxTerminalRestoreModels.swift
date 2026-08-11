//  TmuxTerminalRestoreModels.swift
//  DeskJigShared

import Foundation
import CoreGraphics

enum TmuxTerminalBindingEvidence: String, Sendable {
    case indexedTitle
    case indexedCandidateFallback
    case topologyUnavailableReuse
    case partialTopologyReuse
    case launchRequiredUnderProvisioned
    case axManagedTitle
    case exactWindowId
    case samePID
    case iTermTTY
    case tmuxClientPIDTree
    case uniqueFrameAndPath
    case prePostLaunchBundleDiff
    case unresolved
}

struct TmuxTerminalBindingPlan: Sendable {
    let bundleId: String
    let sessionName: String
    let tmuxIndex: Int
    let expectedWindowCount: Int
    let selectedWindowId: CGWindowID?
    let fallbackWindowIds: [CGWindowID]
    let evidence: TmuxTerminalBindingEvidence
    var staleWindowIds: [CGWindowID]
    let launchAllowed: Bool
}

struct TerminalBindingResult: Sendable {
    let bundleId: String
    let tmuxIndex: Int?
    let selectedWindowId: CGWindowID?
    let finalWindowId: CGWindowID?
    let selectedClientTTY: String?
    let sessionName: String?
    let staleWindowIds: [CGWindowID]
    let wasLaunched: Bool
    let launchAllowed: Bool
}

struct TmuxTerminalRestoreContext: Sendable {
    let preparedTerminalWindowsById: [UUID: WorkspaceWindow]
    let tmuxClients: [TmuxClientInfo]
    let tmuxClientWindowMap: [pid_t: CGWindowID]
    let iTermWindowTTYBindings: [CGWindowID: String]
    let bundleWindowInventory: [String: [SnapshotWindow]]
    let expectedIndicesByBundle: [String: Set<Int>]
    let bindingPlansByTaskId: [String: TmuxTerminalBindingPlan]

    static func initial(
        workspaceWindows: [WorkspaceWindow],
        preparedTerminalWindowsById: [UUID: WorkspaceWindow],
        snapshot: EnhancedSnapshot,
        tmuxClients: [TmuxClientInfo],
        tmuxClientWindowMap: [pid_t: CGWindowID],
        iTermWindowTTYBindings: [CGWindowID: String] = [:]
    ) -> TmuxTerminalRestoreContext {
        let terminalBundleInventory = Dictionary(
            grouping: snapshot.base.windows.filter { BundleRegistry.isTerminal($0.bundleId ?? "") }
        ) { $0.bundleId ?? "" }

        let expectedIndicesByBundle = Self.expectedIndices(for: workspaceWindows)

        return TmuxTerminalRestoreContext(
            preparedTerminalWindowsById: preparedTerminalWindowsById,
            tmuxClients: tmuxClients,
            tmuxClientWindowMap: tmuxClientWindowMap,
            iTermWindowTTYBindings: iTermWindowTTYBindings,
            bundleWindowInventory: terminalBundleInventory,
            expectedIndicesByBundle: expectedIndicesByBundle,
            bindingPlansByTaskId: [:]
        )
    }

    func withBindingPlans(_ bindingPlansByTaskId: [String: TmuxTerminalBindingPlan]) -> TmuxTerminalRestoreContext {
        TmuxTerminalRestoreContext(
            preparedTerminalWindowsById: preparedTerminalWindowsById,
            tmuxClients: tmuxClients,
            tmuxClientWindowMap: tmuxClientWindowMap,
            iTermWindowTTYBindings: iTermWindowTTYBindings,
            bundleWindowInventory: bundleWindowInventory,
            expectedIndicesByBundle: expectedIndicesByBundle,
            bindingPlansByTaskId: bindingPlansByTaskId
        )
    }

    func expectedWindowCount(for bundleId: String) -> Int {
        expectedIndicesByBundle[bundleId]?.count ?? 0
    }

    private static func expectedIndices(for workspaceWindows: [WorkspaceWindow]) -> [String: Set<Int>] {
        var countsByBundle: [String: Int] = [:]

        for window in workspaceWindows
        where BundleRegistry.isTerminal(window.bundleIdentifier) && window.tmuxState != nil {
            countsByBundle[window.bundleIdentifier, default: 0] += 1
        }

        return countsByBundle.reduce(into: [:]) { partialResult, entry in
            partialResult[entry.key] = Set(0..<entry.value)
        }
    }
}

enum ManagedTmuxWindowTitleMatcher {
    static func containsExpectedIndexedTitle(
        _ title: String?,
        expectedIndexedTitle: String
    ) -> Bool {
        guard let normalizedTitle = normalizeTitle(title) else { return false }
        return normalizedTitle.contains(expectedIndexedTitle.lowercased())
    }

    static func matchesManagedIndex(
        _ title: String?,
        bundleId: String,
        index: Int
    ) -> Bool {
        let indexedTitle = BundleRegistry.managedTmuxWindowTitle(bundleId: bundleId, index: index)
        if containsExpectedIndexedTitle(title, expectedIndexedTitle: indexedTitle) {
            return true
        }

        // Keep supporting legacy non-bundle-specific indexed titles used by older
        // snapshots and some unit tests.
        let legacyTitle = BundleRegistry.managedTmuxWindowTitle(index: index)
        return containsExpectedIndexedTitle(title, expectedIndexedTitle: legacyTitle)
    }

    static func managedIndex(from title: String?) -> Int? {
        guard let normalizedTitle = normalizeTitle(title) else { return nil }
        let prefix = "\(BundleRegistry.managedTmuxWindowTitle):"

        let managedSubstring: Substring
        if normalizedTitle.hasPrefix(prefix) {
            managedSubstring = normalizedTitle.dropFirst(prefix.count)
        } else if let range = normalizedTitle.range(of: prefix) {
            let afterPrefix = normalizedTitle[range.upperBound...]
            if let dashRange = afterPrefix.range(of: " \u{2014}") ?? afterPrefix.range(of: " —") {
                managedSubstring = afterPrefix[..<dashRange.lowerBound]
            } else {
                managedSubstring = afterPrefix
            }
        } else {
            return nil
        }

        let trailingComponent = managedSubstring.split(separator: ":").last.map(String.init) ?? ""
        guard !trailingComponent.isEmpty else { return nil }
        return Int(trailingComponent)
    }

    private static func normalizeTitle(_ title: String?) -> String? {
        guard let title else { return nil }
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return trimmed.lowercased()
    }
}

struct SingleProcessTerminalWindowResolver {
    struct AXCandidate: Sendable {
        let windowId: CGWindowID?
        let frame: CGRect?
        let title: String?
        let pid: pid_t?
    }

    struct Attempt: Sendable {
        let resolution: TerminalWindowIdentityResolver.SnapshotResolution?
        let candidateTitlesDescription: String
        let rejectionReason: String
    }

    static func resolve(
        bundleId: String,
        expectedIndexedTitle: String,
        bundleWindows: [SnapshotWindow],
        preLaunchBundleWindowIds: Set<CGWindowID>,
        claimedWindowIds: Set<CGWindowID>,
        targetFrame: CGRect? = nil,
        axCandidates: [AXCandidate]? = nil
    ) -> Attempt {
        let candidates = axCandidates ?? fetchAXCandidates(bundleId: bundleId)
        let candidateTitlesDescription = describeCandidates(candidates)

        let titledCandidates = candidates.filter {
            ManagedTmuxWindowTitleMatcher.containsExpectedIndexedTitle(
                $0.title,
                expectedIndexedTitle: expectedIndexedTitle
            )
        }
        guard !titledCandidates.isEmpty else {
            return Attempt(
                resolution: nil,
                candidateTitlesDescription: candidateTitlesDescription,
                rejectionReason: "no-title-match"
            )
        }

        let availableBundleWindows = bundleWindows.filter { !claimedWindowIds.contains($0.windowId) }
        var correlations: [TerminalWindowIdentityResolver.SnapshotResolution] = []

        for candidate in titledCandidates {
            if let correlated = correlateCandidate(
                candidate,
                to: availableBundleWindows,
                preLaunchBundleWindowIds: preLaunchBundleWindowIds
            ) {
                correlations.append(correlated)
            }
        }

        guard !correlations.isEmpty else {
            return Attempt(
                resolution: nil,
                candidateTitlesDescription: candidateTitlesDescription,
                rejectionReason: "no-snapshot-correlation"
            )
        }

        let uniqueCorrelations = Array(
            Dictionary(
                correlations.map { ($0.window.windowId, $0) },
                uniquingKeysWith: { first, _ in first }
            ).values
        )

        let preferredCorrelations = preferredCorrelationsFromNewWindows(
            uniqueCorrelations,
            preLaunchBundleWindowIds: preLaunchBundleWindowIds
        )

        let finalCorrelations: [TerminalWindowIdentityResolver.SnapshotResolution]
        if preferredCorrelations.count == 1 {
            finalCorrelations = preferredCorrelations
        } else if preferredCorrelations.isEmpty {
            finalCorrelations = uniqueCorrelations
        } else {
            return Attempt(
                resolution: nil,
                candidateTitlesDescription: candidateTitlesDescription,
                rejectionReason: "ambiguous-new-window-match"
            )
        }

        if finalCorrelations.count == 1, let resolved = finalCorrelations.first {
            return Attempt(
                resolution: resolved,
                candidateTitlesDescription: candidateTitlesDescription,
                rejectionReason: "none"
            )
        }

        if let targetFrame {
            let frameMatches = finalCorrelations.filter {
                TerminalWindowIdentityResolver.frameApproximatelyMatches($0.window.frame, targetFrame)
            }
            if frameMatches.count == 1, let resolved = frameMatches.first {
                return Attempt(
                    resolution: resolved,
                    candidateTitlesDescription: candidateTitlesDescription,
                    rejectionReason: "none"
                )
            }
        }

        return Attempt(
            resolution: nil,
            candidateTitlesDescription: candidateTitlesDescription,
            rejectionReason: "ambiguous-window-match"
        )
    }

    private static func fetchAXCandidates(bundleId: String) -> [AXCandidate] {
        Window.all(forBundleID: bundleId, filter: .all).map { handle in
            AXCandidate(
                windowId: TerminalWindowIdentityResolver.cgWindowId(fromAXWindowNumber: handle.windowId),
                frame: handle.frame,
                title: handle.title,
                pid: handle.processID
            )
        }
    }

    private static func correlateCandidate(
        _ candidate: AXCandidate,
        to bundleWindows: [SnapshotWindow],
        preLaunchBundleWindowIds: Set<CGWindowID>
    ) -> TerminalWindowIdentityResolver.SnapshotResolution? {
        if let candidateWindowId = candidate.windowId,
           let exactMatch = bundleWindows.first(where: { $0.windowId == candidateWindowId }) {
            return TerminalWindowIdentityResolver.SnapshotResolution(
                window: exactMatch,
                evidence: .axManagedTitle
            )
        }

        guard let frame = candidate.frame else { return nil }

        let frameMatches = bundleWindows.filter {
            TerminalWindowIdentityResolver.frameApproximatelyMatches($0.frame, frame)
        }
        if frameMatches.count == 1, let match = frameMatches.first {
            let evidence: TmuxTerminalBindingEvidence = preLaunchBundleWindowIds.contains(match.windowId)
                ? .axManagedTitle
                : .prePostLaunchBundleDiff
            return TerminalWindowIdentityResolver.SnapshotResolution(
                window: match,
                evidence: evidence
            )
        }

        let newFrameMatches = frameMatches.filter { !preLaunchBundleWindowIds.contains($0.windowId) }
        if newFrameMatches.count == 1, let match = newFrameMatches.first {
            return TerminalWindowIdentityResolver.SnapshotResolution(
                window: match,
                evidence: .prePostLaunchBundleDiff
            )
        }

        return nil
    }

    private static func preferredCorrelationsFromNewWindows(
        _ correlations: [TerminalWindowIdentityResolver.SnapshotResolution],
        preLaunchBundleWindowIds: Set<CGWindowID>
    ) -> [TerminalWindowIdentityResolver.SnapshotResolution] {
        let newWindowCorrelations = correlations.filter {
            !preLaunchBundleWindowIds.contains($0.window.windowId)
        }
        return newWindowCorrelations.isEmpty ? [] : newWindowCorrelations
    }

    private static func describeCandidates(_ candidates: [AXCandidate]) -> String {
        guard !candidates.isEmpty else { return "none" }
        return candidates.map { candidate in
            let windowId = candidate.windowId.map(String.init) ?? "nil"
            let title = candidate.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "nil"
            return "\(windowId)|\(title)"
        }.joined(separator: ",")
    }
}

struct TerminalWindowIdentityResolver {
    struct SnapshotResolution: Sendable {
        let window: SnapshotWindow
        let evidence: TmuxTerminalBindingEvidence
    }

    struct HandleResolution {
        let handle: WindowHandle
        let evidence: TmuxTerminalBindingEvidence
    }

    static func resolveSnapshotWindow(
        bundleId: String,
        plannedWindowId: CGWindowID?,
        preferredPID: pid_t?,
        preferredPath: String?,
        preferredFrame: CGRect?,
        bundleWindows: [SnapshotWindow]
    ) -> SnapshotResolution? {
        if let plannedWindowId,
           let planned = bundleWindows.first(where: { $0.windowId == plannedWindowId }) {
            return SnapshotResolution(window: planned, evidence: .exactWindowId)
        }

        if let preferredPID {
            let pidMatches = bundleWindows.filter { $0.pid == preferredPID }
            if pidMatches.count == 1, let match = pidMatches.first {
                return SnapshotResolution(window: match, evidence: .samePID)
            }
        }

        if let preferredPath {
            let normalizedPreferred = normalizePath(preferredPath)
            let pathMatches = bundleWindows.filter { window in
                guard let observed = normalizePath(window.freshWorkingDirectory ?? window.documentPath) else {
                    return false
                }
                return observed == normalizedPreferred
            }
            if pathMatches.count == 1, let match = pathMatches.first {
                return SnapshotResolution(window: match, evidence: .uniqueFrameAndPath)
            }
            if pathMatches.count > 1, let preferredFrame {
                let frameMatches = pathMatches.filter { frameApproximatelyMatches($0.frame, preferredFrame) }
                if frameMatches.count == 1, let match = frameMatches.first {
                    return SnapshotResolution(window: match, evidence: .uniqueFrameAndPath)
                }
            }
        }

        return nil
    }

    static func resolveHandle(
        bundleId: String,
        snapshotWindow: SnapshotWindow,
        handles: [WindowHandle]
    ) -> HandleResolution? {
        if let exactIdHandle = handles.first(where: {
            cgWindowId(fromAXWindowNumber: $0.windowId) == snapshotWindow.windowId
        }) {
            return HandleResolution(handle: exactIdHandle, evidence: .exactWindowId)
        }

        let samePIDHandles = handles.filter { $0.processID == snapshotWindow.pid }
        if samePIDHandles.count == 1, let handle = samePIDHandles.first {
            return HandleResolution(handle: handle, evidence: .samePID)
        }

        let preferredPath = normalizePath(snapshotWindow.freshWorkingDirectory ?? snapshotWindow.documentPath)
        if let preferredPath {
            let pathMatches = handles.filter { handle in
                guard let observed = normalizePath(handle.documentPath) else { return false }
                return observed == preferredPath
            }
            if pathMatches.count == 1, let handle = pathMatches.first {
                return HandleResolution(handle: handle, evidence: .uniqueFrameAndPath)
            }
            if pathMatches.count > 1 {
                let frameMatches = pathMatches.filter { handle in
                    guard let handleFrame = handle.frame else { return false }
                    return frameApproximatelyMatches(handleFrame, snapshotWindow.frame)
                }
                if frameMatches.count == 1, let handle = frameMatches.first {
                    return HandleResolution(handle: handle, evidence: .uniqueFrameAndPath)
                }
            }
        }

        return nil
    }

    fileprivate static func normalizePath(_ path: String?) -> String? {
        guard let path else { return nil }
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return URL(fileURLWithPath: (trimmed as NSString).expandingTildeInPath).standardizedFileURL.path
    }

    fileprivate static func frameApproximatelyMatches(_ lhs: CGRect, _ rhs: CGRect, tolerance: CGFloat = 20.0) -> Bool {
        abs(lhs.origin.x - rhs.origin.x) <= tolerance &&
        abs(lhs.origin.y - rhs.origin.y) <= tolerance &&
        abs(lhs.width - rhs.width) <= tolerance &&
        abs(lhs.height - rhs.height) <= tolerance
    }

    fileprivate static func cgWindowId(fromAXWindowNumber value: Int?) -> CGWindowID? {
        guard let value else { return nil }
        return CGWindowID(value)
    }
}
