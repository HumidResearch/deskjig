//  FullScreenInfo.swift
//  DeskJigShared

import Foundation

// MARK: - Models
public struct FullScreenInfo: Identifiable, @unchecked Sendable {
    public let id = UUID()
    public let displayID: Int
    public let screen: NSScreen? // Optional to support mock screens
    public let name: String
    public let resolution: CGSize
    public let frame: NSRect
    public let visibleFrame: NSRect // Frame excluding menu bar and dock
    public let isPrimary: Bool
    public let vendorID: Int
    public let modelNumber: Int
    public let serialNumber: Int?
    public let displayUUID: String?

    /// Initialize from real NSScreen (production)
    public init(screen: NSScreen) {
        self.screen = screen
        self.frame = screen.frame
        self.resolution = CGSize(
            width: screen.frame.width * screen.backingScaleFactor,
            height: screen.frame.height * screen.backingScaleFactor
        )

        // Use CGMainDisplayID() for reliable primary detection across all contexts
        // NSScreen.main returns the screen with the key window, which is wrong in CLI
        // contexts where there is no key window.
        if let displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID {
            self.isPrimary = displayID == CGMainDisplayID()
            self.name = FullScreenInfo.getDisplayName(for: displayID) ?? "Display \(displayID)"
            self.displayID = Int(displayID)
            self.vendorID = Int(CGDisplayVendorNumber(displayID))
            self.modelNumber = Int(CGDisplayModelNumber(displayID))
            let serial = Int(CGDisplaySerialNumber(displayID))
            self.serialNumber = serial > 0 ? serial : nil
            if let cfUUID = CGDisplayCreateUUIDFromDisplayID(displayID)?.takeRetainedValue() {
                self.displayUUID = CFUUIDCreateString(nil, cfUUID) as String
            } else {
                self.displayUUID = nil
            }
        } else {
            // Fallback: use NSScreen.main (may be incorrect in CLI)
            self.isPrimary = screen == NSScreen.main
            self.name = "Unknown Display"
            self.displayID = -1
            self.vendorID = 0
            self.modelNumber = 0
            self.serialNumber = nil
            self.displayUUID = nil
        }

        // Trust AppKit's visible frame directly. Forcing a synthetic 30px inset on
        // non-primary displays can produce incorrect restore targets on setups where
        // the display truly has no reserved top inset.
        self.visibleFrame = screen.visibleFrame
    }
    
    /// Initialize from ScreenProvider (supports both real and mock screens)
    public init(screenProvider: ScreenProvider) {
        // If it's an NSScreenProvider, store the actual NSScreen
        if let nsProvider = screenProvider as? NSScreenProvider {
            self.screen = nsProvider.nsScreen
        } else {
            self.screen = nil
        }
        
        self.frame = screenProvider.frame
        self.isPrimary = screenProvider.isPrimary
        self.resolution = CGSize(
            width: screenProvider.frame.width * screenProvider.backingScaleFactor,
            height: screenProvider.frame.height * screenProvider.backingScaleFactor
        )
        
        self.visibleFrame = screenProvider.visibleFrame
        
        self.name = screenProvider.displayName
        self.displayID = screenProvider.displayID
        self.vendorID = screenProvider.vendorID
        self.modelNumber = screenProvider.modelNumber
        self.serialNumber = screenProvider.serialNumber
        self.displayUUID = screenProvider.displayUUID
    }

    public var displayFingerprint: DisplayFingerprint {
        DisplayFingerprint(screen: self)
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
    /// - Parameter globalMaxY: The maximum Y coordinate across all screens (from DisplayManager.globalMaxY)
    /// - Returns: Visible frame in global window coordinates (top-left origin)
    public func visibleFrameInWindowCoordinates(globalMaxY: CGFloat) -> CGRect {
        WorkspaceDisplayTopology.screenFrameInWindowCoordinates(
            visibleFrame,
            anchorY: globalMaxY
        )
    }

    static func getDisplayName(for displayID: CGDirectDisplayID) -> String? {
        // Try to get the NSScreen for this display ID to use localizedName
        if let screen = NSScreen.screens.first(where: {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID) == displayID
        }) {
            return screen.localizedName
        }

        // Fallback: use vendor ID to determine generic name
        if CoreGraphics.CGDisplayCopyDisplayMode(displayID) != nil {
            let vendorID = CGDisplayVendorNumber(displayID)
            if vendorID == 0x610 { // Apple vendor ID
                return "Built-in Display"
            } else if vendorID != 0 {
                return "External Display"
            }
        }

        return "Display \(displayID)"
    }
}
