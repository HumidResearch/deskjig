//  App.swift
//  DeskJigShared

import Foundation
import AppKit

/// A namespace struct that provides fluent access to macOS applications.
///
/// `AppNamespace` is the type behind the global `App` constant and serves as the primary
/// entry point for the Fluent Window API's application operations. It enables both
/// dynamic member lookup for registered aliases (e.g., `App.Figma`) and explicit
/// finder methods for bundle IDs or app names.
///
/// The struct leverages Swift's `@dynamicMemberLookup` attribute to allow property-style
/// access to registered application aliases. When you write `App.Figma`, Swift calls
/// the dynamic member subscript with "Figma" as the alias, which then looks up the
/// registration in ``AppRegistry`` and returns an ``AppHandle`` if found.
///
/// ## Topics
///
/// ### Finding Applications
/// - ``subscript(dynamicMember:)``
/// - ``find(bundleID:)``
/// - ``find(anyBundleID:)``
/// - ``find(name:)``
///
/// ### Registration
/// - ``register(_:bundleID:alternateBundleIDs:)``
/// - ``unregister(_:)``
///
/// ### Running Applications
/// - ``running()``
///
/// ## Example
///
/// ```swift
/// // Register aliases at app startup
/// App.register("Figma", bundleID: "com.figma.Desktop")
/// App.register("Chrome", bundleID: "com.google.Chrome",
///              alternateBundleIDs: ["com.google.Chrome.canary"])
///
/// // Use dynamic member lookup
/// App.Figma?.firstWindow()?.minimize()
/// App.Chrome?.activate()
///
/// // Or use explicit finder methods
/// App.find(bundleID: "com.apple.Safari")?.firstWindow()?.maximize()
/// ```
///
/// ## See Also
/// - ``AppHandle``
/// - ``AppRegistry``
@dynamicMemberLookup
public struct AppNamespace {

    // MARK: - Dynamic Member Lookup

    /// Accesses a registered application alias using property-style syntax.
    ///
    /// This subscript enables the convenient `App.Figma` syntax by leveraging Swift's
    /// `@dynamicMemberLookup` attribute. When you access a property on the `App` namespace
    /// that doesn't exist as a declared member, Swift automatically calls this subscript
    /// with the property name as the `alias` parameter.
    ///
    /// The subscript looks up the alias in ``AppRegistry/shared`` and returns an ``AppHandle``
    /// configured with the registered bundle ID and any alternate bundle IDs. The returned
    /// handle can be used to find windows, check running state, or perform app actions.
    ///
    /// - Parameter alias: The registered alias name (e.g., "Figma", "Chrome", "Safari").
    ///   This is automatically provided by Swift when using property-style access.
    ///
    /// - Returns: An ``AppHandle`` configured with the registered bundle ID(s) if the alias
    ///   is registered in the ``AppRegistry``, or `nil` if the alias has not been registered.
    ///   Note that a non-nil return does not guarantee the application is currently running.
    ///
    /// ## Example
    ///
    /// ```swift
    /// // First, register the alias
    /// App.register("Figma", bundleID: "com.figma.Desktop")
    ///
    /// // Now use dynamic member lookup
    /// if let figma = App.Figma {
    ///     // Get the first window
    ///     figma.firstWindow()?.activate()
    ///
    ///     // Check if the app is running
    ///     if figma.isRunning {
    ///         print("Figma is running")
    ///     }
    /// }
    ///
    /// // Unregistered aliases return nil
    /// let unknown = App.UnknownApp  // nil
    /// ```
    ///
    /// ## See Also
    /// - ``register(_:bundleID:alternateBundleIDs:)``
    /// - ``AppRegistry``
    public subscript(dynamicMember alias: String) -> AppHandle? {
        guard let registration = AppRegistry.shared.registration(for: alias) else {
            return nil
        }
        return AppHandle(
            bundleID: registration.bundleID,
            alternateBundleIDs: registration.alternateBundleIDs,
            name: alias
        )
    }
    
    // MARK: - Explicit Finders

    /// Finds an application by its bundle identifier.
    ///
    /// Use this method when you know the exact bundle identifier of the application
    /// you want to work with but don't want to register an alias. This is useful for
    /// one-off operations or when working with applications dynamically.
    ///
    /// Unlike dynamic member lookup, this method always returns an ``AppHandle``
    /// (not `nil`) because it creates a handle directly from the bundle ID without
    /// requiring prior registration. However, subsequent operations on the handle
    /// may fail if no application with that bundle ID is installed or running.
    ///
    /// - Parameter bundleID: The bundle identifier of the application
    ///   (e.g., "com.figma.Desktop", "com.apple.Safari", "com.google.Chrome").
    ///
    /// - Returns: An ``AppHandle`` configured for the specified bundle identifier.
    ///   Returns `nil` only if the bundle ID is empty or invalid.
    ///
    /// ## Example
    ///
    /// ```swift
    /// // Find Safari by bundle ID
    /// if let safari = App.find(bundleID: "com.apple.Safari") {
    ///     safari.firstWindow()?.maximize()
    /// }
    ///
    /// // Check if an app is running before operating on it
    /// if let app = App.find(bundleID: "com.figma.Desktop"), app.isRunning {
    ///     app.firstWindow()?.activate()
    /// }
    ///
    /// // Chain operations
    /// App.find(bundleID: "com.apple.Notes")?
    ///     .launch()?
    ///     .firstWindow()?
    ///     .center()
    /// ```
    ///
    /// ## See Also
    /// - ``find(anyBundleID:)``
    /// - ``find(name:)``
    /// - ``subscript(dynamicMember:)``
    public func find(bundleID: String) -> AppHandle? {
        return AppHandle(bundleID: bundleID)
    }
    
    /// Finds an application that matches any of the given bundle identifiers.
    ///
    /// This method is designed for applications that have multiple bundle ID variants,
    /// such as Google Chrome (which has stable, beta, canary, and enterprise versions)
    /// or Microsoft Edge (which has similar variants). The method creates an ``AppHandle``
    /// that will match any of the provided bundle IDs when checking for running instances.
    ///
    /// The first bundle ID in the array is treated as the primary identifier, with
    /// subsequent IDs used as alternates. When the handle checks if the app is running
    /// or retrieves windows, it checks all bundle IDs in order until it finds a match.
    ///
    /// - Parameter bundleIDs: An array of possible bundle identifiers to match against.
    ///   The first element becomes the primary bundle ID, and the rest are treated as
    ///   alternates. The array must not be empty.
    ///
    /// - Returns: An ``AppHandle`` configured to match any of the provided bundle IDs,
    ///   or `nil` if the array is empty.
    ///
    /// ## Example
    ///
    /// ```swift
    /// // Handle all Chrome variants
    /// let chromeVariants = [
    ///     "com.google.Chrome",
    ///     "com.google.Chrome.canary",
    ///     "com.google.Chrome.beta"
    /// ]
    /// if let chrome = App.find(anyBundleID: chromeVariants) {
    ///     // Works with whichever Chrome variant is running
    ///     chrome.firstWindow()?.activate()
    /// }
    ///
    /// // Handle Microsoft Edge variants
    /// let edgeVariants = [
    ///     "com.microsoft.edgemac",
    ///     "com.microsoft.edgemac.Beta",
    ///     "com.microsoft.edgemac.Dev"
    /// ]
    /// App.find(anyBundleID: edgeVariants)?.firstWindow()?.maximize()
    /// ```
    ///
    /// ## See Also
    /// - ``find(bundleID:)``
    /// - ``register(_:bundleID:alternateBundleIDs:)``
    public func find(anyBundleID bundleIDs: [String]) -> AppHandle? {
        guard !bundleIDs.isEmpty else { return nil }
        return AppHandle(bundleID: bundleIDs[0], alternateBundleIDs: Array(bundleIDs.dropFirst()))
    }
    
    /// Finds an application by its display name.
    ///
    /// This method searches for an application using its human-readable display name
    /// (the name shown in the Dock and menu bar) rather than its bundle identifier.
    /// This is useful when you know what the app is called but don't know its bundle ID.
    ///
    /// The search process follows this order:
    /// 1. First, searches through currently running applications using `NSWorkspace`
    /// 2. If not found and ``FluentServices`` has an `ApplicationManager` configured,
    ///    searches through known applications from that manager
    ///
    /// Because the search requires finding a matching running app or known app entry,
    /// this method may return `nil` even for installed applications if they are not
    /// currently running and no `ApplicationManager` is configured.
    ///
    /// - Parameter name: The display name of the application (e.g., "Figma", "Safari",
    ///   "Google Chrome"). The match is exact and case-sensitive.
    ///
    /// - Returns: An ``AppHandle`` for the matching application, or `nil` if no
    ///   application with that exact name could be found.
    ///
    /// ## Example
    ///
    /// ```swift
    /// // Find an app by its display name
    /// if let safari = App.find(name: "Safari") {
    ///     safari.firstWindow()?.maximize()
    /// }
    ///
    /// // Useful when you don't know the bundle ID
    /// App.find(name: "Figma")?.firstWindow()?.activate()
    ///
    /// // Note: Name must match exactly
    /// App.find(name: "safari")      // nil (lowercase)
    /// App.find(name: "Safari")      // AppHandle (correct case)
    /// ```
    ///
    /// ## See Also
    /// - ``find(bundleID:)``
    /// - ``find(anyBundleID:)``
    public func find(name: String) -> AppHandle? {
        // Try to find from running apps first
        let runningApps = NSWorkspace.shared.runningApplications
        if let runningApp = runningApps.first(where: { $0.localizedName == name }),
           let bundleID = runningApp.bundleIdentifier {
            return AppHandle(bundleID: bundleID, name: name)
        }

        // Try ApplicationManager if configured
        if let appManager = FluentServices.shared.applicationManager,
           let appInfo = appManager.applications.first(where: { $0.name == name }),
           let bundleID = appInfo.bundleIdentifier {
            return AppHandle(bundleID: bundleID, name: name)
        }

        return nil
    }
    
    // MARK: - Registration

    /// Registers an alias for convenient property-style access to an application.
    ///
    /// Once registered, the alias can be used with dynamic member lookup syntax
    /// (e.g., `App.Figma` instead of `App.find(bundleID: "com.figma.Desktop")`).
    /// Registrations persist for the lifetime of the application and are stored
    /// in the shared ``AppRegistry``.
    ///
    /// For applications with multiple variants (like Chrome's stable, beta, and canary
    /// versions), you can provide alternate bundle IDs. The handle will match any of
    /// the registered bundle IDs when checking for running instances or retrieving windows.
    ///
    /// Registrations are thread-safe and can be performed from any queue. If an alias
    /// is already registered, calling this method will overwrite the previous registration.
    ///
    /// - Parameters:
    ///   - alias: The friendly name to use as the property accessor (e.g., "Figma",
    ///     "Chrome", "Safari"). This becomes the property name used with `App.` syntax.
    ///     By convention, use PascalCase to match Swift property naming conventions.
    ///   - bundleID: The primary bundle identifier of the application
    ///     (e.g., "com.figma.Desktop", "com.google.Chrome").
    ///   - alternateBundleIDs: An optional array of alternative bundle identifiers.
    ///     Use this for applications with multiple variants. Defaults to an empty array.
    ///
    /// ## Example
    ///
    /// ```swift
    /// // Register a simple alias
    /// App.register("Figma", bundleID: "com.figma.Desktop")
    /// App.register("Safari", bundleID: "com.apple.Safari")
    ///
    /// // Register with alternate bundle IDs for app variants
    /// App.register("Chrome", bundleID: "com.google.Chrome",
    ///              alternateBundleIDs: [
    ///                  "com.google.Chrome.canary",
    ///                  "com.google.Chrome.beta"
    ///              ])
    ///
    /// // Now use dynamic member lookup
    /// App.Figma?.firstWindow()?.minimize()
    /// App.Chrome?.activate()  // Works with any Chrome variant
    ///
    /// // Overwrite an existing registration
    /// App.register("Browser", bundleID: "com.apple.Safari")
    /// App.register("Browser", bundleID: "com.google.Chrome")  // Overwrites Safari
    /// ```
    ///
    /// ## See Also
    /// - ``unregister(_:)``
    /// - ``subscript(dynamicMember:)``
    /// - ``AppRegistry``
    public func register(_ alias: String, bundleID: String, alternateBundleIDs: [String] = []) {
        AppRegistry.shared.register(alias, bundleID: bundleID, alternateBundleIDs: alternateBundleIDs)
    }
    
    /// Removes a previously registered alias from the registry.
    ///
    /// After unregistering, the alias will no longer be accessible via dynamic member
    /// lookup. Attempting to access `App.AliasName` after unregistering will return `nil`.
    ///
    /// This operation is thread-safe and can be performed from any queue. If the alias
    /// is not currently registered, this method does nothing (no error is thrown).
    ///
    /// - Parameter alias: The alias to remove from the registry (e.g., "Figma", "Chrome").
    ///   The alias is case-sensitive and must match exactly what was registered.
    ///
    /// ## Example
    ///
    /// ```swift
    /// // Register and use an alias
    /// App.register("Figma", bundleID: "com.figma.Desktop")
    /// App.Figma?.firstWindow()?.activate()  // Works
    ///
    /// // Unregister the alias
    /// App.unregister("Figma")
    /// App.Figma  // nil - no longer registered
    ///
    /// // Safe to call on non-existent aliases
    /// App.unregister("NonExistent")  // No error
    ///
    /// // Re-register with a different bundle ID if needed
    /// App.register("Figma", bundleID: "com.figma.Desktop.beta")
    /// ```
    ///
    /// ## See Also
    /// - ``register(_:bundleID:alternateBundleIDs:)``
    /// - ``AppRegistry/clearAll()``
    public func unregister(_ alias: String) {
        AppRegistry.shared.unregister(alias)
    }
    
    // MARK: - Running Apps

    /// Returns all currently running applications as `AppHandle` instances.
    ///
    /// This method queries `NSWorkspace` for all running applications and returns
    /// handles for each one. Only applications with a "regular" activation policy
    /// are included, which filters out background-only apps, menu bar utilities,
    /// and system services that don't appear in the Dock.
    ///
    /// The returned handles can be used to inspect or manipulate each application's
    /// windows, check their running state, or perform app-level actions like
    /// activating or hiding.
    ///
    /// - Returns: An array of ``AppHandle`` instances representing all currently
    ///   running applications with regular activation policy. Returns an empty array
    ///   if no applications are running (which would be unusual).
    ///
    /// ## Example
    ///
    /// ```swift
    /// // List all running apps
    /// for app in App.running() {
    ///     print("\(app.localizedName ?? "Unknown") - \(app.bundleID)")
    /// }
    ///
    /// // Find and activate hidden apps
    /// for app in App.running() where app.isHidden {
    ///     app.unhide()
    /// }
    ///
    /// // Count windows across all apps
    /// let totalWindows = App.running().reduce(0) { count, app in
    ///     count + app.windows().count
    /// }
    /// print("Total visible windows: \(totalWindows)")
    ///
    /// // Get the active (frontmost) app
    /// if let activeApp = App.running().first(where: { $0.isActive }) {
    ///     print("Active: \(activeApp.localizedName ?? "Unknown")")
    /// }
    /// ```
    ///
    /// ## See Also
    /// - ``AppHandle/isRunning``
    /// - ``AppHandle/isHidden``
    /// - ``AppHandle/isActive``
    public func running() -> [AppHandle] {
        let runningApps = NSWorkspace.shared.runningApplications
        return runningApps.compactMap { app in
            guard let bundleID = app.bundleIdentifier,
                  app.activationPolicy == .regular else {
                return nil
            }
            return AppHandle(bundleID: bundleID, name: app.localizedName)
        }
    }
}

/// The global entry point for application operations in the Fluent Window API.
///
/// `App` is a shared instance of ``AppNamespace`` that provides access to macOS applications
/// through a fluent, chainable interface. It supports both dynamic member lookup for
/// registered aliases (e.g., `App.Figma`) and explicit finder methods for bundle IDs
/// or display names.
///
/// ## Getting Started
///
/// Register aliases at application startup for commonly-used apps:
///
/// ```swift
/// // In your app delegate or initialization code
/// App.register("Figma", bundleID: "com.figma.Desktop")
/// App.register("Chrome", bundleID: "com.google.Chrome",
///              alternateBundleIDs: ["com.google.Chrome.canary"])
/// App.register("Safari", bundleID: "com.apple.Safari")
/// ```
///
/// ## Dynamic Member Lookup
///
/// After registering an alias, access the app using property-style syntax:
///
/// ```swift
/// // Activate Figma's first window
/// App.Figma?.firstWindow()?.activate()
///
/// // Minimize all Chrome windows
/// App.Chrome?.windows().forEach { $0.minimize() }
///
/// // Check if Safari is running
/// if App.Safari?.isRunning == true {
///     print("Safari is running")
/// }
/// ```
///
/// ## Explicit Finder Methods
///
/// When you don't need to register an alias, use the finder methods directly:
///
/// ```swift
/// // Find by bundle ID
/// App.find(bundleID: "com.apple.Safari")?.firstWindow()?.maximize()
///
/// // Find by display name
/// App.find(name: "Finder")?.firstWindow()?.activate()
///
/// // Find by any of several bundle IDs (useful for app variants)
/// App.find(anyBundleID: ["com.google.Chrome", "com.google.Chrome.canary"])?
///     .firstWindow()?
///     .center()
/// ```
///
/// ## Querying Running Applications
///
/// List all currently running applications:
///
/// ```swift
/// // Print all running apps
/// for app in App.running() {
///     print("\(app.localizedName ?? "Unknown"): \(app.bundleID)")
/// }
///
/// // Find the frontmost app
/// let frontmost = App.running().first { $0.isActive }
/// ```
///
/// ## See Also
/// - ``AppNamespace``
/// - ``AppHandle``
/// - ``AppRegistry``
public let App = AppNamespace()
