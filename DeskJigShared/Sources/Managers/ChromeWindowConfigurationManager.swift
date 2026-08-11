//  ChromeWindowConfigurationManager.swift
//  DeskJigShared

import Foundation
import Cocoa

public class ChromeWindowConfigurationManager: ObservableObject {
    @Published public private(set) var chromeConfigurations: [Int: ChromeWindowConfiguration] = [:]
    public let chromeProfileManager = ChromeProfileManager()

    public init() {
        chromeProfileManager.refreshProfiles()
    }

    // MARK: - Chrome Configuration

    /// Update a chrome configuration directly
    public func updateConfiguration(_ configuration: ChromeWindowConfiguration, for windowId: Int) {
        chromeConfigurations[windowId] = configuration
    }

    public func chromeConfiguration(for windowInfo: WindowInfo) -> ChromeWindowConfiguration? {
        guard let bundleIdentifier = windowInfo.bundleIdentifier,
              chromeBundleIdentifiers.contains(bundleIdentifier) else {
            return nil
        }

        if let existing = chromeConfigurations[windowInfo.id] {
            return existing
        }

        var configuration = ChromeWindowConfiguration(windowId: windowInfo.id)
        if let capture = matchChromeCapture(for: windowInfo) {
            configuration.profileAppleScriptName = capture.profileAppleScriptName
            configuration.chromeWindowId = capture.chromeWindowId
            if let profileName = capture.profileAppleScriptName,
               let profile = chromeProfileManager.profile(forAppleScriptName: profileName) {
                configuration.apply(profile: profile)
            } else if let profileName = capture.profileAppleScriptName {
                configuration.profileDisplayName = profileName
            }
            // Capture tab URLs and active tab index when creating configuration
            configuration.savedTabURLs = capture.tabURLs
            configuration.savedActiveTabIndex = capture.activeTabIndex
            configuration.lastCaptureDate = Date()
            // Enable tab restoration by default when we have profile and tabs
            if configuration.profileDirectory != nil && !capture.tabURLs.isEmpty {
                configuration.shouldRestoreTabs = true
            }
        }

        chromeConfigurations[windowInfo.id] = configuration
        return configuration
    }

    public func applyChromeState(_ state: ChromeWindowState?, to windowId: Int) {
        var configuration = ChromeWindowConfiguration(windowId: windowId, state: state)

        if let directory = configuration.profileDirectory,
           let profile = chromeProfileManager.profile(forDirectory: directory) {
            configuration.apply(profile: profile)
        } else if let profileName = configuration.profileDisplayName {
            configuration.profileAppleScriptName = profileName
        }

        chromeConfigurations[windowId] = configuration
    }

    public func setChromeProfile(directory: String?, for windowInfo: WindowInfo) {
        guard var configuration = chromeConfiguration(for: windowInfo) else { return }

        if let directory,
           let profile = chromeProfileManager.profile(forDirectory: directory) {
            configuration.apply(profile: profile)
        } else {
            configuration.clearProfile()
        }

        chromeConfigurations[windowInfo.id] = configuration
    }

    public func setChromeShouldRestoreTabs(_ newValue: Bool, for windowInfo: WindowInfo, onUpdate: @escaping () -> Void) {
        guard var configuration = chromeConfiguration(for: windowInfo) else { return }

        if newValue {
            if configuration.profileDirectory == nil {
                if let capture = matchChromeCapture(for: windowInfo),
                   let profileName = capture.profileAppleScriptName,
                   let profile = chromeProfileManager.profile(forAppleScriptName: profileName) {
                    configuration.apply(profile: profile)
                } else if let defaultProfile = chromeProfileManager.defaultProfile() {
                    configuration.apply(profile: defaultProfile)
                }
            }

            if let capture = matchChromeCapture(for: windowInfo) {
                configuration.profileAppleScriptName = capture.profileAppleScriptName ?? configuration.profileAppleScriptName
                configuration.chromeWindowId = capture.chromeWindowId ?? configuration.chromeWindowId
                configuration.savedTabURLs = capture.tabURLs
                configuration.savedActiveTabIndex = capture.activeTabIndex
                configuration.lastCaptureDate = Date()
            } else {
                DeskJigLog.warn(.chrome, "Chrome configuration: Unable to capture current tabs for window \(windowInfo.windowTitle)")
            }

            // If we still don't have a profile, disable restoring tabs
            if configuration.profileDirectory == nil {
                DeskJigLog.warn(.chrome, "Chrome configuration: No profile selected for window \(windowInfo.windowTitle). Disabling tab restore.")
                configuration.shouldRestoreTabs = false
                chromeConfigurations[windowInfo.id] = configuration
                onUpdate()
                return
            }

            configuration.shouldRestoreTabs = true
        } else {
            configuration.shouldRestoreTabs = false
        }

        chromeConfigurations[windowInfo.id] = configuration
        onUpdate()
    }

    public func refreshChromeTabs(for windowInfo: WindowInfo, onUpdate: @escaping () -> Void) {
        guard var configuration = chromeConfiguration(for: windowInfo) else { return }

        guard let capture = matchChromeCapture(for: windowInfo) else {
            DeskJigLog.warn(.chrome, "Chrome configuration: Unable to refresh tabs for window \(windowInfo.windowTitle)")
            return
        }

        configuration.profileAppleScriptName = capture.profileAppleScriptName ?? configuration.profileAppleScriptName
        configuration.chromeWindowId = capture.chromeWindowId ?? configuration.chromeWindowId
        configuration.savedTabURLs = capture.tabURLs
        configuration.savedActiveTabIndex = capture.activeTabIndex
        configuration.lastCaptureDate = Date()

        // If we still don't have a profile, try to resolve it now
        if configuration.profileDirectory == nil,
           let profileName = configuration.profileAppleScriptName,
           let profile = chromeProfileManager.profile(forAppleScriptName: profileName) {
            configuration.apply(profile: profile)
        }

        chromeConfigurations[windowInfo.id] = configuration
        onUpdate()
    }

    public func chromeState(for windowInfo: WindowInfo, captureIfNeeded: Bool) -> ChromeWindowState? {
        guard var configuration = chromeConfiguration(for: windowInfo) else { return nil }

        if captureIfNeeded, configuration.shouldRestoreTabs {
            refreshChromeTabs(for: windowInfo, onUpdate: {})
            configuration = chromeConfigurations[windowInfo.id] ?? configuration
        }

        return configuration.workspaceState
    }

    public func matchChromeCapture(for windowInfo: WindowInfo) -> ChromeAppleScriptWindowCapture? {
        let captures = ChromeAutomationService.captureOpenWindows()
        guard !captures.isEmpty else { return nil }

        // First: try to match by saved Chrome Window ID (most reliable)
        if let existingConfig = chromeConfigurations[windowInfo.id],
           let savedChromeId = existingConfig.chromeWindowId,
           let capture = captures.first(where: { $0.chromeWindowId == savedChromeId }) {
            return capture
        }

        // Handle fullscreen Chrome decoration windows
        // These have extreme aspect ratios (e.g., 1920x123) and title "Untitled"
        let aspectRatio = windowInfo.frame.width / max(windowInfo.frame.height, 1)
        let isFullscreenDecoration = aspectRatio > 10.0 || windowInfo.windowTitle == "Untitled"

        if isFullscreenDecoration {
            // Find capture that's on the same screen AND has a valid profile
            // (fullscreen mode creates decoration windows without profile info)
            if let capture = captures.first(where: { capture in
                // Must have a profile to be the real content window
                guard capture.profileAppleScriptName != nil else { return false }

                let windowMinX = windowInfo.frame.origin.x
                let windowMaxX = windowMinX + windowInfo.frame.width
                let captureMinX = capture.bounds.origin.x
                let captureMaxX = captureMinX + capture.bounds.width
                // Check if they're on the same screen (x ranges overlap)
                return windowMinX < captureMaxX && windowMaxX > captureMinX
            }) {
                DeskJigLog.debug(.chrome, "matchChromeCapture: Matched fullscreen decoration '\(windowInfo.windowTitle)' to capture '\(capture.title)' via screen position (profile: \(capture.profileAppleScriptName ?? "nil"))")
                return capture
            }
        }

        // Match by frame/bounds
        if let capture = captures.first(where: { $0.bounds == windowInfo.frame }) {
            return capture
        }

        // Fallback: match by title
        if !windowInfo.windowTitle.isEmpty,
           let capture = captures.first(where: { capture in
               capture.title.contains(windowInfo.windowTitle)
           }) {
            return capture
        }

        return captures.first
    }

    /// Find a Chrome capture by Chrome's internal window ID
    public func findChromeCapture(byChromeWindowId chromeWindowId: Int) -> ChromeAppleScriptWindowCapture? {
        let captures = ChromeAutomationService.captureOpenWindows()
        return captures.first(where: { $0.chromeWindowId == chromeWindowId })
    }
}
