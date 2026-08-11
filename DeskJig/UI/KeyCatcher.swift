//  KeyCatcher.swift
//  DeskJig
//
//  Created by Marco Freedom on 05.09.2025.
//

import SwiftUI
import AppKit

/// Captures key events (Return, ESC, ⌘1…⌘9, arrows) reliably.
struct KeyCatcher: NSViewRepresentable {
    var onKeyDown: (NSEvent) -> Bool
    func makeNSView(context: Context) -> KeyCatcherView {
        let v = KeyCatcherView()
        v.onKeyDown = onKeyDown
        // Ensure the view can receive keyboard focus but delay it to avoid conflicts
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            v.window?.makeFirstResponder(v)
        }
        return v
    }
    func updateNSView(_ nsView: KeyCatcherView, context: Context) {
        nsView.onKeyDown = onKeyDown
    }
}

final class KeyCatcherView: NSView {
    var onKeyDown: ((NSEvent) -> Bool)?
    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        if !(onKeyDown?(event) ?? false) { super.keyDown(with: event) }
    }

    // Allow mouse events to pass through to underlying views
    override func hitTest(_ point: NSPoint) -> NSView? {
        // Let subviews handle mouse events first
        if let hitView = super.hitTest(point), hitView != self {
            return hitView
        }
        // Only return self for keyboard focus, not for mouse events
        return nil
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        return false // Don't consume first mouse click
    }
}
