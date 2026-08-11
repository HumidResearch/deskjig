//  WorkspaceHandle.swift
//  DeskJigShared

import Foundation

/// Result of a workspace restoration operation.
public struct WorkspaceRestorationResult: Sendable {
    /// Number of windows successfully restored
    public let success: Int

    /// Number of windows that failed to restore
    public let failed: Int

    /// The workspace that was restored
    public let workspace: Workspace

    /// Whether all windows were restored successfully
    public var isComplete: Bool { failed == 0 }

    /// Accuracy as a percentage (0.0 to 1.0)
    public var accuracy: Double {
        let total = success + failed
        guard total > 0 else { return 1.0 }
        return Double(success) / Double(total)
    }

    internal init(workspace: Workspace, success: Int, failed: Int) {
        self.workspace = workspace
        self.success = success
        self.failed = failed
    }
}

/// A chainable wrapper for workspace operations.
///
/// `WorkspaceHandle` provides a fluent, chainable API for querying and mutating workspaces.
/// It wraps an underlying `Workspace` model and tracks changes that need to be persisted.
///
/// The handle supports method chaining for mutations, allowing multiple changes to be
/// batched together before saving:
///
/// ```swift
/// Workspaces.find(name: "Development")?
///     .rename("Dev Setup")
///     .setIcon("🛠️")
///     .save()
/// ```
///
/// ## Topics
///
/// ### Reading Workspace Data
/// - ``id``
/// - ``name``
/// - ``icon``
/// - ``keyboardShortcut``
/// - ``windowCount``
/// - ``windows``
/// - ``screens``
/// - ``createdAt``
/// - ``lastActivatedAt``
/// - ``updatedAt``
/// - ``underlyingWorkspace``
///
/// ### Modifying Workspaces
/// - ``rename(_:)``
/// - ``setIcon(_:)``
/// - ``setKeyboardShortcut(_:)``
/// - ``save()``
///
/// ### Restoring Workspaces
/// - ``restore(onRestore:onFailure:)``
/// - ``restore(screenMappings:onRestore:onFailure:)``
/// - ``restoreAsync()``
///
/// ### Other Operations
/// - ``delete()``
/// - ``duplicate(name:icon:)``
/// - ``recapture(screenIndices:)``
public final class WorkspaceHandle {

    /// The underlying workspace model
    private var workspace: Workspace

    /// Reference to WorkspaceManager via FluentServices
    private var workspaceManager: WorkspaceManager? {
        return FluentServices.shared.workspaceManager
    }

    // MARK: - Initialization

    /// Creates a WorkspaceHandle wrapping an existing workspace.
    ///
    /// - Parameter workspace: The workspace model to wrap
    internal init(workspace: Workspace) {
        self.workspace = workspace
    }

    // MARK: - Read-Only Properties

    /// The workspace's unique identifier.
    ///
    /// This UUID is generated when the workspace is first created and remains constant
    /// throughout the workspace's lifetime, even across renames and updates.
    ///
    /// ## Example
    ///
    /// ```swift
    /// let handle = Workspaces.find(name: "Development")
    /// print("Workspace ID: \(handle?.id ?? UUID())")
    /// ```
    ///
    /// ## See Also
    /// - ``underlyingWorkspace``
    public var id: UUID { workspace.id }

    /// The workspace's display name.
    ///
    /// This is the human-readable name shown in the UI and used for workspace lookups.
    /// To change the name, use ``rename(_:)`` followed by ``save()``.
    ///
    /// ## Example
    ///
    /// ```swift
    /// for workspace in Workspaces.all() {
    ///     print("Found workspace: \(workspace.name)")
    /// }
    /// ```
    ///
    /// ## See Also
    /// - ``rename(_:)``
    public var name: String { workspace.name }

    /// The workspace's icon (emoji or SF Symbol name).
    ///
    /// Icons are optional and can be either an emoji character (e.g., "🛠️") or an
    /// SF Symbol name (e.g., "hammer.fill"). Returns `nil` if no icon is set.
    ///
    /// ## Example
    ///
    /// ```swift
    /// if let icon = workspace.icon {
    ///     print("Icon: \(icon)")
    /// } else {
    ///     print("No icon set")
    /// }
    /// ```
    ///
    /// ## See Also
    /// - ``setIcon(_:)``
    public var icon: String? { workspace.icon }

    /// The keyboard shortcut assigned to this workspace.
    ///
    /// When set, users can quickly restore this workspace using the configured
    /// key combination. Returns `nil` if no shortcut is assigned.
    ///
    /// ## Example
    ///
    /// ```swift
    /// if let shortcut = workspace.keyboardShortcut {
    ///     print("Press \(shortcut) to restore this workspace")
    /// }
    /// ```
    ///
    /// ## See Also
    /// - ``setKeyboardShortcut(_:)``
    public var keyboardShortcut: WorkspaceKeyboardShortcut? { workspace.keyboardShortcut }

    /// Number of windows in this workspace.
    ///
    /// Returns the count of `WorkspaceWindow` objects saved in this workspace.
    /// This count reflects the state when the workspace was last captured or recaptured.
    ///
    /// ## Example
    ///
    /// ```swift
    /// let devWorkspace = Workspaces.find(name: "Development")
    /// print("Development has \(devWorkspace?.windowCount ?? 0) windows")
    /// ```
    ///
    /// ## See Also
    /// - ``windows``
    /// - ``recapture(screenIndices:)``
    public var windowCount: Int { workspace.windows.count }

    /// The windows contained in this workspace.
    ///
    /// Returns an array of `WorkspaceWindow` objects representing each window's
    /// position, size, application, and other metadata at the time of capture.
    ///
    /// ## Example
    ///
    /// ```swift
    /// let workspace = Workspaces.find(name: "Development")
    /// for window in workspace?.windows ?? [] {
    ///     print("\(window.appName): \(window.frame)")
    /// }
    /// ```
    ///
    /// ## See Also
    /// - ``windowCount``
    /// - ``recapture(screenIndices:)``
    public var windows: [WorkspaceWindow] { workspace.windows }

    /// The screen configuration when this workspace was captured.
    ///
    /// Contains information about each display's resolution, position, and identifier
    /// at the time the workspace was saved. This is used during restoration to map
    /// windows to the correct screens, even if the display configuration has changed.
    ///
    /// Returns `nil` if screen information was not captured (older workspaces).
    ///
    /// ## Example
    ///
    /// ```swift
    /// if let screens = workspace.screens {
    ///     print("Captured with \(screens.count) displays")
    ///     for (index, screen) in screens.enumerated() {
    ///         print("Screen \(index): \(screen.frame)")
    ///     }
    /// }
    /// ```
    ///
    /// ## See Also
    /// - ``restore(screenMappings:onRestore:onFailure:)``
    public var screens: [WorkspaceScreen]? { workspace.screens }

    /// When this workspace was created.
    ///
    /// The timestamp when the workspace was first saved. This date never changes
    /// after initial creation.
    ///
    /// ## Example
    ///
    /// ```swift
    /// let workspace = Workspaces.find(name: "Development")
    /// let formatter = DateFormatter()
    /// formatter.dateStyle = .medium
    /// print("Created: \(formatter.string(from: workspace?.createdAt ?? Date()))")
    /// ```
    ///
    /// ## See Also
    /// - ``lastActivatedAt``
    /// - ``updatedAt``
    public var createdAt: Date { workspace.createdAt }

    /// When this workspace was last activated/restored.
    ///
    /// Updated each time the workspace is successfully restored. Returns `nil` if
    /// the workspace has never been restored since creation.
    ///
    /// ## Example
    ///
    /// ```swift
    /// // Get most recently used workspaces
    /// let recentWorkspaces = Workspaces.all().sortedByRecent()
    /// for workspace in recentWorkspaces.prefix(5) {
    ///     if let lastUsed = workspace.lastActivatedAt {
    ///         print("\(workspace.name): last used \(lastUsed)")
    ///     }
    /// }
    /// ```
    ///
    /// ## See Also
    /// - ``createdAt``
    /// - ``updatedAt``
    public var lastActivatedAt: Date? { workspace.lastActivatedAt }

    /// When this workspace was last updated.
    ///
    /// This timestamp is updated whenever workspace metadata or windows are modified.
    /// Returns `nil` for workspaces that have never been modified after creation.
    ///
    /// ## Example
    ///
    /// ```swift
    /// if let updated = workspace.updatedAt {
    ///     print("Last modified: \(updated)")
    /// }
    /// ```
    ///
    /// ## See Also
    /// - ``createdAt``
    /// - ``lastActivatedAt``
    public var updatedAt: Date? { workspace.updatedAt }

    /// The underlying Workspace model (for advanced use cases).
    ///
    /// Provides direct access to the wrapped `Workspace` struct for scenarios
    /// where the fluent API is insufficient. Use with caution as modifications
    /// to this object will not be tracked by the handle.
    ///
    /// ## Example
    ///
    /// ```swift
    /// let workspace = Workspaces.find(name: "Development")?.underlyingWorkspace
    /// // Use workspace directly for custom serialization, etc.
    /// let encoder = JSONEncoder()
    /// let data = try? encoder.encode(workspace)
    /// ```
    ///
    /// ## See Also
    /// - ``id``
    /// - ``windows``
    public var underlyingWorkspace: Workspace { workspace }

    // MARK: - Chainable Mutations

    /// Renames the workspace.
    ///
    /// Changes the display name of the workspace. This is a staged change that
    /// is not persisted until ``save()`` is called, allowing multiple mutations
    /// to be batched together.
    ///
    /// - Parameter newName: The new name for the workspace. Can be any non-empty string.
    ///
    /// - Returns: Self for method chaining.
    ///
    /// - Important: Call ``save()`` to persist the change. Without saving, the rename
    ///   will be lost when the handle is deallocated.
    ///
    /// ## Example
    ///
    /// ```swift
    /// // Simple rename
    /// Workspaces.find(name: "Development")?
    ///     .rename("Dev Environment")
    ///     .save()
    ///
    /// // Batch multiple changes
    /// Workspaces.find(name: "Old Name")?
    ///     .rename("New Name")
    ///     .setIcon("🚀")
    ///     .save()
    /// ```
    ///
    /// ## See Also
    /// - ``name``
    /// - ``save()``
    @discardableResult
    public func rename(_ newName: String) -> WorkspaceHandle {
        workspace = workspace.withNewName(newName)
        return self
    }

    /// Sets the workspace icon.
    ///
    /// Assigns an icon to the workspace for visual identification in the UI.
    /// Icons can be emoji characters or SF Symbol names. This is a staged change
    /// that requires ``save()`` to persist.
    ///
    /// - Parameter icon: The new icon to display. Can be:
    ///   - An emoji character (e.g., "🛠️", "📱", "🎨")
    ///   - An SF Symbol name (e.g., "hammer.fill", "folder")
    ///   - `nil` to clear the icon (note: currently `nil` does not clear existing icons)
    ///
    /// - Returns: Self for method chaining.
    ///
    /// - Important: Call ``save()`` to persist the change.
    ///
    /// ## Example
    ///
    /// ```swift
    /// // Set an emoji icon
    /// Workspaces.find(name: "Development")?
    ///     .setIcon("💻")
    ///     .save()
    ///
    /// // Set an SF Symbol icon
    /// Workspaces.find(name: "Design")?
    ///     .setIcon("paintbrush.fill")
    ///     .save()
    /// ```
    ///
    /// ## See Also
    /// - ``icon``
    /// - ``save()``
    @discardableResult
    public func setIcon(_ icon: String?) -> WorkspaceHandle {
        if let icon = icon {
            workspace = workspace.withNewIcon(icon)
        }
        return self
    }

    /// Sets the keyboard shortcut for this workspace.
    ///
    /// Assigns a global keyboard shortcut that can be used to quickly restore
    /// this workspace from anywhere in macOS. This is a staged change that
    /// requires ``save()`` to persist.
    ///
    /// - Parameter shortcut: The keyboard shortcut to assign, or `nil` to remove
    ///   any existing shortcut.
    ///
    /// - Returns: Self for method chaining.
    ///
    /// - Important: Call ``save()`` to persist the change.
    ///
    /// - Note: Keyboard shortcuts must be unique across all workspaces. If the
    ///   shortcut conflicts with another workspace, the save may fail or the
    ///   previous binding may be removed.
    ///
    /// ## Example
    ///
    /// ```swift
    /// // Assign a shortcut
    /// Workspaces.find(name: "Development")?
    ///     .setKeyboardShortcut(WorkspaceKeyboardShortcut(key: "1", modifiers: [.command, .control]))
    ///     .save()
    ///
    /// // Remove a shortcut
    /// Workspaces.find(name: "Development")?
    ///     .setKeyboardShortcut(nil)
    ///     .save()
    /// ```
    ///
    /// ## See Also
    /// - ``keyboardShortcut``
    /// - ``save()``
    @discardableResult
    public func setKeyboardShortcut(_ shortcut: WorkspaceKeyboardShortcut?) -> WorkspaceHandle {
        workspace = workspace.withNewKeyboardShortcut(shortcut)
        return self
    }

    /// Saves any pending changes to the workspace.
    ///
    /// Persists all staged changes (rename, icon, keyboard shortcut) to the
    /// workspace storage.
    ///
    /// This method is typically called at the end of a chain of mutations:
    ///
    /// ```swift
    /// workspace.rename("New Name").setIcon("🚀").save()
    /// ```
    ///
    /// - Returns: Self for continued chaining if save succeeded, or `nil` if:
    ///   - The `WorkspaceManager` is not available (FluentServices not configured)
    ///   - The workspace no longer exists (was deleted elsewhere)
    ///
    /// ## Example
    ///
    /// ```swift
    /// // Basic save with error handling
    /// if let saved = Workspaces.find(name: "Development")?.rename("Dev").save() {
    ///     print("Saved workspace: \(saved.name)")
    /// } else {
    ///     print("Failed to save workspace")
    /// }
    ///
    /// // Chained mutations with save
    /// Workspaces.find(name: "Old Project")?
    ///     .rename("New Project")
    ///     .setIcon("📁")
    ///     .setKeyboardShortcut(nil)
    ///     .save()
    /// ```
    ///
    /// ## See Also
    /// - ``rename(_:)``
    /// - ``setIcon(_:)``
    /// - ``setKeyboardShortcut(_:)``
    @MainActor
    @discardableResult
    public func save() -> WorkspaceHandle? {
        guard let manager = workspaceManager else {
            return nil
        }

        // Find the original workspace in the manager's list
        guard let original = manager.savedWorkspaces.first(where: { $0.id == workspace.id }) else {
            return nil
        }

        // Update metadata through the manager
        manager.updateWorkspaceMetadata(
            for: original,
            newName: workspace.name,
            newIcon: workspace.icon ?? ""
        )

        // Refresh our workspace from the manager's updated list
        if let updated = manager.savedWorkspaces.first(where: { $0.id == workspace.id }) {
            workspace = updated
        }

        return self
    }

    // MARK: - Restoration

    /// Restores this workspace synchronously.
    ///
    /// Opens all windows in the workspace at their saved positions and sizes.
    /// Applications that are not running will be launched. Windows are positioned
    /// on the same screens they were captured on, or the best available screen
    /// if the original display is no longer connected.
    ///
    /// The restoration process:
    /// 1. Launches any required applications that are not running
    /// 2. Waits for windows to become available
    /// 3. Positions each window according to its saved frame
    ///
    /// - Parameters:
    ///   - onRestore: Optional callback invoked when the restoration process completes
    ///     successfully. Called on the main thread.
    ///   - onFailure: Optional callback invoked for each window that fails to restore.
    ///     Receives the `WorkspaceWindow` that failed and an optional error message
    ///     describing the failure reason.
    ///
    /// - Returns: A ``WorkspaceRestorationResult`` containing:
    ///   - `success`: Number of windows successfully restored
    ///   - `failed`: Number of windows that failed to restore
    ///   - `workspace`: The workspace that was restored
    ///   - `isComplete`: `true` if all windows were restored
    ///   - `accuracy`: Restoration accuracy as a percentage (0.0 to 1.0)
    ///
    /// ## Example
    ///
    /// ```swift
    /// // Simple restoration
    /// let result = Workspaces.find(name: "Development")?.restore()
    /// print("Restored \(result?.success ?? 0) windows")
    ///
    /// // Restoration with callbacks
    /// if let workspace = Workspaces.find(name: "Development") {
    ///     Task {
    ///         await workspace.restore(
    ///             onRestore: {
    ///                 print("Restoration complete!")
    ///             },
    ///             onFailure: { window, error in
    ///                 print("Failed to restore \(window.appName): \(error ?? "unknown error")")
    ///             }
    ///         )
    ///     }
    /// }
    ///
    /// // Check restoration accuracy
    /// Task {
    ///     let result = await workspace.restore()
    ///     if result.isComplete {
    ///         print("All windows restored successfully")
    ///     } else {
    ///         print("Restored \(result.accuracy * 100)% of windows")
    ///     }
    /// }
    /// ```
    ///
    /// ## See Also
    /// - ``restore(screenMappings:onRestore:onFailure:)``
    /// - ``restoreAsync()``
    /// - ``WorkspaceRestorationResult``
    @discardableResult
    public func restore(
        onRestore: (() -> Void)? = nil,
        onFailure: ((WorkspaceWindow, String?) -> Void)? = nil
    ) async -> WorkspaceRestorationResult {
        guard let manager = workspaceManager else {
            return WorkspaceRestorationResult(workspace: workspace, success: 0, failed: workspace.windows.count)
        }

        let result = await manager.restoreWorkspace(
            workspace,
            onRestore: onRestore,
            onFailure: onFailure
        )

        return WorkspaceRestorationResult(
            workspace: workspace,
            success: result.windowsRestored,
            failed: result.windowsFailed + result.windowsSkipped
        )
    }

    /// Restores this workspace with custom screen mappings.
    ///
    /// Use this method when the current display configuration differs from when the
    /// workspace was captured. Screen mappings allow you to redirect windows from
    /// their original screens to different screens in the current configuration.
    ///
    /// This is particularly useful when:
    /// - You've changed your monitor setup (added/removed displays)
    /// - Display indices have changed (e.g., external monitor is now primary)
    /// - You want to restore a workspace captured on a different machine
    ///
    /// - Parameters:
    ///   - screenMappings: An array of tuples mapping workspace screen indices to
    ///     current screen indices. Each tuple contains:
    ///     - `workspaceScreenIndex`: The screen index from when the workspace was captured
    ///     - `currentScreenIndex`: The screen index to restore windows to now
    ///   - onRestore: Optional callback invoked when restoration completes.
    ///   - onFailure: Optional callback invoked for each window that fails to restore.
    ///
    /// - Returns: A ``WorkspaceRestorationResult`` with restoration statistics.
    ///
    /// ## Example
    ///
    /// ```swift
    /// // Workspace was captured with 2 monitors, but now you only have 1
    /// // Move all windows from screen 1 to screen 0
    /// let mappings = [
    ///     (workspaceScreenIndex: 0, currentScreenIndex: 0),
    ///     (workspaceScreenIndex: 1, currentScreenIndex: 0)
    /// ]
    /// workspace.restore(screenMappings: mappings)
    ///
    /// // Swap monitors: external is now primary
    /// let swappedMappings = [
    ///     (workspaceScreenIndex: 0, currentScreenIndex: 1),
    ///     (workspaceScreenIndex: 1, currentScreenIndex: 0)
    /// ]
    /// workspace.restore(screenMappings: swappedMappings)
    /// ```
    ///
    /// ## See Also
    /// - ``restore(onRestore:onFailure:)``
    /// - ``screens``
    @discardableResult
    public func restore(
        screenMappings: [(workspaceScreenIndex: Int, currentScreenIndex: Int)],
        onRestore: (() -> Void)? = nil,
        onFailure: ((WorkspaceWindow, String?) -> Void)? = nil
    ) async -> WorkspaceRestorationResult {
        guard let manager = workspaceManager else {
            return WorkspaceRestorationResult(workspace: workspace, success: 0, failed: workspace.windows.count)
        }

        let result = await manager.restoreWorkspaceWithMapping(
            workspace,
            screenMappings: screenMappings,
            onRestore: onRestore,
            onFailure: onFailure
        )

        return WorkspaceRestorationResult(
            workspace: workspace,
            success: result.windowsRestored,
            failed: result.windowsFailed + result.windowsSkipped
        )
    }

    /// Restores this workspace asynchronously.
    ///
    /// An async/await wrapper around ``restore(onRestore:onFailure:)``
    /// for use in Swift concurrency contexts. The restoration work is performed on
    /// the main thread, but this method can be awaited from any context.
    ///
    /// - Returns: A ``WorkspaceRestorationResult`` with restoration statistics.
    ///
    /// ## Example
    ///
    /// ```swift
    /// // Use in an async context
    /// Task {
    ///     if let workspace = Workspaces.find(name: "Development") {
    ///         let result = await workspace.restoreAsync()
    ///         print("Restored \(result.success) of \(result.success + result.failed) windows")
    ///     }
    /// }
    ///
    /// // Use in a SwiftUI view
    /// Button("Restore Workspace") {
    ///     Task {
    ///         let result = await workspace.restoreAsync()
    ///         showingAlert = !result.isComplete
    ///     }
    /// }
    /// ```
    ///
    /// ## See Also
    /// - ``restore(onRestore:onFailure:)``
    public func restoreAsync() async -> WorkspaceRestorationResult {
        await restore(onRestore: nil, onFailure: nil)
    }

    // MARK: - Other Operations

    /// Deletes this workspace permanently.
    ///
    /// Removes the workspace from storage. This operation cannot be undone.
    ///
    /// After deletion, this handle becomes invalid and should not be used further.
    /// Any attempts to call methods on this handle after deletion may produce
    /// unexpected results.
    ///
    /// - Returns: `true` if the deletion succeeded, `false` if:
    ///   - The `WorkspaceManager` is not available
    ///   - The workspace was already deleted
    ///
    /// ## Example
    ///
    /// ```swift
    /// // Delete a workspace by name
    /// if let deleted = Workspaces.find(name: "Old Project")?.delete() {
    ///     print(deleted ? "Workspace deleted" : "Failed to delete")
    /// }
    ///
    /// // Delete with confirmation
    /// if let workspace = Workspaces.find(name: "Temporary") {
    ///     let confirmed = showConfirmationDialog("Delete '\(workspace.name)'?")
    ///     if confirmed {
    ///         workspace.delete()
    ///     }
    /// }
    /// ```
    ///
    /// ## See Also
    /// - ``duplicate(name:icon:)``
    @MainActor
    @discardableResult
    public func delete() -> Bool {
        guard let manager = workspaceManager else {
            return false
        }

        manager.deleteWorkspace(workspace)
        return true
    }

    /// Creates a duplicate of this workspace with a new ID.
    ///
    /// Creates a complete copy of the workspace including all window configurations.
    /// The duplicate is immediately saved and persisted - no need to call ``save()``.
    ///
    /// This is useful for:
    /// - Creating variations of a workspace for different contexts
    /// - Backing up a workspace before making changes
    /// - Creating templates from existing workspaces
    ///
    /// - Parameters:
    ///   - name: The name for the duplicate. Defaults to "Copy of [original name]".
    ///   - icon: The icon for the duplicate. Defaults to the original workspace's icon.
    ///
    /// - Returns: A new ``WorkspaceHandle`` for the duplicated workspace, or `nil` if:
    ///   - The `WorkspaceManager` is not available
    ///   - The duplication operation failed
    ///
    /// ## Example
    ///
    /// ```swift
    /// // Simple duplication with default name
    /// let copy = Workspaces.find(name: "Development")?.duplicate()
    /// print("Created: \(copy?.name ?? "failed")")  // "Copy of Development"
    ///
    /// // Duplicate with custom name and icon
    /// let variant = Workspaces.find(name: "Development")?
    ///     .duplicate(name: "Development - Staging", icon: "🧪")
    ///
    /// // Create a backup before modifying
    /// if let workspace = Workspaces.find(name: "Production") {
    ///     workspace.duplicate(name: "Production (Backup)")
    ///     workspace.recapture()
    /// }
    /// ```
    ///
    /// ## See Also
    /// - ``delete()``
    /// - ``recapture(screenIndices:)``
    @MainActor
    public func duplicate(name: String? = nil, icon: String? = nil) -> WorkspaceHandle? {
        guard let manager = workspaceManager else {
            return nil
        }

        let newName = name ?? "Copy of \(workspace.name)"

        // Use the manager's duplicateWorkspace method which properly persists
        guard let duplicatedWorkspace = manager.duplicateWorkspace(workspace, newName: newName) else {
            return nil
        }

        // If a custom icon was provided, update it
        if let customIcon = icon, customIcon != workspace.icon {
            manager.updateWorkspaceMetadata(
                for: duplicatedWorkspace,
                newName: duplicatedWorkspace.name,
                newIcon: customIcon
            )
        }

        // Return a handle to the persisted duplicate
        if let updated = manager.savedWorkspaces.first(where: { $0.id == duplicatedWorkspace.id }) {
            return WorkspaceHandle(workspace: updated)
        }

        return WorkspaceHandle(workspace: duplicatedWorkspace)
    }

    /// Recaptures this workspace's windows from the current screen state.
    ///
    /// Updates the workspace with the current window positions, sizes, and
    /// configurations. This is useful for refreshing a workspace after you've
    /// manually rearranged windows to better positions.
    ///
    /// The recapture process:
    /// 1. Captures all visible windows on the specified screens
    /// 2. Updates the workspace's window list with new positions and sizes
    /// 3. Updates screen configuration information
    /// 4. Persists the changes automatically (no need to call ``save()``)
    ///
    /// - Parameter screenIndices: A set of screen indices to capture windows from.
    ///   Pass an empty set (the default) to capture windows from all screens.
    ///
    /// - Returns: Self for method chaining if recapture succeeded, or `nil` if:
    ///   - The `WorkspaceManager` is not available
    ///   - The workspace no longer exists in storage
    ///
    /// ## Example
    ///
    /// ```swift
    /// // Recapture all screens
    /// await Workspaces.find(name: "Development")?.recapture()
    ///
    /// // Recapture only the primary screen
    /// await Workspaces.find(name: "Development")?.recapture(screenIndices: [0])
    ///
    /// // Recapture specific screens
    /// await Workspaces.find(name: "Multi-Monitor Setup")?
    ///     .recapture(screenIndices: [0, 1])
    ///
    /// // Chain with other operations
    /// await Workspaces.find(name: "Development")?
    ///     .recapture()?
    ///     .rename("Development (Updated)")
    ///     .save()
    /// ```
    ///
    /// ## See Also
    /// - ``windows``
    /// - ``screens``
    /// - ``duplicate(name:icon:)``
    @discardableResult
    public func recapture(screenIndices: Set<Int> = []) async -> WorkspaceHandle? {
        guard let manager = workspaceManager else {
            return nil
        }

        // Update the workspace windows through the manager
        await manager.updateWorkspaceWindows(
            for: workspace,
            screenIndices: screenIndices
        )

        // Refresh our workspace from the manager's updated list
        if let updated = manager.savedWorkspaces.first(where: { $0.id == workspace.id }) {
            workspace = updated
            return self
        }

        return nil
    }
}

// MARK: - Equatable

extension WorkspaceHandle: Equatable {
    public static func == (lhs: WorkspaceHandle, rhs: WorkspaceHandle) -> Bool {
        return lhs.id == rhs.id
    }
}

// MARK: - Hashable

extension WorkspaceHandle: Hashable {
    public func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

// MARK: - CustomStringConvertible

extension WorkspaceHandle: CustomStringConvertible {
    public var description: String {
        let iconStr = icon.map { " \($0)" } ?? ""
        return "WorkspaceHandle(\(name)\(iconStr), \(windowCount) windows)"
    }
}

// MARK: - Array Extensions

extension Array where Element == WorkspaceHandle {
    /// Filters workspaces whose names contain the given string.
    ///
    /// - Parameter substring: The string to search for (case-insensitive)
    /// - Returns: Filtered array of workspace handles
    public func named(containing substring: String) -> [WorkspaceHandle] {
        return filter { $0.name.localizedCaseInsensitiveContains(substring) }
    }

    /// Filters workspaces that contain windows from the given app.
    ///
    /// - Parameter bundleID: The bundle identifier to search for
    /// - Returns: Filtered array of workspace handles
    public func containingApp(bundleID: String) -> [WorkspaceHandle] {
        return filter { handle in
            handle.windows.contains { $0.bundleIdentifier == bundleID }
        }
    }

    /// Returns workspaces sorted by most recently activated.
    ///
    /// - Returns: Sorted array with most recent first
    public func sortedByRecent() -> [WorkspaceHandle] {
        return sorted { lhs, rhs in
            let lhsDate = lhs.lastActivatedAt ?? lhs.createdAt
            let rhsDate = rhs.lastActivatedAt ?? rhs.createdAt
            return lhsDate > rhsDate
        }
    }

    /// Returns workspaces sorted alphabetically by name.
    ///
    /// - Returns: Sorted array
    public func sortedByName() -> [WorkspaceHandle] {
        return sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}
