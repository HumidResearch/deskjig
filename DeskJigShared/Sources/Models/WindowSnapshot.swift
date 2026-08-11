//  WindowSnapshot.swift
//  DeskJigShared

import Foundation
import AppKit

public struct WindowSnapshot: Identifiable, Hashable, Sendable {
    public let id: Int // Use window number as stable identifier
    public let windowInfo: WindowInfo
    public let appInfo: AppInfo?
    public let screenshot: NSImage?

    public init(id: Int, windowInfo: WindowInfo, appInfo: AppInfo?, screenshot: NSImage?) {
        self.id = id
        self.windowInfo = windowInfo
        self.appInfo = appInfo
        self.screenshot = screenshot
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(id)
        hasher.combine(windowInfo)
        hasher.combine(appInfo)
    }

    public static func == (lhs: WindowSnapshot, rhs: WindowSnapshot) -> Bool {
        lhs.id == rhs.id && lhs.windowInfo == rhs.windowInfo && lhs.appInfo == rhs.appInfo
    }
}

extension WindowSnapshot: CustomDebugStringConvertible {
    public var debugDescription: String {
        var description = """
        WindowSnapshot(
            id: \(id)
            title: "\(windowInfo.windowTitle)"
            app: \(windowInfo.appName)
            bundleID: \(windowInfo.bundleIdentifier ?? "nil")
            frame: \(windowInfo.frameDescription)
            processID: \(windowInfo.processID)
            minimized: \(windowInfo.isMinimized)
            hidden: \(windowInfo.isHidden)
            windowLevel: \(windowInfo.windowLevel)
            hasScreenshot: \(screenshot != nil)
        """

        if let appInfo = appInfo {
            description += "\n    appPath: \(appInfo.path)"
            description += "\n    hasIcon: \(appInfo.icon != nil)"
        }

        description += "\n)"
        return description
    }
}
