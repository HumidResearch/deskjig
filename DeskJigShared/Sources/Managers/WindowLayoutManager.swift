//
//  WindowLayoutManager.swift
//  DeskJig
//
//  Created by Marco Freedom on 16.09.2025.
//

import Foundation
import SwiftUI
import Cocoa
import ApplicationServices

// MARK: - Layout Zone Types

/// A template that indicates where to place one or more windows across the screen
/// in a specified layout.
public enum LayoutTemplate: String, CaseIterable, Hashable, Sendable, Identifiable {
    case leftRightHalf
    case topBottomHalf
    case threeHorizontal
    case threeVertical
    case fourParts
    case fullScreen
    
    static let defaultTemplate: LayoutTemplate = .leftRightHalf
    
    public var id: Self { self }

    public var displayName: String {
        switch self {
        case .leftRightHalf: "Left + Right"
        case .topBottomHalf: "Top + Bottom"
        case .threeHorizontal: "3 Horizontal"
        case .threeVertical: "3 Vertical"
        case .fourParts: "4 Parts"
        case .fullScreen: "Full Screen"
        }
    }
    
    var iconName: String {
        switch self {
        case .leftRightHalf: "rectangle.split.2x1"
        case .topBottomHalf: "rectangle.split.1x2"
        case .threeHorizontal: "rectangle.split.3x1"
        case .threeVertical: "rectangle.split.1x2"
        case .fourParts: "rectangle.split.2x2"
        case .fullScreen: "inset.filled.rectangle"
        }
    }
}

extension LayoutTemplate {
    /// Generates the layout zones using the provided screen frame and index.
    public func generateZones(in screenFrame: CGRect, screenIndex: Int) -> [LayoutZone] {
        switch self {
        case .leftRightHalf:
            generateLeftRightHalfZones(in: screenFrame, screenIndex: screenIndex)
        case .topBottomHalf:
            generateTopBottomHalfZones(in: screenFrame, screenIndex: screenIndex)
        case .threeHorizontal:
            generateThreeHorizontalZones(in: screenFrame, screenIndex: screenIndex)
        case .threeVertical:
            generateThreeVerticalZones(in: screenFrame, screenIndex: screenIndex)
        case .fourParts:
            generateFourPartZones(in: screenFrame, screenIndex: screenIndex)
        case .fullScreen:
            [LayoutZone(type: .fullScreen, frame: screenFrame, screenIndex: screenIndex)]
        }
    }
    
    /// Splits the value evenly between two, adding remainders in the order of the returned values.
    /// e.g. 3 -> (2,1)
    private func splitIntoTwo(_ value: CGFloat) -> (CGFloat, CGFloat) {
        let splitValue = value / 2
        let roundedSplitValue = splitValue.rounded(.down)
        var primaryValue = roundedSplitValue
        let secondaryValue = roundedSplitValue
        if roundedSplitValue != splitValue {
            primaryValue = roundedSplitValue + 1
        }
        return (primaryValue, secondaryValue)
    }
    
    /// Splits the value evenly between three, adding remainders in the order of the returned values.
    /// e.g. 5 -> (2,2,1)
    private func splitIntoThree(_ value: CGFloat) -> (CGFloat, CGFloat, CGFloat) {
        let splitValue = value / 3
        let roundedSplitValue = splitValue.rounded(.down)
        var primaryValue = roundedSplitValue
        var secondaryValue = roundedSplitValue
        let tertiaryValue = roundedSplitValue
        if roundedSplitValue != splitValue {
            primaryValue += 1
            if primaryValue + secondaryValue + tertiaryValue < value {
                secondaryValue += 1
            }
        }
        return (primaryValue, secondaryValue, tertiaryValue)
    }
    
    private func generateLeftRightHalfZones(
        in screenFrame: CGRect,
        screenIndex: Int
    ) -> [LayoutZone] {
        let (leadingWidth, trailingWidth) = splitIntoTwo(screenFrame.width)
        let leftHalfFrame = CGRect(
            x: screenFrame.origin.x,
            y: screenFrame.origin.y,
            width: leadingWidth,
            height: screenFrame.height
        )
        
        let rightHalfFrame = CGRect(
            x: screenFrame.origin.x + leadingWidth,
            y: screenFrame.origin.y,
            width: trailingWidth,
            height: screenFrame.height
        )
        
        return [
            LayoutZone(type: .leftHalf, frame: leftHalfFrame, screenIndex: screenIndex),
            LayoutZone(type: .rightHalf, frame: rightHalfFrame, screenIndex: screenIndex)
        ]
    }
    
    
    private func generateTopBottomHalfZones(
        in screenFrame: CGRect,
        screenIndex: Int
    ) -> [LayoutZone] {
        let (topHeight, bottomHeight) = splitIntoTwo(screenFrame.height)
        let topHalfFrame = CGRect(
            x: screenFrame.origin.x,
            y: screenFrame.origin.y + bottomHeight,
            width: screenFrame.width,
            height: topHeight
        )
        
        let bottomHalfFrame = CGRect(
            x: screenFrame.origin.x,
            y: screenFrame.origin.y,
            width: screenFrame.width,
            height: bottomHeight
        )
        
        return [
            LayoutZone(type: .topHalf, frame: topHalfFrame, screenIndex: screenIndex),
            LayoutZone(type: .bottomHalf, frame: bottomHalfFrame, screenIndex: screenIndex)
        ]
    }
    
    private func generateThreeHorizontalZones(
        in screenFrame: CGRect,
        screenIndex: Int
    ) -> [LayoutZone] {
        let (leadingWidth, middleWidth, trailingWidth) = splitIntoThree(screenFrame.width)
        
        let leftThirdFrame = CGRect(
            x: screenFrame.origin.x,
            y: screenFrame.origin.y,
            width: leadingWidth,
            height: screenFrame.height
        )
        
        let centerThirdFrame = CGRect(
            x: screenFrame.origin.x + leadingWidth,
            y: screenFrame.origin.y,
            width: middleWidth,
            height: screenFrame.height
        )
        
        let rightThirdFrame = CGRect(
            x: screenFrame.origin.x + leadingWidth + middleWidth,
            y: screenFrame.origin.y,
            width: trailingWidth,
            height: screenFrame.height
        )
        
        return [
            LayoutZone(type: .leftThird, frame: leftThirdFrame, screenIndex: screenIndex),
            LayoutZone(type: .centerThird, frame: centerThirdFrame, screenIndex: screenIndex),
            LayoutZone(type: .rightThird, frame: rightThirdFrame, screenIndex: screenIndex)
        ]
    }
    
    private func generateThreeVerticalZones(
        in screenFrame: CGRect,
        screenIndex: Int
    ) -> [LayoutZone] {
        let (topHeight, middleHeight, bottomHeight) = splitIntoThree(screenFrame.height)
        
        let topThirdFrame = CGRect(
            x: screenFrame.origin.x,
            y: screenFrame.origin.y + middleHeight + bottomHeight,
            width: screenFrame.width,
            height: topHeight
        )
        
        let middleThirdFrame = CGRect(
            x: screenFrame.origin.x,
            y: screenFrame.origin.y + bottomHeight,
            width: screenFrame.width,
            height: middleHeight
        )
        
        let bottomThirdFrame = CGRect(
            x: screenFrame.origin.x,
            y: screenFrame.origin.y,
            width: screenFrame.width,
            height: bottomHeight
        )
        
        return [
            LayoutZone(type: .topThird, frame: topThirdFrame, screenIndex: screenIndex),
            LayoutZone(type: .middleThird, frame: middleThirdFrame, screenIndex: screenIndex),
            LayoutZone(type: .bottomThird, frame: bottomThirdFrame, screenIndex: screenIndex)
        ]
    }
    
    private func generateFourPartZones(
        in screenFrame: CGRect,
        screenIndex: Int
    ) -> [LayoutZone] {
        let (topHeight, bottomHeight) = splitIntoTwo(screenFrame.height)
        let (leadingWidth, trailingWidth) = splitIntoTwo(screenFrame.width)
        
        let topLeftFrame = CGRect(
            x: screenFrame.origin.x,
            y: screenFrame.origin.y + bottomHeight,
            width: leadingWidth,
            height: topHeight
        )
        
        let topRightFrame = CGRect(
            x: screenFrame.origin.x + leadingWidth,
            y: screenFrame.origin.y + bottomHeight,
            width: trailingWidth,
            height: topHeight
        )
        
        let bottomLeftFrame = CGRect(
            x: screenFrame.origin.x,
            y: screenFrame.origin.y,
            width: leadingWidth,
            height: bottomHeight
        )
        
        let bottomRightFrame = CGRect(
            x: screenFrame.origin.x + leadingWidth,
            y: screenFrame.origin.y,
            width: trailingWidth,
            height: bottomHeight
        )
        
        return [
            LayoutZone(type: .topLeft, frame: topLeftFrame, screenIndex: screenIndex),
            LayoutZone(type: .topRight, frame: topRightFrame, screenIndex: screenIndex),
            LayoutZone(type: .bottomLeft, frame: bottomLeftFrame, screenIndex: screenIndex),
            LayoutZone(type: .bottomRight, frame: bottomRightFrame, screenIndex: screenIndex)
        ]
    }
}

/// An individual layout zone type, indicating a specific zone within the layout.
public enum LayoutZoneType: String, CaseIterable, Hashable, Sendable {
    case leftHalf
    case rightHalf
    case topHalf
    case bottomHalf
    case leftThird
    case centerThird
    case rightThird
    case topThird
    case middleThird
    case bottomThird
    case topLeft
    case topRight
    case bottomLeft
    case bottomRight
    case fullScreen
    
    public var displayName: String {
        switch self {
        case .leftHalf: "Left Half"
        case .rightHalf: "Right Half"
        case .topHalf: "Top Half"
        case .bottomHalf: "Bottom Half"
        case .leftThird: "Left Third"
        case .centerThird: "Center Third"
        case .rightThird: "Right Third"
        case .topThird: "Top Third"
        case .middleThird: "Middle Third"
        case .bottomThird: "Bottom Third"
        case .topLeft: "Top Left"
        case .topRight: "Top Right"
        case .bottomLeft: "Bottom Left"
        case .bottomRight: "Bottom Right"
        case .fullScreen: "Full Screen"
        }
    }

    public static func from(string: String) -> LayoutZoneType? {
        Self.init(rawValue: string)
    }
}

/// A zone on the screen in which a window of an app should be placed, including
/// an ID, what layout zone type it is, a frame, and screen index.
public struct LayoutZone: Identifiable, Hashable, Sendable {
    public let id = UUID()
    public let type: LayoutZoneType
    public let frame: CGRect
    public let screenIndex: Int

    public var displayName: String {
        type.displayName
    }
}

// MARK: - Layout Manager

/// Simplified WindowLayoutManager that only provides zone snapping functionality.
/// Persistent zone overlays and drag monitoring have been removed.
@Observable public class WindowLayoutManager {
    private var windowManager: WindowManager?

    public init() {}

    public func setWindowManager(_ windowManager: WindowManager) {
        self.windowManager = windowManager
    }

    // MARK: - Window Snapping
    
    /// Snap a window to a zone - called when window is dropped in a zone
    public func snapWindowToZone(windowInfo: WindowInfo, zone: LayoutZone) {
        guard let windowManager = windowManager else {
            DeskJigLog.warn(.window, "WindowManager not available for snapping")
            return
        }

        // CRITICAL: zone.frame is in screen coordinates (bottom-left origin)
        // but moveWindowToFrame expects window coordinates (top-left origin)
        // Convert before passing to window manager
        let screens = NSScreen.screens.map(FullScreenInfo.init(screen:))
        let targetFrameInWindowCoords = WorkspaceDisplayTopology.screenFrameInWindowCoordinates(
            zone.frame,
            from: screens
        )

        DeskJigLog.info(.window, "Snapping window '\(windowInfo.windowTitle)' to \(zone.displayName)")
        DeskJigLog.info(.window, "Zone frame (screen coords): \(zone.frame)")
        DeskJigLog.info(.window, "Target frame (window coords): \(targetFrameInWindowCoords)")
        _ = windowManager.moveWindowToFrame(windowInfo: windowInfo, targetFrame: targetFrameInWindowCoords)
    }
}
