//  WorkspaceDisplaySlot.swift
//  DeskJigShared

import Foundation
import CoreGraphics

/// A saved layout surface in workspace-global geometry.
///
/// Slots are the persisted source of truth for workspace display arrangement.
/// Windows bind to a slot ID and keep their `RelativeWindowFrame` within that slot.
public struct WorkspaceDisplaySlot: Codable, Identifiable, Hashable, Sendable {
    public let id: UUID
    public let title: String
    public let displayID: Int?
    public let displayName: String
    public let resolution: CGSize
    public let arrangementFrame: CGRect
    public let visibleFrame: CGRect
    public let isPrimary: Bool
    public let displayFingerprint: DisplayFingerprint?

    public init(
        id: UUID = UUID(),
        title: String,
        displayID: Int?,
        displayName: String,
        resolution: CGSize,
        arrangementFrame: CGRect,
        visibleFrame: CGRect,
        isPrimary: Bool,
        displayFingerprint: DisplayFingerprint? = nil
    ) {
        self.id = id
        self.title = title
        self.displayID = displayID
        self.displayName = displayName
        self.resolution = resolution
        self.arrangementFrame = arrangementFrame
        self.visibleFrame = visibleFrame
        self.isPrimary = isPrimary
        self.displayFingerprint = displayFingerprint
    }

    public init(screen: WorkspaceScreen, title: String? = nil) {
        self.init(
            id: screen.id,
            title: title ?? screen.name,
            displayID: screen.displayID,
            displayName: screen.name,
            resolution: screen.resolution,
            arrangementFrame: screen.frame,
            visibleFrame: screen.visibleFrame,
            isPrimary: screen.isPrimary,
            displayFingerprint: screen.displayFingerprint
        )
    }

    public init(screen: FullScreenInfo, title: String? = nil) {
        self.init(
            title: title ?? screen.name,
            displayID: screen.displayID,
            displayName: screen.name,
            resolution: screen.resolution,
            arrangementFrame: screen.frame,
            visibleFrame: screen.visibleFrame,
            isPrimary: screen.isPrimary,
            displayFingerprint: screen.displayFingerprint
        )
    }

    public func matches(_ fullScreenInfo: FullScreenInfo) -> Bool {
        if let displayID, displayID == fullScreenInfo.displayID {
            return true
        }
        if let displayFingerprint {
            return displayFingerprint.matches(fullScreenInfo.displayFingerprint)
        }
        return false
    }

    public func asWorkspaceScreen() -> WorkspaceScreen {
        WorkspaceScreen(
            displayID: displayID ?? -1,
            name: displayName,
            resolution: resolution,
            frame: arrangementFrame,
            visibleFrame: visibleFrame,
            isPrimary: isPrimary,
            displayFingerprint: displayFingerprint
        )
    }

    /// Projects this slot's saved visible-area insets onto a currently assigned display frame
    /// and returns the result in window coordinates.
    public func projectedVisibleFrameInWindowCoordinates(
        on currentScreen: FullScreenInfo,
        allCurrentScreens: [FullScreenInfo]
    ) -> CGRect {
        let leftInset = max(0, visibleFrame.minX - arrangementFrame.minX)
        let rightInset = max(0, arrangementFrame.maxX - visibleFrame.maxX)
        let topInset = max(0, arrangementFrame.maxY - visibleFrame.maxY)
        let bottomInset = max(0, visibleFrame.minY - arrangementFrame.minY)

        let projectedVisibleFrame = CGRect(
            x: currentScreen.frame.minX + leftInset,
            y: currentScreen.frame.minY + bottomInset,
            width: max(0, currentScreen.frame.width - leftInset - rightInset),
            height: max(0, currentScreen.frame.height - topInset - bottomInset)
        )
        let globalMaxY = WorkspaceDisplayTopology.windowCoordinateAnchorY(from: allCurrentScreens)

        return CGRect(
            x: projectedVisibleFrame.minX,
            y: globalMaxY - projectedVisibleFrame.maxY,
            width: projectedVisibleFrame.width,
            height: projectedVisibleFrame.height
        )
    }
}
