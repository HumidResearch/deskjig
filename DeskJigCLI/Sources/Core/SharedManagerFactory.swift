//  SharedManagerFactory.swift
//  DeskJigCLI

import Foundation
import DeskJigShared

// MARK: - Shared UserDefaults Helper

/// WorkspaceManager wrapper that reads the DeskJig app's shared UserDefaults.
class SharedWorkspaceManager {
    private let workspaceManager: WorkspaceManager
    let displayManager: DisplayManager
    private let defaultsSuiteName = BundleIdentity.defaultsSuiteName
    private let workspacesKey = BundleIdentity.savedWorkspacesKey
    private let prefsPathOverride = ProcessInfo.processInfo.environment["BENTOCLI_PREFS_PATH_OVERRIDE"]

    var savedWorkspaces: [Workspace] {
        loadWorkspaces()
    }

    init(displayManager: DisplayManager = DisplayManager()) {
        self.displayManager = displayManager
        self.workspaceManager = WorkspaceManager(displayManager: displayManager)
    }

    private lazy var prefsPath: URL = {
        if let override = prefsPathOverride, !override.isEmpty {
            return URL(fileURLWithPath: override).standardizedFileURL
        }

        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Preferences/\(defaultsSuiteName).plist")
    }()

    /// cfprefsd-backed handle on the DeskJig app's preferences domain.
    ///
    /// Writing the plist file directly (the pre-#655 behavior) bypasses
    /// cfprefsd, so a running DeskJig.app kept serving its cached SavedWorkspaces
    /// value even after `reloadWorkspaces()` — a workspace created by the CLI
    /// stayed invisible to in-app restores until the app relaunched. Routing
    /// reads and writes through `UserDefaults(suiteName:)` keeps cfprefsd (and
    /// therefore the running app's `UserDefaults.standard`) coherent in both
    /// directions. `nil` when BENTOCLI_PREFS_PATH_OVERRIDE points the store at
    /// a plain file (tests), which keeps the direct file IO path.
    private lazy var sharedDefaults: UserDefaults? = {
        if let override = prefsPathOverride, !override.isEmpty {
            return nil
        }
        return UserDefaults(suiteName: defaultsSuiteName)
    }()

    /// Connect ApplicationManager to enable app launching during restoration
    /// CRITICAL: Must be called before restoreWorkspace for full functionality
    func setApplicationManager(_ applicationManager: ApplicationManager) {
        workspaceManager.setApplicationManager(applicationManager)
    }

    struct WorkspaceRestoreOutcome {
        let result: FluentRestorationResult
        let failures: [(window: WorkspaceWindow, message: String?)]
    }

    /// Restore workspace asynchronously using Fluent API.
    /// - Parameters:
    ///   - workspace: The workspace to restore
    ///   - displayAssignments: Optional explicit slot→display assignments
    ///     (e.g. deterministic portability degradation, GH #579). When empty
    ///     the normal fingerprint-based display resolution runs.
    ///   - onProgress: Optional callback for progress updates
    func restoreWorkspace(
        _ workspace: Workspace,
        hideAllApps: Bool = false,
        displayAssignments: [WorkspaceDisplayAssignment] = [],
        onProgress: ((String) -> Void)? = nil
    ) async -> WorkspaceRestoreOutcome {
        var failures: [(window: WorkspaceWindow, message: String?)] = []

        let onFailure: (WorkspaceWindow, String?) -> Void = { window, message in
            failures.append((window: window, message: message))
            onProgress?("⚠️  \(window.appName): \(message ?? "Failed")")
        }

        onProgress?("Starting restoration of '\(workspace.name)' with \(workspace.windows.count) window(s)...")

        let options = RestorationOptions(
            hideAllAppsBeforeRestore: hideAllApps
        )

        let result: FluentRestorationResult
        if displayAssignments.isEmpty {
            result = await workspaceManager.restoreWorkspace(
                workspace,
                options: options,
                onRestore: nil,
                onFailure: onFailure
            )
        } else {
            result = await workspaceManager.restoreWorkspaceWithDisplayAssignments(
                workspace,
                displayAssignments: displayAssignments,
                options: options,
                onRestore: nil,
                onFailure: onFailure
            )
        }

        return WorkspaceRestoreOutcome(result: result, failures: failures)
    }

    func restoreWindows(_ windows: [WorkspaceWindow]) async -> FluentRestorationResult {
        await workspaceManager.restoreWindows(windows, onFailure: nil)
    }

    func updateWindow(in workspace: Workspace, updatedWindow: WorkspaceWindow) {
        // Load current workspaces
        var workspaces = loadWorkspaces()

        // Find and update the workspace
        if let index = workspaces.firstIndex(where: { $0.id == workspace.id }) {
            workspaces[index] = workspace.withUpdatedWindow(updatedWindow)

            // Save back to DeskJig app's preferences
            saveWorkspaces(workspaces)
            print("✓ Saved changes to DeskJig app preferences")
        }
    }

    func updateWorkspace(_ workspace: Workspace) {
        var workspaces = loadWorkspaces()

        if let index = workspaces.firstIndex(where: { $0.id == workspace.id }) {
            workspaces[index] = workspace
        } else {
            workspaces.append(workspace)
        }

        saveWorkspaces(workspaces)
    }

    enum WorkspaceImportOutcome {
        case added
        case replaced
        case skipped(reason: String)
    }

    func importWorkspace(
        _ workspace: Workspace,
        replaceExisting: Bool
    ) -> WorkspaceImportOutcome {
        var workspaces = loadWorkspaces()

        if let existingIndex = workspaces.firstIndex(where: {
            $0.id == workspace.id ||
            $0.name.compare(workspace.name, options: [.caseInsensitive]) == .orderedSame
        }) {
            guard replaceExisting else {
                return .skipped(reason: "Workspace already exists (use --replace-existing to overwrite).")
            }
            workspaces[existingIndex] = workspace
            saveWorkspaces(workspaces)
            return .replaced
        }

        workspaces.append(workspace)
        saveWorkspaces(workspaces)
        return .added
    }

    @discardableResult
    func deleteWorkspace(_ workspace: Workspace) -> Bool {
        var workspaces = loadWorkspaces()
        let beforeCount = workspaces.count
        workspaces.removeAll { $0.id == workspace.id }

        guard workspaces.count != beforeCount else {
            return false
        }

        saveWorkspaces(workspaces)
        return true
    }

    func getWorkspace(byId id: UUID) -> Workspace? {
        return loadWorkspaces().first(where: { $0.id == id })
    }

    func getWorkspace(named name: String) -> Workspace? {
        let normalizedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedName.isEmpty else {
            return nil
        }

        return loadWorkspaces().first {
            $0.name.compare(normalizedName, options: [.caseInsensitive]) == .orderedSame
        }
    }

    func resolveWorkspaceID(named name: String) -> UUID? {
        getWorkspace(named: name)?.id
    }

    func reloadSavedWorkspaces() -> [Workspace] {
        loadWorkspaces()
    }

    private func loadWorkspaces() -> [Workspace] {
        var workspaces: [Workspace] = []

        let cacheKey = workspacesKey

        if let sharedDefaults {
            // Real store: read through cfprefsd so writes the running app made
            // through its own UserDefaults are visible even before they flush
            // to the plist file (#655).
            if let workspacesData = sharedDefaults.data(forKey: cacheKey) {
                do {
                    workspaces = try JSONDecoder().decode([Workspace].self, from: workspacesData)
                    DeskJigLog.info(.workspace, "SharedWorkspaceManager: Loaded workspaces from defaults domain", fields: [
                        "domain": defaultsSuiteName,
                        "cacheKey": cacheKey,
                        "workspaceCount": "\(workspaces.count)"
                    ])
                } catch {
                    print("Failed to decode workspaces from DeskJig preferences (key: \(cacheKey)): \(error)")
                }
            } else {
                DeskJigLog.info(.workspace, "SharedWorkspaceManager: No workspaces stored for cache key", fields: [
                    "domain": defaultsSuiteName,
                    "cacheKey": cacheKey
                ])
            }
        } else {
            // Override store (tests): read directly from the plist file
            guard FileManager.default.fileExists(atPath: prefsPath.path) else {
                DeskJigLog.info(.workspace, "SharedWorkspaceManager: Workspace prefs file not found", fields: [
                    "prefsPath": prefsPath.path,
                    "cacheKey": cacheKey
                ])
                return []
            }

            guard let prefsDict = NSDictionary(contentsOf: prefsPath) as? [String: Any] else {
                return []
            }

            if let workspacesData = prefsDict[cacheKey] as? Data {
                do {
                    workspaces = try JSONDecoder().decode([Workspace].self, from: workspacesData)
                    DeskJigLog.info(.workspace, "SharedWorkspaceManager: Loaded workspaces from prefs", fields: [
                        "prefsPath": prefsPath.path,
                        "cacheKey": cacheKey,
                        "workspaceCount": "\(workspaces.count)"
                    ])
                } catch {
                    print("Failed to decode workspaces from DeskJig preferences (key: \(cacheKey)): \(error)")
                }
            } else {
                DeskJigLog.info(.workspace, "SharedWorkspaceManager: No workspaces stored for cache key", fields: [
                    "prefsPath": prefsPath.path,
                    "cacheKey": cacheKey
                ])
            }
        }

        let shouldMigrate = ProcessInfo.processInfo.environment["BENTOCLI_MIGRATE_DIRECTORY_WORKSPACES"] == "1"
        if shouldMigrate {
            return migrateDirectoryWorkspacesIfNeeded(workspaces)
        }

        return workspaces
    }

    private func saveWorkspaces(_ workspaces: [Workspace]) {
        do {
            // Encode workspaces to Data
            let workspacesData = try JSONEncoder().encode(workspaces)

            let cacheKey = workspacesKey

            if let sharedDefaults {
                // Real store: write through cfprefsd. This updates the single
                // key only (no read-modify-write of the whole plist, which
                // could clobber concurrent app writes to other keys) and makes
                // the new value immediately visible to the running app's
                // UserDefaults (#655).
                sharedDefaults.set(workspacesData, forKey: cacheKey)
                // Flush to cfprefsd before this short-lived process exits and
                // before the change signal below triggers an app-side reload.
                sharedDefaults.synchronize()
                DeskJigLog.info(.workspace, "SharedWorkspaceManager: Saved workspaces to defaults domain", fields: [
                    "domain": defaultsSuiteName,
                    "cacheKey": cacheKey,
                    "workspaceCount": "\(workspaces.count)"
                ])
            } else {
                // Override store (tests): write the plist file directly
                var prefsDict = (NSDictionary(contentsOf: prefsPath) as? [String: Any]) ?? [:]

                try FileManager.default.createDirectory(
                    at: prefsPath.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )

                // Update the dictionary
                prefsDict[cacheKey] = workspacesData

                // Write back to file
                let nsDictionary = NSDictionary(dictionary: prefsDict)
                nsDictionary.write(to: prefsPath, atomically: true)

                DeskJigLog.info(.workspace, "SharedWorkspaceManager: Saved workspaces to prefs", fields: [
                    "prefsPath": prefsPath.path,
                    "cacheKey": cacheKey,
                    "workspaceCount": "\(workspaces.count)"
                ])
            }

            // Tell a running DeskJig.app the store changed so it reloads its
            // in-memory workspace list (#655). Posted in override mode too so
            // the CLI-lane tests can assert the signal fires.
            WorkspaceExternalChangeSignal.post()
        } catch {
            print("Failed to save workspaces to DeskJig preferences: \(error)")
        }
    }

    private func migrateDirectoryWorkspacesIfNeeded(_ workspaces: [Workspace]) -> [Workspace] {
        DirectoryWorkspaceManager.shared.reloadWorkspaces()
        let directoryWorkspaces = DirectoryWorkspace.list()
        guard !directoryWorkspaces.isEmpty else { return workspaces }

        let existingIds = Set(workspaces.map(\.id))
        let existingNames = Set(workspaces.map(\.name))

        displayManager.refreshScreens()
        let screens = displayManager.screens.map { WorkspaceScreen(from: $0) }

        var updatedWorkspaces = workspaces
        var migratedCount = 0

        for directoryWorkspace in directoryWorkspaces {
            if existingIds.contains(directoryWorkspace.id) || existingNames.contains(directoryWorkspace.name) {
                continue
            }
            updatedWorkspaces.append(directoryWorkspace.toWorkspace(screens: screens))
            migratedCount += 1
        }

        if migratedCount > 0 {
            saveWorkspaces(updatedWorkspaces)
            print("Migrated \(migratedCount) directory workspace(s) into SavedWorkspaces")
        }

        return updatedWorkspaces
    }
}

func createSharedWorkspaceManager() -> SharedWorkspaceManager {
    SharedWorkspaceManager()
}
