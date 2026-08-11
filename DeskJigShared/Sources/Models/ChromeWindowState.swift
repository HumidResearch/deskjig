//  ChromeWindowState.swift
//  DeskJigShared

import Foundation

public enum ChromeProfileMatchMode: String, Codable, Hashable, Sendable {
    case specific
    case anyWindow
}

public struct ChromeWindowState: Codable, Hashable, Sendable {
    public let profileDirectory: String
    public let profileDisplayName: String
    public let profileHostedDomain: String?
    public let profileUserName: String?
    public let profileMatchMode: ChromeProfileMatchMode
    public let shouldRestoreTabs: Bool
    public let savedTabURLs: [String]
    public let focusedTabIndex: Int?
    /// Chrome's internal window ID from AppleScript (stable within a session)
    public let chromeWindowId: Int?

    public init(
        profileDirectory: String,
        profileDisplayName: String,
        profileHostedDomain: String? = nil,
        profileUserName: String? = nil,
        profileMatchMode: ChromeProfileMatchMode = .specific,
        shouldRestoreTabs: Bool = true,
        savedTabURLs: [String] = [],
        focusedTabIndex: Int? = nil,
        chromeWindowId: Int? = nil
    ) {
        self.profileDirectory = profileDirectory
        self.profileDisplayName = profileDisplayName
        self.profileHostedDomain = profileHostedDomain
        self.profileUserName = profileUserName
        self.profileMatchMode = profileMatchMode
        self.shouldRestoreTabs = shouldRestoreTabs
        self.savedTabURLs = savedTabURLs
        self.focusedTabIndex = focusedTabIndex
        self.chromeWindowId = chromeWindowId
    }

    // MARK: - Codable

    private enum CodingKeys: String, CodingKey {
        case profileDirectory, profileDisplayName, profileHostedDomain, profileUserName
        case profileMatchMode, shouldRestoreTabs, savedTabURLs
        case focusedTabIndex, chromeWindowId
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        profileDirectory = try container.decode(String.self, forKey: .profileDirectory)
        profileDisplayName = try container.decode(String.self, forKey: .profileDisplayName)
        profileHostedDomain = try container.decodeIfPresent(String.self, forKey: .profileHostedDomain)
        profileUserName = try container.decodeIfPresent(String.self, forKey: .profileUserName)

        // Backwards compatibility: default to .specific for old workspaces
        profileMatchMode = try container.decodeIfPresent(ChromeProfileMatchMode.self, forKey: .profileMatchMode) ?? .specific

        shouldRestoreTabs = try container.decode(Bool.self, forKey: .shouldRestoreTabs)
        savedTabURLs = try container.decode([String].self, forKey: .savedTabURLs)
        focusedTabIndex = try container.decodeIfPresent(Int.self, forKey: .focusedTabIndex)
        chromeWindowId = try container.decodeIfPresent(Int.self, forKey: .chromeWindowId)
    }

    public var appleScriptProfileName: String {
        if profileMatchMode == .anyWindow {
            return ""
        }
        if let domain = profileHostedDomain, domain != "NO_HOSTED_DOMAIN", !domain.isEmpty {
            return "\(profileDisplayName) (\(domain))"
        }
        return profileDisplayName
    }
}
