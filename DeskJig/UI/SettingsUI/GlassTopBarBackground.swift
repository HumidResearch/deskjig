//
//  GlassTopBarBackground.swift
//  DeskJig
//
//  Created by Codex on 02/04/26.
//

import SwiftUI
import AppKit
import DeskJigShared

/// Apple Glass background for the top bar (main content area only).
struct GlassTopBarBackground<Content: View>: View {
    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    init() where Content == EmptyView {
        self.content = EmptyView()
    }

    var body: some View {
        GlassTopBarRepresentable(content: content)
    }
}

private struct GlassTopBarRepresentable<Content: View>: NSViewRepresentable {
    let content: Content

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSView {
        let root = NSView(frame: .zero)
        root.autoresizingMask = [.width, .height]

        if #available(macOS 26.0, *) {
            let glassContainer = NSGlassEffectContainerView(frame: .zero)
            glassContainer.autoresizingMask = [.width, .height]

            let glassView = NSGlassEffectView(frame: .zero)
            glassView.autoresizingMask = [.width, .height]
            glassView.style = .regular
            glassView.tintColor = NSColor(DesignTokens.Glass.tint)
            glassView.cornerRadius = 0
            glassView.frame = glassContainer.bounds

            let extensionView = NSBackgroundExtensionView(frame: .zero)
            extensionView.autoresizingMask = [.width, .height]
            // Keep behavior consistent with sidebar glass; the top bar shouldn't re-host window content
            // into the glass plane, otherwise the material can pick up differing backgrounds.
            extensionView.automaticallyPlacesContentView = false
            extensionView.frame = glassView.bounds

            glassView.contentView = extensionView
            glassContainer.contentView = glassView

            root.addSubview(glassContainer)
            glassContainer.frame = root.bounds

            let hostingView = NSHostingView(rootView: AnyView(content))
            context.coordinator.hostingView = hostingView
            hostingView.autoresizingMask = [.width, .height]
            hostingView.frame = root.bounds
            root.addSubview(hostingView)
        } else {
            let visualEffect = NSVisualEffectView(frame: .zero)
            visualEffect.autoresizingMask = [.width, .height]
            visualEffect.material = .sidebar
            visualEffect.blendingMode = .behindWindow
            visualEffect.state = .active
            visualEffect.isEmphasized = false

            let tintOverlay = NSView(frame: .zero)
            tintOverlay.autoresizingMask = [.width, .height]
            tintOverlay.wantsLayer = true
            tintOverlay.layer?.backgroundColor = NSColor(DesignTokens.Glass.tint).cgColor
            tintOverlay.frame = visualEffect.bounds

            visualEffect.addSubview(tintOverlay)
            root.addSubview(visualEffect)
            visualEffect.frame = root.bounds

            let hostingView = NSHostingView(rootView: AnyView(content))
            context.coordinator.hostingView = hostingView
            hostingView.autoresizingMask = [.width, .height]
            hostingView.frame = root.bounds
            root.addSubview(hostingView)
        }

        return root
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.hostingView?.rootView = AnyView(content)
    }

    final class Coordinator {
        var hostingView: NSHostingView<AnyView>?
    }
}
