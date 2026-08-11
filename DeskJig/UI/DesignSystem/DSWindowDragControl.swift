//
//  DSWindowDragControl.swift
//  DeskJig
//
//  Created by Codex on 02/03/26.
//

import SwiftUI
import AppKit

/// Controls whether the window can be dragged by its background while this view is mounted.
struct DSWindowDragControl: NSViewRepresentable {
    var isMovableByBackground: Bool

    func makeNSView(context: Context) -> DragControlView {
        let view = DragControlView()
        view.isMovableByBackground = isMovableByBackground
        return view
    }

    func updateNSView(_ nsView: DragControlView, context: Context) {
        nsView.isMovableByBackground = isMovableByBackground
        nsView.apply()
    }
}

final class DragControlView: NSView {
    var isMovableByBackground: Bool = true
    private var cachedMovableByBackground: Bool?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        apply()
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil, let window, let cached = cachedMovableByBackground {
            DispatchQueue.main.async {
                window.isMovableByWindowBackground = cached
            }
        }
        super.viewWillMove(toWindow: newWindow)
    }

    func apply() {
        guard let window else { return }
        if cachedMovableByBackground == nil {
            cachedMovableByBackground = window.isMovableByWindowBackground
        }
        if isMovableByBackground {
            restore()
        } else {
            window.isMovableByWindowBackground = false
        }
    }

    private func restore() {
        guard let window, let cached = cachedMovableByBackground else { return }
        window.isMovableByWindowBackground = cached
    }
}
