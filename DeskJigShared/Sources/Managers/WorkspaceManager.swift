//
//  WorkspaceManager.swift
//  DeskJigShared
//
//  Created by Marco Freedom on 02.09.2025.
//

import Foundation
import Cocoa
import Combine

// MARK: - Workspace Change Events

/// Events emitted when workspace state changes, for reactive UI updates
public enum WorkspaceChangeEvent: Sendable {
    case created(Workspace)
    case deleted(Workspace)
    case renamed(Workspace, oldName: String)
    case updated(Workspace)
    case duplicated(Workspace, original: Workspace)
}

public class WorkspaceManager: ObservableObject {
    @Published public var savedWorkspaces: [Workspace] = []
    
    private let storageService: WorkspaceStorageService
    private let captureService: WorkspaceCaptureService

    private var applicationManager: ApplicationManagerProtocol?
    private var windowLayoutManager: WindowLayoutManager?
    private var overlayWindowManager: OverlayWindowManager?
    private var folderTabCoordinator: FolderTabCoordinator?
    private let displayManager: DisplayManager

    /// Callback invoked when a missing/deleted app is detected during workspace restoration.
    /// Called on MainActor with (appName, bundleId). Set by main app for toast notifications.
    public var onMissingAppDetected: (@MainActor @Sendable (String, String) -> Void)?

    /// Publisher for workspace change events (creation, deletion, rename, update, duplicate)
    /// Subscribe to this for reactive UI updates when workspaces change
    public let workspaceChangesPublisher = PassthroughSubject<WorkspaceChangeEvent, Never>()

    /// Current restoration run ID for tracking/grepping logs (e.g., "restore_abc123")
    /// Set at the start of each workspace restoration and accessible by handlers
    public static var currentRestoreRunId: String?

    /// The most recently launched workspace ID in this app session.
    /// This is runtime-only state used by UI affordances like quick-switch go-back.
    public private(set) var lastRestoredWorkspaceID: UUID?

    /// The most recently launched workspace payload in this app session.
    /// This captures runtime-transformed payloads (for example quick-switch rewritten open paths).
    public private(set) var lastRestoredWorkspaceSnapshot: Workspace?

    /// The workspace payload launched immediately before `lastRestoredWorkspaceSnapshot`.
    public private(set) var previousRestoredWorkspaceSnapshot: Workspace?

    /// Initialize WorkspaceManager with optional injected handlers for testing
    public init(
        displayManager: DisplayManager
    ) {
        self.displayManager = displayManager
        
        self.storageService = WorkspaceStorageService()
        self.captureService = WorkspaceCaptureService(
            displayManager: displayManager
        )
        self.savedWorkspaces = storageService.loadWorkspaces()
    }

    public func setApplicationManager(_ applicationManager: ApplicationManagerProtocol) {
        self.applicationManager = applicationManager
    }

    public func setOverlayWindowManager(_ overlayWindowManager: OverlayWindowManager) {
        self.overlayWindowManager = overlayWindowManager
    }

    public func setWindowLayoutManager(_ windowLayoutManager: WindowLayoutManager) {
        self.windowLayoutManager = windowLayoutManager
    }

    public func setFolderTabCoordinator(_ folderTabCoordinator: FolderTabCoordinator) {
        self.folderTabCoordinator = folderTabCoordinator
    }

    // MARK: - Workspace Management

    @MainActor
    private func loadWorkspaces() {
        savedWorkspaces = storageService.loadWorkspaces()
        migrateDirectoryWorkspacesIfNeeded()
    }

    private func saveWorkspaces() {
        storageService.saveWorkspaces(savedWorkspaces)
    }

    /// Saves local-only metadata like activation time.
    private func saveWorkspacesLocalOnly() {
        storageService.saveToLocalCacheOnly(savedWorkspaces)
    }

    @MainActor
    public func reloadWorkspaces() {
        DeskJigLog.info(.workspace, "Reloading workspaces from UserDefaults")
        loadWorkspaces()
    }

    @MainActor
    private func migrateDirectoryWorkspacesIfNeeded() {
        if let migrated = storageService.migrateDirectoryWorkspacesIfNeeded(
            currentWorkspaces: savedWorkspaces,
            captureScreens: { [weak self] in self?.captureScreens() ?? [] }
        ) {
            savedWorkspaces = migrated
        }
    }

    private func captureScreens() -> [WorkspaceScreen] {
        return captureService.captureScreens()
    }

    public func getBundleIDsForScreens(screenIndices: Set<Int> = [], currentWindows: [WindowInfo]? = nil) async -> (bundleIDs: Set<String>, windows: [WindowInfo]) {
        return await captureService.getBundleIDsForScreens(
            screenIndices: screenIndices,
            currentWindows: currentWindows,
            overlayWindowManager: overlayWindowManager
        )
    }

    public func captureCurrentWindows(
        selectiveMode: Bool = false,
        screenIndices: Set<Int> = [],
        currentWindows: [WindowInfo]? = nil,
        minVisibilityOverride: Double? = nil,
        skipSupplementation: Bool = false
    ) async -> (windows: [WorkspaceWindow], screens: [WorkspaceScreen]) {
        return await captureService.captureCurrentWindows(
            selectiveMode: selectiveMode,
            screenIndices: screenIndices,
            currentWindows: currentWindows,
            applicationManager: applicationManager,
            overlayWindowManager: overlayWindowManager,
            minVisibilityOverride: minVisibilityOverride,
            skipSupplementation: skipSupplementation
        )
    }

    /// Resolves the captured screens a selective capture should persist.
    ///
    /// #566 writer guard: a stale `screenIndices` filter (indices captured under
    /// a previous monitor topology) can match zero screens, which used to
    /// persist a workspace with an empty `screens` array and no `displaySlots` -
    /// a document that later fails restore normalization with "has no display
    /// slot geometry". Rather than writing a geometry-less workspace, fall back
    /// to persisting every captured screen.
    private func resolveRelevantCapturedScreens(
        captured: [WorkspaceScreen],
        screenIndices: Set<Int>,
        context: String
    ) -> [(offset: Int, element: WorkspaceScreen)] {
        let filtered = Array(captured.enumerated())
            .filter { screenIndices.isEmpty || screenIndices.contains($0.offset) }

        guard filtered.isEmpty, !captured.isEmpty else {
            if captured.isEmpty {
                DeskJigLog.error(.workspace, "Capture returned no screens - workspace will be persisted without display geometry", fields: [
                    "context": context
                ])
            }
            return filtered
        }

        DeskJigLog.warn(.workspace, "Selective capture screen filter matched no screens - persisting all captured screens to preserve display geometry", fields: [
            "context": context,
            "requestedIndices": screenIndices.sorted().map(String.init).joined(separator: ","),
            "capturedScreenCount": "\(captured.count)"
        ])
        return Array(captured.enumerated())
    }

    public func saveCurrentWorkspace(
        id: Workspace.ID = UUID(),
        name: String,
        icon: String?,
        selectiveMode: Bool = false,
        screenIndices: Set<Int> = [],
        minVisibilityOverride: Double? = nil,
        chromeModifications: [UUID: ChromeModification] = [:],
        openByPathModifications: [UUID: OpenByPathModification] = [:]
    ) async {
        let captured = await captureCurrentWindows(
            selectiveMode: selectiveMode,
            screenIndices: screenIndices,
            minVisibilityOverride: minVisibilityOverride
        )

        let relevantScreensWithIndices = resolveRelevantCapturedScreens(
            captured: captured.screens,
            screenIndices: screenIndices,
            context: "saveCurrentWorkspace"
        )

        let relevantScreens = relevantScreensWithIndices.map { $0.element }

        var screenIndexMapping: [Int: Int] = [:]
        for (newIndex, (oldIndex, _)) in relevantScreensWithIndices.enumerated() {
            screenIndexMapping[oldIndex] = newIndex
        }

        var appliedModificationIds = Set<UUID>()
        var appliedOpenByPathModificationIds = Set<UUID>()
        let previousWorkspace = await MainActor.run {
            savedWorkspaces.first(where: { $0.id == id })
        }

        let remappedWindows = captured.windows.map { window -> WorkspaceWindow in
            var updatedWindow = window
            
            if let oldScreenIndex = window.screenIndex,
               let newScreenIndex = screenIndexMapping[oldScreenIndex] {
                updatedWindow = updatedWindow.withScreenMapping(screenIndex: newScreenIndex)
            }
            
            var modification: ChromeModification? = chromeModifications[window.id]
            var matchedModificationId: UUID? = modification != nil ? window.id : nil
            
            if modification == nil && chromeBundleIdentifiers.contains(window.bundleIdentifier) {
                if let (modId, chromeModification) = chromeModifications.first(where: { !appliedModificationIds.contains($0.key) }) {
                    modification = chromeModification
                    matchedModificationId = modId
                }
            }
            
            if let modification = modification, let matchedId = matchedModificationId {
                appliedModificationIds.insert(matchedId)
                let isAnyWindow = modification.profileMatchMode == .anyWindow
                let hasActiveProfileSelection = isAnyWindow || modification.profileDirectory != nil

                let newChromeState = ChromeWindowState(
                    profileDirectory: isAnyWindow ? "" : (modification.profileDirectory ?? window.chromeState?.profileDirectory ?? ""),
                    profileDisplayName: isAnyWindow ? "" : (modification.profileDisplayName ?? window.chromeState?.profileDisplayName ?? ""),
                    profileHostedDomain: isAnyWindow ? nil : (hasActiveProfileSelection ? modification.profileHostedDomain : (modification.profileHostedDomain ?? window.chromeState?.profileHostedDomain)),
                    profileUserName: isAnyWindow ? nil : (hasActiveProfileSelection ? modification.profileUserName : (modification.profileUserName ?? window.chromeState?.profileUserName)),
                    profileMatchMode: modification.profileMatchMode,
                    shouldRestoreTabs: !modification.tabURLs.isEmpty,
                    savedTabURLs: modification.tabURLs,
                    focusedTabIndex: window.chromeState?.focusedTabIndex,
                    chromeWindowId: window.chromeState?.chromeWindowId
                )
                updatedWindow = updatedWindow.withChromeState(newChromeState)
            } else if chromeBundleIdentifiers.contains(window.bundleIdentifier) {
                updatedWindow = updatedWindow.withChromeState(nil)
            }

            if OpenByPathBundleIdentifiers.supported.contains(window.bundleIdentifier) {
                var modification: OpenByPathModification? = openByPathModifications[window.id]
                var matchedModificationId: UUID? = modification != nil ? window.id : nil

                if modification == nil && !openByPathModifications.isEmpty {
                    let candidates = openByPathModifications
                        .filter { candidateId, candidate in
                            !appliedOpenByPathModificationIds.contains(candidateId) &&
                            candidate.bundleIdentifier == window.bundleIdentifier
                        }
                        .sorted { $0.key.uuidString < $1.key.uuidString }

                    if let exact = candidates.first(where: { ($0.value.windowTitle).trimmingCharacters(in: .whitespacesAndNewlines) == (window.windowTitle).trimmingCharacters(in: .whitespacesAndNewlines) }) {
                        modification = exact.value
                        matchedModificationId = exact.key
                    } else if let first = candidates.first {
                        modification = first.value
                        matchedModificationId = first.key
                    }
                }

                if let modification, let matchedId = matchedModificationId {
                    appliedOpenByPathModificationIds.insert(matchedId)
                    let path = self.normalizeOpenPath(modification.openPath)
                    updatedWindow = updatedWindow.withOpenPath(path)
                }
            }
            
            return updatedWindow
        }

        let terminalKeyWindows = preserveGhosttyTerminalKeys(
            in: remappedWindows,
            previousWorkspace: previousWorkspace
        )
        let titledWindows = OpenByPathTitleAssigner.apply(to: terminalKeyWindows)

        let workspace = Workspace(
            id: id,
            name: name,
            icon: icon,
            workspaceWindows: titledWindows,
            screens: relevantScreens
        )
        let updatedWorkspaces = await MainActor.run {
            var workspaces = savedWorkspaces
            workspaces.append(workspace)
            savedWorkspaces = workspaces

            // Emit change event for reactive UI updates
            workspaceChangesPublisher.send(.created(workspace))
            return workspaces
        }

        storageService.saveWorkspaces(updatedWorkspaces)
    }

    /// Save a pre-built workspace directly (used by wizard)
    @MainActor
    public func saveWorkspace(_ workspace: Workspace) {
        savedWorkspaces.append(workspace)
        saveWorkspaces()

        workspaceChangesPublisher.send(.created(workspace))
        DeskJigLog.info(.workspace, "Saved workspace '\(workspace.name)' with \(workspace.windows.count) windows")
    }

    @MainActor
    public func updateWorkspaceMetadata(
        for workspace: Workspace,
        newName: String,
        newIcon: String,
        chromeModifications: [UUID: ChromeModification] = [:],
        openByPathModifications: [UUID: OpenByPathModification] = [:]
    ) {
        let oldName = workspace.name
        savedWorkspaces = storageService.updateWorkspaceMetadata(
            workspaces: savedWorkspaces,
            workspace: workspace,
            newName: newName,
            newIcon: newIcon,
            chromeModifications: chromeModifications,
            openByPathModifications: openByPathModifications,
            normalizeOpenPath: { [weak self] in self?.normalizeOpenPath($0) }
        )

        // Emit change event for reactive UI updates
        if let updatedWorkspace = savedWorkspaces.first(where: { $0.id == workspace.id }) {
            if oldName != newName {
                workspaceChangesPublisher.send(.renamed(updatedWorkspace, oldName: oldName))
            } else {
                workspaceChangesPublisher.send(.updated(updatedWorkspace))
            }
        }
    }

    @MainActor
    public func updateWorkspaceLayout(
        for workspace: Workspace,
        newName: String,
        newIcon: String,
        windows: [WorkspaceWindow],
        screens: [WorkspaceScreen]?,
        displaySlots: [WorkspaceDisplaySlot]? = nil
    ) {
        guard let index = savedWorkspaces.firstIndex(where: { $0.id == workspace.id }) else {
            DeskJigLog.warn(.workspace, "Cannot update layout - workspace '\(workspace.name)' not found")
            return
        }

        let normalizedWindows = windows.map { window in
            let normalizedPath = normalizeOpenPath(window.openPath)
            return window.withOpenPath(normalizedPath)
        }

        let titledWindows = OpenByPathTitleAssigner.apply(to: normalizedWindows)
        let oldName = workspace.name
        let updatedWorkspace = workspace.withUpdatedLayout(
            newName: newName,
            newIcon: newIcon,
            windows: titledWindows,
            screens: screens,
            displaySlots: displaySlots
        )

        savedWorkspaces[index] = updatedWorkspace
        saveWorkspaces()

        if oldName != newName {
            workspaceChangesPublisher.send(.renamed(updatedWorkspace, oldName: oldName))
        } else {
            workspaceChangesPublisher.send(.updated(updatedWorkspace))
        }
    }

    @MainActor
    public func updateWorkspaceDisplayMetadata(
        for workspace: Workspace,
        screens: [WorkspaceScreen],
        displaySlots: [WorkspaceDisplaySlot]
    ) {
        savedWorkspaces = storageService.updateWorkspaceDisplayMetadata(
            workspaces: savedWorkspaces,
            workspaceID: workspace.id,
            screens: screens,
            displaySlots: displaySlots
        )

        if let updatedWorkspace = savedWorkspaces.first(where: { $0.id == workspace.id }) {
            workspaceChangesPublisher.send(.updated(updatedWorkspace))
        }
    }

    public func updateWorkspaceWindows(
        for workspace: Workspace,
        screenIndices: Set<Int> = [],
        minVisibilityOverride: Double? = nil,
        chromeModifications: [UUID: ChromeModification] = [:],
        openByPathModifications: [UUID: OpenByPathModification] = [:]
    ) async {
        let captured = await captureCurrentWindows(
            screenIndices: screenIndices,
            minVisibilityOverride: minVisibilityOverride
        )

        let relevantScreensWithIndices = resolveRelevantCapturedScreens(
            captured: captured.screens,
            screenIndices: screenIndices,
            context: "updateWorkspaceWindows"
        )

        let relevantScreens = relevantScreensWithIndices.map { $0.element }

        var screenIndexMapping: [Int: Int] = [:]
        for (newIndex, (oldIndex, _)) in relevantScreensWithIndices.enumerated() {
            screenIndexMapping[oldIndex] = newIndex
        }

        var appliedOpenByPathModificationIds = Set<UUID>()
        var appliedChromeModificationIds = Set<UUID>()

        var remainingSavedChromeWindows = workspace.windows.filter {
            chromeBundleIdentifiers.contains($0.bundleIdentifier)
        }

        func takeSavedChromeWindow(for window: WorkspaceWindow) -> WorkspaceWindow? {
            guard !remainingSavedChromeWindows.isEmpty else { return nil }

            if window.chromeState?.profileMatchMode == .anyWindow {
                if let index = remainingSavedChromeWindows.firstIndex(where: { $0.chromeState?.profileMatchMode == .anyWindow }) {
                    return remainingSavedChromeWindows.remove(at: index)
                }
            }

            if let profileDirectory = window.chromeState?.profileDirectory, !profileDirectory.isEmpty {
                if let index = remainingSavedChromeWindows.firstIndex(where: { $0.chromeState?.profileDirectory == profileDirectory }) {
                    return remainingSavedChromeWindows.remove(at: index)
                }
            }

            let normalizedWindowTitle = (window.windowTitle).trimmingCharacters(in: .whitespacesAndNewlines)
            if let index = remainingSavedChromeWindows.firstIndex(where: { ($0.windowTitle).trimmingCharacters(in: .whitespacesAndNewlines) == normalizedWindowTitle }) {
                return remainingSavedChromeWindows.remove(at: index)
            }

            if remainingSavedChromeWindows.count == 1 {
                return remainingSavedChromeWindows.removeFirst()
            }

            return nil
        }

        let remappedWindows = captured.windows.map { window -> WorkspaceWindow in
            var updatedWindow = window
            
            if let oldScreenIndex = window.screenIndex,
               let newScreenIndex = screenIndexMapping[oldScreenIndex] {
                updatedWindow = updatedWindow.withScreenMapping(screenIndex: newScreenIndex)
            }
            
            var chromeModification: ChromeModification? = chromeModifications[window.id]
            var matchedChromeModificationId: UUID? = chromeModification != nil ? window.id : nil

            if chromeModification == nil && chromeBundleIdentifiers.contains(window.bundleIdentifier) {
                let windowMatchMode = window.chromeState?.profileMatchMode ?? .specific
                if windowMatchMode == .anyWindow {
                    if let match = chromeModifications.first(where: {
                        !appliedChromeModificationIds.contains($0.key) &&
                            $0.value.profileMatchMode == .anyWindow
                    }) {
                        chromeModification = match.value
                        matchedChromeModificationId = match.key
                    }
                } else if let profileDirectory = window.chromeState?.profileDirectory {
                    if let match = chromeModifications.first(where: {
                        !appliedChromeModificationIds.contains($0.key) &&
                            $0.value.profileDirectory == profileDirectory
                    }) {
                        chromeModification = match.value
                        matchedChromeModificationId = match.key
                    }
                }

                if chromeModification == nil {
                    let remaining = chromeModifications.filter { !appliedChromeModificationIds.contains($0.key) }
                    if remaining.count == 1, let match = remaining.first {
                        chromeModification = match.value
                        matchedChromeModificationId = match.key
                    }
                }
            }

            if let modification = chromeModification, let matchedId = matchedChromeModificationId {
                appliedChromeModificationIds.insert(matchedId)
                let isAnyWindow = modification.profileMatchMode == .anyWindow
                let hasActiveProfileSelection = isAnyWindow || modification.profileDirectory != nil

                let newChromeState = ChromeWindowState(
                    profileDirectory: isAnyWindow ? "" : (modification.profileDirectory ?? window.chromeState?.profileDirectory ?? ""),
                    profileDisplayName: isAnyWindow ? "" : (modification.profileDisplayName ?? window.chromeState?.profileDisplayName ?? ""),
                    profileHostedDomain: isAnyWindow ? nil : (hasActiveProfileSelection ? modification.profileHostedDomain : (modification.profileHostedDomain ?? window.chromeState?.profileHostedDomain)),
                    profileUserName: isAnyWindow ? nil : (hasActiveProfileSelection ? modification.profileUserName : (modification.profileUserName ?? window.chromeState?.profileUserName)),
                    profileMatchMode: modification.profileMatchMode,
                    shouldRestoreTabs: !modification.tabURLs.isEmpty,
                    savedTabURLs: modification.tabURLs,
                    focusedTabIndex: window.chromeState?.focusedTabIndex,
                    chromeWindowId: window.chromeState?.chromeWindowId
                )
                updatedWindow = updatedWindow.withChromeState(newChromeState)
            } else if chromeBundleIdentifiers.contains(window.bundleIdentifier) {
                if let savedWindow = takeSavedChromeWindow(for: window), let savedChromeState = savedWindow.chromeState {
                    updatedWindow = updatedWindow.withChromeState(savedChromeState)
                } else {
                    updatedWindow = updatedWindow.withChromeState(nil)
                }
            }

            if OpenByPathBundleIdentifiers.supported.contains(window.bundleIdentifier) {
                var modification: OpenByPathModification? = openByPathModifications[window.id]
                var matchedModificationId: UUID? = modification != nil ? window.id : nil

                if modification == nil && !openByPathModifications.isEmpty {
                    let candidates = openByPathModifications
                        .filter { candidateId, candidate in
                            !appliedOpenByPathModificationIds.contains(candidateId) &&
                            candidate.bundleIdentifier == window.bundleIdentifier
                        }
                        .sorted { $0.key.uuidString < $1.key.uuidString }

                    if let exact = candidates.first(where: { ($0.value.windowTitle).trimmingCharacters(in: .whitespacesAndNewlines) == (window.windowTitle).trimmingCharacters(in: .whitespacesAndNewlines) }) {
                        modification = exact.value
                        matchedModificationId = exact.key
                    } else if let first = candidates.first {
                        modification = first.value
                        matchedModificationId = first.key
                    }
                }

                if let modification, let matchedId = matchedModificationId {
                    appliedOpenByPathModificationIds.insert(matchedId)
                    updatedWindow = updatedWindow.withOpenPath(self.normalizeOpenPath(modification.openPath))
                }
            }
            
            return updatedWindow
        }

        let terminalKeyWindows = preserveGhosttyTerminalKeys(
            in: remappedWindows,
            previousWorkspace: workspace
        )
        let titledWindows = OpenByPathTitleAssigner.apply(to: terminalKeyWindows)

        let updatedWorkspace = Workspace(
            id: workspace.id,
            name: workspace.name,
            icon: workspace.icon,
            workspaceWindows: titledWindows,
            screens: relevantScreens
        )
        let updatedWorkspaces = await MainActor.run {
            if let index = savedWorkspaces.firstIndex(where: {$0.id == workspace.id}) {
                savedWorkspaces[index] = updatedWorkspace
            } else {
                savedWorkspaces.append(updatedWorkspace)
            }
            return savedWorkspaces
        }

        storageService.saveWorkspaces(updatedWorkspaces)
    }

    @MainActor
    public func deleteWorkspace(_ workspace: Workspace) {
        savedWorkspaces = storageService.deleteWorkspace(savedWorkspaces, workspace: workspace)

        // Emit change event for reactive UI updates
        workspaceChangesPublisher.send(.deleted(workspace))

        cleanupTmuxSessions(for: workspace)
    }

    /// Fire-and-forget kill of the deleted workspace's tmux sessions so they
    /// don't outlive it on the socket. Only runs when the user has tmux fast
    /// switching enabled and tmux is actually installed.
    private func cleanupTmuxSessions(for workspace: Workspace) {
        guard UserDefaults.standard.bool(forKey: "tmuxEnabled") else { return }

        Task.detached(priority: .utility) {
            let commandService = TmuxCommandService()
            guard await commandService.isAvailable else { return }

            let runId = "delete-\(workspace.id.uuidString.prefix(8))"
            DeskJigLog.info(.tmux, "Cleaning up tmux sessions for deleted workspace", fields: [
                "workspaceId": workspace.id.uuidString,
                "workspaceName": workspace.name
            ], runId: runId)
            await TmuxSessionManager(commandService: commandService)
                .cleanupWorkspaceSessions(workspaceId: workspace.id.uuidString, runId: runId)
        }
    }

    @MainActor
    public func renameWorkspace(_ workspace: Workspace, newName: String) {
        let oldName = workspace.name
        savedWorkspaces = storageService.renameWorkspace(savedWorkspaces, workspace: workspace, newName: newName)

        // Emit change event for reactive UI updates
        if let updatedWorkspace = savedWorkspaces.first(where: { $0.id == workspace.id }) {
            workspaceChangesPublisher.send(.renamed(updatedWorkspace, oldName: oldName))
        }
    }

    /// Toggle the favorite status of a workspace
    @MainActor
    public func toggleFavorite(_ workspace: Workspace) {
        guard let index = savedWorkspaces.firstIndex(where: { $0.id == workspace.id }) else {
            DeskJigLog.warn(.workspace, "Cannot toggle favorite - workspace '\(workspace.name)' not found")
            return
        }

        let updatedWorkspace = workspace.withFavoriteToggled()
        savedWorkspaces[index] = updatedWorkspace
        saveWorkspaces()

        // Emit change event for reactive UI updates
        workspaceChangesPublisher.send(.updated(updatedWorkspace))

        DeskJigLog.info(.workspace, "Toggled favorite for workspace '\(workspace.name)' to \(updatedWorkspace.isFavorite)")
    }

    @MainActor
    public func updateWindow(in workspace: Workspace, updatedWindow: WorkspaceWindow) {
        if let index = savedWorkspaces.firstIndex(where: { $0.id == workspace.id }) {
            savedWorkspaces[index] = workspace.withUpdatedWindow(updatedWindow)
            saveWorkspaces()
            DeskJigLog.info(.workspace, "Updated window '\(updatedWindow.windowTitle)' in workspace '\(workspace.name)'")
        }
    }

    /// Duplicate a workspace with a new name
    /// - Parameters:
    ///   - workspace: The workspace to duplicate
    ///   - newName: Name for the duplicate
    /// - Returns: The duplicated workspace, or nil if duplication failed
    @MainActor
    @discardableResult
    public func duplicateWorkspace(_ workspace: Workspace, newName: String) -> Workspace? {
        let duplicate = Workspace(
            id: UUID(),
            name: newName,
            icon: workspace.icon,
            keyboardShortcut: nil,  // Don't copy keyboard shortcut
            workspaceWindows: workspace.windows,
            displaySlots: workspace.displaySlots,
            screens: workspace.screens
        )

        savedWorkspaces.append(duplicate)
        saveWorkspaces()

        // Emit change event for reactive UI updates
        workspaceChangesPublisher.send(.duplicated(duplicate, original: workspace))

        DeskJigLog.info(.workspace, "Duplicated workspace '\(workspace.name)' as '\(newName)'")
        return duplicate
    }

    private func updateWorkspaceActivationTime(_ workspace: Workspace) {
        let updateBlock = {
            if let index = self.savedWorkspaces.firstIndex(where: { $0.id == workspace.id }) {
                // Update activation metadata on the persisted workspace entry only.
                // This avoids writing any transient runtime payload changes (e.g. Quick Switch path rewrites)
                // back into saved workspace definitions.
                self.savedWorkspaces[index] = self.savedWorkspaces[index].withActivationTime(Date())
                // Activation time is device-local state.
                self.saveWorkspacesLocalOnly()
                DeskJigLog.info(.workspace, "Updated activation time for workspace '\(workspace.name)'")
            }
        }

        if Thread.isMainThread {
            updateBlock()
        } else {
            DispatchQueue.main.async {
                updateBlock()
            }
        }
    }

    private func markLastRestoredWorkspace(_ workspace: Workspace) {
        let updateBlock = {
            self.previousRestoredWorkspaceSnapshot = self.lastRestoredWorkspaceSnapshot
            self.lastRestoredWorkspaceSnapshot = workspace
            self.lastRestoredWorkspaceID = workspace.id
        }

        if Thread.isMainThread {
            updateBlock()
        } else {
            DispatchQueue.main.async {
                updateBlock()
            }
        }
    }

    /// Updates runtime-only "last/previous restored" snapshots for this app session.
    /// Use this when a restore path does not flow through `restoreFluentWorkspace`.
    @MainActor
    public func recordRuntimeRestoredWorkspaceSnapshot(_ workspace: Workspace) {
        markLastRestoredWorkspace(workspace)
    }

    public func restoreWindows(
        _ windows: [WorkspaceWindow],
        options: RestorationOptions = .default,
        onRestore: (() -> Void)? = nil,
        onFailure: ((WorkspaceWindow, String?) -> Void)? = nil
    ) async -> FluentRestorationResult {
        DeskJigLog.debug(.workspace, "Starting restoration for \(windows.count) individual window(s)")
        logRestoreCallStack("WorkspaceManager.restoreWindows windows=\(windows.count)")
        displayManager.refreshScreens()
        let screens = WorkspaceDisplayTopology.effectiveScreens(from: displayManager).map { WorkspaceScreen(from: $0) }
        let workspace = Workspace(
            name: "AdHoc Restore",
            workspaceWindows: windows,
            screens: screens
        )

        return await restoreFluentWorkspace(
            workspace,
            displayAssignments: [],
            screenMappings: [],
            options: options,
            onRestore: onRestore,
            onFailure: onFailure
        )
    }

    public func restoreWorkspace(
        _ workspace: Workspace,
        options: RestorationOptions = .default,
        source: String = "unknown",
        onRestore: (() -> Void)? = nil,
        onFailure: ((WorkspaceWindow, String?) -> Void)? = nil
    ) async -> FluentRestorationResult {
        let effectiveOptions = options.launchSource == "unknown"
            ? options.withLaunchSource(source)
            : options
        let result = await restoreFluentWorkspace(
            workspace,
            displayAssignments: [],
            screenMappings: [],
            options: effectiveOptions,
            onRestore: onRestore,
            onFailure: onFailure
        )

        return result
    }

    public func restoreWorkspaceWithMapping(
        _ workspace: Workspace,
        screenMappings: [(workspaceScreenIndex: Int, currentScreenIndex: Int)],
        options: RestorationOptions = .default,
        source: String = "unknown",
        onRestore: (() -> Void)? = nil,
        onFailure: ((WorkspaceWindow, String?) -> Void)? = nil
    ) async -> FluentRestorationResult {
        DeskJigLog.debug(.workspace, "Starting workspace restoration with custom screen mapping for '\(workspace.name)'")
        logRestoreCallStack("WorkspaceManager.restoreWorkspaceWithMapping name=\(workspace.name)")
        let effectiveOptions = options.launchSource == "unknown"
            ? options.withLaunchSource(source)
            : options

        displayManager.refreshScreens()
        let currentScreens = WorkspaceDisplayTopology.effectiveScreens(from: displayManager)
        let normalizedWorkspace: Workspace
        do {
            // Restore path: synthesize placeholder slots for workspaces persisted
            // without display geometry (GH #566) instead of failing outright.
            normalizedWorkspace = try WorkspaceDisplayResolutionService.normalizeWorkspace(
                workspace,
                repairPolicy: .synthesizeMissingGeometry
            )
        } catch {
            DeskJigLog.error(.workspace, "Failed to normalize workspace '\(workspace.name)' for slot assignments: \(error.localizedDescription)", fields: [
                "source": source,
                "hasDisplayMetadata": workspace.hasSavedDisplayMetadata.description,
                "isFlattenedDisplayMetadata": workspace.isDisplayMetadataFlattened.description
            ])
            return failureResult(
                for: workspace,
                runId: Self.currentRestoreRunId ?? FluentWorkspaceRestorer.makeRunId(),
                errorMessage: error.localizedDescription
            )
        }
        guard let orderedSlots = normalizedWorkspace.displaySlots, !orderedSlots.isEmpty else {
            DeskJigLog.debug(.workspace, "Workspace has no display slots after normalization, falling back to normal restoration")
            return await restoreWorkspace(
                workspace,
                options: effectiveOptions,
                source: source,
                onRestore: onRestore,
                onFailure: onFailure
            )
        }

        let displayAssignments: [WorkspaceDisplayAssignment] = screenMappings.compactMap { mapping in
            guard orderedSlots.indices.contains(mapping.workspaceScreenIndex),
                  currentScreens.indices.contains(mapping.currentScreenIndex) else {
                return nil
            }
            return WorkspaceDisplayAssignment(
                slotID: orderedSlots[mapping.workspaceScreenIndex].id,
                displayID: currentScreens[mapping.currentScreenIndex].displayID
            )
        }

        let result = await restoreFluentWorkspace(
            normalizedWorkspace,
            displayAssignments: displayAssignments,
            screenMappings: [],
            options: effectiveOptions,
            onRestore: onRestore,
            onFailure: onFailure,
            currentScreens: currentScreens
        )

        return result
    }

    public func restoreWorkspaceWithDisplayAssignments(
        _ workspace: Workspace,
        displayAssignments: [WorkspaceDisplayAssignment],
        options: RestorationOptions = .default,
        source: String = "unknown",
        onRestore: (() -> Void)? = nil,
        onFailure: ((WorkspaceWindow, String?) -> Void)? = nil
    ) async -> FluentRestorationResult {
        let effectiveOptions = options.launchSource == "unknown"
            ? options.withLaunchSource(source)
            : options
        return await restoreFluentWorkspace(
            workspace,
            displayAssignments: displayAssignments,
            screenMappings: [],
            options: effectiveOptions,
            onRestore: onRestore,
            onFailure: onFailure
        )
    }

    private func restoreFluentWorkspace(
        _ workspace: Workspace,
        displayAssignments: [WorkspaceDisplayAssignment],
        screenMappings: [(workspaceScreenIndex: Int, currentScreenIndex: Int)],
        options: RestorationOptions,
        onRestore: (() -> Void)?,
        onFailure: ((WorkspaceWindow, String?) -> Void)?,
        currentScreens: [FullScreenInfo]? = nil
    ) async -> FluentRestorationResult {
        let shouldSetRunId = Self.currentRestoreRunId == nil
        let runId = Self.currentRestoreRunId ?? FluentWorkspaceRestorer.makeRunId()
        if shouldSetRunId {
            Self.currentRestoreRunId = runId
        }
        defer {
            if shouldSetRunId {
                Self.currentRestoreRunId = nil
            }
        }

        emitLifecycleEvent(
            workspace: workspace,
            event: .started,
            retryAttempt: 0
        )

        await MainActor.run {
            folderTabCoordinator?.clear()
        }

        markLastRestoredWorkspace(workspace)
        updateWorkspaceActivationTime(workspace)

        DeskJigLog.debug(
            .workspace,
            "Workspace launched id=\(workspace.id.uuidString) name=\(workspace.name) icon=\(workspace.icon ?? "unknown") " +
            "windowCount=\(workspace.windows.count) screenCount=\(workspace.screens?.count ?? 0) action=launch",
            runId: runId
        )

        DeskJigLog.debug(
            .workspace,
            "Starting Fluent workspace restoration for '\(workspace.name)' with \(workspace.windows.count) windows",
            runId: runId
        )
        logRestoreCallStack("WorkspaceManager.restoreFluentWorkspace name=\(workspace.name)")

        do {
            let restorer = FluentWorkspaceRestorer.shared

            // Wire up missing app callback if set
            let effectiveOptions: RestorationOptions
            if let missingAppCallback = onMissingAppDetected {
                effectiveOptions = options.withMissingAppCallback(missingAppCallback)
            } else {
                effectiveOptions = options
            }

            let result = try await restorer.restore(
                workspace: workspace,
                options: effectiveOptions,
                displayAssignments: displayAssignments,
                screenMappings: screenMappings,
                runId: runId
            )

            // Emit completion telemetry using the final result
            let evaluation = result.evaluation.map { eval in
                FluentRestorationTelemetry.RestorationEvaluation(
                    isPerfect: eval.isPerfect,
                    hasTimeout: false, // We'll handle timeout separately if needed
                    issues: eval.issues
                )
            } ?? fallbackEvaluation(for: result)

            emitCompletionEvent(
                workspace: workspace,
                evaluation: evaluation,
                retryAttempt: 0 // Retries now handled internally
            )

            persistResolvedDisplayIdentityIfNeeded(
                for: workspace,
                displayAssignments: displayAssignments,
                screenMappings: screenMappings,
                runId: runId,
                precomputedScreens: currentScreens
            )
            await folderTabCoordinator?.configure(
                workspace: workspace,
                result: result
            )
            emitFailureCallbacks(for: result, onFailure: onFailure)
            onRestore?()
            return result

        } catch {
            // User-initiated cancellation is expected, not a per-window failure. Fanning the
            // failure callback out across every window produced a stack of N "Workspace
            // Restoration" toasts on a single cancel; surface one concise notice instead and
            // skip the per-window callbacks. Real failures keep the per-window behavior.
            let isCancellation: Bool
            if let restorationError = error as? RestorationError, case .cancelled = restorationError {
                isCancellation = true
            } else {
                isCancellation = false
            }

            let message = isCancellation
                ? "Restoration was cancelled"
                : "Fluent restoration failed: \(error.localizedDescription)"

            if isCancellation {
                DeskJigLog.debug(.workspace, message, runId: runId)
            } else {
                DeskJigLog.error(.workspace, message, runId: runId)
                emitFailureCallbacks(for: workspace.windows, message: message, onFailure: onFailure)
            }

            let failureResult = failureResult(
                for: workspace,
                runId: runId,
                errorMessage: message
            )
            let evaluation = FluentRestorationTelemetry.RestorationEvaluation(
                isPerfect: false,
                hasTimeout: false,
                issues: [message]
            )
            emitCompletionEvent(
                workspace: workspace,
                evaluation: evaluation,
                retryAttempt: 0
            )
            return failureResult
        }
    }

    private func persistResolvedDisplayIdentityIfNeeded(
        for workspace: Workspace,
        displayAssignments: [WorkspaceDisplayAssignment],
        screenMappings: [(workspaceScreenIndex: Int, currentScreenIndex: Int)],
        runId: String,
        precomputedScreens: [FullScreenInfo]? = nil
    ) {
        guard workspace.hasSavedDisplayMetadata else {
            DeskJigLog.debug(.workspace, "Skipping display metadata persistence - workspace has no saved display metadata", fields: [
                "workspace": workspace.name,
                "workspaceID": workspace.id.uuidString
            ], runId: runId)
            return
        }

        guard savedWorkspaces.contains(where: { $0.id == workspace.id }) else {
            DeskJigLog.debug(.workspace, "Skipping display metadata persistence - workspace is not a persisted saved workspace", fields: [
                "workspace": workspace.name,
                "workspaceID": workspace.id.uuidString
            ], runId: runId)
            return
        }

        // wsm-03: reuse the start-of-restore screen topology when the caller already computed it
        // (monitors don't change during a restore), avoiding a redundant refreshScreens here.
        let currentScreens: [FullScreenInfo]
        if let precomputedScreens {
            currentScreens = precomputedScreens
        } else {
            displayManager.refreshScreens()
            currentScreens = WorkspaceDisplayTopology.effectiveScreens(from: displayManager)
        }

        let preparation: WorkspaceRestorePreparationResult
        do {
            preparation = try WorkspaceDisplayResolutionService.prepare(
                workspace: workspace,
                currentScreens: currentScreens,
                mode: .nonInteractive,
                explicitAssignments: displayAssignments,
                legacyScreenMappings: screenMappings
            )
        } catch {
            DeskJigLog.warn(.workspace, "Skipping display metadata persistence - could not resolve updated display identity", fields: [
                "workspace": workspace.name,
                "workspaceID": workspace.id.uuidString,
                "error": error.localizedDescription
            ], runId: runId)
            return
        }

        guard case .ready(let context) = preparation else {
            DeskJigLog.warn(.workspace, "Skipping display metadata persistence - restore preparation still requires assignment", fields: [
                "workspace": workspace.name,
                "workspaceID": workspace.id.uuidString
            ], runId: runId)
            return
        }

        let resolvedDisplayIdentity = context.resolvedDisplayIdentity
        guard resolvedDisplayIdentity.shouldPersistUpdatedIdentity else {
            DeskJigLog.info(.workspace, "Display metadata already synchronized with current arrangement", fields: [
                "workspace": workspace.name,
                "workspaceID": workspace.id.uuidString,
                "recoveredFingerprintCount": "\(resolvedDisplayIdentity.recoveredFingerprintCount)"
            ], runId: runId)
            return
        }

        Task { @MainActor [weak self] in
            self?.updateWorkspaceDisplayMetadata(
                for: workspace,
                screens: resolvedDisplayIdentity.screens,
                displaySlots: resolvedDisplayIdentity.displaySlots
            )
        }

        DeskJigLog.info(.workspace, "Persisted resolved display identity after successful restore", fields: [
            "workspace": workspace.name,
            "workspaceID": workspace.id.uuidString,
            "trustedAssignmentCount": "\(resolvedDisplayIdentity.trustedAssignments.count)",
            "recoveredFingerprintCount": "\(resolvedDisplayIdentity.recoveredFingerprintCount)",
            "usedRecoveredFingerprints": resolvedDisplayIdentity.usedRecoveredFingerprints
        ], runId: runId)
    }

    private func failureResult(
        for workspace: Workspace,
        runId: String,
        errorMessage: String
    ) -> FluentRestorationResult {
        let emptySnapshot = SystemSnapshot(
            captureTime: Date(),
            captureDurationMs: 0,
            runId: runId,
            displays: [],
            windows: []
        )
        let plan = RestorationPlan(
            runId: runId,
            workspace: workspace,
            snapshot: EnhancedSnapshot.from(emptySnapshot),
            tasks: [],
            tmuxTerminalRestoreContext: nil,
            createdAt: Date(),
            buildDurationMs: 0
        )
        return FluentRestorationResult(
            success: false,
            runId: runId,
            totalDurationMs: 0,
            windowsRestored: 0,
            windowsFailed: workspace.windows.count,
            windowsSkipped: 0,
            plan: plan,
            taskResults: [],
            snapshotDurationMs: 0,
            planDurationMs: 0,
            executeDurationMs: 0,
            evaluation: FluentRestorationResult.Evaluation(
                isPerfect: false,
                issues: [errorMessage]
            )
        )
    }

    private func fallbackEvaluation(
        for result: FluentRestorationResult
    ) -> FluentRestorationTelemetry.RestorationEvaluation {
        let issues = result.windowsFailed > 0
            ? ["Restore failed for \(result.windowsFailed) window(s)"]
            : []
        return FluentRestorationTelemetry.RestorationEvaluation(
            isPerfect: result.windowsFailed == 0,
            hasTimeout: false,
            issues: issues
        )
    }

    private func emitFailureCallbacks(
        for result: FluentRestorationResult,
        onFailure: ((WorkspaceWindow, String?) -> Void)?
    ) {
        guard let onFailure else { return }
        let taskWindows = Dictionary(uniqueKeysWithValues: result.plan.tasks.map { ($0.id, $0.workspaceWindow) })
        for taskResult in result.taskResults where !taskResult.success {
            guard let window = taskWindows[taskResult.taskId] else { continue }
            let notes = taskResult.notes.joined(separator: "; ")
            let message = notes.isEmpty ? taskResult.decision.description : notes
            onFailure(window, message)
        }
    }

    private func emitFailureCallbacks(
        for windows: [WorkspaceWindow],
        message: String,
        onFailure: ((WorkspaceWindow, String?) -> Void)?
    ) {
        guard let onFailure else { return }
        for window in windows {
            onFailure(window, message)
        }
    }

    private func logRestoreCallStack(_ label: String, limit: Int = 8) {
        guard ProcessInfo.processInfo.environment["SHOW_CALL_STACKS"] == "1" else { return }
        let symbols = Thread.callStackSymbols.prefix(limit).joined(separator: " | ")
        DeskJigLog.debug(.workspace, "CallStack \(label) stack=\(symbols)")
    }

    private struct GhosttyWindowCandidate {
        let sourceIndex: Int
        let window: WorkspaceWindow
        let normalizedPath: String?
        let titleToken: String
    }

    /// Preserves stable terminal keys for Ghostty windows across recaptures.
    /// Matching order:
    /// 1) exact normalized openPath
    /// 2) title token (DeskJig token/path token)
    /// 3) deterministic fallback by relative-frame proximity and capture order
    private func preserveGhosttyTerminalKeys(
        in windows: [WorkspaceWindow],
        previousWorkspace: Workspace?
    ) -> [WorkspaceWindow] {
        let currentCandidates = windows.enumerated().compactMap { index, window -> GhosttyWindowCandidate? in
            guard window.bundleIdentifier == BundleRegistry.ghostty else { return nil }
            return GhosttyWindowCandidate(
                sourceIndex: index,
                window: window,
                normalizedPath: normalizeOpenPath(window.openPath),
                titleToken: terminalTitleToken(for: window)
            )
        }

        guard !currentCandidates.isEmpty else { return windows }

        let previousGhosttyWindows = previousWorkspace?.windows.filter {
            $0.bundleIdentifier == BundleRegistry.ghostty
        } ?? []

        guard !previousGhosttyWindows.isEmpty else {
            return windows.map { window in
                guard window.bundleIdentifier == BundleRegistry.ghostty else { return window }
                if let existing = normalizedTerminalKey(window.terminalKey) {
                    return window.withTerminalKey(existing)
                }
                return window.withTerminalKey(UUID().uuidString.lowercased())
            }
        }

        let previousCandidates = previousGhosttyWindows.enumerated().map { index, window in
            GhosttyWindowCandidate(
                sourceIndex: index,
                window: window,
                normalizedPath: normalizeOpenPath(window.openPath),
                titleToken: terminalTitleToken(for: window)
            )
        }

        var assignments: [UUID: String] = [:]
        var usedPreviousWindowIDs = Set<UUID>()

        func assign(_ current: GhosttyWindowCandidate, from matches: [GhosttyWindowCandidate]) {
            guard let best = bestPreviousGhosttyMatch(for: current, matches: matches) else { return }
            let key = normalizedTerminalKey(best.window.terminalKey) ?? best.window.id.uuidString.lowercased()
            assignments[current.window.id] = key
            usedPreviousWindowIDs.insert(best.window.id)
        }

        // Pass 1: exact openPath matching.
        for current in currentCandidates {
            guard let path = current.normalizedPath else { continue }
            let matches = previousCandidates.filter {
                !usedPreviousWindowIDs.contains($0.window.id) && $0.normalizedPath == path
            }
            assign(current, from: matches)
        }

        // Pass 2: title-token matching.
        for current in currentCandidates where assignments[current.window.id] == nil {
            guard !current.titleToken.isEmpty else { continue }
            let matches = previousCandidates.filter {
                !usedPreviousWindowIDs.contains($0.window.id) && $0.titleToken == current.titleToken
            }
            assign(current, from: matches)
        }

        // Pass 3: deterministic fallback.
        for current in currentCandidates where assignments[current.window.id] == nil {
            let matches = previousCandidates.filter { !usedPreviousWindowIDs.contains($0.window.id) }
            assign(current, from: matches)
        }

        return windows.map { window in
            guard window.bundleIdentifier == BundleRegistry.ghostty else { return window }
            if let assigned = assignments[window.id] {
                return window.withTerminalKey(assigned)
            }
            if let existing = normalizedTerminalKey(window.terminalKey) {
                return window.withTerminalKey(existing)
            }
            return window.withTerminalKey(UUID().uuidString.lowercased())
        }
    }

    private func bestPreviousGhosttyMatch(
        for current: GhosttyWindowCandidate,
        matches: [GhosttyWindowCandidate]
    ) -> GhosttyWindowCandidate? {
        matches.min { lhs, rhs in
            let lhsTitlePenalty = lhs.titleToken == current.titleToken ? 0 : 1
            let rhsTitlePenalty = rhs.titleToken == current.titleToken ? 0 : 1

            if lhsTitlePenalty != rhsTitlePenalty {
                return lhsTitlePenalty < rhsTitlePenalty
            }

            let lhsFrameDistance = relativeFrameDistance(lhs.window.relativeFrame, current.window.relativeFrame)
            let rhsFrameDistance = relativeFrameDistance(rhs.window.relativeFrame, current.window.relativeFrame)
            if lhsFrameDistance != rhsFrameDistance {
                return lhsFrameDistance < rhsFrameDistance
            }

            let lhsOrderDistance = abs(lhs.sourceIndex - current.sourceIndex)
            let rhsOrderDistance = abs(rhs.sourceIndex - current.sourceIndex)
            if lhsOrderDistance != rhsOrderDistance {
                return lhsOrderDistance < rhsOrderDistance
            }

            let lhsTitle = lhs.window.windowTitle.lowercased()
            let rhsTitle = rhs.window.windowTitle.lowercased()
            if lhsTitle != rhsTitle {
                return lhsTitle < rhsTitle
            }

            return lhs.window.id.uuidString < rhs.window.id.uuidString
        }
    }

    private func terminalTitleToken(for window: WorkspaceWindow) -> String {
        let normalizedTitle = window.windowTitle.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let titlePrefix = "\(BundleIdentity.terminalTitleTokenPrefix):"
        if normalizedTitle.hasPrefix(titlePrefix) {
            let parts = normalizedTitle.split(separator: ":")
            if parts.count >= 3 {
                return "\(BundleIdentity.terminalTitleTokenPrefix):\(parts[1]):\(parts[2])"
            }
        }
        if let path = normalizeOpenPath(window.openPath) {
            return URL(fileURLWithPath: path).lastPathComponent.lowercased()
        }
        return normalizedTitle
    }

    private func relativeFrameDistance(
        _ lhs: RelativeWindowFrame?,
        _ rhs: RelativeWindowFrame?
    ) -> Double {
        guard let lhs, let rhs else { return 1_000_000 }
        return abs(lhs.xPercent - rhs.xPercent)
            + abs(lhs.yPercent - rhs.yPercent)
            + abs(lhs.widthPercent - rhs.widthPercent)
            + abs(lhs.heightPercent - rhs.heightPercent)
    }

    private func normalizedTerminalKey(_ key: String?) -> String? {
        guard let key else { return nil }
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return trimmed
    }

    private func normalizeOpenPath(_ path: String?) -> String? {
        guard let path else { return nil }
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let expanded = (trimmed as NSString).expandingTildeInPath
        return URL(fileURLWithPath: expanded).standardizedFileURL.path
    }

    private enum WorkspaceLifecycleEvent: String {
        case started = "workspace_restoration_started"
        case completed = "workspace_restoration_completed"
    }

    private func emitLifecycleEvent(
        workspace: Workspace,
        event: WorkspaceRestorationLogPayload.EventType,
        retryAttempt: Int,
        isPerfect: Bool? = nil,
        durationMs: Int? = nil
    ) {
        guard let handler = FluentRestorationTelemetry.restorationLogHandler else { return }
        let message = "[Restoration] \(event.rawValue): \(workspace.name)"
        let payload = WorkspaceRestorationLogPayload(
            workspaceId: workspace.id.uuidString,
            workspaceName: workspace.name,
            eventType: event,
            message: message,
            accuracy: nil,
            missingWindows: nil,
            extraWindows: nil,
            isPerfect: isPerfect,
            retryAttempt: retryAttempt,
            expectedWindows: workspace.windows.count,
            actualWindows: nil,
            screenCount: workspace.screens?.count,
            windowSummary: nil,
            fullReport: nil,
            windows: [],
            displays: [],
            windowChanges: nil,
            positionErrors: nil,
            zOrderStatus: nil,
            missingWindowsDetail: nil,
            extraWindowsDetail: nil,
            positionAccuracyDetail: nil,
            durationMs: durationMs,
            traceId: nil,
            sequence: nil,
            schemaVersion: 1
        )
        handler(payload)
    }

    private func emitCompletionEvent(
        workspace: Workspace,
        evaluation: FluentRestorationTelemetry.RestorationEvaluation?,
        retryAttempt: Int
    ) {
        // Trace completion
        TraceFileWriter.shared.complete(success: evaluation?.isPerfect ?? true, windowCount: workspace.windows.count)

        emitLifecycleEvent(
            workspace: workspace,
            event: .complete,
            retryAttempt: retryAttempt,
            isPerfect: evaluation?.isPerfect,
            durationMs: nil // Duration tracking moved to Fluent
        )

        // Emit clean summary for analytics dashboards
        // Note: For now we're skipping the legacy summary generation as it's being consolidated into DeskJigLog/TraceFileWriter
        
        let clearedRunId = Self.currentRestoreRunId
        Self.currentRestoreRunId = nil
        DeskJigLog.debug(.workspace, "Cleared current restore run id", runId: clearedRunId)
    }
}
