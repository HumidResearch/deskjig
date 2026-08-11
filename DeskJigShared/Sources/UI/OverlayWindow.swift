//
//  OverlayWindow.swift
//  DeskJig
//
//  Created by Marco Freedom on 18.09.2025.
//

import AppKit

class OverlayWindow: NSWindow {
    override var canBecomeKey: Bool { !ignoresMouseEvents }
    override var canBecomeMain: Bool { !ignoresMouseEvents }

    override init(contentRect: NSRect, styleMask style: NSWindow.StyleMask, backing backingStoreType: NSWindow.BackingStoreType, defer flag: Bool) {
        super.init(contentRect: contentRect, styleMask: style, backing: backingStoreType, defer: flag)

        // Ensure the window stays above other windows but doesn't interfere
        self.level = NSWindow.Level.floating
        self.isOpaque = false
        self.backgroundColor = NSColor.clear
        self.ignoresMouseEvents = true
        self.hasShadow = false

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
