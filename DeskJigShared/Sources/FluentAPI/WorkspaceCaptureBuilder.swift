//  WorkspaceCaptureBuilder.swift
//  DeskJigShared

import Foundation

/// Builder for capturing and creating new workspaces.
///
/// Provides a fluent interface for configuring workspace capture:
/// ```swift
/// Workspace.capture()
///     .named("My Workspace")
///     .icon("🚀")
///     .screens([0, 1])
///     .save()
/// ```
public class WorkspaceCaptureBuilder {

    private var name: String?
    private var icon: String?
    private var selectiveMode: Bool = false
    private var screenIndices: Set<Int> = []
    private var chromeModifications: [UUID: ChromeModification] = [:]
    private var openByPathModifications: [UUID: OpenByPathModification] = [:]

    /// Reference to WorkspaceManager via FluentServices
    private var workspaceManager: WorkspaceManager? {
        return FluentServices.shared.workspaceManager
    }

    // MARK: - Initialization

    internal init() {}

    // MARK: - Configuration Methods

    /// Sets the name for the new workspace.
    ///
    /// - Parameter name: The workspace name
    /// - Returns: Self for chaining
    @discardableResult
    public func named(_ name: String) -> Self {
        self.name = name
        return self
    }

    /// Sets the icon for the new workspace.
    ///
    /// - Parameter icon: The icon (emoji or SF Symbol name)
    /// - Returns: Self for chaining
    @discardableResult
    public func icon(_ icon: String) -> Self {
        self.icon = icon
        return self
    }

    /// Enables selective mode for capturing.
    ///
    /// In selective mode, only windows on specified screens are captured.
    ///
    /// - Parameter selective: Whether to use selective mode
    /// - Returns: Self for chaining
    @discardableResult
    public func selective(_ selective: Bool = true) -> Self {
        self.selectiveMode = selective
        return self
    }

    /// Specifies which screens to capture windows from.
    ///
    /// - Parameter indices: Set of screen indices (0-based)
    /// - Returns: Self for chaining
    @discardableResult
    public func screens(_ indices: Set<Int>) -> Self {
        self.screenIndices = indices
        return self
    }

    /// Specifies screens to capture using an array.
    ///
    /// - Parameter indices: Array of screen indices (0-based)
    /// - Returns: Self for chaining
    @discardableResult
    public func screens(_ indices: [Int]) -> Self {
        self.screenIndices = Set(indices)
        return self
    }

    /// Specifies a single screen to capture.
    ///
    /// - Parameter index: The screen index (0-based)
    /// - Returns: Self for chaining
    @discardableResult
    public func screen(_ index: Int) -> Self {
        self.screenIndices = [index]
        return self
    }

    /// Adds a Chrome modification for a specific window.
    ///
    /// Chrome modifications allow you to specify profile and tab settings
    /// for Chrome windows in the workspace.
    ///
    /// - Parameters:
    ///   - windowId: The UUID of the Chrome window to modify
    ///   - modification: The Chrome modification settings
    /// - Returns: Self for chaining
    @discardableResult
    public func chromeModification(for windowId: UUID, _ modification: ChromeModification) -> Self {
        self.chromeModifications[windowId] = modification
        return self
    }

    /// Adds Chrome tabs to be restored for a window.
    ///
    /// This is a convenience method for setting up Chrome tab restoration.
    ///
    /// - Parameters:
    ///   - windowId: The UUID of the Chrome window
    ///   - tabURLs: Array of URLs to restore as tabs
    ///   - profileDirectory: Optional profile directory path
    ///   - profileDisplayName: Optional profile display name
    /// - Returns: Self for chaining
    @discardableResult
    public func withChromeTabs(
        for windowId: UUID,
        tabURLs: [String],
        profileDirectory: String? = nil,
        profileDisplayName: String? = nil
    ) -> Self {
        let modification = ChromeModification(
            tabURLs: tabURLs,
            profileDirectory: profileDirectory,
            profileDisplayName: profileDisplayName,
            profileHostedDomain: nil,
            profileMatchMode: .specific
        )
        return chromeModification(for: windowId, modification)
    }

    /// Adds an open-by-path modification for a specific window.
    ///
    /// Open-by-path modifications allow you to specify the directory path
    /// that apps like Cursor, Ghostty, or Terminal should open to.
    ///
    /// - Parameters:
    ///   - windowId: The UUID of the window to modify
    ///   - modification: The open-by-path modification settings
    /// - Returns: Self for chaining
    @discardableResult
    public func openByPathModification(for windowId: UUID, _ modification: OpenByPathModification) -> Self {
        self.openByPathModifications[windowId] = modification
        return self
    }

    /// Sets the open path for a window.
    ///
    /// This is a convenience method for apps like Cursor, Ghostty, or Terminal
    /// that can be launched into a specific directory.
    ///
    /// - Parameters:
    ///   - windowId: The UUID of the window
    ///   - bundleIdentifier: The app's bundle identifier
    ///   - path: The directory path to open
    ///   - windowTitle: Optional window title (for matching)
    /// - Returns: Self for chaining
    @discardableResult
    public func withOpenPath(
        for windowId: UUID,
        bundleIdentifier: String,
        path: String,
        windowTitle: String = ""
    ) -> Self {
        let modification = OpenByPathModification(
            bundleIdentifier: bundleIdentifier,
            windowTitle: windowTitle,
            openPath: path
        )
        return openByPathModification(for: windowId, modification)
    }

    // MARK: - Capture Operations

    /// Captures current windows and creates a WorkspaceHandle.
    ///
    /// This captures the current window state but does not save it.
    /// Call `save()` on the returned handle to persist the workspace.
    ///
    /// - Returns: WorkspaceHandle for the captured workspace, or nil if capture failed
    public func capture() async -> WorkspaceHandle? {
        guard let manager = workspaceManager else {
            return nil
        }

        guard let workspaceName = name else {
            return nil
        }

        // Capture current windows
        let captured = await manager.captureCurrentWindows(
            selectiveMode: selectiveMode,
            screenIndices: screenIndices
        )

        // Create workspace with captured windows
        let workspace = Workspace(
            name: workspaceName,
            icon: icon,
            workspaceWindows: captured.windows,
            screens: captured.screens
        )

        let handle = WorkspaceHandle(workspace: workspace)
        return handle
    }

    /// Captures current windows and saves as a new workspace.
    ///
    /// This is equivalent to calling `await capture()?.save()`.
    ///
    /// - Returns: WorkspaceHandle for the saved workspace, or nil if failed
    public func save() async -> WorkspaceHandle? {
        guard let manager = workspaceManager else {
            return nil
        }

        guard let workspaceName = name else {
            return nil
        }

        let workspaceId = UUID()

        // Save through the manager which handles everything
        await manager.saveCurrentWorkspace(
            id: workspaceId,
            name: workspaceName,
            icon: icon,
            selectiveMode: selectiveMode,
            screenIndices: screenIndices,
            chromeModifications: chromeModifications,
            openByPathModifications: openByPathModifications
        )

        // Return a handle for the newly created workspace
        return Workspaces.find(id: workspaceId)
    }

    /// Captures current windows without saving.
    ///
    /// Returns the raw capture result for inspection before saving.
    ///
    /// - Returns: Tuple of (windows, screens), or nil if capture failed
    public func preview() async -> (windows: [WorkspaceWindow], screens: [WorkspaceScreen])? {
        guard let manager = workspaceManager else {
            return nil
        }

        return await manager.captureCurrentWindows(
            selectiveMode: selectiveMode,
            screenIndices: screenIndices
        )
    }
}
