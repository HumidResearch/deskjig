//  WorkspaceNamespace.swift
//  DeskJigShared

import Foundation

/// A namespace struct that provides fluent, type-safe access to workspace operations.
///
/// `WorkspaceNamespace` is the core type behind the global `Workspaces` entry point.
/// It uses Swift's `@dynamicMemberLookup` feature to enable intuitive workspace access
/// by name, while also providing explicit query methods for more complex lookups.
///
/// The namespace supports two primary access patterns:
///
/// 1. **Dynamic member lookup** - Access workspaces directly by name using dot syntax:
///    ```swift
///    Workspaces.Development?.restore()
///    Workspaces.WorkSetup?.rename("Office")?.save()
///    ```
///
/// 2. **Explicit query methods** - Use `find`, `all`, `recent`, and `containing` for
///    programmatic access and filtering:
///    ```swift
///    Workspaces.find(name: "Work Setup")?.restore()
///    Workspaces.containing(bundleID: "com.apple.Safari")
///    ```
///
/// All query methods return `WorkspaceHandle` objects (or arrays of them), which
/// provide chainable methods for workspace operations like `restore()`, `rename()`,
/// `delete()`, and `save()`.
///
/// ## Topics
///
/// ### Dynamic Lookup
/// - ``subscript(dynamicMember:)``
///
/// ### Finding Workspaces
/// - ``find(name:)``
/// - ``find(id:)``
/// - ``find(containing:)``
/// - ``all()``
/// - ``recent(limit:)``
///
/// ### Filtering by App
/// - ``containing(bundleID:)``
/// - ``containing(appName:)``
///
/// ### Creating Workspaces
/// - ``capture()``
///
/// ### Statistics
/// - ``count``
/// - ``isEmpty``
@dynamicMemberLookup
public struct WorkspaceNamespace {

    // MARK: - Dynamic Member Lookup

    /// Enables intuitive workspace access using dot syntax like `Workspaces.Development`.
    ///
    /// This subscript powers Swift's `@dynamicMemberLookup` feature, allowing you to
    /// access workspaces by name as if they were properties on the `Workspaces` object.
    /// The lookup is case-insensitive and automatically handles PascalCase/camelCase
    /// conversion to space-separated names.
    ///
    /// The matching algorithm works as follows:
    /// 1. Converts camelCase/PascalCase to space-separated words
    ///    (e.g., `WorkSetup` becomes `"Work Setup"`)
    /// 2. Attempts to find a workspace matching the space-separated name
    /// 3. Falls back to matching the original name if no space-separated match is found
    /// 4. All matching is case-insensitive
    ///
    /// - Parameter name: The workspace name derived from the member access syntax.
    ///   For example, accessing `Workspaces.Development` passes `"Development"` as the name.
    ///
    /// - Returns: A `WorkspaceHandle` if a matching workspace is found, or `nil` if no
    ///   workspace matches the given name.
    ///
    /// ## Example
    ///
    /// ```swift
    /// // Access a workspace named "Development"
    /// Workspaces.Development?.restore()
    ///
    /// // Access a workspace named "Work Setup" using PascalCase
    /// Workspaces.WorkSetup?.restore()
    ///
    /// // Access a workspace named "my development" (case-insensitive)
    /// Workspaces.myDevelopment?.restore()
    ///
    /// // Chain operations on the returned handle
    /// Workspaces.Development?.rename("Dev Environment")?.save()
    /// ```
    ///
    /// ## See Also
    /// - ``find(name:)``
    /// - ``WorkspaceHandle``
    public subscript(dynamicMember name: String) -> WorkspaceHandle? {
        // Convert PascalCase/camelCase to space-separated for matching
        // e.g., "WorkSetup" -> "Work Setup", "myDevelopment" -> "my Development"
        let spacedName = name.replacingOccurrences(
            of: "([a-z])([A-Z])",
            with: "$1 $2",
            options: .regularExpression
        )

        return find(name: spacedName) ?? find(name: name)
    }

    // MARK: - Query Methods

    /// Returns all saved workspaces as an array of handles.
    ///
    /// This method retrieves every workspace that has been saved, regardless of
    /// when it was created or last used. The returned array is not sorted in any
    /// particular order; use array extension methods like `sortedByRecent()` or
    /// `sortedByName()` to apply sorting.
    ///
    /// If the workspace manager is not available (e.g., `FluentServices` has not
    /// been configured), this method returns an empty array rather than failing.
    ///
    /// - Returns: An array of `WorkspaceHandle` objects representing all saved
    ///   workspaces. Returns an empty array if no workspaces exist or if the
    ///   workspace manager is unavailable.
    ///
    /// ## Example
    ///
    /// ```swift
    /// // Get all workspaces
    /// let allWorkspaces = Workspaces.all()
    ///
    /// // Iterate over all workspaces
    /// for workspace in Workspaces.all() {
    ///     print("\(workspace.name): \(workspace.windowCount) windows")
    /// }
    ///
    /// // Combine with array extensions for filtering and sorting
    /// let sortedByName = Workspaces.all().sortedByName()
    /// let recentFirst = Workspaces.all().sortedByRecent()
    /// let safariWorkspaces = Workspaces.all().containingApp(bundleID: "com.apple.Safari")
    /// ```
    ///
    /// ## See Also
    /// - ``recent(limit:)``
    /// - ``find(name:)``
    /// - ``count``
    public func all() -> [WorkspaceHandle] {
        guard let manager = FluentServices.shared.workspaceManager else {
            return []
        }
        return manager.savedWorkspaces.map { WorkspaceHandle(workspace: $0) }
    }

    /// Finds a workspace by its display name.
    ///
    /// This method searches for a workspace with the given name using a two-step
    /// matching process:
    /// 1. First attempts an exact, case-sensitive match
    /// 2. Falls back to a case-insensitive match using localized comparison
    ///
    /// If multiple workspaces have names that match case-insensitively (but not
    /// exactly), the first matching workspace is returned. For deterministic
    /// behavior when duplicate names might exist, use ``find(id:)`` instead.
    ///
    /// - Parameter name: The workspace name to search for. The search is
    ///   case-insensitive, so `"development"`, `"Development"`, and `"DEVELOPMENT"`
    ///   all match a workspace named "Development".
    ///
    /// - Returns: A `WorkspaceHandle` for the matching workspace, or `nil` if no
    ///   workspace with the given name exists.
    ///
    /// ## Example
    ///
    /// ```swift
    /// // Find and restore a workspace
    /// Workspaces.find(name: "Development")?.restore()
    ///
    /// // Find and chain multiple operations
    /// Workspaces.find(name: "Work Setup")?
    ///     .rename("Office Setup")?
    ///     .setIcon("briefcase")?
    ///     .save()
    ///
    /// // Safely handle missing workspaces
    /// if let devWorkspace = Workspaces.find(name: "Development") {
    ///     let result = devWorkspace.restore()
    ///     print("Restored \(result.success) windows")
    /// } else {
    ///     print("Workspace not found")
    /// }
    /// ```
    ///
    /// ## See Also
    /// - ``find(id:)``
    /// - ``find(containing:)``
    /// - ``subscript(dynamicMember:)``
    public func find(name: String) -> WorkspaceHandle? {
        guard let manager = FluentServices.shared.workspaceManager else {
            return nil
        }

        // Try exact match first
        if let workspace = manager.savedWorkspaces.first(where: { $0.name == name }) {
            return WorkspaceHandle(workspace: workspace)
        }

        // Try case-insensitive match
        if let workspace = manager.savedWorkspaces.first(where: {
            $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame
        }) {
            return WorkspaceHandle(workspace: workspace)
        }

        return nil
    }

    /// Finds a workspace by its unique identifier.
    ///
    /// Use this method when you need to look up a specific workspace by its UUID,
    /// which is useful when you have stored a workspace ID from a previous session
    /// or received it from another part of the application. Unlike name-based lookups,
    /// ID-based lookups are guaranteed to return the exact workspace you expect.
    ///
    /// Each workspace is assigned a unique UUID when it is created. This ID remains
    /// constant even if the workspace is renamed, and is persisted across app launches.
    ///
    /// - Parameter id: The UUID of the workspace to find. You can obtain a workspace's
    ///   ID from the `id` property of a `WorkspaceHandle`.
    ///
    /// - Returns: A `WorkspaceHandle` for the workspace with the given ID, or `nil`
    ///   if no workspace with that ID exists.
    ///
    /// ## Example
    ///
    /// ```swift
    /// // Store a workspace ID for later use
    /// let savedId = Workspaces.Development?.id
    ///
    /// // Later, retrieve the workspace by ID
    /// if let workspaceId = savedId, let workspace = Workspaces.find(id: workspaceId) {
    ///     Task { await workspace.restore() }
    /// }
    ///
    /// // Use with workspace IDs from external sources
    /// func restoreWorkspace(from notification: Notification) {
    ///     guard let id = notification.userInfo?["workspaceId"] as? UUID,
    ///           let workspace = Workspaces.find(id: id) else { return }
    ///     Task { await workspace.restore() }
    /// }
    /// ```
    ///
    /// ## See Also
    /// - ``find(name:)``
    /// - ``WorkspaceHandle/id``
    public func find(id: UUID) -> WorkspaceHandle? {
        guard let manager = FluentServices.shared.workspaceManager else {
            return nil
        }

        guard let workspace = manager.savedWorkspaces.first(where: { $0.id == id }) else {
            return nil
        }

        return WorkspaceHandle(workspace: workspace)
    }

    /// Finds all workspaces whose names contain a given substring.
    ///
    /// Use this method to search for workspaces when you only know part of the name,
    /// or when you want to find all workspaces that match a naming pattern. The search
    /// is case-insensitive and uses localized string comparison for proper handling
    /// of international characters.
    ///
    /// Unlike ``find(name:)`` which returns a single workspace, this method returns
    /// an array of all matching workspaces, making it useful for fuzzy searches and
    /// batch operations.
    ///
    /// - Parameter substring: The text to search for within workspace names. The
    ///   search is case-insensitive; `"dev"` matches `"Development"`, `"DevOps"`,
    ///   and `"My Dev Setup"`.
    ///
    /// - Returns: An array of `WorkspaceHandle` objects for workspaces whose names
    ///   contain the substring. Returns an empty array if no matches are found.
    ///
    /// ## Example
    ///
    /// ```swift
    /// // Find all workspaces with "dev" in the name
    /// let devWorkspaces = Workspaces.find(containing: "dev")
    /// for workspace in devWorkspaces {
    ///     print("Found: \(workspace.name)")
    /// }
    ///
    /// // Find and restore all "work" related workspaces
    /// for workspace in Workspaces.find(containing: "work") {
    ///     workspace.restore()
    /// }
    ///
    /// // Search for workspaces by project name
    /// let projectWorkspaces = Workspaces.find(containing: "Project Alpha")
    /// ```
    ///
    /// ## See Also
    /// - ``find(name:)``
    /// - ``all()``
    public func find(containing substring: String) -> [WorkspaceHandle] {
        guard let manager = FluentServices.shared.workspaceManager else {
            return []
        }

        return manager.savedWorkspaces
            .filter { $0.name.localizedCaseInsensitiveContains(substring) }
            .map { WorkspaceHandle(workspace: $0) }
    }

    /// Returns the most recently used workspaces, sorted by activation time.
    ///
    /// This method returns workspaces ordered by when they were last restored or
    /// activated, with the most recent first. It is useful for building "recent
    /// workspaces" menus or quickly accessing frequently used workspaces.
    ///
    /// The sorting considers:
    /// - `lastActivatedAt` timestamp if the workspace has been restored at least once
    /// - `createdAt` timestamp as a fallback for workspaces that have never been restored
    ///
    /// - Parameter limit: The maximum number of workspaces to return. Defaults to 5.
    ///   Pass a larger value to retrieve more recent workspaces, or use ``all()``
    ///   with `sortedByRecent()` if you need all workspaces sorted by recency.
    ///
    /// - Returns: An array of `WorkspaceHandle` objects sorted by most recently
    ///   used first, limited to the specified count. Returns an empty array if
    ///   no workspaces exist.
    ///
    /// ## Example
    ///
    /// ```swift
    /// // Get the 5 most recent workspaces (default)
    /// let recentWorkspaces = Workspaces.recent()
    ///
    /// // Get the 3 most recent workspaces
    /// let topThree = Workspaces.recent(limit: 3)
    ///
    /// // Get the single most recently used workspace
    /// if let lastUsed = Workspaces.recent(limit: 1).first {
    ///     print("Last workspace: \(lastUsed.name)")
    ///     lastUsed.restore()
    /// }
    ///
    /// // Build a recent workspaces menu
    /// for workspace in Workspaces.recent(limit: 10) {
    ///     addMenuItem(workspace.name, icon: workspace.icon)
    /// }
    /// ```
    ///
    /// ## See Also
    /// - ``all()``
    /// - ``WorkspaceHandle/lastActivatedAt``
    public func recent(limit: Int = 5) -> [WorkspaceHandle] {
        guard let manager = FluentServices.shared.workspaceManager else {
            return []
        }

        let sorted = manager.savedWorkspaces.sorted { lhs, rhs in
            let lhsDate = lhs.lastActivatedAt ?? lhs.createdAt
            let rhsDate = rhs.lastActivatedAt ?? rhs.createdAt
            return lhsDate > rhsDate
        }

        return sorted.prefix(limit).map { WorkspaceHandle(workspace: $0) }
    }

    /// Returns all workspaces that contain windows from a specific application.
    ///
    /// Use this method to find workspaces that include windows from a particular app,
    /// identified by its bundle identifier. This is useful for finding all workspaces
    /// related to a specific tool or application.
    ///
    /// The search checks the `bundleIdentifier` property of each window in every
    /// workspace. A workspace is included in the results if at least one of its
    /// windows matches the given bundle ID.
    ///
    /// - Parameter bundleID: The bundle identifier of the application to search for.
    ///   Bundle identifiers are case-sensitive and typically follow reverse-DNS
    ///   notation (e.g., `"com.apple.Safari"`, `"com.google.Chrome"`).
    ///
    /// - Returns: An array of `WorkspaceHandle` objects for workspaces that contain
    ///   at least one window from the specified application. Returns an empty array
    ///   if no workspaces contain windows from that app.
    ///
    /// ## Example
    ///
    /// ```swift
    /// // Find all workspaces containing Safari windows
    /// let safariWorkspaces = Workspaces.containing(bundleID: "com.apple.Safari")
    ///
    /// // Find workspaces for a specific IDE
    /// let cursorWorkspaces = Workspaces.containing(bundleID: "com.todesktop.230313mzl4w4u92")
    /// for workspace in cursorWorkspaces {
    ///     print("\(workspace.name) has Cursor windows")
    /// }
    ///
    /// // Check if any workspace uses Chrome
    /// if !Workspaces.containing(bundleID: "com.google.Chrome").isEmpty {
    ///     print("Chrome is used in at least one workspace")
    /// }
    /// ```
    ///
    /// ## See Also
    /// - ``containing(appName:)``
    /// - ``WorkspaceHandle/windows``
    public func containing(bundleID: String) -> [WorkspaceHandle] {
        guard let manager = FluentServices.shared.workspaceManager else {
            return []
        }

        return manager.savedWorkspaces
            .filter { workspace in
                workspace.windows.contains { $0.bundleIdentifier == bundleID }
            }
            .map { WorkspaceHandle(workspace: $0) }
    }

    /// Returns all workspaces that contain windows from a specific application by name.
    ///
    /// Use this method when you want to find workspaces by application display name
    /// rather than bundle identifier. This is more user-friendly when the bundle ID
    /// is unknown, but less precise since app names can vary or be duplicated.
    ///
    /// The search compares the `appName` property of each window against the provided
    /// name using case-insensitive localized comparison. A workspace is included if
    /// at least one of its windows matches.
    ///
    /// - Parameter appName: The display name of the application to search for.
    ///   The search is case-insensitive, so `"safari"`, `"Safari"`, and `"SAFARI"`
    ///   all match windows from Safari.
    ///
    /// - Returns: An array of `WorkspaceHandle` objects for workspaces that contain
    ///   at least one window from an app with the specified name. Returns an empty
    ///   array if no workspaces contain windows from that app.
    ///
    /// ## Example
    ///
    /// ```swift
    /// // Find all workspaces containing Finder windows
    /// let finderWorkspaces = Workspaces.containing(appName: "Finder")
    ///
    /// // Find workspaces with Terminal windows
    /// for workspace in Workspaces.containing(appName: "Terminal") {
    ///     print("\(workspace.name) includes Terminal")
    /// }
    ///
    /// // Case-insensitive matching
    /// let xcode = Workspaces.containing(appName: "xcode")  // Matches "Xcode"
    /// ```
    ///
    /// - Note: For more precise matching, especially when multiple apps might have
    ///   similar names, use ``containing(bundleID:)`` instead.
    ///
    /// ## See Also
    /// - ``containing(bundleID:)``
    /// - ``WorkspaceHandle/windows``
    public func containing(appName: String) -> [WorkspaceHandle] {
        guard let manager = FluentServices.shared.workspaceManager else {
            return []
        }

        return manager.savedWorkspaces
            .filter { workspace in
                workspace.windows.contains {
                    $0.appName.localizedCaseInsensitiveCompare(appName) == .orderedSame
                }
            }
            .map { WorkspaceHandle(workspace: $0) }
    }

    // MARK: - Creation

    /// Creates a new workspace capture builder for saving the current window state.
    ///
    /// This method returns a `WorkspaceCaptureBuilder` that provides a fluent interface
    /// for configuring and capturing a new workspace from the current window arrangement.
    /// The builder pattern allows you to chain configuration calls before executing the
    /// capture.
    ///
    /// The capture process:
    /// 1. Configure the workspace using builder methods (`named()`, `icon()`, `screens()`, etc.)
    /// 2. Call `save()` to capture current windows and persist the workspace
    /// 3. Optionally call `capture()` instead to get a handle without persisting
    ///
    /// The builder supports advanced options like selective screen capture, Chrome tab
    /// configuration, and open-by-path settings for terminal/editor apps.
    ///
    /// - Returns: A new `WorkspaceCaptureBuilder` instance for configuring the capture.
    ///
    /// ## Example
    ///
    /// ```swift
    /// // Basic workspace capture
    /// await Workspaces.capture()
    ///     .named("Development")
    ///     .icon("laptop.computer")
    ///     .save()
    ///
    /// // Capture specific screens only
    /// await Workspaces.capture()
    ///     .named("Main Monitor Setup")
    ///     .screens([0])  // Primary display only
    ///     .save()
    ///
    /// // Selective mode with multiple screens
    /// await Workspaces.capture()
    ///     .named("Dual Monitor Layout")
    ///     .selective(true)
    ///     .screens([0, 1])
    ///     .icon("display.2")
    ///     .save()
    ///
    /// // Preview before saving
    /// if let preview = await Workspaces.capture()
    ///     .named("Test")
    ///     .screens([0])
    ///     .preview() {
    ///     print("Would capture \(preview.windows.count) windows")
    /// }
    /// ```
    ///
    /// ## See Also
    /// - ``WorkspaceCaptureBuilder``
    /// - ``WorkspaceHandle/recapture(screenIndices:)``
    public func capture() -> WorkspaceCaptureBuilder {
        return WorkspaceCaptureBuilder()
    }

    // MARK: - Statistics

    /// The total number of saved workspaces.
    ///
    /// This property provides a quick way to check how many workspaces exist without
    /// loading all workspace data. It returns 0 if the workspace manager is not
    /// available or if no workspaces have been saved.
    ///
    /// ## Example
    ///
    /// ```swift
    /// // Check workspace count
    /// print("You have \(Workspaces.count) saved workspaces")
    ///
    /// // Use in conditional logic
    /// if Workspaces.count > 10 {
    ///     print("Consider organizing your workspaces")
    /// }
    /// ```
    ///
    /// ## See Also
    /// - ``isEmpty``
    /// - ``all()``
    public var count: Int {
        return FluentServices.shared.workspaceManager?.savedWorkspaces.count ?? 0
    }

    /// A Boolean value indicating whether no workspaces have been saved.
    ///
    /// This property is `true` when there are zero saved workspaces, and `false`
    /// when at least one workspace exists. It provides a more readable alternative
    /// to checking `count == 0`.
    ///
    /// ## Example
    ///
    /// ```swift
    /// // Check if any workspaces exist
    /// if Workspaces.isEmpty {
    ///     print("No workspaces yet. Create one with Workspaces.capture()")
    /// } else {
    ///     print("Found \(Workspaces.count) workspace(s)")
    /// }
    ///
    /// // Guard against empty state
    /// guard !Workspaces.isEmpty else {
    ///     showEmptyStateView()
    ///     return
    /// }
    /// ```
    ///
    /// ## See Also
    /// - ``count``
    /// - ``all()``
    public var isEmpty: Bool {
        return count == 0
    }
}

/// The global entry point for all workspace operations in the Fluent Workspace API.
///
/// `Workspaces` is a pre-configured instance of `WorkspaceNamespace` that provides
/// convenient access to workspace queries, creation, and management. It is the
/// primary interface for interacting with saved workspaces.
///
/// The name uses plural form (`Workspaces`) to avoid conflict with the `Workspace`
/// model struct and to better reflect that it provides access to multiple workspaces.
///
/// ## Access Patterns
///
/// ### Dynamic Member Lookup
/// Access workspaces directly by name using dot syntax. The lookup is case-insensitive
/// and converts PascalCase/camelCase to space-separated names:
/// ```swift
/// Workspaces.Development?.restore()      // Matches "Development"
/// Workspaces.WorkSetup?.restore()        // Matches "Work Setup"
/// Workspaces.myProject?.restore()        // Matches "my Project"
/// ```
///
/// ### Explicit Queries
/// Use query methods for programmatic access and more complex lookups:
/// ```swift
/// Workspaces.find(name: "Work Setup")?.restore()
/// Workspaces.find(id: workspaceId)?.delete()
/// Workspaces.find(containing: "dev")
/// ```
///
/// ### Filtering
/// Find workspaces based on their contents:
/// ```swift
/// Workspaces.containing(bundleID: "com.apple.Safari")
/// Workspaces.containing(appName: "Xcode")
/// Workspaces.recent(limit: 5)
/// ```
///
/// ### Creation
/// Capture the current window state as a new workspace:
/// ```swift
/// Workspaces.capture()
///     .named("New Setup")
///     .icon("desktopcomputer")
///     .save()
/// ```
///
/// ### Statistics
/// Check workspace counts:
/// ```swift
/// print("Total workspaces: \(Workspaces.count)")
/// if Workspaces.isEmpty { showOnboarding() }
/// ```
///
/// ## See Also
/// - ``WorkspaceNamespace``
/// - ``WorkspaceHandle``
/// - ``WorkspaceCaptureBuilder``
public let Workspaces = WorkspaceNamespace()
