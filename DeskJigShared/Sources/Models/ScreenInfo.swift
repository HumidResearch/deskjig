//  ScreenInfo.swift
//  DeskJigShared

import Foundation

public struct ScreenInfo {
    
    /// Starting from 0. Add 1 for user display purposes.
    public let screenNumber: Int
    public let screen: NSScreen
    public let applicationIcons: [NSImage]
    public let applicationCount: Int
    public let windowSnapshots: [WindowSnapshot]
}
