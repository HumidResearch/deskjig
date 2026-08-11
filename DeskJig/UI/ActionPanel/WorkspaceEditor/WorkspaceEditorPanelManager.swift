//  WorkspaceEditorPanelManager.swift
//  DeskJig
//
//  A separate floating panel for workspace creation/editing UI
//  This allows the ActionPanel to remain functional while editing a workspace
//

import SwiftUI
import AppKit
import DeskJigShared

@MainActor
class WorkspaceEditorPanelManager: ObservableObject {
    
    private var panel: NSPanel?
    private weak var workspaceVM: WorkspaceViewModel?
    private weak var actionPanelManager: ActionPanelManager?
    
    init(workspaceVM: WorkspaceViewModel, actionPanelManager: ActionPanelManager) {
        self.workspaceVM = workspaceVM
        self.actionPanelManager = actionPanelManager
    }
    
    /// Shows the workspace editor panel
    func show(editingWorkspace: WorkspaceViewModel.EditingWorkspace) {
        guard let workspaceVM else { return }
        
        // Create panel if it doesn't exist
        if panel == nil {
            panel = makePanel()
        }
        
        guard let panel else { return }
        
        // Create hosting view with automatic sizing
        let hostingView = NSHostingView(
            rootView: WorkspaceEditorPanelContent(
                editedWorkspace: editingWorkspace,
                workspaceVM: workspaceVM,
                actionPanelManager: actionPanelManager,
                onDismiss: { [weak self] in
                    self?.hide()
                },
                onHeightChanged: { [weak self] needsExtraHeight in
                    self?.updatePanelHeight(expanded: needsExtraHeight)
                }
            )
        )
        panel.contentView = hostingView
        
        // Position the panel
        positionPanel(expanded: false)
        
        // Show the panel
        panel.orderFrontRegardless()
        panel.makeKeyAndOrderFront(nil)

        DeskJigLog.info(.workspace, "WorkspaceEditorPanel shown", fields: ["origin": "\(panel.frame.origin)", "size": "\(panel.frame.size)"])
    }
    
    /// Hides the workspace editor panel
    func hide() {
        panel?.orderOut(nil)
        DeskJigLog.info(.workspace, "WorkspaceEditorPanel hidden")
    }

    /// Shows the directory workspace editor panel
    func showDirectoryWorkspaceEditor(editing: WorkspaceViewModel.EditingDirectoryWorkspace) {
        guard let workspaceVM else { return }

        // Create panel if it doesn't exist
        if panel == nil {
            panel = makePanel()
        }

        guard let panel else { return }

        // Create hosting view with automatic sizing
        let hostingView = NSHostingView(
            rootView: DirectoryWorkspaceEditorPanelContent(
                workspaceVM: workspaceVM,
                actionPanelManager: actionPanelManager,
                onDismiss: { [weak self] in
                    self?.hide()
                },
                onHeightChanged: { [weak self] needsExtraHeight in
                    self?.updatePanelHeight(expanded: needsExtraHeight)
                }
            )
        )
        panel.contentView = hostingView

        // Position the panel
        positionPanel(expanded: false)

        // Show the panel
        panel.orderFrontRegardless()
        panel.makeKeyAndOrderFront(nil)

        DeskJigLog.info(.workspace, "DirectoryWorkspaceEditorPanel shown", fields: ["origin": "\(panel.frame.origin)", "size": "\(panel.frame.size)"])
    }
    
    /// Updates the panel content when workspace changes
    func update(editingWorkspace: WorkspaceViewModel.EditingWorkspace) {
        guard let workspaceVM, let panel else { return }
        
        let hostingView = NSHostingView(
            rootView: WorkspaceEditorPanelContent(
                editedWorkspace: editingWorkspace,
                workspaceVM: workspaceVM,
                actionPanelManager: actionPanelManager,
                onDismiss: { [weak self] in
                    self?.hide()
                },
                onHeightChanged: { [weak self] needsExtraHeight in
                    self?.updatePanelHeight(expanded: needsExtraHeight)
                }
            )
        )
        panel.contentView = hostingView
    }
    
    /// Updates panel height when Chrome detail panel is shown/hidden
    private func updatePanelHeight(expanded: Bool) {
        guard let panel, let screen = NSScreen.main else { return }
        
        let screenFrame = screen.visibleFrame
        let newSize = panelSize(expanded: expanded)
        
        // Animate the size change
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.25
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            
            // Calculate new origin to keep panel centered and at bottom
            let newOrigin = NSPoint(
                x: screenFrame.midX - (newSize.width / 2),
                y: screenFrame.minY
            )
            
            panel.animator().setFrame(
                NSRect(origin: newOrigin, size: newSize),
                display: true
            )
        }
        
        DeskJigLog.info(.workspace, "Panel height updated", fields: ["expanded": "\(expanded)", "newSize": "\(newSize)"])
    }
    
    private func makePanel() -> NSPanel {
        let panel = FloatingPanel(
            contentRect: NSRect(origin: .zero, size: panelSize(expanded: false)),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .statusBar  // Changed from .floating to .statusBar to ensure it's above everything
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        
        DeskJigLog.info(.workspace, "Created WorkspaceEditorPanel", fields: ["size": "\(panelSize(expanded: false))"])

        return panel
    }
    
    /// A floating panel that can accept keyboard input while remaining non-activating.
    final class FloatingPanel: NSPanel {

        /// Returns `true` to allow the panel to become key window for keyboard input.
        override var canBecomeKey: Bool {
            true
        }

        /// Returns `true` to allow the panel to become main window if needed.
        override var canBecomeMain: Bool {
            true
        }

        /// Enable dragging the panel by its content
        override var isMovableByWindowBackground: Bool {
            get { true }
            set { }
        }

        /// Allow the panel to be dragged
        override var isMovable: Bool {
            get { true }
            set { }
        }
    }

    private func positionPanel(expanded: Bool) {
        guard let panel, let screen = NSScreen.main else {
            DeskJigLog.error(.workspace, "Cannot position panel - panel or screen not available")
            return
        }
        
        // Position at bottom center of the screen
        let screenFrame = screen.visibleFrame
        let panelSize = self.panelSize(expanded: expanded)
        panel.setContentSize(panelSize)
        
        let origin = NSPoint(
            x: screenFrame.midX - (panelSize.width / 2),
            y: screenFrame.minY // padding is built into panel frame, so place at bottom
        )
        
        panel.setFrameOrigin(origin)
        DeskJigLog.info(.workspace, "Positioned panel", fields: ["origin": "\(origin)", "visibleFrame": "\(screenFrame)"])
    }
    
    private func panelSize(expanded: Bool) -> NSSize {
        // Adjust height based on number of screens and whether Chrome detail is visible
        let baseHeight: CGFloat = 520
        let chromeDetailPanelHeight: CGFloat = expanded ? 350 : 0  // Extra space for Chrome tabs/profiles panel
        let screenSelectorHeight: CGFloat = NSScreen.screens.count > 1 ? 120 : 0
        return NSSize(width: 680, height: baseHeight + chromeDetailPanelHeight + screenSelectorHeight)
    }
}
