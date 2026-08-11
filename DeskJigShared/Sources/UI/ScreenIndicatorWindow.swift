//
//  ScreenIndicatorWindow.swift
//  DeskJig
//
//  Created by Marco Freedom on 18.09.2025.
//

import Foundation

public class ScreenIndicatorWindow: NSWindow {
    override public var canBecomeKey: Bool { false }
    override public var canBecomeMain: Bool { false }

    override init(
        contentRect: NSRect,
        styleMask style: NSWindow.StyleMask,
        backing backingStoreType: NSWindow.BackingStoreType,
        defer flag: Bool
    ) {
        super.init(
            contentRect: contentRect,
            styleMask: style,
            backing: backingStoreType,
            defer: flag
        )

        self.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 1)
        self.isOpaque = false
        self.backgroundColor = NSColor.clear
        self.ignoresMouseEvents = false
        self.hasShadow = true
        self.isRestorable = false
        self.delegate = nil
        self.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
    }

    deinit {
        self.contentView = nil
        self.delegate = nil
    }
}
