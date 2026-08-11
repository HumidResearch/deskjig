//  WorkspaceScreen.swift
//  DeskJigShared

import Foundation
import CoreGraphics

/// A codable representation of screen information for persisting in workspaces
public struct WorkspaceScreen: Codable, Identifiable, Hashable, Sendable {
    public let id: UUID
    public let displayID: Int
    public let name: String
    public let resolution: CGSize
    public let frame: CGRect
    public let visibleFrame: CGRect // Frame excluding menu bar and dock
    public let isPrimary: Bool
    public let displayFingerprint: DisplayFingerprint?

    public init(
        displayID: Int,
        name: String,
        resolution: CGSize,
        frame: CGRect,
        visibleFrame: CGRect,
        isPrimary: Bool,
        displayFingerprint: DisplayFingerprint? = nil
    ) {
        self.id = UUID()
        self.displayID = displayID
        self.name = name
        self.resolution = resolution
        self.frame = frame
        self.visibleFrame = visibleFrame
        self.isPrimary = isPrimary
        self.displayFingerprint = displayFingerprint
    }

    /// Create from FullScreenInfo
    public init(from fullScreenInfo: FullScreenInfo) {
        self.id = UUID()
        self.displayID = fullScreenInfo.displayID
        self.name = fullScreenInfo.name
        self.resolution = fullScreenInfo.resolution
        self.frame = fullScreenInfo.frame
        self.visibleFrame = fullScreenInfo.visibleFrame
        self.isPrimary = fullScreenInfo.isPrimary
        self.displayFingerprint = fullScreenInfo.displayFingerprint
    }

    // Custom decoder for backward compatibility
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        id = try container.decode(UUID.self, forKey: .id)
        displayID = try container.decode(Int.self, forKey: .displayID)
        name = try container.decode(String.self, forKey: .name)
        resolution = try container.decode(CGSize.self, forKey: .resolution)
        frame = try container.decode(CGRect.self, forKey: .frame)
        isPrimary = try container.decode(Bool.self, forKey: .isPrimary)
        displayFingerprint = try container.decodeIfPresent(DisplayFingerprint.self, forKey: .displayFingerprint)

        // Handle backward compatibility - visibleFrame might not exist in older saves
        // Default to frame if not present
        visibleFrame = try container.decodeIfPresent(CGRect.self, forKey: .visibleFrame) ?? frame
    }

    private enum CodingKeys: String, CodingKey {
        case id, displayID, name, resolution, frame, visibleFrame, isPrimary, displayFingerprint
    }

    /// Check if this screen info matches a current FullScreenInfo
    public func matches(_ fullScreenInfo: FullScreenInfo) -> Bool {
        if displayID == fullScreenInfo.displayID {
            return true
        }
        if let displayFingerprint {
            return displayFingerprint.matches(fullScreenInfo.displayFingerprint)
        }
        return false
    }

    /// Returns the visible frame converted to window coordinates (top-left origin)
    /// NSScreen uses bottom-left origin (Y increases upward)
    /// AXUIElement/Windows use top-left origin (Y increases downward)
    ///
    /// **⚠️ Single-Screen Only**: This property uses the screen's own frame for conversion,
    /// which only works correctly for single-screen setups. For multi-monitor setups,
    /// use `visibleFrameInWindowCoordinates(globalMaxY:)` instead.
    public var visibleFrameInWindowCoordinates: CGRect {
        // Single-screen conversion: Uses screen's own height
        // For multi-monitor setups, use visibleFrameInWindowCoordinates(globalMaxY:)
        let windowY = frame.height - visibleFrame.origin.y - visibleFrame.height

        return CGRect(
            x: visibleFrame.origin.x,
            y: windowY,
            width: visibleFrame.width,
            height: visibleFrame.height
        )
    }

    /// Returns the visible frame converted to window coordinates using the global coordinate space
    /// This is the CORRECT method for multi-monitor setups
    /// - Parameter globalMaxY: The maximum Y coordinate across all screens
    /// - Returns: Visible frame in global window coordinates (top-left origin)
    public func visibleFrameInWindowCoordinates(globalMaxY: CGFloat) -> CGRect {
        WorkspaceDisplayTopology.screenFrameInWindowCoordinates(
            visibleFrame,
            anchorY: globalMaxY
        )
    }

    /// Calculate the global maximum Y coordinate from an array of screens
    /// - Parameter screens: Array of WorkspaceScreen objects
    /// - Returns: The maximum frame.maxY in the topology
    public static func calculateGlobalMaxY(from screens: [WorkspaceScreen]) -> CGFloat {
        WorkspaceDisplayTopology.globalMaxY(from: screens)
    }

    public static func calculateWindowCoordinateAnchorY(from screens: [WorkspaceScreen]) -> CGFloat {
        WorkspaceDisplayTopology.windowCoordinateAnchorY(from: screens)
    }
}
