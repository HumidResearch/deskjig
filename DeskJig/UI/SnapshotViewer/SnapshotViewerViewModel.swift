//
//  SnapshotViewerViewModel.swift
//  DeskJig
//
//  View model for the System Snapshot Viewer
//

import Foundation
import Combine
import CoreGraphics
import DeskJigShared

@MainActor
@Observable
final class SnapshotViewerViewModel {

    // MARK: - Combine Subscriptions

    /// Cancellables for Combine subscriptions
    private var cancellables = Set<AnyCancellable>()

    // MARK: - Initialization

    init() {
        setupWorkspaceChangeSubscription()
    }

    /// Subscribe to workspace changes for reactive UI updates
    private func setupWorkspaceChangeSubscription() {
        FluentServices.shared.workspaceChanges?
            .receive(on: DispatchQueue.main)
            .sink { event in
                DeskJigLog.info(.restorationSnapshot, "Workspace change event", fields: ["event": "\(event)"])
                // The @Observable macro will automatically notify observers
                // when computed properties like filteredWorkspaceHandles are accessed
                // Just logging here for debugging
            }
            .store(in: &cancellables)
    }

    // MARK: - Snapshot State

    var snapshot: SystemSnapshot?
    var isCapturing = false
    var selectedWindowId: String? = nil

    // MARK: - Filter State (replaces individual filter properties)

    var filterState = FilterState()

    // MARK: - Sort State (for native Table sorting)

    var sortOrder: [KeyPathComparator<SnapshotWindow>] = [
        KeyPathComparator(\SnapshotWindow.sortableZOrder, order: .forward)
    ]

    // MARK: - Inspector State

    var isInspectorPresented: Bool = true

    // MARK: - Window Pinning

    /// Set of window IDs that are pinned to the top of the list
    var pinnedWindowIds: Set<String> = []

    /// Toggle pin state for a window
    func togglePin(windowId: String) {
        if pinnedWindowIds.contains(windowId) {
            pinnedWindowIds.remove(windowId)
        } else {
            pinnedWindowIds.insert(windowId)
        }
    }

    /// Check if a window is pinned
    func isPinned(_ windowId: String) -> Bool {
        pinnedWindowIds.contains(windowId)
    }

    // MARK: - Display Expansion State

    /// Set of display IDs whose detail cards are expanded
    var expandedDisplayIDs: Set<CGDirectDisplayID> = []

    /// Toggle expanded state for a display card
    func toggleDisplayExpanded(_ displayID: CGDirectDisplayID) {
        if expandedDisplayIDs.contains(displayID) {
            expandedDisplayIDs.remove(displayID)
        } else {
            expandedDisplayIDs.insert(displayID)
        }
    }

    // MARK: - Window Opacity

    /// Current window opacity (0.3 to 1.0)
    var windowOpacity: Double = UserDefaults.standard.double(forKey: "SnapshotViewer.windowOpacity") == 0
        ? 1.0
        : UserDefaults.standard.double(forKey: "SnapshotViewer.windowOpacity") {
        didSet {
            // Persist to UserDefaults
            UserDefaults.standard.set(windowOpacity, forKey: "SnapshotViewer.windowOpacity")
            // Apply to window
            applyWindowOpacity()
        }
    }

    /// Apply opacity to the System Snapshot window
    func applyWindowOpacity() {
        if let window = NSApp.windows.first(where: { $0.title.contains("System Snapshot") }) {
            window.alphaValue = windowOpacity
        }
    }

    // MARK: - Chrome Toggle

    /// Whether to fetch Chrome tab information (off by default for faster captures)
    var shouldFetchChromeInfo: Bool = UserDefaults.standard.bool(forKey: "SnapshotViewer.fetchChromeInfo") {
        didSet {
            UserDefaults.standard.set(shouldFetchChromeInfo, forKey: "SnapshotViewer.fetchChromeInfo")
            // When toggled ON, fetch Chrome data immediately
            if shouldFetchChromeInfo {
                Task { await refreshChromeCapture() }
            }
        }
    }

    // MARK: - Live Update State

    /// Whether live updates are enabled
    var isLiveUpdating = false

    /// Interval for fast captures (window positions) in seconds
    var fastCaptureInterval: TimeInterval = 0.15

    /// Interval for slow captures (Chrome tabs) in seconds
    var slowCaptureInterval: TimeInterval = 1.5

    /// Windows that changed since last capture
    var changedWindowIds: Set<String> = []

    /// Time since last Chrome data update
    var chromeCaptureAge: TimeInterval = 0

    /// Last Chrome capture time
    private var lastChromeCaptureTime: Date?

    /// Previous snapshot for delta detection
    private var previousSnapshot: SystemSnapshot?

    /// Active fast capture task
    private var fastCaptureTask: Task<Void, Never>?

    /// Active slow capture task
    private var slowCaptureTask: Task<Void, Never>?

    /// Last Chrome captures (merged into fast snapshots)
    private var lastChromeCaptures: [ChromeWindowCapture] = []

    // MARK: - Capture Methods

    /// Capture a full snapshot manually
    func captureSnapshot() async {
        guard !isCapturing else { return }

        isCapturing = true
        let runId = "viewer_\(Int(Date().timeIntervalSince1970))"

        DeskJigLog.info(.restorationSnapshot, "Capturing snapshot", fields: ["runId": runId])

        let newSnapshot = await SystemSnapshotCapture.capture(
            runId: runId,
            includeChromeCapture: shouldFetchChromeInfo,
            includeAXEnrichment: true
        )

        // Detect changes
        if let previous = snapshot {
            detectChanges(from: previous, to: newSnapshot)
        }

        previousSnapshot = snapshot
        snapshot = newSnapshot
        lastChromeCaptureTime = Date()
        chromeCaptureAge = 0

        DeskJigLog.info(.restorationSnapshot, "Capture complete", fields: ["durationMs": snapshot?.captureDurationMs ?? 0, "windows": snapshot?.windows.count ?? 0])

        isCapturing = false
    }

    /// Handle window selection - auto-refresh Chrome data if needed
    func onWindowSelected(_ window: SnapshotWindow) async {
        guard shouldFetchChromeInfo else { return }

        // Check if it's a Chrome window
        let chromeBundles = ["com.google.Chrome", "com.google.Chrome.canary", "com.brave.Browser", "com.microsoft.edgemac"]
        guard let bundleId = window.bundleId, chromeBundles.contains(bundleId) else { return }

        DeskJigLog.debug(.restorationSnapshot, "Auto-refreshing Chrome data for selected window")
        await refreshChromeCapture()
    }

    /// Refresh Chrome capture data only
    @MainActor
    func refreshChromeCapture() async {
        DeskJigLog.info(.restorationSnapshot, "Refreshing Chrome capture")

        let runId = "chrome_refresh_\(Int(Date().timeIntervalSince1970))"

        // Do a capture with Chrome enabled to get fresh tab data
        let newSnapshot = await SystemSnapshotCapture.capture(
            runId: runId,
            includeChromeCapture: true,
            includeAXEnrichment: false  // Skip AX enrichment for faster refresh
        )

        // Update Chrome captures
        lastChromeCaptures = newSnapshot.chromeCaptures
        lastChromeCaptureTime = Date()
        chromeCaptureAge = 0

        // Merge into current snapshot if we have one
        if let currentSnapshot = snapshot {
            snapshot = SystemSnapshot(
                captureTime: currentSnapshot.captureTime,
                captureDurationMs: currentSnapshot.captureDurationMs,
                runId: currentSnapshot.runId,
                timing: currentSnapshot.timing,
                displays: currentSnapshot.displays,
                windows: currentSnapshot.windows,
                chromeCaptures: newSnapshot.chromeCaptures
            )
        }

        DeskJigLog.info(.restorationSnapshot, "Chrome refresh complete", fields: ["captures": newSnapshot.chromeCaptures.count])
    }

    // MARK: - Live Update Control

    /// Toggle live updates on/off
    func toggleLiveUpdates() {
        if isLiveUpdating {
            stopLiveUpdates()
        } else {
            startLiveUpdates()
        }
    }

    /// Start live updates with parallel capture threads
    func startLiveUpdates() {
        guard !isLiveUpdating else { return }

        isLiveUpdating = true
        DeskJigLog.info(.restorationSnapshot, "Starting live updates", fields: ["fastMs": Int(fastCaptureInterval * 1000), "slowMs": Int(slowCaptureInterval * 1000)])

        // Start fast capture loop (window positions)
        fastCaptureTask = Task { [weak self] in
            guard let self else { return }
            await self.fastCaptureLoop()
        }

        // Start slow capture loop (Chrome tabs)
        slowCaptureTask = Task { [weak self] in
            guard let self else { return }
            await self.slowCaptureLoop()
        }
    }

    /// Stop live updates
    func stopLiveUpdates() {
        guard isLiveUpdating else { return }

        isLiveUpdating = false
        DeskJigLog.info(.restorationSnapshot, "Stopping live updates")

        fastCaptureTask?.cancel()
        slowCaptureTask?.cancel()
        fastCaptureTask = nil
        slowCaptureTask = nil
    }

    // MARK: - Capture Loops

    private func fastCaptureLoop() async {
        while !Task.isCancelled && isLiveUpdating {
            let startTime = Date()
            let runId = "fast_\(Int(startTime.timeIntervalSince1970 * 1000))"

            // Quick capture without Chrome or AX enrichment (~10-20ms)
            var newSnapshot = await SystemSnapshotCapture.captureQuick(runId: runId)

            // Merge in last Chrome captures if available
            if !lastChromeCaptures.isEmpty {
                newSnapshot = SystemSnapshot(
                    captureTime: newSnapshot.captureTime,
                    captureDurationMs: newSnapshot.captureDurationMs,
                    runId: newSnapshot.runId,
                    timing: newSnapshot.timing,
                    displays: newSnapshot.displays,
                    windows: newSnapshot.windows,
                    chromeCaptures: lastChromeCaptures
                )
            }

            // Detect changes
            if let previous = snapshot {
                detectChanges(from: previous, to: newSnapshot)
            }

            previousSnapshot = snapshot
            snapshot = newSnapshot

            // Update Chrome capture age
            if let lastChromeTime = lastChromeCaptureTime {
                chromeCaptureAge = Date().timeIntervalSince(lastChromeTime)
            }

            // Wait for next interval
            let elapsed = Date().timeIntervalSince(startTime)
            let sleepTime = max(0, fastCaptureInterval - elapsed)
            if sleepTime > 0 {
                guard await Task.sleepUnlessCancelled(for: .seconds(sleepTime)) else { break }
            }
        }
    }

    private func slowCaptureLoop() async {
        while !Task.isCancelled && isLiveUpdating {
            let startTime = Date()
            let runId = "slow_\(Int(startTime.timeIntervalSince1970 * 1000))"

            // Full capture with Chrome (~200-350ms)
            let fullSnapshot = await SystemSnapshotCapture.capture(
                runId: runId,
                includeChromeCapture: shouldFetchChromeInfo,
                includeAXEnrichment: true
            )

            // Store Chrome captures for merging into fast snapshots
            lastChromeCaptures = fullSnapshot.chromeCaptures
            lastChromeCaptureTime = Date()
            chromeCaptureAge = 0

            DeskJigLog.debug(.restorationSnapshot, "Slow capture complete", fields: ["durationMs": fullSnapshot.captureDurationMs, "chromeWindows": fullSnapshot.chromeCaptures.count])

            // Wait for next interval
            let elapsed = Date().timeIntervalSince(startTime)
            let sleepTime = max(0, slowCaptureInterval - elapsed)
            if sleepTime > 0 {
                guard await Task.sleepUnlessCancelled(for: .seconds(sleepTime)) else { break }
            }
        }
    }

    // MARK: - Delta Detection

    private func detectChanges(from previous: SystemSnapshot, to new: SystemSnapshot) {
        var changed: Set<String> = []

        // Build lookup maps
        let previousByWindowId: [CGWindowID: SnapshotWindow] = Dictionary(
            uniqueKeysWithValues: previous.windows.map { ($0.windowId, $0) }
        )
        let newByWindowId: [CGWindowID: SnapshotWindow] = Dictionary(
            uniqueKeysWithValues: new.windows.map { ($0.windowId, $0) }
        )

        // Check for new or changed windows
        for newWindow in new.windows {
            if let prevWindow = previousByWindowId[newWindow.windowId] {
                // Check if frame changed significantly
                if !newWindow.frameMatches(prevWindow.frame, tolerance: 5) {
                    changed.insert(newWindow.id)
                }
                // Check if title changed
                if newWindow.title != prevWindow.title {
                    changed.insert(newWindow.id)
                }
                // Check if minimized state changed
                if newWindow.isMinimized != prevWindow.isMinimized {
                    changed.insert(newWindow.id)
                }
            } else {
                // New window appeared
                changed.insert(newWindow.id)
            }
        }

        // Check for disappeared windows
        for prevWindow in previous.windows {
            if newByWindowId[prevWindow.windowId] == nil {
                // Window disappeared - mark in changed for highlighting before removal
                changed.insert(prevWindow.id)
            }
        }

        // Update changed set (only keep recent changes briefly)
        changedWindowIds = changed

        // Clear changes after a short delay
        if !changed.isEmpty {
            Task { @MainActor in
                await Task.sleepUnlessCancelled(for: .milliseconds(500))
                // Only clear if these exact changes are still current
                self.changedWindowIds.subtract(changed)
            }
        }
    }

    // MARK: - Filter Chips

    /// Active filter chips for display in the filter bar
    var activeFilterChips: [FilterChip] {
        var chips: [FilterChip] = []

        if let displayIndex = filterState.selectedDisplayIndex {
            let displayName = snapshot?.displays.first(where: { $0.index == displayIndex })?.name
                ?? "Display \(displayIndex)"
            chips.append(.display(index: displayIndex, name: displayName))
        }

        if !filterState.searchText.isEmpty {
            chips.append(.searchText(filterState.searchText))
        }

        if let onScreen = filterState.onScreenOnly {
            chips.append(.onScreen(onScreen))
        }

        if let minimized = filterState.minimizedOnly {
            chips.append(.minimized(minimized))
        }

        if filterState.minFrameSize > 0 {
            chips.append(.minSize(filterState.minFrameSize))
        }

        if let pid = filterState.filterPid {
            chips.append(.pid(pid))
        }

        if let bundleId = filterState.filterBundleId {
            chips.append(.bundleId(bundleId))
        }

        if let title = filterState.filterTitle {
            chips.append(.title(title))
        }

        return chips
    }

    /// Remove a specific filter chip
    func removeFilter(_ chip: FilterChip) {
        switch chip {
        case .display: filterState.selectedDisplayIndex = nil
        case .searchText: filterState.searchText = ""
        case .onScreen: filterState.onScreenOnly = nil
        case .minimized: filterState.minimizedOnly = nil
        case .minSize: filterState.minFrameSize = 0
        case .pid: filterState.filterPid = nil
        case .bundleId: filterState.filterBundleId = nil
        case .title: filterState.filterTitle = nil
        }
    }

    // MARK: - Context Menu Helpers

    /// Add a PID filter from context menu
    func addPidFilter(_ pid: pid_t) {
        filterState.filterPid = pid
    }

    /// Add a bundle ID filter from context menu
    func addBundleIdFilter(_ bundleId: String) {
        filterState.filterBundleId = bundleId
    }

    /// Add a display filter from context menu
    func addDisplayFilter(_ displayIndex: Int) {
        filterState.selectedDisplayIndex = displayIndex
    }

    /// Add a title filter from context menu
    func addTitleFilter(_ title: String) {
        filterState.filterTitle = title
    }

    // MARK: - Computed Properties

    /// Filtered windows based on current filter state
    var filteredWindows: [SnapshotWindow] {
        guard let snapshot else { return [] }
        var windows = snapshot.windows

        // Filter by display if selected
        if let displayIndex = filterState.selectedDisplayIndex {
            windows = windows.filter { $0.displayIndex == displayIndex }
        }

        // Filter by search text
        if !filterState.searchText.isEmpty {
            let lowered = filterState.searchText.lowercased()
            windows = windows.filter {
                ($0.appName?.lowercased().contains(lowered) ?? false) ||
                ($0.title?.lowercased().contains(lowered) ?? false) ||
                ($0.bundleId?.lowercased().contains(lowered) ?? false) ||
                String($0.windowId).contains(lowered) ||
                String($0.pid).contains(lowered)
            }
        }

        // Filter by on-screen state
        if let onScreen = filterState.onScreenOnly {
            windows = windows.filter { $0.isOnScreen == onScreen }
        }

        // Filter by minimized state
        if let minimized = filterState.minimizedOnly {
            windows = windows.filter { $0.isMinimized == minimized }
        }

        // Filter by minimum frame size
        if filterState.minFrameSize > 0 {
            windows = windows.filter {
                $0.frame.width >= filterState.minFrameSize &&
                $0.frame.height >= filterState.minFrameSize
            }
        }

        // Filter by PID
        if let pid = filterState.filterPid {
            windows = windows.filter { $0.pid == pid }
        }

        // Filter by Bundle ID
        if let bundleId = filterState.filterBundleId {
            windows = windows.filter { $0.bundleId == bundleId }
        }

        // Filter by exact title
        if let title = filterState.filterTitle {
            windows = windows.filter { $0.title == title }
        }

        return windows
    }

    /// Sorted windows with pinned windows first, then by current sort order
    var sortedWindows: [SnapshotWindow] {
        let windows = filteredWindows

        // Separate pinned and unpinned
        let pinned = windows.filter { pinnedWindowIds.contains($0.id) }
        let unpinned = windows.filter { !pinnedWindowIds.contains($0.id) }

        // Sort unpinned using current sortOrder
        let sortedUnpinned = unpinned.sorted(using: sortOrder)

        return pinned + sortedUnpinned
    }

    var selectedWindow: SnapshotWindow? {
        guard let id = selectedWindowId else { return nil }
        return snapshot?.windows.first { $0.id == id }
    }

    /// Whether Chrome data is stale (older than slow capture interval)
    var isChromeDataStale: Bool {
        chromeCaptureAge > slowCaptureInterval
    }

    /// Human-readable Chrome data age
    var chromeDataAgeText: String {
        if chromeCaptureAge < 1 {
            return "Fresh"
        } else if chromeCaptureAge < 60 {
            return String(format: "%.0fs ago", chromeCaptureAge)
        } else {
            return String(format: "%.1fm ago", chromeCaptureAge / 60)
        }
    }

    // MARK: - Workspaces State (Fluent API)

    /// Saved workspaces (now uses Fluent API)
    var workspaces: [Workspace] {
        Workspaces.all().map { $0.underlyingWorkspace }
    }

    /// Recent workspaces
    var recentWorkspaces: [WorkspaceHandle] {
        Workspaces.recent(limit: 5)
    }

    /// Workspace search query
    var workspaceSearchQuery: String = ""

    /// Filtered workspaces based on search
    var filteredWorkspaceHandles: [WorkspaceHandle] {
        if workspaceSearchQuery.isEmpty {
            return Workspaces.all()
        }
        return Workspaces.find(containing: workspaceSearchQuery)
    }

    /// Result message from workspace operations
    var workspaceOperationResult: String?

    /// Restore a workspace using Fluent API
    func restoreWorkspace(_ handle: WorkspaceHandle) {
        DeskJigLog.debug(.workspace, "Legacy restore button clicked", fields: ["workspace": handle.name])
        Task { @MainActor in
            let result = await handle.restore()
            workspaceOperationResult = "Restored '\(handle.name)': \(result.success)/\(result.success + result.failed) windows"

            // Clear message after 3 seconds
            await Task.sleepUnlessCancelled(for: .seconds(3))
            workspaceOperationResult = nil
        }
    }

    /// Duplicate a workspace using Fluent API
    func duplicateWorkspace(_ handle: WorkspaceHandle) {
        // duplicate() now automatically persists, no need for .save()
        if let newHandle = handle.duplicate(name: "\(handle.name) Copy") {
            workspaceOperationResult = "Duplicated '\(handle.name)' as '\(newHandle.name)'"
        } else {
            workspaceOperationResult = "Failed to duplicate '\(handle.name)'"
        }

        Task {
            await Task.sleepUnlessCancelled(for: .seconds(3))
            workspaceOperationResult = nil
        }
    }

    /// Delete a workspace using Fluent API
    func deleteWorkspace(_ handle: WorkspaceHandle) {
        let name = handle.name
        if handle.delete() {
            workspaceOperationResult = "Deleted '\(name)'"
        } else {
            workspaceOperationResult = "Failed to delete '\(name)'"
        }

        Task {
            await Task.sleepUnlessCancelled(for: .seconds(3))
            workspaceOperationResult = nil
        }
    }

    // MARK: - Cache Data State

    /// Cache info for debugging
    var cacheInfo: CacheInfo?

    /// Cache information structure
    struct CacheInfo {
        let localCacheKey: String
        let localCacheWorkspaceCount: Int
        let localCacheSizeBytes: Int
    }

    /// Load cache info from the shared defaults suite.
    func loadCacheInfo() {
        let localKey = BundleIdentity.savedWorkspacesKey
        let localData = BundleIdentity.sharedDefaults.data(forKey: localKey)

        var localCount = 0
        if let data = localData,
           let workspaces = try? JSONDecoder().decode([Workspace].self, from: data) {
            localCount = workspaces.count
        }

        cacheInfo = CacheInfo(
            localCacheKey: localKey,
            localCacheWorkspaceCount: localCount,
            localCacheSizeBytes: localData?.count ?? 0
        )

        DeskJigLog.info(.restorationSnapshot, "Cache info loaded", fields: ["local": localCount])
    }

}