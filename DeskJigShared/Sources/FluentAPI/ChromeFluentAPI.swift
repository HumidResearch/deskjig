//  ChromeFluentAPI.swift
//  DeskJigShared

import Foundation
import AppKit

// MARK: - Chrome Fluent API

/// Fluent API for Chrome operations accessed via SystemSnapshot.chrome
public struct ChromeAPI: Sendable {
    private let snapshot: SystemSnapshot

    public init(snapshot: SystemSnapshot) {
        self.snapshot = snapshot
    }

    // MARK: - Window Queries

    /// All Chrome windows in the snapshot
    public func windows() -> [SnapshotWindow] {
        snapshot.windows.filter { chromeBundleIdentifiers.contains($0.bundleId ?? "") }
    }

    /// Chrome windows for a specific profile name
    public func windows(profile: String) -> [SnapshotWindow] {
        windows().filter { extractProfileName(from: $0.title) == profile }
    }

    /// Check if a window is a Chrome window
    public func isChrome(_ window: SnapshotWindow) -> Bool {
        guard let bundleId = window.bundleId else { return false }
        return chromeBundleIdentifiers.contains(bundleId)
    }

    // MARK: - Profile Extraction

    /// Extract profile name from a Chrome window title
    /// - Format: "Page Title - Google Chrome - Profile Name" or "Page Title - Profile Name - Google Chrome"
    /// - Returns: The extracted profile name, or nil if not found
    public func extractProfileName(from title: String?) -> String? {
        guard let title = title, !title.isEmpty else { return nil }

        // Chrome title formats:
        // 1. "Page Title - Google Chrome" (default profile, single user)
        // 2. "Page Title - Google Chrome - Profile Name" (multi-profile)
        // 3. "Page Title - Profile Name - Google Chrome" (alternative format)

        let parts = title.components(separatedBy: " - ")
        guard parts.count >= 2 else { return nil }

        // Look for "Google Chrome" in parts to determine format
        if let chromeIndex = parts.firstIndex(where: { $0.contains("Google Chrome") }) {
            // If there's a part after "Google Chrome", that's the profile
            if chromeIndex < parts.count - 1 {
                return parts[chromeIndex + 1]
            }
            // If "Google Chrome" is last but there's a part before it that's not the page title
            // This handles "Page - Profile - Google Chrome" format
            if chromeIndex == parts.count - 1 && chromeIndex >= 2 {
                // The part before "Google Chrome" might be the profile
                let potentialProfile = parts[chromeIndex - 1]
                // If it doesn't look like a page title (short, no special chars), it's likely the profile
                if potentialProfile.count < 30 && !potentialProfile.contains(":") {
                    return potentialProfile
                }
            }
        }

        // Fallback: last part that's not "Google Chrome"
        for part in parts.reversed() {
            if !part.contains("Google Chrome") && !part.isEmpty {
                // Skip if it looks like a URL or page title
                if part.contains("://") || part.contains(".com") || part.contains(".org") {
                    continue
                }
                return part
            }
        }

        return nil
    }

    // MARK: - Capture Matching

    /// Find the Chrome capture for a window (single source of truth for matching)
    /// - Parameter window: The window to find a capture for
    /// - Returns: The matching capture, or nil if not found
    public func capture(for window: SnapshotWindow) -> ChromeWindowCapture? {
        guard isChrome(window) else { return nil }
        guard !snapshot.chromeCaptures.isEmpty else { return nil }

        let windowProfileName = extractProfileName(from: window.title)

        // Strategy 1: Exact profile name match
        if let profileName = windowProfileName,
           let match = snapshot.chromeCaptures.first(where: { $0.profileName == profileName }) {
            return match
        }

        // Strategy 2: Single window + single capture
        let chromeWindows = windows()
        if chromeWindows.count == 1 && snapshot.chromeCaptures.count == 1 {
            return snapshot.chromeCaptures.first
        }

        // Strategy 3: Fuzzy profile matching
        // Handle cases like "Andrew" vs "Andrew (domain.com)"
        if let profileName = windowProfileName {
            let baseProfile = profileName.components(separatedBy: " (").first ?? profileName
            if let match = snapshot.chromeCaptures.first(where: {
                $0.profileName == baseProfile ||
                $0.profileName.hasPrefix(baseProfile) ||
                baseProfile.hasPrefix($0.profileName) ||
                $0.profileName.lowercased() == profileName.lowercased()
            }) {
                return match
            }
        }

        // Strategy 4: Match by document URL
        // If the window has a document path (active tab URL), find a capture containing that URL
        if let documentPath = window.documentPath, !documentPath.isEmpty {
            if let match = snapshot.chromeCaptures.first(where: { capture in
                // Check if any tab URL matches the document path
                capture.tabUrls.contains(where: { url in
                    url == documentPath ||
                    url.hasPrefix(documentPath) ||
                    documentPath.hasPrefix(url)
                })
            }) {
                return match
            }
        }

        // Strategy 5: Match by Chrome window index using z-order
        // Chrome's AppleScript window index often correlates with z-order
        if window.zOrderIndex != nil {
            let sortedChromeWindows = chromeWindows.sorted { ($0.zOrderIndex ?? Int.max) < ($1.zOrderIndex ?? Int.max) }
            if let windowIndex = sortedChromeWindows.firstIndex(where: { $0.windowId == window.windowId }),
               windowIndex < snapshot.chromeCaptures.count {
                // Windows are 1-indexed in AppleScript, 0-indexed in our array
                return snapshot.chromeCaptures[windowIndex]
            }
        }

        // Strategy 6: Match by active tab in title
        // Chrome window titles often show the active tab's page title
        // Try to find a capture where the active tab's URL is reflected in the window title
        if let title = window.title {
            for capture in snapshot.chromeCaptures {
                // Get the active tab URL if available
                if capture.activeTabIndex > 0 && capture.activeTabIndex <= capture.tabUrls.count {
                    let activeUrl = capture.tabUrls[capture.activeTabIndex - 1]
                    // Check if title contains hostname from active URL
                    if let host = URL(string: activeUrl)?.host,
                       title.lowercased().contains(host.lowercased().replacingOccurrences(of: "www.", with: "")) {
                        return capture
                    }
                }
            }
        }

        return nil
    }

    /// Match all Chrome windows to their captures
    /// - Returns: Dictionary mapping window ID to capture
    public func matchAllCaptures() -> [String: ChromeWindowCapture] {
        var matches: [String: ChromeWindowCapture] = [:]
        for window in windows() {
            if let cap = capture(for: window) {
                matches[window.id] = cap
            }
        }
        return matches
    }

    // MARK: - Tab Queries

    /// Get tab URLs for a window (via its matched capture)
    public func tabs(for window: SnapshotWindow) -> [String] {
        capture(for: window)?.tabUrls ?? []
    }

    /// Get active tab index for a window (1-based as reported by Chrome)
    public func activeTabIndex(for window: SnapshotWindow) -> Int? {
        capture(for: window)?.activeTabIndex
    }

    /// Get the active tab URL for a window
    public func activeTabURL(for window: SnapshotWindow) -> String? {
        guard let cap = capture(for: window),
              cap.activeTabIndex > 0 && cap.activeTabIndex <= cap.tabUrls.count else {
            return nil
        }
        return cap.tabUrls[cap.activeTabIndex - 1]
    }

    // MARK: - Profile Queries

    /// All installed Chrome profiles from disk (reads Local State file)
    /// - Returns: Array of ChromeProfile objects
    public func allProfiles() -> [ChromeProfile] {
        let manager = ChromeProfileManager()
        return manager.refreshProfilesSync()
    }

    /// Find the ChromeProfile that matches this window based on profile name extraction
    /// - Parameter window: The Chrome window
    /// - Returns: The matching ChromeProfile, or nil if not found
    public func matchingProfile(for window: SnapshotWindow) -> ChromeProfile? {
        guard isChrome(window) else { return nil }

        // Extract profile name from window title
        guard let profileName = extractProfileName(from: window.title) else { return nil }

        let profiles = allProfiles()

        // Strategy 1: Exact match on appleScriptName
        if let match = profiles.first(where: { $0.appleScriptName == profileName }) {
            return match
        }

        // Strategy 2: Match by display name
        if let match = profiles.first(where: { $0.displayName == profileName }) {
            return match
        }

        // Strategy 3: Fuzzy match - base name without domain
        let baseProfile = profileName.components(separatedBy: " (").first ?? profileName
        if let match = profiles.first(where: {
            $0.displayName == baseProfile ||
            $0.gaiaName?.hasPrefix(baseProfile) == true ||
            baseProfile.hasPrefix($0.displayName)
        }) {
            return match
        }

        return nil
    }

    /// Get all other profiles (profiles not matching this window)
    /// - Parameter window: The Chrome window
    /// - Returns: Array of other ChromeProfile objects
    public func otherProfiles(for window: SnapshotWindow) -> [ChromeProfile] {
        let currentProfile = matchingProfile(for: window)
        let all = allProfiles()
        if let current = currentProfile {
            return all.filter { $0.id != current.id }
        }
        return all
    }

    /// Get a profile by name (case-insensitive)
    /// - Parameter name: The profile name to find
    /// - Returns: The matching profile, or nil if not found
    public func profile(named name: String) -> ChromeProfile? {
        let lowercaseName = name.lowercased()
        return allProfiles().first {
            $0.displayName.lowercased() == lowercaseName ||
            $0.appleScriptName.lowercased() == lowercaseName
        }
    }

    /// Get a profile by username or GAIA name (often an email or account name)
    /// - Parameter username: The username to find (case-insensitive)
    /// - Returns: The matching profile, or nil if not found
    public func profile(username: String) -> ChromeProfile? {
        let lowercaseName = username.lowercased()
        return allProfiles().first {
            $0.userName?.lowercased() == lowercaseName ||
            $0.gaiaName?.lowercased() == lowercaseName
        }
    }

    // MARK: - Profile Actions

    /// Open a URL in a specific profile
    /// Uses command-line launching since extension cannot switch profiles
    /// - Parameters:
    ///   - url: The URL to open
    ///   - profile: The profile to use
    /// - Returns: True if launch succeeded
    @discardableResult
    public func openURL(_ url: String, in profile: ChromeProfile) async -> Bool {
        await ChromeOperations.launchWindow(
            profileDirectory: profile.directory,
            urls: [url]
        )
    }

    /// Open multiple URLs in a specific profile
    /// Uses command-line launching since extension cannot switch profiles
    /// - Parameters:
    ///   - urls: The URLs to open
    ///   - profile: The profile to use
    /// - Returns: True if launch succeeded
    @discardableResult
    public func openURLs(_ urls: [String], in profile: ChromeProfile) async -> Bool {
        await ChromeOperations.launchWindow(
            profileDirectory: profile.directory,
            urls: urls
        )
    }

    /// Launch a new window for a profile
    /// Uses command-line launching since extension cannot switch profiles
    /// - Parameter profile: The profile to use
    /// - Returns: True if launch succeeded
    @discardableResult
    public func launchWindow(for profile: ChromeProfile) async -> Bool {
        await ChromeOperations.launchWindow(
            profileDirectory: profile.directory,
            urls: []
        )
    }

    // MARK: - Native Messaging API

    /// Access real-time Chrome state via native messaging extension
    /// Returns nil if the native messaging service is not configured or not connected
    public var nativeMessaging: ChromeNativeMessagingAPI? {
        guard let service = ChromeNativeMessagingServiceHolder.shared,
              service.isConnected else {
            return nil
        }
        return ChromeNativeMessagingAPI(service: service)
    }

    // MARK: - Summary

    /// Summary of Chrome windows and captures
    public var summary: String {
        let chromeWindows = windows()
        let captures = snapshot.chromeCaptures

        var lines: [String] = []
        lines.append("Chrome Windows: \(chromeWindows.count)")
        lines.append("Chrome Captures: \(captures.count)")

        for (i, window) in chromeWindows.enumerated() {
            let profile = extractProfileName(from: window.title) ?? "Unknown"
            let matched = capture(for: window) != nil ? "✓" : "✗"
            lines.append("  [\(i)] \(profile) - matched: \(matched)")
        }

        if !captures.isEmpty {
            lines.append("Captures:")
            for cap in captures {
                lines.append("  - \(cap.profileName): \(cap.tabUrls.count) tabs, window #\(cap.chromeWindowId)")
            }
        }

        return lines.joined(separator: "\n")
    }
}

// MARK: - SystemSnapshot Extension

extension SystemSnapshot {
    /// Fluent API for Chrome operations
    public var chrome: ChromeAPI {
        ChromeAPI(snapshot: self)
    }
}

// MARK: - Chrome Mutations (Static Operations)

/// Static operations for Chrome that don't require a snapshot
public enum ChromeOperations {

    /// Launch a new Chrome window with a specific profile
    /// - Parameters:
    ///   - profileDirectory: The Chrome profile directory (e.g., "Profile 1", "Default")
    ///   - urls: URLs to open in the new window
    /// - Returns: True if launch succeeded
    @discardableResult
    public static func launchWindow(
        profileDirectory: String?,
        urls: [String] = []
    ) async -> Bool {
        DeskJigLog.info(.chrome, "Launching Chrome window with profile=\(profileDirectory ?? "default"), urls=\(urls.count)")

        // Build arguments: open -na "Google Chrome" --args --new-window --profile-directory=<dir> <urls>
        var args = ["-na", "Google Chrome", "--args", "--new-window"]

        if let profileDir = profileDirectory {
            args.append("--profile-directory=\(profileDir)")
        }

        args.append(contentsOf: urls)

        do {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            process.arguments = args

            try process.run()
            process.waitUntilExit()

            let success = process.terminationStatus == 0
            DeskJigLog.info(.chrome, "Chrome launch \(success ? "succeeded" : "failed")")
            return success
        } catch {
            DeskJigLog.error(.chrome, "Chrome launch error: \(error.localizedDescription)")
            return false
        }
    }

    /// Open tabs in an existing Chrome window using AppleScript
    /// - Parameters:
    ///   - urls: The URLs to open
    ///   - chromeWindowIndex: The Chrome window index (1-based)
    public static func openTabs(
        urls: [String],
        inWindowIndex chromeWindowIndex: Int
    ) async {
        guard !urls.isEmpty else { return }

        DeskJigLog.info(.chrome, "Opening \(urls.count) tabs in Chrome window \(chromeWindowIndex)")

        let script = ChromeAppleScript.replaceActiveTabAndAppend(urls, inWindowIndex: chromeWindowIndex)

        do {
            try AppleScriptRunner.runInProcess(script)
            DeskJigLog.info(.chrome, "Successfully opened \(urls.count) tabs")
        } catch {
            DeskJigLog.error(.chrome, "Tab opening failed: \(error)")
        }
    }

    /// Open tabs in a Chrome window by its Chrome window ID
    /// - Parameters:
    ///   - urls: The URLs to open
    ///   - chromeWindowId: The Chrome window ID (from ChromeWindowCapture)
    public static func openTabs(
        urls: [String],
        inWindowWithChromeId chromeWindowId: Int
    ) {
        guard !urls.isEmpty else { return }
        // Delegate to existing ChromeAutomationService
        ChromeAutomationService.openTabs(urls, inWindowWithChromeId: chromeWindowId)
    }

    /// Set the active tab in a Chrome window
    /// - Parameters:
    ///   - index: The tab index (1-based)
    ///   - chromeWindowId: The Chrome window ID
    public static func setActiveTab(
        index: Int,
        inWindowWithChromeId chromeWindowId: Int
    ) {
        ChromeAutomationService.setActiveTab(index: index, inWindowWithChromeId: chromeWindowId)
    }

    /// Launch a new Chrome window via AppleScript
    /// - Parameters:
    ///   - profileDirectory: The Chrome profile directory (e.g., "Profile 1", "Default")
    ///   - urls: URLs to open in the new window
    /// - Returns: True if launch succeeded
    /// - Note: When profileDirectory is specified, uses CLI launch internally since AppleScript
    ///         doesn't support profile selection. AppleScript is only used when no profile is needed.
    @discardableResult
    public static func launchWindowViaAppleScript(
        profileDirectory: String?,
        urls: [String] = []
    ) async -> Bool {
        DeskJigLog.info(.chrome, "Launching Chrome window via AppleScript with profile=\(profileDirectory ?? "default"), urls=\(urls.count)")

        // IMPORTANT: AppleScript's "make new window" doesn't support profile selection.
        // When a specific profile is needed, we must use CLI launch instead.
        if let profileDir = profileDirectory, !profileDir.isEmpty {
            DeskJigLog.info(.chrome, "Profile specified (\(profileDir)), using CLI launch for profile support")
            return await launchWindow(profileDirectory: profileDir, urls: urls)
        }

        // No profile specified - use pure AppleScript (creates window in active profile)
        let script = ChromeAppleScript.openNewFrontWindow(urls: urls)

        do {
            try AppleScriptRunner.runInProcess(script)
        } catch {
            DeskJigLog.error(.chrome, "AppleScript Chrome launch failed: \(error)")
            return false
        }

        DeskJigLog.info(.chrome, "Successfully launched Chrome window via AppleScript")
        return true
    }

    /// Launch a new Chrome window via native messaging extension
    /// - Parameters:
    ///   - urls: URLs to open in the new window
    /// - Returns: True if launch succeeded, false if native messaging not available
    @discardableResult
    public static func launchWindowViaNativeMessaging(
        urls: [String] = []
    ) async -> Bool {
        DeskJigLog.info(.chrome, "Attempting Chrome window launch via native messaging, urls=\(urls.count)")

        guard let service = ChromeNativeMessagingServiceHolder.shared,
              service.isConnected else {
            DeskJigLog.warn(.chrome, "Native messaging not available for Chrome launch")
            return false
        }

        let api = ChromeNativeMessagingAPI(service: service)
        do {
            _ = try await api.createWindow(urls: urls, focused: true)
            DeskJigLog.info(.chrome, "Successfully launched Chrome window via native messaging")
            return true
        } catch {
            DeskJigLog.error(.chrome, "Native messaging Chrome launch failed: \(error.localizedDescription)")
            return false
        }
    }
}
