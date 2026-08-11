//  RelativeWindowFrame.swift
//  DeskJigShared

import Foundation
import CoreGraphics

/// Represents a window's frame as percentages relative to its screen's visible area
/// This allows windows to be restored on different screen resolutions while respecting system UI
/// Values are rounded to 4 decimal places (0.0001 precision) to handle pixel rounding issues
/// and support accurate divisions like thirds (33.33%), quarters (25%), etc.
/// Values are always clamped to 0.0-1.0 to keep windows within the visible bounds
public struct RelativeWindowFrame: Codable, Hashable, Sendable {
    /// X position as percentage of screen width (0.0000 to 1.0000, where 0.0000 = left edge, 1.0000 = right edge)
    public let xPercent: Double

    /// Y position as percentage of screen height (0.0000 to 1.0000, where 0.0000 = top of visible area, 1.0000 = bottom)
    public let yPercent: Double

    /// Width as percentage of screen width (0.0000 to 1.0000)
    public let widthPercent: Double

    /// Height as percentage of screen height (0.0000 to 1.0000)
    public let heightPercent: Double

    public init(xPercent: Double, yPercent: Double, widthPercent: Double, heightPercent: Double) {
        // Round to 4 decimal places (0.0001 precision) to handle pixel rounding issues
        // while preserving precision for common divisions (thirds, quarters, etc.)
        // Example: 33.333% → 0.3333, 99.9993% → 1.0000, 50.0002% → 0.5000
        let roundedX = round(xPercent * 10000) / 10000
        let roundedY = round(yPercent * 10000) / 10000
        let roundedW = round(widthPercent * 10000) / 10000
        let roundedH = round(heightPercent * 10000) / 10000

        // Clamp values between 0.0 and 1.0 to ensure windows stay within visible screen bounds
        // This prevents windows from extending into system UI areas (dock, menu bar)
        self.xPercent = max(0.0, min(1.0, roundedX))
        self.yPercent = max(0.0, min(1.0, roundedY))
        self.widthPercent = max(0.0, min(1.0, roundedW))
        self.heightPercent = max(0.0, min(1.0, roundedH))
    }

    /// Human-readable description showing percentages with 2 decimal places
    public var description: String {
        let xPct = String(format: "%.2f", xPercent * 100)
        let yPct = String(format: "%.2f", yPercent * 100)
        let wPct = String(format: "%.2f", widthPercent * 100)
        let hPct = String(format: "%.2f", heightPercent * 100)
        return "x:\(xPct)% y:\(yPct)% w:\(wPct)% h:\(hPct)%"
    }
}

/// Utility class for converting between absolute and relative window frames
public class WindowFrameConverter {

    // MARK: - Absolute to Relative Conversion

    /// Convert absolute window frame to relative percentages based on screen's visible area
    /// - Parameters:
    ///   - windowFrame: The absolute window frame in screen coordinates
    ///   - screenVisibleFrame: The screen's visible frame (excluding menu bar and dock)
    /// - Returns: RelativeWindowFrame with percentage-based positioning
    public static func toRelative(windowFrame: CGRect, screenFrame: CGRect) -> RelativeWindowFrame {
        // Calculate relative position within the screen's visible area
        let relativeX = windowFrame.origin.x - screenFrame.origin.x
        let relativeY = windowFrame.origin.y - screenFrame.origin.y

        // Convert to percentages based on visible frame
        let xPercent = screenFrame.width > 0 ? Double(relativeX / screenFrame.width) : 0.0
        let yPercent = screenFrame.height > 0 ? Double(relativeY / screenFrame.height) : 0.0
        let widthPercent = screenFrame.width > 0 ? Double(windowFrame.width / screenFrame.width) : 0.0
        let heightPercent = screenFrame.height > 0 ? Double(windowFrame.height / screenFrame.height) : 0.0

        return RelativeWindowFrame(
            xPercent: xPercent,
            yPercent: yPercent,
            widthPercent: widthPercent,
            heightPercent: heightPercent
        )
    }

    /// Convert WindowInfo to RelativeWindowFrame using FullScreenInfo
    /// **Note:** For multi-monitor setups, this requires access to all screens to calculate global maxY.
    /// Consider using the base method with explicit globalMaxY for better control.
    /// - Parameters:
    ///   - window: The WindowInfo containing absolute frame
    ///   - screen: The FullScreenInfo of the screen the window is on
    ///   - allScreens: Array of all available FullScreenInfo for global coordinate calculation
    /// - Returns: RelativeWindowFrame with percentage-based positioning
    public static func toRelative(window: WindowInfo, screen: FullScreenInfo, allScreens: [FullScreenInfo]) -> RelativeWindowFrame {
        let globalMaxY = WorkspaceDisplayTopology.windowCoordinateAnchorY(from: allScreens)
        return toRelative(windowFrame: window.frame, screenFrame: screen.visibleFrameInWindowCoordinates(globalMaxY: globalMaxY))
    }

    /// Convert WindowInfo to RelativeWindowFrame using WorkspaceScreen
    /// **Note:** For multi-monitor setups, this requires access to all screens to calculate global maxY.
    /// Consider using the base method with explicit globalMaxY for better control.
    /// - Parameters:
    ///   - window: The WindowInfo containing absolute frame
    ///   - screen: The WorkspaceScreen of the screen the window is on
    ///   - allScreens: Array of all available WorkspaceScreen for global coordinate calculation
    /// - Returns: RelativeWindowFrame with percentage-based positioning
    public static func toRelative(window: WindowInfo, screen: WorkspaceScreen, allScreens: [WorkspaceScreen]) -> RelativeWindowFrame {
        let globalMaxY = WorkspaceScreen.calculateWindowCoordinateAnchorY(from: allScreens)
        return toRelative(windowFrame: window.frame, screenFrame: screen.visibleFrameInWindowCoordinates(globalMaxY: globalMaxY))
    }

    // MARK: - Relative to Absolute Conversion

    /// Convert relative frame to absolute coordinates based on screen's visible area
    /// - Parameters:
    ///   - relativeFrame: The RelativeWindowFrame with percentage-based positioning
    ///   - screenFrame: The target screen's visible frame (excluding menu bar and dock)
    /// - Returns: Absolute CGRect in screen coordinates, clamped to fit within screen bounds
    public static func toAbsolute(relativeFrame: RelativeWindowFrame, screenFrame: CGRect) -> CGRect {
        // Calculate absolute position and size based on visible frame
        let absoluteX = screenFrame.origin.x + (CGFloat(relativeFrame.xPercent) * screenFrame.width)
        let absoluteY = screenFrame.origin.y + (CGFloat(relativeFrame.yPercent) * screenFrame.height)
        let absoluteWidth = CGFloat(relativeFrame.widthPercent) * screenFrame.width
        let absoluteHeight = CGFloat(relativeFrame.heightPercent) * screenFrame.height

        // Validate and clamp dimensions to ensure window fits within screen bounds
        // Priority: Position is more important than size, so we preserve X/Y and clamp width/height
        
        // Calculate remaining space from position to screen edge
        let remainingWidth = screenFrame.maxX - absoluteX
        let remainingHeight = screenFrame.maxY - absoluteY
        
        // Clamp width and height to fit within remaining space
        let clampedWidth = min(absoluteWidth, max(remainingWidth, 400.0))  // Min 400px for usability
        let clampedHeight = min(absoluteHeight, max(remainingHeight, 300.0))  // Min 300px for usability
        
        // Log warning if clamping occurred (indicates invalid saved workspace data)
        // Use tolerance-based comparison to avoid false positives from floating-point precision
        // 1.0 pixel tolerance to avoid warnings for minor rounding differences
        let epsilon: CGFloat = 1.0
        let widthClamped = clampedWidth < absoluteWidth - epsilon
        let heightClamped = clampedHeight < absoluteHeight - epsilon

        if widthClamped || heightClamped {
            DeskJigLog.warn(.restorationPositioning, "Window frame clamped to fit screen bounds:")
            DeskJigLog.warn(
                .restorationPositioning,
                "   Original: (\(Int(absoluteX)), \(Int(absoluteY))) \(Int(absoluteWidth))x\(Int(absoluteHeight))"
            )
            DeskJigLog.warn(
                .restorationPositioning,
                "   Clamped:  (\(Int(absoluteX)), \(Int(absoluteY))) \(Int(clampedWidth))x\(Int(clampedHeight))"
            )
            DeskJigLog.warn(
                .restorationPositioning,
                "   Remaining space: width=\(Int(remainingWidth)) height=\(Int(remainingHeight))"
            )
            DeskJigLog.warn(
                .restorationPositioning,
                "   Relative: x:\(String(format: "%.1f", relativeFrame.xPercent * 100))% y:\(String(format: "%.1f", relativeFrame.yPercent * 100))% w:\(String(format: "%.1f", relativeFrame.widthPercent * 100))% h:\(String(format: "%.1f", relativeFrame.heightPercent * 100))%"
            )
        }

        return CGRect(
            x: absoluteX,
            y: absoluteY,
            width: clampedWidth,
            height: clampedHeight
        )
    }

    /// Convert relative frame to absolute coordinates using FullScreenInfo
    /// **Note:** For multi-monitor setups, this requires access to all screens to calculate global maxY.
    /// Consider using `restoreToAbsolute` for automatic screen matching.
    /// - Parameters:
    ///   - relativeFrame: The RelativeWindowFrame with percentage-based positioning
    ///   - screen: The target FullScreenInfo
    ///   - allScreens: Array of all available FullScreenInfo for global coordinate calculation
    /// - Returns: Absolute CGRect in window coordinates (top-left origin)
    public static func toAbsolute(relativeFrame: RelativeWindowFrame, screen: FullScreenInfo, allScreens: [FullScreenInfo]) -> CGRect {
        let globalMaxY = WorkspaceDisplayTopology.windowCoordinateAnchorY(from: allScreens)
        return toAbsolute(relativeFrame: relativeFrame, screenFrame: screen.visibleFrameInWindowCoordinates(globalMaxY: globalMaxY))
    }

    /// Convert relative frame to absolute coordinates using WorkspaceScreen
    /// **Note:** For multi-monitor setups, this requires access to all screens to calculate global maxY.
    /// Consider using `restoreToAbsolute` for automatic screen matching.
    /// - Parameters:
    ///   - relativeFrame: The RelativeWindowFrame with percentage-based positioning
    ///   - screen: The target WorkspaceScreen
    ///   - allScreens: Array of all available WorkspaceScreen for global coordinate calculation
    /// - Returns: Absolute CGRect in window coordinates (top-left origin)
    public static func toAbsolute(relativeFrame: RelativeWindowFrame, screen: WorkspaceScreen, allScreens: [WorkspaceScreen]) -> CGRect {
        let globalMaxY = WorkspaceScreen.calculateWindowCoordinateAnchorY(from: allScreens)
        return toAbsolute(relativeFrame: relativeFrame, screenFrame: screen.visibleFrameInWindowCoordinates(globalMaxY: globalMaxY))
    }

    // MARK: - Screen Matching Utilities

    /// Find best matching screen for a saved WorkspaceScreen in current screen setup
    /// - Parameters:
    ///   - savedScreen: The WorkspaceScreen from a saved workspace
    ///   - currentScreens: Array of current FullScreenInfo screens
    /// - Returns: Best matching FullScreenInfo, or nil only when currentScreens is empty.
    ///   Strategies 1-4 guarantee a match for non-empty input; strategy 4's origin/size proximity scoring terminates the search.
    public static func findMatchingScreen(
        savedScreen: WorkspaceScreen,
        currentScreens: [FullScreenInfo]
    ) -> FullScreenInfo? {
        // Strategy 1: Match by display ID (best match)
        if let match = currentScreens.first(where: { $0.displayID == savedScreen.displayID }) {
            return match
        }

        // Strategy 2: Match by persistent hardware fingerprint when available
        if let fingerprint = savedScreen.displayFingerprint,
           let match = currentScreens.first(where: { fingerprint.matches($0.displayFingerprint) }) {
            return match
        }

        // Strategy 3: Match by primary screen status
        if savedScreen.isPrimary,
           let primary = currentScreens.first(where: { $0.isPrimary }) {
#if DEBUG
            DeskJigLog.debug(
                .restorationPositioning,
                "Screen: Display \(savedScreen.displayID)->\(primary.displayID) (fallback by primary flag)"
            )
#endif
            return primary
        }

        // Strategy 4: Match by relative position/origin similarity (preserves layout ordering)
        let positionMatches = currentScreens.map { currentScreen -> (screen: FullScreenInfo, score: CGFloat) in
            let dx = abs(currentScreen.frame.origin.x - savedScreen.frame.origin.x)
            let dy = abs(currentScreen.frame.origin.y - savedScreen.frame.origin.y)
            let widthDiff = abs(currentScreen.frame.width - savedScreen.frame.width)
            let heightDiff = abs(currentScreen.frame.height - savedScreen.frame.height)
            let score = dx + dy + (widthDiff * 0.1) + (heightDiff * 0.1)
            return (currentScreen, score)
        }
        if let bestPositionMatch = positionMatches.min(by: { $0.score < $1.score }) {
#if DEBUG
            DeskJigLog.debug(
                .restorationPositioning,
                "Screen: Display \(savedScreen.displayID)->\(bestPositionMatch.screen.displayID) (fallback by origin, displayID mismatch)"
            )
#endif
            return bestPositionMatch.screen
        }

        // currentScreens is empty; no screen to match
        return nil
    }

    // MARK: - Convenience Methods

    /// Convert a window to relative frame, automatically finding its screen
    /// - Parameters:
    ///   - window: The WindowInfo to convert
    ///   - screens: Available screens to match against
    ///   - displayManager: DisplayManager for finding the best screen
    /// - Returns: Tuple of (RelativeWindowFrame, screenIndex) or nil if no screen found
    public static func toRelativeWithScreenMatch(
        window: WindowInfo,
        screens: [FullScreenInfo],
        displayManager: DisplayManager
    ) -> (relativeFrame: RelativeWindowFrame, screenIndex: Int)? {
        guard let screenInfo = displayManager.getBestScreen(for: window.frame),
              let screenIndex = screens.firstIndex(where: { $0.displayID == screenInfo.displayID }) else {
            return nil
        }

        let relativeFrame = toRelative(window: window, screen: screenInfo, allScreens: screens)
        return (relativeFrame, screenIndex)
    }

    /// Restore window to absolute frame with automatic screen matching
    /// - Parameters:
    ///   - relativeFrame: The RelativeWindowFrame to restore
    ///   - savedScreen: The WorkspaceScreen the window was originally on
    ///   - currentScreens: Current available screens
    /// - Returns: Absolute CGRect for the window on the best matching screen
    public static func restoreToAbsolute(
        relativeFrame: RelativeWindowFrame,
        savedScreen: WorkspaceScreen,
        currentScreens: [FullScreenInfo]
    ) -> CGRect? {
        guard let matchingScreen = findMatchingScreen(
            savedScreen: savedScreen,
            currentScreens: currentScreens
        ) else {
            return nil
        }

        let globalMaxY = WorkspaceDisplayTopology.windowCoordinateAnchorY(from: currentScreens)
        let screenFrame = matchingScreen.visibleFrameInWindowCoordinates(globalMaxY: globalMaxY)

        return toAbsolute(relativeFrame: relativeFrame, screenFrame: screenFrame)
    }
}
