//
//  WindowManager.swift
//  DeskJigShared
//
//  Created by Marco Freedom on 02.09.2025.
//

import Foundation
import ApplicationServices
import Cocoa
import Combine

public class WindowManager: ObservableObject {
    
    // MARK: - Published Properties (Aggregated from services)
    @Published public var windows: [WindowInfo] = []
    
    /// Returns true if the user has allowed accessibility permissions
    @Published public var hasAccessibilityPermissions = false
    
    /// Returns true if the app should show the initial permissions screen
    @Published public private(set) var shouldShowPermissionsScreen = false
    
    @Published public var savedWorkspaces: [Workspace] = []

    /// Callback for when window restoration fails
    /// - Parameters:
    ///   - window: The WorkspaceWindow that failed to restore
    ///   - message: Optional custom message (e.g., for hidden space errors). If nil, use default message.
    public var onWindowRestorationFailure: ((WorkspaceWindow, String?) -> Void)? = nil

    // MARK: - Internal Services
    private let accessibilityManager: AccessibilityManager
    private let workspaceManager: WorkspaceManager
    public let displayManager: DisplayManager
    public let folderTabCoordinator: FolderTabCoordinator

    private var cancellables = Set<AnyCancellable>()
    private var restorationCancelled = false
    private var autoRefreshTimer: Timer?

    // MARK: - Public Service Access
    
    /// Public access to WorkspaceManager for FluentServices configuration
    public var workspaceManagerService: WorkspaceManager {
        return workspaceManager
    }

    /// Stored reference to ApplicationManager after setApplicationManager is called
    private(set) public var applicationManagerService: ApplicationManagerProtocol?

    public init() {
        // Initialize services with proper dependencies
        self.accessibilityManager = AccessibilityManager()
        self.displayManager = DisplayManager()
        self.folderTabCoordinator = FolderTabCoordinator(displayManager: displayManager)
        FluentServices.configure(
            axWindowService: AXWindowService.shared,
            displayManager: displayManager
        )
        
        // Initialize workspace manager
        self.workspaceManager = WorkspaceManager(
            displayManager: displayManager
        )

        setupBindings()
        folderTabCoordinator.setWindowManager(self)
        workspaceManager.setFolderTabCoordinator(folderTabCoordinator)
        refreshWindows()
    }

    private func setupBindings() {
        accessibilityManager.$hasAccessibilityPermissions
            .receive(on: DispatchQueue.main)
            .assign(to: \.hasAccessibilityPermissions, on: self)
            .store(in: &cancellables)

        // Determine if the permissions screen should be shown
        accessibilityManager.$hasAccessibilityPermissions
            .map { hasAccessibility in
                // If we don't have accessibility permissions,
                // show the permissions screen
                return !hasAccessibility
            }
            .receive(on: DispatchQueue.main)
            .assign(to: &$shouldShowPermissionsScreen)
        
        workspaceManager.$savedWorkspaces
            .receive(on: DispatchQueue.main)
            .assign(to: \.savedWorkspaces, on: self)
            .store(in: &cancellables)

    }

    // MARK: - Process Management
    public func isProcessRunning(bundleIdentifier: String?) -> Bool {
        guard let bundleIdentifier else { return false }
        return NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == bundleIdentifier }
    }

    public func isProcessRunning(pid: pid_t) -> Bool {
        return NSWorkspace.shared.runningApplications.contains { $0.processIdentifier == pid }
    }

    // MARK: - Accessibility Management
    public func checkAccessibilityPermissions() {
        accessibilityManager.checkAccessibilityPermissions()
    }

    public func requestAccessibilityPermissions() {
        accessibilityManager.requestAccessibilityPermissions()
    }

    /// Opens System Settings to a specific preference pane
    public func openSystemSettings(to page: SettingsPane) {
        accessibilityManager.openSystemSettings(to: page)
    }

    // MARK: - Window Discovery
    public func refreshWindows(completion: (() -> Void)? = nil) {
        let runId = makeRunId()
        Task {
            let windows = await SystemSnapshotCapture.captureWindowInfos(
                runId: runId,
                includeHidden: true,
                includeAXEnrichment: false
            )

            await MainActor.run { [weak self] in
                self?.windows = windows
                completion?()
            }
        }
    }
    
    /// Check if there are expired pending positions (timeout condition)
    /// - Returns: True if any pending positions have expired
    public func hasExpiredPendingPositions() -> Bool {
        return false
    }

    // Auto-refresh is now handled automatically via system notifications
    // These methods now use polling against the snapshot engine.
    public func startAutoRefresh(interval: TimeInterval = 0.75) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            stopAutoRefresh()
            autoRefreshTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
                self?.refreshWindows()
            }
            if let timer = autoRefreshTimer {
                RunLoop.main.add(timer, forMode: .common)
            }
            DeskJigLog.info(.window, "WindowManager.startAutoRefresh() enabled polling")
        }
    }

    public func stopAutoRefresh() {
        DispatchQueue.main.async { [weak self] in
            self?.autoRefreshTimer?.invalidate()
            self?.autoRefreshTimer = nil
            DeskJigLog.info(.window, "WindowManager.stopAutoRefresh() disabled polling")
        }
    }

    /// Find the topmost visible window at the specified screen coordinates
    /// Uses direct synchronous CGWindowListCopyWindowInfo for real-time mouse event handling
    public func findTopmostWindow(at location: CGPoint) -> WindowInfo? {
        // #if DEBUG
        // DeskJigLog.debug(.window, "🔍 findTopmostWindow called at location: \(location)")
        // #endif

        guard accessibilityManager.hasAccessibilityPermissions else {
            DeskJigLog.warn(.window, "🔍 Accessibility permissions not granted")
            return nil
        }

        // Direct synchronous call - critical for real-time mouse event handling
        // Use .optionOnScreenOnly to get visible windows in z-order (front to back)
        guard let windowListInfo = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else {
            DeskJigLog.error(.window, "🔍 Failed to get window list")
            return nil
        }

        // #if DEBUG
        // DeskJigLog.debug(.window, "🔍 Got \(windowListInfo.count) windows from CGWindowList")
        // #endif

        displayManager.refreshScreens()
        let screenForLocation = displayManager.getBestScreen(for: CGRect(x: location.x, y: location.y, width: 1, height: 1))
        // #if DEBUG
        // DeskJigLog.debug(.window, "🔍 Screen for location: \(screenForLocation?.displayID ?? 0)")
        // #endif
        let currentPid = ProcessInfo.processInfo.processIdentifier

        // Build PID to app info mapping (like SystemSnapshotCapture does)
        let apps = NSWorkspace.shared.runningApplications
        var pidToApp: [pid_t: (bundleId: String?, appName: String?)] = [:]
        for app in apps {
            pidToApp[app.processIdentifier] = (app.bundleIdentifier, app.localizedName)
        }

        var windowsChecked = 0
        for windowData in windowListInfo {
            // Core required fields
            guard let windowNumber = windowData[kCGWindowNumber as String] as? Int,
                  let ownerPID = windowData[kCGWindowOwnerPID as String] as? pid_t,
                  let windowBounds = windowData[kCGWindowBounds as String] as? [String: Any] else {
                continue
            }

            // Filter to normal windows (layer 0)
            let windowLayer = windowData[kCGWindowLayer as String] as? Int ?? 0
            guard windowLayer == 0 else { continue }

            // Skip our own windows
            guard ownerPID != currentPid else { continue }

            // Get app info from NSWorkspace (more reliable than CGWindowOwnerName)
            let appInfo = pidToApp[ownerPID]
            let appName = appInfo?.appName ?? (windowData[kCGWindowOwnerName as String] as? String) ?? "Unknown"

            // Skip Window Server windows
            guard !appName.contains("Window Server") else { continue }

            let x = windowBounds["X"] as? CGFloat ?? 0
            let y = windowBounds["Y"] as? CGFloat ?? 0
            let width = windowBounds["Width"] as? CGFloat ?? 0
            let height = windowBounds["Height"] as? CGFloat ?? 0
            let frame = CGRect(x: x, y: y, width: width, height: height)

            // Skip very small windows (matches SystemSnapshotCapture minWindowSize)
            guard width >= 65 && height >= 65 else { continue }

            windowsChecked += 1

            // Check if window contains the location
            if !frame.contains(location) {
                DeskJigLog.trace(.window, "🔍 Window '\(appName)' frame \(frame) does not contain location \(location)")
                continue
            }

            // Skip windows on different screens in multi-monitor setups
            if let screenForLocation,
               let screenForWindow = displayManager.getBestScreen(for: frame),
               screenForWindow.displayID != screenForLocation.displayID {
                // #if DEBUG
                // DeskJigLog.debug(.window, "🔍 Window '\(appName)' on different screen (window: \(screenForWindow.displayID), cursor: \(screenForLocation.displayID)) - skipping")
                // #endif
                continue
            }

            // Build WindowInfo from window data
            let title = windowData[kCGWindowName as String] as? String ?? "Untitled"

            // #if DEBUG
            // DeskJigLog.debug(.window, "🔍 Found window: '\(appName)' - '\(title)' (ID: \(windowNumber)) at frame \(frame)")
            // #endif
            return WindowInfo(
                id: windowNumber,
                appName: appName,
                windowTitle: title,
                frame: frame,
                processID: ownerPID,
                bundleIdentifier: appInfo?.bundleId,
                isMinimized: false,
                isHidden: false,
                windowLevel: windowLayer
            )
        }

        DeskJigLog.warn(.window, "🔍 No window found at location \(location) after checking \(windowsChecked) candidate windows")
        return nil
    }

    /// Get the current frame for a specific window by its ID
    /// Uses a targeted single-window CGWindowListCreateDescriptionFromArray query for
    /// real-time drag detection instead of copying the entire on-screen window list,
    /// falling back to the full-list scan when the targeted query comes back empty.
    public func getCurrentWindowFrame(for windowId: Int) -> CGRect? {
        // Direct synchronous call - critical for drag detection.
        // CGWindowListCreateDescriptionFromArray, unlike CGWindowListCopyWindowInfo with
        // .optionOnScreenOnly, returns descriptors for off-screen/minimized windows too, so
        // we must explicitly check kCGWindowIsOnscreen below to preserve the old nil-for-
        // off-screen contract.
        //
        // The array passed in MUST hold raw CGWindowID values stored as pointer-sized
        // entries, not a CFArray of NSNumber - `[windowId] as CFArray` bridges to NSNumber
        // elements, which this API cannot read and reliably returns empty for (verified: 0/8
        // hits on live cross-process window IDs). Building the array via CFArrayCreate with
        // an UnsafeRawPointer bit-pattern of the window ID gets pointer-valued entries and
        // the targeted query actually matches (verified: 8/8 hits on the same IDs). We still
        // fall back to the previous full-list scan below whenever the direct lookup can't
        // confirm a match, so correctness never regresses even for IDs the targeted query
        // can't resolve (e.g. genuinely stale/closed IDs).
        guard let cgWindowId = CGWindowID(exactly: windowId) else {
            DeskJigLog.trace(.window, "🔍 getCurrentWindowFrame: Window ID \(windowId) not representable as CGWindowID")
            return nil
        }
        var windowIdPtr = UnsafeRawPointer(bitPattern: UInt(cgWindowId))
        if let directArray = CFArrayCreate(kCFAllocatorDefault, &windowIdPtr, 1, nil),
           let directList = CGWindowListCreateDescriptionFromArray(
               directArray
           ) as? [[String: Any]], let windowInfo = directList.first,
           let windowNumber = windowInfo[kCGWindowNumber as String] as? Int,
           windowNumber == windowId {
            guard let isOnscreen = windowInfo[kCGWindowIsOnscreen as String] as? Bool, isOnscreen else {
                DeskJigLog.trace(.window, "🔍 getCurrentWindowFrame: Window ID \(windowId) is not on-screen (direct)")
                return nil
            }

            guard let windowBounds = windowInfo[kCGWindowBounds as String] as? [String: Any] else {
                DeskJigLog.warn(.window, "🔍 getCurrentWindowFrame: Window ID \(windowId) descriptor missing bounds (direct)")
                return nil
            }

            let frame = Self.rect(fromCGWindowBounds: windowBounds)
            DeskJigLog.trace(.window, "🔍 getCurrentWindowFrame: Found window ID \(windowId) at frame \(frame) (direct)")
            return frame
        }

        // Fallback: targeted query found nothing - fall back to the full on-screen scan
        // (identical to the pre-#540 implementation) so correctness never regresses.
        guard let windowListInfo = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly],
            kCGNullWindowID
        ) as? [[String: Any]] else {
            DeskJigLog.warn(.window, "🔍 getCurrentWindowFrame: Failed to get window list")
            return nil
        }

        for windowInfo in windowListInfo {
            guard let windowNumber = windowInfo[kCGWindowNumber as String] as? Int,
                  windowNumber == windowId,
                  let windowBounds = windowInfo[kCGWindowBounds as String] as? [String: Any] else {
                continue
            }

            let frame = Self.rect(fromCGWindowBounds: windowBounds)
            DeskJigLog.trace(.window, "🔍 getCurrentWindowFrame: Found window ID \(windowId) at frame \(frame) (fallback scan)")
            return frame
        }

        DeskJigLog.warn(.window, "🔍 getCurrentWindowFrame: Window ID \(windowId) not found in \(windowListInfo.count) windows")
        return nil
    }

    /// Converts a `kCGWindowBounds` dictionary (as returned by both CGWindowList APIs) into a CGRect.
    private static func rect(fromCGWindowBounds windowBounds: [String: Any]) -> CGRect {
        let x = windowBounds["X"] as? CGFloat ?? 0
        let y = windowBounds["Y"] as? CGFloat ?? 0
        let width = windowBounds["Width"] as? CGFloat ?? 0
        let height = windowBounds["Height"] as? CGFloat ?? 0
        return CGRect(x: x, y: y, width: width, height: height)
    }

    /// Calculate the visibility percentage of a window against the current window list.
    public func calculateWindowVisibility(
        _ windowInfo: WindowInfo,
        gridResolution: Int = 20,
        currentWindows: [WindowInfo]? = nil
    ) -> Double {
        let windowsToUse = currentWindows ?? windows
        return SystemSnapshotCapture.calculateWindowVisibility(
            windowInfo,
            gridResolution: gridResolution,
            currentWindows: windowsToUse
        )
    }

    /// Get windows that meet a minimum visibility threshold.
    public func getVisibleWindows(
        minVisibility: Double = 0.5,
        includeMinimized: Bool = false,
        includeHidden: Bool = false,
        currentWindows: [WindowInfo]? = nil
    ) -> [WindowInfo] {
        let runId = makeRunId()
        return syncCapture {
            await SystemSnapshotCapture.visibleWindowInfos(
                minVisibility: minVisibility,
                includeMinimized: includeMinimized,
                includeHidden: includeHidden,
                currentWindows: currentWindows,
                runId: runId,
                includeAXEnrichment: false
            )
        }
    }

    // MARK: - Window Control Functions
    public func closeWindow(windowInfo: WindowInfo) -> Bool {
        guard let handle = resolveHandle(for: windowInfo) else { return false }
        return handle.close() != nil
    }

    public func closeApplication(windowInfo: WindowInfo) -> Bool {
        guard let app = NSWorkspace.shared.runningApplications.first(where: { $0.processIdentifier == windowInfo.processID }) else {
            DeskJigLog.warn(.window, "Could not find running application for PID: \(windowInfo.processID)")
            return false
        }

        let success = app.terminate()
        if success {
            DeskJigLog.info(.window, "Successfully terminated application: \(windowInfo.appName)")
        } else {
            DeskJigLog.error(.window, "Failed to terminate application: \(windowInfo.appName)")
        }
        return success
    }

    public func hideWindow(windowInfo: WindowInfo) -> Bool {
        guard let handle = resolveHandle(for: windowInfo) else { return false }
        return handle.hide() != nil
    }

    public func unhideWindow(windowInfo: WindowInfo) -> Bool {
        guard let handle = resolveHandle(for: windowInfo) else { return false }
        return handle.unhide() != nil
    }
    
    public func minimizeWindow(windowInfo: WindowInfo) -> Bool {
        guard let handle = resolveHandle(for: windowInfo) else { return false }
        return handle.minimize() != nil
    }

    public func restoreWindow(windowInfo: WindowInfo) -> Bool {
        guard let handle = resolveHandle(for: windowInfo) else { return false }
        return handle.restore() != nil
    }

    public func activateWindow(windowInfo: WindowInfo) -> Bool {
        guard let handle = resolveHandle(for: windowInfo) else { return false }
        return handle.activate() != nil
    }

    public func moveWindowToLeftHalf(windowInfo: WindowInfo) -> Bool {
        guard let handle = resolveHandle(for: windowInfo) else { return false }
        return handle.moveToLeftHalf() != nil
    }

    public func moveWindowToRightHalf(windowInfo: WindowInfo) -> Bool {
        guard let handle = resolveHandle(for: windowInfo) else { return false }
        return handle.moveToRightHalf() != nil
    }
    
    public func moveWindowToTopHalf(windowInfo: WindowInfo) -> Bool {
        guard let handle = resolveHandle(for: windowInfo) else { return false }
        return handle.moveToTopHalf() != nil
    }

    public func moveWindowToBottomHalf(windowInfo: WindowInfo) -> Bool {
        guard let handle = resolveHandle(for: windowInfo) else { return false }
        return handle.moveToBottomHalf() != nil
    }

    public func moveWindowToFrame(windowInfo: WindowInfo, targetFrame: CGRect) -> Bool {
        guard let handle = resolveHandle(for: windowInfo) else { return false }
        return handle.setFrame(targetFrame) != nil
    }

    public func centerWindow(windowInfo: WindowInfo) -> Bool {
        guard let handle = resolveHandle(for: windowInfo) else { return false }
        return handle.center() != nil
    }

    public func maximizeWindow(windowInfo: WindowInfo) -> Bool {
        guard let handle = resolveHandle(for: windowInfo) else { return false }
        return handle.maximize() != nil
    }

    /// Simulates a mouse click at the center of the specified window
    /// - Parameter windowInfo: The window to tap on
    /// - Returns: True if the tap was successfully simulated
    public func tapOnWindow(windowInfo: WindowInfo) -> Bool {
        guard let handle = resolveHandle(for: windowInfo) else { return false }
        return handle.tap(preserveMousePosition: true) != nil
    }

    public func moveWindowLeft(windowInfo: WindowInfo) -> Bool {
        guard let handle = resolveHandle(for: windowInfo) else { return false }
        return handle.moveToEdge(.left) != nil
    }

    public func moveWindowRight(windowInfo: WindowInfo) -> Bool {
        guard let handle = resolveHandle(for: windowInfo) else { return false }
        return handle.moveToEdge(.right) != nil
    }

    public func moveWindowUp(windowInfo: WindowInfo) -> Bool {
        guard let handle = resolveHandle(for: windowInfo) else { return false }
        return handle.moveToEdge(.up) != nil
    }

    public func moveWindowDown(windowInfo: WindowInfo) -> Bool {
        guard let handle = resolveHandle(for: windowInfo) else { return false }
        return handle.moveToEdge(.down) != nil
    }

    public func minimizeAllWindows() -> (success: Int, failed: Int) {
        guard !windows.isEmpty else {
            DeskJigLog.info(.window, "No windows to minimize")
            return (success: 0, failed: 0)
        }

        var successCount = 0
        var failedCount = 0

        for window in windows {
            if minimizeWindow(windowInfo: window) {
                successCount += 1
            } else {
                failedCount += 1
            }
        }

        return (success: successCount, failed: failedCount)
    }

    public func hideAllWindows() -> (success: Int, failed: Int) {
        let runId = makeRunId()
        DeskJigLog.info(.window, "[\(runId)] Action bar: Hiding all apps via AppHideUtility")

        // Use AppHideUtility to hide ALL running apps (not just those with visible windows)
        let result = syncCapture {
            await AppHideUtility.hideAllApps(options: .actionBar, runId: runId)
        }

        DeskJigLog.info(.window, "[\(runId)] Hide all complete: \(result.appsHidden) hidden, \(result.appsFailed) failed, \(result.appsSkipped) skipped in \(result.durationMs)ms")

        return (success: result.appsHidden, failed: result.appsFailed)
    }

    public func unhideAllWindows() -> (success: Int, failed: Int) {
        let runId = makeRunId()
        DeskJigLog.info(.window, "[\(runId)] Action bar: Unhiding all apps via AppUnhideUtility")

        // Use AppUnhideUtility to unhide ALL hidden apps (not just those with visible windows)
        let result = syncCapture {
            await AppUnhideUtility.unhideAllApps(options: .actionBar, runId: runId)
        }

        DeskJigLog.info(.window, "[\(runId)] Unhide all complete: \(result.appsUnhidden) unhidden, \(result.appsFailed) failed, \(result.appsSkipped) skipped in \(result.durationMs)ms")

        return (success: result.appsUnhidden, failed: result.appsFailed)
    }

    // MARK: - Screenshot Functions

    /// Create WindowSnapshot instances for all visible windows
    @available(macOS 12.3, *)
    public func createWindowSnapshots() async -> [WindowSnapshot] {
        return await createWindowSnapshots(windows: windows)
    }

    /// Create WindowSnapshot instances for specific windows
    @available(macOS 12.3, *)
    public func createWindowSnapshots(windows: [WindowInfo]) async -> [WindowSnapshot] {
        guard accessibilityManager.hasAccessibilityPermissions else {
            DeskJigLog.warn(.window, "Accessibility permissions not granted for creating window snapshots")
            return []
        }

        return await WindowScreenshot.createWindowSnapshots(
            windows: windows,
            applicationManager: applicationManagerService
        )
    }

    /// Capture screenshot for a specific window
    @available(macOS 12.3, *)
    public func captureWindowScreenshot(windowInfo: WindowInfo) async throws -> CGImage {
        return try await WindowScreenshot.capture(windowInfo: windowInfo)
    }

    // MARK: - Workspace Management
    public func setApplicationManager(_ applicationManager: ApplicationManager) {
        self.applicationManagerService = applicationManager
        workspaceManager.setApplicationManager(applicationManager)
        FluentServices.configure(
            axWindowService: AXWindowService.shared,
            displayManager: displayManager,
            applicationManager: applicationManager,
            workspaceManager: workspaceManager
        )
    }

    public func setWindowLayoutManager(_ windowLayoutManager: WindowLayoutManager) {
        workspaceManager.setWindowLayoutManager(windowLayoutManager)
    }

    public func captureCurrentWindows() async -> [WorkspaceWindow] {
        await workspaceManager.captureCurrentWindows().windows
    }

    public func captureWorkspaceSnapshot(
        screenIndices: Set<Int> = [],
        currentWindows: [WindowInfo]? = nil,
        minVisibilityOverride: Double? = nil,
        skipSupplementation: Bool = false
    ) async -> (windows: [WorkspaceWindow], screens: [WorkspaceScreen]) {
        await workspaceManager.captureCurrentWindows(
            screenIndices: screenIndices,
            currentWindows: currentWindows,
            minVisibilityOverride: minVisibilityOverride,
            skipSupplementation: skipSupplementation
        )
    }

    public func setOverlayWindowManager(_ overlayWindowManager: OverlayWindowManager) {
        workspaceManager.setOverlayWindowManager(overlayWindowManager)
    }

    public func saveCurrentWorkspace(
        id: Workspace.ID = UUID(),
        name: String,
        icon: String?,
        selectiveMode: Bool = false,
        screenIndices: Set<Int> = [],
        minVisibilityOverride: Double? = nil,
        chromeModifications: [UUID: ChromeModification] = [:],
        openByPathModifications: [UUID: OpenByPathModification] = [:]
    ) async {
        await workspaceManager.saveCurrentWorkspace(
            id: id,
            name: name,
            icon: icon,
            selectiveMode: selectiveMode,
            screenIndices: screenIndices,
            minVisibilityOverride: minVisibilityOverride,
            chromeModifications: chromeModifications.mapValues { mod in
                ChromeModification(
                    tabURLs: mod.tabURLs,
                    profileDirectory: mod.profileDirectory,
                    profileDisplayName: mod.profileDisplayName,
                    profileHostedDomain: mod.profileHostedDomain,
                    profileUserName: mod.profileUserName,
                    profileMatchMode: mod.profileMatchMode
                )
            },
            openByPathModifications: openByPathModifications.mapValues { mod in
                OpenByPathModification(
                    bundleIdentifier: mod.bundleIdentifier,
                    windowTitle: mod.windowTitle,
                    openPath: mod.openPath
                )
            }
        )
    }

    public func getBundleIDsForScreens(screenIndices: Set<Int> = [], currentWindows: [WindowInfo]? = nil) async -> (bundleIDs: Set<String>, windows: [WindowInfo]) {
        return await workspaceManager.getBundleIDsForScreens(screenIndices: screenIndices, currentWindows: currentWindows)
    }
    
    /// Lightweight Z-order update for all windows without full refresh
    /// Call this when you need fresh Z-order data (e.g., opening workspace editor modal)
    @discardableResult
    public func updateWindowsZOrder() -> Bool {
        refreshWindows()
        return true
    }

    @MainActor
    public func updateWorkspaceMetadata(
        for workspace: Workspace,
        newName: String,
        newIcon: String,
        chromeModifications: [UUID: ChromeModification] = [:],
        openByPathModifications: [UUID: OpenByPathModification] = [:]
    ) {
        workspaceManager.updateWorkspaceMetadata(
            for: workspace,
            newName: newName,
            newIcon: newIcon,
            chromeModifications: chromeModifications.mapValues { mod in
                ChromeModification(
                    tabURLs: mod.tabURLs,
                    profileDirectory: mod.profileDirectory,
                    profileDisplayName: mod.profileDisplayName,
                    profileHostedDomain: mod.profileHostedDomain,
                    profileUserName: mod.profileUserName,
                    profileMatchMode: mod.profileMatchMode
                )
            },
            openByPathModifications: openByPathModifications.mapValues { mod in
                OpenByPathModification(
                    bundleIdentifier: mod.bundleIdentifier,
                    windowTitle: mod.windowTitle,
                    openPath: mod.openPath
                )
            }
        )
    }

    @MainActor
    public func updateWorkspaceLayout(
        for workspace: Workspace,
        newName: String,
        newIcon: String,
        windows: [WorkspaceWindow],
        screens: [WorkspaceScreen]?
    ) {
        workspaceManager.updateWorkspaceLayout(
            for: workspace,
            newName: newName,
            newIcon: newIcon,
            windows: windows,
            screens: screens
        )
    }
    
    public func updateWorkspaceWindows(
        for workspace: Workspace,
        screenIndices: Set<Int> = [],
        minVisibilityOverride: Double? = nil,
        chromeModifications: [UUID: ChromeModification] = [:],
        openByPathModifications: [UUID: OpenByPathModification] = [:]
    ) async {
        await workspaceManager.updateWorkspaceWindows(
            for: workspace,
            screenIndices: screenIndices,
            minVisibilityOverride: minVisibilityOverride,
            chromeModifications: chromeModifications.mapValues { mod in
                ChromeModification(
                    tabURLs: mod.tabURLs,
                    profileDirectory: mod.profileDirectory,
                    profileDisplayName: mod.profileDisplayName,
                    profileHostedDomain: mod.profileHostedDomain,
                    profileUserName: mod.profileUserName,
                    profileMatchMode: mod.profileMatchMode
                )
            },
            openByPathModifications: openByPathModifications.mapValues { mod in
                OpenByPathModification(
                    bundleIdentifier: mod.bundleIdentifier,
                    windowTitle: mod.windowTitle,
                    openPath: mod.openPath
                )
            }
        )
    }

    @MainActor
    public func deleteWorkspace(_ workspace: Workspace) {
        workspaceManager.deleteWorkspace(workspace)
    }

    @MainActor
    public func renameWorkspace(_ workspace: Workspace, newName: String) {
        workspaceManager.renameWorkspace(workspace, newName: newName)
    }

    @MainActor
    public func reloadWorkspaces() {
        workspaceManager.reloadWorkspaces()
    }
    
    public func setWorkspaceMissingAppCallback(_ callback: @escaping @MainActor @Sendable (String, String) -> Void) {
        workspaceManager.onMissingAppDetected = callback
    }

    @discardableResult public func restoreWorkspace(
        _ workspace: Workspace,
        source: String = "unknown",
        onRestore: (() -> Void)? = nil
    ) async -> FluentRestorationResult {
        restorationCancelled = false
        let hideAllAppsBeforeRestore = UserDefaults.standard.bool(forKey: "restoreHideAllApps")
        let options = RestorationOptions.default
            .withHideAllAppsBeforeRestore(hideAllAppsBeforeRestore)
            .withLaunchSource(source)
        return await workspaceManager.restoreWorkspace(
            workspace,
            options: options,
            source: source,
            onRestore: onRestore,
            onFailure: onWindowRestorationFailure
        )
    }

    /// Restore workspace with custom screen mapping
    public func restoreWorkspaceWithMapping(
        _ workspace: Workspace,
        screenMappings: [(workspaceScreenIndex: Int, currentScreenIndex: Int)],
        source: String = "unknown",
        onRestore: (() -> Void)? = nil
    ) async -> FluentRestorationResult {
        restorationCancelled = false
        let hideAllAppsBeforeRestore = UserDefaults.standard.bool(forKey: "restoreHideAllApps")
        let options = RestorationOptions.default
            .withHideAllAppsBeforeRestore(hideAllAppsBeforeRestore)
            .withLaunchSource(source)
        return await workspaceManager.restoreWorkspaceWithMapping(
            workspace,
            screenMappings: screenMappings,
            options: options,
            source: source,
            onRestore: onRestore,
            onFailure: onWindowRestorationFailure
        )
    }

    public func restoreWorkspaceWithDisplayAssignments(
        _ workspace: Workspace,
        displayAssignments: [WorkspaceDisplayAssignment],
        source: String = "unknown",
        onRestore: (() -> Void)? = nil
    ) async -> FluentRestorationResult {
        restorationCancelled = false
        let hideAllAppsBeforeRestore = UserDefaults.standard.bool(forKey: "restoreHideAllApps")
        let options = RestorationOptions.default
            .withHideAllAppsBeforeRestore(hideAllAppsBeforeRestore)
            .withLaunchSource(source)
        return await workspaceManager.restoreWorkspaceWithDisplayAssignments(
            workspace,
            displayAssignments: displayAssignments,
            options: options,
            source: source,
            onRestore: onRestore,
            onFailure: onWindowRestorationFailure
        )
    }

    public func cancelWorkspaceRestoration() {
        restorationCancelled = true
        Task { await FluentWorkspaceRestorer.shared.cancel() }
    }

    /// Check if restoration has been cancelled
    public var isRestorationCancelled: Bool {
        restorationCancelled
    }
    
    // MARK: - Window Movement Shortcuts
    
    // MARK: Public Movement Methods
    
    /// Moves the topmost window to the left edge of its current screen
    public func moveTopmostWindowLeft() {
        guard let topmostWindow = getTopmostVisibleWindow() else {
            return
        }

        _ = moveWindowLeft(windowInfo: topmostWindow)
    }

    /// Moves the topmost window to the right edge of its current screen
    public func moveTopmostWindowRight() {
        guard let topmostWindow = getTopmostVisibleWindow() else {
            return
        }

        _ = moveWindowRight(windowInfo: topmostWindow)
    }

    /// Moves the topmost window to the top of its current screen
    public func moveTopmostWindowUp() {
        guard let topmostWindow = getTopmostVisibleWindow() else {
            return
        }

        _ = moveWindowUp(windowInfo: topmostWindow)
    }

    /// Moves the topmost window to the bottom of its current screen
    public func moveTopmostWindowDown() {
        guard let topmostWindow = getTopmostVisibleWindow() else {
            return
        }

        _ = moveWindowDown(windowInfo: topmostWindow)
    }
    
    public func centerTopmostWindow() {
        guard let topmostWindow = getTopmostVisibleWindow() else {
            return
        }

        _ = centerWindow(windowInfo: topmostWindow)
    }
    
    public func maximizeTopmostWindow() {
        guard let topmostWindow = getTopmostVisibleWindow() else {
            return
        }

        _ = maximizeWindow(windowInfo: topmostWindow)
    }
    
    /// Closes the topmost visible window
    public func closeTopmostWindow() {
        guard let topmostWindow = getTopmostVisibleWindow() else { return }
        _ = closeWindow(windowInfo: topmostWindow)
    }

    /// Hides the topmost visible window
    public func hideTopmostWindow() {
        guard let topmostWindow = getTopmostVisibleWindow() else { return }
        _ = hideWindow(windowInfo: topmostWindow)
    }

    /// Minimizes the topmost visible window
    public func minimizeTopmostWindow() {
        guard let topmostWindow = getTopmostVisibleWindow() else { return }
        _ = minimizeWindow(windowInfo: topmostWindow)
    }

    /// Restores the topmost visible window
    public func restoreTopmostWindow() {
        guard let topmostWindow = getTopmostVisibleWindow() else { return }
        _ = restoreWindow(windowInfo: topmostWindow)
    }

    /// Activates the topmost visible window
    public func activateTopmostWindow() {
        guard let topmostWindow = getTopmostVisibleWindow() else { return }
        _ = activateWindow(windowInfo: topmostWindow)
    }
    
    /// Test method: Creates a new window for the topmost visible application
    /// This is for debugging/testing window creation across different apps
    public func testCreateNewWindow() {
        DeskJigLog.info(.window, "🧪 Testing window creation for topmost app")
        
        guard let topmostWindow = getTopmostVisibleWindow() else {
            DeskJigLog.warn(.window, "🧪 No topmost window found to test window creation")
            return
        }

        DeskJigLog.info(.window, "🧪 Creating new window for app: \(topmostWindow.appName) (bundle: \(topmostWindow.bundleIdentifier ?? "nil"))")

        guard let bundleIdentifier = topmostWindow.bundleIdentifier else {
            DeskJigLog.warn(.window, "🧪 ❌ No bundle identifier for \(topmostWindow.appName)")
            return
        }

        let success = createNewWindow(for: topmostWindow.appName, bundleIdentifier: bundleIdentifier)

        if success {
            DeskJigLog.info(.window, "🧪 ✅ Window creation succeeded for \(topmostWindow.appName)")
        } else {
            DeskJigLog.warn(.window, "🧪 ❌ Window creation failed for \(topmostWindow.appName)")
        }
    }

    /// Snaps the topmost window to the left half of the screen
    public func moveTopmostWindowToLeftHalf() {
        guard let topmostWindow = getTopmostVisibleWindow() else { return }
        _ = moveWindowToLeftHalf(windowInfo: topmostWindow)
    }

    /// Snaps the topmost window to the right half of the screen
    public func moveTopmostWindowToRightHalf() {
        guard let topmostWindow = getTopmostVisibleWindow() else { return }
        _ = moveWindowToRightHalf(windowInfo: topmostWindow)
    }
    
    /// Snaps the topmost window to the top half of the screen
    public func moveTopmostWindowToTopHalf() {
        guard let topmostWindow = getTopmostVisibleWindow() else { return }
        _ = moveWindowToTopHalf(windowInfo: topmostWindow)
    }

    /// Snaps the topmost window to the bottom half of the screen
    public func moveTopmostWindowToBottomHalf() {
        guard let topmostWindow = getTopmostVisibleWindow() else { return }
        _ = moveWindowToBottomHalf(windowInfo: topmostWindow)
    }

    // MARK: - Thirds

    public func moveTopmostWindowToLeftThird() {
        guard let topmostWindow = getTopmostVisibleWindow() else { return }
        guard let handle = resolveHandle(for: topmostWindow) else { return }
        _ = handle.moveToLeftThird()
    }

    public func moveTopmostWindowToCenterThird() {
        guard let topmostWindow = getTopmostVisibleWindow() else { return }
        guard let handle = resolveHandle(for: topmostWindow) else { return }
        _ = handle.moveToCenterThird()
    }

    public func moveTopmostWindowToRightThird() {
        guard let topmostWindow = getTopmostVisibleWindow() else { return }
        guard let handle = resolveHandle(for: topmostWindow) else { return }
        _ = handle.moveToRightThird()
    }

    // MARK: - Quarters

    public func moveTopmostWindowToTopLeftQuarter() {
        guard let topmostWindow = getTopmostVisibleWindow() else { return }
        guard let handle = resolveHandle(for: topmostWindow) else { return }
        _ = handle.moveToTopLeftQuarter()
    }

    public func moveTopmostWindowToTopRightQuarter() {
        guard let topmostWindow = getTopmostVisibleWindow() else { return }
        guard let handle = resolveHandle(for: topmostWindow) else { return }
        _ = handle.moveToTopRightQuarter()
    }

    public func moveTopmostWindowToBottomLeftQuarter() {
        guard let topmostWindow = getTopmostVisibleWindow() else { return }
        guard let handle = resolveHandle(for: topmostWindow) else { return }
        _ = handle.moveToBottomLeftQuarter()
    }

    public func moveTopmostWindowToBottomRightQuarter() {
        guard let topmostWindow = getTopmostVisibleWindow() else { return }
        guard let handle = resolveHandle(for: topmostWindow) else { return }
        _ = handle.moveToBottomRightQuarter()
    }

    // MARK: - Tiling Layout Methods

    /// Apply side-by-side tiling layout to all windows on current screen
    @MainActor
    public func tileSideBySide() {
        // Refresh windows first to get latest state
        refreshWindows { [weak self] in
            guard let self = self else { return }

            TilingLayoutManager.shared.configure(
                windowManager: self,
                displayManager: self.displayManager
            )
            TilingLayoutManager.shared.applyLayout(.sideBySide)
        }
    }

    /// Apply top-bottom tiling layout to all windows on current screen
    @MainActor
    public func tileTopBottom() {
        // Refresh windows first to get latest state
        refreshWindows { [weak self] in
            guard let self = self else { return }

            TilingLayoutManager.shared.configure(
                windowManager: self,
                displayManager: self.displayManager
            )
            TilingLayoutManager.shared.applyLayout(.topBottom)
        }
    }

    /// Apply quarters tiling layout to all windows on current screen
    @MainActor
    public func tileQuarters() {
        // Refresh windows first to get latest state
        refreshWindows { [weak self] in
            guard let self = self else { return }

            TilingLayoutManager.shared.configure(
                windowManager: self,
                displayManager: self.displayManager
            )
            TilingLayoutManager.shared.applyLayout(.quarters)
        }
    }

    // MARK: Private Helpers

    private func makeRunId() -> String {
        "window_\(UUID().uuidString.prefix(8))"
    }

    private func syncCapture<T>(_ operation: @escaping () async -> T) -> T {
        let semaphore = DispatchSemaphore(value: 0)
        var result: T!

        Task.detached(priority: .userInitiated) {
            result = await operation()
            semaphore.signal()
        }

        semaphore.wait()
        return result
    }

    private func resolveHandle(for windowInfo: WindowInfo) -> WindowHandle? {
        Window.find(windowId: CGWindowID(windowInfo.id))
    }

    private func createNewWindow(for appName: String, bundleIdentifier: String) -> Bool {
        if let existingWindow = Window.all(forBundleID: bundleIdentifier, filter: .visibleOnly).first {
            _ = existingWindow.tap(preserveMousePosition: true)
            usleep(200_000)
        }

        let menuClickScript = """
        tell application "System Events"
            tell process "\(appName)"
                try
                    click menu item "New Window" of menu "File" of menu bar 1
                    return true
                on error errMsg
                    return false
                end try
            end tell
        end tell
        """

        var scriptSucceeded = false
        do {
            let result = try AppleScriptRunner.runInProcess(menuClickScript)
            if result.booleanValue {
                DeskJigLog.info(.window, "🧵 ✅ AppleScript menu click succeeded for \(appName)")
                scriptSucceeded = true
            } else {
                DeskJigLog.warn(.window, "🧵 AppleScript returned false for \(appName)")
            }
        } catch let error as AppleScriptError where error.stage == .compile {
            DeskJigLog.error(.window, "🧵 Failed to create NSAppleScript object for \(appName)")
        } catch {
            DeskJigLog.warn(.window, "🧵 AppleScript error for \(appName): \(error)")
        }

        return scriptSucceeded
    }

    /// Gets the topmost visible window by querying the system directly.
    public func getTopmostVisibleWindow() -> WindowInfo? {
        guard accessibilityManager.hasAccessibilityPermissions else {
            DeskJigLog.trace(.window, "Accessibility permissions not granted")
            return nil
        }

        let runId = makeRunId()
        let currentWindows = syncCapture {
            await SystemSnapshotCapture.captureWindowInfos(
                runId: runId,
                includeHidden: true,
                includeAXEnrichment: false
            )
        }

        return currentWindows.first { !$0.isMinimized && !$0.isHidden }
    }

    // MARK: - Spaces Management (SkyLight)
    
    /// Public access to SkyLightService for Spaces manipulation
    /// ⚠️ WARNING: Uses private macOS APIs that may break in future versions
    public var skyLightService: SkyLightService {
        return SkyLightService.shared
    }
    
    /// Checks if SkyLight Spaces functionality is available
    public var isSpaceManagementAvailable: Bool {
        return SkyLightService.shared.isAvailable()
    }

    /// Gets the currently active Space ID (main display)
    public func getActiveSpace() -> Int {
        return SkyLightService.shared.getActiveSpace()
    }
    
    /// Gets information about the currently active Space
    public func getActiveSpaceInfo() -> SpaceInfo? {
        return SkyLightService.shared.getActiveSpaceInfo()
    }
    
    /// Gets all user-created desktop Spaces
    public func getUserSpaces() -> [SpaceInfo] {
        return SkyLightService.shared.getUserSpaces()
    }
    
    /// Gets all Spaces (user, fullscreen, system)
    public func getAllSpaces() -> [SpaceInfo] {
        return SkyLightService.shared.getAllSpaces()
    }

    /// Gets the Space that a window belongs to
    public func getSpaceForWindow(windowInfo: WindowInfo) -> Int? {
        return SkyLightService.shared.getSpaceForWindow(window: windowInfo)
    }
    
    /// Checks if a window is on the currently active Space (main display only)
    public func isWindowOnCurrentSpace(windowInfo: WindowInfo) -> Bool {
        return SkyLightService.shared.isWindowOnCurrentSpace(window: windowInfo)
    }
    
    /// Checks if a window is on ANY currently visible Space (across all displays).
    /// This is more accurate for multi-monitor setups.
    public func isWindowOnAnyVisibleSpace(windowInfo: WindowInfo) -> Bool {
        return SkyLightService.shared.isWindowOnAnyVisibleSpace(window: windowInfo)
    }

    /// Gets all currently visible space IDs across all displays.
    /// In multi-monitor setups, this returns multiple space IDs.
    public func getAllVisibleSpaces() -> Set<Int> {
        return SkyLightService.shared.getAllVisibleSpaces()
    }

    /// Debug: Prints information about all Spaces
    public func debugPrintSpaces() {
        SkyLightService.shared.debugPrintAllSpaces()
    }

    deinit {
        stopAutoRefresh()
    }
}
