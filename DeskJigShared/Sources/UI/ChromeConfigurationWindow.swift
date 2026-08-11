//
//  ChromeConfigurationWindow.swift
//  DeskJig
//
//  Created by Marco Freedom on 28.10.2025.
//

import AppKit

/// A separate window for displaying interactive Chrome configuration UI
class ChromeConfigurationWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override init(contentRect: NSRect, styleMask style: NSWindow.StyleMask, backing backingStoreType: NSWindow.BackingStoreType, defer flag: Bool) {
        super.init(contentRect: contentRect, styleMask: style, backing: backingStoreType, defer: flag)

        // This window is interactive and sits above the overlay
        self.level = NSWindow.Level(rawValue: Int(NSWindow.Level.floating.rawValue) + 1)
        self.isOpaque = false
        self.backgroundColor = NSColor.clear
        self.ignoresMouseEvents = false  // This window accepts clicks
        self.hasShadow = true
        self.styleMask.insert(.fullSizeContentView)

        // Important: Disable automatic window restoration
        self.isRestorable = false

        // Ensure no delegate is set to avoid retain cycles
        self.delegate = nil
    }

    deinit {
        // Clean up any remaining references
        self.contentView = nil
        self.delegate = nil
    }
}
