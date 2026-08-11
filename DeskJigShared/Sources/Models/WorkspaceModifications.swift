//  WorkspaceModifications.swift
//  DeskJigShared

import Foundation

/// Chrome window modification data for saving/updating workspaces
public struct ChromeModification: Codable, Sendable {
    public var tabURLs: [String]
    public var profileDirectory: String?
    public var profileDisplayName: String?
    public var profileHostedDomain: String?
    public var profileUserName: String?
    public var profileMatchMode: ChromeProfileMatchMode
    
    public init(
        tabURLs: [String],
        profileDirectory: String?,
        profileDisplayName: String?,
        profileHostedDomain: String?,
        profileUserName: String? = nil,
        profileMatchMode: ChromeProfileMatchMode = .specific
    ) {
        self.tabURLs = tabURLs
        self.profileDirectory = profileDirectory
        self.profileDisplayName = profileDisplayName
        self.profileHostedDomain = profileHostedDomain
        self.profileUserName = profileUserName
        self.profileMatchMode = profileMatchMode
    }
}

/// Per-window "open by path" modification data for saving/updating workspaces.
/// This is used for apps like Cursor, Ghostty, and terminal emulators that can be launched into a specific directory.
public struct OpenByPathModification: Codable, Sendable {
    public var bundleIdentifier: String
    public var windowTitle: String
    public var openPath: String?

    public init(
        bundleIdentifier: String,
        windowTitle: String,
        openPath: String?
    ) {
        self.bundleIdentifier = bundleIdentifier
        self.windowTitle = windowTitle
        self.openPath = openPath
    }
}
