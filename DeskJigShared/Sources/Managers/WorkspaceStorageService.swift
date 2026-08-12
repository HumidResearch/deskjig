//
//  WorkspaceStorageService.swift
//  DeskJigShared
//
//  Created by AI on 12.29.2025.
//

import Foundation

public class WorkspaceStorageService {
    private let defaults: UserDefaults

    /// Legacy `UserDefaults` flag marking the one-time directory-workspace import as done.
    ///
    /// The commercial predecessor namespaced this per account
    /// (`"<userID>.directoryWorkspacesMigration.completed"`); the local-only port keeps the
    /// bare suffix as the frozen key. The flag is load-bearing: without it the import re-runs
    /// on every `reloadWorkspaces()` and resurrects directory workspaces the user deleted.
    private static let directoryMigrationCompletedKey = "directoryWorkspacesMigration.completed"

    // MARK: - Initialization

    public init(defaults: UserDefaults? = nil) {
        self.defaults = defaults
            ?? UserDefaults(suiteName: BundleIdentity.defaultsSuiteName)
            ?? .standard
    }

    // MARK: - Load/Save Operations

    public func loadWorkspaces() -> [Workspace] {
        // One-time adoption of `"<uid>.SavedWorkspaces"` written by the
        // account-scoped predecessor. No-op after the first run (flagged).
        LegacyStoreAdoption.adoptLegacyWorkspacesIfNeeded(in: defaults)

        let workspaces = loadWorkspacesFromCache()
        let normalizedWorkspaces = workspaces.map { normalizeWorkspaceForPersistence($0) }
        logLayoutHealthSummary(for: normalizedWorkspaces, context: "load-cache")
        return normalizedWorkspaces
    }

    /// Migrates workspace screen data to ensure consistency with position-based ordering.
    ///
    /// This handles workspaces that were saved before the position-sorting fix, where:
    /// 1. Screens may not be sorted by x-position
    /// 2. Window screenIndex values may reference non-existent screens
    ///
    /// The migration:
    /// 1. Sorts the screens array by x-position (left-to-right)
    /// 2. Re-maps window screenIndex values to match the new sorted order
    /// 3. Clamps any invalid screenIndex values to valid range
    func migrateWorkspaceScreenData(_ workspace: Workspace) -> Workspace {
        guard let screens = workspace.screens, !screens.isEmpty else {
            return workspace
        }

        // Sort screens using the same topology semantics as runtime screen discovery so
        // stacked displays with the same minX resolve deterministically.
        let sortedScreens = WorkspaceDisplayTopology.sortWorkspaceScreens(screens)

        // Check if screens were already sorted - if so, no migration needed
        let alreadySorted = screens.map(\.id) == sortedScreens.map(\.id)

        // Check if any windows have invalid screenIndex
        let maxValidIndex = sortedScreens.count - 1
        let hasInvalidIndices = workspace.windows.contains { window in
            guard let index = window.screenIndex else { return false }
            return index < 0 || index > maxValidIndex
        }

        // Re-map whenever the saved screen order differs from runtime topology semantics,
        // even if the indices are technically in range. Otherwise windows stay attached to
        // stale slot numbers and restore to the wrong saved monitor.
        if alreadySorted && !hasInvalidIndices {
            return workspace
        }

        // Build mapping from old index to new index based on the screen object's stable id.
        var oldToNewIndexMap: [Int: Int] = [:]
        for (oldIndex, screen) in screens.enumerated() {
            if let newIndex = sortedScreens.firstIndex(where: { $0.id == screen.id }) {
                oldToNewIndexMap[oldIndex] = newIndex
            }
        }

        // Migrate window screenIndex values
        let migratedWindows = workspace.windows.map { window -> WorkspaceWindow in
            guard let oldIndex = window.screenIndex else { return window }

            // If there's a mapping, use it; otherwise clamp to valid range
            let newIndex: Int
            if let mappedIndex = oldToNewIndexMap[oldIndex] {
                newIndex = mappedIndex
            } else {
                // Invalid index - clamp to valid range (fallback to last screen or 0)
                newIndex = min(oldIndex, maxValidIndex)
            }

            // Only create new window if index actually changed
            if newIndex == oldIndex {
                return window
            }

            return window.withScreenMapping(screenIndex: newIndex)
        }

        let remappedWindowCount = zip(workspace.windows, migratedWindows).reduce(into: 0) { count, pair in
            if pair.0.screenIndex != pair.1.screenIndex {
                count += 1
            }
        }

        DeskJigLog.info(.workspace, "Migrated workspace '\(workspace.name)' screen data", fields: [
            "sorted": (!alreadySorted).description,
            "fixedIndices": hasInvalidIndices.description,
            "remappedWindowCount": "\(remappedWindowCount)"
        ])

        return workspace.withNewWindowsAndScreens(migratedWindows, screens: sortedScreens)
    }

    private func normalizeWorkspaceForPersistence(_ workspace: Workspace) -> Workspace {
        do {
            return try WorkspaceDisplayResolutionService.normalizeWorkspace(workspace)
        } catch {
            DeskJigLog.error(.workspace, "WorkspaceStorageService: Failed to normalize workspace '\(workspace.name)': \(error.localizedDescription)")
            return workspace
        }
    }

    private func logLayoutHealthSummary(for workspaces: [Workspace], context: String) {
        let summary = WorkspaceLayoutHealthSummary(workspaces: workspaces)
        guard summary.flattenedCount > 0 else { return }

        let brokenPreviewNames = workspaces
            .filter { $0.layoutHealth == .legacyFlattenedBrokenPreview }
            .map(\.name)
            .sorted()

        DeskJigLog.warn(.workspace, "WorkspaceStorageService: Detected flattened legacy workspaces", fields: [
            "context": context,
            "totalCount": "\(summary.totalCount)",
            "flattenedCount": "\(summary.flattenedCount)",
            "legacyFlattenedCount": "\(summary.legacyFlattenedCount)",
            "legacyBrokenPreviewCount": "\(summary.legacyFlattenedBrokenPreviewCount)",
            "brokenPreviewWorkspaces": brokenPreviewNames.joined(separator: ",")
        ])
    }

    private func preserveDisplayMetadataDowngrades(in workspaces: [Workspace]) -> [Workspace] {
        let existingByID = Dictionary(uniqueKeysWithValues: loadWorkspacesFromCache().map { ($0.id, $0) })

        return workspaces.map { workspace in
            guard let existingWorkspace = existingByID[workspace.id] else {
                return workspace
            }

            let repairedWorkspace = workspace.preservingDisplayMetadata(from: existingWorkspace)
            if repairedWorkspace != workspace {
                DeskJigLog.warn(.workspace, "WorkspaceStorageService: Preserved display metadata from richer local copy", fields: [
                    "workspace": workspace.name,
                    "workspaceID": workspace.id.uuidString,
                    "incomingFlattened": workspace.isDisplayMetadataFlattened.description,
                    "existingHasDisplayMetadata": existingWorkspace.hasSavedDisplayMetadata.description
                ])
            }
            return repairedWorkspace
        }
    }

    public func saveWorkspaces(_ workspaces: [Workspace]) {
        let protectedWorkspaces = preserveDisplayMetadataDowngrades(in: workspaces)
        let normalizedWorkspaces = protectedWorkspaces.map { normalizeWorkspaceForPersistence($0) }

        // Already preserved + normalized above, so encode directly instead of
        // re-running both passes inside saveToLocalCache.
        saveToLocalCacheRaw(normalizedWorkspaces)
    }

    // MARK: - Cache Helpers

    /// Loads workspaces from the shared defaults suite.
    private func loadWorkspacesFromCache() -> [Workspace] {
        guard let data = defaults.data(forKey: BundleIdentity.savedWorkspacesKey) else {
            return []
        }

        do {
            return try JSONDecoder().decode([Workspace].self, from: data)
        } catch {
            DeskJigLog.error(.workspace, "WorkspaceStorageService: Failed to decode cached workspaces: \(error)")
            return []
        }
    }

    /// Saves workspaces to the shared cache, running the display-metadata preservation +
    /// normalization passes first. Callers that have already preserved + normalized (e.g.
    /// `saveWorkspaces`) should use `saveToLocalCacheRaw` to avoid a redundant second pass.
    private func saveToLocalCache(_ workspaces: [Workspace]) {
        let protectedWorkspaces = preserveDisplayMetadataDowngrades(in: workspaces)
        let normalizedWorkspaces = protectedWorkspaces.map { normalizeWorkspaceForPersistence($0) }
        saveToLocalCacheRaw(normalizedWorkspaces)
    }

    /// Encodes already-preserved-and-normalized workspaces straight to the shared cache.
    /// Skips the preserve + normalize passes — only call with input that has already been
    /// through `preserveDisplayMetadataDowngrades` (against the RAW workspaces) + normalization.
    private func saveToLocalCacheRaw(_ preparedWorkspaces: [Workspace]) {
        do {
            let data = try JSONEncoder().encode(preparedWorkspaces)
            defaults.set(data, forKey: BundleIdentity.savedWorkspacesKey)
        } catch {
            DeskJigLog.error(.workspace, "WorkspaceStorageService: Failed to encode workspaces for cache: \(error)")
        }
    }

    /// Saves workspaces to the local cache.
    public func saveToLocalCacheOnly(_ workspaces: [Workspace]) {
        saveToLocalCache(workspaces.map { normalizeWorkspaceForPersistence($0) })
    }

    // MARK: - Workspace Operations

    public func migrateDirectoryWorkspacesIfNeeded(
        currentWorkspaces: [Workspace],
        captureScreens: () -> [WorkspaceScreen]
    ) -> [Workspace]? {
        // One-shot: this import runs once per install, never on every reload.
        if defaults.bool(forKey: Self.directoryMigrationCompletedKey) {
            return nil
        }

        DirectoryWorkspaceManager.shared.reloadWorkspaces()
        let directoryWorkspaces = DirectoryWorkspace.list()
        guard !directoryWorkspaces.isEmpty else {
            // Mark complete even if no directory workspaces exist.
            defaults.set(true, forKey: Self.directoryMigrationCompletedKey)
            return nil
        }

        let existingIds = Set(currentWorkspaces.map(\.id))
        let existingNames = Set(currentWorkspaces.map(\.name))
        let savedById = Dictionary(uniqueKeysWithValues: currentWorkspaces.map { ($0.id, $0) })

        var migrated: [Workspace] = []
        var updatedWorkspaces = currentWorkspaces
        var didAnyMigration = false
        var screens: [WorkspaceScreen]?

        for directoryWorkspace in directoryWorkspaces {
            if let savedWorkspace = savedById[directoryWorkspace.id] {
                var updated = directoryWorkspace
                var didUpdate = false

                if directoryWorkspace.name != savedWorkspace.name {
                    updated = updated.withName(savedWorkspace.name)
                    didUpdate = true
                }
                if directoryWorkspace.icon != savedWorkspace.icon {
                    updated = updated.withIcon(savedWorkspace.icon)
                    didUpdate = true
                }

                if didUpdate {
                    DirectoryWorkspaceManager.shared.updateWorkspace(updated)
                    DeskJigLog.info(.workspace, 
                        "DirectoryWorkspace metadata sync: id=\(directoryWorkspace.id) " +
                        "name='\(directoryWorkspace.name)' -> '\(updated.name)' " +
                        "icon='\(directoryWorkspace.icon ?? "nil")' -> '\(updated.icon ?? "nil")'"
                    )
                }
                continue
            }

            if existingIds.contains(directoryWorkspace.id) || existingNames.contains(directoryWorkspace.name) {
                continue
            }

            if screens == nil {
                screens = captureScreens()
            }

            if let screens = screens {
                migrated.append(directoryWorkspace.toWorkspace(screens: screens))
                didAnyMigration = true
            }
        }

        if didAnyMigration {
            updatedWorkspaces.append(contentsOf: migrated)
            saveWorkspaces(updatedWorkspaces)
            DeskJigLog.info(.workspace, "Migrated \(migrated.count) directory workspaces into \(BundleIdentity.savedWorkspacesKey)")

            defaults.set(true, forKey: Self.directoryMigrationCompletedKey)
            return updatedWorkspaces
        }

        // Mark complete even if nothing was migrated.
        defaults.set(true, forKey: Self.directoryMigrationCompletedKey)
        return nil
    }

    public func deleteWorkspace(_ workspaces: [Workspace], workspace: Workspace) -> [Workspace] {
        var updated = workspaces
        updated.removeAll { $0.id == workspace.id }

        saveToLocalCache(updated)

        DeskJigLog.info(.workspace, "Deleted workspace '\(workspace.name)'")
        return updated
    }

    public func renameWorkspace(_ workspaces: [Workspace], workspace: Workspace, newName: String) -> [Workspace] {
        var updated = workspaces
        if let index = updated.firstIndex(where: { $0.id == workspace.id }) {
            updated[index] = workspace.withNewName(newName)
            saveWorkspaces(updated)
            DeskJigLog.info(.workspace, "Renamed workspace to '\(newName)'")
        }
        return updated
    }

    public func updateWorkspaceMetadata(
        workspaces: [Workspace],
        workspace: Workspace,
        newName: String,
        newIcon: String,
        chromeModifications: [UUID: ChromeModification],
        openByPathModifications: [UUID: OpenByPathModification],
        normalizeOpenPath: (String?) -> String?
    ) -> [Workspace] {
        var updatedWorkspaces = workspaces
        guard let index = updatedWorkspaces.firstIndex(where: { $0.id == workspace.id }) else {
            DeskJigLog.error(.workspace, "Cannot update workspace metadata - workspace not found: \(workspace.name)")
            return workspaces
        }

        let existingWorkspace = updatedWorkspaces[index]

        // DIAGNOSTIC: Log chrome modification keys vs window IDs
        DeskJigLog.info(.workspace, "🔍 updateWorkspaceMetadata: chromeModifications keys (\(chromeModifications.count)): \(chromeModifications.keys.map { $0.uuidString.prefix(8) })")
        DeskJigLog.info(.workspace, "🔍 existingWorkspace.windows IDs (\(existingWorkspace.windows.count)): \(existingWorkspace.windows.map { $0.id.uuidString.prefix(8) })")
        for (id, mod) in chromeModifications {
            DeskJigLog.info(.workspace, "🔍   chromeModification[\(id.uuidString.prefix(8))]: profileDir='\(mod.profileDirectory ?? "nil")' displayName='\(mod.profileDisplayName ?? "nil")'")
        }
        for window in existingWorkspace.windows where chromeBundleIdentifiers.contains(window.bundleIdentifier) {
            let existingProfile = window.chromeState?.profileDirectory ?? "nil"
            DeskJigLog.info(.workspace, "🔍   window[\(window.id.uuidString.prefix(8))]: '\(window.windowTitle.prefix(30))' existingProfile='\(existingProfile)'")
        }

        func normalizedTitle(_ title: String) -> String {
            title.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        var appliedOpenByPathModificationIds = Set<UUID>()

        let updatedWindows: [WorkspaceWindow] = existingWorkspace.windows.map { window in
            var updatedWindow = window

            if let modification = chromeModifications[window.id] {
                DeskJigLog.info(.workspace, "🔍 ✓ Found chromeModification for window[\(window.id.uuidString.prefix(8))]: profileDir='\(modification.profileDirectory ?? "nil")'")
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
                DeskJigLog.info(.workspace, "🔍 ✗ No chromeModification for Chrome window[\(window.id.uuidString.prefix(8))]: '\(window.windowTitle.prefix(30))'")
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

                    if let exact = candidates.first(where: { normalizedTitle($0.value.windowTitle) == normalizedTitle(window.windowTitle) }) {
                        modification = exact.value
                        matchedModificationId = exact.key
                    } else if let first = candidates.first {
                        modification = first.value
                        matchedModificationId = first.key
                    }
                }

                if let modification, let matchedId = matchedModificationId {
                    appliedOpenByPathModificationIds.insert(matchedId)
                    updatedWindow = updatedWindow.withOpenPath(normalizeOpenPath(modification.openPath))
                }
            }

            return updatedWindow
        }

        let titledWindows = OpenByPathTitleAssigner.apply(to: updatedWindows)

        let updatedWorkspace = Workspace(
            id: existingWorkspace.id,
            name: newName,
            icon: newIcon,
            workspaceWindows: titledWindows,
            displaySlots: existingWorkspace.displaySlots,
            screens: existingWorkspace.screens
        )

        updatedWorkspaces[index] = updatedWorkspace
        saveWorkspaces(updatedWorkspaces)

        DeskJigLog.info(.workspace, "Updated workspace metadata: '\(workspace.name)' -> '\(newName)', icon: '\(newIcon)'")
        return updatedWorkspaces
    }

    public func updateWorkspaceDisplayMetadata(
        workspaces: [Workspace],
        workspaceID: UUID,
        screens: [WorkspaceScreen],
        displaySlots: [WorkspaceDisplaySlot]
    ) -> [Workspace] {
        var updatedWorkspaces = workspaces
        guard let index = updatedWorkspaces.firstIndex(where: { $0.id == workspaceID }) else {
            DeskJigLog.warn(.workspace, "Cannot update workspace display metadata - workspace not found", fields: [
                "workspaceID": workspaceID.uuidString
            ])
            return workspaces
        }

        let existingWorkspace = updatedWorkspaces[index]
        let updatedWorkspace = existingWorkspace.withNewWindowsAndScreens(
            existingWorkspace.windows,
            screens: screens,
            displaySlots: displaySlots
        )

        guard updatedWorkspace.displaySlots != existingWorkspace.displaySlots ||
                updatedWorkspace.screens != existingWorkspace.screens else {
            DeskJigLog.info(.workspace, "Workspace display metadata already current", fields: [
                "workspace": existingWorkspace.name,
                "workspaceID": existingWorkspace.id.uuidString
            ])
            return workspaces
        }

        updatedWorkspaces[index] = updatedWorkspace
        saveWorkspaces(updatedWorkspaces)

        DeskJigLog.info(.workspace, "Updated workspace display metadata", fields: [
            "workspace": existingWorkspace.name,
            "workspaceID": existingWorkspace.id.uuidString,
            "screenCount": "\(screens.count)",
            "slotCount": "\(displaySlots.count)"
        ])

        return updatedWorkspaces
    }
}
