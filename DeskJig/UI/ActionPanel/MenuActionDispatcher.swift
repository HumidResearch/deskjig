//  MenuActionDispatcher.swift
//  DeskJig

//  Dispatches menu actions to appropriate managers


import Foundation
import AppKit
import SwiftUI
import DeskJigShared

@MainActor
class MenuActionDispatcher {

    // MARK: - Dependencies
    private weak var windowManager: WindowManager?
    private weak var workspaceViewModel: WorkspaceViewModel?
    private weak var actionPanelManager: ActionPanelManager?
    private var chromeProfileWarningRunIds: Set<String> = []

    // MARK: - Initialization
    init(
        windowManager: WindowManager,
        workspaceViewModel: WorkspaceViewModel,
        actionPanelManager: ActionPanelManager? = nil
    ) {
        self.windowManager = windowManager
        self.workspaceViewModel = workspaceViewModel
        self.actionPanelManager = actionPanelManager
    }
    
    /// Sets the action panel manager (can be set after initialization)
    func setActionPanelManager(_ manager: ActionPanelManager) {
        self.actionPanelManager = manager
    }

    // MARK: - Action Dispatch

    /// Executes a menu action with optional parameters
    func dispatch(_ action: MenuAction, parameters: ActionParameters? = nil) async throws {
        DeskJigLog.info(.app, "Dispatching action", fields: ["action": action.rawValue])

        switch action {
        // MARK: Window Actions
        case .closeWindow:
            windowManager?.closeTopmostWindow()

        case .closeApplication:
            // Close application requires windowInfo - use fallback to windowInfo-based method
            if let windowInfo = windowManager?.windows.first(where: { !$0.isMinimized && !$0.isHidden }) {
                _ = windowManager?.closeApplication(windowInfo: windowInfo)
            }

        case .hideWindow:
            windowManager?.hideTopmostWindow()

        case .minimizeWindow:
            windowManager?.minimizeTopmostWindow()

        case .restoreWindow:
            windowManager?.restoreTopmostWindow()

        case .activateWindow:
            windowManager?.activateTopmostWindow()

        case .moveWindowLeft:
            windowManager?.moveTopmostWindowLeft()

        case .moveWindowRight:
            windowManager?.moveTopmostWindowRight()

        case .moveWindowUp:
            windowManager?.moveTopmostWindowUp()

        case .moveWindowDown:
            windowManager?.moveTopmostWindowDown()

        case .centerWindow:
            windowManager?.centerTopmostWindow()

        case .maximizeWindow:
            windowManager?.maximizeTopmostWindow()

        case .moveWindowToLeftHalf:
            windowManager?.moveTopmostWindowToLeftHalf()

        case .moveWindowToRightHalf:
            windowManager?.moveTopmostWindowToRightHalf()
        
        case .moveWindowToTopHalf:
            windowManager?.moveTopmostWindowToTopHalf()

        case .moveWindowToBottomHalf:
            windowManager?.moveTopmostWindowToBottomHalf()

        case .moveWindowToLeftThird:
            windowManager?.moveTopmostWindowToLeftThird()

        case .moveWindowToCenterThird:
            windowManager?.moveTopmostWindowToCenterThird()

        case .moveWindowToRightThird:
            windowManager?.moveTopmostWindowToRightThird()

        case .moveWindowToTopLeftQuarter:
            windowManager?.moveTopmostWindowToTopLeftQuarter()

        case .moveWindowToTopRightQuarter:
            windowManager?.moveTopmostWindowToTopRightQuarter()

        case .moveWindowToBottomLeftQuarter:
            windowManager?.moveTopmostWindowToBottomLeftQuarter()

        case .moveWindowToBottomRightQuarter:
            windowManager?.moveTopmostWindowToBottomRightQuarter()

        case .hideAllWindows:
            let _ = windowManager?.hideAllWindows()

        case .unhideAllWindows:
            let _ = windowManager?.unhideAllWindows()

        case .minimizeAllWindows:
            let _ = windowManager?.minimizeAllWindows()

        // MARK: Tiling Actions
        case .tileSideBySide:
            windowManager?.tileSideBySide()

        case .tileTopBottom:
            windowManager?.tileTopBottom()

        case .tileQuarters:
            windowManager?.tileQuarters()

        // MARK: Workspace Actions
        case .createWorkspace:
            actionPanelManager?.openWorkspacesAction?(.createWorkspace(seed: .currentSnapshot))

        case .saveWorkspace:
            if let name = parameters?.workspaceName, let icon = parameters?.customHandler {
                // When called from menu action, save all screens (empty set = all screens)
                workspaceViewModel?.saveWorkspace(withName: name, andIcon: icon, screenIndices: [])
            } else {
                throw ActionError.missingParameters("workspaceName and icon required")
            }

        case .deleteWorkspace:
            if let workspaceName = parameters?.workspaceName,
               let workspace = findWorkspace(named: workspaceName) {
                workspaceViewModel?.deleteWorkspace(workspace)
            } else {
                throw ActionError.missingParameters("workspaceName")
            }

        case .renameWorkspace:
            if let workspaceName = parameters?.workspaceName,
               let workspace = findWorkspace(named: workspaceName),
               let newName = parameters?.customHandler {
                windowManager?.renameWorkspace(workspace, newName: newName)
            } else {
                throw ActionError.missingParameters("workspaceName and newName required")
            }

        case .editWorkspace:
            if let workspace = parameters?.workspace {
                actionPanelManager?.openWorkspacesAction?(.editWorkspace(id: workspace.id))
            } else if let workspaceName = parameters?.workspaceName,
                      let workspace = findWorkspace(named: workspaceName) {
                actionPanelManager?.openWorkspacesAction?(.editWorkspace(id: workspace.id))
            } else {
                throw ActionError.missingParameters("workspaceName")
            }

        case .openWorkspace:
            if let workspaceName = parameters?.workspaceName {
                DeskJigLog.info(.workspace, "ActionPanel: openWorkspace action", fields: ["workspace": workspaceName])
                workspaceViewModel?.openWorkspace(named: workspaceName, source: "actionPanel")
            } else {
                throw ActionError.missingParameters("workspaceName")
            }

        case .restoreWorkspace:
            if let workspace = parameters?.workspace {
                try await restoreWorkspaceFluentV2(workspace, source: "actionPanelRestore")
            } else if let workspaceName = parameters?.workspaceName,
                      let workspace = findWorkspace(named: workspaceName) {
                try await restoreWorkspaceFluentV2(workspace, source: "actionPanelRestore")
            } else {
                throw ActionError.missingParameters("workspace or workspaceName")
            }

        case .restoreWorkspaceWithMapping:
            // This action requires screen mapping parameters from UI interaction
            // Use .restoreWorkspace for simple restoration, or .editWorkspace to modify mappings
            throw ActionError.notImplemented("restoreWorkspaceWithMapping requires interactive screen mapping selection")

        case .reloadWorkspaces:
            windowManager?.reloadWorkspaces()

        // MARK: Directory Workspace Actions
        case .createDirectoryWorkspace:
            workspaceViewModel?.startCreatingDirectoryWorkspace()
            // Show the directory workspace editor panel
            actionPanelManager?.showWorkspaceEditorIfNeeded()

        case .openDirectoryWorkspace:
            if let workspaceID = parameters?.directoryWorkspaceID,
               let workspace = DirectoryWorkspace.withID(workspaceID) {
                workspaceViewModel?.openDirectoryWorkspace(workspace)
            } else if let workspaceName = parameters?.directoryWorkspaceName {
                workspaceViewModel?.openDirectoryWorkspace(named: workspaceName)
            } else {
                throw ActionError.missingParameters("directoryWorkspaceID or directoryWorkspaceName")
            }

        case .editDirectoryWorkspace:
            if let workspaceID = parameters?.directoryWorkspaceID,
               let workspace = DirectoryWorkspace.withID(workspaceID) {
                workspaceViewModel?.editDirectoryWorkspace(workspace)
                actionPanelManager?.showWorkspaceEditorIfNeeded()
            } else if let workspaceName = parameters?.directoryWorkspaceName,
                      let workspace = DirectoryWorkspace.named(workspaceName) {
                workspaceViewModel?.editDirectoryWorkspace(workspace)
                actionPanelManager?.showWorkspaceEditorIfNeeded()
            } else {
                throw ActionError.missingParameters("directoryWorkspaceID or directoryWorkspaceName")
            }

        case .deleteDirectoryWorkspace:
            if let workspaceID = parameters?.directoryWorkspaceID,
               let workspace = DirectoryWorkspace.withID(workspaceID) {
                workspaceViewModel?.deleteDirectoryWorkspace(workspace)
            } else if let workspaceName = parameters?.directoryWorkspaceName,
                      let workspace = DirectoryWorkspace.named(workspaceName) {
                workspaceViewModel?.deleteDirectoryWorkspace(workspace)
            } else {
                throw ActionError.missingParameters("directoryWorkspaceID or directoryWorkspaceName")
            }

        // MARK: App Actions
        case .openSettings:
            // Handled by ActionPanelManager using SwiftUI's openSettings environment action
            // This should not be reached as ActionPanelManager intercepts this action
            DeskJigLog.warn(.app, "openSettings action reached dispatcher - should be handled by ActionPanelManager")

        case .quit:
            NSApplication.shared.terminate(nil)

        case .about:
            NSApplication.shared.orderFrontStandardAboutPanel(nil)

        case .checkForUpdates:
            // Would integrate with SparkleController
            DeskJigLog.info(.app, "Check for updates triggered")

        case .custom:
            if let handler = parameters?.customHandler {
                try await executeCustomHandler(handler, parameters: parameters)
            } else {
                throw ActionError.missingParameters("customHandler required")
            }

        
        }
    }

    // MARK: - Helper Methods

    /// Finds a workspace by name
    private func findWorkspace(named name: String) -> Workspace? {
        return windowManager?.savedWorkspaces.first { $0.name == name }
    }
    
    /// Parses a layout template string to LayoutTemplate enum
    private func parseLayoutTemplate(_ string: String) -> LayoutTemplate? {
        return LayoutTemplate(rawValue: string)
    }

    /// Executes a custom handler (could be scripting, plugins, etc.)
    private func executeCustomHandler(
        _ handler: String,
        parameters: ActionParameters?
    ) async throws {
        // This could support:
        // - AppleScript execution
        // - JavaScript plugin system
        // - Python scripts
        // - Shell commands
        DeskJigLog.info(.app, "Executing custom handler", fields: ["handler": handler])
        throw ActionError.notImplemented("Custom handlers not yet implemented")
    }

    // MARK: - Errors
    enum ActionError: LocalizedError {
        case missingDependency(String)
        case missingParameters(String)
        case actionFailed(String)
        case notImplemented(String)

        var errorDescription: String? {
            switch self {
            case .missingDependency(let dep): "Missing dependency: \(dep)"
            case .missingParameters(let params): "Missing parameters: \(params)"
            case .actionFailed(let reason): "Action failed: \(reason)"
            case .notImplemented(let feature): "Not implemented: \(feature)"
            }
        }
    }
}

private extension MenuActionDispatcher {
    func restoreWorkspaceFluentV2(_ workspace: Workspace, source: String) async throws {
        DeskJigLog.debug(.workspace, "ActionPanel: Fluent v2 restore triggered", fields: ["workspace": workspace.name, "source": source])

        // Route through WindowManager to ensure missing app callback is wired up
        guard let windowManager else {
            throw ActionError.missingDependency("WindowManager")
        }

        let result = await windowManager.restoreWorkspace(workspace)

        DeskJigLog.debug(.workspace, "ActionPanel: Fluent v2 restore complete", fields: [
            "success": result.success,
            "restored": result.windowsRestored,
            "failed": result.windowsFailed,
            "skipped": result.windowsSkipped
        ], runId: result.runId)
        DeskJigLog.debug(.workspace, "ActionPanel: Fluent v2 timing", fields: [
            "snapshotMs": result.snapshotDurationMs,
            "planMs": result.planDurationMs,
            "executeMs": result.executeDurationMs
        ], runId: result.runId)

        presentChromeProfileRemapWarningIfNeeded(workspace: workspace, result: result)
        if !result.success {
            presentRestoreFailureToast(workspace: workspace, result: result)
        }

        if !result.success && result.windowsRestored == 0 {
            throw ActionError.actionFailed("Fluent v2 restore failed")
        }
    }

    func presentRestoreFailureToast(
        workspace: Workspace,
        result: FluentRestorationResult
    ) {
        guard let evaluation = result.evaluation,
              !evaluation.issues.isEmpty else { return }

        let issueSummary = evaluation.issues.prefix(2).map { "• \($0)" }.joined(separator: "\n")
        let body = "\(workspace.name): \(issueSummary)"
        let duration: NotificationPresenter.PresentationDuration = result.windowsRestored == 0
            ? .persistent
            : .seconds(8)

        NotificationPresenter.present(
            .init(
                "Workspace restore needs attention",
                text: body,
                icon: "exclamationmark.triangle.fill",
                iconColor: .yellow,
                forceDarkAppearance: true
            ),
            for: duration
        )
    }

    func presentChromeProfileRemapWarningIfNeeded(
        workspace: Workspace,
        result: FluentRestorationResult
    ) {
        guard !chromeProfileWarningRunIds.contains(result.runId) else { return }

        let remappedProfiles = result.plan.tasks
            .compactMap(\.chromeTargetProfile)
            .filter { $0.shouldWarnAboutRemapOrFallback }

        guard !remappedProfiles.isEmpty else { return }
        chromeProfileWarningRunIds.insert(result.runId)

        let summary = remappedProfiles.prefix(2).map { profile -> String in
            let stored = profile.storedProfileDirectory ?? "none"
            let resolved = profile.resolvedProfileDirectory ?? "default/any"
            let reason = profile.fallbackReason ?? profile.resolvedBy
            return "• \(stored) → \(resolved) (\(reason))"
        }.joined(separator: "\n")

        NotificationPresenter.present(
            .init(
                "Chrome profile remap applied",
                text: "\(workspace.name): \(summary)",
                icon: "exclamationmark.triangle.fill",
                iconColor: .yellow,
                forceDarkAppearance: true
            ),
            for: .seconds(8)
        )
    }
}

