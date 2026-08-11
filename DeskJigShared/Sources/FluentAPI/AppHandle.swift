//  AppHandle.swift
//  DeskJigShared

import Foundation
import AppKit

/// A chainable wrapper for application operations.
///
/// `AppHandle` provides fluent access to app windows and app-level actions using
/// a chainable API pattern. It wraps the underlying accessibility services and
/// provides a clean interface for window management operations.
///
/// The handle supports apps with multiple bundle identifiers (such as Chrome variants)
/// by allowing alternate bundle IDs to be specified. All lookups will check both the
/// primary and alternate bundle IDs.
///
/// ## Example
///
/// ```swift
/// // Basic window operations
/// App.Chrome?.firstWindow()?.moveToLeftHalf()
/// App.find(name: "Safari")?.launch()?.firstWindow()?.maximize()
///
/// // Find and activate a specific window
/// App.Figma?.window(containing: "Untitled")?.activate()
///
/// // Chain multiple app operations
/// App.VSCode?.launch()?.activate()?.firstWindow()?.moveToCenter()
/// ```
///
/// ## See Also
/// - ``App`` for static accessors to common applications
/// - ``WindowHandle`` for window-level operations
public final class AppHandle {

    /// The primary bundle identifier of the application.
    ///
    /// This is the main bundle ID used to identify the application. For apps with
    /// multiple variants (like Chrome), this is typically the standard bundle ID.
    ///
    /// ## Example
    ///
    /// ```swift
    /// let app = App.Chrome
    /// print(app?.bundleID) // "com.google.Chrome"
    /// ```
    public let bundleID: String

    /// Alternative bundle identifiers for the application.
    ///
    /// Some applications have multiple variants with different bundle IDs. For example,
    /// Google Chrome has variants like Chrome Canary, Chrome Beta, and Chromium, each
    /// with a different bundle ID. This array contains additional bundle IDs to check
    /// when looking for the running application.
    ///
    /// When resolving the running application, the primary `bundleID` is checked first,
    /// then each alternate bundle ID in order.
    ///
    /// ## Example
    ///
    /// ```swift
    /// let chrome = AppHandle(
    ///     bundleID: "com.google.Chrome",
    ///     alternateBundleIDs: ["com.google.Chrome.canary", "org.chromium.Chromium"]
    /// )
    /// ```
    public let alternateBundleIDs: [String]

    /// The display name of the application, if known.
    ///
    /// This is an optional human-readable name provided at initialization time.
    /// If not provided, use ``localizedName`` to get the name from the running application.
    ///
    /// - Note: This value is static and set at initialization. For the current localized
    ///   name of a running application, use ``localizedName`` instead.
    public let name: String?
    
    /// Reference to AXWindowService
    private var axService: AXWindowServiceProtocol? {
        return FluentServices.shared.axWindowService
    }
    
    /// All bundle IDs (primary + alternates) for process lookup
    private var allBundleIDs: [String] {
        return [bundleID] + alternateBundleIDs
    }
    
    // MARK: - Initialization
    
    /// Creates an AppHandle for a bundle identifier.
    ///
    /// - Parameters:
    ///   - bundleID: The application's primary bundle identifier
    ///   - alternateBundleIDs: Alternative bundle IDs (e.g., for Chrome variants)
    ///   - name: Optional display name
    internal init(bundleID: String, alternateBundleIDs: [String] = [], name: String? = nil) {
        self.bundleID = bundleID
        self.alternateBundleIDs = alternateBundleIDs
        self.name = name
    }
    
    // MARK: - Window Finding
    
    /// Applies filter options to an AXWindow
    private func passesFilter(_ window: AXWindow, options: WindowFilterOptions) -> Bool {
        // Size filter
        if window.frame.width < options.minWidth || window.frame.height < options.minHeight {
            return false
        }
        
        // State filters
        if !options.includeMinimized && window.isMinimized {
            return false
        }
        if !options.includeHidden && window.isHidden {
            return false
        }
        
        // Title filters
        let trimmedTitle = window.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !options.includeEmptyTitles && trimmedTitle.isEmpty {
            return false
        }
        if !options.includeUntitled && trimmedTitle == "Untitled" {
            return false
        }
        
        return true
    }
    
    /// Gets the process ID for this app, checking all bundle IDs
    private func getAppProcessID() -> pid_t? {
        guard let service = axService else { return nil }
        
        // Try primary bundle ID first
        if let pid = service.getProcessID(for: bundleID) {
            return pid
        }
        
        // Try alternate bundle IDs
        if !alternateBundleIDs.isEmpty {
            return service.getProcessID(forAnyOf: alternateBundleIDs)
        }
        
        return nil
    }
    
    /// Gets the effective bundle identifier for a running process
    private func getEffectiveBundleID(for processID: pid_t) -> String? {
        return NSWorkspace.shared.runningApplications
            .first { $0.processIdentifier == processID }?
            .bundleIdentifier
    }
    
    /// Returns all windows belonging to this application.
    ///
    /// Retrieves windows for this application from the accessibility API and applies
    /// the specified filter options. Windows are returned in z-order (topmost first).
    ///
    /// By default, the filter excludes minimized windows, hidden windows, windows with
    /// empty titles, and windows smaller than the minimum size threshold.
    ///
    /// - Parameter filter: Filter options controlling which windows are included.
    ///   Defaults to ``WindowFilterOptions/default`` which excludes small and empty windows.
    ///
    /// - Returns: An array of ``WindowHandle`` objects for matching windows. Returns an
    ///   empty array if the app is not running or has no matching windows.
    ///
    /// ## Example
    ///
    /// ```swift
    /// // Get all visible windows
    /// let windows = App.Safari?.windows() ?? []
    /// for window in windows {
    ///     print(window.title)
    /// }
    ///
    /// // Get all windows including minimized
    /// var options = WindowFilterOptions.default
    /// options.includeMinimized = true
    /// let allWindows = App.Finder?.windows(filter: options) ?? []
    ///
    /// // Get windows including those with empty titles
    /// var lenientOptions = WindowFilterOptions.default
    /// lenientOptions.includeEmptyTitles = true
    /// let moreWindows = App.Chrome?.windows(filter: lenientOptions) ?? []
    /// ```
    ///
    /// ## See Also
    /// - ``firstWindow(filter:)`` to get just the topmost window
    /// - ``WindowFilterOptions`` for available filter options
    public func windows(filter: WindowFilterOptions = .default) -> [WindowHandle] {
        guard let service = axService,
              let processID = getAppProcessID() else {
            return []
        }
        
        let effectiveBundleID = getEffectiveBundleID(for: processID) ?? bundleID
        let appWindows = service.getWindows(forProcessID: processID, bundleIdentifier: effectiveBundleID)
        let filtered = appWindows.filter { passesFilter($0, options: filter) }
        return filtered.map { WindowHandle(axWindow: $0) }
    }
    
    /// Returns the first (topmost) window of this application.
    ///
    /// Retrieves the topmost window for this application that passes the specified filter.
    /// This is more efficient than calling ``windows(filter:)`` when you only need one window,
    /// as it stops searching after finding the first match.
    ///
    /// The "first" window is determined by z-order, meaning it's the window that would be
    /// topmost if the application were active. This may not be the most recently focused
    /// window if the app is in the background.
    ///
    /// - Parameter filter: Filter options controlling which windows are considered.
    ///   Defaults to ``WindowFilterOptions/default`` which excludes small and empty windows.
    ///
    /// - Returns: A ``WindowHandle`` for the topmost matching window, or `nil` if the app
    ///   is not running or has no matching windows.
    ///
    /// ## Example
    ///
    /// ```swift
    /// // Get the main window of an app
    /// if let window = App.Xcode?.firstWindow() {
    ///     window.activate()
    /// }
    ///
    /// // Chain operations on the first window
    /// App.Figma?.firstWindow()?.moveToLeftHalf()
    ///
    /// // Launch app and work with its first window
    /// App.Safari?.launch()?.firstWindow()?.maximize()
    /// ```
    ///
    /// ## See Also
    /// - ``windows(filter:)`` to get all windows
    /// - ``window(titled:)`` to find a specific window by exact title
    /// - ``window(containing:)`` to find a window by partial title match
    public func firstWindow(filter: WindowFilterOptions = .default) -> WindowHandle? {
        guard let service = axService,
              let processID = getAppProcessID() else {
            return nil
        }
        
        let effectiveBundleID = getEffectiveBundleID(for: processID) ?? bundleID
        let appWindows = service.getWindows(forProcessID: processID, bundleIdentifier: effectiveBundleID)
        
        // Find first window that passes filter
        guard let window = appWindows.first(where: { passesFilter($0, options: filter) }) else {
            return nil
        }
        
        return WindowHandle(axWindow: window)
    }
    
    /// Returns a window with a specific title.
    ///
    /// Searches for a window with an exact title match. The comparison is case-sensitive
    /// and requires the full title to match exactly.
    ///
    /// - Parameter titled: The exact window title to match.
    ///
    /// - Returns: A ``WindowHandle`` for the first window with the matching title, or `nil`
    ///   if no window with that exact title is found or the app is not running.
    ///
    /// ## Example
    ///
    /// ```swift
    /// // Find a specific document window
    /// if let window = App.TextEdit?.window(titled: "README.md") {
    ///     window.activate()
    /// }
    ///
    /// // Work with a named browser tab/window
    /// App.Safari?.window(titled: "Apple Developer Documentation")?.moveToRightHalf()
    /// ```
    ///
    /// - Note: Window titles can change dynamically (e.g., when a document is edited).
    ///   If you need a more flexible match, use ``window(containing:)`` instead.
    ///
    /// ## See Also
    /// - ``window(containing:)`` for partial title matching
    /// - ``firstWindow(filter:)`` to get the topmost window
    public func window(titled: String) -> WindowHandle? {
        guard let service = axService,
              let processID = getAppProcessID() else {
            return nil
        }
        
        let effectiveBundleID = getEffectiveBundleID(for: processID) ?? bundleID
        let appWindows = service.getWindows(forProcessID: processID, bundleIdentifier: effectiveBundleID)
        
        guard let window = appWindows.first(where: { $0.title == titled }) else {
            return nil
        }
        
        return WindowHandle(axWindow: window)
    }
    
    /// Returns a window with a title containing the specified string.
    ///
    /// Searches for a window whose title contains the specified substring. The comparison
    /// is case-sensitive. If multiple windows match, the first one (by z-order) is returned.
    ///
    /// This is useful when you know part of a window's title but not the exact full title,
    /// such as when searching for a document by filename while the app may add prefixes
    /// or suffixes to the title.
    ///
    /// - Parameter containing: The substring to search for in window titles.
    ///
    /// - Returns: A ``WindowHandle`` for the first window containing the substring in its title,
    ///   or `nil` if no matching window is found or the app is not running.
    ///
    /// ## Example
    ///
    /// ```swift
    /// // Find a window by partial filename
    /// App.VSCode?.window(containing: "AppHandle.swift")?.activate()
    ///
    /// // Find a browser window by page content
    /// App.Chrome?.window(containing: "GitHub")?.moveToLeftHalf()
    ///
    /// // Chain with other operations
    /// App.Figma?.launch()?.window(containing: "Design System")?.maximize()
    /// ```
    ///
    /// - Note: The search is case-sensitive. Use ``window(titled:)`` if you need an exact match.
    ///
    /// ## See Also
    /// - ``window(titled:)`` for exact title matching
    /// - ``window(matchingFrame:tolerance:)`` for frame-based matching
    public func window(containing: String) -> WindowHandle? {
        guard let service = axService,
              let processID = getAppProcessID() else {
            return nil
        }
        
        let effectiveBundleID = getEffectiveBundleID(for: processID) ?? bundleID
        let appWindows = service.getWindows(forProcessID: processID, bundleIdentifier: effectiveBundleID)
        
        guard let window = appWindows.first(where: { $0.title.contains(containing) }) else {
            return nil
        }
        
        return WindowHandle(axWindow: window)
    }
    
    /// Returns a window matching the given frame within a tolerance.
    ///
    /// Searches for a window whose position and size match the specified frame within
    /// the given tolerance. This is particularly useful for workspace restoration when
    /// you need to find a window that was previously at a known position.
    ///
    /// The tolerance is applied to each component (x, y, width, height) independently.
    /// A window matches if all four components are within the tolerance of the target frame.
    ///
    /// - Parameters:
    ///   - frame: The target frame (position and size) to match against.
    ///   - tolerance: Maximum pixel difference allowed for each component. Defaults to 10 pixels,
    ///     which accommodates minor positioning differences from different display configurations.
    ///
    /// - Returns: A ``WindowHandle`` for the first window matching the frame, or `nil` if no
    ///   matching window is found or the app is not running.
    ///
    /// ## Example
    ///
    /// ```swift
    /// // Find a window at a specific location
    /// let targetFrame = CGRect(x: 100, y: 100, width: 800, height: 600)
    /// if let window = App.Safari?.window(matchingFrame: targetFrame) {
    ///     window.activate()
    /// }
    ///
    /// // Use tighter tolerance for precise matching
    /// let preciseFrame = CGRect(x: 0, y: 25, width: 1920, height: 1055)
    /// App.Xcode?.window(matchingFrame: preciseFrame, tolerance: 2.0)?.activate()
    ///
    /// // Use looser tolerance for approximate matching
    /// App.Finder?.window(matchingFrame: savedFrame, tolerance: 50.0)?.moveToCenter()
    /// ```
    ///
    /// ## See Also
    /// - ``window(titled:)`` for title-based matching
    /// - ``window(containing:)`` for partial title matching
    public func window(matchingFrame frame: CGRect, tolerance: CGFloat = 10.0) -> WindowHandle? {
        guard let service = axService,
              let processID = getAppProcessID() else {
            return nil
        }
        
        let effectiveBundleID = getEffectiveBundleID(for: processID) ?? bundleID
        let appWindows = service.getWindows(forProcessID: processID, bundleIdentifier: effectiveBundleID)
        
        guard let window = appWindows.first(where: { $0.frameMatches(frame, tolerance: tolerance) }) else {
            return nil
        }
        
        return WindowHandle(axWindow: window)
    }
    
    // MARK: - App Actions (Chainable)

    /// Launches the application if it's not running.
    ///
    /// If the application is already running, this method returns immediately without
    /// taking any action. Otherwise, it attempts to launch the application using the
    /// ``ApplicationManager`` if available, falling back to `NSWorkspace` if not.
    ///
    /// This method blocks until the launch completes or times out (5 seconds).
    ///
    /// - Returns: `self` for method chaining if the app is running or was successfully launched,
    ///   or `nil` if the launch failed.
    ///
    /// ## Example
    ///
    /// ```swift
    /// // Launch and immediately work with the app
    /// App.Safari?.launch()?.firstWindow()?.maximize()
    ///
    /// // Check if launch succeeded
    /// if let app = App.Xcode?.launch() {
    ///     print("Xcode is now running")
    /// } else {
    ///     print("Failed to launch Xcode")
    /// }
    ///
    /// // Chain multiple operations after launch
    /// App.Figma?.launch()?.activate()?.firstWindow()?.moveToCenter()
    /// ```
    ///
    /// - Note: The method waits up to 5 seconds for the launch to complete.
    ///   For apps that take longer to start, you may need to add additional waiting logic.
    ///
    /// ## See Also
    /// - ``activate()`` to bring a running app to the front
    /// - ``isRunning`` to check if the app is already running
    @discardableResult
    public func launch() -> AppHandle? {
        // Check if already running
        if isRunning {
            return self
        }
        
        // Try to launch via ApplicationManager
        if let appManager = FluentServices.shared.applicationManager,
           let appInfo = appManager.findApplication(by: bundleID) {
            let success = appManager.launchApplication(appInfo)
            return success ? self : nil
        }
        
        // Fallback: try to launch via NSWorkspace
        if let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            let config = NSWorkspace.OpenConfiguration()
            let semaphore = DispatchSemaphore(value: 0)
            var launchSuccess = false
            
            NSWorkspace.shared.openApplication(at: appURL, configuration: config) { _, error in
                launchSuccess = error == nil
                semaphore.signal()
            }
            
            _ = semaphore.wait(timeout: .now() + 5.0)
            return launchSuccess ? self : nil
        }
        
        return nil
    }
    
    /// Activates the application, bringing it to the front.
    ///
    /// Makes this application the active (frontmost) application. All of the app's windows
    /// will be brought forward, and the app will receive keyboard focus. On macOS 14+,
    /// uses the modern `activate()` API; on earlier versions, uses `activate(options:)`
    /// with the `activateIgnoringOtherApps` option.
    ///
    /// - Returns: `self` for method chaining if activation succeeded, or `nil` if the app
    ///   is not running or activation failed.
    ///
    /// ## Example
    ///
    /// ```swift
    /// // Bring an app to the front
    /// App.Safari?.activate()
    ///
    /// // Launch if needed, then activate
    /// App.Xcode?.launch()?.activate()
    ///
    /// // Activate and work with the first window
    /// App.Figma?.activate()?.firstWindow()?.moveToCenter()
    /// ```
    ///
    /// - Note: This activates the entire application. To activate a specific window
    ///   within the app, use ``WindowHandle/activate()`` on the window instead.
    ///
    /// ## See Also
    /// - ``isActive`` to check if the app is already active
    /// - ``hide()`` to hide the application
    /// - ``WindowHandle/activate()`` to activate a specific window
    @discardableResult
    public func activate() -> AppHandle? {
        guard let runningApp = runningApplication else {
            return nil
        }
        
        let success: Bool
        if #available(macOS 14.0, *) {
            success = runningApp.activate()
        } else {
            success = runningApp.activate(options: [.activateIgnoringOtherApps])
        }
        
        return success ? self : nil
    }
    
    /// Hides the application.
    ///
    /// Hides all windows of this application. Hidden windows are not visible on screen
    /// but the application continues running. This is equivalent to pressing Cmd+H
    /// or selecting "Hide" from the application menu.
    ///
    /// - Returns: `self` for method chaining if hiding succeeded, or `nil` if the app
    ///   is not running or hiding failed.
    ///
    /// ## Example
    ///
    /// ```swift
    /// // Hide an application
    /// App.Safari?.hide()
    ///
    /// // Hide after completing some work
    /// App.Xcode?.firstWindow()?.moveToLeftHalf()
    /// App.Xcode?.hide()
    /// ```
    ///
    /// - Note: Hidden applications can be revealed again using ``unhide()`` or by
    ///   clicking on the app's Dock icon.
    ///
    /// ## See Also
    /// - ``unhide()`` to show a hidden application
    /// - ``isHidden`` to check if the app is hidden
    /// - ``activate()`` to bring the app to the front
    @discardableResult
    public func hide() -> AppHandle? {
        guard let runningApp = runningApplication else {
            DeskJigLog.debug(.window, "AppHandle.hide() failed: no running application for bundle=\(bundleID)")
            return nil
        }
        
        let appName = runningApp.localizedName ?? bundleID
        let pid = runningApp.processIdentifier
        
        // Try AX API first (more reliable for hiding)
        if let service = axService {
            if let appElement = service.createAppElement(for: pid) {
                let axSuccess = service.hideApp(appElement)
                if axSuccess {
                    DeskJigLog.debug(.window, "AppHandle.hide() via AX API succeeded for app='\(appName)' bundle=\(bundleID) pid=\(pid)")
                    return self
                } else {
                    DeskJigLog.debug(.window, "AppHandle.hide() via AX API failed for app='\(appName)' bundle=\(bundleID) pid=\(pid), trying NSRunningApplication")
                }
            }
        }
        
        // Fallback: hide via NSRunningApplication
        let success = runningApp.hide()
        if success {
            DeskJigLog.debug(.window, "AppHandle.hide() via NSRunningApplication succeeded for app='\(appName)' bundle=\(bundleID) pid=\(pid)")
        } else {
            DeskJigLog.debug(.window, "AppHandle.hide() via NSRunningApplication failed for app='\(appName)' bundle=\(bundleID) pid=\(pid)")
        }
        return success ? self : nil
    }
    
    /// Unhides the application, making its windows visible again.
    ///
    /// Reveals all windows of a previously hidden application. The windows will appear
    /// at their previous positions but the application may not become the frontmost app.
    /// Use ``activate()`` after unhiding if you want to bring the app to the front.
    ///
    /// - Returns: `self` for method chaining if unhiding succeeded, or `nil` if the app
    ///   is not running or unhiding failed.
    ///
    /// ## Example
    ///
    /// ```swift
    /// // Unhide an application
    /// App.Safari?.unhide()
    ///
    /// // Unhide and bring to front
    /// App.Xcode?.unhide()?.activate()
    ///
    /// // Unhide and work with windows
    /// if let app = App.Figma?.unhide() {
    ///     app.firstWindow()?.moveToCenter()
    /// }
    /// ```
    ///
    /// ## See Also
    /// - ``hide()`` to hide the application
    /// - ``isHidden`` to check if the app is hidden
    /// - ``activate()`` to bring the app to the front after unhiding
    @discardableResult
    public func unhide() -> AppHandle? {
        guard let runningApp = runningApplication else {
            return nil
        }
        
        let success = runningApp.unhide()
        return success ? self : nil
    }
    
    /// Terminates the application gracefully.
    ///
    /// Sends a termination request to the application, allowing it to perform cleanup
    /// and prompt the user to save unsaved documents. This is equivalent to selecting
    /// "Quit" from the application menu or pressing Cmd+Q.
    ///
    /// The application may refuse to terminate (e.g., if there are unsaved documents and
    /// the user cancels the quit). Use ``forceTerminate()`` if you need to ensure the
    /// application exits.
    ///
    /// - Returns: `self` for method chaining (returns self even if the quit is pending,
    ///   as the app may be in the process of terminating), or `nil` if the app is not running.
    ///
    /// ## Example
    ///
    /// ```swift
    /// // Gracefully quit an application
    /// App.Safari?.terminate()
    ///
    /// // Quit multiple apps
    /// App.Chrome?.terminate()
    /// App.Firefox?.terminate()
    /// ```
    ///
    /// - Warning: The method returns immediately; it does not wait for the application
    ///   to fully terminate. Check ``isRunning`` if you need to verify the app has quit.
    ///
    /// ## See Also
    /// - ``forceTerminate()`` to forcibly quit the application
    /// - ``isRunning`` to check if the app is still running
    @discardableResult
    public func terminate() -> AppHandle? {
        guard let runningApp = runningApplication else {
            return nil
        }
        
        runningApp.terminate()
        return self
    }
    
    /// Force terminates the application immediately.
    ///
    /// Forcibly terminates the application without allowing it to perform cleanup or
    /// prompt the user. This is equivalent to force-quitting via Activity Monitor or
    /// using `kill -9`. Any unsaved data will be lost.
    ///
    /// Use this method only when ``terminate()`` fails or when you need to ensure the
    /// application exits immediately regardless of its state.
    ///
    /// - Returns: `self` for method chaining (returns self as the termination is in progress),
    ///   or `nil` if the app is not running.
    ///
    /// ## Example
    ///
    /// ```swift
    /// // Force quit a frozen application
    /// App.Safari?.forceTerminate()
    ///
    /// // Try graceful quit first, then force if still running
    /// App.Chrome?.terminate()
    /// DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
    ///     if App.Chrome?.isRunning == true {
    ///         App.Chrome?.forceTerminate()
    ///     }
    /// }
    /// ```
    ///
    /// - Warning: This will cause immediate termination with potential data loss.
    ///   Prefer ``terminate()`` for normal quit operations.
    ///
    /// ## See Also
    /// - ``terminate()`` for graceful termination
    /// - ``isRunning`` to check if the app has terminated
    @discardableResult
    public func forceTerminate() -> AppHandle? {
        guard let runningApp = runningApplication else {
            return nil
        }
        
        runningApp.forceTerminate()
        return self
    }
    
    // MARK: - State Queries

    /// Indicates whether the application is currently running.
    ///
    /// Checks if any running application matches this handle's bundle identifier
    /// (including alternate bundle IDs). This is a live query that reflects the
    /// current system state.
    ///
    /// ## Example
    ///
    /// ```swift
    /// // Check before performing operations
    /// if App.Safari?.isRunning == true {
    ///     App.Safari?.activate()
    /// }
    ///
    /// // Launch only if not running
    /// if App.Xcode?.isRunning != true {
    ///     App.Xcode?.launch()
    /// }
    /// ```
    ///
    /// ## See Also
    /// - ``launch()`` to start the application
    /// - ``terminate()`` to stop the application
    public var isRunning: Bool {
        return runningApplication != nil
    }
    
    /// Indicates whether the application is currently hidden.
    ///
    /// Returns `true` if the application is running but all its windows are hidden
    /// (equivalent to pressing Cmd+H). Returns `false` if the app is visible, and
    /// also returns `false` if the app is not running.
    ///
    /// ## Example
    ///
    /// ```swift
    /// // Check if app needs to be unhidden
    /// if App.Safari?.isHidden == true {
    ///     App.Safari?.unhide()?.activate()
    /// }
    ///
    /// // Toggle hidden state
    /// if let app = App.Xcode {
    ///     if app.isHidden {
    ///         app.unhide()
    ///     } else {
    ///         app.hide()
    ///     }
    /// }
    /// ```
    ///
    /// ## See Also
    /// - ``hide()`` to hide the application
    /// - ``unhide()`` to show a hidden application
    /// - ``isRunning`` to check if the app is running at all
    public var isHidden: Bool {
        return runningApplication?.isHidden ?? false
    }

    /// Indicates whether the application is currently active (frontmost).
    ///
    /// Returns `true` if this application is the currently active application and
    /// receives keyboard input. Only one application can be active at a time.
    /// Returns `false` if the app is not active or not running.
    ///
    /// ## Example
    ///
    /// ```swift
    /// // Check if already active before activating
    /// if App.Safari?.isActive != true {
    ///     App.Safari?.activate()
    /// }
    ///
    /// // Find which monitored app is active
    /// let apps = [App.Safari, App.Chrome, App.Firefox]
    /// if let activeApp = apps.compactMap({ $0 }).first(where: { $0.isActive }) {
    ///     print("\(activeApp.localizedName ?? "Unknown") is active")
    /// }
    /// ```
    ///
    /// ## See Also
    /// - ``activate()`` to make the app active
    /// - ``isRunning`` to check if the app is running
    public var isActive: Bool {
        return runningApplication?.isActive ?? false
    }
    
    /// The process identifier (PID) of the running application.
    ///
    /// Returns the Unix process ID of the first running instance of this application,
    /// or `nil` if the application is not running. When alternate bundle IDs are
    /// configured, returns the PID of whichever variant is running (checking the
    /// primary bundle ID first).
    ///
    /// ## Example
    ///
    /// ```swift
    /// // Get PID for system integration
    /// if let pid = App.Safari?.processID {
    ///     print("Safari PID: \(pid)")
    /// }
    ///
    /// // Use PID for accessibility operations
    /// if let pid = App.Xcode?.processID {
    ///     let app = AXUIElementCreateApplication(pid)
    ///     // ... perform AX operations
    /// }
    /// ```
    ///
    /// ## See Also
    /// - ``processIDs`` to get PIDs for all running instances
    /// - ``isRunning`` to simply check if the app is running
    public var processID: pid_t? {
        return runningApplication?.processIdentifier
    }

    /// All process identifiers for running instances of this application.
    ///
    /// Returns an array of Unix process IDs for all running instances that match
    /// this handle's bundle identifiers (primary and alternates). This is useful
    /// for applications that can have multiple instances running simultaneously.
    ///
    /// Only returns PIDs for applications with a `.regular` activation policy
    /// (excludes background agents and accessories).
    ///
    /// ## Example
    ///
    /// ```swift
    /// // Check for multiple running instances
    /// let pids = App.Chrome?.processIDs ?? []
    /// if pids.count > 1 {
    ///     print("Multiple Chrome instances running: \(pids)")
    /// }
    ///
    /// // Iterate over all instances
    /// for pid in App.VSCode?.processIDs ?? [] {
    ///     print("VS Code instance: \(pid)")
    /// }
    /// ```
    ///
    /// ## See Also
    /// - ``processID`` to get the PID of the first instance
    /// - ``alternateBundleIDs`` for the bundle IDs being checked
    public var processIDs: [pid_t] {
        let runningApps = NSWorkspace.shared.runningApplications
        return runningApps.compactMap { app in
            guard let bid = app.bundleIdentifier,
                  allBundleIDs.contains(bid),
                  app.activationPolicy == .regular else {
                return nil
            }
            return app.processIdentifier
        }
    }
    
    /// The localized display name of the application.
    ///
    /// Returns the user-facing name of the running application as reported by the system.
    /// If the application is not running, falls back to the ``name`` property set at
    /// initialization. Returns `nil` if neither is available.
    ///
    /// The localized name may differ from the app's filename or bundle ID. For example,
    /// "Google Chrome" instead of "com.google.Chrome".
    ///
    /// ## Example
    ///
    /// ```swift
    /// // Display app name to user
    /// if let name = App.Safari?.localizedName {
    ///     print("Working with \(name)")
    /// }
    ///
    /// // Use in UI
    /// let displayName = App.Xcode?.localizedName ?? "Unknown App"
    /// label.text = displayName
    /// ```
    ///
    /// ## See Also
    /// - ``name`` for the name set at initialization
    /// - ``runningBundleID`` for the actual bundle identifier
    public var localizedName: String? {
        return runningApplication?.localizedName ?? name
    }

    /// The bundle identifier of the actually running application instance.
    ///
    /// Returns the bundle identifier of the currently running application, which may
    /// differ from ``bundleID`` when an alternate bundle ID was matched. For example,
    /// if the handle was created for Chrome but Chrome Canary is running instead,
    /// this returns "com.google.Chrome.canary".
    ///
    /// Returns `nil` if the application is not running.
    ///
    /// ## Example
    ///
    /// ```swift
    /// // Check which variant is actually running
    /// if let runningID = App.Chrome?.runningBundleID {
    ///     if runningID != App.Chrome?.bundleID {
    ///         print("Running alternate: \(runningID)")
    ///     }
    /// }
    ///
    /// // Log the actual running app
    /// if let app = App.Chrome, app.isRunning {
    ///     print("Running: \(app.runningBundleID ?? "unknown")")
    /// }
    /// ```
    ///
    /// ## See Also
    /// - ``bundleID`` for the primary bundle identifier
    /// - ``alternateBundleIDs`` for configured alternate bundle IDs
    public var runningBundleID: String? {
        return runningApplication?.bundleIdentifier
    }
    
    // MARK: - Private Helpers
    
    /// Returns the NSRunningApplication instance if the app is running.
    /// Checks all bundle IDs (primary and alternates).
    private var runningApplication: NSRunningApplication? {
        let runningApps = NSWorkspace.shared.runningApplications
        
        // Check primary bundle ID first
        if let app = runningApps.first(where: { $0.bundleIdentifier == bundleID }) {
            return app
        }
        
        // Check alternate bundle IDs
        for altBundleID in alternateBundleIDs {
            if let app = runningApps.first(where: { $0.bundleIdentifier == altBundleID }) {
                return app
            }
        }
        
        return nil
    }
}

// MARK: - Equatable

extension AppHandle: Equatable {
    public static func == (lhs: AppHandle, rhs: AppHandle) -> Bool {
        return lhs.bundleID == rhs.bundleID
    }
}

// MARK: - Hashable

extension AppHandle: Hashable {
    public func hash(into hasher: inout Hasher) {
        hasher.combine(bundleID)
    }
}

// MARK: - CustomStringConvertible

extension AppHandle: CustomStringConvertible {
    public var description: String {
        let displayName = localizedName ?? name ?? bundleID
        let status = isRunning ? (isHidden ? "hidden" : "running") : "not running"
        return "AppHandle(\(displayName), \(status))"
    }
}
