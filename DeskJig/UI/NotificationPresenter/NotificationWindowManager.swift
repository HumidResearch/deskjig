//
//  NotificationWindowManager.swift
//  DeskJig
//
//  Created by Jake Sax on 11/11/25.
//

import Foundation
import AppKit
import DeskJigShared
import SwiftUI

@MainActor @Observable
final class NotificationWindowManager {

    /// The panel window itself that contains the action panel.
    public private(set) var panel: NotificationPresenterWindow

    /// The details for the current active screen, tracked to keep the action panel
    /// pinned to the active screen.
    private var activeScreen: FullScreenInfo? = nil

    /// Event monitors and polling task keep the toast overlay pinned to the user's active display.
    private var globalMouseDownMonitor: Any?
    private var localMouseDownMonitor: Any?
    private var mouseTrackingTask: Task<Void, Never>?

    init(screen: NSScreen) {
        let screenInfo = FullScreenInfo(screen: screen)
        self.panel = Self.makePanel(forScreen: screenInfo)
        self.activeScreen = screenInfo
        updatePanelFrame(for: screenInfo, animate: false)
        setupScreenTracking()
        moveToFocusedScreenIfNeeded(animate: false)
        self.panel.orderFrontRegardless()
        self.panel.makeKey()
    }

    // MARK: - Panel Window Following
    private func setupScreenTracking() {
        globalMouseDownMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            Task { @MainActor in
                self?.moveToFocusedScreenIfNeeded()
            }
        }

        localMouseDownMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            self?.moveToFocusedScreenIfNeeded()
            return event
        }

        mouseTrackingTask = Task { [weak self] in
            while !Task.isCancelled {
                await MainActor.run {
                    self?.moveToFocusedScreenIfNeeded(animate: false)
                }
                guard await Task.sleepUnlessCancelled(nanoseconds: 300_000_000) else { break }
            }
        }
    }

    private func moveToFocusedScreenIfNeeded(animate: Bool = true) {
        guard let newScreen = focusedScreen() else {
            return
        }

        guard (newScreen.displayID != activeScreen?.displayID) || (newScreen.visibleFrame != activeScreen?.visibleFrame)
        else {
            return
        }

        DeskJigLog.trace(.app, "Moving notification presenter window to focused screen")
        activeScreen = newScreen
        updatePanelFrame(for: newScreen, animate: animate)
    }

    private func focusedScreen() -> FullScreenInfo? {
        let mouseLocation = NSEvent.mouseLocation
        if let mouseScreen = NSScreen.screens.first(where: { $0.frame.contains(mouseLocation) }) {
            return FullScreenInfo(screen: mouseScreen)
        }

        if let mainScreen = NSScreen.main {
            return FullScreenInfo(screen: mainScreen)
        }

        if let firstScreen = NSScreen.screens.first {
            return FullScreenInfo(screen: firstScreen)
        }

        return nil
    }

    private func updatePanelFrame(for screen: FullScreenInfo, animate: Bool) {
        panel.setFrame(
            NSRect(origin: Self.panelOrigin(inScreen: screen), size: screen.visibleFrame.size),
            display: true,
            animate: animate
        )
    }

    static func makePanel(forScreen screen: FullScreenInfo) -> NotificationPresenterWindow {
        // Use visibleFrame size to respect dock and menu bar
        let window = NotificationPresenterWindow(
            contentRect: .init(origin: .zero, size: screen.visibleFrame.size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        window.contentView = NotificationHostingView(rootView: NotificationOverlayRootView())
        return window
    }

    static func panelOrigin(inScreen screen: FullScreenInfo) -> CGPoint {
        // Position at the visible frame origin (just above dock in screen coordinates)
        CGPoint(
            x: screen.visibleFrame.minX,
            y: screen.visibleFrame.minY
        )
    }
}

private struct NotificationOverlayRootView: View {
    var body: some View {
        Color.clear
            .ignoresSafeArea()
            // Keep the full-screen overlay background click-through.
            // Interactive toast controls opt-in with allowsHitTesting(true).
            .allowsHitTesting(false)
            .presentsNotifications()
    }
}

private final class NotificationHostingView: NSHostingView<NotificationOverlayRootView> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }
}
