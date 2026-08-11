//
//  WorkspaceDisplayTopology.swift
//  DeskJigShared
//
//  Workspace-only monitor filtering based on ignored-display preferences.
//

import Foundation
import CoreGraphics

public enum WorkspaceDisplayTopology {
    public static let ignoredDisplaysKey = "workspace.ignoredDisplays"

    /// Converts a frame from screen coordinates (bottom-left origin) into
    /// window coordinates (top-left origin) using the provided window anchor.
    public static func screenFrameInWindowCoordinates(
        _ screenFrame: CGRect,
        anchorY: CGFloat
    ) -> CGRect {
        CGRect(
            x: screenFrame.origin.x,
            y: anchorY - screenFrame.maxY,
            width: screenFrame.width,
            height: screenFrame.height
        )
    }

    /// Converts a frame from screen coordinates into window coordinates using
    /// the primary display's top edge as the anchor.
    public static func screenFrameInWindowCoordinates(
        _ screenFrame: CGRect,
        from screens: [FullScreenInfo]
    ) -> CGRect {
        screenFrameInWindowCoordinates(
            screenFrame,
            anchorY: windowCoordinateAnchorY(from: screens)
        )
    }

    /// Converts a frame from screen coordinates into window coordinates using
    /// the primary display's top edge as the anchor.
    public static func screenFrameInWindowCoordinates(
        _ screenFrame: CGRect,
        from screens: [WorkspaceScreen]
    ) -> CGRect {
        screenFrameInWindowCoordinates(
            screenFrame,
            anchorY: windowCoordinateAnchorY(from: screens)
        )
    }

    public static func sortScreens(_ screens: [FullScreenInfo]) -> [FullScreenInfo] {
        screens.sorted(by: compareFrames)
    }

    public static func sortWorkspaceScreens(_ screens: [WorkspaceScreen]) -> [WorkspaceScreen] {
        screens.sorted(by: compareFrames)
    }

    public static func globalMaxY(from screens: [FullScreenInfo]) -> CGFloat {
        screens.map { $0.frame.maxY }.max() ?? 0
    }

    public static func globalMaxY(from screens: [WorkspaceScreen]) -> CGFloat {
        screens.map { $0.frame.maxY }.max() ?? 0
    }

    /// Returns the vertical anchor used by AX/CGWindowList window coordinates.
    /// On macOS this is the top edge of the primary display, not the top edge of
    /// the entire display topology.
    public static func windowCoordinateAnchorY(from screens: [FullScreenInfo]) -> CGFloat {
        if let primary = screens.first(where: \.isPrimary) {
            return primary.frame.maxY
        }
        return screens.first?.frame.maxY ?? 0
    }

    public static func windowCoordinateAnchorY(from screens: [WorkspaceScreen]) -> CGFloat {
        if let primary = screens.first(where: \.isPrimary) {
            return primary.frame.maxY
        }
        return screens.first?.frame.maxY ?? 0
    }

    public static func loadIgnoredDisplays(
        perUserDefaultsManager: PerUserDefaultsManager = .shared
    ) -> [IgnoredDisplayPreference] {
        perUserDefaultsManager.codable(forKey: ignoredDisplaysKey, as: [IgnoredDisplayPreference].self) ?? []
    }

    public static func saveIgnoredDisplays(
        _ ignoredDisplays: [IgnoredDisplayPreference],
        perUserDefaultsManager: PerUserDefaultsManager = .shared
    ) {
        perUserDefaultsManager.setCodable(ignoredDisplays, forKey: ignoredDisplaysKey)
    }

    public static func isIgnored(
        _ screen: FullScreenInfo,
        ignoredDisplays: [IgnoredDisplayPreference]
    ) -> Bool {
        ignoredDisplays.contains(where: { $0.matches(screen) })
    }

    public static func effectiveScreens(
        from rawScreens: [FullScreenInfo],
        ignoredDisplays: [IgnoredDisplayPreference] = loadIgnoredDisplays()
    ) -> [FullScreenInfo] {
        guard !rawScreens.isEmpty, !ignoredDisplays.isEmpty else {
            return sortScreens(rawScreens)
        }

        let filtered = rawScreens.filter { !isIgnored($0, ignoredDisplays: ignoredDisplays) }
        if filtered.isEmpty {
            DeskJigLog.warn(.workspace, "All current screens were ignored by workspace display preferences; falling back to raw screen topology", fields: [
                "rawCount": "\(rawScreens.count)",
                "ignoredCount": "\(ignoredDisplays.count)"
            ])
            return sortScreens(rawScreens)
        }

        return sortScreens(filtered)
    }

    public static func effectiveScreens(
        from displayManager: DisplayManager,
        ignoredDisplays: [IgnoredDisplayPreference] = loadIgnoredDisplays()
    ) -> [FullScreenInfo] {
        effectiveScreens(from: displayManager.screens, ignoredDisplays: ignoredDisplays)
    }

    private static func compareFrames(lhs: CGRect, rhs: CGRect) -> Bool {
        if lhs.minX != rhs.minX {
            return lhs.minX < rhs.minX
        }

        if lhs.minY != rhs.minY {
            return lhs.minY > rhs.minY
        }

        if lhs.width != rhs.width {
            return lhs.width < rhs.width
        }

        return lhs.height < rhs.height
    }

    private static func compareFrames(lhs: FullScreenInfo, rhs: FullScreenInfo) -> Bool {
        if compareFrames(lhs: lhs.frame, rhs: rhs.frame) {
            return true
        }

        if compareFrames(lhs: rhs.frame, rhs: lhs.frame) {
            return false
        }

        if lhs.isPrimary != rhs.isPrimary {
            return lhs.isPrimary
        }

        return lhs.displayID < rhs.displayID
    }

    private static func compareFrames(lhs: WorkspaceScreen, rhs: WorkspaceScreen) -> Bool {
        if compareFrames(lhs: lhs.frame, rhs: rhs.frame) {
            return true
        }

        if compareFrames(lhs: rhs.frame, rhs: lhs.frame) {
            return false
        }

        if lhs.isPrimary != rhs.isPrimary {
            return lhs.isPrimary
        }

        return lhs.displayID < rhs.displayID
    }
}
