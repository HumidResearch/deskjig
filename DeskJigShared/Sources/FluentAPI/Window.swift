//  Window.swift
//  DeskJigShared

import Foundation
import AppKit
import ApplicationServices

/// Private ApplicationServices (HIServices) function that resolves an `AXUIElement`
/// directly to its `CGWindowID`. Private but ubiquitous — yabai/Rectangle-class window
/// tooling depends on it — and it is the only per-window identity source that works for
/// apps that don't expose the public `AXWindowNumber` attribute (Finder on macOS 26
/// exposes none; see #654 / PR #657 Mini verification). Returns `.success` and writes
/// the window number on resolution; any error is treated as "identity unavailable" and
/// callers fall back to the `AXWindowNumber` attribute read.
@_silgen_name("_AXUIElementGetWindow")
private func _AXUIElementGetWindow(
    _ element: AXUIElement,
    _ windowId: UnsafeMutablePointer<CGWindowID>
) -> AXError

// MARK: - Window Filter Options

/// Configuration options for filtering windows in query methods.
///
/// `WindowFilterOptions` provides fine-grained control over which windows are included
/// when querying windows through the Fluent API. This is useful for excluding helper
/// windows, toolbars, or windows in specific states (minimized, hidden).
///
/// The struct provides three preset configurations for common use cases:
/// - ``default``: Excludes small windows (<=64px) and empty titles, includes minimized/hidden
/// - ``all``: No filtering, includes everything
/// - ``visibleOnly``: Only visible windows on screen, excludes minimized/hidden
///
/// ## Example
///
/// ```swift
/// // Use default filtering (excludes tiny helper windows)
/// let windows = Window.all()
///
/// // Include all windows, even small helper windows
/// let allWindows = Window.all(filter: .all)
///
/// // Only get visible windows (not minimized or hidden)
/// let visibleWindows = Window.all(filter: .visibleOnly)
///
/// // Custom filter: large windows only
/// let largeWindows = Window.all(filter: WindowFilterOptions(
///     minWidth: 800,
///     minHeight: 600,
///     includeMinimized: false,
///     includeHidden: false
/// ))
/// ```
///
/// ## See Also
/// - ``Window/all(filter:)``
/// - ``Window/visible(filter:)``
public struct WindowFilterOptions {
    /// Minimum width for a window to be included.
    ///
    /// Windows with width less than this value are excluded. The default value of 65
    /// filters out small helper windows, toolbars, and other auxiliary UI elements
    /// that are typically 64 pixels or smaller.
    public var minWidth: CGFloat

    /// Minimum height for a window to be included.
    ///
    /// Windows with height less than this value are excluded. The default value of 65
    /// filters out small helper windows, toolbars, and other auxiliary UI elements
    /// that are typically 64 pixels or smaller.
    public var minHeight: CGFloat

    /// Whether to include minimized windows in results.
    ///
    /// When `true` (the default), minimized windows are included in query results.
    /// Set to `false` to only get windows that are currently visible on screen.
    public var includeMinimized: Bool

    /// Whether to include hidden windows in results.
    ///
    /// When `true` (the default), windows from hidden applications are included.
    /// Set to `false` to only get windows from visible applications.
    public var includeHidden: Bool

    /// Whether to include windows with empty titles.
    ///
    /// When `false` (the default), windows with empty or whitespace-only titles
    /// are excluded. These are often helper windows or background UI elements.
    public var includeEmptyTitles: Bool

    /// Whether to include windows with "Untitled" as their title.
    ///
    /// When `true` (the default), windows titled "Untitled" are included.
    /// Some applications use this for new, unsaved documents.
    public var includeUntitled: Bool

    /// Default filter options - excludes small windows and empty titles.
    ///
    /// This is the recommended preset for most use cases. It filters out:
    /// - Windows smaller than 65x65 pixels (helper windows, toolbars)
    /// - Windows with empty titles (background UI elements)
    ///
    /// It includes:
    /// - Minimized windows
    /// - Hidden windows (from hidden applications)
    /// - Windows titled "Untitled"
    public static let `default` = WindowFilterOptions(
        minWidth: 65,
        minHeight: 65,
        includeMinimized: true,
        includeHidden: true,
        includeEmptyTitles: false,
        includeUntitled: true
    )

    /// No filtering - includes all windows regardless of size or state.
    ///
    /// Use this preset when you need to see every window, including small
    /// helper windows, toolbars, and windows with empty titles.
    ///
    /// ## Example
    ///
    /// ```swift
    /// // Get absolutely every window from Safari
    /// let allSafariWindows = Window.all(for: "Safari", filter: .all)
    /// ```
    public static let all = WindowFilterOptions(
        minWidth: 0,
        minHeight: 0,
        includeMinimized: true,
        includeHidden: true,
        includeEmptyTitles: true,
        includeUntitled: true
    )

    /// Only visible windows - excludes minimized, hidden, small, and empty titles.
    ///
    /// Use this preset to get only windows that are currently visible on screen.
    /// This excludes:
    /// - Minimized windows
    /// - Windows from hidden applications
    /// - Windows smaller than 65x65 pixels
    /// - Windows with empty titles
    ///
    /// ## Example
    ///
    /// ```swift
    /// // Get only visible windows on screen
    /// let onScreenWindows = Window.visible()
    ///
    /// // Get the topmost visible window
    /// let topmost = Window.topmost(filter: .visibleOnly)
    /// ```
    public static let visibleOnly = WindowFilterOptions(
        minWidth: 65,
        minHeight: 65,
        includeMinimized: false,
        includeHidden: false,
        includeEmptyTitles: false,
        includeUntitled: true
    )

    /// Creates a new filter options instance with the specified criteria.
    ///
    /// - Parameters:
    ///   - minWidth: Minimum width for inclusion (default: 65)
    ///   - minHeight: Minimum height for inclusion (default: 65)
    ///   - includeMinimized: Include minimized windows (default: true)
    ///   - includeHidden: Include hidden windows (default: true)
    ///   - includeEmptyTitles: Include windows with empty titles (default: false)
    ///   - includeUntitled: Include windows titled "Untitled" (default: true)
    public init(
        minWidth: CGFloat = 65,
        minHeight: CGFloat = 65,
        includeMinimized: Bool = true,
        includeHidden: Bool = true,
        includeEmptyTitles: Bool = false,
        includeUntitled: Bool = true
    ) {
        self.minWidth = minWidth
        self.minHeight = minHeight
        self.includeMinimized = includeMinimized
        self.includeHidden = includeHidden
        self.includeEmptyTitles = includeEmptyTitles
        self.includeUntitled = includeUntitled
    }
}

/// Static entry point for finding and querying windows in the Fluent Window API.
///
/// `Window` provides a comprehensive set of static methods for discovering and querying
/// windows across all running applications. It is backed by AXWindowService for reliable
/// window discovery using the macOS Accessibility API.
///
/// ## Overview
///
/// The `Window` enum serves as the primary entry point for window discovery without needing
/// to first locate an application. Methods are organized into several categories:
///
/// - **CGWindowID Finders**: Find windows by their unique CGWindowID (most precise)
/// - **Composite Finders**: Find windows using multiple criteria (PID + title + frame)
/// - **Single Window Finders**: Find the first window matching criteria
/// - **Multiple Window Finders**: Find all windows matching criteria
/// - **Utility Methods**: Count windows, refresh data
///
/// ## Finding Windows
///
/// ```swift
/// // Find by window ID (most reliable)
/// Window.find(windowId: 12345)?.activate()
///
/// // Find by title
/// Window.find(title: "Document.pdf")?.maximize()
///
/// // Find first window of an app
/// Window.find(appName: "Safari")?.center()
/// Window.find(bundleID: "com.apple.Safari")?.raise()
///
/// // Find by partial title
/// Window.find(titleContaining: "CLAUDE")?.activate()
/// ```
///
/// ## Querying Multiple Windows
///
/// ```swift
/// // Get all windows
/// let allWindows = Window.all()
///
/// // Get all windows for a specific app
/// let safariWindows = Window.all(for: "Safari")
///
/// // Get only visible windows
/// let visible = Window.visible()
///
/// // Get minimized windows
/// let minimized = Window.minimized()
/// ```
///
/// ## Using the Topmost Window
///
/// ```swift
/// // Get the frontmost visible window
/// Window.topmost()?.center()?.raise()?.activate()
///
/// // Get topmost window at a specific location
/// Window.topmost(in: CGRect(x: 100, y: 100, width: 200, height: 200))
/// ```
///
/// ## Filtering Results
///
/// All query methods support filtering via ``WindowFilterOptions``:
///
/// ```swift
/// // Include all windows, even small helper windows
/// Window.all(filter: .all)
///
/// // Only visible windows (not minimized or hidden)
/// Window.all(filter: .visibleOnly)
///
/// // Custom filter for large windows only
/// Window.all(filter: WindowFilterOptions(minWidth: 800, minHeight: 600))
/// ```
///
/// ## Debug Metadata
///
/// Many finder methods have a `WithResult` variant that returns detailed metadata
/// about how the window was found, useful for debugging:
///
/// ```swift
/// let result = Window.findWithResult(title: "My Document")
/// print("Found: \(result.window != nil)")
/// print("Method: \(result.matchMethod)")
/// print("Duration: \(result.matchDuration)s")
/// print("Checked: \(result.candidatesChecked) windows")
/// ```
///
/// ## See Also
/// - ``WindowHandle``
/// - ``WindowFilterOptions``
/// - ``App``
public enum Window {
    
    // MARK: - Internal Helpers
    
    /// Get AXWindowService from FluentServices
    private static var axService: AXWindowServiceProtocol? {
        return FluentServices.shared.axWindowService
    }
    
    /// Get all running user applications (excludes background apps)
    private static func getRunningUserApps() -> [NSRunningApplication] {
        return NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular && $0.bundleIdentifier != nil
        }
    }
    
    /// Get all windows from all running applications
    private static func getAllWindowsFromAX() -> [AXWindow] {
        guard let service = axService else { return [] }
        
        var allWindows: [AXWindow] = []
        var processedPIDs: Set<pid_t> = []
        
        for app in getRunningUserApps() {
            let pid = app.processIdentifier
            processedPIDs.insert(pid)
            let windows = service.getWindows(
                forProcessID: pid,
                bundleIdentifier: app.bundleIdentifier
            )
            allWindows.append(contentsOf: windows)
        }
        
        // Robust discovery for Ghostty (often misses runningApplications)
        let ghosttyPIDs = getGhosttyPIDs()
        for pid in ghosttyPIDs {
            if !processedPIDs.contains(pid) {
                let windows = service.getWindows(forProcessID: pid, bundleIdentifier: "com.mitchellh.ghostty")
                allWindows.append(contentsOf: windows)
            }
        }
        
        return allWindows
    }
    
    /// Get all Ghostty process IDs using the shared locator.
    private static func getGhosttyPIDs() -> [pid_t] {
        GhosttyProcessLocator.findPIDs()
    }

    /// Get Ghostty windows via CGWindowList (can see windows on all Spaces)
    private static func getGhosttyWindowsViaCGWindowList() -> [(pid: pid_t, title: String, frame: CGRect, onScreen: Bool)] {
        let options = CGWindowListOption(arrayLiteral: .optionAll)
        guard let windowList = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return []
        }

        return windowList.compactMap { dict -> (pid: pid_t, title: String, frame: CGRect, onScreen: Bool)? in
            guard let ownerName = dict[kCGWindowOwnerName as String] as? String,
                  ownerName.lowercased().contains("ghostty"),
                  let pid = dict[kCGWindowOwnerPID as String] as? Int32,
                  let bounds = dict[kCGWindowBounds as String] as? [String: CGFloat],
                  let width = bounds["Width"], let height = bounds["Height"],
                  let x = bounds["X"], let y = bounds["Y"],
                  width > 100, height > 100  // Filter out toolbars/popups
            else { return nil }

            let title = dict[kCGWindowName as String] as? String ?? ""
            let onScreen = dict[kCGWindowIsOnscreen as String] as? Bool ?? false
            let frame = CGRect(x: x, y: y, width: width, height: height)

            // Only return windows with titles (real windows)
            guard !title.isEmpty else { return nil }
            return (pid: pid, title: title, frame: frame, onScreen: onScreen)
        }
    }
    
    /// Applies filter options to an AXWindow
    private static func passesFilter(_ window: AXWindow, options: WindowFilterOptions) -> Bool {
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
    
    /// Filters an array of AXWindow using the given options
    private static func filter(_ windows: [AXWindow], with options: WindowFilterOptions) -> [AXWindow] {
        return windows.filter { passesFilter($0, options: options) }
    }
    
    /// Get app name for a process ID
    private static func getAppName(for processID: pid_t) -> String? {
        return NSWorkspace.shared.runningApplications
            .first { $0.processIdentifier == processID }?
            .localizedName
    }

    /// Resolves an AX window to its window-server window number (CGWindowID namespace).
    ///
    /// Primary source is the private `_AXUIElementGetWindow` function: unlike the public
    /// `AXWindowNumber` attribute — which many AppKit apps (Finder on macOS 26 included)
    /// simply do not expose — it resolves for every ordinary window, which is what makes
    /// the #654 identity path engage for same-title siblings. The attribute read is kept
    /// as a fallback for the (unlikely) case where the private symbol errors.
    static func axWindowNumber(for window: AXWindow) -> Int? {
        // Primary: direct AXUIElement → CGWindowID resolution.
        var resolvedId: CGWindowID = 0
        if _AXUIElementGetWindow(window.axElement, &resolvedId) == .success, resolvedId != 0 {
            return Int(resolvedId)
        }

        // Fallback: public AXWindowNumber attribute (exposed by some apps, e.g. Xcode).
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(window.axElement, "AXWindowNumber" as CFString, &value)
        guard result == .success, let value else { return nil }
        if let number = value as? NSNumber { return number.intValue }
        if let intValue = value as? Int { return intValue }
        return nil
    }

    private static func frameDistance(_ lhs: CGRect, _ rhs: CGRect) -> CGFloat {
        lhs.manhattanDistance(to: rhs)
    }

    private static func closestFrameMatch(in windows: [AXWindow], target: CGRect) -> AXWindow? {
        windows.min { frameDistance($0.frame, target) < frameDistance($1.frame, target) }
    }

    // MARK: - CGWindowID → AX Correlation (#654)

    /// How ``correlateAXWindow(windowId:cgFrame:cgTitle:strategy:candidates:windowNumberProvider:)``
    /// matched a candidate.
    enum AXCorrelationMethod: Equatable {
        /// The candidate's resolved window number (`_AXUIElementGetWindow`, falling back
        /// to the `AXWindowNumber` attribute) equals the requested CGWindowID (exact identity).
        case windowNumber
        /// Heuristic fallback using the requested matching strategy.
        case strategy(AXMatchingStrategy)
    }

    /// A correlated AX window plus the method that selected it.
    struct AXCorrelationMatch {
        let window: AXWindow
        let method: AXCorrelationMethod
    }

    /// Correlation failures where guessing would provably risk acting on the wrong
    /// window, so resolution must fail honestly instead (#654).
    enum AXCorrelationError: Error, Equatable, CustomStringConvertible {
        /// Multiple candidates lack a resolvable window number AND share an identical
        /// frame (distance-0 tie): "closest frame" degenerates to enumeration order,
        /// which is exactly the arbitrary-sibling pick that swapped the Finder windows
        /// in the #654 scenario. Never silently move a window that can't be
        /// disambiguated.
        case ambiguousFrameTie(windowId: CGWindowID, tiedCandidates: Int)

        var description: String {
            switch self {
            case .ambiguousFrameTie(let windowId, let tiedCandidates):
                return "windowId=\(windowId): \(tiedCandidates) AX candidates without a resolvable window number share an identical frame; refusing to pick an arbitrary sibling"
            }
        }
    }

    /// Correlates a CGWindowID to one of a process's AX windows.
    ///
    /// Identity comes first: the resolved window number is the window server's window
    /// number — the same namespace as CGWindowID — so an exact match is authoritative.
    /// Frame/title heuristics cannot distinguish same-title siblings that share (or once
    /// shared) a frame, which is how `window move --window-id` used to act on the wrong
    /// sibling (#654). The heuristic strategies therefore only ever see candidates whose
    /// identity is *unknown* (window number unresolvable): a candidate that reports a
    /// different number is provably another window and is never heuristically matched.
    ///
    /// - Parameter windowNumberProvider: Injected per the #481 convention so tests can
    ///   correlate hermetically. The production default tries the private
    ///   `_AXUIElementGetWindow` first (works for every app, Finder included) and falls
    ///   back to the public `AXWindowNumber` attribute read.
    ///
    /// - Throws: ``AXCorrelationError/ambiguousFrameTie(windowId:tiedCandidates:)`` when
    ///   the winning frame-based candidate shares an *identical* frame with another
    ///   candidate and neither has a resolvable window number — a distance-0 tie is
    ///   enumeration-order roulette, so resolution fails honestly instead of guessing.
    static func correlateAXWindow(
        windowId: CGWindowID,
        cgFrame: CGRect,
        cgTitle: String?,
        strategy: AXMatchingStrategy,
        candidates: [AXWindow],
        windowNumberProvider: (AXWindow) -> Int? = { axWindowNumber(for: $0) }
    ) throws -> AXCorrelationMatch? {
        var unidentified: [AXWindow] = []
        for candidate in candidates {
            guard let number = windowNumberProvider(candidate) else {
                unidentified.append(candidate)
                continue
            }
            if number == Int(windowId) {
                return AXCorrelationMatch(window: candidate, method: .windowNumber)
            }
        }

        /// Fails honestly on a distance-0 tie: identical frames among unidentified
        /// candidates cannot be told apart by any frame heuristic.
        func requireUntied(_ match: AXWindow, among frameMatches: [AXWindow]) throws {
            let tied = frameMatches.filter { $0.frame.equalTo(match.frame) }
            if tied.count > 1 {
                DeskJigLog.debug(.window, "🔍 [HandleDebug] windowId=\(windowId) UNRESOLVABLE: \(tied.count) candidates without a window number share an identical frame; refusing to guess (#654)")
                throw AXCorrelationError.ambiguousFrameTie(windowId: windowId, tiedCandidates: tied.count)
            }
        }

        switch strategy {
        case .frameOnly:
            let frameMatches = unidentified.filter { $0.frameMatches(cgFrame, tolerance: 5) }
            if let match = closestFrameMatch(in: frameMatches, target: cgFrame) {
                try requireUntied(match, among: frameMatches)
                if frameMatches.count > 1 {
                    DeskJigLog.debug(.window, "🔍 [HandleDebug] windowId=\(windowId) ambiguous frame match (\(frameMatches.count) candidates without a resolvable window number); picked closest")
                }
                return AXCorrelationMatch(window: match, method: .strategy(strategy))
            }

        case .titleOnly:
            if let title = cgTitle, !title.isEmpty,
               let match = unidentified.first(where: { $0.title == title }) {
                return AXCorrelationMatch(window: match, method: .strategy(strategy))
            }

        case .frameAndTitle:
            if let title = cgTitle {
                let frameMatches = unidentified.filter {
                    $0.frameMatches(cgFrame, tolerance: 5) && $0.title == title
                }
                if let match = closestFrameMatch(in: frameMatches, target: cgFrame) {
                    try requireUntied(match, among: frameMatches)
                    return AXCorrelationMatch(window: match, method: .strategy(strategy))
                }
            }

        case .pidFirstWindow:
            if let match = unidentified.first {
                return AXCorrelationMatch(window: match, method: .strategy(strategy))
            }
        }

        return nil
    }

    // MARK: - CGWindowID-Based Finders (Most Precise)

    /// Returns read-only window information for a CGWindowID.
    ///
    /// This is the fastest lookup method (approximately 10ms) and can see windows on ALL Spaces,
    /// including windows that are not on the current Space. However, it returns read-only
    /// information and cannot be used to manipulate windows.
    ///
    /// This method uses CGWindowList API directly without Accessibility API access, making it
    /// useful for quick lookups when you only need window metadata.
    ///
    /// - Parameter windowId: The unique CGWindowID to look up. This ID is assigned by the
    ///   window server and remains stable for the lifetime of the window.
    ///
    /// - Returns: An `SnapshotWindow` containing window metadata (frame, title, app info),
    ///   or `nil` if no window exists with the specified ID.
    ///
    /// ## Example
    ///
    /// ```swift
    /// // Quick lookup of window info without AX overhead
    /// if let info = Window.info(windowId: 12345) {
    ///     print("Window: \(info.title ?? "Untitled")")
    ///     print("App: \(info.appName ?? "Unknown")")
    ///     print("Frame: \(info.frame)")
    ///     print("On screen: \(info.isOnScreen)")
    /// }
    /// ```
    ///
    /// ## See Also
    /// - ``find(windowId:axMatchStrategy:filter:)`` for a manipulable WindowHandle
    /// - ``infoWithResult(windowId:)`` for debug metadata
    public static func info(windowId: CGWindowID) -> SnapshotWindow? {
        guard let lookup = lookupWindowDictionary(windowId: windowId),
              let window = snapshotWindow(
                  from: lookup.dictionary,
                  expectedWindowId: windowId,
                  appInfoByPid: runningAppInfoByPid()
              ) else {
            return nil
        }

        if lookup.lookupMethod == "scanFallback" {
            DeskJigLog.debug(.window, "Window.info fallback lookup used", fields: [
                "windowId": "\(windowId)",
                "lookupMethod": lookup.lookupMethod,
                "candidatesChecked": "\(lookup.candidatesChecked)"
            ])
        }

        return window
    }

    /// Returns read-only window information for a CGWindowID with debug metadata.
    ///
    /// This method is identical to ``info(windowId:)`` but returns additional metadata
    /// about the lookup process, useful for debugging and telemetry.
    ///
    /// - Parameter windowId: The unique CGWindowID to look up.
    ///
    /// - Returns: A `WindowInfoFinderResult` containing either the window info with match
    ///   metadata, or failure information including the reason the window was not found.
    ///
    /// ## Example
    ///
    /// ```swift
    /// let result = Window.infoWithResult(windowId: 12345)
    /// if let window = result.window {
    ///     print("Found window: \(window.title ?? "Untitled")")
    ///     print("Search took: \(result.matchDuration)s")
    /// } else {
    ///     print("Not found: \(result.notFoundReason ?? "Unknown")")
    /// }
    /// ```
    ///
    /// ## See Also
    /// - ``info(windowId:)`` for simple lookups without metadata
    public static func infoWithResult(windowId: CGWindowID) -> WindowInfoFinderResult {
        let startTime = Date()
        let criteria = WindowFinderCriteria(windowId: windowId)

        guard let lookup = lookupWindowDictionary(windowId: windowId) else {
            return .notFound(
                method: .windowId,
                criteria: criteria,
                duration: Date().timeIntervalSince(startTime),
                candidatesChecked: 0,
                reason: "Window not found via direct or scan lookup for windowId \(windowId)"
            )
        }

        guard let window = snapshotWindow(
            from: lookup.dictionary,
            expectedWindowId: windowId,
            appInfoByPid: runningAppInfoByPid()
        ) else {
            return .notFound(
                method: .windowId,
                criteria: criteria,
                duration: Date().timeIntervalSince(startTime),
                candidatesChecked: lookup.candidatesChecked,
                reason: "Window found via \(lookup.lookupMethod) lookup but missing required fields"
            )
        }

        if lookup.lookupMethod == "scanFallback" {
            DeskJigLog.debug(.window, "Window.infoWithResult fallback lookup used", fields: [
                "windowId": "\(windowId)",
                "lookupMethod": lookup.lookupMethod,
                "candidatesChecked": "\(lookup.candidatesChecked)"
            ])
        }

        return WindowInfoFinderResult(
            window: window,
            matchMethod: .windowId,
            inputCriteria: criteria,
            matchDuration: Date().timeIntervalSince(startTime),
            candidatesChecked: lookup.candidatesChecked,
            matchDetails: "Found window by \(lookup.lookupMethod) lookup"
        )
    }

    private struct WindowIdLookupResult {
        let dictionary: [String: Any]
        let lookupMethod: String
        let candidatesChecked: Int
    }

    private static func runningAppInfoByPid() -> [pid_t: (bundleId: String?, appName: String?)] {
        let apps = NSWorkspace.shared.runningApplications
        var infoByPid: [pid_t: (bundleId: String?, appName: String?)] = [:]
        for app in apps {
            infoByPid[app.processIdentifier] = (app.bundleIdentifier, app.localizedName)
        }
        return infoByPid
    }

    private static func lookupWindowDictionary(windowId: CGWindowID) -> WindowIdLookupResult? {
        // CGWindowListCreateDescriptionFromArray expects a CFArray whose elements are raw
        // CGWindowID values stored as pointer-sized entries (the C convention), not CFNumbers.
        // `[windowId] as CFArray` bridges to NSNumber elements, which this API cannot read and
        // reliably returns empty for (verified: 0/8 hits on live cross-process window IDs).
        // Building the array via CFArrayCreate with an UnsafeRawPointer bit-pattern of the
        // window ID gets pointer-valued entries and the targeted query actually matches
        // (verified: 8/8 hits on the same IDs). See WindowManager.getCurrentWindowFrame(for:)
        // for the same fix applied to the other lookup call site (#668).
        var windowIdPtr = UnsafeRawPointer(bitPattern: UInt(windowId))
        if let directArray = CFArrayCreate(kCFAllocatorDefault, &windowIdPtr, 1, nil),
           let directList = CGWindowListCreateDescriptionFromArray(directArray) as? [[String: Any]],
           let directDict = directList.first,
           let foundWindowId = directDict[kCGWindowNumber as String] as? CGWindowID,
           foundWindowId == windowId {
            return WindowIdLookupResult(
                dictionary: directDict,
                lookupMethod: "direct",
                candidatesChecked: 1
            )
        }

        let options: CGWindowListOption = [.optionAll]
        guard let windowList = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }

        var candidatesChecked = 0
        for dict in windowList {
            candidatesChecked += 1
            guard let foundWindowId = dict[kCGWindowNumber as String] as? CGWindowID,
                  foundWindowId == windowId else { continue }

            return WindowIdLookupResult(
                dictionary: dict,
                lookupMethod: "scanFallback",
                candidatesChecked: candidatesChecked
            )
        }

        return nil
    }

    private static func snapshotWindow(
        from dictionary: [String: Any],
        expectedWindowId: CGWindowID,
        appInfoByPid: [pid_t: (bundleId: String?, appName: String?)]
    ) -> SnapshotWindow? {
        guard let foundWindowId = dictionary[kCGWindowNumber as String] as? CGWindowID,
              foundWindowId == expectedWindowId else {
            return nil
        }

        guard let ownerPid = dictionary[kCGWindowOwnerPID as String] as? pid_t,
              let boundsDict = dictionary[kCGWindowBounds as String] as? [String: CGFloat],
              let x = boundsDict["X"],
              let y = boundsDict["Y"],
              let width = boundsDict["Width"],
              let height = boundsDict["Height"] else {
            return nil
        }

        let appInfo = appInfoByPid[ownerPid]
        let layer = dictionary[kCGWindowLayer as String] as? Int ?? 0
        let isOnScreen = dictionary[kCGWindowIsOnscreen as String] as? Bool ?? false
        let title = dictionary[kCGWindowName as String] as? String

        return SnapshotWindow(
            windowId: expectedWindowId,
            pid: ownerPid,
            bundleId: appInfo?.bundleId,
            appName: appInfo?.appName ?? (dictionary[kCGWindowOwnerName as String] as? String),
            title: title,
            frame: CGRect(x: x, y: y, width: width, height: height),
            layer: layer,
            isOnScreen: isOnScreen
        )
    }

    /// Finds a window by CGWindowID and returns a manipulable WindowHandle.
    ///
    /// This method first looks up the window using CGWindowList API to get its metadata,
    /// then correlates it with an AXUIElement to enable window manipulation. This two-step
    /// process is necessary because macOS provides no direct API to convert a CGWindowID
    /// to an AXUIElement.
    ///
    /// The correlation between CGWindowID and AXUIElement is done using the specified
    /// matching strategy, which determines how windows are matched:
    ///
    /// - `.frameOnly` (default): Match by window frame position and size. Most reliable.
    /// - `.titleOnly`: Match by window title. Works when titles are unique.
    /// - `.frameAndTitle`: Match by both frame and title. Most precise but strictest.
    /// - `.pidFirstWindow`: Take the first window for the process. Fallback strategy.
    ///
    /// - Parameters:
    ///   - windowId: The unique CGWindowID to look up. This ID is assigned by the window
    ///     server and remains stable for the lifetime of the window.
    ///   - axMatchStrategy: The strategy used to correlate the CGWindowID with an
    ///     AXUIElement. Defaults to `.frameOnly` which is the most reliable.
    ///   - filter: Options for filtering candidate windows. Defaults to excluding small
    ///     windows and those with empty titles.
    ///
    /// - Returns: A `WindowHandle` that can be used to manipulate the window (move, resize,
    ///   minimize, etc.), or `nil` if the window was not found or could not be correlated.
    ///
    /// ## Example
    ///
    /// ```swift
    /// // Find and manipulate a window by its ID
    /// if let window = Window.find(windowId: 12345) {
    ///     window.moveTo(x: 100, y: 100)
    ///     window.resize(width: 800, height: 600)
    ///     window.activate()
    /// }
    ///
    /// // Use title matching when frame matching fails (rare)
    /// let window = Window.find(windowId: 12345, axMatchStrategy: .titleOnly)
    /// ```
    ///
    /// ## See Also
    /// - ``info(windowId:)`` for read-only window info without AX overhead
    /// - ``findWithResult(windowId:axMatchStrategy:filter:)`` for debug metadata
    /// - ``AXMatchingStrategy`` for available matching strategies
    public static func find(
        windowId: CGWindowID,
        axMatchStrategy: AXMatchingStrategy = .frameOnly,
        filter: WindowFilterOptions = .default
    ) -> WindowHandle? {
        guard let service = axService else { return nil }

        // Step 1: Get window info from CGWindowList
        guard let windowInfo = info(windowId: windowId) else {
            return nil
        }

        // Step 2: Get AX windows for the same PID
        let bundleId = windowInfo.bundleId
        let axWindows = service.getWindows(forProcessID: windowInfo.pid, bundleIdentifier: bundleId)
        let filtered = self.filter(axWindows, with: filter)

        // Debug logging for handle acquisition failures
        if filtered.isEmpty {
            DeskJigLog.debug(.window, "🔍 [HandleDebug] windowId=\(windowId) bundleId=\(bundleId ?? "nil") - No AX windows returned for PID \(windowInfo.pid) (unfiltered=\(axWindows.count))")
        } else {
            // Always log available AX windows for debugging frame mismatches
            let axFrameDetails = filtered.map { ax in
                let title = ax.title.isEmpty ? "untitled" : ax.title.prefix(30)
                return "'\(title)' \(Int(ax.frame.origin.x)),\(Int(ax.frame.origin.y)) \(Int(ax.frame.width))x\(Int(ax.frame.height))"
            }
            DeskJigLog.debug(.window, "🔍 [HandleDebug] windowId=\(windowId) bundleId=\(bundleId ?? "nil") - AX windows available (\(filtered.count)): [\(axFrameDetails.joined(separator: " | "))]")
        }

        // Step 3: Correlate by window-number identity first, then the requested strategy (#654)
        let correlation: AXCorrelationMatch?
        do {
            correlation = try correlateAXWindow(
                windowId: windowId,
                cgFrame: windowInfo.frame,
                cgTitle: windowInfo.title,
                strategy: axMatchStrategy,
                candidates: filtered
            )
        } catch {
            // Distance-0 tie without identity: fail honestly (no fallbacks) rather than
            // move a window that can't be disambiguated.
            DeskJigLog.debug(.window, "🔍 [HandleDebug] correlation failed honestly: \(error)")
            return nil
        }
        if let match = correlation {
            if match.method == .windowNumber {
                DeskJigLog.debug(.window, "🔍 [HandleDebug] windowId=\(windowId) window number identity match (_AXUIElementGetWindow/AXWindowNumber)")
            }
            return WindowHandle(axWindow: match.window)
        }

        // Debug logging for frame mismatch
        if axMatchStrategy == .frameOnly, !filtered.isEmpty {
            let cgFrame = windowInfo.frame
            let cgTitle = windowInfo.title ?? "untitled"
            DeskJigLog.debug(.window, "🔍 [HandleDebug] windowId=\(windowId) FRAME MISMATCH - CG:'\(cgTitle)' \(Int(cgFrame.origin.x)),\(Int(cgFrame.origin.y)) \(Int(cgFrame.width))x\(Int(cgFrame.height)) - no AX window within 5px tolerance")
        }

        // Fallback for problematic apps where frame matching often fails
        // These apps report different frames via CGWindowList vs AXUIElement:
        // - Xcode: frame discrepancies between CG and AX
        // - Zoom: fullscreen overlay windows visible to CG but not exposed via AX
        // (The former AXWindowNumber exact-match step lives in correlateAXWindow now,
        // which already checked every candidate for all apps.)
        if axMatchStrategy == .frameOnly, !filtered.isEmpty {
            let problematicBundleIds = ["com.apple.dt.Xcode", "com.apple.Xcode", "us.zoom.xos", "com.todesktop.230313mzl4w4u92"]
            if let bundleId = bundleId, problematicBundleIds.contains(bundleId) {
                // Try title-based matching first for better accuracy
                if let cgTitle = windowInfo.title, !cgTitle.isEmpty {
                    // Exact title match
                    let exactTitleMatches = filtered.filter { $0.title == cgTitle }
                    if let titleMatch = closestFrameMatch(in: exactTitleMatches, target: windowInfo.frame) {
                        DeskJigLog.debug(.window, "🔍 [HandleDebug] windowId=\(windowId) problematic app fallback: exact title match '\(cgTitle)'")
                        return WindowHandle(axWindow: titleMatch)
                    }
                    // Partial title match (title contains CG title or vice versa)
                    let partialTitleMatches = filtered.filter {
                        $0.title.contains(cgTitle) || cgTitle.contains($0.title)
                    }
                    if let partialMatch = closestFrameMatch(in: partialTitleMatches, target: windowInfo.frame) {
                        DeskJigLog.debug(.window, "🔍 [HandleDebug] windowId=\(windowId) problematic app fallback: partial title match '\(partialMatch.title)' for CG '\(cgTitle)'")
                        return WindowHandle(axWindow: partialMatch)
                    }
                }
                // Last resort: use first window (existing behavior)
                DeskJigLog.debug(.window, "🔍 [HandleDebug] windowId=\(windowId) problematic app fallback: no title match, using first window '\(filtered.first!.title)'")
                return WindowHandle(axWindow: filtered.first!)
            }
        }

        return nil
    }

    /// Finds a window by CGWindowID and returns a WindowHandle with debug metadata.
    ///
    /// This method is identical to ``find(windowId:axMatchStrategy:filter:)`` but returns
    /// additional metadata about the lookup process, useful for debugging, telemetry,
    /// and understanding why a window was or was not found.
    ///
    /// - Parameters:
    ///   - windowId: The unique CGWindowID to look up.
    ///   - axMatchStrategy: The strategy used to correlate the CGWindowID with an
    ///     AXUIElement. Defaults to `.frameOnly`.
    ///   - filter: Options for filtering candidate windows.
    ///
    /// - Returns: A `WindowFinderResult` containing either the WindowHandle with match
    ///   metadata, or failure information including the reason the window was not found.
    ///
    /// ## Example
    ///
    /// ```swift
    /// let result = Window.findWithResult(windowId: 12345)
    /// if let window = result.window {
    ///     print("Found via: \(result.matchMethod)")
    ///     print("Duration: \(result.matchDuration)ms")
    ///     window.activate()
    /// } else {
    ///     print("Failed: \(result.notFoundReason ?? "Unknown")")
    ///     print("Checked \(result.candidatesChecked) windows")
    /// }
    /// ```
    ///
    /// ## See Also
    /// - ``find(windowId:axMatchStrategy:filter:)`` for simple lookups
    public static func findWithResult(
        windowId: CGWindowID,
        axMatchStrategy: AXMatchingStrategy = .frameOnly,
        filter: WindowFilterOptions = .default
    ) -> WindowFinderResult {
        let startTime = Date()
        let criteria = WindowFinderCriteria(windowId: windowId)

        guard let service = axService else {
            return .notFound(
                method: .windowId,
                criteria: criteria,
                duration: Date().timeIntervalSince(startTime),
                candidatesChecked: 0,
                reason: "AXWindowService not available"
            )
        }

        // Step 1: Get window info from CGWindowList
        guard let windowInfo = info(windowId: windowId) else {
            return .notFound(
                method: .windowId,
                criteria: criteria,
                duration: Date().timeIntervalSince(startTime),
                candidatesChecked: 0,
                reason: "No window found in CGWindowList with ID \(windowId)"
            )
        }

        // Step 2: Get AX windows for the same PID
        let bundleId = windowInfo.bundleId
        let axWindows = service.getWindows(forProcessID: windowInfo.pid, bundleIdentifier: bundleId)
        let filtered = self.filter(axWindows, with: filter)

        // Step 3: Correlate by window-number identity first, then the requested strategy (#654)
        let correlation: AXCorrelationMatch?
        do {
            correlation = try correlateAXWindow(
                windowId: windowId,
                cgFrame: windowInfo.frame,
                cgTitle: windowInfo.title,
                strategy: axMatchStrategy,
                candidates: filtered
            )
        } catch {
            // Distance-0 tie without identity: fail honestly (no fallbacks) rather than
            // resolve to a window that can't be disambiguated.
            return .notFound(
                method: .windowId,
                criteria: criteria,
                duration: Date().timeIntervalSince(startTime),
                candidatesChecked: filtered.count,
                reason: "\(error)"
            )
        }
        if let match = correlation {
            let matchDetails: String
            switch match.method {
            case .windowNumber:
                matchDetails = "Found by CGWindowID → window number identity match (_AXUIElementGetWindow/AXWindowNumber)"
            case .strategy(.frameOnly):
                matchDetails = "Found by CGWindowID → frame matching (\(axMatchStrategy.rawValue))"
            case .strategy(.titleOnly):
                matchDetails = "Found by CGWindowID → title matching (\(axMatchStrategy.rawValue))"
            case .strategy(.frameAndTitle):
                matchDetails = "Found by CGWindowID → frame + title matching (\(axMatchStrategy.rawValue))"
            case .strategy(.pidFirstWindow):
                matchDetails = "Found by CGWindowID → first window for PID (\(axMatchStrategy.rawValue))"
            }
            return WindowFinderResult(
                window: WindowHandle(axWindow: match.window),
                matchMethod: .windowId,
                inputCriteria: criteria,
                matchDuration: Date().timeIntervalSince(startTime),
                candidatesChecked: filtered.count,
                matchDetails: matchDetails
            )
        }

        // Fallback for problematic apps where frame matching often fails
        // These apps report different frames via CGWindowList vs AXUIElement:
        // - Xcode: frame discrepancies between CG and AX
        // - Zoom: fullscreen overlay windows visible to CG but not exposed via AX
        // (The former AXWindowNumber exact-match step lives in correlateAXWindow now,
        // which already checked every candidate for all apps.)
        if axMatchStrategy == .frameOnly, !filtered.isEmpty {
            let problematicBundleIds = ["com.apple.dt.Xcode", "com.apple.Xcode", "us.zoom.xos", "com.todesktop.230313mzl4w4u92"]
            if let bundleId = bundleId, problematicBundleIds.contains(bundleId) {
                // Try title-based matching first for better accuracy
                if let cgTitle = windowInfo.title, !cgTitle.isEmpty {
                    // Exact title match
                    let exactTitleMatches = filtered.filter { $0.title == cgTitle }
                    if let titleMatch = closestFrameMatch(in: exactTitleMatches, target: windowInfo.frame) {
                        DeskJigLog.debug(.window, "🔍 [HandleDebug] windowId=\(windowId) problematic app fallback: exact title match '\(cgTitle)'")
                        return WindowFinderResult(
                            window: WindowHandle(axWindow: titleMatch),
                            matchMethod: .windowId,
                            inputCriteria: criteria,
                            matchDuration: Date().timeIntervalSince(startTime),
                            candidatesChecked: filtered.count,
                            matchDetails: "Found by CGWindowID → problematic app fallback (exact title match '\(cgTitle)')"
                        )
                    }
                    // Partial title match (title contains CG title or vice versa)
                    let partialTitleMatches = filtered.filter {
                        $0.title.contains(cgTitle) || cgTitle.contains($0.title)
                    }
                    if let partialMatch = closestFrameMatch(in: partialTitleMatches, target: windowInfo.frame) {
                        DeskJigLog.debug(.window, "🔍 [HandleDebug] windowId=\(windowId) problematic app fallback: partial title match '\(partialMatch.title)' for CG '\(cgTitle)'")
                        return WindowFinderResult(
                            window: WindowHandle(axWindow: partialMatch),
                            matchMethod: .windowId,
                            inputCriteria: criteria,
                            matchDuration: Date().timeIntervalSince(startTime),
                            candidatesChecked: filtered.count,
                            matchDetails: "Found by CGWindowID → problematic app fallback (partial title match '\(partialMatch.title)' for CG '\(cgTitle)')"
                        )
                    }
                }
                // Last resort: use first window (existing behavior)
                DeskJigLog.debug(.window, "🔍 [HandleDebug] windowId=\(windowId) problematic app fallback: no title match, using first window '\(filtered.first!.title)'")
                return WindowFinderResult(
                    window: WindowHandle(axWindow: filtered.first!),
                    matchMethod: .windowId,
                    inputCriteria: criteria,
                    matchDuration: Date().timeIntervalSince(startTime),
                    candidatesChecked: filtered.count,
                    matchDetails: "Found by CGWindowID → problematic app fallback (first window for PID)"
                )
            }
        }

        return .notFound(
            method: .windowId,
            criteria: criteria,
            duration: Date().timeIntervalSince(startTime),
            candidatesChecked: filtered.count,
            reason: "CGWindowID found but no matching AXWindow using \(axMatchStrategy.rawValue) strategy"
        )
    }

    // MARK: - Composite Finders (PID + Title + Frame)

    /// Finds a window using composite criteria with process ID required.
    ///
    /// This method allows precise window matching using multiple criteria. The process ID
    /// is always required, while title and frame are optional refinements. All provided
    /// criteria must match - there are no fallbacks. If any criterion fails to match,
    /// the method returns `nil`.
    ///
    /// This is particularly useful for workspace restoration where you have saved window
    /// state (PID, title, frame) and need to relocate the exact same window.
    ///
    /// - Parameters:
    ///   - processID: The process ID that owns the window. This is required and narrows
    ///     the search to windows belonging to a specific application process.
    ///   - title: Optional exact title to match. When provided, the window's title must
    ///     match exactly (case-sensitive).
    ///   - frame: Optional frame to match. When provided, the window's frame must be
    ///     within the specified tolerance of this frame.
    ///   - frameTolerance: Maximum pixel difference allowed for frame matching. Defaults
    ///     to 10 pixels to account for minor positioning differences.
    ///   - filter: Options for filtering candidate windows. Defaults to excluding small
    ///     windows and those with empty titles.
    ///
    /// - Returns: A `WindowHandle` for the first window matching all criteria, or `nil`
    ///   if no window matches all the specified criteria.
    ///
    /// ## Example
    ///
    /// ```swift
    /// // Find window by PID only (first window of the process)
    /// if let window = Window.find(processID: 1234) {
    ///     window.activate()
    /// }
    ///
    /// // Find window by PID and exact title
    /// if let window = Window.find(processID: 1234, title: "My Document.txt") {
    ///     window.raise()
    /// }
    ///
    /// // Find window by PID and approximate frame position
    /// let targetFrame = CGRect(x: 100, y: 100, width: 800, height: 600)
    /// if let window = Window.find(processID: 1234, frame: targetFrame, frameTolerance: 20) {
    ///     window.activate()
    /// }
    ///
    /// // Find with all criteria (most precise)
    /// if let window = Window.find(
    ///     processID: 1234,
    ///     title: "My Document.txt",
    ///     frame: targetFrame
    /// ) {
    ///     print("Found exact window match")
    /// }
    /// ```
    ///
    /// ## See Also
    /// - ``findWithResult(processID:title:frame:frameTolerance:filter:)`` for debug metadata
    /// - ``find(windowId:axMatchStrategy:filter:)`` for CGWindowID-based lookup
    public static func find(
        processID: pid_t,
        title: String? = nil,
        frame: CGRect? = nil,
        frameTolerance: CGFloat = 10,
        filter: WindowFilterOptions = .default
    ) -> WindowHandle? {
        guard let service = axService else { return nil }

        // Get bundle ID for the process
        let bundleId = NSWorkspace.shared.runningApplications
            .first { $0.processIdentifier == processID }?
            .bundleIdentifier

        let windows = service.getWindows(forProcessID: processID, bundleIdentifier: bundleId)
        let filtered = self.filter(windows, with: filter)

        for window in filtered {
            // Check title if provided
            if let requiredTitle = title, window.title != requiredTitle {
                continue
            }

            // Check frame if provided
            if let requiredFrame = frame, !window.frameMatches(requiredFrame, tolerance: frameTolerance) {
                continue
            }

            // All criteria matched
            return WindowHandle(axWindow: window)
        }

        return nil
    }

    /// Finds a window using composite criteria and returns a WindowHandle with debug metadata.
    ///
    /// This method is identical to ``find(processID:title:frame:frameTolerance:filter:)`` but
    /// returns additional metadata about the lookup process, useful for debugging, telemetry,
    /// and understanding why a window was or was not found.
    ///
    /// The result includes detailed information about the match method used, the number of
    /// windows checked, the search duration, and the specific reason for failure if the
    /// window was not found.
    ///
    /// - Parameters:
    ///   - processID: The process ID that owns the window (required).
    ///   - title: Optional exact title to match.
    ///   - frame: Optional frame to match.
    ///   - frameTolerance: Maximum pixel difference for frame matching (default: 10px).
    ///   - filter: Options for filtering candidate windows.
    ///
    /// - Returns: A `WindowFinderResult` containing either the WindowHandle with match
    ///   metadata, or failure information.
    ///
    /// ## Example
    ///
    /// ```swift
    /// let result = Window.findWithResult(
    ///     processID: 1234,
    ///     title: "My Document.txt"
    /// )
    ///
    /// switch result.matchMethod {
    /// case .processIdAndTitle:
    ///     print("Matched by PID and title")
    /// case .processIdAndFrame:
    ///     print("Matched by PID and frame")
    /// default:
    ///     break
    /// }
    ///
    /// if result.window == nil {
    ///     print("Failed: \(result.notFoundReason ?? "Unknown")")
    /// }
    /// ```
    ///
    /// ## See Also
    /// - ``find(processID:title:frame:frameTolerance:filter:)`` for simple lookups
    public static func findWithResult(
        processID: pid_t,
        title: String? = nil,
        frame: CGRect? = nil,
        frameTolerance: CGFloat = 10,
        filter: WindowFilterOptions = .default
    ) -> WindowFinderResult {
        let startTime = Date()
        let criteria = WindowFinderCriteria(
            processId: processID,
            title: title,
            frame: frame,
            frameTolerance: frame != nil ? frameTolerance : nil
        )

        // Determine match method based on provided criteria
        let matchMethod: WindowFinderMethod
        if title != nil && frame != nil {
            matchMethod = .processIdTitleAndFrame
        } else if title != nil {
            matchMethod = .processIdAndTitle
        } else if frame != nil {
            matchMethod = .processIdAndFrame
        } else {
            matchMethod = .processId
        }

        guard let service = axService else {
            return .notFound(
                method: matchMethod,
                criteria: criteria,
                duration: Date().timeIntervalSince(startTime),
                candidatesChecked: 0,
                reason: "AXWindowService not available"
            )
        }

        // Get bundle ID for the process
        let bundleId = NSWorkspace.shared.runningApplications
            .first { $0.processIdentifier == processID }?
            .bundleIdentifier

        let windows = service.getWindows(forProcessID: processID, bundleIdentifier: bundleId)
        let filtered = self.filter(windows, with: filter)

        if filtered.isEmpty {
            return .notFound(
                method: matchMethod,
                criteria: criteria,
                duration: Date().timeIntervalSince(startTime),
                candidatesChecked: 0,
                reason: "No windows found for PID \(processID)"
            )
        }

        for window in filtered {
            // Check title if provided
            if let requiredTitle = title, window.title != requiredTitle {
                continue
            }

            // Check frame if provided
            if let requiredFrame = frame, !window.frameMatches(requiredFrame, tolerance: frameTolerance) {
                continue
            }

            // All criteria matched
            var details = "Matched by PID"
            if title != nil { details += " + exact title" }
            if frame != nil { details += " + frame (\(Int(frameTolerance))px tolerance)" }

            return WindowFinderResult(
                window: WindowHandle(axWindow: window),
                matchMethod: matchMethod,
                inputCriteria: criteria,
                matchDuration: Date().timeIntervalSince(startTime),
                candidatesChecked: filtered.count,
                matchDetails: details
            )
        }

        // Build failure reason
        var reason = "No window matched all criteria for PID \(processID)"
        if title != nil { reason += ", title required" }
        if frame != nil { reason += ", frame required" }
        reason += " (checked \(filtered.count) windows)"

        return .notFound(
            method: matchMethod,
            criteria: criteria,
            duration: Date().timeIntervalSince(startTime),
            candidatesChecked: filtered.count,
            reason: reason
        )
    }

    // MARK: - Single Window Finders

    /// Finds the first window belonging to an application by its display name.
    ///
    /// This method searches for a running application by its localized display name
    /// (as shown in the Dock and menu bar) and returns a handle to its first window.
    /// Only applications with "regular" activation policy are considered (excludes
    /// background agents and accessories).
    ///
    /// - Parameters:
    ///   - appName: The application's display name (e.g., "Safari", "Finder", "Visual Studio Code").
    ///     This is case-sensitive and must match exactly.
    ///   - filter: Options for filtering candidate windows. Defaults to excluding small
    ///     windows and those with empty titles.
    ///
    /// - Returns: A `WindowHandle` for the first window of the application, or `nil` if the
    ///   application is not running or has no windows matching the filter.
    ///
    /// ## Example
    ///
    /// ```swift
    /// // Find Safari's first window and bring it to front
    /// if let safari = Window.find(appName: "Safari") {
    ///     safari.activate()
    /// }
    ///
    /// // Find Finder window and center it
    /// Window.find(appName: "Finder")?.center()
    ///
    /// // Chain multiple operations
    /// Window.find(appName: "Notes")?
    ///     .moveTo(x: 100, y: 100)
    ///     .resize(width: 600, height: 400)
    ///     .raise()
    /// ```
    ///
    /// ## See Also
    /// - ``find(bundleID:filter:)`` for more reliable lookup using bundle identifier
    /// - ``all(for:filter:)`` to get all windows for an app
    /// - ``findWithResult(appName:filter:)`` for debug metadata
    public static func find(appName: String, filter: WindowFilterOptions = .default) -> WindowHandle? {
        guard let service = axService else { return nil }

        // Find app by name
        guard let app = NSWorkspace.shared.runningApplications.first(where: {
            $0.localizedName == appName && $0.activationPolicy == .regular
        }) else {
            return nil
        }

        let windows = service.getWindows(
            forProcessID: app.processIdentifier,
            bundleIdentifier: app.bundleIdentifier
        )

        let filtered = self.filter(windows, with: filter)
        guard let window = filtered.first else { return nil }

        return WindowHandle(axWindow: window)
    }

    /// Finds the first window belonging to an application by name with debug metadata.
    ///
    /// This method is identical to ``find(appName:filter:)`` but returns additional metadata
    /// about the lookup process, useful for debugging and telemetry.
    ///
    /// - Parameters:
    ///   - appName: The application's display name (case-sensitive, exact match).
    ///   - filter: Options for filtering candidate windows.
    ///
    /// - Returns: A `WindowFinderResult` containing either the WindowHandle with match
    ///   metadata, or failure information including the reason the window was not found.
    ///
    /// ## See Also
    /// - ``find(appName:filter:)`` for simple lookups
    public static func findWithResult(appName: String, filter: WindowFilterOptions = .default) -> WindowFinderResult {
        let startTime = Date()
        let criteria = WindowFinderCriteria(appName: appName)

        guard let service = axService else {
            return .notFound(method: .appName, criteria: criteria, duration: Date().timeIntervalSince(startTime), candidatesChecked: 0, reason: "AXWindowService not available")
        }

        guard let app = NSWorkspace.shared.runningApplications.first(where: {
            $0.localizedName == appName && $0.activationPolicy == .regular
        }) else {
            return .notFound(method: .appName, criteria: criteria, duration: Date().timeIntervalSince(startTime), candidatesChecked: 0, reason: "No running app found with name '\(appName)'")
        }

        let windows = service.getWindows(forProcessID: app.processIdentifier, bundleIdentifier: app.bundleIdentifier)
        let filtered = self.filter(windows, with: filter)

        guard let window = filtered.first else {
            return .notFound(method: .appName, criteria: criteria, duration: Date().timeIntervalSince(startTime), candidatesChecked: filtered.count, reason: "App '\(appName)' has no windows matching filter")
        }

        return WindowFinderResult(
            window: WindowHandle(axWindow: window),
            matchMethod: .appName,
            inputCriteria: criteria,
            matchDuration: Date().timeIntervalSince(startTime),
            candidatesChecked: filtered.count,
            matchDetails: "Found first window for app '\(appName)'"
        )
    }

    /// Finds the first window belonging to an application by its bundle identifier.
    ///
    /// This is the most reliable way to find an application's window because bundle
    /// identifiers are stable and unique, unlike display names which can be localized
    /// or changed. Use this method when you need consistent behavior across different
    /// system languages and application versions.
    ///
    /// - Parameters:
    ///   - bundleID: The application's bundle identifier (e.g., "com.apple.Safari",
    ///     "com.google.Chrome"). This is case-sensitive.
    ///   - filter: Options for filtering candidate windows. Defaults to excluding small
    ///     windows and those with empty titles.
    ///
    /// - Returns: A `WindowHandle` for the first window of the application, or `nil` if the
    ///   application is not running or has no windows matching the filter.
    ///
    /// ## Example
    ///
    /// ```swift
    /// // Find Safari's first window using bundle ID
    /// if let safari = Window.find(bundleID: "com.apple.Safari") {
    ///     safari.activate()
    /// }
    ///
    /// // Find Chrome window
    /// Window.find(bundleID: "com.google.Chrome")?.center()
    ///
    /// // Find VS Code window
    /// Window.find(bundleID: "com.microsoft.VSCode")?.maximize()
    /// ```
    ///
    /// ## See Also
    /// - ``find(appName:filter:)`` for lookup by display name
    /// - ``find(anyBundleID:filter:)`` for apps with multiple bundle ID variants
    /// - ``all(forBundleID:filter:)`` to get all windows for an app
    /// - ``findWithResult(bundleID:filter:)`` for debug metadata
    public static func find(bundleID: String, filter: WindowFilterOptions = .default) -> WindowHandle? {
        guard let service = axService else { return nil }

        guard let processID = service.getProcessID(for: bundleID) else {
            return nil
        }

        let windows = service.getWindows(forProcessID: processID, bundleIdentifier: bundleID)
        let filtered = self.filter(windows, with: filter)
        guard let window = filtered.first else { return nil }

        return WindowHandle(axWindow: window)
    }

    /// Finds the first window belonging to an application by bundle ID with debug metadata.
    ///
    /// This method is identical to ``find(bundleID:filter:)`` but returns additional metadata
    /// about the lookup process, useful for debugging and telemetry.
    ///
    /// - Parameters:
    ///   - bundleID: The application's bundle identifier (case-sensitive).
    ///   - filter: Options for filtering candidate windows.
    ///
    /// - Returns: A `WindowFinderResult` containing either the WindowHandle with match
    ///   metadata, or failure information including the reason the window was not found.
    ///
    /// ## See Also
    /// - ``find(bundleID:filter:)`` for simple lookups
    public static func findWithResult(bundleID: String, filter: WindowFilterOptions = .default) -> WindowFinderResult {
        let startTime = Date()
        let criteria = WindowFinderCriteria(bundleId: bundleID)

        guard let service = axService else {
            return .notFound(method: .bundleId, criteria: criteria, duration: Date().timeIntervalSince(startTime), candidatesChecked: 0, reason: "AXWindowService not available")
        }

        guard let processID = service.getProcessID(for: bundleID) else {
            return .notFound(method: .bundleId, criteria: criteria, duration: Date().timeIntervalSince(startTime), candidatesChecked: 0, reason: "No running app found with bundle ID '\(bundleID)'")
        }

        let windows = service.getWindows(forProcessID: processID, bundleIdentifier: bundleID)
        let filtered = self.filter(windows, with: filter)

        guard let window = filtered.first else {
            return .notFound(method: .bundleId, criteria: criteria, duration: Date().timeIntervalSince(startTime), candidatesChecked: filtered.count, reason: "Bundle '\(bundleID)' has no windows matching filter")
        }

        return WindowFinderResult(
            window: WindowHandle(axWindow: window),
            matchMethod: .bundleId,
            inputCriteria: criteria,
            matchDuration: Date().timeIntervalSince(startTime),
            candidatesChecked: filtered.count,
            matchDetails: "Found first window for bundle '\(bundleID)'"
        )
    }

    /// Finds the first window belonging to an application matching any of the given bundle identifiers.
    ///
    /// Some applications (particularly Chromium-based browsers) can have multiple bundle
    /// identifier variants depending on how they were installed or configured. This method
    /// accepts an array of possible bundle IDs and returns the first matching window from
    /// any of them.
    ///
    /// Common use cases include:
    /// - Chrome: "com.google.Chrome", "com.google.Chrome.canary", "com.google.Chrome.beta"
    /// - Arc: "company.thebrowser.Browser", "company.thebrowser.Browser.nightly"
    ///
    /// - Parameters:
    ///   - bundleIDs: An array of possible bundle identifiers to search for. The first
    ///     running application matching any of these IDs will be used.
    ///   - filter: Options for filtering candidate windows. Defaults to excluding small
    ///     windows and those with empty titles.
    ///
    /// - Returns: A `WindowHandle` for the first window of the first matching application,
    ///   or `nil` if no application with any of the bundle IDs is running or has matching windows.
    ///
    /// ## Example
    ///
    /// ```swift
    /// // Find Chrome window (handles stable, beta, canary, etc.)
    /// let chromeIDs = [
    ///     "com.google.Chrome",
    ///     "com.google.Chrome.beta",
    ///     "com.google.Chrome.canary"
    /// ]
    /// if let chrome = Window.find(anyBundleID: chromeIDs) {
    ///     chrome.activate()
    /// }
    ///
    /// // Find Arc browser window
    /// let arcIDs = ["company.thebrowser.Browser", "company.thebrowser.Browser.nightly"]
    /// Window.find(anyBundleID: arcIDs)?.center()
    /// ```
    ///
    /// ## See Also
    /// - ``find(bundleID:filter:)`` for single bundle ID lookup
    /// - ``all(forAnyBundleID:filter:)`` to get all windows for any matching app
    public static func find(anyBundleID bundleIDs: [String], filter: WindowFilterOptions = .default) -> WindowHandle? {
        guard let service = axService else { return nil }
        
        guard let processID = service.getProcessID(forAnyOf: bundleIDs) else {
            return nil
        }
        
        // Get the actual bundle ID from the running app
        let actualBundleID = NSWorkspace.shared.runningApplications
            .first { $0.processIdentifier == processID }?
            .bundleIdentifier
        
        let windows = service.getWindows(forProcessID: processID, bundleIdentifier: actualBundleID)
        let filtered = self.filter(windows, with: filter)
        guard let window = filtered.first else { return nil }
        
        return WindowHandle(axWindow: window)
    }

    /// Finds the first window with an exact title match.
    ///
    /// This method searches across all running applications to find a window with
    /// a title that exactly matches the specified string. The search is case-sensitive.
    ///
    /// Note that window titles can change frequently (e.g., browser tabs, document names),
    /// so this method may not find a window if its title has changed since you last
    /// observed it.
    ///
    /// - Parameter title: The exact window title to match (case-sensitive).
    ///
    /// - Returns: A `WindowHandle` for the first window with the matching title, or `nil`
    ///   if no window has that exact title.
    ///
    /// ## Example
    ///
    /// ```swift
    /// // Find a specific document window
    /// if let doc = Window.find(title: "My Document.pdf - Preview") {
    ///     doc.activate()
    /// }
    ///
    /// // Find a browser tab by its exact title
    /// Window.find(title: "GitHub")?.raise()
    /// ```
    ///
    /// ## See Also
    /// - ``find(titleContaining:filter:)`` for partial title matching
    /// - ``findWithResult(title:)`` for debug metadata
    public static func find(title: String) -> WindowHandle? {
        let allWindows = getAllWindowsFromAX()
        guard let window = allWindows.first(where: { $0.title == title }) else {
            return nil
        }
        return WindowHandle(axWindow: window)
    }

    /// Finds the first window with an exact title match, returning debug metadata.
    ///
    /// This method is identical to ``find(title:)`` but returns additional metadata
    /// about the lookup process, useful for debugging and telemetry.
    ///
    /// - Parameter title: The exact window title to match (case-sensitive).
    ///
    /// - Returns: A `WindowFinderResult` containing either the WindowHandle with match
    ///   metadata, or failure information including the reason the window was not found.
    ///
    /// ## See Also
    /// - ``find(title:)`` for simple lookups
    public static func findWithResult(title: String) -> WindowFinderResult {
        let startTime = Date()
        let criteria = WindowFinderCriteria(title: title)

        let allWindows = getAllWindowsFromAX()
        guard let window = allWindows.first(where: { $0.title == title }) else {
            return .notFound(method: .titleExact, criteria: criteria, duration: Date().timeIntervalSince(startTime), candidatesChecked: allWindows.count, reason: "No window found with exact title '\(title)'")
        }

        return WindowFinderResult(
            window: WindowHandle(axWindow: window),
            matchMethod: .titleExact,
            inputCriteria: criteria,
            matchDuration: Date().timeIntervalSince(startTime),
            candidatesChecked: allWindows.count,
            matchDetails: "Found window with exact title match"
        )
    }

    /// Finds the first window with a title containing the specified substring.
    ///
    /// This method searches across all running applications to find a window whose
    /// title contains the specified substring. The search is case-sensitive.
    ///
    /// This is more flexible than ``find(title:)`` because it matches partial titles,
    /// making it useful when you know part of a window title but not the exact text.
    ///
    /// - Parameters:
    ///   - titleContaining: The substring to search for within window titles.
    ///     The search is case-sensitive.
    ///   - filter: Options for filtering candidate windows. Defaults to excluding small
    ///     windows and those with empty titles.
    ///
    /// - Returns: A `WindowHandle` for the first window whose title contains the substring,
    ///   or `nil` if no window title contains the specified text.
    ///
    /// ## Example
    ///
    /// ```swift
    /// // Find any window with "CLAUDE" in the title
    /// if let claude = Window.find(titleContaining: "CLAUDE") {
    ///     claude.activate()
    /// }
    ///
    /// // Find a document by partial filename
    /// Window.find(titleContaining: "budget_2024")?.raise()
    ///
    /// // Find browser tab containing domain name
    /// Window.find(titleContaining: "github.com")?.activate()
    /// ```
    ///
    /// ## See Also
    /// - ``find(title:)`` for exact title matching
    /// - ``all(titleContaining:filter:)`` to get all windows with matching titles
    /// - ``findWithResult(titleContaining:filter:)`` for debug metadata
    public static func find(titleContaining: String, filter: WindowFilterOptions = .default) -> WindowHandle? {
        let allWindows = getAllWindowsFromAX()
        let filtered = self.filter(allWindows, with: filter)
        guard let window = filtered.first(where: { $0.title.contains(titleContaining) }) else {
            return nil
        }
        return WindowHandle(axWindow: window)
    }

    /// Finds the first window with a title containing the specified substring, returning debug metadata.
    ///
    /// This method is identical to ``find(titleContaining:filter:)`` but returns additional
    /// metadata about the lookup process, useful for debugging and telemetry.
    ///
    /// - Parameters:
    ///   - titleContaining: The substring to search for within window titles.
    ///   - filter: Options for filtering candidate windows.
    ///
    /// - Returns: A `WindowFinderResult` containing either the WindowHandle with match
    ///   metadata, or failure information including the reason the window was not found.
    ///
    /// ## See Also
    /// - ``find(titleContaining:filter:)`` for simple lookups
    public static func findWithResult(titleContaining: String, filter: WindowFilterOptions = .default) -> WindowFinderResult {
        let startTime = Date()
        let criteria = WindowFinderCriteria(title: titleContaining)

        let allWindows = getAllWindowsFromAX()
        let filtered = self.filter(allWindows, with: filter)
        guard let window = filtered.first(where: { $0.title.contains(titleContaining) }) else {
            return .notFound(method: .titleContaining, criteria: criteria, duration: Date().timeIntervalSince(startTime), candidatesChecked: filtered.count, reason: "No window found with title containing '\(titleContaining)'")
        }

        return WindowFinderResult(
            window: WindowHandle(axWindow: window),
            matchMethod: .titleContaining,
            inputCriteria: criteria,
            matchDuration: Date().timeIntervalSince(startTime),
            candidatesChecked: filtered.count,
            matchDetails: "Found window with title containing '\(titleContaining)'"
        )
    }

    /// Finds the first window matching the given frame position and size.
    ///
    /// This method searches across all running applications to find a window whose
    /// frame (position and size) matches the specified frame within the given tolerance.
    /// This is useful for workspace restoration where you need to find a window that
    /// was previously at a specific location.
    ///
    /// The tolerance parameter allows for minor positioning differences that can occur
    /// due to window snapping, screen scaling, or other factors.
    ///
    /// - Parameters:
    ///   - frame: The target frame (position and size) to match against.
    ///   - tolerance: Maximum pixel difference allowed for each component (x, y, width, height)
    ///     when comparing frames. Defaults to 10 pixels.
    ///   - filter: Options for filtering candidate windows. Defaults to excluding small
    ///     windows and those with empty titles.
    ///
    /// - Returns: A `WindowHandle` for the first window whose frame is within the tolerance
    ///   of the target frame, or `nil` if no window matches.
    ///
    /// ## Example
    ///
    /// ```swift
    /// // Find a window at a specific position
    /// let targetFrame = CGRect(x: 100, y: 100, width: 800, height: 600)
    /// if let window = Window.find(matchingFrame: targetFrame) {
    ///     print("Found window: \(window.title)")
    /// }
    ///
    /// // Use larger tolerance for less precise matching
    /// Window.find(matchingFrame: targetFrame, tolerance: 50)?.activate()
    /// ```
    ///
    /// ## See Also
    /// - ``find(processID:title:frame:frameTolerance:filter:)`` for multi-criteria matching
    /// - ``findWithResult(matchingFrame:tolerance:filter:)`` for debug metadata
    public static func find(matchingFrame frame: CGRect, tolerance: CGFloat = 10.0, filter: WindowFilterOptions = .default) -> WindowHandle? {
        let allWindows = getAllWindowsFromAX()
        let filtered = self.filter(allWindows, with: filter)
        guard let window = filtered.first(where: { $0.frameMatches(frame, tolerance: tolerance) }) else {
            return nil
        }
        return WindowHandle(axWindow: window)
    }

    /// Finds the first window matching the given frame, returning debug metadata.
    ///
    /// This method is identical to ``find(matchingFrame:tolerance:filter:)`` but returns
    /// additional metadata about the lookup process, useful for debugging and telemetry.
    ///
    /// - Parameters:
    ///   - frame: The target frame to match against.
    ///   - tolerance: Maximum pixel difference for frame matching (default: 10px).
    ///   - filter: Options for filtering candidate windows.
    ///
    /// - Returns: A `WindowFinderResult` containing either the WindowHandle with match
    ///   metadata, or failure information including the reason the window was not found.
    ///
    /// ## See Also
    /// - ``find(matchingFrame:tolerance:filter:)`` for simple lookups
    public static func findWithResult(matchingFrame frame: CGRect, tolerance: CGFloat = 10.0, filter: WindowFilterOptions = .default) -> WindowFinderResult {
        let startTime = Date()
        let criteria = WindowFinderCriteria(frame: frame, frameTolerance: tolerance)

        let allWindows = getAllWindowsFromAX()
        let filtered = self.filter(allWindows, with: filter)
        guard let window = filtered.first(where: { $0.frameMatches(frame, tolerance: tolerance) }) else {
            return .notFound(method: .frameOnly, criteria: criteria, duration: Date().timeIntervalSince(startTime), candidatesChecked: filtered.count, reason: "No window found matching frame within \(Int(tolerance))px tolerance")
        }

        return WindowFinderResult(
            window: WindowHandle(axWindow: window),
            matchMethod: .frameOnly,
            inputCriteria: criteria,
            matchDuration: Date().timeIntervalSince(startTime),
            candidatesChecked: filtered.count,
            matchDetails: "Found window by frame match (\(Int(tolerance))px tolerance)"
        )
    }

    /// Returns the topmost (frontmost) visible window across all applications.
    ///
    /// This method uses CGWindowList API to determine accurate z-order (front-to-back stacking)
    /// and returns the frontmost visible window. This is the window that would receive keyboard
    /// input if clicked.
    ///
    /// The method filters out system UI elements (menu bar, Dock, etc.) and only considers
    /// windows from applications with "regular" activation policy.
    ///
    /// - Parameter filter: Options for filtering candidate windows. Defaults to `.visibleOnly`
    ///   which excludes minimized and hidden windows.
    ///
    /// - Returns: A `WindowHandle` for the topmost window, or `nil` if no visible windows exist.
    ///
    /// ## Example
    ///
    /// ```swift
    /// // Get the frontmost window and center it
    /// Window.topmost()?.center()
    ///
    /// // Get topmost window including minimized windows
    /// let top = Window.topmost(filter: .default)
    ///
    /// // Chain operations on the topmost window
    /// Window.topmost()?
    ///     .center()
    ///     .raise()
    ///     .activate()
    /// ```
    ///
    /// ## See Also
    /// - ``topmost(in:bundleIdentifiers:filter:)`` for topmost window in a specific region
    /// - ``at(location:)`` for window at a specific point
    public static func topmost(filter: WindowFilterOptions = .visibleOnly) -> WindowHandle? {
        guard let service = axService else { return nil }

        // Use CGWindowList to get accurate z-order (front-to-back)
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let windowList = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }
        
        // Iterate through windows front-to-back to find the first valid one
        for cgWindow in windowList {
            let layer = cgWindow[kCGWindowLayer as String] as? Int ?? 0

            // Layer 0 is normal windows (skip menu bar, dock, etc.)
            guard layer == 0 else { continue }

            guard let ownerPID = cgWindow[kCGWindowOwnerPID as String] as? pid_t else { continue }

            // Skip if this is not a regular app (check activation policy)
            guard let app = NSWorkspace.shared.runningApplications.first(where: {
                $0.processIdentifier == ownerPID && $0.activationPolicy == .regular
            }) else { continue }

            // Get bounds from CGWindowList (always available, unlike window name on macOS 15+)
            guard let boundsDict = cgWindow[kCGWindowBounds as String] as? [String: CGFloat],
                  let cgX = boundsDict["X"],
                  let cgY = boundsDict["Y"],
                  let cgWidth = boundsDict["Width"],
                  let cgHeight = boundsDict["Height"] else {
                continue
            }

            // Apply size filter early using CG bounds
            if cgWidth < filter.minWidth || cgHeight < filter.minHeight {
                continue
            }

            let cgFrame = CGRect(x: cgX, y: cgY, width: cgWidth, height: cgHeight)

            // Get all AX windows for this process
            let axWindows = service.getWindows(
                forProcessID: ownerPID,
                bundleIdentifier: app.bundleIdentifier
            )

            // Primary match: by frame/bounds (reliable on all macOS versions)
            if let matchedWindow = axWindows.first(where: { $0.frameMatches(cgFrame, tolerance: 5) }) {
                if passesFilter(matchedWindow, options: filter) {
                    return WindowHandle(axWindow: matchedWindow)
                }
            }

            // Secondary match: by title if available (kCGWindowName may be nil on macOS 15+)
            if let windowName = cgWindow[kCGWindowName as String] as? String, !windowName.isEmpty {
                if let matchedWindow = axWindows.first(where: { $0.title == windowName }) {
                    if passesFilter(matchedWindow, options: filter) {
                        return WindowHandle(axWindow: matchedWindow)
                    }
                }
            }

            // Last resort: take the first AX window from this app that passes filter
            // This works when there's only one window or frame matching failed
            if let firstWindow = axWindows.first(where: { passesFilter($0, options: filter) }) {
                return WindowHandle(axWindow: firstWindow)
            }
        }
        
        return nil
    }

    /// Returns the topmost visible window that occupies a specific screen region.
    ///
    /// This method finds the frontmost window whose frame contains the center point of
    /// the specified target frame. This is useful for finding which window is "under"
    /// a particular area of the screen.
    ///
    /// The method uses CGWindowList API for accurate z-order determination and can
    /// optionally filter to only consider windows from specific applications.
    ///
    /// - Parameters:
    ///   - frame: The target region to test. The center point of this frame is used
    ///     to determine containment.
    ///   - bundleIdentifiers: Optional set of bundle identifiers to limit the search to.
    ///     If provided, only windows from applications with these bundle IDs are considered.
    ///     If `nil`, all applications are considered.
    ///   - filter: Options for filtering candidate windows. Defaults to `.visibleOnly`.
    ///
    /// - Returns: A `WindowHandle` for the topmost window whose frame contains the target
    ///   region's center point, or `nil` if no window occupies that region.
    ///
    /// ## Example
    ///
    /// ```swift
    /// // Find topmost window at a specific screen region
    /// let region = CGRect(x: 500, y: 300, width: 100, height: 100)
    /// if let window = Window.topmost(in: region) {
    ///     print("Window at region: \(window.title)")
    /// }
    ///
    /// // Find topmost browser window in a region
    /// let browserBundles: Set<String> = [
    ///     "com.apple.Safari",
    ///     "com.google.Chrome",
    ///     "company.thebrowser.Browser"
    /// ]
    /// Window.topmost(in: region, bundleIdentifiers: browserBundles)?.activate()
    /// ```
    ///
    /// ## See Also
    /// - ``topmost(filter:)`` for the overall topmost window
    /// - ``at(location:)`` for window at a specific point
    public static func topmost(
        in frame: CGRect,
        bundleIdentifiers: Set<String>? = nil,
        filter: WindowFilterOptions = .visibleOnly
    ) -> WindowHandle? {
        guard let service = axService else { return nil }

        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let windowList = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }

        let targetPoint = CGPoint(x: frame.midX, y: frame.midY)

        for cgWindow in windowList {
            let layer = cgWindow[kCGWindowLayer as String] as? Int ?? 0
            guard layer == 0 else { continue }
            guard let ownerPID = cgWindow[kCGWindowOwnerPID as String] as? pid_t else { continue }

            guard let app = NSWorkspace.shared.runningApplications.first(where: {
                $0.processIdentifier == ownerPID && $0.activationPolicy == .regular
            }) else { continue }

            if let bundleIdentifiers,
               let bundle = app.bundleIdentifier,
               !bundleIdentifiers.contains(bundle) {
                continue
            }

            guard let boundsDict = cgWindow[kCGWindowBounds as String] as? [String: CGFloat],
                  let cgX = boundsDict["X"],
                  let cgY = boundsDict["Y"],
                  let cgWidth = boundsDict["Width"],
                  let cgHeight = boundsDict["Height"] else {
                continue
            }

            if cgWidth < filter.minWidth || cgHeight < filter.minHeight {
                continue
            }

            let cgFrame = CGRect(x: cgX, y: cgY, width: cgWidth, height: cgHeight)
            guard cgFrame.contains(targetPoint) else { continue }

            let axWindows = service.getWindows(
                forProcessID: ownerPID,
                bundleIdentifier: app.bundleIdentifier
            )

            if let matchedWindow = axWindows.first(where: { $0.frameMatches(cgFrame, tolerance: 5) }) {
                if passesFilter(matchedWindow, options: filter) {
                    return WindowHandle(axWindow: matchedWindow)
                }
            }

            if let windowName = cgWindow[kCGWindowName as String] as? String, !windowName.isEmpty {
                if let matchedWindow = axWindows.first(where: { $0.title == windowName }) {
                    if passesFilter(matchedWindow, options: filter) {
                        return WindowHandle(axWindow: matchedWindow)
                    }
                }
            }

            if let firstWindow = axWindows.first(where: { passesFilter($0, options: filter) }) {
                return WindowHandle(axWindow: firstWindow)
            }
        }

        return nil
    }

    /// Returns the first visible window containing the specified screen point.
    ///
    /// This method searches all windows to find one whose frame contains the specified
    /// screen coordinates. Note that without z-order information from CGWindowList,
    /// this returns the first matching window encountered, which may not be the topmost.
    ///
    /// For accurate z-order aware lookup, use ``topmost(in:bundleIdentifiers:filter:)``
    /// with a small frame centered on your target point.
    ///
    /// - Parameter location: The screen coordinates (in global screen space) to test.
    ///
    /// - Returns: A `WindowHandle` for a visible window containing the point, or `nil`
    ///   if no visible window contains the specified location.
    ///
    /// ## Example
    ///
    /// ```swift
    /// // Find window at a specific screen point
    /// let point = CGPoint(x: 500, y: 300)
    /// if let window = Window.at(location: point) {
    ///     print("Window at point: \(window.title)")
    /// }
    ///
    /// // Get window under the cursor position
    /// let cursorLocation = NSEvent.mouseLocation
    /// Window.at(location: cursorLocation)?.raise()
    /// ```
    ///
    /// ## See Also
    /// - ``topmost(in:bundleIdentifiers:filter:)`` for z-order aware lookup
    /// - ``topmost(filter:)`` for the overall topmost window
    public static func at(location: CGPoint) -> WindowHandle? {
        let allWindows = getAllWindowsFromAX()
        
        // Find windows containing the point
        // Note: Without z-order info, we just return the first match
        for window in allWindows {
            if window.frame.contains(location) && !window.isMinimized && !window.isHidden {
                return WindowHandle(axWindow: window)
            }
        }
        
        return nil
    }
    
    // MARK: - Multiple Window Finders

    /// Returns all windows from all running applications.
    ///
    /// This method queries windows from all running applications with "regular" activation
    /// policy and returns them as an array of WindowHandle objects that can be manipulated.
    ///
    /// The results can be filtered using ``WindowFilterOptions`` to exclude small helper
    /// windows, hidden windows, or windows with empty titles.
    ///
    /// - Parameter filter: Options for filtering the returned windows. Defaults to excluding
    ///   small windows (<=64px) and those with empty titles.
    ///
    /// - Returns: An array of `WindowHandle` objects representing all windows matching
    ///   the filter criteria. Returns an empty array if no windows are found.
    ///
    /// ## Example
    ///
    /// ```swift
    /// // Get all windows with default filtering
    /// let allWindows = Window.all()
    /// print("Total windows: \(allWindows.count)")
    ///
    /// // Include all windows, even small helper windows
    /// let everything = Window.all(filter: .all)
    ///
    /// // Get only visible windows
    /// let visible = Window.all(filter: .visibleOnly)
    ///
    /// // Process each window
    /// for window in Window.all() {
    ///     print("\(window.appName ?? "Unknown"): \(window.title)")
    /// }
    ///
    /// // Minimize all windows
    /// Window.all().forEach { $0.minimize() }
    /// ```
    ///
    /// ## See Also
    /// - ``all(for:filter:)`` to get windows for a specific app
    /// - ``visible(filter:)`` for only visible windows
    /// - ``count`` for just the window count
    public static func all(filter: WindowFilterOptions = .default) -> [WindowHandle] {
        let allWindows = getAllWindowsFromAX()
        let filtered = self.filter(allWindows, with: filter)
        return filtered.map { WindowHandle(axWindow: $0) }
    }

    /// Returns all windows belonging to an application by its display name.
    ///
    /// This method searches for a running application by its localized display name
    /// and returns all of its windows as an array of WindowHandle objects.
    ///
    /// - Parameters:
    ///   - appName: The application's display name (e.g., "Safari", "Finder").
    ///     This is case-sensitive and must match exactly.
    ///   - filter: Options for filtering the returned windows. Defaults to excluding
    ///     small windows and those with empty titles.
    ///
    /// - Returns: An array of `WindowHandle` objects for all windows belonging to the
    ///   application. Returns an empty array if the app is not running or has no
    ///   matching windows.
    ///
    /// ## Example
    ///
    /// ```swift
    /// // Get all Safari windows
    /// let safariWindows = Window.all(for: "Safari")
    /// print("Safari has \(safariWindows.count) windows")
    ///
    /// // Minimize all Chrome windows
    /// Window.all(for: "Google Chrome").forEach { $0.minimize() }
    ///
    /// // Get all visible Finder windows
    /// let finderWindows = Window.all(for: "Finder", filter: .visibleOnly)
    /// ```
    ///
    /// ## See Also
    /// - ``all(forBundleID:filter:)`` for more reliable lookup by bundle ID
    /// - ``find(appName:filter:)`` to get just the first window
    public static func all(for appName: String, filter: WindowFilterOptions = .default) -> [WindowHandle] {
        guard let service = axService else { return [] }
        
        // Find app by name
        guard let app = NSWorkspace.shared.runningApplications.first(where: {
            $0.localizedName == appName && $0.activationPolicy == .regular
        }) else {
            return []
        }
        
        let windows = service.getWindows(
            forProcessID: app.processIdentifier,
            bundleIdentifier: app.bundleIdentifier
        )
        
        let filtered = self.filter(windows, with: filter)
        return filtered.map { WindowHandle(axWindow: $0) }
    }

    /// Returns all windows belonging to a specific process by its process ID.
    ///
    /// This method is useful for applications that can spawn multiple processes (e.g., Ghostty,
    /// Electron apps) or when you need deterministic process-based window association rather
    /// than bundle ID-based lookup.
    ///
    /// - Parameters:
    ///   - processID: The process identifier (PID) that owns the windows.
    ///   - bundleID: Optional bundle identifier for the process. Used for window metadata
    ///     enrichment but not required for the lookup.
    ///   - filter: Options for filtering the returned windows. Defaults to excluding
    ///     small windows and those with empty titles.
    ///
    /// - Returns: An array of `WindowHandle` objects for all windows belonging to the
    ///   process. Returns an empty array if the process has no matching windows.
    ///
    /// ## Example
    ///
    /// ```swift
    /// // Get all windows for a specific process
    /// let windows = Window.all(forProcessID: 1234)
    ///
    /// // Get windows with bundle ID for metadata
    /// let ghosttyWindows = Window.all(
    ///     forProcessID: pid,
    ///     bundleID: "com.mitchellh.ghostty"
    /// )
    ///
    /// // Get only visible windows for a process
    /// let visible = Window.all(forProcessID: 1234, filter: .visibleOnly)
    /// ```
    ///
    /// ## See Also
    /// - ``all(forBundleID:filter:)`` for bundle ID-based lookup
    /// - ``allAcrossProcesses(forBundleID:filter:)`` for multi-process apps
    public static func all(
        forProcessID processID: pid_t,
        bundleID: String? = nil,
        filter: WindowFilterOptions = .default
    ) -> [WindowHandle] {
        guard let service = axService else { return [] }

        let windows = service.getWindows(forProcessID: processID, bundleIdentifier: bundleID)
        let filtered = self.filter(windows, with: filter)
        return filtered.map { WindowHandle(axWindow: $0) }
    }

    /// Returns all windows belonging to an application by its bundle identifier.
    ///
    /// This is the most reliable way to get an application's windows because bundle
    /// identifiers are stable and unique. Unlike ``all(for:filter:)``, this method
    /// uses the bundle identifier which is consistent across different system languages
    /// and application versions.
    ///
    /// Note: This method returns windows from a single process. For applications that
    /// can run multiple instances (multiple PIDs), use ``allAcrossProcesses(forBundleID:filter:)``.
    ///
    /// - Parameters:
    ///   - bundleID: The application's bundle identifier (e.g., "com.apple.Safari").
    ///     This is case-sensitive.
    ///   - filter: Options for filtering the returned windows. Defaults to excluding
    ///     small windows and those with empty titles.
    ///
    /// - Returns: An array of `WindowHandle` objects for all windows belonging to the
    ///   application. Returns an empty array if the app is not running or has no
    ///   matching windows.
    ///
    /// ## Example
    ///
    /// ```swift
    /// // Get all Safari windows
    /// let safariWindows = Window.all(forBundleID: "com.apple.Safari")
    ///
    /// // Get all visible Chrome windows
    /// let chromeWindows = Window.all(
    ///     forBundleID: "com.google.Chrome",
    ///     filter: .visibleOnly
    /// )
    ///
    /// // Count VS Code windows
    /// let vsCodeCount = Window.all(forBundleID: "com.microsoft.VSCode").count
    /// ```
    ///
    /// ## See Also
    /// - ``allAcrossProcesses(forBundleID:filter:)`` for multi-process apps
    /// - ``all(for:filter:)`` for lookup by display name
    /// - ``find(bundleID:filter:)`` to get just the first window
    public static func all(forBundleID bundleID: String, filter: WindowFilterOptions = .default) -> [WindowHandle] {
        guard let service = axService else { return [] }
        
        guard let processID = service.getProcessID(for: bundleID) else {
            return []
        }
        
        let windows = service.getWindows(forProcessID: processID, bundleIdentifier: bundleID)
        let filtered = self.filter(windows, with: filter)
        return filtered.map { WindowHandle(axWindow: $0) }
    }

    /// Returns all windows for an application across all of its running processes.
    ///
    /// Some applications (e.g., Ghostty, Electron apps) can run multiple independent
    /// processes that each have their own windows. This method collects windows from
    /// all processes matching the bundle identifier, unlike ``all(forBundleID:filter:)``
    /// which only queries a single process.
    ///
    /// This method has special handling for Ghostty which can be particularly difficult
    /// to enumerate reliably through standard APIs.
    ///
    /// - Parameters:
    ///   - bundleID: The application's bundle identifier. All running processes with
    ///     this bundle ID will be queried for windows.
    ///   - filter: Options for filtering the returned windows. Defaults to excluding
    ///     small windows and those with empty titles.
    ///
    /// - Returns: An array of `WindowHandle` objects for all windows across all processes
    ///   matching the bundle identifier. Returns an empty array if no matching processes
    ///   are running or have matching windows.
    ///
    /// ## Example
    ///
    /// ```swift
    /// // Get all Ghostty windows across all instances
    /// let ghosttyWindows = Window.allAcrossProcesses(forBundleID: "com.mitchellh.ghostty")
    /// print("Found \(ghosttyWindows.count) Ghostty windows")
    ///
    /// // Get all Terminal windows across processes
    /// let terminalWindows = Window.allAcrossProcesses(
    ///     forBundleID: "com.apple.Terminal",
    ///     filter: .visibleOnly
    /// )
    /// ```
    ///
    /// ## See Also
    /// - ``all(forBundleID:filter:)`` for single-process apps
    /// - ``all(forProcessID:bundleID:filter:)`` for specific process lookup
    public static func allAcrossProcesses(forBundleID bundleID: String, filter: WindowFilterOptions = .default) -> [WindowHandle] {
        guard let service = axService else { return [] }

        // Special handling for Ghostty: use ps to find all processes (more reliable than pgrep/NSWorkspace)
        if bundleID == "com.mitchellh.ghostty" {
            let pids = getGhosttyPIDs()
            var axWindows: [AXWindow] = []
            for pid in pids {
                axWindows.append(contentsOf: service.getWindows(forProcessID: pid, bundleIdentifier: bundleID))
            }

            // Supplement with CGWindowList to detect windows on other Spaces
            let cgWindows = getGhosttyWindowsViaCGWindowList()
            let axPIDsWithWindows = Set(axWindows.map { $0.processID })

            // Find PIDs that CGWindowList found but AX didn't (windows on other Spaces)
            let cgPIDsWithWindows = Set(cgWindows.map { $0.pid })
            let missingPIDs = cgPIDsWithWindows.subtracting(axPIDsWithWindows)

            if !missingPIDs.isEmpty, WorkspaceManager.currentRestoreRunId != nil {
                DeskJigLog.debug(.restorationSnapshot, "Found Ghostty processes with windows on other Spaces", fields: [
                    "count": missingPIDs.count,
                    "pids": missingPIDs.sorted().map { "\($0)" }.joined(separator: ",")
                ])
            }

            let filtered = self.filter(axWindows, with: filter)
            return filtered.map { WindowHandle(axWindow: $0) }
        }

        let runningApps = NSWorkspace.shared.runningApplications.filter {
            $0.bundleIdentifier == bundleID && $0.activationPolicy == .regular
        }

        var windows: [AXWindow] = []
        windows.reserveCapacity(runningApps.count * 2)

        for app in runningApps {
            windows.append(contentsOf: service.getWindows(forProcessID: app.processIdentifier, bundleIdentifier: bundleID))
        }

        let filtered = self.filter(windows, with: filter)
        return filtered.map { WindowHandle(axWindow: $0) }
    }

    /// Returns all windows for an application matching any of the given bundle identifiers.
    ///
    /// Some applications (particularly Chromium-based browsers) can have multiple bundle
    /// identifier variants. This method accepts an array of possible bundle IDs and returns
    /// all windows from the first matching running application.
    ///
    /// - Parameters:
    ///   - bundleIDs: An array of possible bundle identifiers to search for.
    ///   - filter: Options for filtering the returned windows. Defaults to excluding
    ///     small windows and those with empty titles.
    ///
    /// - Returns: An array of `WindowHandle` objects for all windows belonging to the
    ///   first matching application. Returns an empty array if no application with any
    ///   of the bundle IDs is running or has matching windows.
    ///
    /// ## Example
    ///
    /// ```swift
    /// // Get all Chrome windows (handles stable, beta, canary variants)
    /// let chromeIDs = [
    ///     "com.google.Chrome",
    ///     "com.google.Chrome.beta",
    ///     "com.google.Chrome.canary"
    /// ]
    /// let chromeWindows = Window.all(forAnyBundleID: chromeIDs)
    ///
    /// // Close all Chrome windows
    /// Window.all(forAnyBundleID: chromeIDs).forEach { $0.close() }
    /// ```
    ///
    /// ## See Also
    /// - ``find(anyBundleID:filter:)`` to get just the first window
    /// - ``all(forBundleID:filter:)`` for single bundle ID lookup
    public static func all(forAnyBundleID bundleIDs: [String], filter: WindowFilterOptions = .default) -> [WindowHandle] {
        guard let service = axService else { return [] }
        
        guard let processID = service.getProcessID(forAnyOf: bundleIDs) else {
            return []
        }
        
        let actualBundleID = NSWorkspace.shared.runningApplications
            .first { $0.processIdentifier == processID }?
            .bundleIdentifier
        
        let windows = service.getWindows(forProcessID: processID, bundleIdentifier: actualBundleID)
        let filtered = self.filter(windows, with: filter)
        return filtered.map { WindowHandle(axWindow: $0) }
    }

    /// Returns all windows with titles containing the specified substring.
    ///
    /// This method searches across all running applications to find windows whose
    /// titles contain the specified substring. The search is case-sensitive.
    ///
    /// - Parameters:
    ///   - titleContaining: The substring to search for within window titles.
    ///     The search is case-sensitive.
    ///   - filter: Options for filtering candidate windows. Defaults to excluding
    ///     small windows and those with empty titles.
    ///
    /// - Returns: An array of `WindowHandle` objects for all windows whose titles
    ///   contain the substring. Returns an empty array if no matches are found.
    ///
    /// ## Example
    ///
    /// ```swift
    /// // Find all windows with "CLAUDE" in the title
    /// let claudeWindows = Window.all(titleContaining: "CLAUDE")
    ///
    /// // Find all document windows
    /// let docWindows = Window.all(titleContaining: ".pdf")
    ///
    /// // Close all windows with "Untitled" in the title
    /// Window.all(titleContaining: "Untitled").forEach { $0.close() }
    /// ```
    ///
    /// ## See Also
    /// - ``find(titleContaining:filter:)`` to get just the first match
    /// - ``find(title:)`` for exact title matching
    public static func all(titleContaining: String, filter: WindowFilterOptions = .default) -> [WindowHandle] {
        let allWindows = getAllWindowsFromAX()
        let matchingWindows = allWindows.filter { $0.title.contains(titleContaining) }
        let filtered = self.filter(matchingWindows, with: filter)
        return filtered.map { WindowHandle(axWindow: $0) }
    }

    /// Returns all visible windows (excluding hidden and minimized windows).
    ///
    /// This is a convenience method that returns windows currently visible on screen.
    /// By default, it uses `.visibleOnly` filter which excludes minimized windows,
    /// hidden windows, small helper windows, and windows with empty titles.
    ///
    /// - Parameter filter: Options for filtering the returned windows. Defaults to
    ///   `.visibleOnly` which excludes minimized, hidden, small, and empty-titled windows.
    ///
    /// - Returns: An array of `WindowHandle` objects for all visible windows.
    ///   Returns an empty array if no visible windows exist.
    ///
    /// ## Example
    ///
    /// ```swift
    /// // Get all visible windows
    /// let visibleWindows = Window.visible()
    /// print("Visible windows: \(visibleWindows.count)")
    ///
    /// // List all visible windows with their apps
    /// for window in Window.visible() {
    ///     print("\(window.appName ?? "Unknown"): \(window.title)")
    /// }
    ///
    /// // Tile all visible windows
    /// let visible = Window.visible()
    /// // ... tiling logic
    /// ```
    ///
    /// ## See Also
    /// - ``all(filter:)`` to include all windows regardless of visibility
    /// - ``minimized()`` to get only minimized windows
    /// - ``hidden()`` to get only hidden windows
    public static func visible(filter: WindowFilterOptions = .visibleOnly) -> [WindowHandle] {
        let allWindows = getAllWindowsFromAX()
        let filtered = self.filter(allWindows, with: filter)
        return filtered.map { WindowHandle(axWindow: $0) }
    }

    /// Returns all minimized windows across all applications.
    ///
    /// This method returns windows that are currently minimized to the Dock.
    /// Minimized windows can still be manipulated (e.g., unminimized) using
    /// the returned WindowHandle objects.
    ///
    /// - Returns: An array of `WindowHandle` objects for all minimized windows.
    ///   Returns an empty array if no windows are minimized.
    ///
    /// ## Example
    ///
    /// ```swift
    /// // Get all minimized windows
    /// let minimizedWindows = Window.minimized()
    /// print("Minimized windows: \(minimizedWindows.count)")
    ///
    /// // Restore all minimized windows
    /// Window.minimized().forEach { $0.unminimize() }
    ///
    /// // List minimized windows by app
    /// for window in Window.minimized() {
    ///     print("\(window.appName ?? "Unknown"): \(window.title)")
    /// }
    /// ```
    ///
    /// ## See Also
    /// - ``visible(filter:)`` to get only visible windows
    /// - ``hidden()`` to get hidden windows
    /// - ``all(filter:)`` to get all windows
    public static func minimized() -> [WindowHandle] {
        let allWindows = getAllWindowsFromAX()
        let minimizedWindows = allWindows.filter { $0.isMinimized }
        return minimizedWindows.map { WindowHandle(axWindow: $0) }
    }

    /// Returns all hidden windows across all applications.
    ///
    /// This method returns windows belonging to applications that are currently hidden
    /// (via Cmd+H or the "Hide" menu command). These windows are not minimized to the
    /// Dock but are invisible until the application is unhidden.
    ///
    /// - Returns: An array of `WindowHandle` objects for all hidden windows.
    ///   Returns an empty array if no windows are hidden.
    ///
    /// ## Example
    ///
    /// ```swift
    /// // Get all hidden windows
    /// let hiddenWindows = Window.hidden()
    /// print("Hidden windows: \(hiddenWindows.count)")
    ///
    /// // List hidden windows by app
    /// for window in Window.hidden() {
    ///     print("\(window.appName ?? "Unknown"): \(window.title)")
    /// }
    /// ```
    ///
    /// ## See Also
    /// - ``visible(filter:)`` to get only visible windows
    /// - ``minimized()`` to get minimized windows
    /// - ``all(filter:)`` to get all windows
    public static func hidden() -> [WindowHandle] {
        let allWindows = getAllWindowsFromAX()
        let hiddenWindows = allWindows.filter { $0.isHidden }
        return hiddenWindows.map { WindowHandle(axWindow: $0) }
    }

    // MARK: - Utility Methods

    /// Triggers a refresh of window data and calls the completion handler when done.
    ///
    /// Since the Fluent Window API is backed by AXWindowService which always queries
    /// live data from the Accessibility API, this method is effectively a no-op. The
    /// AXWindowService does not cache window data, so every query returns fresh results.
    ///
    /// This method is provided for API compatibility with systems that may have cached
    /// window data.
    ///
    /// - Parameter completion: An optional closure called when the refresh is complete.
    ///   Since no actual refresh is needed, this is called immediately.
    ///
    /// ## Example
    ///
    /// ```swift
    /// // Refresh and then query windows
    /// Window.refresh {
    ///     let windows = Window.all()
    ///     print("Found \(windows.count) windows")
    /// }
    ///
    /// // Synchronous usage (completion is optional)
    /// Window.refresh()
    /// let windows = Window.all()
    /// ```
    ///
    /// ## See Also
    /// - ``count`` for the current window count
    /// - ``all(filter:)`` for getting all windows
    public static func refresh(completion: (() -> Void)? = nil) {
        // AXWindowService always returns fresh data, no caching to refresh
        completion?()
    }

    /// The total count of windows from all running applications.
    ///
    /// This property returns the number of windows from all applications with "regular"
    /// activation policy. Unlike ``count(filter:)``, this returns the raw count without
    /// any filtering applied.
    ///
    /// Note that this includes all windows, even small helper windows and those with
    /// empty titles that would typically be filtered out.
    ///
    /// ## Example
    ///
    /// ```swift
    /// // Get total window count
    /// print("Total windows: \(Window.count)")
    ///
    /// // Compare with filtered count
    /// print("Total: \(Window.count)")
    /// print("Filtered: \(Window.count(filter: .default))")
    /// print("Visible only: \(Window.count(filter: .visibleOnly))")
    /// ```
    ///
    /// ## See Also
    /// - ``count(filter:)`` for filtered window count
    /// - ``all(filter:)`` to get the actual windows
    public static var count: Int {
        return getAllWindowsFromAX().count
    }

    /// Returns the count of windows matching the specified filter options.
    ///
    /// This method is more efficient than calling `Window.all(filter:).count` when you
    /// only need the count and don't need the actual WindowHandle objects.
    ///
    /// - Parameter filter: Options for filtering which windows to count.
    ///
    /// - Returns: The number of windows matching the filter criteria.
    ///
    /// ## Example
    ///
    /// ```swift
    /// // Count visible windows only
    /// let visibleCount = Window.count(filter: .visibleOnly)
    ///
    /// // Count all windows including helpers
    /// let totalCount = Window.count(filter: .all)
    ///
    /// // Count with custom filter
    /// let largeWindowCount = Window.count(filter: WindowFilterOptions(
    ///     minWidth: 400,
    ///     minHeight: 300
    /// ))
    /// ```
    ///
    /// ## See Also
    /// - ``count`` for unfiltered window count
    /// - ``all(filter:)`` to get the actual windows
    public static func count(filter: WindowFilterOptions) -> Int {
        let allWindows = getAllWindowsFromAX()
        return self.filter(allWindows, with: filter).count
    }
}
