//  ChromeNativeMessagingAPI.swift
//  DeskJigShared

import Foundation

// MARK: - Chrome Native Messaging Fluent API

/// Fluent API for Chrome native messaging operations
/// Provides real-time access to Chrome tab and window state
public struct ChromeNativeMessagingAPI: Sendable {
    private let service: ChromeNativeMessagingServiceProtocol

    public init(service: ChromeNativeMessagingServiceProtocol) {
        self.service = service
    }

    // MARK: - Connection Status

    /// Whether the native messaging connection is active
    public var isConnected: Bool {
        service.isConnected
    }

    /// Current connection status
    public var status: ChromeNativeMessagingStatus {
        service.status
    }

    // MARK: - Tab Queries

    /// Get all open tabs across all Chrome windows
    /// - Parameter forceRefresh: If true, bypass cache and fetch fresh data from Chrome (default: false)
    /// - Returns: Array of real-time tab information
    /// - Throws: ChromeNativeMessagingError if not connected or request fails
    public func allTabs(forceRefresh: Bool = false) async throws -> [ChromeRealTimeTab] {
        try await service.getAllTabs(forceRefresh: forceRefresh)
    }

    /// Get tabs for a specific Chrome window
    /// - Parameter windowId: The Chrome window ID
    /// - Returns: Array of tabs in that window
    /// - Throws: ChromeNativeMessagingError if not connected or request fails
    public func tabs(forWindowId windowId: Int) async throws -> [ChromeRealTimeTab] {
        try await service.getTabsForWindow(windowId: windowId)
    }

    /// Get the active tab for a specific Chrome window
    /// - Parameter windowId: The Chrome window ID
    /// - Returns: The active tab, or nil if not found
    /// - Throws: ChromeNativeMessagingError if not connected or request fails
    public func activeTab(forWindowId windowId: Int) async throws -> ChromeRealTimeTab? {
        try await service.getActiveTab(windowId: windowId)
    }

    /// Get all active tabs across all windows (one per window)
    /// - Returns: Array of active tabs, one per window
    /// - Throws: ChromeNativeMessagingError if not connected or request fails
    public func allActiveTabs() async throws -> [ChromeRealTimeTab] {
        let windows = try await service.getAllWindows(forceRefresh: false)
        return windows.compactMap { window in
            window.tabs.first { $0.active }
        }
    }

    // MARK: - Window Queries

    /// Get all Chrome windows with their tabs
    /// - Parameter forceRefresh: If true, bypass cache and fetch fresh data from Chrome (default: false)
    /// - Returns: Array of real-time window information
    /// - Throws: ChromeNativeMessagingError if not connected or request fails
    public func allWindows(forceRefresh: Bool = false) async throws -> [ChromeRealTimeWindow] {
        try await service.getAllWindows(forceRefresh: forceRefresh)
    }

    /// Get a specific Chrome window by ID
    /// - Parameter windowId: The Chrome window ID
    /// - Returns: The window, or nil if not found
    /// - Throws: ChromeNativeMessagingError if not connected or request fails
    public func window(id windowId: Int) async throws -> ChromeRealTimeWindow? {
        let windows = try await service.getAllWindows(forceRefresh: false)
        return windows.first { $0.id == windowId }
    }

    /// Get the focused Chrome window
    /// - Returns: The focused window, or nil if none focused
    /// - Throws: ChromeNativeMessagingError if not connected or request fails
    public func focusedWindow() async throws -> ChromeRealTimeWindow? {
        let windows = try await service.getAllWindows(forceRefresh: false)
        return windows.first { $0.focused }
    }

    // MARK: - Tab Search

    /// Find tabs matching a URL pattern
    /// - Parameter urlPattern: URL or URL pattern to search for (case-insensitive)
    /// - Returns: Array of matching tabs
    /// - Throws: ChromeNativeMessagingError if not connected or request fails
    public func findTabs(matchingURL urlPattern: String) async throws -> [ChromeRealTimeTab] {
        let allTabs = try await service.getAllTabs(forceRefresh: false)
        let lowercasePattern = urlPattern.lowercased()
        return allTabs.filter { $0.url.lowercased().contains(lowercasePattern) }
    }

    /// Find tabs matching a title pattern
    /// - Parameter titlePattern: Title pattern to search for (case-insensitive)
    /// - Returns: Array of matching tabs
    /// - Throws: ChromeNativeMessagingError if not connected or request fails
    public func findTabs(matchingTitle titlePattern: String) async throws -> [ChromeRealTimeTab] {
        let allTabs = try await service.getAllTabs(forceRefresh: false)
        let lowercasePattern = titlePattern.lowercased()
        return allTabs.filter { $0.title.lowercased().contains(lowercasePattern) }
    }

    /// Find tabs by domain
    /// - Parameter domain: The domain to search for (e.g., "github.com")
    /// - Returns: Array of tabs from that domain
    /// - Throws: ChromeNativeMessagingError if not connected or request fails
    public func findTabs(forDomain domain: String) async throws -> [ChromeRealTimeTab] {
        let allTabs = try await service.getAllTabs(forceRefresh: false)
        let lowercaseDomain = domain.lowercased()
        return allTabs.filter { tab in
            guard let host = URL(string: tab.url)?.host?.lowercased() else { return false }
            return host == lowercaseDomain || host.hasSuffix(".\(lowercaseDomain)")
        }
    }

    // MARK: - Event Streams

    /// Stream of tab events from Chrome
    public var tabEvents: AsyncStream<ChromeTabEvent> {
        service.tabEvents
    }

    /// Stream of window events from Chrome
    public var windowEvents: AsyncStream<ChromeWindowEvent> {
        service.windowEvents
    }

    /// Stream of navigation events from Chrome
    public var navigationEvents: AsyncStream<ChromeNavigationEvent> {
        service.navigationEvents
    }

    // MARK: - Statistics

    /// Get tab count across all windows
    /// - Returns: Total number of open tabs
    /// - Throws: ChromeNativeMessagingError if not connected or request fails
    public func tabCount() async throws -> Int {
        let tabs = try await service.getAllTabs(forceRefresh: false)
        return tabs.count
    }

    /// Get window count
    /// - Returns: Total number of open windows
    /// - Throws: ChromeNativeMessagingError if not connected or request fails
    public func windowCount() async throws -> Int {
        let windows = try await service.getAllWindows(forceRefresh: false)
        return windows.count
    }

    /// Get a summary of Chrome state
    /// - Returns: A human-readable summary
    /// - Throws: ChromeNativeMessagingError if not connected or request fails
    public func summary() async throws -> String {
        let windows = try await service.getAllWindows(forceRefresh: false)
        let totalTabs = windows.reduce(0) { $0 + $1.tabs.count }

        var lines: [String] = []
        lines.append("Chrome Native Messaging Summary")
        lines.append("  Connected: \(isConnected)")
        lines.append("  Windows: \(windows.count)")
        lines.append("  Total Tabs: \(totalTabs)")

        for window in windows {
            let focusedMark = window.focused ? " [focused]" : ""
            lines.append("  Window \(window.id)\(focusedMark): \(window.tabs.count) tabs")
            if let activeTab = window.tabs.first(where: { $0.active }) {
                let truncatedTitle = activeTab.title.prefix(40)
                lines.append("    Active: \(truncatedTitle)")
            }
        }

        return lines.joined(separator: "\n")
    }

    // MARK: - Tab Commands

    /// Create a new tab in Chrome
    /// - Parameters:
    ///   - url: The URL to open
    ///   - windowId: Optional window ID (uses current window if nil)
    ///   - pinned: Whether the tab should be pinned
    ///   - active: Whether the tab should be active
    /// - Returns: The created tab
    /// - Throws: ChromeNativeMessagingError if not connected or command fails
    @discardableResult
    public func createTab(
        url: String,
        windowId: Int? = nil,
        pinned: Bool = false,
        active: Bool = true
    ) async throws -> ChromeRealTimeTab {
        var payload: [String: Any] = [
            "url": url,
            "pinned": pinned,
            "active": active
        ]
        if let windowId = windowId {
            payload["windowId"] = windowId
        }

        let payloadData = try JSONSerialization.data(withJSONObject: payload)
        let response = try await service.sendCommand(type: "createTab", payload: payloadData)
        return try JSONDecoder().decode(ChromeRealTimeTab.self, from: response)
    }

    /// Open a URL in a new tab (convenience method)
    /// - Parameters:
    ///   - url: The URL to open
    ///   - windowId: Optional window ID (uses current window if nil)
    /// - Returns: The created tab
    /// - Throws: ChromeNativeMessagingError if not connected or command fails
    @discardableResult
    public func openURL(_ url: String, in windowId: Int? = nil) async throws -> ChromeRealTimeTab {
        try await createTab(url: url, windowId: windowId)
    }

    /// Update a tab's URL
    /// - Parameters:
    ///   - tabId: The tab ID to update
    ///   - url: The new URL
    /// - Throws: ChromeNativeMessagingError if not connected or command fails
    public func updateTab(id tabId: Int, url: String) async throws {
        let payload: [String: Any] = ["tabId": tabId, "url": url]
        let payloadData = try JSONSerialization.data(withJSONObject: payload)
        _ = try await service.sendCommand(type: "updateTab", payload: payloadData)
    }

    /// Close a tab
    /// - Parameter tabId: The tab ID to close
    /// - Throws: ChromeNativeMessagingError if not connected or command fails
    public func closeTab(id tabId: Int) async throws {
        let payload: [String: Any] = ["tabId": tabId]
        let payloadData = try JSONSerialization.data(withJSONObject: payload)
        _ = try await service.sendCommand(type: "closeTab", payload: payloadData)
    }

    /// Close multiple tabs at once
    /// - Parameter tabIds: Array of tab IDs to close
    /// - Throws: ChromeNativeMessagingError if not connected or command fails
    public func closeTabs(ids tabIds: [Int]) async throws {
        let payload: [String: Any] = ["tabIds": tabIds]
        let payloadData = try JSONSerialization.data(withJSONObject: payload)
        _ = try await service.sendCommand(type: "closeTabs", payload: payloadData)
    }

    /// Activate a tab (make it the active tab in its window)
    /// - Parameter tabId: The tab ID to activate
    /// - Throws: ChromeNativeMessagingError if not connected or command fails
    public func activateTab(id tabId: Int) async throws {
        let payload: [String: Any] = ["tabId": tabId]
        let payloadData = try JSONSerialization.data(withJSONObject: payload)
        _ = try await service.sendCommand(type: "activateTab", payload: payloadData)
    }

    /// Pin or unpin a tab
    /// - Parameters:
    ///   - tabId: The tab ID to update
    ///   - pinned: Whether the tab should be pinned
    /// - Throws: ChromeNativeMessagingError if not connected or command fails
    public func setTabPinned(id tabId: Int, pinned: Bool) async throws {
        let payload: [String: Any] = ["tabId": tabId, "pinned": pinned]
        let payloadData = try JSONSerialization.data(withJSONObject: payload)
        _ = try await service.sendCommand(type: "updateTabProperties", payload: payloadData)
    }

    /// Mute or unmute a tab
    /// - Parameters:
    ///   - tabId: The tab ID to update
    ///   - muted: Whether the tab should be muted
    /// - Throws: ChromeNativeMessagingError if not connected or command fails
    public func setTabMuted(id tabId: Int, muted: Bool) async throws {
        let payload: [String: Any] = ["tabId": tabId, "muted": muted]
        let payloadData = try JSONSerialization.data(withJSONObject: payload)
        _ = try await service.sendCommand(type: "updateTabProperties", payload: payloadData)
    }

    /// Move tabs to a different window
    /// - Parameters:
    ///   - tabIds: The tab IDs to move
    ///   - windowId: Target window ID
    ///   - index: Position in target window (-1 for end)
    /// - Throws: ChromeNativeMessagingError if not connected or command fails
    public func moveTabs(tabIds: [Int], toWindow windowId: Int, atIndex index: Int = -1) async throws {
        let payload: [String: Any] = ["tabIds": tabIds, "windowId": windowId, "index": index]
        let payloadData = try JSONSerialization.data(withJSONObject: payload)
        _ = try await service.sendCommand(type: "moveTabs", payload: payloadData)
    }

    /// Move a single tab to a new window
    /// - Parameter tabId: The tab ID to move
    /// - Returns: The new window containing the tab
    /// - Throws: ChromeNativeMessagingError if not connected or command fails
    @discardableResult
    public func moveTabToNewWindow(tabId: Int) async throws -> ChromeRealTimeWindow {
        let payload: [String: Any] = ["tabId": tabId]
        let payloadData = try JSONSerialization.data(withJSONObject: payload)
        let response = try await service.sendCommand(type: "moveTabToNewWindow", payload: payloadData)
        return try JSONDecoder().decode(ChromeRealTimeWindow.self, from: response)
    }

    // MARK: - Window Commands

    /// Create a new Chrome window
    /// - Parameters:
    ///   - urls: URLs to open in the new window (empty for new tab page)
    ///   - focused: Whether the window should be focused
    ///   - incognito: Whether to create an incognito window
    /// - Returns: The created window
    /// - Throws: ChromeNativeMessagingError if not connected or command fails
    @discardableResult
    public func createWindow(
        urls: [String] = [],
        focused: Bool = true,
        incognito: Bool = false
    ) async throws -> ChromeRealTimeWindow {
        let payload: [String: Any] = [
            "urls": urls,
            "focused": focused,
            "incognito": incognito
        ]
        let payloadData = try JSONSerialization.data(withJSONObject: payload)
        let response = try await service.sendCommand(type: "createWindow", payload: payloadData)
        return try JSONDecoder().decode(ChromeRealTimeWindow.self, from: response)
    }

    /// Focus a Chrome window
    /// - Parameter windowId: The window ID to focus
    /// - Throws: ChromeNativeMessagingError if not connected or command fails
    public func focusWindow(id windowId: Int) async throws {
        let payload: [String: Any] = ["windowId": windowId]
        let payloadData = try JSONSerialization.data(withJSONObject: payload)
        _ = try await service.sendCommand(type: "focusWindow", payload: payloadData)
    }

    /// Close a Chrome window
    /// - Parameter windowId: The window ID to close
    /// - Throws: ChromeNativeMessagingError if not connected or command fails
    public func closeWindow(id windowId: Int) async throws {
        let payload: [String: Any] = ["windowId": windowId]
        let payloadData = try JSONSerialization.data(withJSONObject: payload)
        _ = try await service.sendCommand(type: "closeWindow", payload: payloadData)
    }

    // MARK: - Tab Group Commands

    /// Group tabs together into a new or existing group
    /// - Parameters:
    ///   - tabIds: The tab IDs to group
    ///   - groupId: Optional existing group ID to add tabs to
    ///   - windowId: Optional window ID for creating a new group (only used if groupId is nil)
    /// - Returns: The group ID (new or existing)
    /// - Throws: ChromeNativeMessagingError if not connected or command fails
    @discardableResult
    public func groupTabs(tabIds: [Int], inGroupId groupId: Int? = nil, windowId: Int? = nil) async throws -> Int {
        var payload: [String: Any] = ["tabIds": tabIds]
        if let groupId = groupId {
            payload["groupId"] = groupId
        }
        if let windowId = windowId {
            payload["windowId"] = windowId
        }

        let payloadData = try JSONSerialization.data(withJSONObject: payload)
        let response = try await service.sendCommand(type: "groupTabs", payload: payloadData)
        let result = try JSONDecoder().decode([String: Int].self, from: response)
        return result["groupId"] ?? -1
    }

    /// Remove tabs from their groups
    /// - Parameter tabIds: The tab IDs to ungroup
    /// - Throws: ChromeNativeMessagingError if not connected or command fails
    public func ungroupTabs(tabIds: [Int]) async throws {
        let payload: [String: Any] = ["tabIds": tabIds]
        let payloadData = try JSONSerialization.data(withJSONObject: payload)
        _ = try await service.sendCommand(type: "ungroupTabs", payload: payloadData)
    }

    /// Update tab group properties
    /// - Parameters:
    ///   - groupId: The group ID to update
    ///   - title: Optional new title for the group
    ///   - color: Optional new color (grey, blue, red, yellow, green, pink, purple, cyan, orange)
    ///   - collapsed: Optional collapsed state
    /// - Throws: ChromeNativeMessagingError if not connected or command fails
    public func updateGroup(id groupId: Int, title: String? = nil, color: String? = nil, collapsed: Bool? = nil) async throws {
        var payload: [String: Any] = ["groupId": groupId]
        if let title = title {
            payload["title"] = title
        }
        if let color = color {
            payload["color"] = color
        }
        if let collapsed = collapsed {
            payload["collapsed"] = collapsed
        }

        let payloadData = try JSONSerialization.data(withJSONObject: payload)
        _ = try await service.sendCommand(type: "updateGroup", payload: payloadData)
    }

    /// Get all tab groups, optionally filtered by window
    /// - Parameter windowId: Optional window ID to filter groups
    /// - Returns: Array of tab group information
    /// - Throws: ChromeNativeMessagingError if not connected or command fails
    public func getGroups(windowId: Int? = nil) async throws -> [ChromeTabGroup] {
        var payload: [String: Any] = [:]
        if let windowId = windowId {
            payload["windowId"] = windowId
        }

        let payloadData = payload.isEmpty ? nil : try JSONSerialization.data(withJSONObject: payload)
        let response = try await service.sendCommand(type: "getGroups", payload: payloadData)
        return try JSONDecoder().decode([ChromeTabGroup].self, from: response)
    }
}

// MARK: - Service Holder

/// Shared service holder for native messaging
/// This allows the service to be injected/configured at app startup
public enum ChromeNativeMessagingServiceHolder {
    private static var _service: ChromeNativeMessagingServiceProtocol?
    private static let lock = NSLock()

    /// The shared native messaging service instance
    /// Returns nil if not configured
    public static var shared: ChromeNativeMessagingServiceProtocol? {
        lock.lock()
        defer { lock.unlock() }
        return _service
    }

    /// Configure the shared service instance
    /// - Parameter service: The service to use
    public static func configure(_ service: ChromeNativeMessagingServiceProtocol?) {
        lock.lock()
        _service = service
        lock.unlock()
    }
}
