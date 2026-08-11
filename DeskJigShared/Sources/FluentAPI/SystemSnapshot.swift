//  SystemSnapshot.swift
//  DeskJigShared

import Foundation
import AppKit
import CoreGraphics

// MARK: - Chrome Supplementation Status

/// Status of Chrome window supplementation during restoration.
/// Chrome windows need additional data (profile names from AX titles, tab URLs)
/// that isn't available in quick CGWindowList captures.
public enum ChromeSupplementationStatus: String, Sendable {
    /// Window is not Chrome - no supplementation needed
    case notRequired
    /// Chrome window awaiting supplementation (profile/tab data not yet fetched)
    case pending
    /// Chrome window fully enriched with profile and tab data
    case completed
    /// Supplementation failed (timeout or error)
    case failed
}

// MARK: - Terminal Supplementation Status

/// Status of terminal window supplementation during restoration.
/// Terminal windows need additional data (working directory) that isn't
/// available in quick CGWindowList captures.
public enum TerminalSupplementationStatus: String, Sendable {
    /// Window is not a terminal - no supplementation needed
    case notRequired
    /// Terminal window awaiting supplementation (working directory not yet fetched)
    case pending
    /// Terminal window fully enriched with working directory
    case completed
    /// Supplementation failed (timeout or error)
    case failed
}

/// Source of the working directory data during terminal supplementation.
public enum TerminalWorkingDirectorySource: String, Sendable {
    /// Retrieved via kAXDocument attribute (most reliable)
    case axDocument
    /// Parsed from window title (less reliable)
    case titleParse
    /// Obtained via lsof command (slow but reliable fallback)
    case lsof
    /// Obtained via iTerm session TTY mapping (fallback for terminal shells)
    case tty
}

/// Method for fetching terminal working directories during supplementation.
public enum TerminalFetchMethod: String, Sendable, CaseIterable {
    /// Use AX API (kAXDocument) - fastest, ~10-50ms
    case axAPI
    /// Use lsof to find working directory from process - slower, ~100-200ms
    case lsof
    /// Parse from window title (least reliable but instant)
    case titleParse
    /// Try AX first, fall back to lsof if unavailable
    case axWithLsofFallback
    /// Skip supplementation entirely
    case disabled
}

// MARK: - IDE Supplementation Status

/// Status of IDE window supplementation during restoration.
/// IDE windows need additional data (document path/project folder) that isn't
/// reliably available in quick CGWindowList captures.
public enum IDESupplementationStatus: String, Sendable {
    /// Window is not an IDE - no supplementation needed
    case notRequired
    /// IDE window awaiting supplementation (document path not yet fetched)
    case pending
    /// IDE window fully enriched with document/project path
    case completed
    /// Supplementation failed (timeout or error)
    case failed
}

/// Source of the document path data during IDE supplementation.
public enum IDEDocumentPathSource: String, Sendable {
    /// Retrieved from Cursor's storage.json (most reliable for Cursor)
    case cursorState
    /// Retrieved via kAXDocument attribute
    case axDocument
    /// Parsed from window title (less reliable)
    case titleParse
    /// Derived via process tree cwd lookup (lsof fallback)
    case processTreeLsof
}

/// Method for fetching IDE document paths during supplementation.
public enum IDEFetchMethod: String, Sendable, CaseIterable {
    /// Use Cursor state file (storage.json) - reliable for Cursor
    case cursorState
    /// Use AX API (kAXDocument)
    case axAPI
    /// Use Cursor state first, fall back to AX if unavailable
    case cursorStateWithAXFallback
    /// Skip supplementation entirely
    case disabled
}

// MARK: - Display Info

public struct DisplayInfo: Sendable, Identifiable {
    public let displayID: CGDirectDisplayID
    public let frame: CGRect
    public let visibleFrame: CGRect
    public let isMain: Bool
    public let index: Int
    public let name: String?
    public let scaleFactor: CGFloat

    public var id: CGDirectDisplayID { displayID }

    public init(
        displayID: CGDirectDisplayID,
        frame: CGRect,
        visibleFrame: CGRect,
        isMain: Bool,
        index: Int,
        name: String? = nil,
        scaleFactor: CGFloat = 1.0
    ) {
        self.displayID = displayID
        self.frame = frame
        self.visibleFrame = visibleFrame
        self.isMain = isMain
        self.index = index
        self.name = name
        self.scaleFactor = scaleFactor
    }
}

// MARK: - Snapshot Window

public struct SnapshotWindow: Sendable, Identifiable {
    // Core (from CGWindowList)
    public let windowId: CGWindowID
    public let pid: pid_t
    public let bundleId: String?
    public let appName: String?
    public let title: String?
    public let frame: CGRect
    public let layer: Int
    public let isOnScreen: Bool

    // Display mapping
    public let displayID: CGDirectDisplayID?
    public let displayIndex: Int?

    // Z-order (0 = frontmost, increases toward back)
    public let zOrderIndex: Int?

    // AX enrichment (may be nil if not enriched)
    public var documentPath: String?
    public var isMinimized: Bool?
    public var isFullScreen: Bool?

    // Chrome-specific (parsed from title)
    public var chromeProfileName: String?

    // Chrome supplementation fields (populated by ChromeSupplementationService)
    /// Status of Chrome data supplementation
    public var supplementationStatus: ChromeSupplementationStatus?
    /// Fresh AX title with full profile info (e.g., "GitHub - Google Chrome - Work")
    public var freshAxTitle: String?
    /// Profile name extracted from freshAxTitle (e.g., "Work")
    public var chromeProfileFromTitle: String?
    /// Tab URLs fetched via AppleScript or Native Extension
    public var chromeTabUrls: [String]?

    // Terminal supplementation fields (populated by TerminalSupplementationService)
    /// Status of terminal data supplementation
    public var terminalSupplementationStatus: TerminalSupplementationStatus?
    /// Working directory fetched via AX API (reliable path extraction)
    public var freshWorkingDirectory: String?
    /// Method used to obtain the working directory (ax, lsof, title)
    public var workingDirectorySource: TerminalWorkingDirectorySource?

    // IDE supplementation fields (populated by IDESupplementationService)
    /// Status of IDE data supplementation
    public var ideSupplementationStatus: IDESupplementationStatus?
    /// Document/project path fetched via Cursor state or AX API
    public var ideDocumentPath: String?
    /// Method used to obtain the document path
    public var ideDocumentPathSource: IDEDocumentPathSource?

    // AX accessibility verification
    /// Whether this window is accessible via Accessibility API.
    /// nil = not checked, true = accessible, false = zombie window (exists in CGWindowList but not AX)
    public var isAXAccessible: Bool?

    // Identity for delta detection
    public var id: String { "\(pid)-\(windowId)" }

    public init(
        windowId: CGWindowID,
        pid: pid_t,
        bundleId: String?,
        appName: String?,
        title: String?,
        frame: CGRect,
        layer: Int,
        isOnScreen: Bool,
        displayID: CGDirectDisplayID? = nil,
        displayIndex: Int? = nil,
        zOrderIndex: Int? = nil,
        documentPath: String? = nil,
        isMinimized: Bool? = nil,
        isFullScreen: Bool? = nil,
        chromeProfileName: String? = nil,
        supplementationStatus: ChromeSupplementationStatus? = nil,
        freshAxTitle: String? = nil,
        chromeProfileFromTitle: String? = nil,
        chromeTabUrls: [String]? = nil,
        terminalSupplementationStatus: TerminalSupplementationStatus? = nil,
        freshWorkingDirectory: String? = nil,
        workingDirectorySource: TerminalWorkingDirectorySource? = nil,
        ideSupplementationStatus: IDESupplementationStatus? = nil,
        ideDocumentPath: String? = nil,
        ideDocumentPathSource: IDEDocumentPathSource? = nil,
        isAXAccessible: Bool? = nil
    ) {
        self.windowId = windowId
        self.pid = pid
        self.bundleId = bundleId
        self.appName = appName
        self.title = title
        self.frame = frame
        self.layer = layer
        self.isOnScreen = isOnScreen
        self.displayID = displayID
        self.displayIndex = displayIndex
        self.zOrderIndex = zOrderIndex
        self.documentPath = documentPath
        self.isMinimized = isMinimized
        self.isFullScreen = isFullScreen
        self.chromeProfileName = chromeProfileName
        self.supplementationStatus = supplementationStatus
        self.freshAxTitle = freshAxTitle
        self.chromeProfileFromTitle = chromeProfileFromTitle
        self.chromeTabUrls = chromeTabUrls
        self.terminalSupplementationStatus = terminalSupplementationStatus
        self.freshWorkingDirectory = freshWorkingDirectory
        self.workingDirectorySource = workingDirectorySource
        self.ideSupplementationStatus = ideSupplementationStatus
        self.ideDocumentPath = ideDocumentPath
        self.ideDocumentPathSource = ideDocumentPathSource
        self.isAXAccessible = isAXAccessible
    }

    /// Check if frame approximately matches another frame
    public func frameMatches(_ other: CGRect, tolerance: CGFloat = 10) -> Bool {
        frame.approximatelyEquals(other, tolerance: tolerance)
    }
}

// MARK: - Chrome Window Capture

public struct ChromeWindowCapture: Sendable {
    public let profileDirectory: String
    public let profileName: String
    public let chromeWindowId: Int
    public let tabUrls: [String]
    public let activeTabIndex: Int

    public init(
        profileDirectory: String,
        profileName: String,
        chromeWindowId: Int,
        tabUrls: [String],
        activeTabIndex: Int
    ) {
        self.profileDirectory = profileDirectory
        self.profileName = profileName
        self.chromeWindowId = chromeWindowId
        self.tabUrls = tabUrls
        self.activeTabIndex = activeTabIndex
    }
}

// MARK: - System Snapshot

public struct SystemSnapshot: Sendable {
    public let captureTime: Date
    public let captureDurationMs: Int
    public let runId: String

    // Timing breakdown per phase
    public let timing: [String: Int]

    // Display info
    public let displays: [DisplayInfo]

    // Windows from CGWindowList (fast)
    public let windows: [SnapshotWindow]

    // Indexes
    public let byPID: [pid_t: [SnapshotWindow]]
    public let byBundleID: [String: [SnapshotWindow]]
    public let byDisplayID: [CGDirectDisplayID: [SnapshotWindow]]

    // Chrome-specific (captured in parallel, may be empty)
    public let chromeCaptures: [ChromeWindowCapture]

    // MARK: - Initialization

    public init(
        captureTime: Date,
        captureDurationMs: Int,
        runId: String,
        timing: [String: Int] = [:],
        displays: [DisplayInfo],
        windows: [SnapshotWindow],
        chromeCaptures: [ChromeWindowCapture] = []
    ) {
        self.captureTime = captureTime
        self.captureDurationMs = captureDurationMs
        self.runId = runId
        self.timing = timing
        self.displays = displays
        self.windows = windows
        self.chromeCaptures = chromeCaptures

        // Build indexes
        var byPID: [pid_t: [SnapshotWindow]] = [:]
        var byBundleID: [String: [SnapshotWindow]] = [:]
        var byDisplayID: [CGDirectDisplayID: [SnapshotWindow]] = [:]

        for window in windows {
            byPID[window.pid, default: []].append(window)
            if let bundleId = window.bundleId {
                byBundleID[bundleId, default: []].append(window)
            }
            if let displayID = window.displayID {
                byDisplayID[displayID, default: []].append(window)
            }
        }

        self.byPID = byPID
        self.byBundleID = byBundleID
        self.byDisplayID = byDisplayID
    }

    // MARK: - Delta Detection

    /// Returns windows that appeared since the previous snapshot
    public func windowsAppeared(since previous: SystemSnapshot) -> [SnapshotWindow] {
        let previousIds = Set(previous.windows.map { $0.id })
        return windows.filter { !previousIds.contains($0.id) }
    }

    /// Returns windows that disappeared since the previous snapshot
    public func windowsDisappeared(since previous: SystemSnapshot) -> [SnapshotWindow] {
        let currentIds = Set(windows.map { $0.id })
        return previous.windows.filter { !currentIds.contains($0.id) }
    }

    /// Find windows matching a bundle ID
    public func windows(forBundleID bundleId: String) -> [SnapshotWindow] {
        byBundleID[bundleId] ?? []
    }

    /// Find windows for a specific PID
    public func windows(forPID pid: pid_t) -> [SnapshotWindow] {
        byPID[pid] ?? []
    }

    /// Find windows on a specific display
    public func windows(onDisplay displayID: CGDirectDisplayID) -> [SnapshotWindow] {
        byDisplayID[displayID] ?? []
    }

    /// Find a window by its CGWindowID
    public func window(byId windowId: CGWindowID) -> SnapshotWindow? {
        windows.first { $0.windowId == windowId }
    }

    /// Find windows matching a frame (with tolerance)
    public func windows(matchingFrame frame: CGRect, tolerance: CGFloat = 10) -> [SnapshotWindow] {
        windows.filter { $0.frameMatches(frame, tolerance: tolerance) }
    }
}

// MARK: - Snapshot Capture

public enum SystemSnapshotCapture {
    /// Capture a full system snapshot
    /// - Parameters:
    ///   - runId: The restoration run ID for logging
    ///   - includeChromeCapture: Whether to capture Chrome tab state (slower, ~200ms)
    ///   - includeAXEnrichment: Whether to enrich with AX data (slower, ~50ms)
    ///   - minWindowSize: Minimum window size to include (default 65x65, filters tiny auxiliary windows)
    /// - Returns: The captured snapshot
    public static func capture(
        runId: String,
        includeChromeCapture: Bool = false,
        includeAXEnrichment: Bool = false,
        axEnrichmentBundleAllowlist: Set<String>? = nil,
        axAccessibilityBundleAllowlist: Set<String>? = nil,
        minWindowSize: CGSize = CGSize(width: 65, height: 65),
        windowListOption: CGWindowListOption = [.optionAll]
    ) async -> SystemSnapshot {
        let startTime = Date()
        var timing: [String: Int] = [:]

        // Phase 1: Capture displays
        let displayStart = Date()
        let displays = await captureDisplays()
        timing["displays"] = Int(Date().timeIntervalSince(displayStart) * 1000)

        // Phase 2: Capture windows
        let windowStart = Date()
        var windows = await captureWindows(
            minWindowSize: minWindowSize,
            runId: runId,
            axAccessibilityBundleAllowlist: axAccessibilityBundleAllowlist,
            windowListOption: windowListOption
        )
        timing["windows"] = Int(Date().timeIntervalSince(windowStart) * 1000)

        // Phase 3: Map windows to displays
        let mapStart = Date()
        windows = mapWindowsToDisplays(windows: windows, displays: displays)
        timing["mapping"] = Int(Date().timeIntervalSince(mapStart) * 1000)

        // Phase 4: Chrome capture (optional)
        var chromeCaptures: [ChromeWindowCapture] = []
        if includeChromeCapture {
            let chromeStart = Date()
            chromeCaptures = await captureChromeState()
            timing["chrome"] = Int(Date().timeIntervalSince(chromeStart) * 1000)
        }

        // Phase 5: AX enrichment for IDE windows (optional)
        if includeAXEnrichment {
            let axStart = Date()
            windows = await enrichWithAXData(windows: windows, bundleAllowlist: axEnrichmentBundleAllowlist)
            timing["ax_enrichment"] = Int(Date().timeIntervalSince(axStart) * 1000)
        }

        let captureDurationMs = Int(Date().timeIntervalSince(startTime) * 1000)

        return SystemSnapshot(
            captureTime: startTime,
            captureDurationMs: captureDurationMs,
            runId: runId,
            timing: timing,
            displays: displays,
            windows: windows,
            chromeCaptures: chromeCaptures
        )
    }

    /// Quick capture without optional enrichment (~10ms)
    public static func captureQuick(
        runId: String,
        minWindowSize: CGSize = CGSize(width: 65, height: 65)
    ) async -> SystemSnapshot {
        await capture(runId: runId, includeChromeCapture: false, includeAXEnrichment: false, minWindowSize: minWindowSize)
    }

    /// Quick capture filtered to windows of a single bundle ID.
    ///
    /// Used by polling loops (e.g., `waitForWindowAndPosition`) that only need windows
    /// for one specific app, avoiding the overhead of processing all system windows.
    public static func captureForBundle(
        bundleId: String,
        runId: String,
        minWindowSize: CGSize = CGSize(width: 65, height: 65)
    ) async -> SystemSnapshot {
        // Fast path (snap-02 / snap-03): scope AX zombie verification to the target
        // bundle's PIDs only, instead of verifying every app's off-screen titled windows
        // system-wide. The returned (filtered) windows are identical to the old
        // captureQuick+filter — the target bundle was always verified — but we skip the
        // AX round-trips for all other apps' off-screen windows, which is the per-poll win.
        let snapshot = await capture(
            runId: runId,
            includeChromeCapture: false,
            includeAXEnrichment: false,
            axAccessibilityBundleAllowlist: [bundleId],
            minWindowSize: minWindowSize
        )
        let filtered = snapshot.windows.filter { $0.bundleId == bundleId }
        return SystemSnapshot(
            captureTime: snapshot.captureTime,
            captureDurationMs: snapshot.captureDurationMs,
            runId: snapshot.runId,
            timing: snapshot.timing,
            displays: snapshot.displays,
            windows: filtered,
            chromeCaptures: snapshot.chromeCaptures
        )
    }

    /// Quick capture of *on-screen* windows only.
    ///
    /// Useful for post-restore z-order checks and cleanup where off-screen windows cannot
    /// visually occlude restored workspace windows.
    public static func captureQuickOnScreenOnly(
        runId: String,
        minWindowSize: CGSize = CGSize(width: 65, height: 65)
    ) async -> SystemSnapshot {
        await capture(
            runId: runId,
            includeChromeCapture: false,
            includeAXEnrichment: false,
            minWindowSize: minWindowSize,
            windowListOption: [.optionOnScreenOnly, .excludeDesktopElements]
        )
    }

    /// Capture WindowInfo values using the snapshot engine.
    public static func captureWindowInfos(
        runId: String,
        minWindowSize: CGSize = CGSize(width: 65, height: 65),
        includeHidden: Bool = true,
        includeAXEnrichment: Bool = false,
        excludeCurrentApp: Bool = true,
        excludeSystemWindows: Bool = true
    ) async -> [WindowInfo] {
        let snapshot = await capture(
            runId: runId,
            includeChromeCapture: false,
            includeAXEnrichment: includeAXEnrichment,
            minWindowSize: minWindowSize
        )
        return snapshot.windowInfos(
            includeHidden: includeHidden,
            excludeCurrentApp: excludeCurrentApp,
            excludeSystemWindows: excludeSystemWindows
        )
    }

    /// Calculate the visibility percentage of a window (how much is NOT occluded by windows above it).
    public static func calculateWindowVisibility(
        _ windowInfo: WindowInfo,
        gridResolution: Int = 20,
        currentWindows: [WindowInfo],
        zOrderMap: [Int: Int]? = nil
    ) -> Double {
        let windowLevel = zOrderMap?[windowInfo.id] ?? windowInfo.windowLevel
        let windowsAbove = currentWindows.filter { other in
            let otherLevel = zOrderMap?[other.id] ?? other.windowLevel
            return otherLevel < windowLevel &&
                !other.isMinimized &&
                !other.isHidden
        }

        guard !windowsAbove.isEmpty else {
            return 1.0
        }

        let overlappingWindowsAbove = windowsAbove.filter { $0.frame.intersects(windowInfo.frame) }
        guard !overlappingWindowsAbove.isEmpty else {
            return 1.0
        }

        if overlappingWindowsAbove.contains(where: { fullyCovers($0.frame, target: windowInfo.frame) }) {
            return 0.0
        }

        let cellWidth = windowInfo.frame.width / CGFloat(gridResolution)
        let cellHeight = windowInfo.frame.height / CGFloat(gridResolution)

        var visibleCells = 0
        let totalCells = gridResolution * gridResolution

        for row in 0..<gridResolution {
            for col in 0..<gridResolution {
                let cellCenterX = windowInfo.frame.origin.x + (CGFloat(col) + 0.5) * cellWidth
                let cellCenterY = windowInfo.frame.origin.y + (CGFloat(row) + 0.5) * cellHeight
                let cellCenter = CGPoint(x: cellCenterX, y: cellCenterY)

                var isCovered = false
                for windowAbove in overlappingWindowsAbove {
                    if windowAbove.frame.contains(cellCenter) {
                        isCovered = true
                        break
                    }
                }

                if !isCovered {
                    visibleCells += 1
                }
            }
        }

        return Double(visibleCells) / Double(totalCells)
    }

    private static func fullyCovers(_ occluder: CGRect, target: CGRect, tolerance: CGFloat = 1.0) -> Bool {
        let expanded = occluder.insetBy(dx: -tolerance, dy: -tolerance)
        return expanded.contains(target)
    }

    /// Get windows that meet a minimum visibility threshold.
    public static func visibleWindowInfos(
        minVisibility: Double = 0.5,
        includeMinimized: Bool = false,
        includeHidden: Bool = false,
        currentWindows: [WindowInfo]? = nil,
        runId: String,
        minWindowSize: CGSize = CGSize(width: 65, height: 65),
        includeAXEnrichment: Bool = false,
        excludeCurrentApp: Bool = true,
        excludeSystemWindows: Bool = true
    ) async -> [WindowInfo] {
        let windowsToUse: [WindowInfo]
        if let currentWindows {
            windowsToUse = currentWindows
        } else {
            windowsToUse = await captureWindowInfos(
                runId: runId,
                minWindowSize: minWindowSize,
                includeHidden: true,
                includeAXEnrichment: includeAXEnrichment,
                excludeCurrentApp: excludeCurrentApp,
                excludeSystemWindows: excludeSystemWindows
            )
        }
        let zOrderMap = buildOnScreenZOrderMap(minWindowSize: minWindowSize)

        // Debug logging: Log all Chrome windows found before visibility filtering
        let chromeWindows = windowsToUse.filter { chromeBundleIdentifiers.contains($0.bundleIdentifier ?? "") }
        if !chromeWindows.isEmpty {
            DeskJigLog.debug(.restorationChrome, "visibleWindowInfos: Found \(chromeWindows.count) Chrome window(s) before visibility filter")
            for chrome in chromeWindows {
                // Determine which monitor based on frame.origin.x
                // Monitor 0 (left) typically has negative X, Monitor 1 (right/primary) has positive X
                let monitorGuess = chrome.frame.origin.x < 0 ? "Monitor 0 (left)" : "Monitor 1 (right)"
                DeskJigLog.trace(.restorationChrome, "  Chrome window: '\(chrome.windowTitle)' frame=\(chrome.frame) level=\(chrome.windowLevel) \(monitorGuess) isHidden=\(chrome.isHidden)")
            }
        }

        var result: [WindowInfo] = []
        for window in windowsToUse {
            if !includeMinimized && window.isMinimized {
                continue
            }
            if !includeHidden && window.isHidden {
                continue
            }
            // Note: We no longer filter out windows with empty titles here.
            // Chrome windows can have empty titles in CGWindowList but valid titles via AX API.
            // These windows will display as "Untitled" in the preview if needed.

            let visibility = calculateWindowVisibility(window, currentWindows: windowsToUse, zOrderMap: zOrderMap)

            // Debug logging: Log visibility calculation for Chrome windows with detailed occlusion info
            if chromeBundleIdentifiers.contains(window.bundleIdentifier ?? "") {
                let passes = visibility >= minVisibility
                DeskJigLog.trace(.restorationChrome, "Chrome window '\(window.windowTitle)' visibility: \(String(format: "%.0f%%", visibility * 100)), threshold: \(String(format: "%.0f%%", minVisibility * 100)), passes: \(passes)")

                // Log which windows are occluding this Chrome window
                if visibility < 1.0 {
                    let windowLevel = zOrderMap[window.id] ?? window.windowLevel
                    let windowsAbove = windowsToUse.filter { other in
                        let otherLevel = zOrderMap[other.id] ?? other.windowLevel
                        return otherLevel < windowLevel &&
                            !other.isMinimized &&
                            !other.isHidden &&
                            other.frame.intersects(window.frame)
                    }
                    if !windowsAbove.isEmpty {
                        DeskJigLog.trace(.restorationChrome, "  Occluding windows (level < \(window.windowLevel)):")
                        for occluder in windowsAbove.prefix(5) {
                            DeskJigLog.trace(.restorationChrome, "    - '\(occluder.appName)' level=\(occluder.windowLevel) frame=\(occluder.frame)")
                        }
                        if windowsAbove.count > 5 {
                            DeskJigLog.trace(.restorationChrome, "    ... and \(windowsAbove.count - 5) more")
                        }
                    }
                }
            }

            if visibility >= minVisibility {
                result.append(window)
            }
        }

        result.sort { (left, right) in
            let leftLevel = zOrderMap[left.id] ?? left.windowLevel
            let rightLevel = zOrderMap[right.id] ?? right.windowLevel
            return leftLevel < rightLevel
        }
        return result
    }

    private static func buildOnScreenZOrderMap(minWindowSize: CGSize) -> [Int: Int] {
        let onScreenOptions: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let onScreenList = CGWindowListCopyWindowInfo(onScreenOptions, kCGNullWindowID) as? [[String: Any]] else {
            return [:]
        }

        var mapping: [Int: Int] = [:]
        var index = 0
        for dict in onScreenList {
            guard let windowId = dict[kCGWindowNumber as String] as? Int,
                  let boundsDict = dict[kCGWindowBounds as String] as? [String: CGFloat],
                  let width = boundsDict["Width"],
                  let height = boundsDict["Height"] else {
                continue
            }

            let layer = dict[kCGWindowLayer as String] as? Int ?? 0
            guard layer == 0 else { continue }
            guard width >= minWindowSize.width, height >= minWindowSize.height else { continue }

            mapping[windowId] = index
            index += 1
        }

        return mapping
    }

    // MARK: - Private Capture Methods

    private static func captureDisplays() async -> [DisplayInfo] {
        var displayCount: UInt32 = 0
        CGGetActiveDisplayList(0, nil, &displayCount)

        guard displayCount > 0 else { return [] }

        var displayIDs = [CGDirectDisplayID](repeating: 0, count: Int(displayCount))
        CGGetActiveDisplayList(displayCount, &displayIDs, &displayCount)

        let mainDisplayID = CGMainDisplayID()

        return displayIDs.enumerated().map { index, displayID in
            let bounds = CGDisplayBounds(displayID)

            // Get visible frame, name, and scale factor from NSScreen
            let screen = NSScreen.screens.first(where: { $0.displayID == displayID })
            let visibleFrame = screen?.visibleFrame ?? bounds
            let name = screen?.localizedName
            let scaleFactor = screen?.backingScaleFactor ?? 1.0

            return DisplayInfo(
                displayID: displayID,
                frame: bounds,
                visibleFrame: visibleFrame,
                isMain: displayID == mainDisplayID,
                index: index,
                name: name,
                scaleFactor: scaleFactor
            )
        }
    }
    /// Builds the front-to-back z-order map for layer-0, min-size on-screen windows
    /// from a dedicated on-screen CGWindowList (snap-11). Kept separate from the
    /// .optionAll list because that list's ordering is not trusted for z-order.
    private static func buildOnScreenZOrderMap(
        from onScreenList: [[String: Any]],
        minWindowSize: CGSize
    ) -> [CGWindowID: Int] {
        var map: [CGWindowID: Int] = [:]
        var index = 0
        for dict in onScreenList {
            guard let record = CGWindowRecord(dict: dict),
                  record.layer == 0,
                  record.frame.width >= minWindowSize.width,
                  record.frame.height >= minWindowSize.height else {
                continue
            }
            map[record.windowId] = index
            index += 1
        }
        return map
    }

    private static func captureWindows(
        minWindowSize: CGSize,
        runId: String,
        axAccessibilityBundleAllowlist: Set<String>? = nil,
        windowListOption: CGWindowListOption = [.optionAll]
    ) async -> [SnapshotWindow] {
        guard let windowList = CGWindowListCopyWindowInfo(windowListOption, kCGNullWindowID) as? [[String: Any]] else {
            return []
        }

        // Build on-screen z-order mapping (front-to-back) for layer-0 windows.
        // NOTE: the dedicated on-screen list is intentional — the .optionAll list's
        // ordering is NOT trusted for z-order (see the windowZOrder assignment below), so
        // snap-01's "derive z-order from the single .optionAll list" idea was rejected.
        // We only dedupe the dictionary parsing (CGWindowRecord) and extract the loop.
        let onScreenList: [[String: Any]]
        if windowListOption.contains(.optionOnScreenOnly) {
            onScreenList = windowList
        } else {
            let onScreenOptions: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
            onScreenList = (CGWindowListCopyWindowInfo(onScreenOptions, kCGNullWindowID) as? [[String: Any]]) ?? []
        }
        let onScreenZOrder = buildOnScreenZOrderMap(from: onScreenList, minWindowSize: minWindowSize)

        // Build PID to app info mapping
        let apps = NSWorkspace.shared.runningApplications
        var pidToApp: [pid_t: (bundleId: String?, appName: String?)] = [:]
        for app in apps {
            pidToApp[app.processIdentifier] = (app.bundleIdentifier, app.localizedName)
        }

        var result: [SnapshotWindow] = []

        // Track filtered windows for logging
        var filteredCount = 0
        var filteredWindows: [(windowId: CGWindowID, size: CGSize, bundleId: String?)] = []

        for dict in windowList {
            guard let record = CGWindowRecord(dict: dict), let pid = record.pid else {
                continue
            }
            let windowId = record.windowId
            let x = record.frame.origin.x
            let y = record.frame.origin.y
            let width = record.frame.width
            let height = record.frame.height

            let layer = record.layer
            // Only include normal windows (layer 0)
            guard layer == 0 else { continue }

            let appInfo = pidToApp[pid]

            // Filter and LOG small windows
            guard width >= minWindowSize.width, height >= minWindowSize.height else {
                filteredCount += 1
                if filteredWindows.count < 10 { // Keep first 10 for logging
                    filteredWindows.append((windowId, CGSize(width: width, height: height), appInfo?.bundleId))
                }
                continue
            }

            let isOnScreen = record.isOnScreen
            let title = record.title

            // Determine supplementation status for Chrome windows
            let isChrome = chromeBundleIdentifiers.contains(appInfo?.bundleId ?? "")
            let supplementationStatus: ChromeSupplementationStatus = isChrome ? .pending : .notRequired

            // Determine supplementation status for terminal windows
            let isTerminal = BundleRegistry.isTerminal(appInfo?.bundleId ?? "")
            let terminalSupplementationStatus: TerminalSupplementationStatus = isTerminal ? .pending : .notRequired

            // Determine supplementation status for IDE windows
            let isIDE = BundleRegistry.isIDE(appInfo?.bundleId ?? "")
            let ideSupplementationStatus: IDESupplementationStatus = isIDE ? .pending : .notRequired

            // Only assign z-order to on-screen windows; off-screen windows get Int.max.
            // Use the on-screen z-order list to avoid ordering issues from optionAll.
            let windowZOrder = isOnScreen ? (onScreenZOrder[windowId] ?? Int.max) : Int.max

            let window = SnapshotWindow(
                windowId: windowId,
                pid: pid,
                bundleId: appInfo?.bundleId,
                appName: appInfo?.appName ?? (dict[kCGWindowOwnerName as String] as? String),
                title: title,
                frame: CGRect(x: x, y: y, width: width, height: height),
                layer: layer,
                isOnScreen: isOnScreen,
                zOrderIndex: windowZOrder,
                supplementationStatus: supplementationStatus,
                terminalSupplementationStatus: terminalSupplementationStatus,
                ideSupplementationStatus: ideSupplementationStatus
            )
            result.append(window)

        }

        // LOG filtered windows if any (only for actual restoration runs)
        if filteredCount > 0 && runId.hasPrefix("restore_") {
            let sizes = filteredWindows.map { max(Int($0.size.width), Int($0.size.height)) }
            DeskJigLog.trace(.restorationTrace, "Filtered small windows from snapshot", fields: [
                "filteredCount": "\(filteredCount)",
                "minSize": "\(Int(minWindowSize.width))x\(Int(minWindowSize.height))",
                "maxFilteredDimension": "\(sizes.max() ?? 0)"
            ], runId: runId)
            DeskJigLog.trace(.restorationTrace, "Filtered small windows detail", fields: [
                "filtered": filteredWindows.map { "\($0.windowId):\(Int($0.size.width))x\(Int($0.size.height))" }.joined(separator: ",")
            ], runId: runId)
        }

        // Verify AX accessibility for off-screen windows with titles (potential zombie windows)
        // This detects windows that exist in CGWindowList but are not accessible via Accessibility API
        result = verifyAXAccessibility(
            windows: result,
            runId: runId,
            bundleAllowlist: axAccessibilityBundleAllowlist
        )

        return result
    }

    /// Verify AX accessibility for off-screen windows to detect zombie windows.
    /// Zombie windows exist in CGWindowList but have no AX representation (e.g., after hide/unhide issues).
    private static func verifyAXAccessibility(
        windows: [SnapshotWindow],
        runId: String,
        bundleAllowlist: Set<String>? = nil
    ) -> [SnapshotWindow] {
        // Find off-screen windows with titles that need verification
        let offScreenIndices = windows.indices.filter { i in
            let w = windows[i]
            if let allowlist = bundleAllowlist, let bundleId = w.bundleId {
                if !allowlist.contains(bundleId) {
                    return false
                }
            } else if bundleAllowlist != nil {
                return false
            }
            return !w.isOnScreen && w.title != nil && !w.title!.isEmpty
        }

        guard !offScreenIndices.isEmpty else { return windows }

        // Group by PID for efficient AX queries
        let pidToIndices = Dictionary(grouping: offScreenIndices, by: { windows[$0].pid })

        var result = windows
        var zombieCount = 0

        for (pid, indices) in pidToIndices {
            // Get AX windows for this PID via the shared enumeration skeleton.
            // nil = AX copy failed; [] = no windows — both mean the CGWindowList windows are zombies.
            let axWindows = AXWindowService.shared.enumerateWindows(pid: pid)
            let axWindowCount = axWindows?.count ?? 0

            // If AX returns 0 windows but CGWindowList has windows, they're zombies
            if axWindowCount == 0 {
                for i in indices {
                    result[i].isAXAccessible = false
                    zombieCount += 1
                }
            } else if let axWindows {
                // Build set of AX window frames for matching
                let axFrames = axWindows.compactMap { $0.frame }

                // Check each off-screen window against AX frames
                for i in indices {
                    let window = result[i]
                    let hasMatchingAXWindow = axFrames.contains { axFrame in
                        abs(axFrame.origin.x - window.frame.origin.x) <= 5 &&
                        abs(axFrame.origin.y - window.frame.origin.y) <= 5 &&
                        abs(axFrame.width - window.frame.width) <= 5 &&
                        abs(axFrame.height - window.frame.height) <= 5
                    }
                    result[i].isAXAccessible = hasMatchingAXWindow
                    if !hasMatchingAXWindow {
                        zombieCount += 1
                    }
                }
            }
        }

        // Log zombie windows if found during restoration
        if zombieCount > 0 && runId.hasPrefix("restore_") {
            let zombieApps = Set(result.filter { $0.isAXAccessible == false }.compactMap { $0.appName }).sorted()
            DeskJigLog.trace(.restorationTrace, "Detected zombie windows (CGWindowList but no AX)", fields: [
                "zombieCount": "\(zombieCount)",
                "apps": zombieApps.joined(separator: ",")
            ], runId: runId)
            let zombieDetails = result.enumerated()
                .filter { $0.element.isAXAccessible == false }
                .map { "\($0.element.windowId):\($0.element.appName ?? "?"):\($0.element.title ?? "")" }
                .joined(separator: ", ")
            DeskJigLog.trace(.restorationTrace, "Zombie windows detail", fields: [
                "windows": zombieDetails
            ], runId: runId)
        }

        return result
    }

    private static func mapWindowsToDisplays(windows: [SnapshotWindow], displays: [DisplayInfo]) -> [SnapshotWindow] {
        windows.map { window in
            var mapped = window
            // Find the display that contains the window's center
            let windowCenter = CGPoint(x: window.frame.midX, y: window.frame.midY)
            if let display = displays.first(where: { $0.frame.contains(windowCenter) }) {
                mapped = SnapshotWindow(
                    windowId: window.windowId,
                    pid: window.pid,
                    bundleId: window.bundleId,
                    appName: window.appName,
                    title: window.title,
                    frame: window.frame,
                    layer: window.layer,
                    isOnScreen: window.isOnScreen,
                    displayID: display.displayID,
                    displayIndex: display.index,
                    zOrderIndex: window.zOrderIndex,
                    documentPath: window.documentPath,
                    isMinimized: window.isMinimized,
                    isFullScreen: window.isFullScreen,
                    chromeProfileName: window.chromeProfileName,
                    supplementationStatus: window.supplementationStatus,
                    freshAxTitle: window.freshAxTitle,
                    chromeProfileFromTitle: window.chromeProfileFromTitle,
                    chromeTabUrls: window.chromeTabUrls,
                    terminalSupplementationStatus: window.terminalSupplementationStatus,
                    freshWorkingDirectory: window.freshWorkingDirectory,
                    workingDirectorySource: window.workingDirectorySource,
                    ideSupplementationStatus: window.ideSupplementationStatus,
                    ideDocumentPath: window.ideDocumentPath,
                    ideDocumentPathSource: window.ideDocumentPathSource,
                    isAXAccessible: window.isAXAccessible
                )
            }
            return mapped
        }
    }

    private static func captureChromeState() async -> [ChromeWindowCapture] {
        // Check if Chrome is running
        let chromeApp = NSWorkspace.shared.runningApplications.first {
            $0.bundleIdentifier == "com.google.Chrome"
        }
        guard chromeApp != nil else {
            DeskJigLog.debug(.restorationChrome, "Chrome not found in NSWorkspace.runningApplications")
            return []
        }

        let script = ChromeAppleScript.windowSnapshotData

        let resultString: String?
        if AppleScriptRunner.shouldUseOsascript {
            let result = AppleScriptRunner.runOsascript(script, timeout: AppleScriptRunner.defaultTimeout)
            if result.timedOut {
                DeskJigLog.debug(.restorationChrome, "osascript timed out during Chrome capture")
                return []
            }
            if !result.errorOutput.isEmpty {
                DeskJigLog.debug(.restorationChrome, "osascript stderr: \(result.errorOutput)")
            }
            resultString = result.trimmedOutput
        } else {
            do {
                resultString = try AppleScriptRunner.runInProcess(script).stringValue
            } catch let error as AppleScriptError {
                DeskJigLog.error(.restorationChrome, "AppleScript execution failed: \(error.message) (error \(error.errorNumber ?? -1))")
                return []
            } catch {
                DeskJigLog.error(.restorationChrome, "AppleScript execution failed: \(error.localizedDescription)")
                return []
            }
        }

        guard let resultString, !resultString.isEmpty else {
            DeskJigLog.debug(
                .restorationChrome,
                "AppleScript returned empty result - Chrome windows may be inaccessible (minimized or on different space)"
            )
            return []
        }

        DeskJigLog.debug(.restorationChrome, "AppleScript returned: \(resultString.prefix(200))...")

        // Parse result: "1:::Profile Name:::2:::url1^^^url2###2:::Default:::1:::url3"
        var captures: [ChromeWindowCapture] = []

        let windowParts = resultString.components(separatedBy: "###")
        for windowData in windowParts {
            let parts = windowData.components(separatedBy: ":::")
            guard parts.count >= 4 else { continue }

            let windowIndex = Int(parts[0]) ?? 0
            let profileName = parts[1]
            let activeTabIndex = Int(parts[2]) ?? 0
            let tabUrlsString = parts[3]
            let tabUrls = tabUrlsString.isEmpty ? [] : tabUrlsString.components(separatedBy: "^^^")

            captures.append(ChromeWindowCapture(
                profileDirectory: profileName,  // Using profile name as directory for now
                profileName: profileName,
                chromeWindowId: windowIndex,
                tabUrls: tabUrls,
                activeTabIndex: activeTabIndex
            ))
        }

        DeskJigLog.debug(.restorationChrome, "Captured \(captures.count) Chrome windows with tab data")
        return captures
    }

    private static func enrichWithAXData(
        windows: [SnapshotWindow],
        bundleAllowlist: Set<String>? = nil
    ) async -> [SnapshotWindow] {
        var enriched = windows

        // Group windows by PID to avoid repeated AX queries for same app
        let windowsByPid = Dictionary(grouping: enriched.indices, by: { enriched[$0].pid })

        for (pid, indices) in windowsByPid {
            if let allowlist = bundleAllowlist {
                let hasAllowedWindow = indices.contains { index in
                    if let bundleId = enriched[index].bundleId {
                        return allowlist.contains(bundleId)
                    }
                    return false
                }
                if !hasAllowedWindow {
                    continue
                }
            }

            // Build AX window data for matching via the shared enumeration skeleton.
            // Use AXWindowNumber when available and enforce one-to-one matching so
            // stacked windows with identical frames don't all bind to the same AX window.
            guard let axWindows = AXWindowService.shared.enumerateWindows(
                pid: pid,
                includeTitle: true,
                includeWindowNumber: true
            ) else { continue }

            struct AXWindowData {
                let element: AXUIElement
                let title: String?
                let frame: CGRect?
                let windowId: CGWindowID?
                var matched: Bool
            }
            var axWindowData: [AXWindowData] = []
            for axWindow in axWindows {
                let trimmedTitle = axWindow.title?.trimmingCharacters(in: .whitespacesAndNewlines)
                let title = (trimmedTitle?.isEmpty ?? true) ? "Untitled" : trimmedTitle

                axWindowData.append(
                    AXWindowData(
                        element: axWindow.element,
                        title: title,
                        frame: axWindow.frame,
                        windowId: axWindow.windowNumber,
                        matched: false
                    )
                )
            }

            // Match each CGWindowList window to an AX window
            for i in indices {
                let window = enriched[i]

                var matchedAXWindow: AXUIElement? = nil
                var matchedAXTitle: String? = nil

                // Strategy 1: direct window number match.
                var matchedIndex = axWindowData.firstIndex(where: {
                    !$0.matched && $0.windowId == window.windowId
                })

                // Strategy 2: frame fallback (one-to-one).
                if matchedIndex == nil {
                    matchedIndex = axWindowData.firstIndex(where: { axData in
                        guard !axData.matched, let axFrame = axData.frame else { return false }
                        let tolerance: CGFloat = 5
                        return abs(axFrame.origin.x - window.frame.origin.x) <= tolerance &&
                               abs(axFrame.origin.y - window.frame.origin.y) <= tolerance &&
                               abs(axFrame.width - window.frame.width) <= tolerance &&
                               abs(axFrame.height - window.frame.height) <= tolerance
                    })
                }

                if let idx = matchedIndex {
                    matchedAXWindow = axWindowData[idx].element
                    matchedAXTitle = axWindowData[idx].title
                    axWindowData[idx].matched = true

                    if let axTitle = axWindowData[idx].title {
                        let isChrome = chromeBundleIdentifiers.contains(window.bundleId ?? "")
                        let currentTitle = window.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                        let needsTitleUpdate = isChrome || currentTitle.isEmpty || currentTitle == "Untitled"
                        let isReplacingWithUntitled = axTitle == "Untitled" && !currentTitle.isEmpty && currentTitle != "Untitled"

                        if needsTitleUpdate && !isReplacingWithUntitled && axTitle != currentTitle {
                            enriched[i] = SnapshotWindow(
                                windowId: window.windowId,
                                pid: window.pid,
                                bundleId: window.bundleId,
                                appName: window.appName,
                                title: axTitle,
                                frame: window.frame,
                                layer: window.layer,
                                isOnScreen: window.isOnScreen,
                                displayID: window.displayID,
                                displayIndex: window.displayIndex,
                                zOrderIndex: window.zOrderIndex,
                                documentPath: window.documentPath,
                                isMinimized: window.isMinimized,
                                isFullScreen: window.isFullScreen,
                                chromeProfileName: window.chromeProfileName,
                                supplementationStatus: window.supplementationStatus,
                                freshAxTitle: window.freshAxTitle,
                                chromeProfileFromTitle: window.chromeProfileFromTitle,
                                chromeTabUrls: window.chromeTabUrls,
                                terminalSupplementationStatus: window.terminalSupplementationStatus,
                                freshWorkingDirectory: window.freshWorkingDirectory,
                                workingDirectorySource: window.workingDirectorySource,
                                ideSupplementationStatus: window.ideSupplementationStatus,
                                ideDocumentPath: window.ideDocumentPath,
                                ideDocumentPathSource: window.ideDocumentPathSource,
                                isAXAccessible: window.isAXAccessible
                            )
                        }
                    }
                }

                // If we found a match, enrich with additional AX data
                if let axWindow = matchedAXWindow {
                    if let axTitle = matchedAXTitle,
                       chromeBundleIdentifiers.contains(window.bundleId ?? "") {
                        enriched[i].freshAxTitle = axTitle
                        enriched[i].chromeProfileFromTitle = ChromeAutomationService.parseProfileName(from: axTitle)
                    }

                    // Get document path
                    var docRef: CFTypeRef?
                    if AXUIElementCopyAttributeValue(axWindow, kAXDocumentAttribute as CFString, &docRef) == .success,
                       let docPath = docRef as? String {
                        enriched[i].documentPath = docPath.replacingOccurrences(of: "file://", with: "")
                    }

                    // Get minimized state
                    var minRef: CFTypeRef?
                    if AXUIElementCopyAttributeValue(axWindow, kAXMinimizedAttribute as CFString, &minRef) == .success {
                        enriched[i].isMinimized = (minRef as? Bool) ?? false
                    }

                    // Get fullscreen state
                    var fullscreenRef: CFTypeRef?
                    if AXUIElementCopyAttributeValue(axWindow, "AXFullScreen" as CFString, &fullscreenRef) == .success {
                        enriched[i].isFullScreen = (fullscreenRef as? Bool) ?? false
                    }
                }
            }
        }

        return enriched
    }
}

// MARK: - Report Generation

extension SystemSnapshot {
    /// Convert snapshot windows into WindowInfo values.
    public func windowInfos(
        includeHidden: Bool = true,
        excludeCurrentApp: Bool = true,
        excludeSystemWindows: Bool = true
    ) -> [WindowInfo] {
        let currentPid = ProcessInfo.processInfo.processIdentifier
        let infos = windows.compactMap { window -> WindowInfo? in
            if excludeCurrentApp && window.pid == currentPid {
                return nil
            }
            if excludeSystemWindows, let appName = window.appName, appName.contains("Window Server") {
                return nil
            }
            if !includeHidden && !window.isOnScreen {
                return nil
            }

            let trimmedTitle = (window.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let title = trimmedTitle.isEmpty ? "Untitled" : trimmedTitle
            let isMinimized = window.isMinimized ?? false
            let isHidden = isMinimized ? false : !window.isOnScreen
            let windowLevel = window.zOrderIndex ?? Int.max

            return WindowInfo(
                id: Int(window.windowId),
                appName: window.appName ?? "Unknown",
                windowTitle: title,
                frame: window.frame,
                processID: window.pid,
                bundleIdentifier: window.bundleId,
                isMinimized: isMinimized,
                isHidden: isHidden,
                windowLevel: windowLevel
            )
        }

        return infos.sorted { $0.windowLevel < $1.windowLevel }
    }

    /// Generate a human-readable report of the snapshot
    public func generateReport() -> String {
        var lines: [String] = []

        lines.append("=== System Snapshot [\(runId)] ===")
        lines.append("Total: \(captureDurationMs)ms")
        lines.append("")

        // Timing breakdown
        if !timing.isEmpty {
            lines.append("Timing:")
            for (phase, ms) in timing.sorted(by: { $0.key < $1.key }) {
                lines.append("  \(phase): \(ms)ms")
            }
            lines.append("")
        }

        // Displays
        lines.append("Displays (\(displays.count)):")
        for display in displays {
            let main = display.isMain ? " [MAIN]" : ""
            let displayName = display.name ?? "Display \(display.index)"
            lines.append("  [\(display.index)] \(displayName)\(main)")
            lines.append("      Frame: \(Int(display.frame.width))x\(Int(display.frame.height)) @ (\(Int(display.frame.origin.x)),\(Int(display.frame.origin.y)))")
            lines.append("      Visible: \(Int(display.visibleFrame.width))x\(Int(display.visibleFrame.height))")
            lines.append("      Scale: \(display.scaleFactor)x")
        }
        lines.append("")

        // Windows by display
        lines.append("Windows (\(windows.count) total):")
        let byDisplay = Dictionary(grouping: windows) { $0.displayIndex ?? -1 }
        for displayIdx in byDisplay.keys.sorted() {
            let displayWindows = byDisplay[displayIdx] ?? []
            let displayName = displayIdx >= 0 ? "Display \(displayIdx)" : "Unknown"
            lines.append("  \(displayName) (\(displayWindows.count)):")
            for window in displayWindows.prefix(15) {
                let title = (window.title ?? "").prefix(35)
                let app = window.appName ?? "?"
                lines.append("    [\(window.windowId)] \(app): \(title)")
                if let doc = window.documentPath {
                    lines.append("        doc: \(doc)")
                }
            }
            if displayWindows.count > 15 {
                lines.append("    ... +\(displayWindows.count - 15) more")
            }
        }
        lines.append("")

        // Chrome state
        if !chromeCaptures.isEmpty {
            lines.append("Chrome (\(chromeCaptures.count) windows):")
            for capture in chromeCaptures {
                lines.append("  Window \(capture.chromeWindowId): \(capture.profileName)")
                lines.append("    Tabs: \(capture.tabUrls.count) (active: \(capture.activeTabIndex))")
                for url in capture.tabUrls.prefix(3) {
                    lines.append("      - \(url.prefix(60))")
                }
                if capture.tabUrls.count > 3 {
                    lines.append("      ... +\(capture.tabUrls.count - 3) more")
                }
            }
        }

        return lines.joined(separator: "\n")
    }
}

// MARK: - Sortable Properties Extension

extension SnapshotWindow {
    /// Non-optional app name for sorting (empty string if nil)
    public var sortableAppName: String { appName ?? "" }

    /// Non-optional title for sorting (empty string if nil)
    public var sortableTitle: String { title ?? "" }

    /// Non-optional display index for sorting (Int.max if nil)
    public var sortableDisplayIndex: Int { displayIndex ?? Int.max }

    /// Non-optional z-order for sorting (Int.max if nil)
    public var sortableZOrder: Int { zOrderIndex ?? Int.max }

    /// Heuristic: window might be on different Space if off-screen but not minimized
    public var mightBeOnDifferentSpace: Bool {
        !isOnScreen && isMinimized != true
    }
}

// MARK: - NSScreen Extension

private extension NSScreen {
    var displayID: CGDirectDisplayID {
        let key = NSDeviceDescriptionKey(rawValue: "NSScreenNumber")
        return deviceDescription[key] as? CGDirectDisplayID ?? 0
    }
}
