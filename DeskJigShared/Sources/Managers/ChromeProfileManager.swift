//  ChromeProfileManager.swift
//  DeskJigShared

import Foundation

public protocol ChromeProfileManagerProtocol: AnyObject {
    var profiles: [ChromeProfile] { get }
    var lastUsedProfileDirectory: String? { get }
    func refreshProfiles()
    func refreshProfilesSync() -> [ChromeProfile]
    func profile(forDirectory directory: String) -> ChromeProfile?
    func profile(forAppleScriptName appleScriptName: String) -> ChromeProfile?
    func defaultProfile() -> ChromeProfile?
}

public struct ChromeProfile: Identifiable, Equatable {
    public var id: String { directory }
    
    public let directory: String
    public let displayName: String
    public let hostedDomain: String?
    public let userName: String?
    public let isManaged: Bool
    public let gaiaName: String?
    public var appleScriptName: String
    
    /// Returns the first name from gaiaName if available, otherwise falls back to displayName.
    /// This matches what Chrome shows in window titles for managed/Google-connected profiles.
    public var appleScriptDisplayName: String {
        gaiaName?.components(separatedBy: " ").first ?? displayName
    }
}

public final class ChromeProfileManager: ObservableObject {
    private let fileManager: FileManager
    private let localStateURL: URL
    @Published public private(set) var profiles: [ChromeProfile] = []
    @Published public private(set) var lastUsedProfileDirectory: String?

    public init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
        self.localStateURL = fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Google/Chrome/Local State")
    }

    public func refreshProfiles() {
        guard fileManager.fileExists(atPath: localStateURL.path) else {
            DeskJigLog.info(.chrome, "ChromeProfileManager: Local State file missing at \(localStateURL.path)")
            DispatchQueue.main.async { [weak self] in
                self?.profiles = []
                self?.lastUsedProfileDirectory = nil
            }
            return
        }

        do {
            let data = try Data(contentsOf: localStateURL)
            let decoder = JSONDecoder()
            let localState = try decoder.decode(LocalState.self, from: data)

            let orderedDirectories = localState.profile.profilesOrder ?? []
            var discoveredProfiles: [ChromeProfile] = localState.profile.infoCache.map { entry in
                let hostedDomain = (entry.value.hostedDomain ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                let appleScriptName = {
                    let hostedDomain = hostedDomain.isEmpty || hostedDomain == "NO_HOSTED_DOMAIN" ? nil : hostedDomain
                    if let gaiaName = entry.value.gaiaName, let hostedDomain {
                        let displayName = gaiaName.components(separatedBy: " ").first ?? gaiaName
                        return "\(displayName) (\(hostedDomain))"
                    } else if let hostedDomain {
                        return "\(entry.value.name) (\(hostedDomain))"
                    }
                    return entry.value.name
                }()
                return ChromeProfile(
                    directory: entry.key,
                    displayName: entry.value.name,
                    hostedDomain: hostedDomain.isEmpty || hostedDomain == "NO_HOSTED_DOMAIN" ? nil : hostedDomain,
                    userName: entry.value.userName,
                    isManaged: (entry.value.isManaged ?? 0) != 0,
                    gaiaName: entry.value.gaiaName,
                    appleScriptName: appleScriptName
                )
            }

            if !orderedDirectories.isEmpty {
                discoveredProfiles.sort { first, second in
                    let firstIndex = orderedDirectories.firstIndex(of: first.directory) ?? Int.max
                    let secondIndex = orderedDirectories.firstIndex(of: second.directory) ?? Int.max
                    if firstIndex == secondIndex {
                        return first.displayName < second.displayName
                    }
                    return firstIndex < secondIndex
                }
            } else {
                discoveredProfiles.sort { $0.displayName < $1.displayName }
            }

            DispatchQueue.main.async { [weak self] in
                self?.profiles = discoveredProfiles
                self?.lastUsedProfileDirectory = localState.profile.lastUsed
            }
        } catch {
            DeskJigLog.error(.chrome, "ChromeProfileManager: Failed to parse Local State – \(error.localizedDescription)")
            DispatchQueue.main.async { [weak self] in
                self?.profiles = []
                self?.lastUsedProfileDirectory = nil
            }
        }
    }
    
    /// Synchronously refresh and return profiles (blocks until parsing completes).
    ///
    /// - Important: When called off the main thread, the `@Published` properties
    ///   (`profiles`, `lastUsedProfileDirectory`) are updated **asynchronously** on the
    ///   main thread. Callers must consume the returned value and must not read the
    ///   published state right after this call. Use `refreshProfilesSyncWithLastUsed()`
    ///   when the last-used profile directory is also needed.
    /// - Note: Concurrent off-main refreshes publish their results in enqueue order on
    ///   the main queue, so the last enqueued refresh wins.
    public func refreshProfilesSync() -> [ChromeProfile] {
        refreshProfilesSyncWithLastUsed().profiles
    }

    /// Synchronously refresh and return profiles together with the last-used profile
    /// directory from Chrome's Local State. Same publishing semantics as
    /// `refreshProfilesSync()`: off-main, published state lands asynchronously, so
    /// callers must use the returned tuple rather than the `@Published` properties.
    func refreshProfilesSyncWithLastUsed() -> (profiles: [ChromeProfile], lastUsed: String?) {
        guard fileManager.fileExists(atPath: localStateURL.path) else {
            DeskJigLog.info(.chrome, "ChromeProfileManager: Local State file missing at \(localStateURL.path)")
            updateProfiles([], lastUsed: nil)
            return ([], nil)
        }

        do {
            let data = try Data(contentsOf: localStateURL)
            let decoder = JSONDecoder()
            let localState = try decoder.decode(LocalState.self, from: data)

            let orderedDirectories = localState.profile.profilesOrder ?? []
            var discoveredProfiles: [ChromeProfile] = localState.profile.infoCache.map { entry in
                let hostedDomain = (entry.value.hostedDomain ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                let appleScriptName = {
                    let hostedDomain = hostedDomain.isEmpty || hostedDomain == "NO_HOSTED_DOMAIN" ? nil : hostedDomain
                    if let gaiaName = entry.value.gaiaName, let hostedDomain {
                        let displayName = gaiaName.components(separatedBy: " ").first ?? gaiaName
                        return "\(displayName) (\(hostedDomain))"
                    } else if let hostedDomain {
                        return "\(entry.value.name) (\(hostedDomain))"
                    }
                    return entry.value.name
                }()
                return ChromeProfile(
                    directory: entry.key,
                    displayName: entry.value.name,
                    hostedDomain: hostedDomain.isEmpty || hostedDomain == "NO_HOSTED_DOMAIN" ? nil : hostedDomain,
                    userName: entry.value.userName,
                    isManaged: (entry.value.isManaged ?? 0) != 0,
                    gaiaName: entry.value.gaiaName,
                    appleScriptName: appleScriptName
                )
            }

            if !orderedDirectories.isEmpty {
                discoveredProfiles.sort { first, second in
                    let firstIndex = orderedDirectories.firstIndex(of: first.directory) ?? Int.max
                    let secondIndex = orderedDirectories.firstIndex(of: second.directory) ?? Int.max
                    if firstIndex == secondIndex {
                        return first.displayName < second.displayName
                    }
                    return firstIndex < secondIndex
                }
            } else {
                discoveredProfiles.sort { $0.displayName < $1.displayName }
            }

            updateProfiles(discoveredProfiles, lastUsed: localState.profile.lastUsed)

            return (discoveredProfiles, localState.profile.lastUsed)
        } catch {
            DeskJigLog.error(.chrome, "ChromeProfileManager: Failed to parse Local State – \(error.localizedDescription)")
            updateProfiles([], lastUsed: nil)
            return ([], nil)
        }
    }

    public func profile(forDirectory directory: String) -> ChromeProfile? {
        profiles.first(where: { $0.directory == directory })
    }

    public func profile(forAppleScriptName appleScriptName: String) -> ChromeProfile? {
        profiles.first(where: { $0.appleScriptName == appleScriptName })
    }

    public func defaultProfile() -> ChromeProfile? {
        if let lastUsedProfileDirectory,
           let profile = profile(forDirectory: lastUsedProfileDirectory) {
            return profile
        }
        return profiles.first
    }

    /// Publishes the given profiles on the main thread.
    ///
    /// Off-main callers dispatch asynchronously: blocking with `main.sync` here can
    /// deadlock if the main thread is simultaneously waiting on the calling queue.
    /// The documented contract of the sync refresh methods is that callers consume
    /// the returned values, never the `@Published` properties right after the call,
    /// so the published state does not need to land before returning.
    private func updateProfiles(_ profiles: [ChromeProfile], lastUsed: String?) {
        if Thread.isMainThread {
            self.profiles = profiles
            self.lastUsedProfileDirectory = lastUsed
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.profiles = profiles
                self?.lastUsedProfileDirectory = lastUsed
            }
        }
    }
}

extension ChromeProfileManager: ChromeProfileManagerProtocol {}

// MARK: - Local State Structures

private extension ChromeProfileManager {
    struct LocalState: Decodable {
        struct Profile: Decodable {
            struct Info: Decodable {
                let name: String
                let userName: String?
                let hostedDomain: String?
                let isManaged: Int?
                let gaiaName: String?

                private enum CodingKeys: String, CodingKey {
                    case name
                    case userName = "user_name"
                    case hostedDomain = "hosted_domain"
                    case isManaged = "is_managed"
                    case gaiaName = "gaia_name"
                }
            }

            let infoCache: [String: Info]
            let lastUsed: String?
            let profilesOrder: [String]?

            private enum CodingKeys: String, CodingKey {
                case infoCache = "info_cache"
                case lastUsed = "last_used"
                case profilesOrder = "profiles_order"
            }
        }

        let profile: Profile
    }
}
