//  ChromeSupplementationService.swift
//  DeskJigShared

import Foundation
import AppKit
import CoreGraphics

// MARK: - Chrome Fetch Method

/// Method for fetching Chrome tab URLs during supplementation
public enum ChromeFetchMethod: String, Sendable, CaseIterable {
    /// Use AppleScript to fetch tabs (~200ms, reliable, no extension needed)
    case appleScript
    /// Use Native Extension messaging (~50ms, faster, requires extension connected)
    case nativeExtension
    /// Try native extension first, fall back to AppleScript
    case both
    /// Skip supplementation entirely (use existing snapshot data only)
    case disabled
}

// MARK: - Supplementation Result

/// Result of Chrome window supplementation
public struct ChromeSupplementationResult: Sendable {
    /// Number of Chrome windows that were enriched
    public let enrichedCount: Int
    /// Number of Chrome windows that failed supplementation
    public let failedCount: Int
    /// Total time taken in milliseconds
    public let durationMs: Int
    /// Method used for tab URL fetching
    public let method: ChromeFetchMethod
    /// Notes about the supplementation process
    public let notes: [String]

    public init(
        enrichedCount: Int,
        failedCount: Int,
        durationMs: Int,
        method: ChromeFetchMethod,
        notes: [String] = []
    ) {
        self.enrichedCount = enrichedCount
        self.failedCount = failedCount
        self.durationMs = durationMs
        self.method = method
        self.notes = notes
    }
}

// MARK: - Chrome Supplementation Service

/// Actor that enriches Chrome windows in a snapshot with profile and tab data.
///
/// Chrome windows in quick CGWindowList captures lack profile information (only tab titles).
/// This service fetches fresh AX titles (which include profile names) and correlates
/// tab URLs from AppleScript or Native Extension for better profile matching.
///
/// ## Usage
/// ```swift
/// let service = ChromeSupplementationService()
/// let enrichedSnapshot = await service.supplementChromeWindows(
///     in: snapshot,
///     method: .appleScript,
///     runId: "restore-123"
/// )
/// ```
public actor ChromeSupplementationService {

    // MARK: - Constants

    /// Chrome bundle identifier
    private let chromeBundleId = "com.google.Chrome"

    /// Tolerance for frame matching between AX/AppleScript windows and CGWindowList
    /// Increased from 10px to 30px to account for coordinate system differences
    private let frameTolerance: CGFloat = 30.0

    private let osascriptTimeout: TimeInterval = 6.0

    // MARK: - Dependencies

    /// AX access used to resolve Chrome's PID and enumerate its windows.
    /// Injected with a default so production call sites stay unchanged while
    /// tests can supply a mock; methods must use this property instead of
    /// referencing `AXWindowService.shared` directly (#481).
    private let axService: AXWindowEnumerating

    // MARK: - Initialization

    public init(axService: AXWindowEnumerating = AXWindowService.shared) {
        self.axService = axService
    }

    // MARK: - Public API

    /// Supplement Chrome windows in a snapshot with profile and tab data.
    ///
    /// - Parameters:
    ///   - snapshot: The system snapshot containing Chrome windows to enrich
    ///   - method: Method to use for fetching tab URLs
    ///   - includeTabUrls: When false, skips tab URL fetching and only enriches with AX titles/profile names.
    ///   - runId: Restoration run ID for logging
    /// - Returns: A new snapshot with enriched Chrome windows
    public func supplementChromeWindows(
        in snapshot: SystemSnapshot,
        method: ChromeFetchMethod,
        includeTabUrls: Bool = true,
        runId: String
    ) async -> SystemSnapshot {
        let startTime = Date()

        // Find Chrome windows in snapshot
        let chromeWindows = snapshot.windows.filter { $0.bundleId == chromeBundleId }

        guard !chromeWindows.isEmpty else {
            DeskJigLog.debug(.restorationChrome, "No Chrome windows to supplement", runId: runId)
            return snapshot
        }

        DeskJigLog.debug(
            .restorationChrome,
            "Starting Chrome supplementation (count=\(chromeWindows.count), method=\(method.rawValue), includeTabUrls=\(includeTabUrls))",
            runId: runId
        )

        // Skip if disabled
        if method == .disabled {
            DeskJigLog.debug(.restorationChrome, "Chrome supplementation disabled", runId: runId)
            return markWindowsAsStatus(snapshot, status: .notRequired, runId: runId)
        }

        // Mark Chrome windows as pending
        let workingSnapshot = markChromeWindowsAsPending(snapshot, runId: runId)

        // Fetch fresh AX titles (for profile extraction)
        let axTitles = await fetchFreshAxTitles(for: chromeWindows, runId: runId)

        // Fetch tab URLs with bounds (for correlation).
        // This is expensive when Chrome has many tabs; skip unless we truly need tab URLs.
        let tabData: [CGWindowID: (urls: [String], profile: String)]
        if includeTabUrls {
            tabData = await fetchTabUrls(
                for: chromeWindows,
                method: method,
                runId: runId
            )
        } else {
            tabData = [:]
            DeskJigLog.debug(.restorationChrome, "Skipping tab URL fetch (includeTabUrls=false)", runId: runId)
        }

        // Enrich windows with fetched data
        var enrichedCount = 0
        var failedCount = 0
        var enrichedWindows: [SnapshotWindow] = []

        for window in workingSnapshot.windows {
            if window.bundleId == chromeBundleId {
                var enriched = window

                // Apply AX title and extract profile
                if let freshTitle = axTitles[window.windowId] {
                    enriched.freshAxTitle = freshTitle
                    enriched.chromeProfileFromTitle = extractProfileName(from: freshTitle)
                }

                // Apply tab URLs (matched by frame correlation)
                if let data = tabData[window.windowId] {
                    enriched.chromeTabUrls = data.urls
                    // If we didn't get profile from AX title, use AppleScript profile
                    if enriched.chromeProfileFromTitle == nil || enriched.chromeProfileFromTitle?.isEmpty == true {
                        enriched.chromeProfileFromTitle = data.profile
                    }
                }

                // Update status
                if enriched.freshAxTitle != nil || enriched.chromeTabUrls != nil {
                    enriched.supplementationStatus = .completed
                    enrichedCount += 1
                } else {
                    enriched.supplementationStatus = .failed
                    failedCount += 1
                }

                enrichedWindows.append(enriched)
            } else {
                enrichedWindows.append(window)
            }
        }

        let durationMs = Int(Date().timeIntervalSince(startTime) * 1000)

        DeskJigLog.debug(
            .restorationChrome,
            "Chrome supplementation complete (enriched=\(enrichedCount), failed=\(failedCount), duration=\(durationMs)ms)",
            runId: runId
        )

        // Build new snapshot with enriched windows
        return SystemSnapshot(
            captureTime: snapshot.captureTime,
            captureDurationMs: snapshot.captureDurationMs,
            runId: snapshot.runId,
            timing: snapshot.timing,
            displays: snapshot.displays,
            windows: enrichedWindows,
            chromeCaptures: snapshot.chromeCaptures
        )
    }

    // MARK: - Private Helpers

    /// Mark all Chrome windows as pending supplementation
    private func markChromeWindowsAsPending(_ snapshot: SystemSnapshot, runId: String) -> SystemSnapshot {
        let windows = snapshot.windows.map { window -> SnapshotWindow in
            if window.bundleId == chromeBundleId {
                var updated = window
                updated.supplementationStatus = .pending
                return updated
            }
            return window
        }

        return SystemSnapshot(
            captureTime: snapshot.captureTime,
            captureDurationMs: snapshot.captureDurationMs,
            runId: snapshot.runId,
            timing: snapshot.timing,
            displays: snapshot.displays,
            windows: windows,
            chromeCaptures: snapshot.chromeCaptures
        )
    }

    /// Mark all windows with a specific status (for disabled case)
    private func markWindowsAsStatus(_ snapshot: SystemSnapshot, status: ChromeSupplementationStatus, runId: String) -> SystemSnapshot {
        let windows = snapshot.windows.map { window -> SnapshotWindow in
            var updated = window
            updated.supplementationStatus = window.bundleId == chromeBundleId ? status : .notRequired
            return updated
        }

        return SystemSnapshot(
            captureTime: snapshot.captureTime,
            captureDurationMs: snapshot.captureDurationMs,
            runId: snapshot.runId,
            timing: snapshot.timing,
            displays: snapshot.displays,
            windows: windows,
            chromeCaptures: snapshot.chromeCaptures
        )
    }

    /// Fetch fresh AX titles for Chrome windows (includes profile names).
    /// AX titles format: "PageTitle - Google Chrome - ProfileName"
    ///
    /// IMPORTANT: Uses one-to-one matching to prevent stacked windows from all matching
    /// the same AX window. Each AX window can only be matched once.
    private func fetchFreshAxTitles(for windows: [SnapshotWindow], runId: String) async -> [CGWindowID: String] {
        var result: [CGWindowID: String] = [:]

        // Get Chrome app's PID
        guard let chromePid = axService.getProcessID(for: chromeBundleId) else {
            DeskJigLog.debug(.restorationChrome, "Chrome not running, cannot fetch AX titles", runId: runId)
            return result
        }

        // Get AX windows via the shared enumeration skeleton.
        guard let axWindows = axService.enumerateWindows(
            pid: chromePid,
            includeTitle: true,
            includeWindowNumber: false,
            includeDocumentPath: false
        ) else {
            DeskJigLog.debug(.restorationChrome, "Failed to get AX windows for Chrome", runId: runId)
            return result
        }

        // Build frame + title data from AX windows
        var axWindowData: [(frame: CGRect, title: String, matched: Bool)] = []
        for axWindow in axWindows {
            guard let frame = axWindow.frame else { continue }
            axWindowData.append((frame: frame, title: axWindow.title ?? "", matched: false))
        }

        // STRATEGY 1: First pass - match by CGWindowList title containing AX page title
        // This works when CGWindowList title contains the page title (which is the first part of AX title)
        for window in windows where result[window.windowId] == nil {
            guard let cgTitle = window.title, !cgTitle.isEmpty else { continue }

            // Find an unmatched AX window whose page title is in the CGWindowList title
            for i in 0..<axWindowData.count where !axWindowData[i].matched && !axWindowData[i].title.isEmpty {
                let axTitle = axWindowData[i].title
                // Extract page title from AX title (everything before " - Google Chrome")
                let pageTitle = axTitle.components(separatedBy: " - Google Chrome").first ?? axTitle

                if cgTitle.contains(pageTitle) || pageTitle.contains(cgTitle.components(separatedBy: " - ").first ?? cgTitle) {
                    result[window.windowId] = axTitle
                    axWindowData[i].matched = true
                    DeskJigLog.debug(
                        .restorationChrome,
                        "Fresh AX title via title match (windowId=\(window.windowId), title=\(axTitle.prefix(50)))",
                        runId: runId
                    )
                    break
                }
            }
        }

        // STRATEGY 2: Second pass - match by frame (one-to-one, mark as matched)
        // Only for windows that didn't match by title
        for window in windows where result[window.windowId] == nil {
            for i in 0..<axWindowData.count where !axWindowData[i].matched && !axWindowData[i].title.isEmpty {
                if framesMatch(window.frame, axWindowData[i].frame) {
                    result[window.windowId] = axWindowData[i].title
                    axWindowData[i].matched = true  // Mark as used - prevents duplicate matching
                    DeskJigLog.debug(
                        .restorationChrome,
                        "Fresh AX title via frame match (windowId=\(window.windowId), title=\(axWindowData[i].title.prefix(50)))",
                        runId: runId
                    )
                    break
                }
            }
        }

        // Log any unmatched windows
        for window in windows where result[window.windowId] == nil {
            let frameStr = "(\(Int(window.frame.origin.x)),\(Int(window.frame.origin.y)) \(Int(window.frame.width))x\(Int(window.frame.height)))"
            DeskJigLog.debug(
                .restorationChrome,
                "AX title match FAILED for windowId=\(window.windowId), cgFrame=\(frameStr), cgTitle=\(window.title ?? "nil")",
                runId: runId
            )
        }

        DeskJigLog.debug(
            .restorationChrome,
            "Fetched \(result.count)/\(windows.count) fresh AX titles",
            runId: runId
        )
        return result
    }

    /// Fetch tab URLs via AppleScript with window bounds for correlation.
    /// Returns a mapping of CGWindowID to (tab URLs, profile name).
    private func fetchTabUrls(
        for windows: [SnapshotWindow],
        method: ChromeFetchMethod,
        runId: String
    ) async -> [CGWindowID: (urls: [String], profile: String)] {
        switch method {
        case .appleScript:
            return await fetchTabUrlsViaAppleScript(for: windows, runId: runId)
        case .nativeExtension:
            return await fetchTabUrlsViaNativeExtension(for: windows, runId: runId)
        case .both:
            // Try native extension first
            let nativeResult = await fetchTabUrlsViaNativeExtension(for: windows, runId: runId)
            if !nativeResult.isEmpty {
                return nativeResult
            }
            // Fall back to AppleScript
            DeskJigLog.debug(
                .restorationChrome,
                "Native extension returned no results, falling back to AppleScript",
                runId: runId
            )
            return await fetchTabUrlsViaAppleScript(for: windows, runId: runId)
        case .disabled:
            return [:]
        }
    }

    /// Fetch tab URLs via AppleScript including window bounds for correlation.
    private func fetchTabUrlsViaAppleScript(
        for windows: [SnapshotWindow],
        runId: String
    ) async -> [CGWindowID: (urls: [String], profile: String)] {
        // Format: "x,y,width,height:::profileName:::url1^^^url2^^^url3###" for each window
        let script = ChromeAppleScript.windowTabDataWithBoundsAndProfiles

        let resultString = await runAppleScript(script, runId: runId)
        guard let resultString, !resultString.isEmpty else {
            DeskJigLog.debug(.restorationChrome, "AppleScript returned empty result", runId: runId)
            return [:]
        }

        // Parse result into structured data first
        var appleScriptWindows: [(frame: CGRect, profile: String, tabUrls: [String], pageTitle: String, matched: Bool)] = []

        let windowParts = resultString.components(separatedBy: "###")
        for windowData in windowParts {
            let parts = windowData.components(separatedBy: ":::")
            guard parts.count >= 3 else { continue }

            // Parse bounds: "x,y,width,height"
            let boundsStr = parts[0]
            let boundsParts = boundsStr.components(separatedBy: ",")
            guard boundsParts.count == 4,
                  let x = Double(boundsParts[0]),
                  let y = Double(boundsParts[1]),
                  let width = Double(boundsParts[2]),
                  let height = Double(boundsParts[3]) else { continue }

            let frame = CGRect(x: x, y: y, width: width, height: height)
            let profileName = parts[1]
            let tabUrlsString = parts[2]
            let tabUrls = tabUrlsString.isEmpty ? [] : tabUrlsString.components(separatedBy: "^^^")

            // Extract page title from active tab URL for title-based matching
            let pageTitle = tabUrls.first.flatMap { url -> String? in
                // Extract domain/path for matching
                guard let urlObj = URL(string: url) else { return nil }
                return urlObj.host ?? urlObj.path
            } ?? ""

            appleScriptWindows.append((frame: frame, profile: profileName, tabUrls: tabUrls, pageTitle: pageTitle, matched: false))
        }

        // Correlate with CGWindowList windows using one-to-one matching
        var tabData: [CGWindowID: (urls: [String], profile: String)] = [:]

        // STRATEGY 1: Match by profile name in CGWindowList title
        for window in windows where tabData[window.windowId] == nil {
            guard let cgTitle = window.title else { continue }

            for i in 0..<appleScriptWindows.count where !appleScriptWindows[i].matched {
                let asWindow = appleScriptWindows[i]
                // Check if CGWindowList title contains the profile name
                if cgTitle.contains(" - \(asWindow.profile)") ||
                   cgTitle.hasSuffix(asWindow.profile) {
                    tabData[window.windowId] = (urls: asWindow.tabUrls, profile: asWindow.profile)
                    appleScriptWindows[i].matched = true
                    DeskJigLog.debug(
                        .restorationChrome,
                        "Tab URLs correlated via profile (windowId=\(window.windowId), profile=\(asWindow.profile), tabCount=\(asWindow.tabUrls.count))",
                        runId: runId
                    )
                    break
                }
            }
        }

        // STRATEGY 2: Match by page title in CGWindowList title
        for window in windows where tabData[window.windowId] == nil {
            guard let cgTitle = window.title, !cgTitle.isEmpty else { continue }

            for i in 0..<appleScriptWindows.count where !appleScriptWindows[i].matched {
                let asWindow = appleScriptWindows[i]
                // Check if CGWindowList title contains the page title (domain)
                if !asWindow.pageTitle.isEmpty && cgTitle.lowercased().contains(asWindow.pageTitle.lowercased()) {
                    tabData[window.windowId] = (urls: asWindow.tabUrls, profile: asWindow.profile)
                    appleScriptWindows[i].matched = true
                    DeskJigLog.debug(
                        .restorationChrome,
                        "Tab URLs correlated via pageTitle (windowId=\(window.windowId), profile=\(asWindow.profile), tabCount=\(asWindow.tabUrls.count))",
                        runId: runId
                    )
                    break
                }
            }
        }

        // STRATEGY 3: Fall back to frame matching (one-to-one)
        for window in windows where tabData[window.windowId] == nil {
            for i in 0..<appleScriptWindows.count where !appleScriptWindows[i].matched {
                let asWindow = appleScriptWindows[i]
                if framesMatch(window.frame, asWindow.frame) {
                    tabData[window.windowId] = (urls: asWindow.tabUrls, profile: asWindow.profile)
                    appleScriptWindows[i].matched = true
                    DeskJigLog.debug(
                        .restorationChrome,
                        "Tab URLs correlated via frame (windowId=\(window.windowId), profile=\(asWindow.profile), tabCount=\(asWindow.tabUrls.count))",
                        runId: runId
                    )
                    break
                }
            }
        }

        DeskJigLog.debug(
            .restorationChrome,
            "Fetched tab URLs for \(tabData.count)/\(windows.count) windows via AppleScript",
            runId: runId
        )
        return tabData
    }

    private func runAppleScript(_ script: String, runId: String) async -> String? {
        if AppleScriptRunner.shouldUseOsascript {
            DeskJigLog.debug(.restorationChrome, "Using osascript for Chrome tab fetch", runId: runId)
            return await runAppleScriptViaOsascript(script, runId: runId)
        }

        do {
            let descriptor = try AppleScriptRunner.runInProcess(script)
            return descriptor.stringValue
        } catch let error as AppleScriptError {
            DeskJigLog.error(.restorationChrome, "AppleScript tab fetch failed: \(error.message)", runId: runId)
            return nil
        } catch {
            DeskJigLog.error(.restorationChrome, "AppleScript tab fetch failed: \(error.localizedDescription)", runId: runId)
            return nil
        }
    }

    private func runAppleScriptViaOsascript(_ script: String, runId: String) async -> String? {
        await Task.detached(priority: .utility) { [osascriptTimeout] in
            let result = AppleScriptRunner.runOsascript(script, timeout: osascriptTimeout)

            if result.timedOut {
                DeskJigLog.debug(.restorationChrome, result.errorOutput, runId: runId)
                return nil
            }

            if !result.errorOutput.isEmpty {
                DeskJigLog.debug(.restorationChrome, "osascript stderr: \(result.errorOutput)", runId: runId)
            }

            let trimmedOutput = result.trimmedOutput
            return trimmedOutput.isEmpty ? nil : trimmedOutput
        }.value
    }

    /// Fetch tab URLs via Native Extension messaging.
    /// Uses the ChromeNativeMessagingService if available.
    private func fetchTabUrlsViaNativeExtension(
        for windows: [SnapshotWindow],
        runId: String
    ) async -> [CGWindowID: (urls: [String], profile: String)] {
        // TODO: Integrate with ChromeNativeMessagingService when available
        // For now, return empty - the service can be wired up later
        DeskJigLog.debug(.restorationChrome, "Native extension fetch not yet implemented", runId: runId)
        return [:]
    }

    /// Extract profile name from Chrome AX title.
    /// Format: "PageTitle - Google Chrome - ProfileName" or "PageTitle - Google Chrome" (default)
    /// Note: Chrome uses different dash types (-, –, —) in different contexts
    private func extractProfileName(from title: String) -> String? {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)

        // Strategy 1: Check all delimiter variants (matches ChromeAutomationService.parseProfileName)
        let delimiters = [
            " - Google Chrome - ",  // regular hyphen
            " – Google Chrome – ",  // en dash
            " — Google Chrome — "   // em dash
        ]

        for delimiter in delimiters {
            if let range = trimmedTitle.range(of: delimiter, options: .backwards) {
                let profileName = trimmedTitle[range.upperBound...]
                if !profileName.isEmpty {
                    return String(profileName)
                }
            }
        }

        // Strategy 2: Check for Default profile (title ends with " - Google Chrome" variants)
        let defaultSuffixes = [
            " - Google Chrome",   // regular hyphen
            " – Google Chrome",   // en dash
            " — Google Chrome"    // em dash
        ]
        for suffix in defaultSuffixes {
            if trimmedTitle.hasSuffix(suffix) {
                return "Default"
            }
        }

        return nil
    }

    /// Check if two frames match within tolerance.
    private func framesMatch(_ frame1: CGRect, _ frame2: CGRect) -> Bool {
        frame1.approximatelyEquals(frame2, tolerance: frameTolerance)
    }
}

// MARK: - SystemSnapshot Extension

extension SystemSnapshot {
    /// Returns true if any Chrome windows are still pending supplementation.
    public var hasPendingChromeSupplementation: Bool {
        windows.contains { $0.supplementationStatus == .pending }
    }

    /// Returns Chrome windows that have completed supplementation.
    public var supplementedChromeWindows: [SnapshotWindow] {
        windows.filter { $0.supplementationStatus == .completed }
    }

    /// Find a Chrome window by profile name (using supplementation data).
    /// Uses two-pass matching: exact matches first, then base-name fallback only if supplementation failed.
    public func findChromeWindow(withProfile profileName: String) -> SnapshotWindow? {
        let chromeWindows = windows.filter { $0.bundleId == "com.google.Chrome" }

        // PASS 1: Exact matches only
        if let exactMatch = chromeWindows.first(where: { window in
            guard let extractedProfile = window.chromeProfileFromTitle else { return false }
            return extractedProfile == profileName
        }) {
            return exactMatch
        }

        // PASS 2: Base-name fallback (only if ALL Chrome windows have failed/nil supplementation)
        // This prevents matching a window with a different profile when supplementation succeeded
        let allSupplementationFailed = chromeWindows.allSatisfy {
            $0.supplementationStatus == .failed || $0.supplementationStatus == nil
        }

        if allSupplementationFailed {
            return chromeWindows.first { window in
                guard let extractedProfile = window.chromeProfileFromTitle else { return false }
                let extractedBase = extractedProfile.components(separatedBy: " (").first ?? extractedProfile
                let targetBase = profileName.components(separatedBy: " (").first ?? profileName
                return extractedBase == targetBase
            }
        }

        // If supplementation succeeded but no exact match → return nil (will create new window)
        return nil
    }
}
