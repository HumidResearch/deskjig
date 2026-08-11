//  WorkspaceDisplayResolution.swift
//  DeskJigShared

import Foundation
import CoreGraphics

public struct WorkspaceDisplayAssignment: Codable, Hashable, Sendable {
    public let slotID: UUID
    public let displayID: Int

    public init(slotID: UUID, displayID: Int) {
        self.slotID = slotID
        self.displayID = displayID
    }
}

public enum WorkspaceRestorePreparationMode: Sendable {
    case interactive
    case nonInteractive
}

public struct WorkspaceRestoreAssignmentPrompt: Sendable {
    public let normalizedWorkspace: Workspace
    public let currentScreens: [FullScreenInfo]
    public let analysis: ScreenMismatchAnalysis
    public let orderedSlotIDs: [UUID]
    public let suggestedAssignments: [WorkspaceDisplayAssignment]

    public init(
        normalizedWorkspace: Workspace,
        currentScreens: [FullScreenInfo],
        analysis: ScreenMismatchAnalysis,
        orderedSlotIDs: [UUID],
        suggestedAssignments: [WorkspaceDisplayAssignment]
    ) {
        self.normalizedWorkspace = normalizedWorkspace
        self.currentScreens = currentScreens
        self.analysis = analysis
        self.orderedSlotIDs = orderedSlotIDs
        self.suggestedAssignments = suggestedAssignments
    }

    public func displayAssignments(from mappings: [ScreenMappingInfo]) -> [WorkspaceDisplayAssignment] {
        let displayIDByCurrentIndex = Dictionary(
            uniqueKeysWithValues: currentScreens.enumerated().map { ($0.offset, $0.element.displayID) }
        )

        return mappings.compactMap { mapping in
            guard let currentIndex = mapping.currentIndex,
                  orderedSlotIDs.indices.contains(mapping.savedIndex),
                  let displayID = displayIDByCurrentIndex[currentIndex] else {
                return nil
            }

            return WorkspaceDisplayAssignment(
                slotID: orderedSlotIDs[mapping.savedIndex],
                displayID: displayID
            )
        }
    }
}

public struct ResolvedWorkspaceWindowTarget: Sendable {
    public let windowID: UUID
    public let slotID: UUID
    public let displayID: Int
    public let targetScreenIndex: Int
    public let targetFrame: CGRect

    public init(
        windowID: UUID,
        slotID: UUID,
        displayID: Int,
        targetScreenIndex: Int,
        targetFrame: CGRect
    ) {
        self.windowID = windowID
        self.slotID = slotID
        self.displayID = displayID
        self.targetScreenIndex = targetScreenIndex
        self.targetFrame = targetFrame
    }
}

public struct WorkspaceResolvedDisplayIdentity: Sendable {
    public let displaySlots: [WorkspaceDisplaySlot]
    public let screens: [WorkspaceScreen]
    public let trustedAssignments: [WorkspaceDisplayAssignment]
    public let usedRecoveredFingerprints: Bool
    public let recoveredFingerprintCount: Int
    public let shouldPersistUpdatedIdentity: Bool

    public init(
        displaySlots: [WorkspaceDisplaySlot],
        screens: [WorkspaceScreen],
        trustedAssignments: [WorkspaceDisplayAssignment],
        usedRecoveredFingerprints: Bool,
        recoveredFingerprintCount: Int,
        shouldPersistUpdatedIdentity: Bool
    ) {
        self.displaySlots = displaySlots
        self.screens = screens
        self.trustedAssignments = trustedAssignments
        self.usedRecoveredFingerprints = usedRecoveredFingerprints
        self.recoveredFingerprintCount = recoveredFingerprintCount
        self.shouldPersistUpdatedIdentity = shouldPersistUpdatedIdentity
    }
}

public struct ResolvedWorkspaceRestoreContext: Sendable {
    public let normalizedWorkspace: Workspace
    public let resolvedWorkspace: Workspace
    public let currentScreens: [FullScreenInfo]
    public let orderedSlots: [WorkspaceDisplaySlot]
    public let assignments: [WorkspaceDisplayAssignment]
    public let windowTargetsByWindowID: [UUID: ResolvedWorkspaceWindowTarget]
    public let resolvedDisplayIdentity: WorkspaceResolvedDisplayIdentity

    public init(
        normalizedWorkspace: Workspace,
        resolvedWorkspace: Workspace,
        currentScreens: [FullScreenInfo],
        orderedSlots: [WorkspaceDisplaySlot],
        assignments: [WorkspaceDisplayAssignment],
        windowTargetsByWindowID: [UUID: ResolvedWorkspaceWindowTarget],
        resolvedDisplayIdentity: WorkspaceResolvedDisplayIdentity
    ) {
        self.normalizedWorkspace = normalizedWorkspace
        self.resolvedWorkspace = resolvedWorkspace
        self.currentScreens = currentScreens
        self.orderedSlots = orderedSlots
        self.assignments = assignments
        self.windowTargetsByWindowID = windowTargetsByWindowID
        self.resolvedDisplayIdentity = resolvedDisplayIdentity
    }
}

public enum WorkspaceRestorePreparationResult: Sendable {
    case ready(ResolvedWorkspaceRestoreContext)
    case requiresAssignment(WorkspaceRestoreAssignmentPrompt)
}

/// How `normalizeWorkspace` treats a workspace persisted with neither
/// `displaySlots` nor `screens` (GH #566: "has no display slot geometry").
enum WorkspaceGeometryRepairPolicy: Sendable {
    /// Throw `RestorationError.invalidWorkspace`. Used by the persistence
    /// normalization path so flattened workspaces stay flattened on disk and
    /// remain eligible for the richer-copy healing in
    /// `Workspace.preservingDisplayMetadata(from:)` and the legacy repair UI.
    case strict
    /// Synthesize in-memory placeholder display slots so restoration can
    /// proceed (via the normal screen-assignment flow). The synthetic slots are
    /// never persisted directly; after a successful restore the resolved real
    /// display identity is written back by
    /// `WorkspaceManager.persistDisplayMetadataAfterSuccessfulRestore`.
    case synthesizeMissingGeometry
}

enum WorkspaceDisplayResolutionService {
    static func normalizeWorkspace(
        _ workspace: Workspace,
        repairPolicy: WorkspaceGeometryRepairPolicy = .strict
    ) throws -> Workspace {
        let normalizedSlots: [WorkspaceDisplaySlot]
        let normalizedScreens: [WorkspaceScreen]
        let windowsWithSlots: [WorkspaceWindow]

        if let displaySlots = workspace.displaySlots, !displaySlots.isEmpty {
            normalizedSlots = sortSlots(displaySlots)
            normalizedScreens = normalizedSlots.map { $0.asWorkspaceScreen() }
            let orderedSlotIDs = normalizedSlots.map(\.id)
            let slotIndexByID = Dictionary(uniqueKeysWithValues: orderedSlotIDs.enumerated().map { ($0.element, $0.offset) })

            windowsWithSlots = try workspace.windows.map { window in
                if let displaySlotID = window.displaySlotID {
                    guard let slotIndex = slotIndexByID[displaySlotID] else {
                        throw RestorationError.invalidWorkspace("Window '\(window.appName)' references missing display slot \(displaySlotID.uuidString)")
                    }
                    return window
                        .withDisplaySlotID(displaySlotID)
                        .withScreenMapping(screenIndex: slotIndex)
                }

                if let screenIndex = window.screenIndex {
                    guard normalizedSlots.indices.contains(screenIndex) else {
                        throw RestorationError.invalidWorkspace("Window '\(window.appName)' has invalid legacy screenIndex \(screenIndex)")
                    }
                    let slotID = normalizedSlots[screenIndex].id
                    return window
                        .withDisplaySlotID(slotID)
                        .withScreenMapping(screenIndex: screenIndex)
                }

                throw RestorationError.invalidWorkspace("Window '\(window.appName)' is missing both displaySlotID and legacy screenIndex")
            }
        } else {
            guard let screens = workspace.screens, !screens.isEmpty else {
                switch repairPolicy {
                case .strict:
                    throw RestorationError.invalidWorkspace("Workspace '\(workspace.name)' has no display slot geometry")
                case .synthesizeMissingGeometry:
                    return synthesizeMissingGeometry(for: workspace)
                }
            }

            let sortedScreens = WorkspaceDisplayTopology.sortWorkspaceScreens(screens)
            normalizedScreens = sortedScreens
            normalizedSlots = sortedScreens.enumerated().map { index, screen in
                WorkspaceDisplaySlot(screen: screen, title: "Monitor \(index + 1)")
            }
            let slotIDByLegacyScreenID = Dictionary(
                uniqueKeysWithValues: zip(sortedScreens.map(\.id), normalizedSlots.map(\.id))
            )
            let normalizedIndexByLegacyScreenID = Dictionary(
                uniqueKeysWithValues: sortedScreens.enumerated().map { ($0.element.id, $0.offset) }
            )

            windowsWithSlots = try workspace.windows.map { window in
                guard let legacyScreenIndex = window.screenIndex else {
                    throw RestorationError.invalidWorkspace("Window '\(window.appName)' is missing legacy screenIndex required for migration")
                }
                guard screens.indices.contains(legacyScreenIndex) else {
                    throw RestorationError.invalidWorkspace("Window '\(window.appName)' has invalid legacy screenIndex \(legacyScreenIndex)")
                }
                let legacyScreenID = screens[legacyScreenIndex].id
                guard let slotID = slotIDByLegacyScreenID[legacyScreenID],
                      let normalizedIndex = normalizedIndexByLegacyScreenID[legacyScreenID] else {
                    throw RestorationError.invalidWorkspace("Could not migrate legacy screen mapping for '\(window.appName)'")
                }
                return window
                    .withDisplaySlotID(slotID)
                    .withScreenMapping(screenIndex: normalizedIndex)
            }
        }

        return workspace.withNewWindowsAndScreens(
            windowsWithSlots,
            screens: normalizedScreens,
            displaySlots: normalizedSlots
        )
    }

    /// Rebuilds restorable in-memory geometry for a workspace persisted with
    /// neither `displaySlots` nor `screens` (a "flattened" workspace, GH #566).
    ///
    /// One placeholder slot is synthesized per saved `screenIndex` (windows
    /// without any screen mapping default to the first slot), using the same
    /// synthetic-slot shape as `WorkspaceLegacyLayoutRepair`. The placeholder
    /// geometry never matches a real display fingerprint, so restoration flows
    /// through the regular screen-mismatch analysis: interactive restores show
    /// the display-assignment prompt and non-interactive restores fail with the
    /// actionable `assignmentRequired` error instead of `invalidWorkspace`.
    private static func synthesizeMissingGeometry(for workspace: Workspace) -> Workspace {
        let slotCount = max(1, (workspace.windows.compactMap(\.screenIndex).max() ?? 0) + 1)
        let slotWidth: CGFloat = 1920
        let slotHeight: CGFloat = 1080
        let visibleHeight: CGFloat = 1050

        let syntheticSlots = (0..<slotCount).map { (index: Int) -> WorkspaceDisplaySlot in
            let xOrigin = CGFloat(index) * slotWidth
            let arrangementFrame = CGRect(x: xOrigin, y: 0, width: slotWidth, height: slotHeight)
            let visibleFrame = CGRect(x: xOrigin, y: 0, width: slotWidth, height: visibleHeight)
            return WorkspaceDisplaySlot(
                id: UUID(),
                title: "Monitor \(index + 1)",
                displayID: -(index + 1),
                displayName: "Recovered Monitor \(index + 1)",
                resolution: CGSize(width: slotWidth, height: slotHeight),
                arrangementFrame: arrangementFrame,
                visibleFrame: visibleFrame,
                isPrimary: index == 0
            )
        }

        let mappedWindows = workspace.windows.map { window -> WorkspaceWindow in
            let slotIndex = min(max(window.screenIndex ?? 0, 0), slotCount - 1)
            return window
                .withDisplaySlotID(syntheticSlots[slotIndex].id)
                .withScreenMapping(screenIndex: slotIndex)
        }

        DeskJigLog.warn(.workspace, "Workspace has no persisted display geometry - synthesized placeholder display slots for restore", fields: [
            "workspace": workspace.name,
            "workspaceID": workspace.id.uuidString,
            "windowCount": "\(workspace.windows.count)",
            "synthesizedSlotCount": "\(slotCount)"
        ])

        return workspace.withNewWindowsAndScreens(
            mappedWindows,
            screens: syntheticSlots.map { $0.asWorkspaceScreen() },
            displaySlots: syntheticSlots
        )
    }

    static func prepare(
        workspace: Workspace,
        currentScreens: [FullScreenInfo],
        mode: WorkspaceRestorePreparationMode,
        explicitAssignments: [WorkspaceDisplayAssignment] = [],
        legacyScreenMappings: [(workspaceScreenIndex: Int, currentScreenIndex: Int)] = []
    ) throws -> WorkspaceRestorePreparationResult {
        // Restore preparation repairs missing geometry instead of failing:
        // persisted workspaces that lost their display metadata (GH #566) get
        // synthetic slots here and flow into the assignment/mismatch analysis.
        let normalizedWorkspace = try normalizeWorkspace(workspace, repairPolicy: .synthesizeMissingGeometry)
        guard let orderedSlots = normalizedWorkspace.displaySlots, !orderedSlots.isEmpty else {
            throw RestorationError.invalidWorkspace("Workspace '\(workspace.name)' has no display slots after normalization")
        }

        let effectiveCurrentScreens = WorkspaceDisplayTopology.sortScreens(currentScreens)
        let enrichment = recoverLegacyDisplayFingerprints(
            slots: orderedSlots,
            currentScreens: effectiveCurrentScreens
        )
        let analysisSlots = enrichment.slots
        let slotScreens = analysisSlots.map { $0.asWorkspaceScreen() }
        let analysisWorkspace = normalizedWorkspace.withNewWindowsAndScreens(
            normalizedWorkspace.windows,
            screens: slotScreens,
            displaySlots: analysisSlots
        )
        let analysis = ScreenMismatchDetector.analyze(workspace: analysisWorkspace, currentScreens: effectiveCurrentScreens)
        let orderedSlotIDs = analysisSlots.map(\.id)
        let suggestedAssignments = analysis.suggestedMappings.compactMap { mapping -> WorkspaceDisplayAssignment? in
            guard let currentIndex = mapping.currentIndex,
                  orderedSlotIDs.indices.contains(mapping.savedIndex),
                  effectiveCurrentScreens.indices.contains(currentIndex) else {
                return nil
            }
            return WorkspaceDisplayAssignment(
                slotID: orderedSlotIDs[mapping.savedIndex],
                displayID: effectiveCurrentScreens[currentIndex].displayID
            )
        }

        let resolvedAssignments = try resolveAssignments(
            explicitAssignments: explicitAssignments,
            legacyScreenMappings: legacyScreenMappings,
            orderedSlotIDs: orderedSlotIDs,
            currentScreens: effectiveCurrentScreens
        )

        let allHighConfidence = analysis.suggestedMappings.allSatisfy { $0.isHighConfidence }
        let screenCountsMatch = analysis.savedScreenCount == analysis.currentScreenCount

        let requiresAssignment: Bool
        if screenCountsMatch && allHighConfidence {
            // All monitors confidently identified — no user assignment needed
            requiresAssignment = false
        } else {
            requiresAssignment =
                analysis.hasTopologyChange ||
                analysis.hasLowConfidenceMappings ||
                !screenCountsMatch ||
                suggestedAssignments.count != orderedSlots.count
        }

        let assignments = resolvedAssignments.isEmpty ? suggestedAssignments : resolvedAssignments
        let resolvedDisplayIdentity = buildResolvedDisplayIdentity(
            normalizedWorkspace: normalizedWorkspace,
            slots: analysisSlots,
            currentScreens: effectiveCurrentScreens,
            assignments: assignments,
            recoveredFingerprintCount: enrichment.recoveredCount
        )

        DeskJigLog.info(.workspace, "Workspace display preparation analyzed", fields: [
            "workspace": workspace.name,
            "savedScreenCount": "\(analysis.savedScreenCount)",
            "currentScreenCount": "\(analysis.currentScreenCount)",
            "screenCountsMatch": screenCountsMatch,
            "allHighConfidence": allHighConfidence,
            "hasTopologyChange": analysis.hasTopologyChange,
            "hasLowConfidenceMappings": analysis.hasLowConfidenceMappings,
            "recoveredFingerprintCount": "\(enrichment.recoveredCount)",
            "fingerprintRecoveryApplied": enrichment.recoveredCount > 0,
            "shouldPersistUpdatedIdentity": resolvedDisplayIdentity.shouldPersistUpdatedIdentity,
            "mappingKinds": analysis.suggestedMappings
                .map { "s\($0.savedIndex)->c\($0.currentIndex.map(String.init) ?? "nil"):\($0.matchKind.rawValue)" }
                .joined(separator: ","),
            "requiresAssignment": requiresAssignment
        ])

        if resolvedAssignments.isEmpty && requiresAssignment {
            if mode == .interactive {
                return .requiresAssignment(
                    WorkspaceRestoreAssignmentPrompt(
                        normalizedWorkspace: analysisWorkspace,
                        currentScreens: effectiveCurrentScreens,
                        analysis: analysis,
                        orderedSlotIDs: orderedSlotIDs,
                        suggestedAssignments: suggestedAssignments
                    )
                )
            }

            throw RestorationError.assignmentRequired(
                "Display arrangement for workspace '\(workspace.name)' requires explicit slot assignment before restore"
            )
        }

        let displayIndexByID = Dictionary(uniqueKeysWithValues: effectiveCurrentScreens.enumerated().map { ($0.element.displayID, $0.offset) })
        let assignmentBySlotID = Dictionary(uniqueKeysWithValues: assignments.map { ($0.slotID, $0.displayID) })
        let slotByID = Dictionary(uniqueKeysWithValues: analysisSlots.map { ($0.id, $0) })

        var resolvedWindows: [WorkspaceWindow] = []
        var windowTargetsByWindowID: [UUID: ResolvedWorkspaceWindowTarget] = [:]
        resolvedWindows.reserveCapacity(normalizedWorkspace.windows.count)
        windowTargetsByWindowID.reserveCapacity(normalizedWorkspace.windows.count)

        for window in normalizedWorkspace.windows {
            guard let slotID = window.displaySlotID else {
                throw RestorationError.invalidWorkspace("Window '\(window.appName)' is missing display slot geometry")
            }
            guard let displayID = assignmentBySlotID[slotID] else {
                // Slot has no assigned display (fewer monitors than saved layouts) — skip this window
                continue
            }
            guard let targetScreenIndex = displayIndexByID[displayID],
                  effectiveCurrentScreens.indices.contains(targetScreenIndex) else {
                throw RestorationError.unresolvedDisplays("Assigned display \(displayID) is no longer available")
            }
            guard let relativeFrame = window.relativeFrame else {
                throw RestorationError.invalidWorkspace("Window '\(window.appName)' is missing relative geometry")
            }
            guard let slot = slotByID[slotID] else {
                throw RestorationError.invalidWorkspace("Missing slot geometry for \(slotID.uuidString)")
            }

            let targetVisibleFrame = slot.projectedVisibleFrameInWindowCoordinates(
                on: effectiveCurrentScreens[targetScreenIndex],
                allCurrentScreens: effectiveCurrentScreens
            )
            let targetFrame = WindowFrameConverter.toAbsolute(
                relativeFrame: relativeFrame,
                screenFrame: targetVisibleFrame
            )
            let resolvedWindow = window.withScreenMapping(screenIndex: targetScreenIndex)
            resolvedWindows.append(resolvedWindow)
            windowTargetsByWindowID[window.id] = ResolvedWorkspaceWindowTarget(
                windowID: window.id,
                slotID: slotID,
                displayID: displayID,
                targetScreenIndex: targetScreenIndex,
                targetFrame: targetFrame
            )
        }

        let resolvedWorkspace = normalizedWorkspace.withNewWindowsAndScreens(
            resolvedWindows,
            screens: effectiveCurrentScreens.map { WorkspaceScreen(from: $0) },
            displaySlots: analysisSlots
        )

        return .ready(
            ResolvedWorkspaceRestoreContext(
                normalizedWorkspace: analysisWorkspace,
                resolvedWorkspace: resolvedWorkspace,
                currentScreens: effectiveCurrentScreens,
                orderedSlots: analysisSlots,
                assignments: assignments,
                windowTargetsByWindowID: windowTargetsByWindowID,
                resolvedDisplayIdentity: resolvedDisplayIdentity
            )
        )
    }

    private struct LegacyDisplayFingerprintRecoveryResult {
        let slots: [WorkspaceDisplaySlot]
        let recoveredCount: Int
    }

    private static func recoverLegacyDisplayFingerprints(
        slots: [WorkspaceDisplaySlot],
        currentScreens: [FullScreenInfo]
    ) -> LegacyDisplayFingerprintRecoveryResult {
        guard slots.count == currentScreens.count, !slots.isEmpty else {
            return LegacyDisplayFingerprintRecoveryResult(slots: slots, recoveredCount: 0)
        }

        var assignedCurrentIndices = Set<Int>()
        var recoveredBySlotID: [UUID: DisplayFingerprint] = [:]

        for slot in slots {
            if let existingFingerprint = slot.displayFingerprint {
                recoveredBySlotID[slot.id] = existingFingerprint
                if let matchedCurrentIndex = currentScreens.firstIndex(where: { existingFingerprint.matches($0.displayFingerprint) }) {
                    assignedCurrentIndices.insert(matchedCurrentIndex)
                }
                continue
            }

            let matches = currentScreens.enumerated().filter { currentIndex, currentScreen in
                !assignedCurrentIndices.contains(currentIndex) &&
                slotMatchesLegacyScreen(slot, currentScreen: currentScreen)
            }

            guard matches.count == 1, let match = matches.first else {
                return LegacyDisplayFingerprintRecoveryResult(slots: slots, recoveredCount: 0)
            }

            assignedCurrentIndices.insert(match.offset)
            recoveredBySlotID[slot.id] = match.element.displayFingerprint
        }

        let enrichedSlots = slots.map { slot in
            guard slot.displayFingerprint == nil,
                  let fingerprint = recoveredBySlotID[slot.id] else {
                return slot
            }

            return WorkspaceDisplaySlot(
                id: slot.id,
                title: slot.title,
                displayID: slot.displayID,
                displayName: slot.displayName,
                resolution: slot.resolution,
                arrangementFrame: slot.arrangementFrame,
                visibleFrame: slot.visibleFrame,
                isPrimary: slot.isPrimary,
                displayFingerprint: fingerprint
            )
        }

        let recoveredCount = enrichedSlots.reduce(into: 0) { count, slot in
            if slot.displayFingerprint != nil,
               slots.first(where: { $0.id == slot.id })?.displayFingerprint == nil {
                count += 1
            }
        }

        return LegacyDisplayFingerprintRecoveryResult(
            slots: enrichedSlots,
            recoveredCount: recoveredCount
        )
    }

    private static func slotMatchesLegacyScreen(
        _ slot: WorkspaceDisplaySlot,
        currentScreen: FullScreenInfo
    ) -> Bool {
        guard slot.arrangementFrame == currentScreen.frame,
              slot.resolution == currentScreen.resolution else {
            return false
        }

        return slot.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
            .caseInsensitiveCompare(currentScreen.name.trimmingCharacters(in: .whitespacesAndNewlines)) == .orderedSame
    }

    private static func buildResolvedDisplayIdentity(
        normalizedWorkspace: Workspace,
        slots: [WorkspaceDisplaySlot],
        currentScreens: [FullScreenInfo],
        assignments: [WorkspaceDisplayAssignment],
        recoveredFingerprintCount: Int
    ) -> WorkspaceResolvedDisplayIdentity {
        let currentScreenByDisplayID = Dictionary(uniqueKeysWithValues: currentScreens.map { ($0.displayID, $0) })
        let displayIDBySlotID = Dictionary(uniqueKeysWithValues: assignments.map { ($0.slotID, $0.displayID) })

        let persistedSlots = slots.map { slot in
            guard let displayID = displayIDBySlotID[slot.id],
                  let currentScreen = currentScreenByDisplayID[displayID] else {
                return slot
            }

            return WorkspaceDisplaySlot(
                id: slot.id,
                title: slot.title,
                displayID: currentScreen.displayID,
                displayName: currentScreen.name,
                resolution: currentScreen.resolution,
                arrangementFrame: currentScreen.frame,
                visibleFrame: currentScreen.visibleFrame,
                isPrimary: currentScreen.isPrimary,
                displayFingerprint: currentScreen.displayFingerprint
            )
        }

        let persistedScreens = persistedSlots.map { $0.asWorkspaceScreen() }
        let shouldPersistUpdatedIdentity =
            persistedSlots != (normalizedWorkspace.displaySlots ?? []) ||
            persistedScreens != (normalizedWorkspace.screens ?? [])

        return WorkspaceResolvedDisplayIdentity(
            displaySlots: persistedSlots,
            screens: persistedScreens,
            trustedAssignments: assignments,
            usedRecoveredFingerprints: recoveredFingerprintCount > 0,
            recoveredFingerprintCount: recoveredFingerprintCount,
            shouldPersistUpdatedIdentity: shouldPersistUpdatedIdentity
        )
    }

    /// Resolves caller-provided assignments (explicit slot assignments or legacy
    /// index mappings) into validated display assignments.
    ///
    /// Returns an empty array when the caller provided neither. Auto-suggested
    /// mappings are deliberately NOT used as a fallback here: `prepare` must be
    /// able to distinguish "the caller chose displays" from "we would have to
    /// guess" so that ambiguous topologies reach the assignment prompt
    /// (interactive) or the fail-fast `assignmentRequired` error
    /// (non-interactive). Confident auto-suggestions are adopted by `prepare`
    /// itself after the `requiresAssignment` gate passes.
    private static func resolveAssignments(
        explicitAssignments: [WorkspaceDisplayAssignment],
        legacyScreenMappings: [(workspaceScreenIndex: Int, currentScreenIndex: Int)],
        orderedSlotIDs: [UUID],
        currentScreens: [FullScreenInfo]
    ) throws -> [WorkspaceDisplayAssignment] {
        if !explicitAssignments.isEmpty {
            return try validateAssignments(explicitAssignments, orderedSlotIDs: orderedSlotIDs, currentScreens: currentScreens)
        }

        if !legacyScreenMappings.isEmpty {
            let assignments = try legacyScreenMappings.map { mapping -> WorkspaceDisplayAssignment in
                guard orderedSlotIDs.indices.contains(mapping.workspaceScreenIndex) else {
                    throw RestorationError.invalidWorkspace("Legacy screen mapping references invalid saved screen \(mapping.workspaceScreenIndex)")
                }
                guard currentScreens.indices.contains(mapping.currentScreenIndex) else {
                    throw RestorationError.unresolvedDisplays("Legacy screen mapping references unavailable current screen \(mapping.currentScreenIndex)")
                }
                return WorkspaceDisplayAssignment(
                    slotID: orderedSlotIDs[mapping.workspaceScreenIndex],
                    displayID: currentScreens[mapping.currentScreenIndex].displayID
                )
            }
            return try validateAssignments(assignments, orderedSlotIDs: orderedSlotIDs, currentScreens: currentScreens)
        }

        return []
    }

    private static func validateAssignments(
        _ assignments: [WorkspaceDisplayAssignment],
        orderedSlotIDs: [UUID],
        currentScreens: [FullScreenInfo]
    ) throws -> [WorkspaceDisplayAssignment] {
        let validSlotIDs = Set(orderedSlotIDs)
        let validDisplayIDs = Set(currentScreens.map(\.displayID))

        var seenSlotIDs = Set<UUID>()
        var seenDisplayIDs = Set<Int>()
        for assignment in assignments {
            guard validSlotIDs.contains(assignment.slotID) else {
                throw RestorationError.invalidWorkspace("Assignment references unknown display slot \(assignment.slotID.uuidString)")
            }
            guard validDisplayIDs.contains(assignment.displayID) else {
                throw RestorationError.unresolvedDisplays("Assignment references unavailable display \(assignment.displayID)")
            }
            if !seenSlotIDs.insert(assignment.slotID).inserted {
                throw RestorationError.assignmentRequired("Duplicate assignment for display slot \(assignment.slotID.uuidString)")
            }
            if !seenDisplayIDs.insert(assignment.displayID).inserted {
                throw RestorationError.assignmentRequired("Multiple slots assigned to display \(assignment.displayID)")
            }
        }

        return assignments.sorted {
            orderedSlotIDs.firstIndex(of: $0.slotID)! < orderedSlotIDs.firstIndex(of: $1.slotID)!
        }
    }

    private static func sortSlots(_ slots: [WorkspaceDisplaySlot]) -> [WorkspaceDisplaySlot] {
        slots.sorted { lhs, rhs in
            let lhsFrame = lhs.arrangementFrame
            let rhsFrame = rhs.arrangementFrame
            if lhsFrame.minX != rhsFrame.minX {
                return lhsFrame.minX < rhsFrame.minX
            }
            if lhsFrame.minY != rhsFrame.minY {
                return lhsFrame.minY > rhsFrame.minY
            }
            return lhs.id.uuidString < rhs.id.uuidString
        }
    }
}

