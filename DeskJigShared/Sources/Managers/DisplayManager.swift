//
//  FullScreenInfo.swift
//  DeskJig
//
//  Created by Marco Freedom on 12.09.2025.
//

import Foundation
import AppKit
import CoreGraphics

// MARK: - Display Manager
public class DisplayManager: ObservableObject {
    @Published public var screens: [FullScreenInfo] = []

    /// The maximum Y coordinate in the global screen coordinate space
    /// In macOS, the coordinate space is anchored to the first screen (which is typically the main screen)
    /// This is used to convert from screen coordinates (bottom-left origin) to window coordinates (top-left origin)
    public var globalMaxY: CGFloat {
        WorkspaceDisplayTopology.globalMaxY(from: screens)
    }

    public var windowCoordinateAnchorY: CGFloat {
        WorkspaceDisplayTopology.windowCoordinateAnchorY(from: screens)
    }

    public init() {
        refreshScreens()
    }

    // MARK: - Screen Management
    public func refreshScreens() {
        screens = WorkspaceDisplayTopology.sortScreens(
            NSScreen.screens.map { FullScreenInfo(screen: $0) }
        )
    }
    
    func findDisplayForWindow(windowBounds: CGRect) -> CGDirectDisplayID? {
        let maxDisplays: UInt32 = 16
        var displayIDs = [CGDirectDisplayID](repeating: 0, count: Int(maxDisplays))
        var displayCount: UInt32 = 0
        
        CGGetActiveDisplayList(maxDisplays, &displayIDs, &displayCount)
        
        for i in 0..<Int(displayCount) {
            let displayID = displayIDs[i]
            let displayBounds = CGDisplayBounds(displayID)
            
            // Check if window intersects with this display
            if displayBounds.contains(CGPoint(x: windowBounds.midX, y:windowBounds.midY)) {
                return displayID
            }
        }
        
        return nil
    }
    
    public func getBestScreen(for rect: CGRect) -> FullScreenInfo? {
        if let foundWindowId = findDisplayForWindow(windowBounds: rect),
           let containingScreen = screens.first(where: { $0.displayID == Int(foundWindowId) }) {
            return containingScreen
        } else {
            return nil
        }
    }

    /// Calculates the distance from a point to the nearest edge of a rectangle
    /// - Parameters:
    ///   - point: The point
    ///   - rect: The rectangle
    /// - Returns: Distance to the rectangle (0 if point is inside)
    private func distanceFromPointToRect(point: NSPoint, rect: NSRect) -> CGFloat {
        let dx = max(0, max(rect.minX - point.x, point.x - rect.maxX))
        let dy = max(0, max(rect.minY - point.y, point.y - rect.maxY))
        return sqrt(dx * dx + dy * dy)
    }

    // MARK: - Coordinate Conversion Functions

    /// Converts a point from captured coordinates to display coordinates for non-primary displays
    /// - Parameters:
    ///   - capturedPoint: The point as captured (in screen coordinate system)
    ///   - targetScreen: The screen to convert coordinates for
    /// - Returns: The point in the target screen's local coordinate system
    public func convertCapturedPointToDisplayCoordinates(_ capturedPoint: NSPoint, for targetScreen: FullScreenInfo) -> NSPoint {
        let displayX = capturedPoint.x + targetScreen.frame.minX
        let globalMaxY = WorkspaceDisplayTopology.windowCoordinateAnchorY(from: screens)
        let displayY = capturedPoint.y + globalMaxY - (targetScreen.frame.height + targetScreen.frame.minY) - 25

        return NSPoint(x: displayX, y: displayY)
    }

    /// Converts display coordinates back to screen coordinates
    /// - Parameters:
    ///   - displayPoint: Point in display coordinate system (origin at top-left)
    ///   - sourceScreen: The screen the point belongs to
    /// - Returns: The point in screen coordinate system
    public func convertDisplayPointToScreenCoordinates(_ displayPoint: NSPoint, from sourceScreen: FullScreenInfo) -> NSPoint {
        let screenX = displayPoint.x - sourceScreen.frame.minX
        let globalMaxY = WorkspaceDisplayTopology.windowCoordinateAnchorY(from: screens)
        let screenY = displayPoint.y - (globalMaxY - (sourceScreen.frame.height + sourceScreen.frame.minY)) + 25
        
        return NSPoint(
            x: screenX,
            y: screenY
        )
    }
}
