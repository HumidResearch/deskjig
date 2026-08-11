//
//  WorkspaceCaptureService.swift
//  DeskJigShared
//
//  Created by AI on 12.29.2025.
//

import Foundation
import Cocoa

public class WorkspaceCaptureService {
    private let displayManager: DisplayManager
    private let bestScreenResolver: (CGRect) -> FullScreenInfo?
    
    public init(
        displayManager: DisplayManager,
        bestScreenResolver: ((CGRect) -> FullScreenInfo?)? = nil
    ) {
        self.displayManager = displayManager
        self.bestScreenResolver = bestScreenResolver ?? { [weak displayManager] frame in
            displayManager?.getBestScreen(for: frame)
        }
    }
    
    /// Capture current screen information
    public func captureScreens() -> [WorkspaceScreen] {
        displayManager.refreshScreens()
        return WorkspaceDisplayTopology
            .effectiveScreens(from: displayManager)
            .map { WorkspaceScreen(from: $0) }
    }

    /// Find screen info for a given window frame using DisplayManager
    public func findScreenInfo(for frame: CGRect, in screens: [WorkspaceScreen]) -> (displayID: Int, index: Int)? {
        guard let fullScreenInfo = bestScreenResolver(frame) else {
            return nil
        }

        if let index = screens.firstIndex(where: { $0.displayID == fullScreenInfo.displayID }) {
            return (fullScreenInfo.displayID, index)
        }

        return nil
    }

    private func makeRunId() -> String {
        "capture_\(UUID().uuidString.prefix(8))"
    }

    private static func captureVisibleWindows(
        runId: String,
        minVisibilityThreshold: Double,
        currentWindows: [WindowInfo]?,
        includeAXEnrichment: Bool
    ) async -> [WindowInfo] {
        await Task.detached(priority: .userInitiated) {
            await SystemSnapshotCapture.visibleWindowInfos(
                minVisibility: minVisibilityThreshold,
                includeMinimized: false,
                includeHidden: false,
                currentWindows: currentWindows,
                runId: runId,
                includeAXEnrichment: includeAXEnrichment
            )
        }.value
    }

    private static func captureSnapshotWindows(
        runId: String,
        minVisibilityThreshold: Double,
        currentWindows: [WindowInfo]?,
        skipSupplementation: Bool = false
    ) async -> (snapshot: SystemSnapshot, visibleWindows: [WindowInfo]) {
        await Task.detached(priority: .userInitiated) {
            var snapshot = await SystemSnapshotCapture.capture(
                runId: runId,
                includeChromeCapture: false,
                includeAXEnrichment: true
            )

            // Skip supplementation for preview captures to reduce log verbosity and improve performance
            if !skipSupplementation {
                let terminalSupplementation = TerminalSupplementationService()
                snapshot = await terminalSupplementation.supplementTerminalWindows(
                    in: snapshot,
                    method: .axWithLsofFallback,
                    runId: runId
                )

                let ideSupplementation = IDESupplementationService()
                snapshot = await ideSupplementation.supplementIDEWindows(
                    in: snapshot,
                    method: .cursorStateWithAXFallback,
                    runId: runId
                )
            }

            let visibilityWindows = currentWindows ?? snapshot.windowInfos(
                includeHidden: true,
                excludeCurrentApp: true,
                excludeSystemWindows: true
            )

            let visibleWindows = await SystemSnapshotCapture.visibleWindowInfos(
                minVisibility: minVisibilityThreshold,
                includeMinimized: false,
                includeHidden: false,
                currentWindows: visibilityWindows,
                runId: runId
            )

            return (snapshot, visibleWindows)
        }.value
    }

    private func normalizeOpenPath(_ path: String?) -> String? {
        guard let path else { return nil }
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let expanded = (trimmed as NSString).expandingTildeInPath
        return URL(fileURLWithPath: expanded).standardizedFileURL.path
    }

    private func resolveOpenPath(
        bundleId: String,
        snapshotWindow: SnapshotWindow?
    ) -> String? {
        guard let snapshotWindow else { return nil }

        let path: String?
        if BundleRegistry.isTerminal(bundleId) {
            path = snapshotWindow.freshWorkingDirectory ?? snapshotWindow.documentPath
        } else if BundleRegistry.isIDE(bundleId) {
            path = snapshotWindow.ideDocumentPath ?? snapshotWindow.documentPath
        } else {
            return nil
        }

        return normalizeOpenPath(path)
    }

    private func visibleFrameInSnapshotCoordinates(
        for screen: WorkspaceScreen,
        snapshotDisplayFrame: CGRect
    ) -> CGRect {
        let leftInset = max(0, screen.visibleFrame.minX - screen.frame.minX)
        let rightInset = max(0, screen.frame.maxX - screen.visibleFrame.maxX)
        let topInset = max(0, screen.frame.maxY - screen.visibleFrame.maxY)
        let bottomInset = max(0, screen.visibleFrame.minY - screen.frame.minY)

        return CGRect(
            x: snapshotDisplayFrame.minX + leftInset,
            y: snapshotDisplayFrame.minY + topInset,
            width: max(0, snapshotDisplayFrame.width - leftInset - rightInset),
            height: max(0, snapshotDisplayFrame.height - topInset - bottomInset)
        )
    }

    /// Get bundle IDs of windows filtered by screen indices
    public func getBundleIDsForScreens(
        screenIndices: Set<Int> = [],
        currentWindows: [WindowInfo]? = nil,
        overlayWindowManager: OverlayWindowManager?
    ) async -> (bundleIDs: Set<String>, windows: [WindowInfo]) {
        let minVisibilityThreshold = await MainActor.run {
            overlayWindowManager?.minVisibilityThreshold ?? 0.0
        }
        DeskJigLog.debug(.workspace, "getBundleIDsForScreens: Using minVisibilityThreshold: \(String(format: "%.0f%%", minVisibilityThreshold * 100))")

        let runId = makeRunId()
        let allVisibleWindows = await Self.captureVisibleWindows(
            runId: runId,
            minVisibilityThreshold: minVisibilityThreshold,
            currentWindows: currentWindows,
            includeAXEnrichment: true
        )

        guard !allVisibleWindows.isEmpty else {
            DeskJigLog.debug(.workspace, "getBundleIDsForScreens: No visible windows meet visibility threshold")
            return (bundleIDs: [], windows: [])
        }

        let filteredWindows: [WindowInfo]
        if !screenIndices.isEmpty {
            let screens = await MainActor.run { captureScreens() }
            filteredWindows = await MainActor.run {
                allVisibleWindows.filter { windowInfo in
                    if let screenInfo = findScreenInfo(for: windowInfo.frame, in: screens) {
                        return screenIndices.contains(screenInfo.index)
                    }
                    return false
                }
            }
            DeskJigLog.debug(.workspace, 
                "getBundleIDsForScreens: Filtered to \(filteredWindows.count) windows on selected screens: \(Array(screenIndices).sorted())"
            )
        } else {
            filteredWindows = allVisibleWindows
            DeskJigLog.debug(.workspace, "getBundleIDsForScreens: Using all visible windows (\(filteredWindows.count))")
        }

        return (bundleIDs: Set(filteredWindows.compactMap(\.bundleIdentifier)), windows: filteredWindows)
    }

    public func captureCurrentWindows(
        selectiveMode: Bool = false,
        screenIndices: Set<Int> = [],
        currentWindows: [WindowInfo]? = nil,
        applicationManager: ApplicationManagerProtocol?,
        overlayWindowManager: OverlayWindowManager?,
        minVisibilityOverride: Double? = nil,
        skipSupplementation: Bool = false
    ) async -> (windows: [WorkspaceWindow], screens: [WorkspaceScreen]) {
        let screens = await MainActor.run { captureScreens() }
        let minVisibilityThreshold = await MainActor.run {
            if let override = minVisibilityOverride {
                return max(0.0, min(1.0, override))
            }
            return overlayWindowManager?.minVisibilityThreshold ?? 0.0
        }

        if !skipSupplementation {
            DeskJigLog.debug(.workspace, "Capturing windows with minVisibilityThreshold: \(String(format: "%.0f%%", minVisibilityThreshold * 100))")
        }

        let runId = makeRunId()
        let (snapshot, allWindowsToSave) = await Self.captureSnapshotWindows(
            runId: runId,
            minVisibilityThreshold: minVisibilityThreshold,
            currentWindows: currentWindows,
            skipSupplementation: skipSupplementation
        )

        guard !allWindowsToSave.isEmpty else {
            let modeDescription = selectiveMode ? "windows with overlays" : "visible windows with bundle identifiers"
            DeskJigLog.debug(.workspace, "No \(modeDescription) meet visibility threshold")
            return (windows: [], screens: screens)
        }

        let snapshotWindowsById = Dictionary(
            uniqueKeysWithValues: snapshot.windows.map { (Int($0.windowId), $0) }
        )

        let windows = await MainActor.run {
            let windowsToSave: [WindowInfo]
            if !screenIndices.isEmpty {
                windowsToSave = allWindowsToSave.filter { windowInfo in
                    if let screenInfo = findScreenInfo(for: windowInfo.frame, in: screens) {
                        return screenIndices.contains(screenInfo.index)
                    }
                    return false
                }
                DeskJigLog.debug(.workspace, 
                    "Filtered to \(windowsToSave.count) windows on selected screens: \(Array(screenIndices).sorted())"
                )

                // Debug: Log Chrome windows specifically to diagnose profile capture issues
                let chromeWindowsSaved = windowsToSave.filter { chromeBundleIdentifiers.contains($0.bundleIdentifier ?? "") }
                let chromeWindowsFiltered = allWindowsToSave.filter { chromeBundleIdentifiers.contains($0.bundleIdentifier ?? "") }.count - chromeWindowsSaved.count
                if !chromeWindowsSaved.isEmpty || chromeWindowsFiltered > 0 {
                    DeskJigLog.debug(.workspace, "Chrome windows after screen filter: \(chromeWindowsSaved.count) saved, \(chromeWindowsFiltered) filtered out")
                    for chrome in chromeWindowsSaved {
                        DeskJigLog.debug(.workspace, "  Saved Chrome: '\(chrome.windowTitle)' frame=\(chrome.frame)")
                    }
                }
            } else {
                windowsToSave = allWindowsToSave
                DeskJigLog.debug(.workspace, "Capturing windows from all screens")

                // Debug: Log Chrome windows when not filtering by screen
                let chromeWindows = windowsToSave.filter { chromeBundleIdentifiers.contains($0.bundleIdentifier ?? "") }
                if !chromeWindows.isEmpty {
                    DeskJigLog.debug(.workspace, "Chrome windows (all screens): \(chromeWindows.count) found")
                    for chrome in chromeWindows {
                        DeskJigLog.debug(.workspace, "  Chrome: '\(chrome.windowTitle)' frame=\(chrome.frame)")
                    }
                }
            }

            let applicationPathsByBundleId: [String: String] = {
                guard let applicationManager else { return [:] }
                let bundleIds = Set(windowsToSave.compactMap(\.bundleIdentifier))
                var mapping: [String: String] = [:]
                for bundleId in bundleIds {
                    if let path = applicationManager.findApplication(by: bundleId)?.path {
                        mapping[bundleId] = path
                    }
                }
                return mapping
            }()

            let chromeStatesByWindowId: [Int: ChromeWindowState] = {
                guard let overlayManager = overlayWindowManager else { return [:] }
                var mapping: [Int: ChromeWindowState] = [:]
                for windowInfo in windowsToSave {
                    guard let bundleId = windowInfo.bundleIdentifier,
                          chromeBundleIdentifiers.contains(bundleId) else { continue }
                    let chromeConfig = overlayManager.chromeConfiguration(for: windowInfo)
                    if let state = chromeConfig?.workspaceState {
                        mapping[windowInfo.id] = state
                        DeskJigLog.debug(.workspace, 
                            "Captured Chrome state for window '\(windowInfo.windowTitle)': profile=\(state.profileDisplayName), tabs=\(state.savedTabURLs.count)"
                        )
                    } else {
                        DeskJigLog.warn(.workspace, "Failed to capture Chrome state for window '\(windowInfo.windowTitle)'")
                    }
                }
                return mapping
            }()

            // Track fullscreen Chrome windows to deduplicate decoration windows
            var fullscreenChromeScreens: Set<Int> = []

            return windowsToSave.compactMap { windowInfo -> WorkspaceWindow? in
                guard let bundleId = windowInfo.bundleIdentifier, !bundleId.isEmpty else {
                    DeskJigLog.debug(.workspace, "Filtered window '\(windowInfo.windowTitle)' (app: \(windowInfo.appName)): missing bundleIdentifier")
                    return nil
                }

                let applicationPath: String? = applicationPathsByBundleId[bundleId]
                let chromeState = chromeStatesByWindowId[windowInfo.id]
                let screenInfo = findScreenInfo(for: windowInfo.frame, in: screens)
                let screenIndex = screenInfo?.index

                // Check if this is a Chrome window in fullscreen mode
                let isChrome = chromeBundleIdentifiers.contains(bundleId)

                if isChrome, let screenIdx = screenIndex {
                    // Check for extreme aspect ratio (decoration window in fullscreen Space)
                    let aspectRatio = windowInfo.frame.width / max(windowInfo.frame.height, 1)
                    let isExtremeAspectRatio = aspectRatio > 15.0

                    // Check isFullScreen from snapshot if available
                    let snapshotWindow = snapshotWindowsById[windowInfo.id]
                    let isFullScreen = snapshotWindow?.isFullScreen == true

                    if isExtremeAspectRatio || isFullScreen {
                        // If we already have a fullscreen Chrome on this screen, skip this decoration window
                        if fullscreenChromeScreens.contains(screenIdx) {
                            DeskJigLog.debug(.workspace, "Filtered Chrome fullscreen decoration window on screen \(screenIdx): '\(windowInfo.windowTitle)'")
                            return nil
                        }

                        // Mark this screen as having a fullscreen Chrome
                        fullscreenChromeScreens.insert(screenIdx)

                        // Create WorkspaceWindow with full-screen relative frame
                        let fullScreenFrame = RelativeWindowFrame(
                            xPercent: 0.0,
                            yPercent: 0.0,
                            widthPercent: 1.0,
                            heightPercent: 1.0
                        )

                        DeskJigLog.debug(.workspace, "Chrome fullscreen detected on screen \(screenIdx): '\(windowInfo.windowTitle)' - using full screen frame")

                        let openPath = resolveOpenPath(
                            bundleId: bundleId,
                            snapshotWindow: snapshotWindow
                        )

                        return WorkspaceWindow(
                            bundleIdentifier: bundleId,
                            appName: windowInfo.appName,
                            windowTitle: windowInfo.windowTitle,
                            openPath: openPath,
                            applicationPath: applicationPath,
                            chromeState: chromeState,
                            screenIndex: screenIdx,
                            relativeFrame: fullScreenFrame
                        )
                    }
                }

                // Normal window processing
                var relativeFrame: RelativeWindowFrame?
                if let index = screenIndex, index < screens.count {
                    let screen = screens[index]
                    let snapshotVisibleFrame = snapshot.displays
                        .first(where: { Int($0.displayID) == screen.displayID })
                        .map { self.visibleFrameInSnapshotCoordinates(for: screen, snapshotDisplayFrame: $0.frame) }
                    let relativeFrameBasis = snapshotVisibleFrame
                        ?? screen.visibleFrameInWindowCoordinates(globalMaxY: self.displayManager.windowCoordinateAnchorY)

                    relativeFrame = WindowFrameConverter.toRelative(
                        windowFrame: windowInfo.frame,
                        screenFrame: relativeFrameBasis
                    )
                }

                let openPath = resolveOpenPath(
                    bundleId: bundleId,
                    snapshotWindow: snapshotWindowsById[windowInfo.id]
                )

                return WorkspaceWindow(
                    bundleIdentifier: bundleId,
                    appName: windowInfo.appName,
                    windowTitle: windowInfo.windowTitle,
                    openPath: openPath,
                    applicationPath: applicationPath,
                    chromeState: chromeState,
                    screenIndex: screenIndex,
                    relativeFrame: relativeFrame
                )
            }
        }

        let windowOrderSummary = windows.prefix(5).map { "\($0.appName)" }.joined(separator: ", ")
        DeskJigLog.debug(.workspace, "Captured \(windows.count) windows that meet visibility threshold. First 5: \(windowOrderSummary)")
        return (windows: windows, screens: screens)
    }
}
