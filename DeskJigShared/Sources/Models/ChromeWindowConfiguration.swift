//  ChromeWindowConfiguration.swift
//  DeskJigShared

import Foundation

public let chromeBundleIdentifiers: Set<String> = [
    "com.google.Chrome",
    "com.google.Chrome.beta",
    "com.google.Chrome.dev",
    "com.google.Chrome.canary"
]

public struct ChromeWindowConfiguration: Equatable {
    public let windowId: Int
    public var profileDirectory: String?
    public var profileDisplayName: String?
    public var profileHostedDomain: String?
    public var profileUserName: String?
    public var profileAppleScriptName: String?
    public var profileMatchMode: ChromeProfileMatchMode
    public var shouldRestoreTabs: Bool
    public var savedTabURLs: [String]
    public var savedActiveTabIndex: Int?
    public var lastCaptureDate: Date?
    /// Chrome's internal window ID from AppleScript (stable within a session)
    public var chromeWindowId: Int?

    public init(windowId: Int) {
        self.windowId = windowId
        self.shouldRestoreTabs = false
        self.savedTabURLs = []
        self.profileDirectory = nil
        self.profileDisplayName = nil
        self.profileHostedDomain = nil
        self.profileUserName = nil
        self.profileAppleScriptName = nil
        self.profileMatchMode = .specific
        self.savedActiveTabIndex = nil
        self.lastCaptureDate = nil
        self.chromeWindowId = nil
    }

    public init(windowId: Int, state: ChromeWindowState?) {
        self.init(windowId: windowId)

        guard let state else { return }

        profileDirectory = state.profileDirectory
        profileDisplayName = state.profileDisplayName
        profileHostedDomain = state.profileHostedDomain
        profileUserName = state.profileUserName
        profileMatchMode = state.profileMatchMode
        shouldRestoreTabs = state.shouldRestoreTabs
        savedTabURLs = state.savedTabURLs
        savedActiveTabIndex = state.focusedTabIndex
        chromeWindowId = state.chromeWindowId
    }

    public var workspaceState: ChromeWindowState? {
        if profileMatchMode == .anyWindow {
            return ChromeWindowState(
                profileDirectory: profileDirectory ?? "",
                profileDisplayName: profileDisplayName ?? "",
                profileHostedDomain: profileHostedDomain,
                profileUserName: profileUserName,
                profileMatchMode: profileMatchMode,
                shouldRestoreTabs: shouldRestoreTabs,
                savedTabURLs: savedTabURLs,
                focusedTabIndex: savedActiveTabIndex,
                chromeWindowId: chromeWindowId
            )
        }

        guard let profileDirectory,
              let profileDisplayName else { return nil }

        return ChromeWindowState(
            profileDirectory: profileDirectory,
            profileDisplayName: profileDisplayName,
            profileHostedDomain: profileHostedDomain,
            profileUserName: profileUserName,
            profileMatchMode: profileMatchMode,
            shouldRestoreTabs: shouldRestoreTabs,
            savedTabURLs: savedTabURLs,
            focusedTabIndex: savedActiveTabIndex,
            chromeWindowId: chromeWindowId
        )
    }

    public mutating func apply(profile: ChromeProfile) {
        profileDirectory = profile.directory
        // Use first name from gaiaName if available, otherwise fall back to displayName
        profileDisplayName = profile.gaiaName?.components(separatedBy: " ").first ?? profile.displayName
        profileHostedDomain = profile.hostedDomain
        profileUserName = profile.userName
        profileAppleScriptName = profile.appleScriptName
        profileMatchMode = .specific
    }

    public mutating func clearProfile() {
        profileDirectory = nil
        profileDisplayName = nil
        profileHostedDomain = nil
        profileUserName = nil
        profileAppleScriptName = nil
        profileMatchMode = .specific
        shouldRestoreTabs = false
        savedTabURLs = []
        savedActiveTabIndex = nil
    }
}
