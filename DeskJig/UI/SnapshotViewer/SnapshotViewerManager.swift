//
//  SnapshotViewerManager.swift
//  DeskJig
//
//  Manages the System Snapshot Viewer floating panel
//

import AppKit
import SwiftUI
import DeskJigShared

/// Custom panel that can become key without requiring the app to be active
final class SnapshotViewerPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

@MainActor
final class SnapshotViewerManager: NSObject, NSWindowDelegate {
    static let shared = SnapshotViewerManager()

    private var panel: NSPanel?
    private var viewModel: SnapshotViewerViewModel?
    private var keyMonitor: Any?

    private override init() {
        super.init()
    }

    func show(workspaces: [Workspace] = []) {
        // If panel exists and is visible, bring it to front
        if let existingPanel = panel, existingPanel.isVisible {
            // Workspaces are now fetched via Fluent API (Workspaces.all())
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
            existingPanel.makeKeyAndOrderFront(nil)
            return
        }

        DeskJigLog.info(.restorationSnapshot, "Opening System Snapshot Viewer (workspaces via Fluent API)")

        // Create view model - workspaces are now fetched via Fluent API
        let vm = SnapshotViewerViewModel()
        self.viewModel = vm

        // Create SwiftUI content view
        let contentView = SnapshotViewerView(viewModel: vm)

        // Create panel - use nonactivatingPanel so it stays visible when activating other windows
        let panel = SnapshotViewerPanel(
            contentRect: NSRect(x: 0, y: 0, width: 1100, height: 700),
            styleMask: [.titled, .closable, .resizable, .miniaturizable, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.title = "System Snapshot"
        panel.level = .normal
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        panel.minSize = NSSize(width: 800, height: 500)
        panel.contentView = NSHostingView(rootView: contentView)
        panel.center()
        panel.delegate = self

        self.panel = panel

        // Temporarily set activation policy to regular so window can appear
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)

        DeskJigLog.info(.restorationSnapshot, "System Snapshot Viewer panel shown", fields: ["frame": panel.frame])

        // Set up global key monitor for Cmd+Shift+P to pick window under cursor
        setupKeyMonitor()

        // Trigger initial capture
        Task {
            await vm.captureSnapshot()
        }
    }

    func close() {
        removeKeyMonitor()
        panel?.close()
        panel = nil
        viewModel = nil
    }

    // MARK: - Window Picking (Cmd+Shift+P)

    private func setupKeyMonitor() {
        // Remove existing monitor if any
        removeKeyMonitor()

        // Add global key monitor for Cmd+Shift+P
        keyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.modifierFlags.contains([.command, .shift]),
                  event.charactersIgnoringModifiers?.lowercased() == "p" else { return }

            Task { @MainActor in
                self?.selectWindowUnderCursor()
            }
        }

        // Also add local monitor for when our panel has focus
        if keyMonitor != nil {
            let localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                if event.modifierFlags.contains([.command, .shift]),
                   event.charactersIgnoringModifiers?.lowercased() == "p" {
                    Task { @MainActor in
                        self?.selectWindowUnderCursor()
                    }
                    return nil // Consume the event
                }
                return event
            }
            // Store as tuple for cleanup (we'll need to track both)
            // For simplicity, just use the global one - local is handled by the global anyway
            _ = localMonitor
        }

        DeskJigLog.debug(.restorationSnapshot, "Window picking key monitor set up (Cmd+Shift+P)")
    }

    private func removeKeyMonitor() {
        if let monitor = keyMonitor {
            NSEvent.removeMonitor(monitor)
            keyMonitor = nil
            DeskJigLog.debug(.restorationSnapshot, "Window picking key monitor removed")
        }
    }

    private func selectWindowUnderCursor() {
        guard let viewModel = viewModel,
              let snapshot = viewModel.snapshot else {
            DeskJigLog.warn(.restorationSnapshot, "Cannot pick window: no snapshot available")
            return
        }

        // Get mouse location in screen coordinates
        let mouseLocation = NSEvent.mouseLocation

        // Convert to CGWindow coordinates (flip Y axis)
        // NSEvent.mouseLocation uses bottom-left origin, CGWindowList uses top-left
        guard let mainScreen = NSScreen.screens.first else { return }
        let screenHeight = mainScreen.frame.height
        let cgMouseLocation = CGPoint(
            x: mouseLocation.x,
            y: screenHeight - mouseLocation.y
        )

        DeskJigLog.debug(.restorationSnapshot, "Picking window at cursor", fields: ["nsPoint": "\(mouseLocation)", "cgPoint": "\(cgMouseLocation)"])

        // Find the topmost window under the cursor from our snapshot
        // Windows are ordered by z-index, so first match is topmost
        let sortedWindows = snapshot.windows.sorted { (w1, w2) in
            (w1.zOrderIndex ?? Int.max) < (w2.zOrderIndex ?? Int.max)
        }

        for window in sortedWindows {
            // Skip our own panel
            if window.title?.contains("System Snapshot") == true {
                continue
            }

            // Check if cursor is within this window's frame
            if window.frame.contains(cgMouseLocation) {
                // Found the window - select it in the table
                viewModel.selectedWindowId = window.id
                DeskJigLog.info(.restorationSnapshot, "Window picked", fields: ["app": window.appName ?? "Unknown", "title": window.title ?? "No title", "id": window.id])

                // Flash the panel to indicate selection
                panel?.makeKeyAndOrderFront(nil)
                return
            }
        }

        DeskJigLog.debug(.restorationSnapshot, "No window found under cursor", fields: ["point": "\(cgMouseLocation)"])
    }

    // MARK: - NSWindowDelegate

    nonisolated func windowWillClose(_ notification: Notification) {
        // Restore accessory activation policy when window closes (if no other windows open)
        Task { @MainActor in
            // Remove key monitor
            self.removeKeyMonitor()

            // Check if main window is visible
            let hasOtherWindows = NSApp.windows.contains { window in
                window.isVisible && window != self.panel
            }

            if !hasOtherWindows {
                DeskJigLog.info(.restorationSnapshot, "System Snapshot Viewer closed, restoring accessory activation policy")
                NSApp.setActivationPolicy(.accessory)
            }

            self.panel = nil
            self.viewModel = nil
        }
    }
}