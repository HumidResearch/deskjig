//  ChromeWindowMatcher.swift
//  DeskJigShared

import AppKit
import CoreGraphics
import Foundation

public enum ChromeWindowMatchMethod: String, Sendable {
    case chromeWindowId
    case axTitle
    case supplementationExact
    case supplementationBaseName
    case titleExact
    case titleBaseName
    case appleScriptBounds
    case tabUrlsSupplementation
    case tabUrlsCapture
    case noMatch
}

public struct ChromeWindowMatchResult: Sendable {
    public let window: SnapshotWindow?
    public let capture: ChromeAppleScriptWindowCapture?
    public let chromeWindowId: Int?
    public let method: ChromeWindowMatchMethod

    public init(
        window: SnapshotWindow?,
        capture: ChromeAppleScriptWindowCapture?,
        chromeWindowId: Int?,
        method: ChromeWindowMatchMethod
    ) {
        self.window = window
        self.capture = capture
        self.chromeWindowId = chromeWindowId
        self.method = method
    }
}

public struct ChromeTargetProfile: Sendable {
    public let storedProfileDirectory: String?
    public let storedHostedDomain: String?
    public let storedUserName: String?
    public let storedProfileName: String?
    public let resolvedProfileDirectory: String?
    public let profileDirectory: String?
    public let targetProfileName: String
    public let resolvedBy: String
    public let fallbackReason: String?

    public init(
        storedProfileDirectory: String?,
        storedHostedDomain: String?,
        storedUserName: String?,
        storedProfileName: String?,
        resolvedProfileDirectory: String?,
        targetProfileName: String,
        resolvedBy: String,
        fallbackReason: String? = nil
    ) {
        self.storedProfileDirectory = storedProfileDirectory
        self.storedHostedDomain = storedHostedDomain
        self.storedUserName = storedUserName
        self.storedProfileName = storedProfileName
        self.resolvedProfileDirectory = resolvedProfileDirectory
        self.profileDirectory = resolvedProfileDirectory
        self.targetProfileName = targetProfileName
        self.resolvedBy = resolvedBy
        self.fallbackReason = fallbackReason
    }

    public var shouldWarnAboutRemapOrFallback: Bool {
        if fallbackReason != nil {
            return true
        }
        if let storedProfileDirectory, let resolvedProfileDirectory {
            return storedProfileDirectory != resolvedProfileDirectory
        }
        return false
    }
}

public struct ChromeRaiseSelection: Sendable {
    public let window: SnapshotWindow
    public let method: String

    public init(window: SnapshotWindow, method: String) {
        self.window = window
        self.method = method
    }
}

public final class ChromeWindowMatcher {
    private let boundsTolerance: CGFloat = 10.0
    private let profileManager = ChromeProfileManager()

    private struct ChromeProfileContext {
        let otherProfileNames: Set<String>
        let profileCount: Int
    }

    public init() {}

    public func resolveTargetProfile(
        for chromeState: ChromeWindowState?,
        profiles: [ChromeProfile]? = nil,
        lastUsedProfileDirectory: String? = nil
    ) -> ChromeTargetProfile? {
        guard let chromeState else { return nil }
        if chromeState.profileMatchMode == .anyWindow {
            return nil
        }

        let storedDirectory = normalizedValue(chromeState.profileDirectory)
        let storedHostedDomain = normalizedValue(chromeState.profileHostedDomain)
        let storedUserName = normalizedValue(chromeState.profileUserName)
        let storedProfileName = normalizedValue(chromeState.appleScriptProfileName)
        // Use the refresh return value for lastUsed — the manager's @Published
        // properties are updated asynchronously when refreshed off-main (#476),
        // so reading them here would observe stale state.
        let resolvedProfiles: [ChromeProfile]
        let lastUsedDirectory: String?
        if let profiles {
            resolvedProfiles = profiles
            lastUsedDirectory = lastUsedProfileDirectory
        } else {
            let refreshed = profileManager.refreshProfilesSyncWithLastUsed()
            resolvedProfiles = refreshed.profiles
            lastUsedDirectory = lastUsedProfileDirectory ?? refreshed.lastUsed
        }
        let profiles = resolvedProfiles
        var fallbackReasons: [String] = []

        func targetName(for profile: ChromeProfile) -> String {
            profile.appleScriptName
        }

        func result(
            profile: ChromeProfile?,
            resolvedBy: String,
            fallbackReason: String? = nil,
            targetProfileNameOverride: String? = nil
        ) -> ChromeTargetProfile {
            let resolvedDirectory = profile?.directory
            let targetProfileName = targetProfileNameOverride ?? profile.map(targetName(for:)) ?? storedProfileName ?? ""
            return ChromeTargetProfile(
                storedProfileDirectory: storedDirectory,
                storedHostedDomain: storedHostedDomain,
                storedUserName: storedUserName,
                storedProfileName: storedProfileName,
                resolvedProfileDirectory: resolvedDirectory,
                targetProfileName: targetProfileName,
                resolvedBy: resolvedBy,
                fallbackReason: fallbackReason
            )
        }

        if let storedDirectory,
           let profile = profiles.first(where: { $0.directory == storedDirectory }) {
            return result(profile: profile, resolvedBy: "exactDirectory")
        }

        if storedDirectory != nil {
            fallbackReasons.append("stored-directory-not-found")
        }

        if let storedHostedDomain {
            let hostedDomainMatches = profiles.filter {
                normalizedValue($0.hostedDomain)?.caseInsensitiveCompare(storedHostedDomain) == .orderedSame
            }
            if hostedDomainMatches.count == 1, let match = hostedDomainMatches.first {
                return result(
                    profile: match,
                    resolvedBy: "uniqueHostedDomain",
                    fallbackReason: fallbackReasons.isEmpty ? nil : fallbackReasons.joined(separator: ",")
                )
            }
            if hostedDomainMatches.isEmpty {
                fallbackReasons.append("hosted-domain-not-found")
            } else {
                fallbackReasons.append("hosted-domain-ambiguous")
            }
        }

        if let storedUserName {
            let userNameMatches = profiles.filter {
                normalizedValue($0.userName)?.caseInsensitiveCompare(storedUserName) == .orderedSame
            }
            if userNameMatches.count == 1, let match = userNameMatches.first {
                return result(
                    profile: match,
                    resolvedBy: "uniqueUserName",
                    fallbackReason: fallbackReasons.isEmpty ? nil : fallbackReasons.joined(separator: ",")
                )
            }
            if userNameMatches.isEmpty {
                fallbackReasons.append("user-name-not-found")
            } else {
                fallbackReasons.append("user-name-ambiguous")
            }
        }

        let storedNameVariants = normalizedNameVariants(storedProfileName)
            .union(normalizedNameVariants(chromeState.profileDisplayName))
        if !storedNameVariants.isEmpty {
            let displayMatches = profiles.filter { profile in
                !storedNameVariants.isDisjoint(with: normalizedProfileNameVariants(profile))
            }
            if displayMatches.count == 1, let match = displayMatches.first {
                return result(
                    profile: match,
                    resolvedBy: "uniqueDisplayName",
                    fallbackReason: fallbackReasons.isEmpty ? nil : fallbackReasons.joined(separator: ",")
                )
            }
            if displayMatches.isEmpty {
                fallbackReasons.append("display-name-not-found")
            } else {
                fallbackReasons.append("display-name-ambiguous")
            }
        }

        if let fallback = defaultProfile(from: profiles, lastUsedDirectory: lastUsedDirectory) {
            return result(
                profile: fallback,
                resolvedBy: "defaultProfile",
                fallbackReason: fallbackReasons.isEmpty ? "no-unique-identity-match" : fallbackReasons.joined(separator: ",")
            )
        }

        if profiles.isEmpty {
            return result(
                profile: nil,
                resolvedBy: "anyProfileFallback",
                fallbackReason: fallbackReasons.isEmpty ? "no-local-profiles" : fallbackReasons.joined(separator: ",")
            )
        }

        return result(
            profile: profiles.first,
            resolvedBy: "anyProfileFallback",
            fallbackReason: fallbackReasons.isEmpty ? "no-default-profile" : fallbackReasons.joined(separator: ",")
        )
    }

    public func captureOpenWindows(includeTabURLs: Bool = false) -> [ChromeAppleScriptWindowCapture] {
        ChromeAutomationService.captureOpenWindows(includeTabURLs: includeTabURLs)
    }

    public static func formatCapturesForTrace(_ captures: [ChromeAppleScriptWindowCapture]) -> String {
        captures.map { formatCaptureForTrace($0) }.joined(separator: " | ")
    }

    private static func formatCaptureForTrace(_ capture: ChromeAppleScriptWindowCapture) -> String {
        let id = capture.chromeWindowId.map { "\($0)" } ?? "nil"
        let profile = capture.profileAppleScriptName ?? "nil"
        let activeIndex = capture.activeTabIndex.map { "\($0)" } ?? "nil"
        let title = truncateForTrace(capture.title)
        let bounds = String(
            format: "%.0f,%.0f %.0fx%.0f",
            capture.bounds.origin.x,
            capture.bounds.origin.y,
            capture.bounds.width,
            capture.bounds.height
        )
        let tabs = capture.tabURLs.map { ChromeAutomationService.formatURLForLog($0) }.joined(separator: ", ")
        return "id=\(id) profile=\(profile) active=\(activeIndex) bounds=\(bounds) title='\(title)' tabs=[\(tabs)]"
    }

    private static func truncateForTrace(_ value: String, limit: Int = 80) -> String {
        guard value.count > limit else { return value }
        let endIndex = value.index(value.startIndex, offsetBy: limit)
        return String(value[..<endIndex]) + "..."
    }

    public func matchExistingWindow(
        workspaceWindow: WorkspaceWindow,
        snapshot: SystemSnapshot,
        chromeCaptures: [ChromeAppleScriptWindowCapture],
        matchMethod: MatchMethod,
        taskContext: RestorationTaskContext,
        allowAppleScriptBounds: Bool = true,
        workspaceProfileDirectories: Set<String> = [],
        excludingWindowIds: Set<CGWindowID> = []
    ) -> ChromeWindowMatchResult {
        // Filter out zombie windows (exist in CGWindowList but not accessible via AX API)
        let chromeWindows = snapshot.windows.filter {
            $0.bundleId == workspaceWindow.bundleIdentifier &&
            $0.isAXAccessible != false &&
            !excludingWindowIds.contains($0.windowId)
        }
        let refreshed = profileManager.refreshProfilesSyncWithLastUsed()
        let profiles = refreshed.profiles
        let targetProfile = resolveTargetProfile(
            for: workspaceWindow.chromeState,
            profiles: profiles,
            lastUsedProfileDirectory: refreshed.lastUsed
        )
        let profileDisplayName = targetProfile?.targetProfileName ?? ""
        let storedProfileDir = normalizedValue(workspaceWindow.chromeState?.profileDirectory) ?? ""
        let resolvedProfileDir = targetProfile?.resolvedProfileDirectory ?? (storedProfileDir.isEmpty ? nil : storedProfileDir)
        let targetProfileDir = resolvedProfileDir ?? "Default"
        let storedHostedDomain = normalizedValue(workspaceWindow.chromeState?.profileHostedDomain)
        let urls = workspaceWindow.chromeState?.savedTabURLs ?? []
        let hasSupplementationData = chromeWindows.contains { $0.supplementationStatus == .completed }
        let workspaceProfileCount = workspaceProfileDirectories.isEmpty ? profiles.count : workspaceProfileDirectories.count
        let hasMultipleProfiles = workspaceProfileCount > 1
        let profileMatchMode = workspaceWindow.chromeState?.profileMatchMode ?? .specific
        let profileContext = chromeProfileContext(
            for: resolvedProfileDir ?? targetProfileDir,
            targetProfileName: profileDisplayName,
            profiles: profiles
        )
        let allowBoundsFallback = allowAppleScriptBounds && !hasMultipleProfiles
        let captureProfilesByDirectory = chromeCaptures.map { capture -> String in
            let name = capture.profileAppleScriptName ?? "nil"
            let directory = profiles.first(where: { $0.appleScriptName == name })?.directory ?? "unknown"
            return "\(name)->\(directory)"
        }

        DeskJigLog.debug(.restorationTrace, "Snapshot Chrome analysis", fields: ["taskId": taskContext.taskId, "taskType": taskContext.taskType.rawValue,
            "chromeWindowsInSnapshot": "\(chromeWindows.count)",
            "windowIds": chromeWindows.map { "\($0.windowId)" }.joined(separator: ","),
            "titles": chromeWindows.compactMap { $0.title }.joined(separator: "|"),
            "hasSupplementationData": "\(hasSupplementationData)",
            "supplementedProfiles": chromeWindows.compactMap { $0.chromeProfileFromTitle }.joined(separator: "|"),
            "targetProfileDir": targetProfileDir,
            "storedProfileDirectory": storedProfileDir.isEmpty ? "none" : storedProfileDir,
            "resolvedProfileDirectory": resolvedProfileDir ?? "none",
            "storedHostedDomain": storedHostedDomain ?? "none",
            "targetProfileDisplayName": profileDisplayName.isEmpty ? "none" : profileDisplayName,
            "resolvedBy": targetProfile?.resolvedBy ?? "none",
            "fallbackReason": targetProfile?.fallbackReason ?? "none",
            "storedProfileDisplayName": workspaceWindow.chromeState?.appleScriptProfileName ?? "none",
            "captureProfilesByDirectory": captureProfilesByDirectory.joined(separator: "|"),
            "profileCount": "\(profileContext.profileCount)",
            "workspaceProfileCount": "\(workspaceProfileCount)",
            "otherProfiles": profileContext.otherProfileNames.joined(separator: "|")
        ], runId: taskContext.runId)

        if profileDisplayName.isEmpty,
           profileMatchMode != .anyWindow,
           hasMultipleProfiles {
            DeskJigLog.debug(.restorationTrace, "Skipping Chrome match without resolved profile", fields: ["taskId": taskContext.taskId, "taskType": taskContext.taskType.rawValue,
                "profileMatchMode": profileMatchMode.rawValue,
                "profileCount": "\(workspaceProfileCount)"
            ], runId: taskContext.runId)
            return ChromeWindowMatchResult(
                window: nil,
                capture: nil,
                chromeWindowId: nil,
                method: .noMatch
            )
        }

        var matchedWindow: SnapshotWindow?
        var matchedCapture: ChromeAppleScriptWindowCapture?
        var matchedChromeWindowId: Int?
        var matchedMethod: ChromeWindowMatchMethod = .noMatch

        // PRIORITY 0: Match by Chrome internal window ID
        if matchMethod == .chromeWindowId,
           let targetChromeWindowId = workspaceWindow.chromeState?.chromeWindowId,
           let capture = chromeCaptures.first(where: { $0.chromeWindowId == targetChromeWindowId }) {
            matchedCapture = capture
            matchedChromeWindowId = capture.chromeWindowId
            matchedWindow = matchSnapshotWindow(for: capture, candidates: chromeWindows)

            if let matchedWindow {
                matchedMethod = .chromeWindowId
                DeskJigLog.debug(.restorationTrace, "Matched via chromeWindowId", fields: ["taskId": taskContext.taskId, "taskType": taskContext.taskType.rawValue,
                    "chromeWindowId": "\(targetChromeWindowId)",
                    "matchedWindowId": "\(matchedWindow.windowId)",
                    "captureTitle": capture.title
                ], runId: taskContext.runId)
            }
        }

        // PRIORITY 1: Match by AX profile to avoid stacked-window misassignment
        if matchedWindow == nil, !profileDisplayName.isEmpty {
            let axMatches = matchChromeWindowsByAxProfile(
                candidates: chromeWindows,
                profileDisplayName: profileDisplayName,
                otherProfileNames: profileContext.otherProfileNames,
                taskContext: taskContext
            )

            if axMatches.count == 1 {
                matchedWindow = axMatches[0]
                matchedMethod = .axTitle
                DeskJigLog.debug(.restorationTrace, "Profile matched via AX title", fields: ["taskId": taskContext.taskId, "taskType": taskContext.taskType.rawValue,
                    "matchedWindowId": "\(matchedWindow!.windowId)",
                    "matchMethod": "axTitle"
                ], runId: taskContext.runId)
            } else if axMatches.count > 1 {
                if let chromeState = workspaceWindow.chromeState,
                   let best = selectChromeCandidateByTabOverlap(
                    candidates: axMatches,
                    chromeState: chromeState,
                    chromeCaptures: chromeCaptures
                   ) {
                    matchedWindow = best
                    matchedMethod = .tabUrlsSupplementation
                    DeskJigLog.debug(.restorationTrace, "Multiple AX profile matches - using tab overlap", fields: ["taskId": taskContext.taskId, "taskType": taskContext.taskType.rawValue,
                        "candidateIds": axMatches.map { "\($0.windowId)" }.joined(separator: ","),
                        "selectedWindowId": "\(matchedWindow?.windowId ?? 0)"
                    ], runId: taskContext.runId)
                } else {
                    matchedWindow = axMatches.sorted { ($0.zOrderIndex ?? Int.max) < ($1.zOrderIndex ?? Int.max) }.first
                    matchedMethod = .axTitle
                    DeskJigLog.debug(.restorationTrace, "Multiple AX profile matches - using frontmost", fields: ["taskId": taskContext.taskId, "taskType": taskContext.taskType.rawValue,
                        "candidateIds": axMatches.map { "\($0.windowId)" }.joined(separator: ","),
                        "selectedWindowId": "\(matchedWindow?.windowId ?? 0)"
                    ], runId: taskContext.runId)
                }
            }
        }

        // If we matched, try to link AppleScript capture for tab operations
        if let matchedWindow, matchedCapture == nil {
            matchedCapture = findCapture(
                for: matchedWindow,
                in: chromeCaptures,
                targetProfile: profileDisplayName.isEmpty ? nil : profileDisplayName,
                profileContext: profileContext
            )
            matchedChromeWindowId = matchedCapture?.chromeWindowId
        }

        // PRIORITY 2: Use supplementation data (chromeProfileFromTitle) if available
        if matchedWindow == nil, hasSupplementationData, !profileDisplayName.isEmpty {
            matchedWindow = chromeWindows.first(where: { chromeWin in
                guard let extractedProfile = chromeWin.chromeProfileFromTitle else { return false }
                guard isSafeProfileName(extractedProfile, context: profileContext) else { return false }
                return extractedProfile == profileDisplayName
            })

            if matchedWindow == nil {
                let targetHasDomain = profileDisplayName.contains(" (")
                matchedWindow = chromeWindows.first { chromeWin in
                    guard let extractedProfile = chromeWin.chromeProfileFromTitle else { return false }
                    guard isSafeProfileName(extractedProfile, context: profileContext) else { return false }
                    let extractedHasDomain = extractedProfile.contains(" (")
                    if extractedHasDomain == targetHasDomain {
                        return false
                    }
                    let extractedBase = extractedProfile.components(separatedBy: " (").first ?? extractedProfile
                    let targetBase = profileDisplayName.components(separatedBy: " (").first ?? profileDisplayName
                    return extractedBase == targetBase
                }

                if let matchedWindow {
                    matchedMethod = .supplementationBaseName
                    DeskJigLog.debug(.restorationTrace, "Using base-name fallback (supplementation domain mismatch)", fields: ["taskId": taskContext.taskId, "taskType": taskContext.taskType.rawValue,
                        "matchedWindowId": "\(matchedWindow.windowId)",
                        "matchedProfile": matchedWindow.chromeProfileFromTitle ?? "unknown",
                        "targetProfile": profileDisplayName
                    ], runId: taskContext.runId)
                } else {
                    let allSupplementationFailed = chromeWindows.allSatisfy {
                        $0.supplementationStatus == .failed || $0.supplementationStatus == nil
                    }

                    if allSupplementationFailed {
                        matchedWindow = chromeWindows.first(where: { chromeWin in
                            guard let extractedProfile = chromeWin.chromeProfileFromTitle else { return false }
                            guard isSafeProfileName(extractedProfile, context: profileContext) else { return false }
                            let extractedBase = extractedProfile.components(separatedBy: " (").first ?? extractedProfile
                            let targetBase = profileDisplayName.components(separatedBy: " (").first ?? profileDisplayName
                            return extractedBase == targetBase
                        })

                        if let matchedWindow {
                            matchedMethod = .supplementationBaseName
                            DeskJigLog.debug(.restorationTrace, "Using base-name fallback (supplementation failed)", fields: ["taskId": taskContext.taskId, "taskType": taskContext.taskType.rawValue,
                                "matchedWindowId": "\(matchedWindow.windowId)",
                                "matchedProfile": matchedWindow.chromeProfileFromTitle ?? "unknown",
                                "targetProfile": profileDisplayName
                            ], runId: taskContext.runId)
                        }
                    }
                }
            }

            if let matchedWindow {
                matchedMethod = matchedMethod == .supplementationBaseName ? .supplementationBaseName : .supplementationExact
                DeskJigLog.debug(.restorationTrace, "Profile matched via supplementation data", fields: ["taskId": taskContext.taskId, "taskType": taskContext.taskType.rawValue,
                    "matchedWindowId": "\(matchedWindow.windowId)",
                    "matchedProfile": matchedWindow.chromeProfileFromTitle ?? "unknown",
                    "matchMethod": matchedMethod == .supplementationExact ? "exactMatch" : "baseNameFallback"
                ], runId: taskContext.runId)
            }
        }

        // PRIORITY 3: Fall back to CGWindowList title parsing
        if matchedWindow == nil {
            matchedWindow = chromeWindows.first(where: { chromeWin in
                guard !profileDisplayName.isEmpty else { return chromeWin.title != nil }
                guard let title = chromeWin.title else { return false }

                if title.hasSuffix(profileDisplayName) {
                    return true
                }

                if let extractedProfile = ChromeAutomationService.parseProfileName(from: title) {
                    guard isSafeProfileName(extractedProfile, context: profileContext) else { return false }
                    if extractedProfile == profileDisplayName {
                        return true
                    }
                }

                return false
            })

            if matchedWindow == nil {
                let allSupplementationFailed = chromeWindows.allSatisfy {
                    $0.supplementationStatus == .failed || $0.supplementationStatus == nil
                }

                if allSupplementationFailed {
                    matchedWindow = chromeWindows.first(where: { chromeWin in
                        guard !profileDisplayName.isEmpty else { return false }
                        guard let title = chromeWin.title else { return false }

                        if let extractedProfile = ChromeAutomationService.parseProfileName(from: title) {
                            guard isSafeProfileName(extractedProfile, context: profileContext) else { return false }
                            let extractedBase = extractedProfile.components(separatedBy: " (").first ?? extractedProfile
                            let targetBase = profileDisplayName.components(separatedBy: " (").first ?? profileDisplayName
                            return extractedBase == targetBase
                        }

                        return false
                    })
                }
            }

            if let matchedWindow {
                let title = matchedWindow.title ?? ""
                let extractedProfile = ChromeAutomationService.parseProfileName(from: title)
                let isExactMatch = title.hasSuffix(profileDisplayName) || extractedProfile == profileDisplayName
                matchedMethod = isExactMatch ? .titleExact : .titleBaseName
                DeskJigLog.debug(.restorationTrace, "Profile matched via title parsing", fields: ["taskId": taskContext.taskId, "taskType": taskContext.taskType.rawValue,
                    "matchedWindowId": "\(matchedWindow.windowId)",
                    "matchedTitle": title,
                    "matchMethod": isExactMatch ? "exactMatch" : "baseNameFallback"
                ], runId: taskContext.runId)
            }
        }

        // PRIORITY 4: Correlate AppleScript captures by bounds + title when profile match fails
        if matchedWindow == nil && !profileDisplayName.isEmpty && allowBoundsFallback {
            DeskJigLog.debug(.restorationTrace, "No profile match via supplementation/title, trying AppleScript bounds correlation", fields: ["taskId": taskContext.taskId, "taskType": taskContext.taskType.rawValue,
                "chromeWindowCount": "\(chromeWindows.count)",
                "targetProfileDir": targetProfileDir,
                "targetProfileDisplayName": profileDisplayName,
                "availableTitles": chromeWindows.compactMap { $0.title }.joined(separator: "|"),
                "supplementedProfiles": chromeWindows.compactMap { $0.chromeProfileFromTitle }.joined(separator: "|"),
                "hasSupplementationData": "\(hasSupplementationData)",
                "appleScriptCapturesCount": "\(chromeCaptures.count)"
            ], runId: taskContext.runId)

            if let capture = chromeCaptures.first(where: { $0.profileAppleScriptName == profileDisplayName }) {
                let boundsMatchingWindows = chromeWindows.filter { snapshotWindow in
                    abs(snapshotWindow.frame.origin.x - capture.bounds.origin.x) <= boundsTolerance &&
                    abs(snapshotWindow.frame.origin.y - capture.bounds.origin.y) <= boundsTolerance &&
                    abs(snapshotWindow.frame.width - capture.bounds.width) <= boundsTolerance &&
                    abs(snapshotWindow.frame.height - capture.bounds.height) <= boundsTolerance
                }

                DeskJigLog.debug(.restorationTrace, "AppleScript bounds candidates", fields: ["taskId": taskContext.taskId, "taskType": taskContext.taskType.rawValue,
                    "captureTitle": capture.title,
                    "captureProfile": capture.profileAppleScriptName ?? "nil",
                    "candidateCount": "\(boundsMatchingWindows.count)",
                    "candidateIds": boundsMatchingWindows.map { "\($0.windowId)" }.joined(separator: ","),
                    "candidateTitles": boundsMatchingWindows.compactMap { $0.title }.joined(separator: "|")
                ], runId: taskContext.runId)

                if boundsMatchingWindows.count == 1 {
                    matchedWindow = boundsMatchingWindows.first
                } else if boundsMatchingWindows.count > 1 {
                    let capturePageTitle = capturePageTitle(capture)

                    matchedWindow = boundsMatchingWindows.first(where: { snapshotWindow in
                        guard let snapshotTitle = snapshotWindow.title else { return false }
                        return snapshotTitle.hasPrefix(capturePageTitle)
                    })

                    if matchedWindow == nil {
                        matchedWindow = boundsMatchingWindows.first(where: { snapshotWindow in
                            guard let snapshotTitle = snapshotWindow.title else { return false }
                            let snapshotPageTitle = snapshotTitle.components(separatedBy: " - Google Chrome").first ?? snapshotTitle
                            return snapshotPageTitle == capturePageTitle ||
                                capturePageTitle.contains(snapshotPageTitle) ||
                                snapshotPageTitle.contains(capturePageTitle)
                        })
                    }

                    if let matchedWindow {
                        DeskJigLog.debug(.restorationTrace, "Disambiguated by title", fields: ["taskId": taskContext.taskId, "taskType": taskContext.taskType.rawValue,
                            "capturePageTitle": capturePageTitle,
                            "matchedWindowId": "\(matchedWindow.windowId)",
                            "matchedTitle": matchedWindow.title ?? "nil"
                        ], runId: taskContext.runId)
                    } else {
                        DeskJigLog.debug(.restorationTrace, "WARN: Could not disambiguate by title, multiple windows with same bounds", fields: ["taskId": taskContext.taskId, "taskType": taskContext.taskType.rawValue,
                            "capturePageTitle": capturePageTitle,
                            "candidateTitles": boundsMatchingWindows.compactMap { $0.title }.joined(separator: "|")
                        ], runId: taskContext.runId)
                    }
                }

                if let matchedWindow {
                    matchedCapture = capture
                    matchedChromeWindowId = capture.chromeWindowId
                    matchedMethod = .appleScriptBounds
                    DeskJigLog.debug(.restorationTrace, "Matched via AppleScript bounds+title correlation", fields: ["taskId": taskContext.taskId, "taskType": taskContext.taskType.rawValue,
                        "profile": profileDisplayName,
                        "matchedWindowId": "\(matchedWindow.windowId)",
                        "chromeWindowId": "\(capture.chromeWindowId ?? -1)",
                        "captureTitle": capture.title,
                        "matchedTitle": matchedWindow.title ?? "nil"
                    ], runId: taskContext.runId)
                } else {
                    DeskJigLog.debug(.restorationTrace, "AppleScript capture found but no bounds match in snapshot", fields: ["taskId": taskContext.taskId, "taskType": taskContext.taskType.rawValue,
                        "profile": profileDisplayName,
                        "captureBounds": "\(Int(capture.bounds.origin.x)),\(Int(capture.bounds.origin.y)) \(Int(capture.bounds.width))x\(Int(capture.bounds.height))",
                        "snapshotWindowBounds": chromeWindows.map { "\(Int($0.frame.origin.x)),\(Int($0.frame.origin.y))" }.joined(separator: "|")
                    ], runId: taskContext.runId)
                }
            } else {
                DeskJigLog.debug(.restorationTrace, "No AppleScript capture found for profile", fields: ["taskId": taskContext.taskId, "taskType": taskContext.taskType.rawValue,
                    "targetProfile": profileDisplayName,
                    "availableProfiles": chromeCaptures.compactMap { $0.profileAppleScriptName }.joined(separator: "|")
                ], runId: taskContext.runId)
            }
        }

        if matchedWindow == nil && !profileDisplayName.isEmpty {
            DeskJigLog.debug(.restorationTrace, "FAILED: No profile match after all attempts", fields: ["taskId": taskContext.taskId, "taskType": taskContext.taskType.rawValue,
                "error": "NO_PROFILE_MATCH"
            ], runId: taskContext.runId)
        }

        // PHASE 2: Tab URL matching fallback when profile matching fails
        let hasProfileRequirement = !profileDisplayName.isEmpty
        let allowTabUrlMatching = matchMethod == .chromeTabUrls || !hasProfileRequirement

        if matchedWindow == nil && !urls.isEmpty && allowTabUrlMatching {
            DeskJigLog.debug(.restorationTrace, "Trying tab URL matching", fields: ["taskId": taskContext.taskId, "taskType": taskContext.taskType.rawValue,
                "savedTabCount": "\(urls.count)",
                "savedUrls": urls.prefix(3).joined(separator: " | ")
            ], runId: taskContext.runId)

            if hasSupplementationData {
                for chromeWin in chromeWindows {
                    guard let windowTabUrls = chromeWin.chromeTabUrls, !windowTabUrls.isEmpty else { continue }

                    let matchingTabs = urls.filter { savedUrl in
                        windowTabUrls.contains { capturedUrl in
                            ChromeAutomationService.urlsAreEquivalent(savedUrl, capturedUrl)
                        }
                    }

                    let matchRatio = Double(matchingTabs.count) / Double(urls.count)

                    if matchRatio > 0.5 {
                        matchedWindow = chromeWin
                        matchedMethod = .tabUrlsSupplementation
                        DeskJigLog.debug(.restorationTrace, "Tab URL match found (via supplementation)", fields: ["taskId": taskContext.taskId, "taskType": taskContext.taskType.rawValue,
                            "matchingTabs": "\(matchingTabs.count)/\(urls.count)",
                            "matchRatio": "\(Int(matchRatio * 100))%",
                            "windowId": "\(chromeWin.windowId)",
                            "matchMethod": "supplementationTabUrls"
                        ], runId: taskContext.runId)
                        break
                    }
                }
            }

            if matchedWindow == nil {
                let chromeCapturesFallback = chromeCaptures

                DeskJigLog.debug(.restorationTrace, "Trying chromeCaptures fallback", fields: ["taskId": taskContext.taskId, "taskType": taskContext.taskType.rawValue,
                    "capturesAvailable": "\(chromeCapturesFallback.count)"
                ], runId: taskContext.runId)

                for capture in chromeCapturesFallback {
                    let capturedUrls = capture.tabURLs
                    guard !capturedUrls.isEmpty else { continue }

                    let matchingTabs = urls.filter { savedUrl in
                        capturedUrls.contains { capturedUrl in
                            ChromeAutomationService.urlsAreEquivalent(savedUrl, capturedUrl)
                        }
                    }

                    let matchRatio = Double(matchingTabs.count) / Double(urls.count)

                    if matchRatio > 0.5 {
                        if let matchedChromeWindow = matchSnapshotWindow(for: capture, candidates: chromeWindows) {
                            matchedWindow = matchedChromeWindow
                            matchedCapture = capture
                            matchedChromeWindowId = capture.chromeWindowId
                            matchedMethod = .tabUrlsCapture
                            DeskJigLog.debug(.restorationTrace, "Tab URL match found (via chromeCaptures)", fields: ["taskId": taskContext.taskId, "taskType": taskContext.taskType.rawValue,
                                "matchingTabs": "\(matchingTabs.count)/\(urls.count)",
                                "matchRatio": "\(Int(matchRatio * 100))%",
                                "captureProfile": capture.profileAppleScriptName ?? "unknown",
                                "chromeWindowId": "\(capture.chromeWindowId ?? -1)",
                                "windowId": "\(matchedChromeWindow.windowId)",
                                "matchMethod": "chromeCapturesTabUrls"
                            ], runId: taskContext.runId)
                            break
                        }
                    }
                }
            }

            if matchedWindow == nil {
                let chromeCapturesFallback = snapshot.chromeCaptures

                DeskJigLog.debug(.restorationTrace, "Trying snapshot chromeCaptures fallback", fields: ["taskId": taskContext.taskId, "taskType": taskContext.taskType.rawValue,
                    "capturesAvailable": "\(chromeCapturesFallback.count)"
                ], runId: taskContext.runId)

                if !chromeCapturesFallback.isEmpty {
                    var chromeWindowsByChromeId: [Int: SnapshotWindow] = [:]
                    var chromeCapturesByChromeId: [Int: ChromeAppleScriptWindowCapture] = [:]

                    for capture in chromeCaptures {
                        guard let chromeWindowId = capture.chromeWindowId else { continue }
                        chromeCapturesByChromeId[chromeWindowId] = capture
                        if let mappedWindow = matchSnapshotWindow(for: capture, candidates: chromeWindows) {
                            chromeWindowsByChromeId[chromeWindowId] = mappedWindow
                        }
                    }

                    for capture in chromeCapturesFallback {
                        let capturedUrls = capture.tabUrls
                        guard !capturedUrls.isEmpty else { continue }

                        let matchingTabs = urls.filter { savedUrl in
                            capturedUrls.contains { capturedUrl in
                                ChromeAutomationService.urlsAreEquivalent(savedUrl, capturedUrl)
                            }
                        }

                        let matchRatio = Double(matchingTabs.count) / Double(urls.count)

                        if matchRatio > 0.5,
                           let matchedChromeWindow = chromeWindowsByChromeId[capture.chromeWindowId] {
                            matchedWindow = matchedChromeWindow
                            matchedCapture = chromeCapturesByChromeId[capture.chromeWindowId]
                            matchedChromeWindowId = capture.chromeWindowId
                            matchedMethod = .tabUrlsCapture
                            DeskJigLog.debug(.restorationTrace, "Tab URL match found (via snapshot chromeCaptures)", fields: ["taskId": taskContext.taskId, "taskType": taskContext.taskType.rawValue,
                                "matchingTabs": "\(matchingTabs.count)/\(urls.count)",
                                "matchRatio": "\(Int(matchRatio * 100))%",
                                "captureProfile": capture.profileName,
                                "chromeWindowId": "\(capture.chromeWindowId)",
                                "windowId": "\(matchedChromeWindow.windowId)",
                                "matchMethod": "chromeCapturesTabUrls"
                            ], runId: taskContext.runId)
                            break
                        }
                    }
                }
            }

            if matchedWindow != nil {
                DeskJigLog.debug(.restorationTrace, "Profile match result (via tab URLs)", fields: ["taskId": taskContext.taskId, "taskType": taskContext.taskType.rawValue,
                    "foundMatch": "true",
                    "matchMethod": matchedMethod == .tabUrlsSupplementation ? "supplementationTabUrls" : "chromeCapturesTabUrls"
                ], runId: taskContext.runId)
            }
        } else if matchedWindow == nil && !urls.isEmpty && hasProfileRequirement {
            DeskJigLog.debug(.restorationTrace, "Skipping tab URL matching (profile required but not matched)", fields: ["taskId": taskContext.taskId, "taskType": taskContext.taskType.rawValue,
                "targetProfile": profileDisplayName.isEmpty ? "none" : profileDisplayName,
                "reason": "Tab URLs could match wrong profile"
            ], runId: taskContext.runId)
        }

        let hasProfileTarget = !profileDisplayName.isEmpty
        let matchMethodLabel = matchedWindow != nil
            ? (hasProfileTarget ? "profileDisplayNameMatch" : "noProfileRequired")
            : "noMatch"
        DeskJigLog.debug(.restorationTrace, "Profile match result", fields: ["taskId": taskContext.taskId, "taskType": taskContext.taskType.rawValue,
            "foundMatch": "\(matchedWindow != nil)",
            "matchedWindowId": matchedWindow.map { "\($0.windowId)" } ?? "none",
            "matchedTitle": matchedWindow?.title ?? "none",
            "targetProfile": profileDisplayName.isEmpty ? "none" : profileDisplayName,
            "matchMethod": matchMethodLabel
        ], runId: taskContext.runId)

        return ChromeWindowMatchResult(
            window: matchedWindow,
            capture: matchedCapture,
            chromeWindowId: matchedChromeWindowId,
            method: matchedMethod
        )
    }

    public func selectPostLaunchCapture(
        from captures: [ChromeAppleScriptWindowCapture],
        preLaunchCaptures: [ChromeAppleScriptWindowCapture],
        targetProfile: String?,
        profileDirectory: String?,
        taskContext: RestorationTaskContext
    ) -> ChromeAppleScriptWindowCapture? {
        let preLaunchIds = Set(preLaunchCaptures.compactMap { $0.chromeWindowId })
        let profileContext = chromeProfileContext(for: profileDirectory, targetProfileName: targetProfile)
        let profileCandidates: [ChromeAppleScriptWindowCapture]
        let profileMatchMethod: String

        if let targetProfile, !targetProfile.isEmpty {
            let exactMatches = captures.filter { capture in
                guard let profile = capture.profileAppleScriptName else { return false }
                guard isSafeProfileName(profile, context: profileContext) else { return false }
                return profile == targetProfile
            }
            if !exactMatches.isEmpty {
                profileCandidates = exactMatches
                profileMatchMethod = "exact"
            } else {
                let targetHasDomain = targetProfile.contains(" (")
                let baseMatches = captures.filter { capture in
                    guard let profile = capture.profileAppleScriptName else { return false }
                    guard isSafeProfileName(profile, context: profileContext) else { return false }
                    let profileHasDomain = profile.contains(" (")
                    if profileHasDomain == targetHasDomain {
                        return false
                    }
                    let profileBase = profile.components(separatedBy: " (").first ?? profile
                    let targetBase = targetProfile.components(separatedBy: " (").first ?? targetProfile
                    return profileBase == targetBase
                }
                profileCandidates = baseMatches
                profileMatchMethod = baseMatches.isEmpty ? "none" : "baseName"
            }
        } else {
            profileCandidates = captures
            profileMatchMethod = "any"
        }

        let newCandidates = profileCandidates.filter { capture in
            guard let chromeWindowId = capture.chromeWindowId else { return true }
            return !preLaunchIds.contains(chromeWindowId)
        }

        let selected = newCandidates.first ?? profileCandidates.first

        DeskJigLog.debug(.restorationTrace, "Post-launch Chrome capture selection", fields: ["taskId": taskContext.taskId, "taskType": taskContext.taskType.rawValue,
            "captureCount": "\(captures.count)",
            "profileCandidates": "\(profileCandidates.count)",
            "newCandidates": "\(newCandidates.count)",
            "selectedProfile": selected?.profileAppleScriptName ?? "none",
            "selectedChromeWindowId": selected?.chromeWindowId.map { "\($0)" } ?? "none",
            "profileMatchMethod": profileMatchMethod
        ], runId: taskContext.runId)

        return selected
    }

    public func matchSnapshotWindow(
        for capture: ChromeAppleScriptWindowCapture,
        candidates: [SnapshotWindow]
    ) -> SnapshotWindow? {
        let pageTitle = capturePageTitle(capture)
        let titleMatches = candidates.filter { candidate in
            guard let title = candidate.title else { return false }
            return title.hasPrefix(pageTitle) || pageTitle.hasPrefix(title)
        }

        if titleMatches.count == 1 {
            return titleMatches[0]
        }

        if titleMatches.count > 1 {
            if let boundsMatch = titleMatches.first(where: { framesMatch($0.frame, capture.bounds) }) {
                return boundsMatch
            }

            return titleMatches.sorted { ($0.zOrderIndex ?? Int.max) < ($1.zOrderIndex ?? Int.max) }.first
        }

        let boundsMatches = candidates.filter { framesMatch($0.frame, capture.bounds) }
        if boundsMatches.count == 1 {
            return boundsMatches[0]
        }

        if boundsMatches.count > 1 {
            return boundsMatches.sorted { ($0.zOrderIndex ?? Int.max) < ($1.zOrderIndex ?? Int.max) }.first
        }

        return nil
    }

    public func resolveHandle(
        snapshotWindow: SnapshotWindow,
        chromeState: ChromeWindowState?
    ) -> WindowHandle? {
        if let axTitle = snapshotWindow.freshAxTitle {
            if let handle = Window.find(processID: snapshotWindow.pid, title: axTitle, filter: .all) {
                return handle
            }
        }

        let bundleId = snapshotWindow.bundleId ?? "com.google.Chrome"
        let chromeHandles = Window.allAcrossProcesses(forBundleID: bundleId, filter: .all)
        guard !chromeHandles.isEmpty else { return nil }

        let profileDisplayName = resolveTargetProfile(for: chromeState)?.targetProfileName ?? ""
        var candidates = chromeHandles

        if !profileDisplayName.isEmpty {
            let profileMatches = chromeHandles.filter { handle in
                guard let title = handle.title else { return false }
                guard let profile = ChromeAutomationService.parseProfileName(from: title) else { return false }
                return profile == profileDisplayName
            }

            if !profileMatches.isEmpty {
                candidates = profileMatches
            }
        }

        if let pageTitle = snapshotWindow.title, !pageTitle.isEmpty {
            if let match = candidates.first(where: { $0.title?.contains(pageTitle) == true }) {
                return match
            }
        }

        if candidates.count == 1 {
            return candidates[0]
        }

        return candidates.first
    }

    public func selectRaiseCandidate(
        candidates: [SnapshotWindow],
        chromeState: ChromeWindowState
    ) -> ChromeRaiseSelection? {
        guard !candidates.isEmpty else { return nil }

        let profileDisplayName = chromeState.appleScriptProfileName
        let profileMatches = candidates.filter { candidate in
            if profileDisplayName.isEmpty {
                return true
            }

            let profile = candidate.chromeProfileFromTitle ??
                candidate.freshAxTitle.flatMap { ChromeAutomationService.parseProfileName(from: $0) }
            return profile == profileDisplayName
        }

        guard !profileMatches.isEmpty else { return nil }

        if profileMatches.count == 1 {
            let method = profileDisplayName.isEmpty ? "chromeAnyWindow" : "chromeProfileFromTitle"
            return ChromeRaiseSelection(window: profileMatches[0], method: method)
        }

        if let best = selectChromeCandidateByTabOverlap(
            candidates: profileMatches,
            chromeState: chromeState
        ) {
            return ChromeRaiseSelection(window: best, method: "chromeTabOverlap")
        }

        let frontmost = profileMatches.sorted {
            ($0.zOrderIndex ?? Int.max) < ($1.zOrderIndex ?? Int.max)
        }.first!
        let method = profileDisplayName.isEmpty ? "chromeAnyWindowFrontmost" : "chromeProfileFrontmost"
        return ChromeRaiseSelection(window: frontmost, method: method)
    }

    public func matchWindowsByAxProfileForRaise(
        candidates: [SnapshotWindow],
        profileDisplayName: String
    ) -> [SnapshotWindow] {
        var matches: [SnapshotWindow] = []

        for candidate in candidates {
            guard let handle = Window.find(
                windowId: candidate.windowId,
                axMatchStrategy: .frameAndTitle,
                filter: .all
            ),
            let title = handle.title,
            let profile = ChromeAutomationService.parseProfileName(from: title) else {
                continue
            }

            if profile == profileDisplayName {
                matches.append(candidate)
            }
        }

        return matches
    }

    public func matchFallbackProfileWindow(
        candidates: [SnapshotWindow],
        profileDisplayName: String
    ) -> SnapshotWindow? {
        guard !profileDisplayName.isEmpty else { return nil }

        if let byTitle = candidates.first(where: { candidate in
            guard let title = candidate.title else { return false }
            let profileSuffix = " - \(profileDisplayName)"
            let profileWithDomainPattern = " - \(profileDisplayName) ("
            return title.hasSuffix(profileDisplayName) ||
                title.contains(profileSuffix + " (") ||
                (title.contains(profileSuffix) && !title.contains(profileWithDomainPattern.dropLast()))
        }) {
            return byTitle
        }

        return candidates.first { $0.chromeProfileFromTitle == profileDisplayName }
    }

    private func matchChromeWindowsByAxProfile(
        candidates: [SnapshotWindow],
        profileDisplayName: String,
        otherProfileNames: Set<String>,
        taskContext: RestorationTaskContext
    ) -> [SnapshotWindow] {
        var matches: [SnapshotWindow] = []

        for candidate in candidates {
            let profile = candidate.chromeProfileFromTitle ??
                candidate.freshAxTitle.flatMap { ChromeAutomationService.parseProfileName(from: $0) }
            if let profile, otherProfileNames.contains(profile) {
                continue
            }
            if profile == profileDisplayName {
                matches.append(candidate)
            }
        }

        if !matches.isEmpty {
            DeskJigLog.debug(.restorationTrace, "AX profile candidates", fields: ["taskId": taskContext.taskId, "taskType": taskContext.taskType.rawValue,
                "profile": profileDisplayName,
                "candidateIds": matches.map { "\($0.windowId)" }.joined(separator: ",")
            ], runId: taskContext.runId)
        }

        return matches
    }

    private func findCapture(
        for window: SnapshotWindow,
        in captures: [ChromeAppleScriptWindowCapture],
        targetProfile: String?,
        profileContext: ChromeProfileContext
    ) -> ChromeAppleScriptWindowCapture? {
        if let targetProfile, !targetProfile.isEmpty {
            let profileMatches = captures.filter { capture in
                guard let profile = capture.profileAppleScriptName else { return false }
                guard isSafeProfileName(profile, context: profileContext) else { return false }
                return profile == targetProfile
            }
            if profileMatches.count == 1 {
                return profileMatches[0]
            }

            if profileMatches.count > 1, let title = window.title {
                let titleMatches = profileMatches.filter { capture in
                    let pageTitle = capturePageTitle(capture)
                    return title.hasPrefix(pageTitle) || pageTitle.hasPrefix(title)
                }

                if titleMatches.count == 1 {
                    return titleMatches[0]
                }

                if let boundsMatch = profileMatches.first(where: { framesMatch(window.frame, $0.bounds) }) {
                    return boundsMatch
                }

                return titleMatches.first ?? profileMatches.first
            }
        }

        let candidateCaptures: [ChromeAppleScriptWindowCapture]
        if let targetProfile, !targetProfile.isEmpty {
            candidateCaptures = captures.filter { capture in
                guard let profile = capture.profileAppleScriptName else { return true }
                return isSafeProfileName(profile, context: profileContext)
            }
        } else {
            candidateCaptures = captures
        }

        guard let title = window.title, !candidateCaptures.isEmpty else { return nil }

        let titleMatches = candidateCaptures.filter { capture in
            let pageTitle = capturePageTitle(capture)
            return title.hasPrefix(pageTitle) || pageTitle.hasPrefix(title)
        }

        if titleMatches.count == 1 {
            return titleMatches[0]
        }

        if titleMatches.count > 1 {
            return titleMatches.first(where: { framesMatch(window.frame, $0.bounds) }) ?? titleMatches.first
        }

        let boundsMatches = candidateCaptures.filter { framesMatch(window.frame, $0.bounds) }
        if boundsMatches.count == 1 {
            return boundsMatches[0]
        }

        return boundsMatches.first
    }

    private func chromeProfileContext(
        for profileDirectory: String?,
        targetProfileName: String? = nil,
        profiles: [ChromeProfile]? = nil
    ) -> ChromeProfileContext {
        let profiles = profiles ?? profileManager.refreshProfilesSync()
        if let profileDirectory, !profileDirectory.isEmpty,
           profiles.contains(where: { $0.directory == profileDirectory }) {
            let otherProfileNames = Set(profiles.filter { $0.directory != profileDirectory }.map { $0.appleScriptName })
            return ChromeProfileContext(otherProfileNames: otherProfileNames, profileCount: profiles.count)
        }

        if let targetProfileName, !targetProfileName.isEmpty {
            let otherProfileNames = Set(profiles.filter { $0.appleScriptName != targetProfileName }.map { $0.appleScriptName })
            return ChromeProfileContext(otherProfileNames: otherProfileNames, profileCount: profiles.count)
        }

        return ChromeProfileContext(otherProfileNames: [], profileCount: profiles.count)
    }

    private func isSafeProfileName(_ profileName: String, context: ChromeProfileContext) -> Bool {
        !context.otherProfileNames.contains(profileName)
    }

    private func capturePageTitle(_ capture: ChromeAppleScriptWindowCapture) -> String {
        if let range = capture.title.range(of: " - Google Chrome") {
            return String(capture.title[..<range.lowerBound])
        }
        return capture.title
    }

    private func framesMatch(_ frame1: CGRect, _ frame2: CGRect) -> Bool {
        frame1.approximatelyEquals(frame2, tolerance: boundsTolerance)
    }

    private func selectChromeCandidateByTabOverlap(
        candidates: [SnapshotWindow],
        chromeState: ChromeWindowState,
        chromeCaptures: [ChromeAppleScriptWindowCapture] = []
    ) -> SnapshotWindow? {
        let savedUrls = chromeState.savedTabURLs
        guard !savedUrls.isEmpty else { return nil }

        var captureByWindowId: [CGWindowID: ChromeAppleScriptWindowCapture] = [:]
        if !chromeCaptures.isEmpty {
            for capture in chromeCaptures {
                if let matched = matchSnapshotWindow(for: capture, candidates: candidates) {
                    captureByWindowId[matched.windowId] = capture
                }
            }
        }
        var bestMatch: (window: SnapshotWindow, score: Int)?

        for candidate in candidates {
            let urls: [String]
            if let candidateUrls = candidate.chromeTabUrls, !candidateUrls.isEmpty {
                urls = candidateUrls
            } else if let capture = captureByWindowId[candidate.windowId], !capture.tabURLs.isEmpty {
                urls = capture.tabURLs
            } else {
                continue
            }

            let score = urls.filter { candidateUrl in
                savedUrls.contains { savedUrl in
                    ChromeAutomationService.urlsAreEquivalent(savedUrl, candidateUrl)
                }
            }.count
            if score == 0 { continue }

            if bestMatch == nil || score > bestMatch!.score {
                bestMatch = (candidate, score)
            }
        }

        return bestMatch?.window
    }

    /// - Parameter lastUsedDirectory: The last-used profile directory as returned by the
    ///   refresh that produced `profiles`. Deliberately not read from the manager's
    ///   @Published `lastUsedProfileDirectory`, which is published asynchronously and can
    ///   be stale on off-main restoration paths (#476).
    private func defaultProfile(from profiles: [ChromeProfile], lastUsedDirectory: String?) -> ChromeProfile? {
        if let lastUsed = normalizedValue(lastUsedDirectory),
           let byLastUsed = profiles.first(where: { $0.directory == lastUsed }) {
            return byLastUsed
        }
        return profiles.first
    }

    private func normalizedValue(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != "NO_HOSTED_DOMAIN" else { return nil }
        return trimmed
    }

    private func normalizedNameVariants(_ value: String?) -> Set<String> {
        guard let normalized = normalizedValue(value) else { return [] }
        let lower = normalized.lowercased()
        let base = lower.components(separatedBy: " (").first?.trimmingCharacters(in: .whitespacesAndNewlines) ?? lower
        if base.isEmpty || base == lower {
            return [lower]
        }
        return [lower, base]
    }

    private func normalizedProfileNameVariants(_ profile: ChromeProfile) -> Set<String> {
        normalizedNameVariants(profile.displayName)
            .union(normalizedNameVariants(profile.appleScriptDisplayName))
            .union(normalizedNameVariants(profile.appleScriptName))
            .union(normalizedNameVariants(profile.gaiaName))
    }

}

