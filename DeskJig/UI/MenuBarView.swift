//  MenuBarView.swift
//  DeskJig

import SwiftUI
import KeyboardShortcuts
import DeskJigShared

struct MenuBarView: View {
    @Environment(AppDelegate.self) private var appDelegate
    @EnvironmentObject var windowManager: WindowManager
    @EnvironmentObject var appUpdateController: SparkleController

    var body: some View {
        Button("Open DeskJig") {
            appDelegate.setMainWindowIsVisible(true)
        }
        .globalKeyboardShortcut(.showWorkspaceView)

        Divider()

        workspacesMenu

        Divider()

        #if DEBUG
        Button("System Snapshot") {
            appDelegate.showSnapshotViewer()
        }
        .keyboardShortcut("s", modifiers: [.option, .shift])
        #endif

        Divider()

        moveLeftButton
            .keyboardShortcut(.leftArrow, modifiers: [.control, .option])
        moveRightButton
            .keyboardShortcut(.rightArrow, modifiers: [.control, .option])
        moveToTopButton
            .keyboardShortcut(.upArrow, modifiers: [.control, .option])
        moveToBottomButton
            .keyboardShortcut(.downArrow, modifiers: [.control, .option])
        centerButton
            .keyboardShortcut("c", modifiers: [.control, .option])
        maximizeButton
            .keyboardShortcut("m", modifiers: [.control, .option])

        Divider()

        #if DEBUG
        Button("Reload Workspaces") {
            windowManager.reloadWorkspaces()
        }
        .keyboardShortcut("r", modifiers: [.command])

        Divider()
        #endif

        #if DEBUG
        Menu("Test Debugging") {
            Button("Print Window List") {
                printWindowList()
            }
            // The "Test Crash" / "Test Non-Fatal Error" / "Test Workspace
            // Restoration Failure" items are gone: each existed only to push a
            // synthetic event into Crashlytics or Sentry, both of which the
            // port drops. Nothing local replaces them.
        }

        Button("Reset Tutorial") {
            appDelegate.resetTutorialProgress()
        }

        Menu("Update Testing") {
            Button("Set Update Interval to 1 Minute") {
                appUpdateController.setShortUpdateInterval()
            }

            Button("Reset Update Interval to 24 Hours") {
                appUpdateController.resetUpdateInterval()
            }

            Divider()

            Button("Check for Updates Now") {
                appUpdateController.checkForUpdates()
            }
        }

        Divider()
        #endif

        Button("Update DeskJig…") {
            appUpdateController.checkForUpdates()
        }
        .disabled(!appUpdateController.canCheckForUpdates)

        Divider()

        Button("Quit") {
            NSApplication.shared.terminate(nil)
        }
        .keyboardShortcut("q")
    }

    /// Workspace switcher (#595): lists saved workspaces and restores the
    /// clicked one through the same in-app flow the Action Panel uses.
    /// Standard menu items keep the submenu fully AX-accessible.
    @ViewBuilder
    private var workspacesMenu: some View {
        Menu("Workspaces") {
            if windowManager.savedWorkspaces.isEmpty {
                Text("No Saved Workspaces")
            } else {
                ForEach(windowManager.savedWorkspaces, id: \.id) { workspace in
                    Button(workspace.name) {
                        openWorkspace(workspace)
                    }
                }
            }
        }
    }

    private func openWorkspace(_ workspace: Workspace) {
        guard let workspaceViewModel = appDelegate.workspaceViewModel else {
            DeskJigLog.error(.workspace, "Menu bar: workspace view model unavailable, cannot open workspace", fields: ["workspace": workspace.name])
            return
        }
        DeskJigLog.info(.workspace, "Menu bar: opening workspace", fields: ["workspace": workspace.name])
        workspaceViewModel.openWorkspace(workspace, source: "menuBarExtra")
    }

    private var moveLeftButton: some View {
        Button("Move Left") {
            windowManager.moveTopmostWindowLeft()
        }
    }

    private var moveRightButton: some View {
        Button("Move Right") {
            windowManager.moveTopmostWindowRight()
        }
    }

    private var moveToTopButton: some View {
        Button("Move to Top") {
            windowManager.moveTopmostWindowUp()
        }
    }

    private var moveToBottomButton: some View {
        Button("Move to Bottom") {
            windowManager.moveTopmostWindowDown()
        }
    }

    private var centerButton: some View {
        Button("Center") {
            windowManager.centerTopmostWindow()
        }
    }

    private var maximizeButton: some View {
        Button("Maximize") {
            windowManager.maximizeTopmostWindow()
        }
    }

    // MARK: - Debug Functions

    private func printWindowList() {
        let windows = windowManager.windows
        var lines: [String] = []
        lines.append("")
        lines.append("========================================")
        lines.append("CURRENT WINDOW LIST (\(windows.count) windows)")
        lines.append("========================================")
        lines.append("")

        if windows.isEmpty {
            lines.append("No windows found.")
        } else {
            for (index, window) in windows.enumerated() {
                if window.isHidden { continue }
                let marker = window.isMinimized ? "📦" : (window.isHidden ? "👻" : "✅")

                lines.append("[\(index + 1)] \(marker) Window ID: \(window.id)")
                lines.append("    App: \(window.appName)")
                lines.append("    Title: \(window.windowTitle)")
                lines.append("    Bundle ID: \(window.bundleIdentifier ?? "nil")")
                lines.append("    Frame: x:\(Int(window.frame.origin.x)) y:\(Int(window.frame.origin.y)) w:\(Int(window.frame.width)) h:\(Int(window.frame.height))")
                lines.append("    Process ID: \(window.processID)")
                lines.append("    Window Level: \(window.windowLevel)")
                lines.append("    State: minimized=\(window.isMinimized), hidden=\(window.isHidden)")
                lines.append("")
            }
        }

        lines.append("========================================")
        lines.append("")

        DeskJigLog.debug(.app, lines.joined(separator: "\n"))
    }
}
