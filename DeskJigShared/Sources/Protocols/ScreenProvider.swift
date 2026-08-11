//
//  ScreenProvider.swift
//  DeskJigShared
//
//  Protocol abstraction for NSScreen to enable testing
//

import Foundation
import CoreGraphics

/// Protocol that abstracts NSScreen functionality for testing
public protocol ScreenProvider {
    var frame: CGRect { get }
    var visibleFrame: CGRect { get }
    var backingScaleFactor: CGFloat { get }
    var isPrimary: Bool { get }
    var displayID: Int { get }
    var displayName: String { get }
    var vendorID: Int { get }
    var modelNumber: Int { get }
    var serialNumber: Int? { get }
    var displayUUID: String? { get }
}

public extension ScreenProvider {
    var vendorID: Int { 0 }
    var modelNumber: Int { 0 }
    var serialNumber: Int? { nil }
    var displayUUID: String? { nil }
}

/// Production wrapper for NSScreen
public class NSScreenProvider: ScreenProvider {
    private let screen: NSScreen
    
    public init(screen: NSScreen) {
        self.screen = screen
    }
    
    public var frame: CGRect {
        return screen.frame
    }
    
    public var visibleFrame: CGRect {
        return screen.visibleFrame
    }
    
    public var backingScaleFactor: CGFloat {
        return screen.backingScaleFactor
    }
    
    public var isPrimary: Bool {
        return screen == NSScreen.main
    }
    
    public var displayID: Int {
        if let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID {
            return Int(id)
        }
        return -1
    }
    
    public var displayName: String {
        if let displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID {
            return FullScreenInfo.getDisplayName(for: displayID) ?? "Display \(displayID)"
        }
        return "Unknown Display"
    }

    public var vendorID: Int {
        guard let displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else {
            return 0
        }
        return Int(CGDisplayVendorNumber(displayID))
    }

    public var modelNumber: Int {
        guard let displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else {
            return 0
        }
        return Int(CGDisplayModelNumber(displayID))
    }

    public var serialNumber: Int? {
        guard let displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else {
            return nil
        }
        let serial = Int(CGDisplaySerialNumber(displayID))
        return serial > 0 ? serial : nil
    }

    public var displayUUID: String? {
        guard let displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID,
              let cfUUID = CGDisplayCreateUUIDFromDisplayID(displayID)?.takeRetainedValue() else {
            return nil
        }
        return CFUUIDCreateString(nil, cfUUID) as String
    }
    
    /// Get the actual NSScreen for backwards compatibility
    public var nsScreen: NSScreen {
        return screen
    }
}

/// Mock screen provider for testing
public class MockScreenProvider: ScreenProvider {
    public let frame: CGRect
    public let visibleFrame: CGRect
    public let backingScaleFactor: CGFloat
    public let isPrimary: Bool
    public let displayID: Int
    public let displayName: String
    public let vendorID: Int
    public let modelNumber: Int
    public let serialNumber: Int?
    public let displayUUID: String?
    
    public init(
        frame: CGRect,
        visibleFrame: CGRect,
        backingScaleFactor: CGFloat = 1.0,
        isPrimary: Bool = true,
        displayID: Int = 1,
        displayName: String = "Mock Display",
        vendorID: Int = 0,
        modelNumber: Int = 0,
        serialNumber: Int? = nil,
        displayUUID: String? = nil
    ) {
        self.frame = frame
        self.visibleFrame = visibleFrame
        self.backingScaleFactor = backingScaleFactor
        self.isPrimary = isPrimary
        self.displayID = displayID
        self.displayName = displayName
        self.vendorID = vendorID
        self.modelNumber = modelNumber
        self.serialNumber = serialNumber
        self.displayUUID = displayUUID
    }
}
