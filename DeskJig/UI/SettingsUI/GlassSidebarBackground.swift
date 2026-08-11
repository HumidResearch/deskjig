//
//  GlassSidebarBackground.swift
//  DeskJig
//
//  Created by Codex on 02/04/26.
//

import SwiftUI
import AppKit
import DeskJigShared

/// Sidebar-only Apple Glass background with macOS 26 glass APIs and a fallback.
struct GlassSidebarBackground<Content: View>: View {
    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        GlassSidebarRepresentable(content: content)
    }
}

private struct GlassSidebarRepresentable<Content: View>: NSViewRepresentable {
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
