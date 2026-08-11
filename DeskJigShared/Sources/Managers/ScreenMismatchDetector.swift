//
//  ScreenMismatchDetector.swift
//  DeskJigShared
//
//  Detects screen configuration mismatches between saved workspaces and current displays.
//

import Foundation
import CoreGraphics

public enum ScreenMappingMatchKind: String, Sendable {
    case displayID
    case fingerprint
    case primary
    case geometry
    case unresolved
}

/// Represents the analysis of screen configuration between a workspace and current displays
public struct ScreenMismatchAnalysis: Sendable {
    /// Number of screens saved in the workspace
    public let savedScreenCount: Int
    /// Number of currently connected screens
    public let currentScreenCount: Int
    /// The screens saved in the workspace
    public let savedScreens: [WorkspaceScreen]
    /// The currently connected screens
    public let currentScreens: [FullScreenInfo]
    /// Auto-suggested mappings from saved screen index to current screen index
    public let suggestedMappings: [ScreenMappingInfo]
    /// Whether the current topology differs materially from the saved workspace geometry.
    public let hasTopologyChange: Bool
    /// Whether any mapping relies on low-confidence fallback logic.
    public let hasLowConfidenceMappings: Bool

    /// Public initializer
    public init(
        savedScreenCount: Int,
        currentScreenCount: Int,
        savedScreens: [WorkspaceScreen],
        currentScreens: [FullScreenInfo],
        suggestedMappings: [ScreenMappingInfo],
        hasTopologyChange: Bool = false,
        hasLowConfidenceMappings: Bool = false
    ) {
        self.savedScreenCount = savedScreenCount
        self.currentScreenCount = currentScreenCount
        self.savedScreens = savedScreens
        self.currentScreens = currentScreens
        self.suggestedMappings = suggestedMappings
        self.hasTopologyChange = hasTopologyChange
        self.hasLowConfidenceMappings = hasLowConfidenceMappings
    }

    /// Returns true when user should be prompted to select screen mappings
    public var requiresUserSelection: Bool {
        guard savedScreenCount > 0 else { return false }

        // When all monitors are confidently identified (displayID or fingerprint)
        // and screen counts match, skip user selection even if topology changed
        let allHighConfidence = suggestedMappings.allSatisfy { $0.isHighConfidence }
        if currentScreenCount == savedScreenCount && allHighConfidence {
            return false
        }

        return currentScreenCount < savedScreenCount ||
            hasLowConfidenceMappings ||
            hasTopologyChange
    }

    /// Returns true when more screens were saved than are currently available
    public var hasFewerScreens: Bool {
        currentScreenCount < savedScreenCount
    }

    /// Returns true when more screens are available than were saved
    public var hasMoreScreens: Bool {
        currentScreenCount > savedScreenCount
    }
}

/// Represents a mapping from a saved workspace screen to a current screen
public struct ScreenMappingInfo: Sendable, Equatable {
    /// Index of the screen in the saved workspace
    public let savedIndex: Int
    /// Index of the screen in current displays (nil if not mapped)
    public var currentIndex: Int?
    /// How this mapping was chosen.
    public let matchKind: ScreenMappingMatchKind
    /// Geometry score used for fallback matching.
    public let geometryScore: CGFloat?

    public init(
        savedIndex: Int,
        currentIndex: Int?,
        matchKind: ScreenMappingMatchKind = .unresolved,
        geometryScore: CGFloat? = nil
    ) {
        self.savedIndex = savedIndex
        self.currentIndex = currentIndex
        self.matchKind = matchKind
        self.geometryScore = geometryScore
    }

    public var isHighConfidence: Bool {
        matchKind == .displayID || matchKind == .fingerprint
    }
}

/// Service for detecting and analyzing screen configuration mismatches
public enum ScreenMismatchDetector {

    /// Analyzes a workspace's screen configuration against current displays
    /// - Parameters:
    ///   - workspace: The workspace to analyze
    ///   - currentScreens: Currently connected displays
    /// - Returns: Analysis result with mismatch info and suggested mappings
    public static func analyze(workspace: Workspace, currentScreens: [FullScreenInfo]) -> ScreenMismatchAnalysis {
        let savedScreens = workspace.screens ?? []

        // If no saved screens, return empty analysis (backward compatibility)
        guard !savedScreens.isEmpty else {
            return ScreenMismatchAnalysis(
                savedScreenCount: 0,
                currentScreenCount: currentScreens.count,
                savedScreens: [],
                currentScreens: currentScreens,
                suggestedMappings: [],
                hasTopologyChange: false,
                hasLowConfidenceMappings: false
            )
        }

        let suggestedMappings = suggestMappings(savedScreens: savedScreens, currentScreens: currentScreens)
        let hasLowConfidenceMappings = suggestedMappings.contains { !$0.isHighConfidence }
        let hasTopologyChange = topologyChanged(
            savedScreens: savedScreens,
            currentScreens: currentScreens,
            mappings: suggestedMappings
        )

        return ScreenMismatchAnalysis(
            savedScreenCount: savedScreens.count,
            currentScreenCount: currentScreens.count,
            savedScreens: savedScreens,
            currentScreens: currentScreens,
            suggestedMappings: suggestedMappings,
            hasTopologyChange: hasTopologyChange,
            hasLowConfidenceMappings: hasLowConfidenceMappings
        )
    }

    /// Suggests optimal mappings from saved screens to current screens.
    ///
    /// Preference order:
    /// 1. Exact display ID match
    /// 2. Persistent hardware fingerprint match
    /// 3. Primary-to-primary
    /// 4. Closest geometric match
    ///
    /// - Parameters:
    ///   - savedScreens: Screens saved in the workspace
    ///   - currentScreens: Currently connected displays
    /// - Returns: Array of suggested mappings
    public static func suggestMappings(
        savedScreens: [WorkspaceScreen],
        currentScreens: [FullScreenInfo]
    ) -> [ScreenMappingInfo] {
        guard !savedScreens.isEmpty else { return [] }

        var mappings = Array(
            repeating: ScreenMappingInfo(savedIndex: 0, currentIndex: nil),
            count: savedScreens.count
        )
        var usedCurrentIndices = Set<Int>()

        for savedIndex in savedScreens.indices {
            mappings[savedIndex] = ScreenMappingInfo(savedIndex: savedIndex, currentIndex: nil)
        }

        func assignSavedScreens(
            matchKind: ScreenMappingMatchKind,
            using matcher: (WorkspaceScreen, FullScreenInfo) -> Bool
        ) {
            for savedIndex in savedScreens.indices where mappings[savedIndex].currentIndex == nil {
                let savedScreen = savedScreens[savedIndex]
                if let currentIndex = currentScreens.indices.first(where: { currentIndex in
                    !usedCurrentIndices.contains(currentIndex) &&
                    matcher(savedScreen, currentScreens[currentIndex])
                }) {
                    mappings[savedIndex] = ScreenMappingInfo(
                        savedIndex: savedIndex,
                        currentIndex: currentIndex,
                        matchKind: matchKind
                    )
                    usedCurrentIndices.insert(currentIndex)
                }
            }
        }

        assignSavedScreens(matchKind: .displayID) { savedScreen, currentScreen in
            savedScreen.displayID == currentScreen.displayID
        }

        assignSavedScreens(matchKind: .fingerprint) { savedScreen, currentScreen in
            guard let fingerprint = savedScreen.displayFingerprint else { return false }
            return fingerprint.matches(currentScreen.displayFingerprint)
        }

        assignSavedScreens(matchKind: .primary) { savedScreen, currentScreen in
            savedScreen.isPrimary && currentScreen.isPrimary
        }

        for savedIndex in savedScreens.indices where mappings[savedIndex].currentIndex == nil {
            let savedScreen = savedScreens[savedIndex]
            let remainingCandidates = currentScreens.indices.filter { !usedCurrentIndices.contains($0) }
            guard let bestIndex = remainingCandidates.min(by: { lhs, rhs in
                score(savedScreen: savedScreen, currentScreen: currentScreens[lhs]) <
                    score(savedScreen: savedScreen, currentScreen: currentScreens[rhs])
            }) else {
                continue
            }
            let bestScore = score(savedScreen: savedScreen, currentScreen: currentScreens[bestIndex])
            mappings[savedIndex] = ScreenMappingInfo(
                savedIndex: savedIndex,
                currentIndex: bestIndex,
                matchKind: .geometry,
                geometryScore: bestScore
            )
            usedCurrentIndices.insert(bestIndex)
        }

        return mappings
    }

    private static func topologyChanged(
        savedScreens: [WorkspaceScreen],
        currentScreens: [FullScreenInfo],
        mappings: [ScreenMappingInfo]
    ) -> Bool {
        guard !savedScreens.isEmpty else { return false }

        if savedScreens.count != currentScreens.count {
            return true
        }

        for mapping in mappings {
            guard let currentIndex = mapping.currentIndex,
                  savedScreens.indices.contains(mapping.savedIndex),
                  currentScreens.indices.contains(currentIndex) else {
                return true
            }

            let savedScreen = savedScreens[mapping.savedIndex]
            let currentScreen = currentScreens[currentIndex]
            if topologyDelta(savedScreen: savedScreen, currentScreen: currentScreen) > 0.2 {
                return true
            }
        }

        return false
    }

    private static func topologyDelta(savedScreen: WorkspaceScreen, currentScreen: FullScreenInfo) -> CGFloat {
        let savedWidth = max(savedScreen.frame.width, 1)
        let savedHeight = max(savedScreen.frame.height, 1)

        let xDelta = abs(savedScreen.frame.minX - currentScreen.frame.minX) / savedWidth
        let yDelta = abs(savedScreen.frame.minY - currentScreen.frame.minY) / savedHeight
        let widthDelta = abs(savedScreen.frame.width - currentScreen.frame.width) / savedWidth
        let heightDelta = abs(savedScreen.frame.height - currentScreen.frame.height) / savedHeight

        return max(xDelta, yDelta, widthDelta, heightDelta)
    }

    private static func score(savedScreen: WorkspaceScreen, currentScreen: FullScreenInfo) -> CGFloat {
        let dx = abs(savedScreen.frame.origin.x - currentScreen.frame.origin.x)
        let dy = abs(savedScreen.frame.origin.y - currentScreen.frame.origin.y)
        let widthDiff = abs(savedScreen.frame.width - currentScreen.frame.width)
        let heightDiff = abs(savedScreen.frame.height - currentScreen.frame.height)
        return dx + dy + (widthDiff * 0.1) + (heightDiff * 0.1)
    }
}

// MARK: - FullScreenInfo Equatable conformance for firstIndex(of:)
extension FullScreenInfo: Equatable {
    public static func == (lhs: FullScreenInfo, rhs: FullScreenInfo) -> Bool {
        lhs.displayID == rhs.displayID
    }
}
