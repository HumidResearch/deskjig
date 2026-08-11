//  ChromeAutomationService.swift
//  DeskJigShared

import Foundation

public struct ChromeAppleScriptWindowCapture: Equatable, Sendable {
    public let bounds: CGRect
    public let title: String
    public let profileAppleScriptName: String?
    public let tabURLs: [String]
    public let activeTabIndex: Int?
    /// Chrome's internal window ID from AppleScript (stable within a session)
    public let chromeWindowId: Int?
}

/// Lightweight helper responsible for running the AppleScript commands we
/// need to inspect Google Chrome windows and their tabs.
public enum ChromeAutomationService {

    /// When true, logs full URLs instead of masked `*.com` format
    private static var showFullURLsInLogs: Bool {
        ProcessInfo.processInfo.environment["SHOW_FULL_URLS"] == "1"
    }

    /// When true, enables verbose step-by-step logging
    /// ON by default in DEBUG builds, OFF in Release
    /// Can be toggled with VERBOSE_CHROME_LOGS environment variable
    static var verboseLogging: Bool {
        #if DEBUG
        // Default ON for debug builds, can be disabled with VERBOSE_CHROME_LOGS=0
        return ProcessInfo.processInfo.environment["VERBOSE_CHROME_LOGS"] != "0"
        #else
        // Default OFF for release builds, can be enabled with VERBOSE_CHROME_LOGS=1
        return ProcessInfo.processInfo.environment["VERBOSE_CHROME_LOGS"] == "1"
        #endif
    }

    private static var shouldUseOsascript: Bool {
        AppleScriptRunner.shouldUseOsascript
    }

    // MARK: - TCC Warmup State Machine

    private enum TCCWarmupState {
        case notStarted
        case inProgress
        case completed(success: Bool)
    }

    private static let tccLock = NSLock()
    private static var tccState: TCCWarmupState = .notStarted
    private static let tccSemaphore = DispatchSemaphore(value: 0)

    /// Triggers TCC Automation permission dialog for System Events if not already granted.
    /// Safe to call from any thread. Concurrent callers block until the in-flight warmup finishes.
    public static func warmupTCCIfNeeded() {
        tccLock.lock()
        switch tccState {
        case .completed:
            tccLock.unlock()
            return
        case .inProgress:
            tccLock.unlock()
            // Another thread is running warmup — wait for it to finish
            tccSemaphore.wait()
            // Re-signal so other waiters also unblock
            tccSemaphore.signal()
            return
        case .notStarted:
            tccState = .inProgress
            tccLock.unlock()
        }

        let result = AppleScriptRunner.runOsascript(
            "tell application \"System Events\" to return \"\"",
            timeout: 10.0
        )
        let success = result.exitCode == 0
        if !success {
            DeskJigLog.warn(.restorationChrome, "TCC warmup failed (user may have denied): \(result.errorOutput)")
        }

        tccLock.lock()
        tccState = .completed(success: success)
        tccLock.unlock()
        // Wake all threads waiting on the semaphore
        tccSemaphore.signal()
    }

    /// Synchronously verifies TCC permission is granted, blocking until any in-flight warmup completes.
    /// Returns true if warmup succeeded. Safe to call from any thread.
    public static func verifyTCCPermission() -> Bool {
        warmupTCCIfNeeded()
        tccLock.lock()
        defer { tccLock.unlock() }
        if case .completed(let success) = tccState {
            return success
        }
        return false
    }

    /// Resets TCC warmup state so the next call to warmupTCCIfNeeded() re-runs the warmup.
    /// Use after a runtime permission error suggests TCC state has changed.
    public static func resetTCCWarmupState() {
        tccLock.lock()
        tccState = .notStarted
        tccLock.unlock()
    }

    private static let osascriptTimeout: TimeInterval = AppleScriptRunner.defaultTimeout

    /// Helper to format URL for logging (respects SHOW_FULL_URLS env var).
    /// Default format is domain-only (or scheme-only for non-HTTP URLs).
    static func formatURLForLog(_ url: String) -> String {
        showFullURLsInLogs ? url : summarizeURLForLog(url)
    }

    private static func summarizeURLForLog(_ url: String) -> String {
        guard let components = URLComponents(string: url) else { return url }

        let scheme = components.scheme?.lowercased()
        if scheme == "http" || scheme == "https" {
            if let host = components.host {
                if let port = components.port {
                    return "\(host):\(port)"
                }
                return host
            }
            return url
        }

        if scheme == "file" {
            let lastComponent = URL(fileURLWithPath: components.path).lastPathComponent
            return lastComponent.isEmpty ? "file:///" : "file://\(lastComponent)"
        }

        if let scheme {
            if let host = components.host, !host.isEmpty {
                return "\(scheme)://\(host)"
            }
            if !components.path.isEmpty {
                return "\(scheme):\(components.path)"
            }
            return "\(scheme):"
        }

        return url
    }

    private static func formatURLListForLog(_ urls: [String]) -> String {
        guard !urls.isEmpty else { return "none" }
        return urls.map { formatURLForLog($0) }.joined(separator: ", ")
    }

    private static func formatBoundsForLog(_ bounds: CGRect) -> String {
        String(format: "(%.0f, %.0f) %.0fx%.0f", bounds.origin.x, bounds.origin.y, bounds.width, bounds.height)
    }

    private static func truncateForLog(_ value: String, limit: Int = 80) -> String {
        guard value.count > limit else { return value }
        let endIndex = value.index(value.startIndex, offsetBy: limit)
        return String(value[..<endIndex]) + "..."
    }

    static public func captureOpenWindows(includeTabURLs: Bool = true) -> [ChromeAppleScriptWindowCapture] {
        if verboseLogging {
            DeskJigLog.debug(.restorationChrome, "captureOpenWindows: start")
        }

        // Fast check: if Chrome isn't running, return empty array immediately
        // This avoids slow AppleScript timeouts when Chrome is not launched
        guard isChromeRunning() else {
            DeskJigLog.info(.restorationChrome, "Not running")
            return []
        }

        let systemWindows = ChromeAutomationService.fetchSystemEventWindows()
        guard !systemWindows.isEmpty else {
            DeskJigLog.warn(.restorationChrome, "No system windows found")
            return []
        }

        let windowData = ChromeAutomationService.fetchChromeWindowDescriptors(includeTabURLs: includeTabURLs)
        guard !windowData.isEmpty else {
            DeskJigLog.warn(.restorationChrome, "No window descriptors found")
            return []
        }

        var captures: [ChromeAppleScriptWindowCapture] = []
        captures.reserveCapacity(systemWindows.count)

        if verboseLogging {
            DeskJigLog.debug(.restorationChrome, "captureOpenWindows: system=\(systemWindows.count) descriptors=\(windowData.count)")
        }

        // Track which Chrome descriptors have been matched
        var usedDescriptorIndices = Set<Int>()

        // Helper: check if two bounds match within tolerance
        func boundsMatch(_ b1: CGRect?, _ b2: CGRect, tolerance: CGFloat = 50.0) -> Bool {
            guard let b1 = b1 else { return false }
            return abs(b1.origin.x - b2.origin.x) <= tolerance &&
                   abs(b1.origin.y - b2.origin.y) <= tolerance
        }

        // For each system window, find the matching Chrome descriptor
        for (_, systemWindow) in systemWindows.enumerated() {
            let title = systemWindow.title
            let bounds = systemWindow.bounds
            let profileName = ChromeAutomationService.parseProfileName(from: title)

            // Find matching Chrome descriptor: System Events title starts with Chrome window name
            // e.g., "localhost - Network error - Google Chrome - Andrew" starts with "localhost"
            var matchedDescriptor: WindowDescriptor? = nil
            var matchMethod = "unique"

            // Find all Chrome descriptors whose name is a prefix of this title (and haven't been used)
            var candidates: [(index: Int, descriptor: WindowDescriptor)] = []
            for (descIndex, descriptor) in windowData.enumerated() {
                guard !usedDescriptorIndices.contains(descIndex) else { continue }
                if !descriptor.name.isEmpty && title.hasPrefix(descriptor.name) {
                    candidates.append((descIndex, descriptor))
                }
            }

            if candidates.isEmpty {
                // Title matching failed - try bounds matching as fallback (bounds are always reliable)
                for (descIndex, descriptor) in windowData.enumerated() {
                    guard !usedDescriptorIndices.contains(descIndex) else { continue }
                    if boundsMatch(descriptor.bounds, bounds) {
                        matchedDescriptor = descriptor
                        usedDescriptorIndices.insert(descIndex)
                        matchMethod = "bounds"
                        break
                    }
                }
            } else if candidates.count == 1 {
                // Only one match - use it
                let selected = candidates[0]
                matchedDescriptor = selected.descriptor
                usedDescriptorIndices.insert(selected.index)
                matchMethod = "unique"
            } else {
                // Multiple candidates with same name prefix - use BOUNDS to find the correct match
                matchMethod = "bounds-disambiguate"

                // First, try to find a candidate with matching bounds
                if let bestMatch = candidates.first(where: { boundsMatch($0.descriptor.bounds, bounds) }) {
                    matchedDescriptor = bestMatch.descriptor
                    usedDescriptorIndices.insert(bestMatch.index)
                } else {
                    // Fallback: just take the first candidate
                    let selected = candidates[0]
                    matchedDescriptor = selected.descriptor
                    usedDescriptorIndices.insert(selected.index)
                    matchMethod = "first-candidate"
                }
            }
            let tabURLs = matchedDescriptor?.tabURLs ?? []
            let activeTabIndex = matchedDescriptor?.activeTabIndex
            let chromeWindowId = matchedDescriptor?.identifier

            if verboseLogging {
                let boundsStr = formatBoundsForLog(bounds)
                let activeURL = activeTabIndex.flatMap { idx in
                    let arrayIdx = idx - 1
                    return arrayIdx >= 0 && arrayIdx < tabURLs.count ? formatURLForLog(tabURLs[arrayIdx]) : nil
                } ?? "none"
                DeskJigLog.debug(
                    .restorationChrome,
                    "Chrome[\(chromeWindowId ?? 0)]: title='\(truncateForLog(title))' profile='\(profileName ?? "nil")' bounds=\(boundsStr) match=\(matchMethod) tabs=\(tabURLs.count) active=\(activeURL)"
                )
            }

            captures.append(
                ChromeAppleScriptWindowCapture(
                    bounds: bounds,
                    title: title,
                    profileAppleScriptName: profileName,
                    tabURLs: tabURLs,
                    activeTabIndex: activeTabIndex,
                    chromeWindowId: chromeWindowId
                )
            )
        }

        // Build consolidated summary log
        let windowSummaries = captures.map { capture -> String in
            let id = capture.chromeWindowId.map { String($0) } ?? "nil"
            let profile = capture.profileAppleScriptName ?? "nil"
            let title = truncateForLog(capture.title)
            let boundsStr = formatBoundsForLog(capture.bounds)
            // activeTabIndex is 1-based from AppleScript, convert to 0-based for array access
            let activeURL = capture.activeTabIndex.flatMap { idx in
                let arrayIdx = idx - 1
                return arrayIdx >= 0 && arrayIdx < capture.tabURLs.count ? formatURLForLog(capture.tabURLs[arrayIdx]) : nil
            } ?? "none"
            return "id=\(id) title='\(title)' profile='\(profile)' bounds=\(boundsStr) tabs=\(capture.tabURLs.count) active=\(activeURL)"
        }
        if windowSummaries.isEmpty {
            DeskJigLog.info(.restorationChrome, "Windows: 0")
        } else {
            DeskJigLog.info(.restorationChrome, "Windows: \(captures.count) [\(windowSummaries.joined(separator: " | "))]")
        }

        return captures
    }

    /// Lightweight capture built solely from Chrome window descriptors (id / name / bounds /
    /// activeTabIndex / tabURLs), skipping the System Events fetch + O(n·m) correlation merge that
    /// `captureOpenWindows` performs.
    ///
    /// chrome-11: use ONLY where the consumer needs id/bounds/tabs and does NOT need the profile or
    /// the System Events titlebar. `profileAppleScriptName` is ALWAYS nil here (the profile derives
    /// from the System Events title, which this path skips) and `title` is the Chrome window name
    /// (active-tab title), NOT the full " - Google Chrome - <Profile>" titlebar. Do NOT substitute
    /// this where profile matching occurs (selectPostLaunchCapture / matchExistingWindow) or where a
    /// System-Events liveness signal is required (the post-launch failure diagnostic).
    static public func captureChromeDescriptorCaptures(includeTabURLs: Bool = false) -> [ChromeAppleScriptWindowCapture] {
        guard isChromeRunning() else {
            DeskJigLog.info(.restorationChrome, "Not running")
            return []
        }

        let windowData = ChromeAutomationService.fetchChromeWindowDescriptors(includeTabURLs: includeTabURLs)
        guard !windowData.isEmpty else {
            DeskJigLog.warn(.restorationChrome, "No window descriptors found")
            return []
        }

        let captures = windowData.map { descriptor in
            ChromeAppleScriptWindowCapture(
                bounds: descriptor.bounds ?? .zero,
                title: descriptor.name,
                profileAppleScriptName: nil,
                tabURLs: descriptor.tabURLs,
                activeTabIndex: descriptor.activeTabIndex,
                chromeWindowId: descriptor.identifier
            )
        }

        if verboseLogging {
            DeskJigLog.debug(.restorationChrome, "captureChromeDescriptorCaptures: \(captures.count) window(s) (descriptor-only, profile/title unavailable)")
        }

        return captures
    }

    static public func captureTabs(forWindowWithBounds bounds: CGRect) -> ChromeAppleScriptWindowCapture? {
        let captures = ChromeAutomationService.captureOpenWindows()
        // Use tolerance for bounds matching (floating point precision)
        return captures.first(where: { capture in
            boundsMatch(capture.bounds, bounds, tolerance: 5.0)
        })
    }
    
    /// Check if two bounds match within tolerance
    static private func boundsMatch(_ bounds1: CGRect, _ bounds2: CGRect, tolerance: CGFloat) -> Bool {
        return abs(bounds1.origin.x - bounds2.origin.x) <= tolerance &&
               abs(bounds1.origin.y - bounds2.origin.y) <= tolerance &&
               abs(bounds1.width - bounds2.width) <= tolerance &&
               abs(bounds1.height - bounds2.height) <= tolerance
    }

    // MARK: - Chrome Window ID-based Tab Operations (preferred over bounds-based)

    /// Fetch tab URLs for a single Chrome window by its internal ID.
    ///
    /// This is significantly faster than `captureOpenWindows(includeTabURLs: true)` when we only
    /// need to de-duplicate tabs for a single restored window.
    /// Parse a "x,y,width,height" CSV string into a CGRect (nil if malformed).
    private static func parseBoundsCSV(_ csv: String) -> CGRect? {
        let parts = csv.split(separator: ",")
        guard parts.count == 4,
              let x = Double(parts[0]),
              let y = Double(parts[1]),
              let width = Double(parts[2]),
              let height = Double(parts[3]) else { return nil }
        return CGRect(x: x, y: y, width: width, height: height)
    }

    static private func fetchTabURLs(inWindowWithChromeId chromeWindowId: Int) -> (urls: [String], activeTabIndex: Int?, bounds: CGRect?)? {
        let start = Date()

        let script = ChromeAppleScript.tabData(inWindowID: chromeWindowId)

        let output: String?
        if shouldUseOsascript {
            let result = AppleScriptRunner.runOsascript(script, timeout: osascriptTimeout)
            if result.timedOut {
                DeskJigLog.warn(.restorationChrome, "Chrome[\(chromeWindowId)]: Tab capture timed out")
                return nil
            }
            if result.exitCode != 0 {
                let message = result.errorOutput.isEmpty ? "osascript exited with code \(result.exitCode)" : result.errorOutput
                DeskJigLog.warn(.restorationChrome, "Chrome[\(chromeWindowId)]: Tab capture failed - \(message)")
                return nil
            }
            output = result.trimmedOutput
        } else {
            do {
                output = try run(script: script)?.stringValue
            } catch {
                DeskJigLog.warn(.restorationChrome, "Chrome[\(chromeWindowId)]: Tab capture failed - \(error.localizedDescription)")
                return nil
            }
        }

        guard let output, !output.isEmpty else { return nil }
        if output.hasPrefix("Error:") {
            DeskJigLog.warn(.restorationChrome, "Chrome[\(chromeWindowId)]: Tab capture AppleScript error - \(output)")
            return nil
        }

        let parts = output.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
        let activeTabIndex = parts.first.flatMap { Int($0) }
        let bounds = parts.count > 1 ? parseBoundsCSV(String(parts[1])) : nil
        let tabString = parts.count > 2 ? String(parts[2]) : ""
        let urls = tabString.isEmpty ? [] : tabString.components(separatedBy: "^^^")

        if verboseLogging {
            let durationMs = Int(Date().timeIntervalSince(start) * 1000)
            DeskJigLog.debug(.restorationChrome, "Chrome[\(chromeWindowId)]: Captured \(urls.count) tab(s) in \(durationMs)ms")
        }

        return (urls: urls, activeTabIndex: activeTabIndex, bounds: bounds)
    }

    /// Find capture by Chrome window ID (more reliable than bounds).
    ///
    /// chrome-03: fetches tabs + bounds in a single `window id N`-scoped AppleScript, eliminating
    /// the previous `captureOpenWindows(includeTabURLs:false)` pre-step (System Events fetch +
    /// descriptor fetch + merge) that was only used to recover one window's metadata.
    /// NOTE: `title`/`profileAppleScriptName` are intentionally left empty/nil — they derive from
    /// the System Events titlebar, which this fast path skips, and every caller of this method
    /// reads only `tabURLs`/`activeTabIndex` (verified).
    static public func captureTabs(forWindowWithChromeId chromeWindowId: Int) -> ChromeAppleScriptWindowCapture? {
        guard let tabInfo = fetchTabURLs(inWindowWithChromeId: chromeWindowId) else {
            return nil
        }
        return ChromeAppleScriptWindowCapture(
            bounds: tabInfo.bounds ?? .zero,
            title: "",
            profileAppleScriptName: nil,
            tabURLs: tabInfo.urls,
            activeTabIndex: tabInfo.activeTabIndex,
            chromeWindowId: chromeWindowId
        )
    }

    /// Open missing tabs using Chrome window ID (preferred over bounds-based)
    static public func openMissingTabs(_ urls: [String], inWindowWithChromeId chromeWindowId: Int) {
        guard !urls.isEmpty else {
            if verboseLogging { DeskJigLog.debug(.restorationChrome, "Chrome[\(chromeWindowId)]: No URLs to open") }
            return
        }
        guard isChromeRunning() else {
            DeskJigLog.warn(.restorationChrome, "Chrome[\(chromeWindowId)]: Cannot open tabs - Chrome not running")
            return
        }

        if verboseLogging {
            DeskJigLog.debug(.restorationChrome, "Chrome[\(chromeWindowId)]: Requested \(urls.count) URL(s) [\(formatURLListForLog(urls))]")
        }

        if let tabInfo = fetchTabURLs(inWindowWithChromeId: chromeWindowId) {
            if verboseLogging {
                DeskJigLog.debug(.restorationChrome, "Chrome[\(chromeWindowId)]: Window has \(tabInfo.urls.count) existing tab(s)")
            }

            let trulyMissingURLs = urls.filter { candidateURL in
                let isAlreadyOpen = tabInfo.urls.contains { existingURL in
                    urlsAreEquivalent(candidateURL, existingURL)
                }
                return !isAlreadyOpen
            }

            if trulyMissingURLs.isEmpty {
                if verboseLogging { DeskJigLog.debug(.restorationChrome, "Chrome[\(chromeWindowId)]: All URLs already open") }
                return
            }

            openTabsInWindow(urls: trulyMissingURLs, chromeWindowId: chromeWindowId)
        } else {
            DeskJigLog.warn(.restorationChrome, "Chrome[\(chromeWindowId)]: Could not capture tabs, opening all URLs")
            openTabsInWindow(urls: urls, chromeWindowId: chromeWindowId)
        }
    }

    /// Open tabs without re-checking existing state (no capture).
    static public func openTabs(_ urls: [String], inWindowWithChromeId chromeWindowId: Int) {
        guard !urls.isEmpty else {
            if verboseLogging { DeskJigLog.debug(.restorationChrome, "Chrome[\(chromeWindowId)]: No URLs to open") }
            return
        }
        guard isChromeRunning() else {
            DeskJigLog.warn(.restorationChrome, "Chrome[\(chromeWindowId)]: Cannot open tabs - Chrome not running")
            return
        }

        if verboseLogging {
            DeskJigLog.debug(.restorationChrome, "Chrome[\(chromeWindowId)]: Opening \(urls.count) tab(s) [\(formatURLListForLog(urls))]")
        }

        openTabsInWindow(urls: urls, chromeWindowId: chromeWindowId)
    }

    /// Internal helper to open tabs via AppleScript using Chrome window ID
    static private func openTabsInWindow(urls: [String], chromeWindowId: Int) {
        guard !urls.isEmpty else { return }

        let script = ChromeAppleScript.appendTabs(urls, toWindowID: chromeWindowId)

        do {
            try execute(script: script)
            let urlList = formatURLListForLog(urls)
            DeskJigLog.info(.restorationChrome, "Chrome[\(chromeWindowId)]: Opened \(urls.count) tab(s) (\(urlList))")
        } catch {
            DeskJigLog.error(.restorationChrome, "Chrome[\(chromeWindowId)]: Failed to open tabs - \(error.localizedDescription)")
        }
    }

    /// Set active tab using Chrome window ID (preferred over bounds-based)
    static public func setActiveTab(index: Int, inWindowWithChromeId chromeWindowId: Int) {
        guard index > 0 else {
            if verboseLogging { DeskJigLog.debug(.restorationChrome, "Chrome[\(chromeWindowId)]: setActiveTab invalid index \(index)") }
            return
        }
        guard isChromeRunning() else {
            DeskJigLog.warn(.restorationChrome, "Chrome[\(chromeWindowId)]: Cannot set active tab - not running")
            return
        }

        let script = ChromeAppleScript.setActiveTab(index: index, inWindowID: chromeWindowId)

        do {
            try execute(script: script)
            DeskJigLog.info(.restorationChrome, "Chrome[\(chromeWindowId)]: Set active tab to \(index)")
        } catch {
            DeskJigLog.error(.restorationChrome, "Chrome[\(chromeWindowId)]: Failed to set active tab - \(error.localizedDescription)")
        }
    }

    /// Replace the active tab URL in a specific Chrome window.
    /// Also brings that window to the front.
    /// - Returns: `true` when the URL update succeeds.
    @discardableResult
    static public func setActiveTabURL(_ targetURL: String, inWindowWithChromeId chromeWindowId: Int) -> Bool {
        let trimmedURL = targetURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedURL.isEmpty else {
            return false
        }
        guard isChromeRunning() else {
            DeskJigLog.warn(.restorationChrome, "Chrome[\(chromeWindowId)]: Cannot set active tab URL - not running")
            return false
        }

        let script = ChromeAppleScript.setActiveTabURL(trimmedURL, inWindowID: chromeWindowId)

        do {
            try execute(script: script)
            DeskJigLog.info(.restorationChrome, "Chrome[\(chromeWindowId)]: Set active tab URL to \(formatURLForLog(trimmedURL))")
            return true
        } catch {
            DeskJigLog.error(.restorationChrome, "Chrome[\(chromeWindowId)]: Failed to set active tab URL - \(error.localizedDescription)")
            return false
        }
    }

    /// Close a specific Chrome window by Chrome's AppleScript window ID.
    /// - Parameter chromeWindowId: Target Chrome window id.
    /// - Returns: `true` when the close command succeeds.
    @discardableResult
    static public func closeWindow(withChromeId chromeWindowId: Int) -> Bool {
        guard isChromeRunning() else {
            DeskJigLog.warn(.restorationChrome, "Chrome[\(chromeWindowId)]: Cannot close window - not running")
            return false
        }

        let script = ChromeAppleScript.closeWindow(windowID: chromeWindowId)

        do {
            try execute(script: script)
            DeskJigLog.info(.restorationChrome, "Chrome[\(chromeWindowId)]: Closed window")
            return true
        } catch {
            DeskJigLog.error(.restorationChrome, "Chrome[\(chromeWindowId)]: Failed to close window - \(error.localizedDescription)")
            return false
        }
    }

    /// Reposition an existing Chrome window by its internal window ID via AppleScript.
    ///
    /// Used as a fallback when the AX handle for a Chrome window isn't available,
    /// and for post-animation bounds confirmation.
    ///
    /// - Parameters:
    ///   - chromeWindowId: Chrome's internal window ID from AppleScript.
    ///   - bounds: Target frame in window-coordinate space (top-left origin).
    /// - Returns: `true` when the bounds command succeeds.
    @discardableResult
    static public func setBounds(chromeWindowId: Int, bounds: CGRect) -> Bool {
        guard isChromeRunning() else {
            DeskJigLog.warn(.restorationChrome, "Chrome[\(chromeWindowId)]: Cannot set bounds - not running")
            return false
        }

        let left = Int(bounds.minX.rounded())
        let top = Int(bounds.minY.rounded())
        let right = Int(bounds.maxX.rounded())
        let bottom = Int(bounds.maxY.rounded())

        let script = ChromeAppleScript.setBounds(ofWindowID: chromeWindowId, to: bounds)

        do {
            try execute(script: script)
            DeskJigLog.info(.restorationChrome, "Chrome[\(chromeWindowId)]: Set bounds to {\(left), \(top), \(right), \(bottom)}")
            return true
        } catch {
            DeskJigLog.error(.restorationChrome, "Chrome[\(chromeWindowId)]: Failed to set bounds - \(error.localizedDescription)")
            return false
        }
    }

    /// Focus an existing tab matching `targetURL` (using URL equivalence),
    /// or open the URL in a preferred window and focus it.
    ///
    /// - Parameters:
    ///   - targetURL: URL to focus/open.
    ///   - preferredChromeWindowIds: Optional preferred window ordering.
    /// - Returns: true when the request was handled by a running Chrome window.
    static public func focusOrOpenURL(
        _ targetURL: String,
        preferredChromeWindowIds: [Int] = []
    ) -> Bool {
        let trimmedURL = targetURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedURL.isEmpty else {
            return false
        }
        guard isChromeRunning() else {
            return false
        }

        let captures = captureOpenWindows(includeTabURLs: true).compactMap { capture -> ChromeAppleScriptWindowCapture? in
            guard capture.chromeWindowId != nil else { return nil }
            return capture
        }
        guard !captures.isEmpty else {
            return false
        }

        let preferredOrder = Dictionary(uniqueKeysWithValues: preferredChromeWindowIds.enumerated().map { ($1, $0) })
        let orderedCaptures = captures.sorted { lhs, rhs in
            let lhsID = lhs.chromeWindowId ?? -1
            let rhsID = rhs.chromeWindowId ?? -1
            let lhsRank = preferredOrder[lhsID] ?? Int.max
            let rhsRank = preferredOrder[rhsID] ?? Int.max
            if lhsRank != rhsRank {
                return lhsRank < rhsRank
            }
            return lhsID < rhsID
        }

        for capture in orderedCaptures {
            guard let chromeWindowId = capture.chromeWindowId else { continue }
            if let matchingIndex = capture.tabURLs.firstIndex(where: { existingURL in
                urlsAreEquivalent(trimmedURL, existingURL)
            }) {
                // AppleScript uses 1-based tab indices.
                setActiveTab(index: matchingIndex + 1, inWindowWithChromeId: chromeWindowId)
                return true
            }
        }

        guard let targetCapture = orderedCaptures.first,
              let targetChromeWindowId = targetCapture.chromeWindowId else {
            return false
        }

        openMissingTabs([trimmedURL], inWindowWithChromeId: targetChromeWindowId)

        if let refreshed = captureTabs(forWindowWithChromeId: targetChromeWindowId),
           let matchingIndex = refreshed.tabURLs.firstIndex(where: { existingURL in
               urlsAreEquivalent(trimmedURL, existingURL)
           }) {
            setActiveTab(index: matchingIndex + 1, inWindowWithChromeId: targetChromeWindowId)
        } else {
            // Opened tabs are appended; focus the most likely appended tab.
            setActiveTab(index: targetCapture.tabURLs.count + 1, inWindowWithChromeId: targetChromeWindowId)
        }

        return true
    }

    /// Open URLs in a brand-new Chrome window and optionally place it at exact bounds.
    /// This intentionally avoids reusing existing tabs/windows.
    ///
    /// - Parameters:
    ///   - targetURLs: URLs to open in the new window (first URL becomes the initial tab).
    ///   - centeredBounds: Optional frame in window-coordinate space (top-left origin).
    ///   - activateApp: Whether to bring Chrome to front after creation.
    /// - Returns: true when AppleScript command succeeds.
    static public func openURLsInNewWindow(
        _ targetURLs: [String],
        centeredBounds: CGRect? = nil,
        activateApp: Bool = true
    ) -> Bool {
        openURLsInNewWindowWithResult(
            targetURLs,
            centeredBounds: centeredBounds,
            activateApp: activateApp
        ).opened
    }

    /// Open URLs in a brand-new Chrome window and return both success and created window ID when available.
    ///
    /// - Parameters:
    ///   - targetURLs: URLs to open in the new window (first URL becomes the initial tab).
    ///   - centeredBounds: Optional frame in window-coordinate space (top-left origin).
    ///   - activateApp: Whether to bring Chrome to front after creation.
    /// - Returns: Tuple with `opened` and best-effort `windowID`.
    static public func openURLsInNewWindowWithResult(
        _ targetURLs: [String],
        centeredBounds: CGRect? = nil,
        activateApp: Bool = true
    ) -> (opened: Bool, windowID: Int?) {
        let normalizedURLs = targetURLs
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        guard !normalizedURLs.isEmpty else {
            return (opened: false, windowID: nil)
        }

        let script = ChromeAppleScript.openURLsInNewWindow(
            normalizedURLs,
            bounds: centeredBounds,
            activate: activateApp
        )

        do {
            let result = try run(script: script)
            let windowID = parseAppleScriptInt(result)
            if let centeredBounds {
                DeskJigLog.info(
                    .restorationChrome,
                    "Opened new Chrome window for URLs \(normalizedURLs.count) [\(formatURLListForLog(normalizedURLs))] at \(formatBoundsForLog(centeredBounds)) (activate=\(activateApp ? "true" : "false"), id=\(windowID.map(String.init) ?? "nil"))"
                )
            } else {
                DeskJigLog.info(
                    .restorationChrome,
                    "Opened new Chrome window for URLs \(normalizedURLs.count) [\(formatURLListForLog(normalizedURLs))] (activate=\(activateApp ? "true" : "false"), id=\(windowID.map(String.init) ?? "nil"))"
                )
            }
            return (opened: true, windowID: windowID)
        } catch {
            DeskJigLog.error(.restorationChrome, "Failed to open new Chrome window for URLs - \(error.localizedDescription)")
            return (opened: false, windowID: nil)
        }
    }

    /// Open URL in a brand-new Chrome window and optionally place it at exact bounds.
    /// This intentionally avoids reusing existing tabs/windows.
    ///
    /// - Parameters:
    ///   - targetURL: URL to open in the new window.
    ///   - centeredBounds: Optional frame in window-coordinate space (top-left origin).
    /// - Returns: true when AppleScript command succeeds.
    static public func openURLInNewWindow(
        _ targetURL: String,
        centeredBounds: CGRect? = nil,
        activateApp: Bool = true
    ) -> Bool {
        openURLsInNewWindow([targetURL], centeredBounds: centeredBounds, activateApp: activateApp)
    }

    /// Close tabs not in the saved list using Chrome window ID (preferred over bounds-based)
    static public func closeTabsNotInList(_ urls: [String], inWindowWithChromeId chromeWindowId: Int) {
        guard !urls.isEmpty else {
            DeskJigLog.info(.restorationChrome, "closeTabsNotInList[ID]: No URLs provided, skipping")
            return
        }
        guard isChromeRunning() else {
            DeskJigLog.warn(.restorationChrome, "closeTabsNotInList[ID]: Chrome is not running")
            return
        }

        guard let tabInfo = fetchTabURLs(inWindowWithChromeId: chromeWindowId) else {
            DeskJigLog.warn(.restorationChrome, "closeTabsNotInList[ID]: Could not capture current tabs for Chrome ID \(chromeWindowId)")
            return
        }

        var remainingTargets = urls
        var tabsToClose: [Int] = []

        for (index, existingURL) in tabInfo.urls.enumerated() {
            if let matchIndex = remainingTargets.firstIndex(where: { urlsAreEquivalent($0, existingURL) }) {
                remainingTargets.remove(at: matchIndex)
            } else {
                tabsToClose.append(index + 1) // 1-based index
            }
        }

        if tabsToClose.isEmpty {
            DeskJigLog.info(.restorationChrome, "closeTabsNotInList[ID]: No extra tabs to close")
            return
        }

        if tabsToClose.count >= tabInfo.urls.count {
            DeskJigLog.info(.restorationChrome, "closeTabsNotInList[ID]: Keeping one tab to prevent window close")
            tabsToClose.removeLast()
        }

        if tabsToClose.isEmpty {
            DeskJigLog.info(.restorationChrome, "closeTabsNotInList[ID]: No tabs to close after safety check")
            return
        }

        tabsToClose.sort(by: >)

        DeskJigLog.info(.restorationChrome, "closeTabsNotInList[ID]: Closing \(tabsToClose.count) extra tab(s): \(tabsToClose)")
        closeTabs(at: tabsToClose, inWindowWithChromeId: chromeWindowId)
        DeskJigLog.info(.restorationChrome, "closeTabsNotInList[ID]: Completed")
    }

    /// Close multiple tabs (1-based indices) in a single AppleScript round-trip using Chrome window ID.
    ///
    /// `indices` MUST be supplied in descending order (the caller's responsibility — see the
    /// `tabsToClose.sort(by: >)` + keep-one-tab safety in `closeTabsNotInList`/`closeNewTabPages`),
    /// so closing a higher index never shifts a lower one. The per-index `count of tabs` guard
    /// safely skips stale/over-range indices. This replaces the previous one-osascript-subprocess-
    /// per-tab loop with a single round-trip (chrome-04).
    static private func closeTabs(at indices: [Int], inWindowWithChromeId chromeWindowId: Int) {
        guard !indices.isEmpty else { return }

        let script = ChromeAppleScript.closeTabs(at: indices, inWindowID: chromeWindowId)

        do {
            try execute(script: script)
            DeskJigLog.debug(.restorationChrome, "closeTabs[ID]: Closed \(indices.count) tab(s) \(indices) in Chrome window \(chromeWindowId)")
        } catch {
            DeskJigLog.error(.restorationChrome, "closeTabs[ID]: Failed to close tabs \(indices) - \(error.localizedDescription)")
        }
    }

    // MARK: - Bounds-based Tab Operations (fallback)

    static public func openMissingTabs(_ urls: [String], inWindowWithBounds bounds: CGRect) {
        guard !urls.isEmpty else {
            DeskJigLog.info(.restorationChrome, "openMissingTabs: No URLs to open, returning")
            return
        }
        guard isChromeRunning() else {
            DeskJigLog.warn(.restorationChrome, "openMissingTabs: Cannot open tabs, Chrome is not running")
            return
        }

        let boundsStr = formatBoundsForLog(bounds)
        DeskJigLog.info(.restorationChrome, "openMissingTabs: window \(boundsStr) requested=\(urls.count) [\(formatURLListForLog(urls))]")

        // Pre-filter: Get current tabs and check which URLs are truly missing using normalized comparison
        // This prevents duplicates when URLs differ only by www., trailing slash, etc.
        if let capture = captureTabs(forWindowWithBounds: bounds) {
            DeskJigLog.info(.restorationChrome, "openMissingTabs: existing=\(capture.tabURLs.count) [\(formatURLListForLog(capture.tabURLs))]")

            // Filter out URLs that are already open (using normalized comparison)
            let trulyMissingURLs = urls.filter { candidateURL in
                let isAlreadyOpen = capture.tabURLs.contains { existingURL in
                    urlsAreEquivalent(candidateURL, existingURL)
                }
                return !isAlreadyOpen
            }

            if trulyMissingURLs.isEmpty {
                DeskJigLog.info(.restorationChrome, "openMissingTabs: All requested URLs already open, nothing to do")
                return
            }

            DeskJigLog.info(.restorationChrome, "openMissingTabs: missing=\(trulyMissingURLs.count) [\(formatURLListForLog(trulyMissingURLs))]")

            // Only open truly missing URLs
            openTabsInWindow(urls: trulyMissingURLs, bounds: bounds)
        } else {
            DeskJigLog.warn(.restorationChrome, "openMissingTabs: Could not capture current tabs, opening all URLs")
            openTabsInWindow(urls: urls, bounds: bounds)
        }
    }

    static public func openTabs(_ urls: [String], inWindowWithBounds bounds: CGRect) {
        guard !urls.isEmpty else {
            DeskJigLog.info(.restorationChrome, "openTabs: No URLs to open, returning")
            return
        }
        guard isChromeRunning() else {
            DeskJigLog.warn(.restorationChrome, "openTabs: Cannot open tabs, Chrome is not running")
            return
        }

        let boundsStr = formatBoundsForLog(bounds)
        DeskJigLog.info(.restorationChrome, "openTabs: window \(boundsStr) opening=\(urls.count) [\(formatURLListForLog(urls))]")
        openTabsInWindow(urls: urls, bounds: bounds)
    }
    
    /// Internal helper to open tabs via AppleScript (no duplicate checking)
    static private func openTabsInWindow(urls: [String], bounds: CGRect) {
        guard !urls.isEmpty else { return }
        
        let script = ChromeAppleScript.appendTabs(urls, matchingBounds: bounds)

        do {
            try executeInProcess(script: script)
            DeskJigLog.info(.restorationChrome, "openTabsInWindow: Opened \(urls.count) tab(s) [\(formatURLListForLog(urls))]")
        } catch {
            DeskJigLog.error(.restorationChrome, "openTabsInWindow: Failed - \(error.localizedDescription)")
        }
    }

    static public func setActiveTab(index: Int, inWindowWithBounds bounds: CGRect) {
        guard index > 0 else {
            if verboseLogging { DeskJigLog.debug(.restorationChrome, "setActiveTab invalid index \(index)") }
            return
        }
        guard isChromeRunning() else {
            DeskJigLog.warn(.restorationChrome, "Cannot set active tab - not running")
            return
        }

        let boundsStr = String(format: "(%.0f, %.0f)", bounds.origin.x, bounds.origin.y)

        let script = ChromeAppleScript.setActiveTab(index: index, matchingBounds: bounds)

        do {
            try executeInProcess(script: script)
            DeskJigLog.info(.restorationChrome, "Chrome @ \(boundsStr): Set active tab to \(index)")
        } catch {
            DeskJigLog.error(.restorationChrome, "Chrome @ \(boundsStr): Failed to set active tab - \(error.localizedDescription)")
        }
    }

    /// Close only chrome://newtab/ tabs (new tab pages)
    /// This preserves all other existing tabs while removing empty new tab pages
    static public func closeNewTabPages(inWindowWithBounds bounds: CGRect) {
        guard isChromeRunning() else {
            DeskJigLog.warn(.restorationChrome, "closeNewTabPages: Chrome is not running")
            return
        }

        let boundsStr = formatBoundsForLog(bounds)
        DeskJigLog.info(.restorationChrome, "closeNewTabPages: window \(boundsStr)")

        // Get current tabs in the window
        guard let capture = captureTabs(forWindowWithBounds: bounds) else {
            DeskJigLog.warn(.restorationChrome, "closeNewTabPages: Could not find window at bounds")
            return
        }

        DeskJigLog.info(.restorationChrome, "closeNewTabPages: existing=\(capture.tabURLs.count) [\(formatURLListForLog(capture.tabURLs))]")
        
        // URLs that represent Chrome's new tab page
        let newTabURLs = [
            "chrome://newtab/",
            "chrome://newtab",
            "chrome://new-tab-page/",
            "chrome://new-tab-page",
            "about:newtab",
            "about:blank"
        ]
        
        // Find new tab pages to close
        // Tab indices are 1-based in AppleScript, and we need to close from end to avoid index shifting
        var tabsToClose: [Int] = []
        for (index, existingURL) in capture.tabURLs.enumerated() {
            let isNewTabPage = newTabURLs.contains { newTabURL in
                existingURL.lowercased().hasPrefix(newTabURL.lowercased())
            }
            if isNewTabPage {
                tabsToClose.append(index + 1) // Convert to 1-based index
            } else {
                continue
            }
        }

        if tabsToClose.isEmpty {
            DeskJigLog.info(.restorationChrome, "closeNewTabPages: No new tab pages to close")
            return
        }

        // Don't close if it's the only tab (would close the window)
        if tabsToClose.count >= capture.tabURLs.count {
            DeskJigLog.info(.restorationChrome, "closeNewTabPages: All tabs are new tab pages, keeping one to prevent window close")
            tabsToClose.removeLast() // Keep at least one tab
        }

        if tabsToClose.isEmpty {
            DeskJigLog.info(.restorationChrome, "closeNewTabPages: No tabs to close after safety check")
            return
        }

        // Close tabs from highest index to lowest to avoid index shifting issues
        tabsToClose.sort(by: >)

        DeskJigLog.info(.restorationChrome, "closeNewTabPages: Closing \(tabsToClose.count) new tab page(s): \(tabsToClose)")

        for tabIndex in tabsToClose {
            closeTab(at: tabIndex, inWindowWithBounds: bounds)
        }

        DeskJigLog.info(.restorationChrome, "closeNewTabPages: Completed")
    }

    /// Close only chrome://newtab/ pages using Chrome window ID (preferred over bounds-based)
    static public func closeNewTabPages(inWindowWithChromeId chromeWindowId: Int) {
        guard isChromeRunning() else {
            DeskJigLog.warn(.restorationChrome, "closeNewTabPages[ID]: Chrome is not running")
            return
        }

        DeskJigLog.info(.restorationChrome, "closeNewTabPages[ID]: Chrome window \(chromeWindowId)")

        // Get current tabs in the window
        guard let capture = captureTabs(forWindowWithChromeId: chromeWindowId) else {
            DeskJigLog.warn(.restorationChrome, "closeNewTabPages[ID]: Could not find window with Chrome ID \(chromeWindowId)")
            return
        }

        DeskJigLog.info(.restorationChrome, "closeNewTabPages[ID]: existing=\(capture.tabURLs.count) [\(formatURLListForLog(capture.tabURLs))]")

        // URLs that represent Chrome's new tab page
        let newTabURLs = [
            "chrome://newtab/",
            "chrome://newtab",
            "chrome://new-tab-page/",
            "chrome://new-tab-page",
            "about:newtab",
            "about:blank"
        ]

        // Find new tab pages to close
        // Tab indices are 1-based in AppleScript, and we need to close from end to avoid index shifting
        var tabsToClose: [Int] = []
        for (index, existingURL) in capture.tabURLs.enumerated() {
            let isNewTabPage = newTabURLs.contains { newTabURL in
                existingURL.lowercased().hasPrefix(newTabURL.lowercased())
            }
            if isNewTabPage {
                tabsToClose.append(index + 1) // Convert to 1-based index
            } else {
                continue
            }
        }

        if tabsToClose.isEmpty {
            DeskJigLog.info(.restorationChrome, "closeNewTabPages[ID]: No new tab pages to close")
            return
        }

        // Don't close if it's the only tab (would close the window)
        if tabsToClose.count >= capture.tabURLs.count {
            DeskJigLog.info(.restorationChrome, "closeNewTabPages[ID]: All tabs are new tab pages, keeping one to prevent window close")
            tabsToClose.removeLast() // Keep at least one tab
        }

        if tabsToClose.isEmpty {
            DeskJigLog.info(.restorationChrome, "closeNewTabPages[ID]: No tabs to close after safety check")
            return
        }

        // Close tabs from highest index to lowest to avoid index shifting issues
        tabsToClose.sort(by: >)

        DeskJigLog.info(.restorationChrome, "closeNewTabPages[ID]: Closing \(tabsToClose.count) new tab page(s): \(tabsToClose)")
        closeTabs(at: tabsToClose, inWindowWithChromeId: chromeWindowId)
        DeskJigLog.info(.restorationChrome, "closeNewTabPages[ID]: Completed")
    }

    static public func closeTabsNotInList(_ urls: [String], inWindowWithBounds bounds: CGRect) {
        guard !urls.isEmpty else {
            DeskJigLog.info(.restorationChrome, "closeTabsNotInList: No URLs provided, skipping")
            return
        }
        guard isChromeRunning() else {
            DeskJigLog.warn(.restorationChrome, "closeTabsNotInList: Chrome is not running")
            return
        }

        guard let capture = captureTabs(forWindowWithBounds: bounds) else {
            DeskJigLog.warn(.restorationChrome, "closeTabsNotInList: Could not capture current tabs")
            return
        }

        var remainingTargets = urls
        var tabsToClose: [Int] = []

        for (index, existingURL) in capture.tabURLs.enumerated() {
            if let matchIndex = remainingTargets.firstIndex(where: { urlsAreEquivalent($0, existingURL) }) {
                remainingTargets.remove(at: matchIndex)
            } else {
                tabsToClose.append(index + 1) // 1-based index
            }
        }

        if tabsToClose.isEmpty {
            DeskJigLog.info(.restorationChrome, "closeTabsNotInList: No extra tabs to close")
            return
        }

        if tabsToClose.count >= capture.tabURLs.count {
            DeskJigLog.info(.restorationChrome, "closeTabsNotInList: Keeping one tab to prevent window close")
            tabsToClose.removeLast()
        }

        if tabsToClose.isEmpty {
            DeskJigLog.info(.restorationChrome, "closeTabsNotInList: No tabs to close after safety check")
            return
        }

        tabsToClose.sort(by: >)

        DeskJigLog.info(.restorationChrome, "closeTabsNotInList: Closing \(tabsToClose.count) extra tab(s): \(tabsToClose)")
        for tabIndex in tabsToClose {
            closeTab(at: tabIndex, inWindowWithBounds: bounds)
        }
        DeskJigLog.info(.restorationChrome, "closeTabsNotInList: Completed")
    }
    
    /// Close a specific tab by index (1-based) in a window
    static private func closeTab(at tabIndex: Int, inWindowWithBounds bounds: CGRect) {
        let script = ChromeAppleScript.closeTab(at: tabIndex, matchingBounds: bounds)
        
        do {
            try executeInProcess(script: script)
            DeskJigLog.debug(.restorationChrome, "closeTab: Closed tab \(tabIndex)")
        } catch {
            DeskJigLog.error(.restorationChrome, "closeTab: Failed to close tab \(tabIndex) - \(error.localizedDescription)")
        }
    }

    @discardableResult
    static public func launchChromeWindow(profileDirectory: String, urls: [String]) -> Bool {
        DeskJigLog.info(.restorationChrome, "launchChromeWindow: profile=\(profileDirectory) urls=\(urls.count) [\(formatURLListForLog(urls))]")

        var arguments: [String] = ["-na", "Google Chrome", "--args", "--new-window", "--profile-directory=\(profileDirectory)"]
        arguments.append(contentsOf: urls)

        if verboseLogging {
            DeskJigLog.debug(.restorationChrome, "launchChromeWindow: command=/usr/bin/open \(arguments.joined(separator: " "))")
        }

        let process = Process()
        process.launchPath = "/usr/bin/open"
        process.arguments = arguments

        do {
            try process.run()
            DeskJigLog.info(.restorationChrome, "launchChromeWindow: Successfully launched")
            return true
        } catch {
            DeskJigLog.error(.restorationChrome, "launchChromeWindow: Failed - \(error.localizedDescription)")
            return false
        }
    }

    /// Check if Chrome is currently running
    static public func isChromeRunning() -> Bool {
        let runningApps = NSWorkspace.shared.runningApplications
        return runningApps.contains { app in
            chromeBundleIdentifiers.contains(app.bundleIdentifier ?? "")
        }
    }
}

// MARK: - Internal helpers (accessible from other files in DeskJigShared)

extension ChromeAutomationService {
    /// Parse profile name from Chrome window title (e.g., "Page - Google Chrome - ProfileName" -> "ProfileName")
    static func parseProfileName(from title: String) -> String? {
        let delimiters = [
            " - Google Chrome - ",  // regular hyphen
            " - Google Chrome – ",  // en dash
            " - Google Chrome — "   // em dash
        ]

        for delimiter in delimiters {
            if let range = title.range(of: delimiter, options: .backwards) {
                let profileName = title[range.upperBound...]
                return profileName.isEmpty ? nil : String(profileName)
            }
        }
        return nil
    }

    /// Normalize a URL for comparison purposes using URL class
    /// Handles: trailing slashes, www prefix, http vs https, case sensitivity, port numbers
    public static func normalizeURL(_ urlString: String) -> String {
        // Try to parse as URL
        guard let url = URL(string: urlString) else {
            // Fallback to basic string normalization if URL parsing fails
            DeskJigLog.debug(.restorationChrome, "normalizeURL: Failed to parse '\(urlString)' as URL, using string fallback")
            return urlString.lowercased()
                .replacingOccurrences(of: "https://", with: "")
                .replacingOccurrences(of: "http://", with: "")
                .replacingOccurrences(of: "www.", with: "")
                .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        }

        // Extract and normalize host
        var host = url.host?.lowercased() ?? ""

        // Remove www. prefix from host
        if host.hasPrefix("www.") {
            host = String(host.dropFirst(4))
        }

        // Normalize path - remove trailing slash and index files
        var path = url.path
        if path.hasSuffix("/") {
            path = String(path.dropLast())
        }
        if path.hasSuffix("/index.html") || path.hasSuffix("/index.htm") {
            path = String(path.dropLast(path.hasSuffix("/index.html") ? 11 : 10))
        }
        // Empty path or just "/" becomes empty
        if path == "/" {
            path = ""
        }

        // Include query string if present (some URLs are differentiated by query)
        let query = url.query ?? ""

        // Preserve non-default ports so localhost:3000 and localhost:62047 don't collapse.
        let scheme = url.scheme?.lowercased()
        let defaultPort: Int? = {
            switch scheme {
            case "http":
                return 80
            case "https":
                return 443
            default:
                return nil
            }
        }()
        let hostWithPort: String
        if let port = url.port, defaultPort != port {
            hostWithPort = "\(host):\(port)"
        } else {
            hostWithPort = host
        }

        // Build normalized URL: host(+port) + path + query
        var normalized = hostWithPort + path
        if !query.isEmpty {
            normalized += "?" + query
        }

        return normalized
    }

    /// Check whether a saved/target URL is already represented by an existing tab URL.
    ///
    /// Matching is directional:
    /// - `targetURL` is the saved URL from the workspace
    /// - `existingURL` is the currently open tab URL
    ///
    /// Uses multi-tier matching:
    /// 1. Exact normalized comparison (host + path + query)
    /// 2. Host fallback when the target URL is host-root only (e.g., https://mail.google.com)
    /// 3. Base domain matching for auth/redirect URLs (e.g., signin.aws.amazon.com matches console.aws.amazon.com)
    public static func urlsAreEquivalent(_ targetURL: String, _ existingURL: String) -> Bool {
        let normalizedTarget = normalizeURL(targetURL)
        let normalizedExisting = normalizeURL(existingURL)

        // Never collapse different localhost ports, regardless of normalization tier.
        if let targetComponents = urlMatchComponents(from: targetURL),
           let existingComponents = urlMatchComponents(from: existingURL),
           targetComponents.isLoopbackHost,
           existingComponents.isLoopbackHost,
           targetComponents.effectivePort != existingComponents.effectivePort {
            if verboseLogging {
                DeskJigLog.debug(
                    .restorationChrome,
                    "URL mismatch (localhost port preflight): '\(formatURLForLog(targetURL))' != '\(formatURLForLog(existingURL))' [targetPort=\(targetComponents.effectivePort.map(String.init) ?? "nil") existingPort=\(existingComponents.effectivePort.map(String.init) ?? "nil")]"
                )
            }
            return false
        }

        // Tier 1: Exact normalized match
        if normalizedTarget == normalizedExisting {
            if verboseLogging && targetURL != existingURL {
                DeskJigLog.debug(
                    .restorationChrome,
                    "URL match (exact): '\(formatURLForLog(targetURL))' = '\(formatURLForLog(existingURL))'"
                )
            }
            return true
        }

        // Tier 2: If the target is a host-root URL, allow any route on that same host.
        if let targetComponents = urlMatchComponents(from: targetURL),
           let existingComponents = urlMatchComponents(from: existingURL),
           targetComponents.host == existingComponents.host,
           targetComponents.isHostRoot {
            if targetComponents.isLoopbackHost || existingComponents.isLoopbackHost {
                guard targetComponents.effectivePort == existingComponents.effectivePort else {
                    if verboseLogging {
                        DeskJigLog.debug(
                            .restorationChrome,
                            "URL mismatch (localhost port): '\(formatURLForLog(targetURL))' != '\(formatURLForLog(existingURL))' [targetPort=\(targetComponents.effectivePort.map(String.init) ?? "nil") existingPort=\(existingComponents.effectivePort.map(String.init) ?? "nil")]"
                        )
                    }
                    return false
                }
            }
            if verboseLogging {
                DeskJigLog.debug(
                    .restorationChrome,
                    "URL match (host fallback): '\(formatURLForLog(targetURL))' = '\(formatURLForLog(existingURL))' [host=\(targetComponents.host)]"
                )
            }
            return true
        }

        // Tier 3: Base domain match for auth-related URLs
        // This handles redirects like: console.aws.amazon.com → signin.aws.amazon.com
        let baseDomain1 = extractBaseDomain(from: targetURL)
        let baseDomain2 = extractBaseDomain(from: existingURL)

        if !baseDomain1.isEmpty && baseDomain1 == baseDomain2 {
            // Check if either URL contains auth-related patterns
            let authPatterns = ["signin", "login", "auth", "oauth", "sso", "saml", "identity", "account", "sessions"]
            let url1Lower = targetURL.lowercased()
            let url2Lower = existingURL.lowercased()
            let hasAuthPattern = authPatterns.contains { url1Lower.contains($0) || url2Lower.contains($0) }

            if hasAuthPattern {
                if verboseLogging {
                    DeskJigLog.debug(
                        .restorationChrome,
                        "URL match (base domain + auth): '\(formatURLForLog(targetURL))' = '\(formatURLForLog(existingURL))' [domain=\(baseDomain1)]"
                    )
                }
                return true
            }
        }

        return false
    }
}

// MARK: - Private helpers

private extension ChromeAutomationService {
    struct WindowDescriptor {
        let identifier: Int
        let name: String
        let tabURLs: [String]
        let activeTabIndex: Int?
        let bounds: CGRect?  // Window bounds from Chrome (optional for backwards compatibility)
    }

    struct SystemWindow {
        let title: String
        let bounds: CGRect
    }

    // MARK: - Osascript Error Categorization

    enum OsascriptErrorCategory: String {
        case permissionDenied       // "not allowed to send Apple events", error 1743
        case assistiveAccessDenied  // "not allowed assistive access", error -25211
        case timeout                // osascript timed out
        case processNotFound        // "doesn't exist", process not running
        case executionError         // generic AppleScript execution error

        var isRetryable: Bool {
            switch self {
            case .permissionDenied, .timeout: return true
            case .assistiveAccessDenied, .processNotFound, .executionError: return false
            }
        }

        static func categorize(result: AppleScriptProcessResult) -> OsascriptErrorCategory {
            if result.timedOut { return .timeout }
            let stderr = result.errorOutput.lowercased()
            if stderr.contains("assistive access") || stderr.contains("-25211") {
                return .assistiveAccessDenied
            }
            if stderr.contains("not allowed") || stderr.contains("1743") || stderr.contains("not permitted") {
                return .permissionDenied
            }
            if stderr.contains("doesn't exist") || stderr.contains("not running") || stderr.contains("not find") {
                return .processNotFound
            }
            return .executionError
        }
    }

    static func fetchChromeWindowDescriptorsViaOsascript(includeTabURLs: Bool) -> [WindowDescriptor] {
        let script = ChromeAppleScript.windowDescriptors(
            includeTabURLs: includeTabURLs,
            output: .delimitedText
        )

        let result = AppleScriptRunner.runOsascript(script, timeout: osascriptTimeout)

        // On failure, categorize and retry once for retryable errors
        if result.exitCode != 0 || result.timedOut {
            let category = OsascriptErrorCategory.categorize(result: result)
            DeskJigLog.warn(.restorationChrome, "fetchChromeWindowDescriptors osascript failed: category=\(category.rawValue) stderr=\(result.errorOutput)")

            if category.isRetryable {
                if category == .permissionDenied {
                    resetTCCWarmupState()
                    warmupTCCIfNeeded()
                }
                Thread.sleep(forTimeInterval: 0.5)
                DeskJigLog.info(.restorationChrome, "fetchChromeWindowDescriptors retrying after \(category.rawValue)")
                let retryResult = AppleScriptRunner.runOsascript(script, timeout: osascriptTimeout)
                if retryResult.exitCode == 0 && !retryResult.timedOut {
                    return parseChromeWindowDescriptors(from: retryResult)
                }
                let retryCategory = OsascriptErrorCategory.categorize(result: retryResult)
                DeskJigLog.warn(.restorationChrome, "fetchChromeWindowDescriptors retry also failed: category=\(retryCategory.rawValue) stderr=\(retryResult.errorOutput)")
            }
            return []
        }

        if !result.errorOutput.isEmpty {
            DeskJigLog.warn(.restorationChrome, "fetchChromeWindowDescriptors osascript stderr: \(result.errorOutput)")
        }

        return parseChromeWindowDescriptors(from: result)
    }

    /// Parse Chrome window descriptors from osascript output.
    private static func parseChromeWindowDescriptors(from result: AppleScriptProcessResult) -> [WindowDescriptor] {
        let output = result.trimmedOutput
        guard !output.isEmpty else {
            if verboseLogging { DeskJigLog.debug(.restorationChrome, "fetchChromeWindowDescriptors osascript returned empty output") }
            return []
        }

        var descriptors: [WindowDescriptor] = []
        for line in output.split(separator: "\n") {
            let parts = line.split(separator: "\t", omittingEmptySubsequences: false)
            // When includeTabURLs=false, osascript output may end the line with a trailing tab.
            // trimmedOutput removes the trailing tab on the last line, leaving only 4 parts.
            guard parts.count >= 4 else { continue }

            let identifier = Int(parts[0]) ?? 0
            let name = String(parts[1])
            let activeTabIndex = Int(parts[2])

            let boundsParts = parts[3].split(separator: ",")
            var bounds: CGRect?
            if boundsParts.count == 4,
               let x = Double(boundsParts[0]),
               let y = Double(boundsParts[1]),
               let width = Double(boundsParts[2]),
               let height = Double(boundsParts[3]) {
                bounds = CGRect(x: x, y: y, width: width, height: height)
            }

            let tabString: String
            if parts.count >= 5 {
                if parts.count > 5 {
                    tabString = parts[4...].map(String.init).joined(separator: "\t")
                } else {
                    tabString = String(parts[4])
                }
            } else {
                tabString = ""
            }
            let tabURLs = tabString.isEmpty ? [] : tabString.components(separatedBy: "^^^")

            descriptors.append(
                WindowDescriptor(
                    identifier: identifier,
                    name: name,
                    tabURLs: tabURLs,
                    activeTabIndex: activeTabIndex,
                    bounds: bounds
                )
            )
        }

        if verboseLogging {
            let summaries = descriptors.map { descriptor in
                let boundsStr = descriptor.bounds.map { formatBoundsForLog($0) } ?? "nil"
                return "id=\(descriptor.identifier) name='\(truncateForLog(descriptor.name))' bounds=\(boundsStr) tabs=\(descriptor.tabURLs.count)"
            }
            DeskJigLog.debug(.restorationChrome, "fetchChromeWindowDescriptors (osascript): \(descriptors.count) descriptor(s) [\(summaries.joined(separator: " | "))]")
        }

        return descriptors
    }

    static func fetchSystemEventWindows() -> [SystemWindow] {
        warmupTCCIfNeeded()
        if verboseLogging { DeskJigLog.debug(.restorationChrome, "fetchSystemEventWindows - fetching via System Events...") }

        // Always use NSAppleScript (in-process) for System Events window property access.
        // osascript subprocess requires its own Accessibility (assistive access) permission,
        // which only DeskJig.app has. NSAppleScript runs in-process and inherits DeskJig's Accessibility.
        let script = """
        tell application "System Events"
          if (exists process "Google Chrome") is false then
            return {}
          end if
          tell process "Google Chrome"
            set out to {}
            repeat with i from 1 to count of windows
              set windowName to name of window i as string
              set windowPos to position of window i
              set windowSize to size of window i
              set x to item 1 of windowPos
              set y to item 2 of windowPos
              set width to item 1 of windowSize
              set height to item 2 of windowSize
              set end of out to {windowName, x, y, width, height}
            end repeat
            return out
          end tell
        end tell
        """

        do {
            guard let result = try run(script: script) else {
                if verboseLogging { DeskJigLog.debug(.restorationChrome, "fetchSystemEventWindows - script returned nil") }
                return []
            }
            let windows = result.toSystemWindowArray()
            if verboseLogging {
                let summaries = windows.map { window in
                    "title='\(truncateForLog(window.title))' bounds=\(formatBoundsForLog(window.bounds))"
                }
                DeskJigLog.debug(.restorationChrome, "fetchSystemEventWindows: \(windows.count) window(s) [\(summaries.joined(separator: " | "))]")
            }
            return windows
        } catch {
            DeskJigLog.error(.restorationChrome, "fetchSystemEventWindows failed - \(error.localizedDescription)")
            return []
        }
    }

    static func fetchChromeWindowDescriptors(includeTabURLs: Bool) -> [WindowDescriptor] {
        warmupTCCIfNeeded()
        if verboseLogging { DeskJigLog.debug(.restorationChrome, "fetchChromeWindowDescriptors - fetching via Chrome AppleScript...") }

        if shouldUseOsascript {
            return fetchChromeWindowDescriptorsViaOsascript(includeTabURLs: includeTabURLs)
        }

        let script = ChromeAppleScript.windowDescriptors(
            includeTabURLs: includeTabURLs,
            output: .appleEventList
        )

        do {
            guard let result = try run(script: script) else {
                if verboseLogging { DeskJigLog.debug(.restorationChrome, "fetchChromeWindowDescriptors - script returned nil") }
                return []
            }
            let descriptors = result.toWindowDescriptorArray()
            if verboseLogging {
                let summaries = descriptors.map { descriptor in
                    let boundsStr = descriptor.bounds.map { formatBoundsForLog($0) } ?? "nil"
                    return "id=\(descriptor.identifier) name='\(truncateForLog(descriptor.name))' bounds=\(boundsStr) tabs=\(descriptor.tabURLs.count)"
                }
                DeskJigLog.debug(.restorationChrome, "fetchChromeWindowDescriptors: \(descriptors.count) descriptor(s) [\(summaries.joined(separator: " | "))]")
            }
            return descriptors
        } catch {
            DeskJigLog.error(.restorationChrome, "fetchChromeWindowDescriptors failed - \(error.localizedDescription)")
            return []
        }
    }

    static func execute(script: String) throws {
        if shouldUseOsascript {
            let result = AppleScriptRunner.runOsascript(script, timeout: osascriptTimeout)
            if result.timedOut {
                throw ChromeAutomationError.executionFailed(result.errorOutput)
            }
            if result.exitCode != 0 {
                let message = result.errorOutput.isEmpty ? "osascript exited with code \(result.exitCode)" : result.errorOutput
                throw ChromeAutomationError.executionFailed(message)
            }
            return
        }

        _ = try run(script: script)
    }

    /// Execute a script that contains System Events window property access (position, size, name).
    /// Always uses NSAppleScript (in-process) regardless of `shouldUseOsascript`, because
    /// System Events UI element access requires the calling process to have Accessibility permission.
    /// DeskJig.app has this permission; osascript does not and cannot be granted it by the app.
    static func executeInProcess(script: String) throws {
        _ = try run(script: script)
    }

    static func run(script: String) throws -> NSAppleEventDescriptor? {
        let result: NSAppleEventDescriptor
        do {
            result = try AppleScriptRunner.runInProcess(script)
        } catch let error as AppleScriptError {
            if error.stage == .compile {
                throw ChromeAutomationError.compilationFailed
            }
            throw ChromeAutomationError.executionFailed(error.message)
        }

        // Return nil for "missing value" or empty descriptors
        if result.stringValue == "missing value" {
            return nil
        }

        if result.descriptorType == typeAEList && result.numberOfItems == 0 {
            return nil
        }

        return result
    }

    private static func parseAppleScriptInt(_ descriptor: NSAppleEventDescriptor?) -> Int? {
        guard let descriptor else { return nil }
        let intValue = Int(descriptor.int32Value)
        if intValue > 0 {
            return intValue
        }
        if let stringValue = descriptor.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
           let parsed = Int(stringValue),
           parsed > 0 {
            return parsed
        }
        return nil
    }

    /// Extract the base domain from a URL (e.g., "aws.amazon.com" from "console.aws.amazon.com")
    /// Returns the last 2-3 parts of the domain depending on TLD structure
    private static func extractBaseDomain(from urlString: String) -> String {
        guard let url = URL(string: urlString),
              let host = url.host?.lowercased() else {
            return ""
        }

        let parts = host.split(separator: ".").map(String.init)

        // Handle common multi-part TLDs
        let multiPartTLDs = ["co.uk", "com.au", "co.nz", "co.jp", "com.br", "com.mx"]
        let lastTwoParts = parts.suffix(2).joined(separator: ".")

        if multiPartTLDs.contains(lastTwoParts) && parts.count >= 3 {
            // e.g., example.co.uk → return last 3 parts
            return parts.suffix(3).joined(separator: ".")
        } else if parts.count >= 2 {
            // e.g., console.aws.amazon.com → amazon.com (last 2 parts)
            // But for aws.amazon.com, we want aws.amazon.com (service subdomain matters)
            // Use last 3 parts if available to capture service-level domains
            if parts.count >= 3 {
                return parts.suffix(3).joined(separator: ".")
            }
            return parts.suffix(2).joined(separator: ".")
        }

        return host
    }

    private struct URLMatchComponents {
        let scheme: String
        let host: String
        let port: Int?
        let path: String
        let hasQuery: Bool

        var isHostRoot: Bool {
            path.isEmpty && !hasQuery
        }

        var effectivePort: Int? {
            if let port {
                return port
            }
            switch scheme {
            case "http":
                return 80
            case "https":
                return 443
            default:
                return nil
            }
        }

        var isLoopbackHost: Bool {
            host == "localhost" || host == "127.0.0.1" || host == "::1"
        }
    }

    private static func urlMatchComponents(from urlString: String) -> URLMatchComponents? {
        guard let url = URL(string: urlString),
              let scheme = url.scheme?.lowercased(),
              var host = url.host?.lowercased() else {
            return nil
        }

        if host.hasPrefix("www.") {
            host = String(host.dropFirst(4))
        }

        var path = url.path
        if path.hasSuffix("/") {
            path = String(path.dropLast())
        }
        if path.hasSuffix("/index.html") || path.hasSuffix("/index.htm") {
            path = String(path.dropLast(path.hasSuffix("/index.html") ? 11 : 10))
        }
        if path == "/" {
            path = ""
        }

        let hasQuery = !(url.query ?? "").isEmpty

        return URLMatchComponents(
            scheme: scheme,
            host: host,
            port: url.port,
            path: path,
            hasQuery: hasQuery
        )
    }

}

// MARK: - Descriptor helpers

private extension NSAppleEventDescriptor {
    func toStringArray() -> [String] {
        guard descriptorType == typeAEList else { return [] }
        var result: [String] = []
        if numberOfItems == 0 { return result }
        for index in 1...numberOfItems {
            if let item = atIndex(index)?.stringValue {
                result.append(item)
            }
        }
        return result
    }

    func toSystemWindowArray() -> [ChromeAutomationService.SystemWindow] {
        guard descriptorType == typeAEList else { return [] }
        var windows: [ChromeAutomationService.SystemWindow] = []

        for index in 1...numberOfItems {
            guard let item = atIndex(index) else { continue }
            let title = item.atIndex(1)?.stringValue ?? ""
            let x = CGFloat(item.atIndex(2)?.int32Value ?? 0)
            let y = CGFloat(item.atIndex(3)?.int32Value ?? 0)
            let width = CGFloat(item.atIndex(4)?.int32Value ?? 0)
            let height = CGFloat(item.atIndex(5)?.int32Value ?? 0)

            windows.append(
                ChromeAutomationService.SystemWindow(
                    title: title,
                    bounds: CGRect(x: x, y: y, width: width, height: height)
                )
            )
        }

        return windows
    }

    func toWindowDescriptorArray() -> [ChromeAutomationService.WindowDescriptor] {
        guard descriptorType == typeAEList else { return [] }
        var descriptors: [ChromeAutomationService.WindowDescriptor] = []

        for index in 1...numberOfItems {
            guard let item = atIndex(index) else { continue }
            let identifier = item.atIndex(1)?.int32Value ?? -1
            let name = item.atIndex(2)?.stringValue ?? ""
            let activeIndexValue = item.atIndex(3)?.int32Value
            let tabListDescriptor = item.atIndex(4)
            let tabURLs = tabListDescriptor?.toStringArray() ?? []

            // Parse bounds from Chrome (format: {x1, y1, x2, y2})
            var bounds: CGRect? = nil
            if let boundsDescriptor = item.atIndex(5),
               boundsDescriptor.numberOfItems >= 4 {
                // Chrome bounds format: {left, top, right, bottom}
                let x1 = CGFloat(boundsDescriptor.atIndex(1)?.int32Value ?? 0)
                let y1 = CGFloat(boundsDescriptor.atIndex(2)?.int32Value ?? 0)
                let x2 = CGFloat(boundsDescriptor.atIndex(3)?.int32Value ?? 0)
                let y2 = CGFloat(boundsDescriptor.atIndex(4)?.int32Value ?? 0)
                bounds = CGRect(x: x1, y: y1, width: x2 - x1, height: y2 - y1)
            }

            descriptors.append(
                ChromeAutomationService.WindowDescriptor(
                    identifier: Int(identifier),
                    name: name,
                    tabURLs: tabURLs,
                    activeTabIndex: activeIndexValue != nil ? Int(activeIndexValue!) : nil,
                    bounds: bounds
                )
            )
        }

        return descriptors
    }
}

// MARK: - Errors

enum ChromeAutomationError: Error {
    case compilationFailed
    case executionFailed(String)
}
