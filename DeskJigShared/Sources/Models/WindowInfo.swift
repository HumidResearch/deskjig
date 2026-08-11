//  WindowInfo.swift
//  DeskJigShared

import Foundation
import CoreGraphics

public struct WindowInfo: Identifiable, Hashable, Sendable {
    public var id: Int // Use window number as stable identifier - mutable to update temporary IDs
    public let appName: String
    public var windowTitle: String // Made mutable for title change tracking
    public var frame: CGRect // Made mutable for position tracking
    public let processID: pid_t
    public let bundleIdentifier: String?
    public var isMinimized: Bool // Made mutable for state tracking
    public var isHidden: Bool // Made mutable for state tracking
    public var windowLevel: Int
    public var subrole: String?

    public init(
        id: Int,
        appName: String,
        windowTitle: String,
        frame: CGRect,
        processID: pid_t,
        bundleIdentifier: String?,
        isMinimized: Bool,
        isHidden: Bool,
        windowLevel: Int,
        subrole: String? = nil
    ) {
        self.id = id
        self.appName = appName
        self.windowTitle = windowTitle
        self.frame = frame
        self.processID = processID
        self.bundleIdentifier = bundleIdentifier
        self.isMinimized = isMinimized
        self.isHidden = isHidden
        self.windowLevel = windowLevel
        self.subrole = subrole
    }

    public var frameDescription: String {
        return "x: \(Int(frame.origin.x)), y: \(Int(frame.origin.y)), w: \(Int(frame.size.width)), h: \(Int(frame.size.height))"
    }
}
