//
//  NotificationPresenterWindow.swift
//  DeskJig
//
//  Created by Jake Sax on 11/11/25.
//

import Foundation
import SwiftUI

final class NotificationPresenterWindow: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
    
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
        self.level = .floating + 1
        self.isOpaque = false
        self.backgroundColor = .clear
        self.hasShadow = false
        self.isFloatingPanel = true
        self.hidesOnDeactivate = false
        self.becomesKeyOnlyIfNeeded = true
        self.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
    }
    
}
