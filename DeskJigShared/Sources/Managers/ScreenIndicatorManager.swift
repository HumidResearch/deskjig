//
//  ScreenIndicatorManager.swift
//  DeskJig
//
//  Created by Marco Freedom on 04.09.2025.
//

import Foundation
import SwiftUI
import Cocoa
import AppKit

public class ScreenIndicatorManager: ObservableObject {
    @Published public var isEnabled = false {
        didSet {
            if isEnabled {
                createIndicatorWindows()
            } else {
                removeIndicatorWindows()
                // Show main window when screen indicators are disabled
                onMainWindowVisibilityChanged?(true)
            }
        }
    }

    public init() {}

    // Only stores the action tile window (layout template selector)
    private var indicatorWindows: [String: NSWindow] = [:] // Key: screen identifier
    private var windowLayoutManager: WindowLayoutManager?

    // Callback for when save workspace is requested
    public var onSaveWorkspaceRequested: (() -> Void)?

    /// Callback for when workspace editing is canceled (with the red x button for now).
    public var onCancelWorkspaceEditing: (() -> Void)?

    // Callback for when main window visibility should change
    public var onMainWindowVisibilityChanged: ((Bool) -> Void)?

    public func setWindowLayoutManager(_ windowLayoutManager: WindowLayoutManager) {
        self.windowLayoutManager = windowLayoutManager
    }

    private func createIndicatorWindows() {
        let screens = NSScreen.screens
        for (index, screen) in screens.enumerated() {
            if TestingConfiguration.SKIP_MAIN_SCREEN && index == 0 {
                continue
            }
            if TestingConfiguration.SKIP_SECOND_SCREEN && index == 1 {
                continue
            }
            let screenKey = "screen_\(index)"

            let screenInfo = ScreenInfo(
                screenNumber: index,
                screen: screen,
                applicationIcons: [],
                applicationCount: 0,
                windowSnapshots: []
            )

            if let existingWindow = indicatorWindows[screenKey] {
                updateIndicatorWindow(existingWindow, with: screenInfo)
            } else {
                let newWindow = createIndicatorWindow(
                    for: screenInfo,
                    screenKey: screenKey
                )
                indicatorWindows[screenKey] = newWindow
            }
        }

        // Remove indicators for screens that no longer exist
        let currentScreenKeys = Set(screens.enumerated().map { "screen_\($0.offset)" })
        let keysToRemove = Set(indicatorWindows.keys).subtracting(currentScreenKeys)
        for keyToRemove in keysToRemove {
            if let windowToRemove = indicatorWindows[keyToRemove] {
                windowToRemove.orderOut(nil)
                indicatorWindows.removeValue(forKey: keyToRemove)
            }
        }
    }

    private func createIndicatorWindow(
        for screenInfo: ScreenInfo,
        screenKey: String
    ) -> NSWindow {
        let screen = screenInfo.screen
        let screenFrame = screen.visibleFrame
        let actionTileSize: CGSize = WorkspaceActionTileView.size
        let margin: CGFloat = 20

        // Only create action tile (layout template selector), centered on screen
        let actionTileWindowFrame = CGRect(
            x: screenFrame.minX + (screenFrame.width - actionTileSize.width) / 2,
            y: screenFrame.minY + margin,
            width: actionTileSize.width,
            height: actionTileSize.height
        )

        // Create action tile window
        let actionTileWindow = ScreenIndicatorWindow(
            contentRect: actionTileWindowFrame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )

        let actionTileView = createActionTileView(withScreenInfo: screenInfo)
        let actionTileHostingView = NSHostingView(rootView: actionTileView)
        actionTileHostingView.frame = CGRect(
            origin: .zero,
            size: actionTileWindowFrame.size
        )
        actionTileWindow.contentView = actionTileHostingView
        actionTileWindow.orderFront(self)

        return actionTileWindow
    }

    private func updateIndicatorWindow(
        _ window: NSWindow,
        with screenInfo: ScreenInfo
    ) {
        // Update the SwiftUI content
        if let hostingView = window.contentView as? NSHostingView<WorkspaceActionTileView> {
            hostingView.rootView = createActionTileView(withScreenInfo: screenInfo)
        }
    }

    private func createActionTileView(withScreenInfo screenInfo: ScreenInfo) -> WorkspaceActionTileView {
        WorkspaceActionTileView(
            screenInfo: screenInfo,
            isGridVisible: false,
            onToggleGrid: nil,
            windowLayoutManager: windowLayoutManager
        )
    }

    private func removeIndicatorWindows() {
        for (_, window) in indicatorWindows {
            window.orderOut(nil)
        }
        indicatorWindows.removeAll()
    }

    /// Enable screen indicators for creating a new workspace
    /// Shows only the layout template selector
    public func enableForWorkspaceCreation() {
        DeskJigLog.info(.window, "Enabling screen indicators for workspace creation")

        // Enable indicators to show the layout selector
        isEnabled = true

        DeskJigLog.info(.window, "Screen indicators enabled for workspace creation (layout selector only)")
    }

    // MARK: - Cleanup

    deinit {
        removeIndicatorWindows()
    }
}
