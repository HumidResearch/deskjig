//
//  WorkspaceViewModel.swift
//  DeskJig
//

import SwiftUI
import AppKit
import Combine
import DeskJigShared
import KeyboardShortcuts

@MainActor @Observable
final class WorkspaceViewModel {
    nonisolated static let quickSwitchLaunchSource = "quick-switch"
    nonisolated static let settingsEnterLaunchSource = "settings-enter"

    struct WorkspaceLaunchResolution {
        let workspace: Workspace
        let persistedWorkspace: Workspace?
        let usedLatestPersistedCopy: Bool
    }

    private struct QuickSwitchWindowVisibilityOutcome {
        let hideAttempted: Bool
        let hideSucceeded: Bool
        let reopenedOnFailure: Bool
    }

    enum SettingsWorkspaceCreateSeed: Equatable {
        case blank
        case currentSnapshot
    }

    enum SettingsWorkspaceAction: Equatable {
        case editWorkspace(id: UUID)
        case createWorkspace(seed: SettingsWorkspaceCreateSeed)
    }

    // MARK: - Dependencies
    var applicationManager = ApplicationManager()
    var windowManager: WindowManager
    var overlayWindowManager: OverlayWindowManager
    var windowLayoutManager = WindowLayoutManager()
    var screenIndicatorManager = ScreenIndicatorManager()
    /// Workspaces synced from WindowManager synced from WorkspaceManager
    private(set) var workspaces: [WorkspaceWithApps] = []

    // MARK: - App Delegate
    private weak var appDelegate: AppDelegate?

    // MARK: - Navigation
    let navigationManager: NavigationManager

    // MARK: - UI State
    var workspaceToRestore: Workspace?
    var showingRestoreConfirmation = false
    var showingDeleteConfirmation = false
    var workspaceToDelete: Workspace?
    var workspaceBeingEdited: EditingWorkspace?
    var isEditingLayout = false  // Track if we're editing layout vs just metadata
    var showingWorkspaceNaming = false
    var workspaceNamingMode: WorkspaceNamingMode?
    var showingWorkspaceDeletion = false
    var showingScreenMapping = false
    var workspaceForScreenMapping: Workspace?
    var workspaceToEditInSettings: Workspace?  // Workspace to edit in main settings modal
    var showingWorkspaceEditInSettings = false  // Controls main settings edit modal
    var pendingSettingsWorkspaceAction: SettingsWorkspaceAction?
    private var presentedWorkspaceLaunchOverlay: WorkspaceLaunchOverlay?
    private var workspaceLaunchTask: (id: UUID, task: Task<Void,Error>)? = nil
    private var chromeProfileWarningRunIds: Set<String> = []

    // MARK: - Constants
    private let workspaceSectionUUID = UUID()
    private let newWorkspaceSectionUUID = UUID()

    private var cancellables = Set<AnyCancellable>()

    enum EditingWorkspace: Equatable {
        case new(Workspace)
        case existing(Workspace)

        var workspace: Workspace {
            switch self {
            case .new(let workspace): workspace
            case .existing(let workspace): workspace
            }
        }

        var isNew: Bool {
            switch self {
            case .new: true
            case .existing: false
            }
        }
    }

    func requestSettingsEdit(_ workspace: Workspace) {
        pendingSettingsWorkspaceAction = .editWorkspace(id: workspace.id)
    }

    func requestSettingsEdit(id: UUID) {
        pendingSettingsWorkspaceAction = .editWorkspace(id: id)
    }

    func requestSettingsCreate(seed: SettingsWorkspaceCreateSeed) {
        pendingSettingsWorkspaceAction = .createWorkspace(seed: seed)
    }

    func clearSettingsWorkspaceAction() {
        pendingSettingsWorkspaceAction = nil
    }

    // MARK: - Initialization
    init(navigationManager: NavigationManager, windowManager: WindowManager, overlayWindowManager: OverlayWindowManager) {
        self.navigationManager = navigationManager
        self.windowManager = windowManager
        self.overlayWindowManager = overlayWindowManager
        setupManagers()

        windowManager.$savedWorkspaces
            .map { workspaces in
                workspaces
                    .sorted { $0.createdAt > $1.createdAt }
                    .map { workspace in
                        WorkspaceWithApps(
                            workspace: workspace,
                            apps: Set(workspace.windows.map(\.bundleIdentifier))
                                .sorted()
                                .compactMap {
                                    self.applicationManager.findApplication(by: $0)
                                }
                        )
                    }
            }
            .sink { [weak self] workspaces in
                self?.workspaces = workspaces
            }
            .store(in: &cancellables)
    }

    // MARK: - Setup
    private func setupManagers() {
        windowManager.checkAccessibilityPermissions()
        overlayWindowManager.setWindowManager(windowManager)
        windowLayoutManager.setWindowManager(windowManager)
        // NOTE: the reference app also called
        // `screenIndicatorManager.setOverlayWindowManager(overlayWindowManager)`
        // here. Wave 1 removed that setter from `ScreenIndicatorManager` along
        // with its only two readers (`toggleGrid()` / `isGridVisible()`, both
        // dead), so the call had no observable effect and is dropped rather
        // than the shared cleanup being reverted.
        screenIndicatorManager.setWindowLayoutManager(windowLayoutManager)
        windowManager.setOverlayWindowManager(overlayWindowManager)
        windowManager.setApplicationManager(applicationManager)
        windowManager.setWindowLayoutManager(windowLayoutManager)

        // Set up callback for when screen indicator requests main window visibility change
        screenIndicatorManager.onMainWindowVisibilityChanged = { [weak self] shouldShow in
            DispatchQueue.main.async {
                self?.setMainWindowVisibility(shouldShow)
            }
        }
    }

    // MARK: - App Delegate Management
    func setAppDelegate(_ appDelegate: AppDelegate) {
        self.appDelegate = appDelegate
        /// Make sure we reopen the main window when cancelling workspace editing
        self.screenIndicatorManager.onCancelWorkspaceEditing = {
            DeskJigLog.info(.workspace, "Canceling workspace editing")
            appDelegate.setMainWindowIsVisible(true)
            self.workspaceBeingEdited = nil
            self.showingWorkspaceNaming = false
        }
    }

    // MARK: - Window Visibility Management
    private func setMainWindowVisibility(_ shouldShow: Bool) {
        appDelegate?.setMainWindowIsVisible(shouldShow)
    }

    // MARK: - Computed Properties
    var currentSections: [TileSection] {
        if let currentTile = navigationManager.navigationStack.last, let children = currentTile.children {
            // When we're inside a tile, show its children as a single section without title
            return [TileSection(id: currentTile.tileSectionUUID!, title: "", tiles: children)]
        } else {
            // At root level, show real sections based on workspace data
            return realSections
        }
    }

    private var realSections: [TileSection] {
        var sections: [TileSection] = []

        // First section: Workspaces sorted by creation time
        let sortedWorkspaces = windowManager.savedWorkspaces.sorted {
            $0.createdAt > $1.createdAt
        }

        let workspaceTiles = sortedWorkspaces.map { workspace in
            Tile(
                title: workspace.name,
                subtitle: "\(workspace.windows.count) windows • \(formattedDate(workspace.createdAt))",
                icon: nil,
                type: .branch,
                children: createWorkspaceActions(for: workspace),
                tileSectionUUID: workspaceSectionUUID,
                apps: Set(workspace.windows.map(\.bundleIdentifier)).sorted().compactMap {
                    if let app = applicationManager.findApplication(by: $0) {
                        return app
                    } else {
                        DeskJigLog.warn(.workspace, "Failed to find app", fields: ["bundleId": $0])
                        return nil
                    }
                }
            )
        }

        if !workspaceTiles.isEmpty {
            sections.append(TileSection(id: workspaceSectionUUID, title: "Workspaces", tiles: workspaceTiles))
        }

        // Second section: Create new
        let createTiles = [
            Tile(
                title: "Create workspace",
                subtitle: "Start workspace creation",
                icon: .addBox,
                type: .leaf,
                children: nil,
                tileSectionUUID: workspaceSectionUUID
            ),
        ]

        sections.append(TileSection(id: newWorkspaceSectionUUID, title: "Create new", tiles: createTiles))

        return sections
    }

    var filteredSections: [TileSection] {
        let baseSections = currentSections
        guard !navigationManager.search.trimmingCharacters(in: .whitespaces).isEmpty else { return baseSections }

        return baseSections.compactMap { section in
            let filteredTiles = section.tiles.filter { $0.title.localizedCaseInsensitiveContains(navigationManager.search) }
            return filteredTiles.isEmpty ? nil : TileSection(id: section.id, title: section.title, tiles: filteredTiles)
        }
    }

    var allFilteredTiles: [Tile] {
        filteredSections.flatMap { $0.tiles }
    }

    var breadcrumbPath: String {
        navigationManager.breadcrumbPath
    }

    // MARK: - Helper Methods
    private func createWorkspaceActions(for workspace: Workspace) -> [Tile] {
        return [
            Tile(
                title: "Open workspace",
                subtitle: "Restore \(workspace.name)",
                icon: .northEast,
                type: .leaf,
                children: nil
            ),
            Tile(
                title: "Restore to selected displays",
                subtitle: "Choose target displays",
                icon: .viewCompact,
                type: .leaf,
                children: nil
            ),
            Tile(
                title: "Edit layout",
                subtitle: "Change workspace layout",
                icon: .viewCompact,
                type: .leaf,
                children: nil
            ),
            Tile(
                title: "Rename workspace",
                subtitle: "Change workspace name",
                icon: .pencil,
                type: .leaf,
                children: nil
            ),
            Tile(
                title: "Delete workspace",
                subtitle: "Remove workspace",
                icon: .trash,
                type: .leaf,
                children: nil
            )
        ]
    }

    private func formattedDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    func calculateGlobalIndex(for section: TileSection, tileIndex: Int) -> Int {
        navigationManager.calculateGlobalIndex(for: section, tileIndex: tileIndex, filteredSections: filteredSections)
    }

    func titleForMode(_ mode: WorkspaceNamingMode) -> String {
        switch mode {
        case .create: "Create Workspace"
        case .rename: "Rename Workspace"
        }
    }

    // MARK: - Navigation Methods
    func moveSelection(direction: MoveCommandDirection, columns: Int, total: Int) {
        let navDirection = convertToNavigationDirection(direction)
        navigationManager.moveSelection(direction: navDirection, columns: columns, allTiles: allFilteredTiles, filteredSections: filteredSections)
    }

    private func convertToNavigationDirection(_ direction: MoveCommandDirection) -> NavigationDirection {
        switch direction {
        case .left: return .left
        case .right: return .right
        case .up: return .up
        case .down: return .down
        @unknown default: return .down
        }
    }

    // MARK: - Action Methods
    func handleEsc() {
        if !navigationManager.navigateBack() {
            NSApp.keyWindow?.close() // Back/close behavior for sample
        }
    }

    func handleKeyPress(_ keyPress: KeyPress) -> KeyPress.Result {
        navigationManager.handleKeyPress(
            keyPress,
            allTiles: allFilteredTiles,
            onActivate: { [weak self] tile in
                self?.activate(tile: tile)  // Enter key uses normal activate
            },
            onKeyboardShortcut: { [weak self] tile in
                self?.activateWithKeyboardShortcut(tile: tile)  // CMD+1-9 uses shortcut activate
            }
        )
    }

//    func handleKey(event: NSEvent, columns: Int, total: Int) -> Bool {
//        navigationManager.handleKey(
//            event: event,
//            columns: columns,
//            allTiles: allFilteredTiles,
//            filteredSections: filteredSections,
//            onActivate: { [weak self] tile in
//                self?.activate(tile: tile)  // Enter key uses normal activate
//            },
//            onKeyboardShortcut: { [weak self] tile in
//                self?.activateWithKeyboardShortcut(tile: tile)  // CMD+1-9 uses shortcut activate
//            },
//            onEscape: { [weak self] in
//                self?.handleEsc()
//            }
//        )
//    }

    func activate(tile: Tile) {
        switch tile.type {
        case .branch: navigationManager.navigateToTile(tile)
        case .leaf: handleLeafAction(tile: tile)
        }
    }

    private func activateWithKeyboardShortcut(tile: Tile) {
        switch tile.type {
        case .branch:
            // For keyboard shortcuts, directly open workspace tiles
            if isWorkspaceTile(tile) {
                openWorkspace(named: tile.title)
            } else {
                navigationManager.navigateToTile(tile)
            }
        case .leaf:
            handleLeafAction(tile: tile)
        }
    }

    private func handleLeafAction(tile: Tile) {
        // Handle different leaf actions based on title
        switch tile.title {
        case "Open workspace":
            // Find the workspace this action belongs to
            if let workspaceTitle = navigationManager.navigationStack.last?.title {
                openWorkspace(named: workspaceTitle)
            }

        case "Restore to selected displays":
            // Find the workspace and show screen mapping UI
            if let workspaceTitle = navigationManager.navigationStack.last?.title,
               let workspace = windowManager.savedWorkspaces.first(where: { $0.name == workspaceTitle }) {
                workspaceForScreenMapping = workspace
                showingScreenMapping = true
            }

        case "Edit layout":
            guard let workspaceTitle = navigationManager.navigationStack.last?.title,
                  let workspace = windowManager.savedWorkspaces.first(where: { $0.name == workspaceTitle }) else {
                DeskJigLog.error(.workspace, "Could not find workspace to edit")
                return
            }

            editWorkspace(workspace)

        case "Rename workspace":
            // Find the workspace this action belongs to
            if let workspaceTitle = navigationManager.navigationStack.last?.title,
               let workspace = windowManager.savedWorkspaces.first(where: { $0.name == workspaceTitle }) {
                // Show rename dialog in this view
                workspaceNamingMode = .rename(workspace)
                showingWorkspaceNaming = true
            }

        case "Delete workspace":
            // Find the workspace this action belongs to
            if let workspaceTitle = navigationManager.navigationStack.last?.title,
               let workspace = windowManager.savedWorkspaces.first(where: { $0.name == workspaceTitle }) {
                workspaceToDelete = workspace
                showingWorkspaceDeletion = true
            }

        case "Create workspace":
            // Start workspace creation process - enable screen indicators first
            startCreatingWorkspace()

        default:
            // Default action for unknown tiles
            NSSound(named: .init("Glass"))?.play()
        }
    }

    /// Starts workspace creation.
    /// - Returns: Always `true` once creation flow has been initialized.
    @discardableResult
    func startCreatingWorkspace() -> Bool {
        DeskJigLog.info(.workspace, "Starting workspace creation")

        workspaceBeingEdited = .new(
            .init(
                name: "My Workspace",
                workspaceWindows: []
            )
        )

        DeskJigLog.info(.workspace, "Workspace creation started")
        return true
    }

    func editWorkspace(_ workspace: Workspace) {
        DeskJigLog.info(.workspace, "Starting workspace metadata editing", fields: ["workspace": workspace.name])
        workspaceBeingEdited = .existing(workspace)
        isEditingLayout = false  // Start in metadata editing mode

        // Close main window without restoring workspace
        self.closeMainNexusWindow()

        DeskJigLog.info(.workspace, "Workspace editor opened in metadata-only mode")
    }

    /// Opens the workspace editor modal in the main settings window (for hotkey pill clicks)
    func openWorkspaceEditorInSettings(_ workspace: Workspace) {
        DeskJigLog.info(.workspace, "Opening workspace editor in settings", fields: ["workspace": workspace.name])
        workspaceToEditInSettings = workspace
        showingWorkspaceEditInSettings = true
    }

    func enterLayoutEditingMode() {
        guard let workspaceBeingEdited else {
            DeskJigLog.error(.workspace, "Cannot enter layout editing mode - no workspace being edited")
            return
        }

        let workspace = workspaceBeingEdited.workspace
        DeskJigLog.info(.workspace, "Entering layout editing mode", fields: ["workspace": workspace.name])
        isEditingLayout = true

        // Use openWorkspace to properly activate apps and restore the workspace
        // This ensures apps are launched/activated before positioning windows
        openWorkspace(named: workspace.name)
    }

    /// Enters layout editing mode without restoring the workspace.
    /// This allows editing layout using saved workspace data while keeping current windows as-is.
    func enterLayoutEditingModeWithoutRestore() {
        guard let workspaceBeingEdited else {
            DeskJigLog.error(.workspace, "Cannot enter layout editing mode - no workspace being edited")
            return
        }

        let workspace = workspaceBeingEdited.workspace
        DeskJigLog.info(.workspace, "Entering layout editing mode (without restore)", fields: ["workspace": workspace.name])
        isEditingLayout = true

        // Do NOT call openWorkspace - the user's current windows stay as-is
        // The WorkspaceEditorPanelContent will use the saved workspace data for preview
    }

    /// Chrome window modification data for saving
    struct ChromeWindowModification {
        var tabURLs: [String]
        var profileDirectory: String?
        var profileDisplayName: String?
        var profileHostedDomain: String?
        var profileUserName: String?
        var profileMatchMode: ChromeProfileMatchMode = .specific
    }

    /// Per-window "open by path" modification data for saving/updating workspaces.
    struct OpenByPathWindowModification {
        var bundleIdentifier: String
        var windowTitle: String
        var openPath: String?
    }

    func saveWorkspace(
        withName name: String,
        andIcon icon: String,
        screenIndices: Set<Int>,
        chromeModifications: [UUID: ChromeWindowModification] = [:],
        openByPathModifications: [UUID: OpenByPathWindowModification] = [:]
    ) {
        guard workspaceBeingEdited != nil else {
            DeskJigLog.error(.workspace, "Cannot save workspace, none being edited")
            return
        }

        // Log screen selection
        if screenIndices.isEmpty {
            DeskJigLog.warn(.workspace, "No screens selected, saving all screens")
        } else {
            DeskJigLog.info(.workspace, "Saving workspace for screen indices", fields: ["screenIndices": Array(screenIndices).sorted().description])
        }

        if !chromeModifications.isEmpty {
            DeskJigLog.info(.workspace, "Received Chrome modifications", fields: ["count": chromeModifications.count])
            for (windowId, mod) in chromeModifications {
                DeskJigLog.info(.workspace, "Chrome modification detail", fields: [
                    "windowId": windowId.uuidString,
                    "urlCount": mod.tabURLs.count,
                    "profile": mod.profileDisplayName ?? "nil"
                ])
                for (index, url) in mod.tabURLs.enumerated() {
                    DeskJigLog.info(.workspace, "Chrome tab URL", fields: ["index": index, "url": url])
                }
            }
        }

        if !openByPathModifications.isEmpty {
            DeskJigLog.info(.workspace, "Received openByPath modifications", fields: ["count": openByPathModifications.count])
            for (windowId, mod) in openByPathModifications {
                DeskJigLog.info(.workspace, "openByPath modification detail", fields: [
                    "windowId": windowId.uuidString,
                    "bundleIdentifier": mod.bundleIdentifier,
                    "openPath": mod.openPath ?? "nil"
                ])
            }
        }

        windowManager.refreshWindows { [weak self] in
            guard let self, let workspaceBeingEdited = self.workspaceBeingEdited else { return }

            Task { [weak self] in
                guard let self else { return }

                switch workspaceBeingEdited {
                case .new(let workspace):
                    // New workspaces always capture current window positions
                    await self.windowManager.saveCurrentWorkspace(
                        id: workspace.id,
                        name: name,
                        icon: icon,
                        screenIndices: screenIndices,
                        minVisibilityOverride: 1.0,
                        chromeModifications: chromeModifications.mapValues { mod in
                            ChromeModification(
                                tabURLs: mod.tabURLs,
                                profileDirectory: mod.profileDirectory,
                                profileDisplayName: mod.profileDisplayName,
                                profileHostedDomain: mod.profileHostedDomain,
                                profileUserName: mod.profileUserName,
                                profileMatchMode: mod.profileMatchMode
                            )
                        },
                        openByPathModifications: openByPathModifications.mapValues { mod in
                            OpenByPathModification(
                                bundleIdentifier: mod.bundleIdentifier,
                                windowTitle: mod.windowTitle,
                                openPath: mod.openPath
                            )
                        }
                    )

                    DeskJigLog.info(.workspace, "Workspace created: \(name)", fields: [
                        "workspace_id": workspace.id.uuidString,
                        "workspace_name": name,
                        "workspace_icon": icon,
                        "screen_count": screenIndices.count,
                        "chrome_modifications": chromeModifications.count,
                        "action": "create"
                    ])
                case .existing(let workspace):
                    if self.isEditingLayout {
                        // Layout editing mode: capture new window positions
                        DeskJigLog.info(.workspace, "Saving workspace with updated layout")
                        await self.windowManager.updateWorkspaceWindows(
                            for: workspace.withNewName(name).withNewIcon(icon),
                            screenIndices: screenIndices,
                            minVisibilityOverride: 1.0,
                            chromeModifications: chromeModifications.mapValues { mod in
                                ChromeModification(
                                    tabURLs: mod.tabURLs,
                                    profileDirectory: mod.profileDirectory,
                                    profileDisplayName: mod.profileDisplayName,
                                    profileHostedDomain: mod.profileHostedDomain,
                                    profileUserName: mod.profileUserName,
                                    profileMatchMode: mod.profileMatchMode
                                )
                            },
                            openByPathModifications: openByPathModifications.mapValues { mod in
                                OpenByPathModification(
                                    bundleIdentifier: mod.bundleIdentifier,
                                    windowTitle: mod.windowTitle,
                                    openPath: mod.openPath
                                )
                            }
                        )

                        DeskJigLog.info(.workspace, "Workspace layout updated: \(name)", fields: [
                            "workspace_id": workspace.id.uuidString,
                            "workspace_name": name,
                            "workspace_icon": icon,
                            "screen_count": screenIndices.count,
                            "chrome_modifications": chromeModifications.count,
                            "action": "edit_layout"
                        ])
                    } else {
                        // Metadata editing mode: update name, icon, and chrome modifications
                        DeskJigLog.info(.workspace, "Saving workspace with metadata changes")
                        self.windowManager.updateWorkspaceMetadata(
                            for: workspace,
                            newName: name,
                            newIcon: icon,
                            chromeModifications: chromeModifications.mapValues { mod in
                                ChromeModification(
                                    tabURLs: mod.tabURLs,
                                    profileDirectory: mod.profileDirectory,
                                    profileDisplayName: mod.profileDisplayName,
                                    profileHostedDomain: mod.profileHostedDomain,
                                    profileUserName: mod.profileUserName,
                                    profileMatchMode: mod.profileMatchMode
                                )
                            },
                            openByPathModifications: openByPathModifications.mapValues { mod in
                                OpenByPathModification(
                                    bundleIdentifier: mod.bundleIdentifier,
                                    windowTitle: mod.windowTitle,
                                    openPath: mod.openPath
                                )
                            }
                        )

                        DeskJigLog.info(.workspace, "Workspace metadata updated: \(name)", fields: [
                            "workspace_id": workspace.id.uuidString,
                            "workspace_name": name,
                            "workspace_icon": icon,
                            "chrome_modifications": chromeModifications.count,
                            "action": "edit_metadata"
                        ])
                    }
                }

                // WindowLayoutManager no longer has persistent zones
                // Snap-to-zone only happens during drag with preview overlays

                self.workspaceBeingEdited = nil
                self.isEditingLayout = false  // Reset flag after save
            }
        }
    }

    func cancelWorkspaceEditing() {
        DeskJigLog.info(.workspace, "Cancelling workspace editing")

        // WindowLayoutManager no longer has persistent zones

        workspaceBeingEdited = nil
        isEditingLayout = false  // Reset flag on cancel
    }

    private func isWorkspaceTile(_ tile: Tile) -> Bool {
        // Check if this tile belongs to the workspace section
        return tile.tileSectionUUID == workspaceSectionUUID
    }

    func openWorkspace(named workspaceName: String, source: String = "unknown") {
        guard let workspace = windowManager.savedWorkspaces.first(where: { $0.name == workspaceName }) else {
            DeskJigLog.error(.workspace, "Could not open workspace named", fields: ["workspace": workspaceName])
            return
        }

        openWorkspace(workspace, source: source, launchDisplayName: workspaceName)
    }

    /// Launches a workspace payload through the standard restoration flow.
    /// `launchDisplayName` controls the launch overlay title and logs.
    /// `onComplete` is called after restoration finishes (on MainActor).
    func openWorkspace(
        _ workspace: Workspace,
        source: String = "unknown",
        launchDisplayName: String? = nil,
        onComplete: (() -> Void)? = nil
    ) {
        let resolution = Self.resolveWorkspaceForLaunch(
            workspace,
            source: source,
            savedWorkspaces: windowManager.savedWorkspaces
        )
        let resolvedWorkspace = resolution.workspace
        let displayName = launchDisplayName ?? resolvedWorkspace.name

        if source == Self.quickSwitchLaunchSource,
           let persistedWorkspace = resolution.persistedWorkspace,
           persistedWorkspace != workspace {
            DeskJigLog.info(.workspace, "QuickSwitch: preserving runtime workspace payload for launch", fields: [
                "workspace": workspace.name,
                "workspaceID": workspace.id.uuidString,
                "runtimeOpenPathCount": "\(Self.openPathWindowCount(in: workspace))",
                "persistedOpenPathCount": "\(Self.openPathWindowCount(in: persistedWorkspace))",
                "runtimeTerminalKeyCount": "\(Self.terminalKeyCount(in: workspace))",
                "persistedTerminalKeyCount": "\(Self.terminalKeyCount(in: persistedWorkspace))",
                "runtimeTmuxCwdCount": "\(Self.tmuxInitialWorkingDirectoryCount(in: workspace))",
                "persistedTmuxCwdCount": "\(Self.tmuxInitialWorkingDirectoryCount(in: persistedWorkspace))",
                "runtimePayloadDifferenceCount": "\(Self.quickSwitchPayloadDifferenceCount(runtime: workspace, persisted: persistedWorkspace))"
            ])
        }

        if resolvedWorkspace.layoutHealth != .healthy {
            DeskJigLog.warn(.workspace, "Opening workspace with legacy flattened layout data", fields: [
                "workspace": resolvedWorkspace.name,
                "layoutHealth": resolvedWorkspace.layoutHealth.rawValue,
                "source": source,
                "usedLatestPersistedCopy": resolution.usedLatestPersistedCopy.description
            ])
        }

        launchWorkspace(
            resolvedWorkspace,
            launchDisplayName: displayName,
            source: source,
            onComplete: onComplete
        )
    }

    private func launchWorkspace(
        _ workspace: Workspace,
        launchDisplayName: String,
        source: String,
        onComplete: (() -> Void)? = nil
    ) {
        let runId = FluentWorkspaceRestorer.makeRunId()
        DeskJigLog.debug(.workspace, "Opening workspace via standard restore flow", fields: [
            "workspace": launchDisplayName,
            "source": source
        ], runId: runId)
        let launchID = UUID()
        let shouldCloseImmediately = Self.shouldCloseMainWindowImmediately(source: source)
        let shouldReopenOnFailure = shouldCloseImmediately

        if shouldCloseImmediately {
            let hideStart = Date()
            let hideSucceeded = closeMainNexusWindow()
            let hideDurationMs = max(0, Int(Date().timeIntervalSince(hideStart) * 1000))
            logQuickSwitchWindowVisibilityOutcome(
                runId: runId,
                source: source,
                outcome: QuickSwitchWindowVisibilityOutcome(
                    hideAttempted: true,
                    hideSucceeded: hideSucceeded,
                    reopenedOnFailure: false
                ),
                reason: "launch-start",
                durationMs: hideDurationMs
            )
        }

        presentLaunchLoaderOverlay(forWorkspace: launchDisplayName, withLaunchID: launchID)

        let launchTask: Task<Void, Error> = Task { [weak self] in
            guard let self else {
                throw CancellationError()
            }

            do {
                self.presentPortabilityWarningIfNeeded(for: workspace, runId: runId)

                let preparation = try await FluentWorkspaceRestorer.shared.prepareRestore(
                    workspace: workspace,
                    mode: .interactive
                )
                try Task.checkCancellation()

                self.handlePreparedWorkspaceLaunch(
                    preparation,
                    launchDisplayName: launchDisplayName,
                    runId: runId,
                    launchID: launchID,
                    closeAfterRestore: !shouldCloseImmediately,
                    source: source,
                    reopenMainWindowOnFailure: shouldReopenOnFailure,
                    onComplete: onComplete
                )
            } catch is CancellationError {
                self.handleWorkspaceLaunchPreparationCancellation(
                    runId: runId,
                    launchID: launchID,
                    source: source,
                    reopenMainWindowOnFailure: shouldReopenOnFailure
                )
            } catch {
                self.handleWorkspaceLaunchPreparationFailure(
                    workspace: workspace,
                    error: error,
                    runId: runId,
                    launchID: launchID,
                    source: source,
                    reopenMainWindowOnFailure: shouldReopenOnFailure
                )
            }
        }

        self.workspaceLaunchTask = (launchID, launchTask)
    }

    /// GH #579: pre-restore portability validation. Warns (toast + log) when the
    /// workspace references apps that are not installed, folders that no longer
    /// exist, or more displays than are connected — so degraded restores are
    /// explained up front instead of failing silently window-by-window.
    /// The restore itself proceeds; missing apps surface per-window through the
    /// existing missing-app callback and display mismatches through the
    /// interactive display-assignment prompt.
    private func presentPortabilityWarningIfNeeded(for workspace: Workspace, runId: String) {
        windowManager.displayManager.refreshScreens()
        let currentDisplayCount = WorkspaceDisplayTopology
            .effectiveScreens(from: windowManager.displayManager)
            .count
        let report = WorkspacePortabilityAnalyzer().analyze(
            workspace: workspace,
            currentDisplayCount: currentDisplayCount
        )
        guard report.hasFindings else { return }

        DeskJigLog.warn(.workspace, "Workspace portability findings before restore", fields: [
            "workspace": workspace.name,
            "missingApps": "\(report.missingApps.count)",
            "missingPaths": "\(report.missingPaths.count)",
            "savedDisplayCount": "\(report.savedDisplayCount)",
            "currentDisplayCount": "\(report.currentDisplayCount)",
            "warnings": report.warnings.joined(separator: " | ")
        ], runId: runId)

        NotificationPresenter.present(
            .init(
                "Workspace may restore differently",
                text: "\(workspace.name): \(report.warnings.joined(separator: " "))",
                icon: "exclamationmark.triangle.fill",
                iconColor: .yellow,
                forceDarkAppearance: true
            ),
            for: .seconds(8)
        )
    }

    nonisolated static func shouldCloseMainWindowImmediately(source: String) -> Bool {
        switch source {
        case quickSwitchLaunchSource, settingsEnterLaunchSource:
            return true
        default:
            return false
        }
    }

    nonisolated static func resolveWorkspaceForLaunch(
        _ workspace: Workspace,
        source: String,
        savedWorkspaces: [Workspace]
    ) -> WorkspaceLaunchResolution {
        let persistedWorkspace = savedWorkspaces.first(where: { $0.id == workspace.id })
        if source == quickSwitchLaunchSource {
            return WorkspaceLaunchResolution(
                workspace: workspace,
                persistedWorkspace: persistedWorkspace,
                usedLatestPersistedCopy: false
            )
        }

        return WorkspaceLaunchResolution(
            workspace: persistedWorkspace ?? workspace,
            persistedWorkspace: persistedWorkspace,
            usedLatestPersistedCopy: persistedWorkspace != nil && persistedWorkspace != workspace
        )
    }

    private nonisolated static func openPathWindowCount(in workspace: Workspace) -> Int {
        workspace.windows.filter { ($0.openPath?.isEmpty == false) }.count
    }

    private nonisolated static func terminalKeyCount(in workspace: Workspace) -> Int {
        workspace.windows.filter { ($0.terminalKey?.isEmpty == false) }.count
    }

    private nonisolated static func tmuxInitialWorkingDirectoryCount(in workspace: Workspace) -> Int {
        workspace.windows.filter { ($0.tmuxState?.initialWorkingDirectory.isEmpty == false) }.count
    }

    private nonisolated static func quickSwitchPayloadDifferenceCount(
        runtime: Workspace,
        persisted: Workspace
    ) -> Int {
        let persistedWindowsByID = Dictionary(uniqueKeysWithValues: persisted.windows.map { ($0.id, $0) })
        return runtime.windows.reduce(into: 0) { count, runtimeWindow in
            guard let persistedWindow = persistedWindowsByID[runtimeWindow.id] else {
                count += 1
                return
            }
            if runtimeWindow.openPath != persistedWindow.openPath ||
                runtimeWindow.terminalKey != persistedWindow.terminalKey ||
                runtimeWindow.tmuxState?.initialWorkingDirectory != persistedWindow.tmuxState?.initialWorkingDirectory {
                count += 1
            }
        }
    }

    private func handlePreparedWorkspaceLaunch(
        _ preparation: WorkspaceRestorePreparationResult,
        launchDisplayName: String,
        runId: String,
        launchID: UUID,
        closeAfterRestore: Bool,
        source: String,
        reopenMainWindowOnFailure: Bool,
        onComplete: (() -> Void)? = nil
    ) {
        guard workspaceLaunchTask?.id == launchID else {
            return
        }

        switch preparation {
        case .ready(let context):
            DeskJigLog.debug(.workspace, "Fluent workspace preparation resolved display assignments", fields: [
                "workspace": launchDisplayName,
                "assignmentCount": context.assignments.count,
                "assignments": context.assignments
                    .map { "\($0.slotID.uuidString)->\($0.displayID)" }
                    .joined(separator: ", ")
            ], runId: runId)

            startWorkspaceRestorationTask(
                workspace: context.normalizedWorkspace,
                displayAssignments: context.assignments,
                runId: runId,
                launchID: launchID,
                closeAfterRestore: closeAfterRestore,
                source: source,
                reopenMainWindowOnFailure: reopenMainWindowOnFailure,
                onComplete: onComplete
            )

        case .requiresAssignment(let prompt):
            DeskJigLog.debug(.workspace, "Fluent workspace preparation requires display assignment", fields: [
                "workspace": launchDisplayName,
                "savedScreenCount": prompt.analysis.savedScreenCount,
                "currentScreenCount": prompt.analysis.currentScreenCount
            ], runId: runId)

            presentLaunchLoaderOverlay(
                forWorkspace: launchDisplayName,
                withLaunchID: launchID,
                initialPhase: .screenSelection(prompt.analysis, prompt.normalizedWorkspace),
                onMappingsSelected: { [weak self] mappings in
                    let displayAssignments = prompt.displayAssignments(from: mappings)
                    self?.continueWorkspaceRestoration(
                        workspace: prompt.normalizedWorkspace,
                        displayAssignments: displayAssignments,
                        runId: runId,
                        launchID: launchID,
                        closeAfterRestore: closeAfterRestore,
                        source: source,
                        reopenMainWindowOnFailure: reopenMainWindowOnFailure,
                        onComplete: onComplete
                    )
                }
            )
        }
    }

    private func handleWorkspaceLaunchPreparationCancellation(
        runId: String,
        launchID: UUID,
        source: String,
        reopenMainWindowOnFailure: Bool
    ) {
        hideWorkspaceLaunchLoaderOverlay(reason: "prepare-cancelled")
        if workspaceLaunchTask?.id == launchID {
            workspaceLaunchTask = nil
        }
        if reopenMainWindowOnFailure {
            let reopened = reopenMainNexusWindow()
            logQuickSwitchWindowVisibilityOutcome(
                runId: runId,
                source: source,
                outcome: QuickSwitchWindowVisibilityOutcome(
                    hideAttempted: true,
                    hideSucceeded: true,
                    reopenedOnFailure: reopened
                ),
                reason: "prepare-cancelled"
            )
        }
    }

    private func handleWorkspaceLaunchPreparationFailure(
        workspace: Workspace,
        error: Error,
        runId: String,
        launchID: UUID,
        source: String,
        reopenMainWindowOnFailure: Bool
    ) {
        hideWorkspaceLaunchLoaderOverlay(reason: "prepare-error")
        DeskJigLog.error(.workspace, "Workspace launch preparation error", fields: [
            "workspace": workspace.name,
            "error": error.localizedDescription
        ], runId: runId)

        // #566: preparation failures used to dismiss the launch overlay and only
        // log, so a structurally broken workspace (e.g. one persisted without
        // display-slot geometry) failed with no user-facing signal. Surface the
        // failure the same way restore failures are surfaced.
        NotificationPresenter.present(
            .init(
                "Workspace couldn't be restored",
                text: "\(workspace.name): \(error.localizedDescription)",
                icon: "exclamationmark.triangle.fill",
                iconColor: .red,
                forceDarkAppearance: true
            ),
            for: .persistent
        )

        if workspaceLaunchTask?.id == launchID {
            workspaceLaunchTask = nil
        }

        if reopenMainWindowOnFailure {
            let reopened = reopenMainNexusWindow()
            logQuickSwitchWindowVisibilityOutcome(
                runId: runId,
                source: source,
                outcome: QuickSwitchWindowVisibilityOutcome(
                    hideAttempted: true,
                    hideSucceeded: true,
                    reopenedOnFailure: reopened
                ),
                reason: "prepare-failed"
            )
        }
    }

    /// Continues workspace restoration after user selects display assignments
    private func continueWorkspaceRestoration(
        workspace: Workspace,
        displayAssignments: [WorkspaceDisplayAssignment],
        runId: String,
        launchID: UUID,
        closeAfterRestore: Bool,
        source: String,
        reopenMainWindowOnFailure: Bool,
        onComplete: (() -> Void)? = nil
    ) {
        DeskJigLog.debug(.workspace, "Continuing restoration with user-selected display assignments", fields: [
            "assignments": displayAssignments
                .map { "\($0.slotID.uuidString)->\($0.displayID)" }
                .joined(separator: ", ")
        ], runId: runId)

        // Transition overlay to restoring phase (already done by the overlay callback)
        startWorkspaceRestorationTask(
            workspace: workspace,
            displayAssignments: displayAssignments,
            runId: runId,
            launchID: launchID,
            closeAfterRestore: closeAfterRestore,
            source: source,
            reopenMainWindowOnFailure: reopenMainWindowOnFailure,
            onComplete: onComplete
        )
    }

    /// Starts the actual workspace restoration task
    private func startWorkspaceRestorationTask(
        workspace: Workspace,
        displayAssignments: [WorkspaceDisplayAssignment],
        runId: String,
        launchID: UUID,
        closeAfterRestore: Bool = true,
        source: String = "unknown",
        reopenMainWindowOnFailure: Bool = false,
        onComplete: (() -> Void)? = nil
    ) {
        let launchTask: Task<Void, Error> = Task { [weak self] in
            try await Task.sleep(for: .seconds(1.0))
            try Task.checkCancellation()

            await MainActor.run {
                self?.navigationManager.navigationStack.removeAll()
                self?.navigationManager.selectedIndex = 0
            }

            do {
                guard let strongSelf = self else {
                    throw CancellationError()
                }
                let result = await strongSelf.windowManager.restoreWorkspaceWithDisplayAssignments(
                    workspace,
                    displayAssignments: displayAssignments,
                    source: source
                )

                await MainActor.run {
                    self?.hideWorkspaceLaunchLoaderOverlay(reason: "restore-complete")

                    if result.windowsFailed == 0 {
                        DeskJigLog.debug(.workspace, "Workspace restored via Fluent v2", fields: [
                            "workspace": workspace.name,
                            "restored": result.windowsRestored
                        ], runId: result.runId)
                    } else if result.windowsRestored > 0 {
                        DeskJigLog.warn(.workspace, "Workspace partially restored via Fluent v2", fields: [
                            "workspace": workspace.name,
                            "restored": result.windowsRestored,
                            "failed": result.windowsFailed,
                            "skipped": result.windowsSkipped
                        ], runId: result.runId)
                    } else {
                        DeskJigLog.error(.workspace, "Workspace restoration failed via Fluent v2", fields: [
                            "workspace": workspace.name,
                            "failed": result.windowsFailed,
                            "skipped": result.windowsSkipped
                        ], runId: result.runId)
                    }

                    onComplete?()

                    if self?.workspaceLaunchTask?.id == launchID {
                        self?.workspaceLaunchTask = nil
                    }

                    self?.presentChromeProfileRemapWarningIfNeeded(workspace: workspace, result: result)
                    if !result.success {
                        self?.presentRestoreFailureToast(
                            workspace: workspace,
                            result: result,
                            source: source
                        )
                        if reopenMainWindowOnFailure {
                            let reopened = self?.reopenMainNexusWindow() ?? false
                            self?.logQuickSwitchWindowVisibilityOutcome(
                                runId: runId,
                                source: source,
                                outcome: QuickSwitchWindowVisibilityOutcome(
                                    hideAttempted: true,
                                    hideSucceeded: true,
                                    reopenedOnFailure: reopened
                                ),
                                reason: "restore-failed"
                            )
                        }
                    }
                }

                if closeAfterRestore {
                    let closeMainWindowTask = MainActor.async(after: .seconds(0.5)) { [weak self] in
                        self?.closeMainNexusWindow()
                    }
                    _ = try? await closeMainWindowTask.value
                }
            } catch is CancellationError {
                await MainActor.run {
                    self?.hideWorkspaceLaunchLoaderOverlay(reason: "restore-cancelled")
                    if self?.workspaceLaunchTask?.id == launchID {
                        self?.workspaceLaunchTask = nil
                    }
                    if reopenMainWindowOnFailure {
                        let reopened = self?.reopenMainNexusWindow() ?? false
                        self?.logQuickSwitchWindowVisibilityOutcome(
                            runId: runId,
                            source: source,
                            outcome: QuickSwitchWindowVisibilityOutcome(
                                hideAttempted: true,
                                hideSucceeded: true,
                                reopenedOnFailure: reopened
                            ),
                            reason: "restore-cancelled"
                        )
                    }
                }
            } catch {
                await MainActor.run {
                    self?.hideWorkspaceLaunchLoaderOverlay(reason: "restore-error")
                    DeskJigLog.error(.workspace, "Workspace restoration error", fields: [
                        "workspace": workspace.name,
                        "error": error.localizedDescription
                    ], runId: runId)
                    if self?.workspaceLaunchTask?.id == launchID {
                        self?.workspaceLaunchTask = nil
                    }
                    if reopenMainWindowOnFailure {
                        let reopened = self?.reopenMainNexusWindow() ?? false
                        self?.logQuickSwitchWindowVisibilityOutcome(
                            runId: runId,
                            source: source,
                            outcome: QuickSwitchWindowVisibilityOutcome(
                                hideAttempted: true,
                                hideSucceeded: true,
                                reopenedOnFailure: reopened
                            ),
                            reason: "restore-error"
                        )
                    }
                }
                throw error
            }
        }

        self.workspaceLaunchTask = (launchID, launchTask)
    }

    /// Presents an overlay over the screen that shows the name of the workspace
    /// and a loading indicator while the workspace is being launched.
    ///
    /// - Parameters:
    ///   - workspace: Name of the workspace being launched.
    ///   - launchID: Unique ID for this launch task.
    ///   - initialPhase: Initial phase for the overlay (default: .loading).
    ///   - onMappingsSelected: Callback when user confirms screen mappings (for screenSelection phase).
    private func presentLaunchLoaderOverlay(
        forWorkspace workspace: String,
        withLaunchID launchID: UUID,
        initialPhase: WorkspaceLaunchOverlay.LaunchPhase = .loading,
        onMappingsSelected: (([ScreenMappingInfo]) -> Void)? = nil
    ) {
        hideWorkspaceLaunchLoaderOverlay(reason: "replace")
        let overlay = WorkspaceLaunchOverlay(
            workspace: workspace,
            cancelWorkspaceLaunch: { [weak self] in
                self?.cancelWorkspaceLaunch(withLaunchID: launchID)
                self?.hideWorkspaceLaunchLoaderOverlay(reason: "cancel")
            },
            initialPhase: initialPhase,
            onMappingsSelected: onMappingsSelected,
            applicationManager: applicationManager
        )
        presentedWorkspaceLaunchOverlay = overlay
        overlay.show()
    }

    private func hideWorkspaceLaunchLoaderOverlay(reason: String) {
        DeskJigLog.debug(.workspace, "WorkspaceLaunchOverlay: hide requested", fields: ["reason": reason])
        presentedWorkspaceLaunchOverlay?.dismiss()
        presentedWorkspaceLaunchOverlay = nil
    }

    private func cancelWorkspaceLaunch(withLaunchID launchID: UUID) {
        guard let workspaceLaunchTask, workspaceLaunchTask.id == launchID else {
            DeskJigLog.warn(.workspace, "Cannot cancel workspace launch task", fields: [
                "requestedId": launchID.uuidString,
                "currentId": workspaceLaunchTask?.id.uuidString ?? "nil"
            ])
            return
        }
        DeskJigLog.debug(.workspace, "Canceling workspace launch task", fields: ["launchId": launchID.uuidString])
        workspaceLaunchTask.task.cancel()
        self.workspaceLaunchTask = nil
        self.windowManager.cancelWorkspaceRestoration()
        Task {
            await FluentWorkspaceRestorer.shared.cancel()
        }
    }

    @discardableResult
    private func closeMainNexusWindow() -> Bool {
        if let resolvedAppDelegate = appDelegate ?? (NSApplication.shared.delegate as? AppDelegate),
           resolvedAppDelegate.isWindowVisible {
            // Keep Bento running in menu bar while hiding the settings window.
            resolvedAppDelegate.setMainWindowIsVisible(false)
            return true
        }

        // Fallback: hide the window directly if delegate wiring is unavailable.
        if let mainWindow = NSApplication.shared.windows.first(where: {
            $0.identifier?.rawValue == DeskJigApp.mainWindowID || $0.title == DeskJigApp.mainWindowTitle
        }), mainWindow.isVisible {
            mainWindow.orderOut(nil)
            return true
        }

        return false
    }

    @discardableResult
    private func reopenMainNexusWindow() -> Bool {
        if let resolvedAppDelegate = appDelegate ?? (NSApplication.shared.delegate as? AppDelegate) {
            resolvedAppDelegate.setMainWindowIsVisible(true)
            return true
        }

        if let mainWindow = NSApplication.shared.windows.first(where: {
            $0.identifier?.rawValue == DeskJigApp.mainWindowID || $0.title == DeskJigApp.mainWindowTitle
        }) {
            mainWindow.orderFrontRegardless()
            mainWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return true
        }

        return false
    }

    private func logQuickSwitchWindowVisibilityOutcome(
        runId: String,
        source: String,
        outcome: QuickSwitchWindowVisibilityOutcome,
        reason: String,
        durationMs: Int? = nil
    ) {
        var fields: [String: any Sendable] = [
            "source": source,
            "reason": reason,
            "hideAttempted": outcome.hideAttempted,
            "hideSucceeded": outcome.hideSucceeded,
            "reopenedOnFailure": outcome.reopenedOnFailure
        ]
        if let durationMs {
            fields["durationMs"] = durationMs
        }
        DeskJigLog.debug(.workspace, "QuickSwitchWindowVisibilityOutcome", fields: fields, runId: runId)
    }

    // MARK: - Workspace Naming Methods
    private func showWorkspaceCreationNaming() {
        workspaceNamingMode = .create
        showingWorkspaceNaming = true
    }

    func handleWorkspaceNaming(name: String) {
        guard let mode = workspaceNamingMode else { return }

        switch mode {
        case .create:
            // Save workspace with the provided name directly through windowManager
            Task {
                await windowManager.saveCurrentWorkspace(name: name, icon: nil)
            }

            // Disable ScreenIndicatorManager and WindowLayoutManager after saving
            if screenIndicatorManager.isEnabled {
                screenIndicatorManager.isEnabled = false
            }
            // WindowLayoutManager no longer has persistent zones
        case .rename(let workspace):
            // Rename the existing workspace
            windowManager.renameWorkspace(workspace, newName: name)

            // Update the navigation stack to reflect the new name
            updateNavigationStackAfterRename(oldWorkspace: workspace, newName: name)
        }

        // Hide the naming dialog
        showingWorkspaceNaming = false
        workspaceNamingMode = nil

        // Ensure fresh focus on search
        navigationManager.refocus()
    }

    func cancelWorkspaceNaming() {
        showingWorkspaceNaming = false
        workspaceNamingMode = nil

        // Ensure fresh focus on search
        navigationManager.refocus()
    }

    private func updateNavigationStackAfterRename(oldWorkspace: Workspace, newName: String) {
        // Update the navigation stack to reflect the renamed workspace
        for (index, tile) in navigationManager.navigationStack.enumerated() {
            if tile.title == oldWorkspace.name && tile.tileSectionUUID == workspaceSectionUUID {
                // Find the updated workspace from windowManager to get accurate data
                if let updatedWorkspace = windowManager.savedWorkspaces.first(where: { $0.id == oldWorkspace.id }) {
                    // Create a new tile with the updated name and children
                    let updatedTile = Tile(
                        title: updatedWorkspace.name,
                        subtitle: "\(updatedWorkspace.windows.count) windows • \(formattedDate(updatedWorkspace.createdAt))",
                        icon: tile.icon,
                        type: tile.type,
                        children: createWorkspaceActions(for: updatedWorkspace),
                        tileSectionUUID: tile.tileSectionUUID
                    )
                    navigationManager.navigationStack[index] = updatedTile
                }
                break
            }
        }
    }

    // MARK: - Lifecycle Methods
    func updateManagers() {
        overlayWindowManager.updateOverlays()
        // screenIndicatorManager no longer needs manual updates
    }

    func validateSelectedIndex() {
        navigationManager.validateSelectedIndex(totalTiles: allFilteredTiles.count)
    }

    func deleteWorkspace(_ workspace: Workspace) {
        // Clean up keyboard shortcut
        KeyboardShortcuts.reset(.workspace(workspace.id))
        DeskJigLog.info(.workspace, "Cleared keyboard shortcut for deleted workspace", fields: ["workspace": workspace.name])

        windowManager.deleteWorkspace(workspace)
        workspaceToDelete = nil
        showingWorkspaceDeletion = false

        // Navigate back to main menu (clear navigation stack)
        navigationManager.navigationStack.removeAll()
        navigationManager.selectedIndex = 0
    }

    func cancelDeleteWorkspace() {
        workspaceToDelete = nil
        showingWorkspaceDeletion = false
    }

    // MARK: - Favorites

    /// Computed property for favorite workspaces
    var favoriteWorkspaces: [WorkspaceWithApps] {
        workspaces.filter { $0.workspace.isFavorite }
    }

    /// Toggle favorite status for a workspace
    func toggleFavorite(_ workspace: Workspace) {
        windowManager.workspaceManagerService.toggleFavorite(workspace)
    }

    // MARK: - Inline Editing

    /// Updates workspace metadata inline without opening the full editor.
    /// Used by WorkspaceCardView for inline editing.
    func updateWorkspaceInline(
        workspace: Workspace,
        newName: String,
        newIcon: String,
        chromeModifications: [UUID: ChromeWindowModification],
        openByPathModifications: [UUID: OpenByPathWindowModification]
    ) {
        DeskJigLog.info(.workspace, "Updating workspace inline", fields: ["from": workspace.name, "to": newName])

        windowManager.updateWorkspaceMetadata(
            for: workspace,
            newName: newName,
            newIcon: newIcon,
            chromeModifications: chromeModifications.mapValues { mod in
                ChromeModification(
                    tabURLs: mod.tabURLs,
                    profileDirectory: mod.profileDirectory,
                    profileDisplayName: mod.profileDisplayName,
                    profileHostedDomain: mod.profileHostedDomain,
                    profileUserName: mod.profileUserName,
                    profileMatchMode: mod.profileMatchMode
                )
            },
            openByPathModifications: openByPathModifications.mapValues { mod in
                OpenByPathModification(
                    bundleIdentifier: mod.bundleIdentifier,
                    windowTitle: mod.windowTitle,
                    openPath: mod.openPath
                )
            }
        )

        DeskJigLog.info(.workspace, "Workspace inline update complete")
    }

    func applyInferredLegacyWorkspaceRepair(_ workspace: Workspace) {
        let referenceWorkspaces = windowManager.savedWorkspaces.filter { $0.id != workspace.id }
        guard case .resolved(let candidate) = workspace.monitorRepairResult(using: referenceWorkspaces) else {
            DeskJigLog.warn(.workspace, "No resolved legacy workspace repair available to apply", fields: [
                "workspace": workspace.name,
                "layoutHealth": workspace.layoutHealth.rawValue
            ])
            return
        }

        applyLegacyWorkspaceRepairCandidate(candidate, to: workspace)
    }

    func applyLegacyWorkspaceRepairCandidate(
        _ candidate: WorkspaceLegacyLayoutRepairCandidate,
        to workspace: Workspace
    ) {
        let repairedWorkspace = candidate.repairedWorkspace
        let repairedScreens = repairedWorkspace.screens ?? []
        let repairedSlots = repairedWorkspace.displaySlots ?? []

        DeskJigLog.info(.workspace, "Applying legacy workspace repair candidate", fields: [
            "workspace": workspace.name,
            "layoutHealthBefore": workspace.layoutHealth.rawValue,
            "candidateScore": "\(candidate.score)",
            "candidateConfidence": "\(candidate.confidence)",
            "repairedScreenCount": "\(repairedScreens.count)",
            "repairedSlotCount": "\(repairedSlots.count)"
        ])

        windowManager.workspaceManagerService.updateWorkspaceLayout(
            for: workspace,
            newName: workspace.name,
            newIcon: workspace.icon ?? "",
            windows: repairedWorkspace.windows,
            screens: repairedScreens,
            displaySlots: repairedSlots
        )

        windowManager.workspaceManagerService.reloadWorkspaces()

        if let refreshedWorkspace = windowManager.workspaceManagerService.savedWorkspaces.first(where: { $0.id == workspace.id }) {
            DeskJigLog.info(.workspace, "Legacy workspace repair candidate applied", fields: [
                "workspace": refreshedWorkspace.name,
                "layoutHealthAfter": refreshedWorkspace.layoutHealth.rawValue,
                "screenCount": "\(refreshedWorkspace.screens?.count ?? 0)",
                "slotCount": "\(refreshedWorkspace.displaySlots?.count ?? 0)"
            ])
        }
    }

    func recaptureLegacyWorkspaceLayout(_ workspace: Workspace) {
        DeskJigLog.info(.workspace, "Recapturing legacy workspace layout from current windows", fields: [
            "workspace": workspace.name,
            "layoutHealthBefore": workspace.layoutHealth.rawValue
        ])

        Task {
            await windowManager.updateWorkspaceWindows(for: workspace)

            let refreshedWorkspace = await MainActor.run {
                windowManager.savedWorkspaces.first(where: { $0.id == workspace.id })
            }

            guard let refreshedWorkspace else {
                DeskJigLog.warn(.workspace, "Legacy workspace recapture finished but refreshed workspace was not found", fields: [
                    "workspace": workspace.name
                ])
                return
            }

            DeskJigLog.info(.workspace, "Legacy workspace recapture complete", fields: [
                "workspace": refreshedWorkspace.name,
                "layoutHealthAfter": refreshedWorkspace.layoutHealth.rawValue,
                "screenCount": "\(refreshedWorkspace.screens?.count ?? 0)",
                "slotCount": "\(refreshedWorkspace.displaySlots?.count ?? 0)"
            ])
        }
    }

    // MARK: - Screen Mapping Methods

    func restoreWorkspaceWithMapping(workspace: Workspace, screenMappings: [ScreenMapping]) {
        DeskJigLog.debug(.workspace, "Restoring workspace with custom screen mapping", fields: ["workspace": workspace.name])

        // Close the screen mapping UI and navigate back
//        showingScreenMapping = false
//        workspaceForScreenMapping = nil
//        navigationManager.navigateBack()

        // Convert ScreenMapping to tuples for WindowManager
        let mappingTuples = screenMappings.map { mapping in
            (workspaceScreenIndex: mapping.workspaceScreenIndex, currentScreenIndex: mapping.currentScreenIndex)
        }

        Task {
            // Route through WindowManager to ensure missing app callback is wired up
            let result = await windowManager.restoreWorkspaceWithMapping(
                workspace,
                screenMappings: mappingTuples,
                source: "workspace-mapping"
            )
            DeskJigLog.debug(.workspace, "FluentWorkspaceRestorer complete", fields: [
                "success": result.success,
                "restored": result.windowsRestored,
                "failed": result.windowsFailed,
                "skipped": result.windowsSkipped
            ], runId: result.runId)

            presentChromeProfileRemapWarningIfNeeded(workspace: workspace, result: result)
            if !result.success {
                presentRestoreFailureToast(
                    workspace: workspace,
                    result: result,
                    source: "workspace-mapping"
                )
            }
        }
    }

    private func presentRestoreFailureToast(
        workspace: Workspace,
        result: FluentRestorationResult,
        source: String? = nil
    ) {
        let issues = result.evaluation?.issues ?? []
        guard !issues.isEmpty else { return }

        let issueSummary = issues.prefix(2).map { "• \($0)" }.joined(separator: "\n")
        let body = "\(workspace.name): \(issueSummary)"
        let duration: NotificationPresenter.PresentationDuration = result.windowsRestored == 0
            ? .persistent
            : .seconds(8)
        let isQuickSwitchFailure = source == Self.quickSwitchLaunchSource

        NotificationPresenter.present(
            .init(
                isQuickSwitchFailure ? "Quick Switch failed" : "Workspace restore needs attention",
                text: body,
                icon: "exclamationmark.triangle.fill",
                iconColor: isQuickSwitchFailure ? .red : .yellow,
                forceDarkAppearance: true
            ),
            for: duration
        )
    }

    private func presentChromeProfileRemapWarningIfNeeded(
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

    func cancelScreenMapping() {
        workspaceForScreenMapping = nil
        showingScreenMapping = false
    }

    // MARK: - Navigation Helper Methods

    func findSectionContaining(globalIndex: Int) -> TileSection? {
        var currentGlobalIndex = 0

        for section in filteredSections {
            let sectionEndIndex = currentGlobalIndex + section.tiles.count - 1

            if globalIndex >= currentGlobalIndex && globalIndex <= sectionEndIndex {
                return section
            }

            currentGlobalIndex += section.tiles.count
        }

        return nil
    }

    // MARK: - Space Helpers

    /// Check if a process has any windows on the current visible Space
    /// Uses CGWindowListCopyWindowInfo which doesn't activate apps
    private func hasWindowsOnCurrentSpace(processID: pid_t) -> Bool {
        guard let windowListInfo = CGWindowListCopyWindowInfo(
            [.optionAll, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else {
            return false
        }

        for windowInfo in windowListInfo {
            guard let windowPID = windowInfo[kCGWindowOwnerPID as String] as? pid_t,
                  windowPID == processID,
                  let windowLayer = windowInfo[kCGWindowLayer as String] as? Int,
                  let windowNumber = windowInfo[kCGWindowNumber as String] as? Int,
                  windowLayer == 0,
                  let windowBounds = windowInfo[kCGWindowBounds as String] as? [String: Any] else {
                continue
            }

            // Filter out small windows (toolbar, popups, etc.)
            let width = windowBounds["Width"] as? CGFloat ?? 0
            let height = windowBounds["Height"] as? CGFloat ?? 0
            if width <= 64 || height <= 64 {
                continue
            }

            // kCGWindowIsOnscreen indicates if the window is on a currently visible Space
            let isOnScreen = windowInfo[kCGWindowIsOnscreen as String] as? Bool ?? false
            if isOnScreen {
                return true
            }
            let windowID = CGWindowID(windowNumber)
            if SkyLightService.shared.isWindowOnAnyVisibleSpace(windowID: windowID) {
                return true
            }
        }

        return false
    }

    // MARK: - Directory Workspace State

    var directoryWorkspaceBeingEdited: EditingDirectoryWorkspace?

    enum EditingDirectoryWorkspace: Equatable {
        case new
        case existing(DirectoryWorkspace)

        var workspace: DirectoryWorkspace? {
            switch self {
            case .new: return nil
            case .existing(let workspace): return workspace
            }
        }

        var isNew: Bool {
            switch self {
            case .new: return true
            case .existing: return false
            }
        }

        static func == (lhs: EditingDirectoryWorkspace, rhs: EditingDirectoryWorkspace) -> Bool {
            switch (lhs, rhs) {
            case (.new, .new):
                return true
            case (.existing(let lhsWorkspace), .existing(let rhsWorkspace)):
                return lhsWorkspace.id == rhsWorkspace.id
            default:
                return false
            }
        }
    }

    // MARK: - Directory Workspace Methods

    func startCreatingDirectoryWorkspace() {
        DeskJigLog.info(.workspace, "Starting directory workspace creation")
        directoryWorkspaceBeingEdited = .new
        DeskJigLog.info(.workspace, "Directory workspace creation started")
    }

    func editDirectoryWorkspace(_ workspace: DirectoryWorkspace) {
        DeskJigLog.info(.workspace, "Starting directory workspace editing", fields: ["workspace": workspace.name])
        directoryWorkspaceBeingEdited = .existing(workspace)
        closeMainNexusWindow()
        DeskJigLog.info(.workspace, "Directory workspace editor opened")
    }

    func saveDirectoryWorkspace(
        withName name: String,
        andIcon icon: String,
        screenIndices: Set<Int>,
        windows: [WorkspaceWindow],
        screens: [WorkspaceScreen],
        openByPathModifications: [UUID: OpenByPathWindowModification]
    ) {
        DeskJigLog.info(.workspace, "Saving directory workspace", fields: ["name": name, "icon": icon, "windowCount": windows.count])

        // Convert WorkspaceWindows + modifications into DirectoryWorkspace window specs
        // NOTE: UI preview windows are stored as relative frames; DirectoryWorkspace uses position presets.
        // We map relative frames to the closest WindowPosition preset for reliable restoration.
        let existingWorkspace = directoryWorkspaceBeingEdited?.workspace

        var windowSpecs: [WindowSpec] = []

        for (_, window) in windows.enumerated() {
            guard let modification = openByPathModifications[window.id],
                  let directoryPath = modification.openPath else {
                DeskJigLog.warn(.workspace, "Window missing directory path, skipping", fields: ["windowId": window.id.uuidString])
                continue
            }

            let expandedPath = (directoryPath as NSString).expandingTildeInPath
            let position = window.relativeFrame.map { WindowPosition.closest(to: $0) }

            switch window.bundleIdentifier {
            case OpenByPathBundleIdentifiers.cursor:
                var spec = DirectoryApp.cursor().inDirectory(expandedPath)
                if let position {
                    spec = spec.atPosition(position, screen: window.screenIndex)
                } else if let screenIndex = window.screenIndex {
                    spec = spec.onScreen(screenIndex)
                }
                windowSpecs.append(spec)

            case OpenByPathBundleIdentifiers.codex:
                var spec = DirectoryApp.codex().inDirectory(expandedPath)
                if let position {
                    spec = spec.atPosition(position, screen: window.screenIndex)
                } else if let screenIndex = window.screenIndex {
                    spec = spec.onScreen(screenIndex)
                }
                windowSpecs.append(spec)

            case OpenByPathBundleIdentifiers.ghostty:
                var spec = DirectoryApp.ghostty()
                    .withWindowTitle(modification.windowTitle)
                    .inDirectory(expandedPath)

                if let position {
                    spec = spec.atPosition(position, screen: window.screenIndex)
                } else if let screenIndex = window.screenIndex {
                    spec = spec.onScreen(screenIndex)
                }

                windowSpecs.append(spec)

            case OpenByPathBundleIdentifiers.vscode:
                var spec = DirectoryApp.vscode().inDirectory(expandedPath)

                if let position {
                    spec = spec.atPosition(position, screen: window.screenIndex)
                } else if let screenIndex = window.screenIndex {
                    spec = spec.onScreen(screenIndex)
                }

                windowSpecs.append(spec)

            case OpenByPathBundleIdentifiers.terminal:
                var spec = DirectoryApp.terminal().inDirectory(expandedPath)

                if let position {
                    spec = spec.atPosition(position, screen: window.screenIndex)
                } else if let screenIndex = window.screenIndex {
                    spec = spec.onScreen(screenIndex)
                }

                windowSpecs.append(spec)

            case OpenByPathBundleIdentifiers.iterm2:
                var spec = DirectoryApp.iterm().inDirectory(expandedPath)

                if let position {
                    spec = spec.atPosition(position, screen: window.screenIndex)
                } else if let screenIndex = window.screenIndex {
                    spec = spec.onScreen(screenIndex)
                }

                windowSpecs.append(spec)

            default:
                DeskJigLog.warn(.workspace, "Unsupported bundleIdentifier for directory workspace, skipping", fields: ["bundleIdentifier": window.bundleIdentifier])
                continue
            }
        }

        guard !windowSpecs.isEmpty else {
            DeskJigLog.error(.workspace, "No valid directory workspace windows to save")
            return
        }

        do {
            let savedWorkspace: DirectoryWorkspace
            let actionName: String

            if let existingWorkspace {
                savedWorkspace = existingWorkspace
                    .withWindowSpecs(windowSpecs)
                    .withName(name)
                    .withIcon(icon)
                try savedWorkspace.save()
                actionName = "update_directory_workspace"
            } else {
                var builder = DirectoryWorkspace.create(name).withIcon(icon)
                for spec in windowSpecs {
                    builder = builder.add(spec)
                }
                savedWorkspace = try builder.save()
                actionName = "create_directory_workspace"
            }

            DeskJigLog.info(.workspace, "Directory workspace saved", fields: [
                "name": name,
                "windowCount": windowSpecs.count,
                "id": savedWorkspace.id.uuidString,
                "action": actionName
            ])
        } catch {
            DeskJigLog.error(.workspace, "Failed to save DirectoryWorkspace", fields: ["name": name, "error": error.localizedDescription])
            return
        }

        directoryWorkspaceBeingEdited = nil
    }

    func cancelDirectoryWorkspaceEditing() {
        DeskJigLog.info(.workspace, "Cancelling directory workspace editing")
        directoryWorkspaceBeingEdited = nil
    }

    func deleteDirectoryWorkspace(_ workspace: DirectoryWorkspace) {
        DeskJigLog.info(.workspace, "Deleting directory workspace", fields: ["workspace": workspace.name])

        do {
            try workspace.delete()
        } catch {
            DeskJigLog.error(.workspace, "Failed to delete DirectoryWorkspace", fields: ["workspace": workspace.name, "error": error.localizedDescription])
        }
        directoryWorkspaceBeingEdited = nil

        DeskJigLog.info(.workspace, "Directory workspace deleted: \(workspace.name)", fields: [
            "workspace_id": workspace.id.uuidString,
            "action": "delete_directory_workspace"
        ])
    }

    func openDirectoryWorkspace(named workspaceName: String) {
        guard let workspace = DirectoryWorkspace.named(workspaceName) else {
            DeskJigLog.error(.workspace, "Could not find directory workspace", fields: ["workspaceName": workspaceName])
            return
        }

        openDirectoryWorkspace(workspace)
    }

    func openDirectoryWorkspace(_ workspace: DirectoryWorkspace, persist: Bool = true, hideAllApps: Bool? = nil) {
        DeskJigLog.debug(.workspace, "Opening directory workspace", fields: ["workspace": workspace.name])

        let launchID = UUID()
        windowManager.displayManager.refreshScreens()
        let runtimeScreens = WorkspaceDisplayTopology.effectiveScreens(from: windowManager.displayManager).map {
            WorkspaceScreen(from: $0)
        }
        let runtimeSnapshot = workspace.toWorkspace(screens: runtimeScreens)
        windowManager.workspaceManagerService.recordRuntimeRestoredWorkspaceSnapshot(runtimeSnapshot)

        // Show overlay first
        presentLaunchLoaderOverlay(forWorkspace: workspace.name, withLaunchID: launchID)

        // Use simple Task pattern (matches CLI behavior) - no extra DispatchQueue layer
        // The nested DispatchQueue.global().async { Task { ... } } was causing timing issues
        // where Ghostty config files weren't being read reliably
        let launchTask: Task<Void, Error> = Task { [weak self] in
            let logger: ((String) -> Void) = { message in
                DeskJigLog.debug(.workspace, "DW-Restore: \(message)")
            }

            let isMainThread = await MainActor.run { Thread.isMainThread }
            DeskJigLog.debug(.workspace, "DW-Restore: Task starting", fields: ["isMainThread": isMainThread])

            do {
                let result = try await workspace.restore(persist: persist, hideAllApps: hideAllApps, logger: logger, onProgress: { progress in
                    // Reset watchdog on progress to prevent timeout during slow operations
                    Task { @MainActor in
                        self?.presentedWorkspaceLaunchOverlay?.resetWatchdog()
                    }
                })

                await MainActor.run {
                    self?.hideWorkspaceLaunchLoaderOverlay(reason: "restore-complete")

                    if result.failedCount == 0 {
                        DeskJigLog.debug(.workspace, "Directory workspace restored", fields: [
                            "workspace": workspace.name,
                            "windows": result.successCount
                        ])
                    } else if result.successCount > 0 {
                        DeskJigLog.warn(.workspace, "Directory workspace partially restored", fields: [
                            "workspace": workspace.name,
                            "succeeded": result.successCount,
                            "failed": result.failedCount
                        ])
                    } else {
                        let reasons = result.failures.map { $0.error.localizedDescription }.joined(separator: ", ")
                        DeskJigLog.error(.workspace, "Directory workspace restoration failed", fields: [
                            "workspace": workspace.name,
                            "reasons": reasons
                        ])
                    }

                    if self?.workspaceLaunchTask?.id == launchID {
                        self?.workspaceLaunchTask = nil
                    }
                    self?.closeMainNexusWindow()
                }
            } catch {
                await MainActor.run {
                    self?.hideWorkspaceLaunchLoaderOverlay(reason: "restore-error")
                    DeskJigLog.error(.workspace, "Directory workspace restoration error", fields: [
                        "workspace": workspace.name,
                        "error": error.localizedDescription
                    ])
                    if self?.workspaceLaunchTask?.id == launchID {
                        self?.workspaceLaunchTask = nil
                    }
                }
                throw error
            }
        }

        // Track the task so watchdog can cancel it properly
        self.workspaceLaunchTask = (launchID, launchTask)
    }
}
