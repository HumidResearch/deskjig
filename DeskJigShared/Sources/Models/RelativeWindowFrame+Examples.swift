//  RelativeWindowFrame+Examples.swift
//  DeskJigShared

import Foundation
import CoreGraphics

#if DEBUG
extension WindowFrameConverter {

    /// Example: Converting a window on left half of screen to relative frame
    /// This demonstrates how visibleFrame (excluding menu bar) is used for calculations
    static func exampleLeftHalfWindow() {
        // Screen full frame: 1920x1080 at origin (0, 0)
        // Menu bar: 25 pixels at top
        // Visible frame: (0, 25, 1920, 1055)
        let screenVisibleFrame = CGRect(x: 0, y: 25, width: 1920, height: 1055)

        // Window: Left half of visible screen area (full height excluding menu bar)
        let windowFrame = CGRect(x: 0, y: 25, width: 960, height: 1055)

        // Convert to relative (using visible frame)
        let relativeFrame = WindowFrameConverter.toRelative(
            windowFrame: windowFrame,
            screenFrame: screenVisibleFrame
        )

        DeskJigLog.debug(.workspace, "Left half window:")
        DeskJigLog.debug(.workspace, "  Absolute: \(windowFrame)")
        DeskJigLog.debug(.workspace, "  Relative: \(relativeFrame.description)")
        // Output: x:0% y:0% w:50% h:100%
        // Note: Height is 100% of VISIBLE area, menu bar correctly excluded

        // Now restore on a different resolution screen (2560x1440)
        // New menu bar: 28 pixels at top
        // New visible frame: (0, 28, 2560, 1412)
        let newScreenVisibleFrame = CGRect(x: 0, y: 28, width: 2560, height: 1412)
        let restoredFrame = WindowFrameConverter.toAbsolute(
            relativeFrame: relativeFrame,
            screenFrame: newScreenVisibleFrame
        )

        DeskJigLog.debug(.workspace, "  Restored on 2560x1440: \(restoredFrame)")
        // Output: x:0 y:28 w:1280 h:1412 (still left half, menu bar respected!)
    }

    /// Example: Window at center of visible screen area
    static func exampleCenterWindow() {
        // Screen visible frame: (0, 25, 1920, 1055) - menu bar at top
        let screenVisibleFrame = CGRect(x: 0, y: 25, width: 1920, height: 1055)

        // Window: 800x600 centered in visible area
        // Center X: 0 + (1920 - 800) / 2 = 560
        // Center Y: 25 + (1055 - 600) / 2 = 252.5
        let windowFrame = CGRect(x: 560, y: 252.5, width: 800, height: 600)

        let relativeFrame = WindowFrameConverter.toRelative(
            windowFrame: windowFrame,
            screenFrame: screenVisibleFrame
        )

        DeskJigLog.debug(.workspace, "Centered window:")
        DeskJigLog.debug(.workspace, "  Absolute: \(windowFrame)")
        DeskJigLog.debug(.workspace, "  Relative: \(relativeFrame.description)")
        // Output: x:29% y:21% w:41% h:56%

        // Restore on ultra-wide screen (3440x1440, menu bar 30px)
        let ultraWideVisible = CGRect(x: 0, y: 30, width: 3440, height: 1410)
        let restoredFrame = WindowFrameConverter.toAbsolute(
            relativeFrame: relativeFrame,
            screenFrame: ultraWideVisible
        )

        DeskJigLog.debug(.workspace, "  Restored on ultra-wide: \(restoredFrame)")
        // Proportions maintained relative to visible screen area
    }

    /// Example: Multi-monitor setup with menu bars
    static func exampleMultiMonitor() {
        // Primary screen (laptop): Full 2880x1800 at (0, 0), menu bar 39px
        _ = CGRect(x: 0, y: 39, width: 2880, height: 1761) // primaryVisible

        // External monitor: Full 2560x1440 at (2880, 0), menu bar 25px
        // Note: In macOS, only primary screen has menu bar, but we track both
        let externalVisible = CGRect(x: 2880, y: 0, width: 2560, height: 1440)

        // Window on external monitor, top-right quarter (in visible area)
        let windowOnExternal = CGRect(x: 4160, y: 0, width: 1280, height: 720)

        // Convert relative to external monitor (using its visible frame)
        let relativeFrame = WindowFrameConverter.toRelative(
            windowFrame: windowOnExternal,
            screenFrame: externalVisible
        )

        DeskJigLog.debug(.workspace, "Window on external monitor:")
        DeskJigLog.debug(.workspace, "  Absolute: \(windowOnExternal)")
        DeskJigLog.debug(.workspace, "  Relative to external: \(relativeFrame.description)")
        // Output: x:50% y:0% w:50% h:50% (top-right quarter)

        // Now user switches to single 4K monitor (3840x2160), menu bar 32px
        let newScreenVisible = CGRect(x: 0, y: 32, width: 3840, height: 2128)
        let restoredFrame = WindowFrameConverter.toAbsolute(
            relativeFrame: relativeFrame,
            screenFrame: newScreenVisible
        )

        DeskJigLog.debug(.workspace, "  Restored on 4K: \(restoredFrame)")
        // Output: x:1920 y:32 w:1920 h:1064 (still top-right quarter!)
    }

    /// Example: Workspace restoration with screen matching
    static func exampleWorkspaceRestoration() {
        // Original setup when workspace was saved
        // Dell U2720Q: 4K monitor with 28px menu bar
        let savedScreen = WorkspaceScreen(
            displayID: 123,
            name: "Dell U2720Q",
            resolution: CGSize(width: 3840, height: 2160),
            frame: CGRect(x: 0, y: 0, width: 3840, height: 2160),
            visibleFrame: CGRect(x: 0, y: 28, width: 3840, height: 2132),
            isPrimary: true
        )

        // Window was on right half of visible screen area
        let relativeFrame = RelativeWindowFrame(
            xPercent: 0.5,
            yPercent: 0.0,
            widthPercent: 0.5,
            heightPercent: 1.0
        )

        // Current setup - different monitor with different resolution
        let currentScreens = [
            FullScreenInfo(screen: NSScreen.main!) // Assume 2560x1440, 25px menu bar
        ]

        // Find matching screen and restore
        if let restoredFrame = WindowFrameConverter.restoreToAbsolute(
            relativeFrame: relativeFrame,
            savedScreen: savedScreen,
            currentScreens: currentScreens
        ) {
            DeskJigLog.debug(.workspace, "Workspace restoration:")
            DeskJigLog.debug(.workspace, "  Original screen: 3840x2160 (visible: 3840x2132)")
            DeskJigLog.debug(.workspace, "  Current screen: \(currentScreens[0].resolution)")
            DeskJigLog.debug(.workspace, "  Current visible: \(currentScreens[0].visibleFrame)")
            DeskJigLog.debug(.workspace, "  Window relative: \(relativeFrame.description)")
            DeskJigLog.debug(.workspace, "  Restored frame: \(restoredFrame)")
            // Window maintains right-half position on new screen's visible area
        }
    }

    /// Example: Handling screen configuration changes with menu bars
    static func exampleScreenConfigChange() {
        DeskJigLog.debug(.workspace, "\n=== Screen Configuration Change Example ===\n")

        // Scenario: User has 3 monitors at work, 1 at home

        // Work setup with realistic visible frames
        let workScreens = [
            WorkspaceScreen(
                displayID: 1,
                name: "Built-in Retina",
                resolution: CGSize(width: 2880, height: 1800),
                frame: CGRect(x: 0, y: 0, width: 2880, height: 1800),
                visibleFrame: CGRect(x: 0, y: 39, width: 2880, height: 1761), // Menu bar on primary
                isPrimary: true
            ),
            WorkspaceScreen(
                displayID: 2,
                name: "Left Monitor",
                resolution: CGSize(width: 2560, height: 1440),
                frame: CGRect(x: -2560, y: 0, width: 2560, height: 1440),
                visibleFrame: CGRect(x: -2560, y: 0, width: 2560, height: 1440), // No menu bar on secondary
                isPrimary: false
            ),
            WorkspaceScreen(
                displayID: 3,
                name: "Right Monitor",
                resolution: CGSize(width: 2560, height: 1440),
                frame: CGRect(x: 2880, y: 0, width: 2560, height: 1440),
                visibleFrame: CGRect(x: 2880, y: 0, width: 2560, height: 1440), // No menu bar on secondary
                isPrimary: false
            )
        ]

        // Windows saved with relative positioning (based on visible frames)
        _ = RelativeWindowFrame(xPercent: 0.0, yPercent: 0.0, widthPercent: 1.0, heightPercent: 1.0) // windowOnLeft
        _ = RelativeWindowFrame(xPercent: 0.25, yPercent: 0.25, widthPercent: 0.5, heightPercent: 0.5) // windowOnBuiltIn
        _ = RelativeWindowFrame(xPercent: 0.0, yPercent: 0.0, widthPercent: 0.5, heightPercent: 1.0) // windowOnRight

        DeskJigLog.debug(.workspace, "Work setup (3 monitors):")
        DeskJigLog.debug(.workspace, "  Left monitor: \(workScreens[1].name) - \(workScreens[1].visibleFrame)")
        DeskJigLog.debug(.workspace, "  Built-in: \(workScreens[0].name) - \(workScreens[0].visibleFrame)")
        DeskJigLog.debug(.workspace, "  Right monitor: \(workScreens[2].name) - \(workScreens[2].visibleFrame)")

        // Home setup - only built-in display
        let homeScreen = FullScreenInfo(screen: NSScreen.main!)

        DeskJigLog.debug(.workspace, "\nHome setup (1 monitor):")
        DeskJigLog.debug(.workspace, "  \(homeScreen.name) - \(homeScreen.resolution)")
        DeskJigLog.debug(.workspace, "  Visible: \(homeScreen.visibleFrame)")

        // Strategy: Map all windows to the single available screen
        DeskJigLog.debug(.workspace, "\nWindow restoration strategy:")
        DeskJigLog.debug(.workspace, "  - Window from left monitor (100% visible) → Restored to built-in visible area")
        DeskJigLog.debug(.workspace, "  - Window from built-in (25%,25%,50%,50%) → Same relative position in visible area")
        DeskJigLog.debug(.workspace, "  - Window from right monitor (left 50%) → Restored respecting menu bar")
        DeskJigLog.debug(.workspace, "\nAll calculations respect menu bar boundaries!")
    }

    /// Example: Full-height window correctly handles menu bar
    static func exampleFullHeightWindow() {
        DeskJigLog.debug(.workspace, "\n=== Full-Height Window Example ===\n")

        // Screen configuration
        let fullFrame = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let visibleFrame = CGRect(x: 0, y: 25, width: 1920, height: 1055) // 25px menu bar

        // Window that fills entire visible height (excluding menu bar)
        let windowFrame = CGRect(x: 0, y: 25, width: 960, height: 1055)

        let relativeFrame = WindowFrameConverter.toRelative(
            windowFrame: windowFrame,
            screenFrame: visibleFrame
        )

        DeskJigLog.debug(.workspace, "Full-height window (left half):")
        DeskJigLog.debug(.workspace, "  Screen full frame: \(fullFrame)")
        DeskJigLog.debug(.workspace, "  Screen visible frame: \(visibleFrame)")
        DeskJigLog.debug(.workspace, "  Window frame: \(windowFrame)")
        DeskJigLog.debug(.workspace, "  Relative: \(relativeFrame.description)")
        DeskJigLog.debug(.workspace, "  → Height is 100% of VISIBLE area (correct!)")

        // Restore on different screen
        let newFullFrame = CGRect(x: 0, y: 0, width: 2560, height: 1440)
        let newVisibleFrame = CGRect(x: 0, y: 28, width: 2560, height: 1412) // 28px menu bar

        let restoredFrame = WindowFrameConverter.toAbsolute(
            relativeFrame: relativeFrame,
            screenFrame: newVisibleFrame
        )

        DeskJigLog.debug(.workspace, "\nRestored on larger screen:")
        DeskJigLog.debug(.workspace, "  New screen full frame: \(newFullFrame)")
        DeskJigLog.debug(.workspace, "  New screen visible frame: \(newVisibleFrame)")
        DeskJigLog.debug(.workspace, "  Restored window frame: \(restoredFrame)")
        DeskJigLog.debug(.workspace, "  → Still 100% of visible height, menu bar respected!")
    }
}
#endif
