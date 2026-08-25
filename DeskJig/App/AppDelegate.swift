//
//  AppDelegate.swift
//  DeskJig
//

import AppKit
import CoreServices
import KeyboardShortcuts
import DeskJigShared

enum URLHandoffScreenGeometry {
    static func orderedScreensLeftToRight(_ screens: [FullScreenInfo]) -> [FullScreenInfo] {
        screens.sorted { lhs, rhs in
            if lhs.frame.minX == rhs.frame.minX {
                return lhs.frame.minY < rhs.frame.minY
            }
            return lhs.frame.minX < rhs.frame.minX
        }
    }

    static func preferredScreenIndex(
        referenceFrame: CGRect?,
        screens: [FullScreenInfo]
    ) -> Int {
        let orderedScreens = orderedScreensLeftToRight(screens)
        guard !orderedScreens.isEmpty else { return 0 }
        guard let referenceFrame else { return 0 }

        let center = CGPoint(x: referenceFrame.midX, y: referenceFrame.midY)
        for (index, screen) in orderedScreens.enumerated() {
            let visibleFrame = WorkspaceDisplayTopology.screenFrameInWindowCoordinates(
                screen.visibleFrame,
                from: orderedScreens
            )
            if visibleFrame.contains(center) {
                return index
            }
        }

        return 0
    }

    static func screenVisibleFrame(
        for screenIndex: Int,
        screens: [FullScreenInfo]
    ) -> CGRect? {
        let orderedScreens = orderedScreensLeftToRight(screens)
        guard !orderedScreens.isEmpty else { return nil }

        let clampedIndex = min(max(screenIndex, 0), orderedScreens.count - 1)
        return WorkspaceDisplayTopology.screenFrameInWindowCoordinates(
            orderedScreens[clampedIndex].visibleFrame,
            from: orderedScreens
        )
    }

    static func centeredForceChromeFrame(
        for screenIndex: Int,
        screens: [FullScreenInfo]
    ) -> CGRect? {
        guard let visibleFrame = screenVisibleFrame(for: screenIndex, screens: screens) else {
            return nil
        }

        let width = visibleFrame.width * 0.70
        let height = visibleFrame.height * 0.80
        let x = visibleFrame.origin.x + (visibleFrame.width - width) / 2.0
        let y = visibleFrame.origin.y + (visibleFrame.height - height) / 2.0

        return CGRect(x: x, y: y, width: width, height: height)
    }
}

@Observable
class AppDelegate: NSObject, NSApplicationDelegate {

    private(set) var isWindowVisible = false
    var isWindowManagementModeEnabled = true

    private var windowCloseObserver: Any?
    private var hasRegisteredWindowManagementShortcuts = false

    private let windowTitle = DeskJigApp.mainWindowTitle

    // Reference to the status bar button for programmatic access
    var statusBarButton: NSStatusBarButton?

    var actionPanelManager: ActionPanelManager?

    // References for early startup initialization (before onFirstLoad fires)
    weak var workspaceViewModel: WorkspaceViewModel?
    /// Set to `true` after `performStartupInitialization` runs in `applicationDidFinishLaunching`.
    /// `onFirstLoad()` checks this to avoid duplicate startup work.
    private(set) var didPerformEarlyStartup = false

    // Reference to the window manager for keyboard shortcuts
    weak var windowManager: WindowManager? {
        didSet {
            if isWindowManagementModeEnabled {
                registerWindowManagementShortcutsIfNeeded()
            }
        }
    }

    // Reference to the screen indicator manager for workspace creation
    weak var screenIndicatorManager: ScreenIndicatorManager?

    // Reference for auto-opening window on first launch
    var simpleOnboardingVM: SimpleOnboardingViewModel?

    // Chrome native messaging service
    private var chromeNativeMessagingService: ChromeNativeMessagingService?

    /// Reloads the in-memory workspace list when bentoctl writes the
    /// SavedWorkspaces store out-of-process (#655), so a workspace created via
    /// `workspace create-from-spec` is restorable and visible without relaunch.
    private var workspaceExternalChangeObserver: WorkspaceExternalChangeObserver?

    func applicationDidFinishLaunching(_ notification: Notification) {

        // App-hosted test run (DeskJigTests): the XCTest runner launches this
        // very app as the test host. Startup work that reaches OUTSIDE the
        // process — global hotkey registration, the Chrome native-messaging
        // port, the menu-bar item, the action panel, the auto-opened main
        // window, the dock icon — has no business running under test: it
        // contends with a real DeskJig/Bento install for system-wide singletons
        // and steals focus mid-run. Bail out before any of it. In-process state
        // (the workspace store, logging) is untouched, so suites that read the
        // app's own model still see a fully constructed host.
        //
        // Same rationale and same predicate as SingleInstanceGuard's no-op in
        // tests; see RuntimeEnvironment.isRunningTests().
        if RuntimeEnvironment.isRunningTests() {
            DeskJigLog.info(.app, "[AppDelegate] Test host launch — skipping hotkeys, native messaging, menu bar and window presentation")
            return
        }

        // Secondary instance (dual-bundle LaunchServices routing, #565): skip all
        // normal startup — hotkeys and Chrome native messaging would clobber the
        // primary's registrations. Only register for URL events so the launch URL
        // can be forwarded to the primary, then exit cleanly.
        if SingleInstanceGuard.isSecondaryInstance {
            NSAppleEventManager.shared().setEventHandler(
                self,
                andSelector: #selector(handleGetURLEvent(_:replyEvent:)),
                forEventClass: AEEventClass(kInternetEventClass),
                andEventID: AEEventID(kAEGetURL)
            )
            SingleInstanceGuard.beginHandoffCountdown()
            return
        }

        if CommandLine.arguments.contains("--reset-defaults") {
            if let bundleID = Bundle.main.bundleIdentifier {
                UserDefaults.standard.removePersistentDomain(forName: bundleID)
                UserDefaults.standard.synchronize()
                DeskJigLog.info(.app, "Cleared UserDefaults")
            }
        }
        setupWindowCloseObserver()

        // Capture the status bar button reference after a short delay
        // This allows SwiftUI's MenuBarExtra to be fully set up
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.captureStatusBarButton()
        }

        // Auto-open window if onboarding is incomplete
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [weak self] in
            self?.checkAndAutoOpenWindowDirect()
        }

        KeyboardShortcuts.onKeyUp(for: .showWorkspaceView) { [self] in
            DeskJigLog.info(.app, "Show Workspace View shortcut activated!")
            logAnalyticsEvent("shortcut_activated", parameters: ["type": "workspace_view"])
            let shouldShowWindow = shouldShowMainWindowForWorkspaceShortcut()
            setMainWindowIsVisible(shouldShowWindow)
            if shouldShowWindow {
                UserDefaults.standard.set(SettingsSidebarSection.allWorkspaces.rawValue, forKey: "settings.selectedSection")
                DeskJigContentView.sectionPublisher.send(.allWorkspaces)
            }
        }

        KeyboardShortcuts.onKeyUp(for: .quickSwitch) { [self] in
            DeskJigLog.info(.app, "Quick Switch shortcut activated!")
            logAnalyticsEvent("shortcut_activated", parameters: ["type": "quick_switch"])
            setMainWindowIsVisible(true)
            DeskJigContentView.sectionPublisher.send(.quickSwitch)
        }

        KeyboardShortcuts.onKeyUp(for: .hideApp) { [weak self] in
            guard let self, let windowManager else { return }
            DeskJigLog.info(.app, "Hide app shortcut activated!")
            windowManager.hideTopmostWindow()
        }

        KeyboardShortcuts.onKeyUp(for: .hideAllApps) { [weak self] in
            guard let self, let windowManager else { return }
            DeskJigLog.info(.app, "Hide all apps shortcut activated!")
            let _ = windowManager.hideAllWindows()
        }

        KeyboardShortcuts.onKeyUp(for: .showAllApps) { [weak self] in
            guard let self, let windowManager else { return }
            DeskJigLog.info(.app, "Show all apps shortcut activated!")
            _ = windowManager.unhideAllWindows()
        }

        // Window management shortcuts are enabled by default
        registerWindowManagementShortcutsIfNeeded()

        // Register for URL events
        NSAppleEventManager.shared().setEventHandler(
            self,
            andSelector: #selector(handleGetURLEvent(_:replyEvent:)),
            forEventClass: AEEventClass(kInternetEventClass),
            andEventID: AEEventID(kAEGetURL)
        )

        // Observe external SavedWorkspaces writes from bentoctl (#655) so a
        // CLI-created workspace is immediately restorable (`bentoctl app
        // restore`) and visible in the UI without an app relaunch. Delivered
        // on the main queue by WorkspaceExternalChangeObserver.
        workspaceExternalChangeObserver = WorkspaceExternalChangeObserver { [weak self] in
            MainActor.assumeIsolated {
                guard let windowManager = self?.windowManager else { return }
                DeskJigLog.info(.app, "External workspace-store change signal received; reloading workspaces")
                windowManager.reloadWorkspaces()
            }
        }

        // Start Chrome native messaging service
        startChromeNativeMessagingService()

        // Perform critical startup work that onFirstLoad() normally handles.
        // applicationDidFinishLaunching fires reliably on every launch, whereas
        // .onLoad on MenuBarExtra can be delayed 30-50s+ on rapid restarts.
        performStartupInitialization()

        if let actionPanelManager {
            DeskJigLog.info(.app, "Presenting ActionPanelManager from app delegate")
            actionPanelManager.presentPanel()
        } else {
            DeskJigLog.warn(.app, "No ActionPanelManager")
        }

        // Add DeskJig to the dock
        NSApp.setActivationPolicy(.regular)
    }

    @MainActor
    func checkAndAutoOpenWindowDirect() {
        guard let simpleOnboardingVM else { return }

        if !simpleOnboardingVM.isCompleted {
            DeskJigLog.info(.app, "Auto-opening window (onboarding incomplete)")

            // Set the flag first
            isWindowVisible = true

            // Fire the publisher - even if no one is listening yet, we track the state
            DeskJigApp.mainWindowVisibilityPublisher.send((wasVisible: false, isVisible: true))

            // Also trigger a delayed check to ensure it actually opens
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                if self?.isWindowVisible == true {
                    // If still supposed to be visible, send publisher again
                    DeskJigApp.mainWindowVisibilityPublisher.send((wasVisible: false, isVisible: true))
                }
            }
        } else {
            presentPermissionsOnboardingIfAccessibilityMissing()
        }
    }

    /// Migrated Bento users adopt a completed onboarding, so the onboarding's
    /// Accessibility step never runs for them — but this binary's signature has
    /// no TCC grant of its own, and without one every restore fails silently
    /// (#20). Re-present the existing onboarding wizard at its permissions
    /// stage — the same flow Bento used — rather than a bespoke prompt: its
    /// button drives the native dialog, opens the Accessibility pane, polls for
    /// the grant, and pre-warms the Chrome automation TCC. Finishing the stage
    /// re-marks completion idempotently, so the wizard never loops.
    ///
    /// `--force-permissions-onboarding` presents it regardless of grant state,
    /// so the flow can be exercised on a machine that has already granted.
    @MainActor
    private func presentPermissionsOnboardingIfAccessibilityMissing() {
        let forced = CommandLine.arguments.contains("--force-permissions-onboarding")
        guard forced || !AXIsProcessTrusted() else { return }
        guard let simpleOnboardingVM else { return }

        DeskJigLog.warn(.app, "Accessibility not granted after completed onboarding — presenting permissions onboarding stage", fields: ["forced": forced])

        isWindowVisible = true
        DeskJigApp.mainWindowVisibilityPublisher.send((wasVisible: false, isVisible: true))
        simpleOnboardingVM.presentPermissionsStageForMigration()

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            if self?.isWindowVisible == true {
                DeskJigApp.mainWindowVisibilityPublisher.send((wasVisible: false, isVisible: true))
            }
        }
    }

    // MARK: - Early Startup Initialization

    /// Runs the startup work that `onFirstLoad()` normally performs, but from
    /// `applicationDidFinishLaunching` which fires reliably every launch.
    ///
    /// When the MenuBarExtra `.onLoad` is delayed (common on rapid app restarts), the
    /// dock would otherwise stay empty until that callback fires.
    @MainActor
    func performStartupInitialization() {
        guard !didPerformEarlyStartup else { return }
        windowManager?.reloadWorkspaces()
        actionPanelManager?.forceRefreshDynamicContent()
        // The old `actionPanelManager?.isDisabled = false` un-gate is gone with
        // the subscription wall — the panel is enabled from construction.
        didPerformEarlyStartup = true
    }

    // MARK: - Event Logging Helpers

    /// Local-only event log. DeskJig ships no analytics backend; this exists so
    /// the call sites that used to feed one keep a readable breadcrumb trail.
    func logAnalyticsEvent(_ name: String, parameters: [String: Any]?) {
        DeskJigLog.info(.app, "Event", fields: ["name": name, "parameters": "\(parameters ?? [:])"])
    }

    /// Local-only crash-context log. DeskJig ships no crash-reporting backend; this
    /// exists so call sites that used to feed one keep a readable breadcrumb trail.
    func logCrashlyticsMessage(_ message: String) {
        DeskJigLog.info(.app, "Crashlytics Log", fields: ["message": message])
    }

    /// Local-only record of an important event.
    func logCriticalEvent(_ name: String, parameters: [String: Any]? = nil) {
        DeskJigLog.info(.app, "Critical Event", fields: ["name": name, "parameters": "\(parameters ?? [:])"])
    }

    // MARK: - Debug Helpers

    #if DEBUG
    /// Resets the onboarding + tutorial progress so the first-run flow can be
    /// replayed without reinstalling.
    @MainActor
    func resetTutorialProgress() {
        DeskJigLog.info(.app, "Resetting tutorial progress...")

        // Reset all onboarding systems via notifications
        NotificationCenter.default.post(
            name: SimpleOnboardingViewModel.progressResetNotification,
            object: nil
        )
        NotificationCenter.default.post(
            name: OnboardingTutorialViewModel.progressResetNotification,
            object: nil
        )

        DeskJigLog.info(.app, "Tutorial reset complete")
        logAnalyticsEvent("debug_reset_tutorial", parameters: nil)
    }
    #endif

    private func setupWindowCloseObserver() {
        windowCloseObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            // Handle window closing - don't quit the app
            guard let window = notification.object as? NSWindow, window.title == self?.windowTitle else {
                return
            }
            // Main window is closing, but app should continue running
            DeskJigLog.info(.app, "Main window closing - app will continue in status bar")
            self?.logAnalyticsEvent("window_closed", parameters: ["window_type": "main"])
            self?.isWindowVisible = false
        }
    }

    private func shouldShowMainWindowForWorkspaceShortcut() -> Bool {
        guard let mainWindow = resolvedMainWindow else {
            // No window instance yet; first shortcut press should always open.
            return true
        }

        let isActuallyVisible = mainWindow.isVisible && !mainWindow.isMiniaturized
        let isFrontmostAndFocused = isActuallyVisible && NSApp.isActive && mainWindow.isKeyWindow

        // If we're stale, reconcile cached state from actual window visibility.
        if isWindowVisible != isActuallyVisible {
            DeskJigLog.info(.app, "Main window visibility state reconciled", fields: ["cached": isWindowVisible, "actual": isActuallyVisible])
            isWindowVisible = isActuallyVisible
        }

        // If DeskJig is already frontmost and focused, allow hotkey toggle-to-hide.
        // Otherwise always show/focus on first press.
        return !isFrontmostAndFocused
    }

    private var resolvedMainWindow: NSWindow? {
        NSApplication.shared.windows.first { window in
            window.identifier?.rawValue == DeskJigApp.mainWindowID || window.title == windowTitle
        }
    }

    @MainActor
    private func bringMainWindowToFrontIfPresent() {
        guard let mainWindow = resolvedMainWindow else { return }
        NSApp.activate(ignoringOtherApps: true)
        mainWindow.orderFrontRegardless()
        mainWindow.makeKeyAndOrderFront(nil)
        mainWindow.orderFrontRegardless()
    }

    func setMainWindowIsVisible(_ isVisible: Bool) {
        DeskJigLog.info(.app, "Toggling main window visibility", fields: ["isVisible": isVisible])
        if isVisible {
            Task { @MainActor in
                bringMainWindowToFrontIfPresent()
            }
        }
        let wasVisible = self.isWindowVisible
        self.isWindowVisible = isVisible
        DeskJigApp.mainWindowVisibilityPublisher.send((wasVisible, isVisible))
        logAnalyticsEvent(isVisible ? "window_shown" : "window_hidden", parameters: nil)
    }

    func openMenuBar() {
        // Try to open the menu bar by finding and clicking the button
        if let button = statusBarButton {
            DeskJigLog.info(.app, "Opening menu bar using stored button reference")
            button.performClick(nil)
        } else {
            DeskJigLog.info(.app, "Attempting to capture and click status bar button")
            captureStatusBarButton()
            if let button = statusBarButton {
                button.performClick(nil)
            } else {
                // Fallback: Use accessibility API to perform the click
                DeskJigLog.info(.app, "Using accessibility API to open menu bar")
                clickStatusBarViaAccessibility()
            }
        }
    }

    private func captureStatusBarButton() {
        // Find the status bar button by searching through all windows
        let allWindows = NSApplication.shared.windows

        for window in allWindows {
            if let contentView = window.contentView {
                if let button = findButtonInView(contentView) {
                    statusBarButton = button
                    DeskJigLog.info(.app, "Successfully captured status bar button reference")
                    return
                }
            }
        }

        DeskJigLog.debug(.app, "Could not find status bar button in window hierarchy")
    }

    private func findButtonInView(_ view: NSView) -> NSStatusBarButton? {
        if let button = view as? NSStatusBarButton {
            return button
        }

        for subview in view.subviews {
            if let button = findButtonInView(subview) {
                return button
            }
        }

        return nil
    }

    private func axElement(from reference: AnyObject?) -> AXUIElement? {
        guard let reference else {
            return nil
        }

        let cfReference = reference as CFTypeRef
        guard CFGetTypeID(cfReference) == AXUIElementGetTypeID() else {
            return nil
        }

        return unsafeBitCast(cfReference, to: AXUIElement.self)
    }

    private func clickStatusBarViaAccessibility() {
        // Use accessibility API to find and click our menu bar item
        let systemElement = AXUIElementCreateSystemWide()

        // Get the menu bar
        var menuBarRef: AnyObject?
        guard AXUIElementCopyAttributeValue(systemElement, kAXMenuBarAttribute as CFString, &menuBarRef) == .success,
              let menuBarElement = axElement(from: menuBarRef) else {
            DeskJigLog.warn(.app, "Could not access menu bar via accessibility")
            return
        }

        // Get menu bar items (extras)
        var extrasRef: AnyObject?
        guard AXUIElementCopyAttributeValue(menuBarElement, "AXExtrasMenuBar" as CFString, &extrasRef) == .success,
              let extrasElement = axElement(from: extrasRef) else {
            // Try getting all children if extras not available
            var childrenRef: AnyObject?
            guard AXUIElementCopyAttributeValue(menuBarElement, kAXChildrenAttribute as CFString, &childrenRef) == .success,
                  let children = childrenRef as? [AXUIElement] else {
                DeskJigLog.warn(.app, "Could not get menu bar children via accessibility")
                return
            }

            // Look for our menu bar extra in all children (usually at the right side)
            // Check the last few items as extras are typically on the right
            let startIndex = max(0, children.count - 10)
            for item in children[startIndex...].reversed() {
                if tryClickMenuItem(item) {
                    return
                }
            }

            DeskJigLog.warn(.app, "Could not find menu bar item via accessibility")
            return
        }

        // Get children of extras
        var extrasChildrenRef: AnyObject?
        guard AXUIElementCopyAttributeValue(extrasElement, kAXChildrenAttribute as CFString, &extrasChildrenRef) == .success,
              let extrasChildren = extrasChildrenRef as? [AXUIElement] else {
            DeskJigLog.warn(.app, "Could not get menu bar extras children")
            return
        }

        // Look through extras for our item
        for item in extrasChildren.reversed() {
            if tryClickMenuItem(item) {
                return
            }
        }

        DeskJigLog.warn(.app, "Could not find our menu bar item in extras")
    }

    private func tryClickMenuItem(_ element: AXUIElement) -> Bool {
        // Get the description or title to identify our menu bar extra
        var descRef: AnyObject?
        var titleRef: AnyObject?

        AXUIElementCopyAttributeValue(element, kAXDescriptionAttribute as CFString, &descRef)
        AXUIElementCopyAttributeValue(element, kAXTitleAttribute as CFString, &titleRef)

        let description = descRef as? String
        let title = titleRef as? String

        // Check if this is our menu bar item
        // Our MenuBarExtra has the title "Window Monitor" or uses the system image
        if let desc = description, desc.contains("Window Monitor") || desc.contains("macwindow") {
            DeskJigLog.info(.app, "Found menu bar item via description", fields: ["description": desc])
            AXUIElementPerformAction(element, kAXPressAction as CFString)
            return true
        }

        if let t = title, t.contains("Window Monitor") {
            DeskJigLog.info(.app, "Found menu bar item via title", fields: ["title": t])
            AXUIElementPerformAction(element, kAXPressAction as CFString)
            return true
        }

        return false
    }

    // MARK: - System Snapshot Viewer

    @MainActor
    func showSnapshotViewer() {
        SnapshotViewerManager.shared.show()
    }

    private func registerWindowManagementShortcutsIfNeeded() {
        guard !hasRegisteredWindowManagementShortcuts else { return }
        guard windowManager != nil else {
            DeskJigLog.warn(.app, "Cannot register window management shortcuts - WindowManager not set yet")
            return
        }

        hasRegisteredWindowManagementShortcuts = true

        func register(
            _ name: KeyboardShortcuts.Name,
            action: @escaping (WindowManager) -> Void,
            logMessage: String
        ) {
            KeyboardShortcuts.onKeyUp(for: name) { [weak self] in
                guard let self,
                      self.isWindowManagementModeEnabled,
                      let manager = self.windowManager else { return }
                DeskJigLog.info(.app, "\(logMessage) shortcut activated!")
                action(manager)
            }
        }

        register(.moveWindowUp, action: { $0.moveTopmostWindowUp() }, logMessage: "Move window up")
        register(.moveWindowDown, action: { $0.moveTopmostWindowDown() }, logMessage: "Move window down")
        register(.moveWindowLeft, action: { $0.moveTopmostWindowLeft() }, logMessage: "Move window left")
        register(.moveWindowRight, action: { $0.moveTopmostWindowRight() }, logMessage: "Move window right")
        register(.moveWindowToLeftHalf, action: { $0.moveTopmostWindowToLeftHalf() }, logMessage: "Move window to left half")
        register(.moveWindowToRightHalf, action: { $0.moveTopmostWindowToRightHalf() }, logMessage: "Move window to right half")
        register(.moveWindowToTopHalf, action: { $0.moveTopmostWindowToTopHalf() }, logMessage: "Move window to top half")
        register(.moveWindowToBottomHalf, action: { $0.moveTopmostWindowToBottomHalf() }, logMessage: "Move window to bottom half")
        register(.moveWindowToLeftThird, action: { $0.moveTopmostWindowToLeftThird() }, logMessage: "Move window to left third")
        register(.moveWindowToCenterThird, action: { $0.moveTopmostWindowToCenterThird() }, logMessage: "Move window to center third")
        register(.moveWindowToRightThird, action: { $0.moveTopmostWindowToRightThird() }, logMessage: "Move window to right third")
        register(.moveWindowToTopLeftQuarter, action: { $0.moveTopmostWindowToTopLeftQuarter() }, logMessage: "Move window to top-left quarter")
        register(.moveWindowToTopRightQuarter, action: { $0.moveTopmostWindowToTopRightQuarter() }, logMessage: "Move window to top-right quarter")
        register(.moveWindowToBottomLeftQuarter, action: { $0.moveTopmostWindowToBottomLeftQuarter() }, logMessage: "Move window to bottom-left quarter")
        register(.moveWindowToBottomRightQuarter, action: { $0.moveTopmostWindowToBottomRightQuarter() }, logMessage: "Move window to bottom-right quarter")
        register(.maximizeWindow, action: { $0.maximizeTopmostWindow() }, logMessage: "Maximize window")
        register(.centerWindow, action: { $0.centerTopmostWindow() }, logMessage: "Center window")

        DeskJigLog.info(.app, "Window management shortcuts registered")
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false // Keep app running when window is closed
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Log app termination
        logAnalyticsEvent("app_terminated", parameters: nil)
        DeskJigLog.info(.app, "App terminating normally")

        // Stop Chrome native messaging service
        chromeNativeMessagingService?.stop()

        // Clean up observers
        if let observer = windowCloseObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    // MARK: - Chrome Native Messaging

    private func startChromeNativeMessagingService() {
        do {
            let service = ChromeNativeMessagingService()
            try service.start()
            chromeNativeMessagingService = service

            // Configure the shared holder so the fluent API can access it
            ChromeNativeMessagingServiceHolder.configure(service)

            DeskJigLog.info(.app, "Chrome native messaging service started successfully")

            // Auto-update native host registration if app path has changed
            autoUpdateNativeHostRegistration()
        } catch {
            DeskJigLog.error(.app, "Failed to start Chrome native messaging service", fields: ["error": error.localizedDescription])
        }
    }

    /// Check if native host registration needs updating (e.g., app moved to different location)
    /// and re-register automatically if the path is wrong
    private func autoUpdateNativeHostRegistration() {
        let setupManager = ChromeExtensionSetupManager.shared
        let installedBrowsers = ChromeBrowser.installedBrowsers

        guard !installedBrowsers.isEmpty else {
            DeskJigLog.debug(.app, "No Chromium browsers installed, skipping native host registration check")
            return
        }

        var needsReregistration = false

        for browser in installedBrowsers {
            let status = setupManager.checkNativeHostStatus(for: browser)
            switch status {
            case .registeredButWrongPath(let currentPath, let expectedPath):
                DeskJigLog.info(.app, "Native host has wrong path", fields: ["browser": browser.rawValue, "currentPath": currentPath, "expectedPath": expectedPath])
                needsReregistration = true
            case .registeredButBinaryMissing(let path):
                // Manifest string-matches but the binary it points at is gone
                // (e.g. stale App Translocation path); re-register from the
                // current bundle location.
                DeskJigLog.warn(.app, "Native host manifest points at a missing binary", fields: ["browser": browser.rawValue, "path": path])
                needsReregistration = true
            case .notRegistered:
                // If already registered for another browser, register for this one too
                if installedBrowsers.contains(where: { setupManager.checkNativeHostStatus(for: $0) == .registered }) {
                    DeskJigLog.info(.app, "Native host not registered, will register", fields: ["browser": browser.rawValue])
                    needsReregistration = true
                }
            default:
                break
            }
        }

        if needsReregistration {
            DeskJigLog.info(.app, "Auto-updating native host registration for all browsers")
            let results = setupManager.registerNativeHostForAllBrowsers()
            for (browser, result) in results {
                switch result {
                case .success:
                    DeskJigLog.info(.app, "Successfully re-registered native host", fields: ["browser": browser.rawValue])
                case .failure(let error):
                    DeskJigLog.error(.app, "Failed to re-register native host", fields: ["browser": browser.rawValue, "error": error.localizedDescription])
                }
            }
        } else {
            DeskJigLog.debug(.app, "Native host registration is up to date")
        }
    }

    // MARK: - Workspace Creation

    func startWorkspaceCreation() {
        DeskJigLog.info(.app, "Starting workspace creation from menu bar")

        // Close the main window if it's visible
        if isWindowVisible {
            isWindowVisible = false
            if let window = NSApplication.shared.windows.first(where: { $0.title == windowTitle }) {
                window.close()
            }
        }

        // Enable screen indicators after a delay
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let screenIndicatorManager = self?.screenIndicatorManager else {
                DeskJigLog.error(.app, "Cannot start workspace creation - ScreenIndicatorManager not found")
                return
            }

            DeskJigLog.info(.app, "Enabling screen indicators for workspace creation")
            screenIndicatorManager.isEnabled = true
        }
    }
}

// MARK: - URL Handling

extension AppDelegate {
    /// Listen for and handle URL events
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            handleIncomingURL(url)
        }
    }

    // For when app is NOT running (launched via URL)
    @objc func handleGetURLEvent(_ event: NSAppleEventDescriptor, replyEvent: NSAppleEventDescriptor) {
        guard
            let urlString = event.paramDescriptor(forKeyword: AEKeyword(keyDirectObject))?.stringValue,
            let url = URL(string: urlString)
        else {
            return
        }
        DeskJigLog.info(.app, "Received URL event", fields: ["url": url.absoluteString])
        handleIncomingURL(url)
    }

    /// Handle the incoming URL
    private func handleIncomingURL(_ url: URL) {
        // Secondary instance (#565): don't handle anything locally — re-dispatch
        // to the primary instance's exact bundle and exit. URL events are always
        // delivered on the main thread.
        let forwardedToPrimary = MainActor.assumeIsolated { () -> Bool in
            guard SingleInstanceGuard.isSecondaryInstance else { return false }
            SingleInstanceGuard.forwardToPrimary(url)
            return true
        }
        if forwardedToPrimary { return }

        // Handle the registered scheme for internal links. The scheme itself is
        // a frozen legacy identifier (see BundleIdentity).
        if url.scheme == BundleIdentity.urlScheme {
            handleAppSchemeURL(url)
        }
    }

    /// Handle `bento://` scheme URLs
    private func handleAppSchemeURL(_ url: URL) {
        // In-app restore trigger (bentoctl app restore / #465). "restore" is the
        // stable host; "test-restore" is the legacy DEBUG-era alias kept for
        // existing automation. Always enabled in DEBUG builds; in Release gated
        // behind the hidden BentoAllowAppRestoreURL defaults flag.
        if url.host == "restore" || url.host == "test-restore" {
            guard Self.allowsAppRestoreURL else {
                DeskJigLog.warn(
                    .app,
                    "Rejected \(BundleIdentity.urlScheme)://\(url.host ?? "restore") request: in-app restore URL handling is disabled in Release builds. "
                        + "Enable with `defaults write \(BundleIdentity.bundleID) \(BundleIdentity.allowAppRestoreURLKey) -bool true`.",
                    fields: ["url": url.absoluteString]
                )
                return
            }
            Task { @MainActor in
                await runGUIRestoreParity(url: url)
            }
            return
        }

        if url.host == "settings" {
            let section = AppURLHelper.resolveSettingsSection(from: url)
            Task { @MainActor in
                setMainWindowIsVisible(true)
                if let section {
                    DeskJigContentView.sectionPublisher.send(section)
                } else {
                    DeskJigContentView.sectionPublisher.send(.settings)
                }
            }
            return
        }

        // Handle notify deep link (from bentoctl notify / Claude Code hooks)
        if url.host == "notify" {
            Task { @MainActor in
                handleNotifyURL(url)
            }
            return
        }

        // Handle quick-switch deep link (from bentoctl workspace quick-switch)
        if url.host == "quick-switch" {
            Task { @MainActor in
                handleQuickSwitchURL(url)
            }
            return
        }

        // Handle URL handoff deep link (from bentoctl url-handoff)
        if url.host == "url-handoff" {
            Task { @MainActor in
                handleURLHandoffURL(url)
            }
            return
        }
    }

    @MainActor
    private func handleNotifyURL(_ url: URL) {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            DeskJigLog.error(.app, "Notify URL invalid", fields: ["url": url.absoluteString])
            return
        }

        let queryItems = components.queryItems ?? []
        let message = queryItems.first(where: { $0.name == "message" })?.value
            ?? "Claude Code needs your attention"
        let subtext = queryItems.first(where: { $0.name == "subtext" })?.value
        let cwd = queryItems.first(where: { $0.name == "cwd" })?.value
        let actionTitle = queryItems.first(where: { $0.name == "action_title" })?.value ?? "Switch"
        let extraURL = queryItems.first(where: { $0.name == "url" })?.value
        let openFilePath = queryItems.first(where: { $0.name == "open" })?.value

        DeskJigLog.info(.app, "Notify URL received", fields: ["message": message, "cwd": cwd ?? "nil", "url": extraURL ?? "nil", "open": openFilePath ?? "nil"])

        guard let windowManager, let workspaceVM = workspaceViewModel else {
            DeskJigLog.error(.app, "Notify URL: windowManager or workspaceViewModel not available")
            return
        }

        let savedWorkspaces = windowManager.savedWorkspaces

        // Resolve workspace from cwd using Quick Switch priority chain
        var resolvedWorkspace: Workspace?
        var transformedWorkspace: Workspace?
        let dirName: String

        if let cwd {
            let quickSwitchVM = QuickSwitchViewModel()
            resolvedWorkspace = quickSwitchVM.resolveDefaultWorkspace(
                for: cwd,
                savedWorkspaces: savedWorkspaces
            )
            if let workspace = resolvedWorkspace {
                transformedWorkspace = quickSwitchVM.makeQuickSwitchWorkspace(
                    from: workspace,
                    targetDirectoryPath: cwd
                )
            }
            // Inject Chrome URL into workspace before restoration
            if let urlString = extraURL, let workspace = transformedWorkspace {
                transformedWorkspace = AppURLHelper.injectChromeURL(urlString, into: workspace).workspace
            }
            dirName = URL(fileURLWithPath: cwd).lastPathComponent
        } else {
            dirName = "Unknown"
        }

        let toastSubtext = subtext ?? (resolvedWorkspace != nil
            ? "\(dirName) — \(resolvedWorkspace!.name)"
            : dirName)

        let notification = NotificationPresenter.NotificationContent(
            message,
            text: toastSubtext,
            icon: "terminal.fill",
            iconColor: .blue,
            actionTitle: (transformedWorkspace != nil || extraURL != nil || openFilePath != nil) ? actionTitle : nil
        )

        let tapAction: (@Sendable () -> Void)? = {
            guard let workspace = transformedWorkspace else {
                // No workspace — if URL was requested, open it directly as fallback
                if let urlString = extraURL, let fallbackURL = URL(string: urlString) {
                    return { NSWorkspace.shared.open(fallbackURL) }
                }
                if let filePath = openFilePath {
                    return { AppURLHelper.openFileViaProcess(filePath) }
                }
                return nil
            }
            let displayName = "Claude Code: \(dirName)"
            return { [weak workspaceVM] in
                Task<Void, Never> { @MainActor in
                    workspaceVM?.openWorkspace(
                        workspace,
                        source: "claudeCodeHook",
                        launchDisplayName: displayName,
                        onComplete: {
                            if let filePath = openFilePath {
                                AppURLHelper.openFileViaProcess(filePath)
                            }
                        }
                    )
                }
            }
        }()

        NotificationPresenter.present(
            notification,
            tapAction: tapAction,
            for: .persistent
        )

        logAnalyticsEvent("notify_url_received", parameters: [
            "has_cwd": cwd != nil,
            "has_workspace": resolvedWorkspace != nil
        ])
    }

    private enum URLHandoffMode: String {
        case auto
        case tabs
        case makeRoom = "make-room"
    }

    private enum URLHandoffDirection: String {
        case auto
        case leftToRight = "left-to-right"
        case rightToLeft = "right-to-left"
    }

    private enum URLHandoffOutcome: String {
        case openedExistingChrome = "opened-existing-chrome"
        case openedNewChrome = "opened-new-chrome"
        case openedMakeRoomChrome = "opened-make-room-chrome"
        case failed = "failed"
    }

    private static var activeURLHandoffChromeWindowID: Int?

    private struct URLHandoffRequest {
        let mode: URLHandoffMode
        let direction: URLHandoffDirection
        let cwd: String?
        let requestedScreenIndex: Int?
        let animateDisplacedWindow: Bool
        let toastMessage: String?
        let toastSubtext: String?
        let requester: URLHandoffRequesterContext

        var shouldPresentRestoreToast: Bool {
            mode == .makeRoom && (toastMessage != nil || toastSubtext != nil)
        }
    }

    private struct URLHandoffExecutionResult {
        let outcome: URLHandoffOutcome
        let restoreToastContext: URLHandoffRestoreToastContext?
    }

    private struct URLHandoffMakeRoomResult {
        let opened: Bool
        let restoreToastContext: URLHandoffRestoreToastContext?
    }

    private struct URLHandoffRestoreToastContext {
        let chromeBounds: CGRect
        let screenVisibleFrame: CGRect
        let restoreOnDismiss: (@MainActor () -> Void)
        let switchToWorkspaceOnDismiss: (@MainActor () -> Void)?
    }

    private struct URLHandoffSplitFrames {
        let chromeSide: CGRect
        let displacedSide: CGRect
        let resolvedDirection: URLHandoffDirection
        let screenVisibleFrame: CGRect
        let layoutMode: URLHandoffLayoutMode
    }

    private enum URLHandoffLayoutMode: String {
        case push
        case overlay
    }

    private struct URLHandoffCreatedChromeWindow {
        let windowID: Int
        let closeByIDSafe: Bool
    }

    private struct URLHandoffDisplacedSelection {
        let window: WindowHandle?
        let source: String
    }

    private struct URLHandoffRequesterContext {
        let displayName: String
        let bundleIdentifier: String?
        let appName: String?
        let iconPath: String?
        let iconAssetName: String?
    }

    private final class URLHandoffOnceGate: @unchecked Sendable {
        private let lock = NSLock()
        private var hasRun = false

        func run(_ action: @escaping @MainActor () -> Void) {
            lock.lock()
            let shouldRun = !hasRun
            if shouldRun {
                hasRun = true
            }
            lock.unlock()

            guard shouldRun else { return }
            Task { @MainActor in
                action()
            }
        }
    }

    @MainActor
    private func handleURLHandoffURL(_ url: URL) {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            DeskJigLog.error(.app, "URL handoff deep link invalid", fields: ["url": url.absoluteString])
            return
        }

        let queryItems = components.queryItems ?? []
        let modeRaw = queryItems.first(where: { $0.name == "mode" })?.value?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let mode = URLHandoffMode(rawValue: modeRaw ?? "") ?? .auto
        let directionRaw = queryItems.first(where: { $0.name == "direction" })?.value?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let direction = URLHandoffDirection(rawValue: directionRaw ?? "") ?? .auto
        let cwd = queryItems.first(where: { $0.name == "cwd" })?.value?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let screenRaw = queryItems.first(where: { $0.name == "screen" })?.value?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let requestedScreenIndex: Int? = {
            guard let screenRaw, !screenRaw.isEmpty else { return nil }
            guard let value = Int(screenRaw) else {
                DeskJigLog.warn(.app, "URL handoff screen index is invalid; ignoring override", fields: [
                    "screen": screenRaw
                ])
                return nil
            }
            return value
        }()
        let toastMessage = queryItems.first(where: { $0.name == "toast_message" })?.value?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let toastSubtext = queryItems.first(where: { $0.name == "toast_subtext" })?.value?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let requesterBundleIdentifier = queryItems.first(where: { $0.name == "requester_bundle_id" })?.value?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let requesterAppName = queryItems.first(where: { $0.name == "requester_app_name" })?.value?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let requesterIconPath = queryItems.first(where: { $0.name == "requester_icon_path" })?.value?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let animateDisplacedRaw = queryItems.first(where: { $0.name == "animate_displaced" })?.value?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        var rawURLs = queryItems
            .filter { $0.name == "url" }
            .compactMap(\.value)

        let csvURLs = queryItems
            .filter { $0.name == "urls" }
            .compactMap(\.value)
            .flatMap { value in
                value.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
            }
        rawURLs.append(contentsOf: csvURLs)

        let urls = Self.normalizedURLHandoffURLs(rawURLs)

        guard !urls.isEmpty else {
            DeskJigLog.warn(.app, "URL handoff ignored because no valid URLs were provided", fields: [
                "mode": mode.rawValue,
                "cwd": cwd ?? "nil"
            ])
            return
        }

        let request = URLHandoffRequest(
            mode: mode,
            direction: direction,
            cwd: cwd,
            requestedScreenIndex: requestedScreenIndex,
            animateDisplacedWindow: Self.parseURLHandoffBool(
                animateDisplacedRaw,
                key: "animate_displaced",
                defaultValue: false
            ),
            toastMessage: (toastMessage?.isEmpty == false) ? toastMessage : nil,
            toastSubtext: (toastSubtext?.isEmpty == false) ? toastSubtext : nil,
            requester: Self.resolveURLHandoffRequesterContext(
                bundleIdentifier: requesterBundleIdentifier,
                appName: requesterAppName,
                iconPathOverride: requesterIconPath
            )
        )
        let execution = Self.executeURLHandoff(urls: urls, request: request)

        if request.shouldPresentRestoreToast, let restoreToastContext = execution.restoreToastContext {
            let restoreCopy = Self.resolveURLHandoffRestoreToastCopy(
                requesterDisplayName: request.requester.displayName,
                message: request.toastMessage,
                subtext: request.toastSubtext,
                primaryURL: urls.first
            )
            Self.presentURLHandoffRestoreToast(
                title: restoreCopy.title,
                subtext: restoreCopy.body,
                chromeBounds: restoreToastContext.chromeBounds,
                screenVisibleFrame: restoreToastContext.screenVisibleFrame,
                restoreOnDismiss: restoreToastContext.restoreOnDismiss,
                switchToWorkspaceOnDismiss: restoreToastContext.switchToWorkspaceOnDismiss
            )
        }

        DeskJigLog.info(.app, "URL handoff executed", fields: [
            "mode": mode.rawValue,
            "direction": direction.rawValue,
            "screen": requestedScreenIndex.map(String.init) ?? "auto",
            "urlCount": "\(urls.count)",
            "outcome": execution.outcome.rawValue,
            "restoreToast": request.shouldPresentRestoreToast ? "true" : "false",
            "animateDisplaced": request.animateDisplacedWindow ? "true" : "false",
            "cwd": cwd ?? "nil",
            "requester": request.requester.displayName
        ])

        logAnalyticsEvent("url_handoff_received", parameters: [
            "mode": mode.rawValue,
            "direction": direction.rawValue,
            "screen_override": requestedScreenIndex as Any,
            "url_count": urls.count,
            "outcome": execution.outcome.rawValue,
            "restore_toast": request.shouldPresentRestoreToast,
            "animate_displaced": request.animateDisplacedWindow
        ])
    }

    private static func normalizedURLHandoffURLs(_ rawURLs: [String]) -> [String] {
        var deduplicated: [String] = []
        for raw in rawURLs {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            if deduplicated.contains(trimmed) { continue }
            deduplicated.append(trimmed)
        }
        return deduplicated
    }

    private static func parseURLHandoffBool(_ raw: String?, key: String, defaultValue: Bool) -> Bool {
        guard let raw, !raw.isEmpty else {
            return defaultValue
        }
        switch raw.lowercased() {
        case "1", "true", "yes", "on":
            return true
        case "0", "false", "no", "off":
            return false
        default:
            DeskJigLog.warn(.app, "URL handoff bool query value is invalid; using default", fields: [
                "key": key,
                "value": raw,
                "default": defaultValue ? "true" : "false"
            ])
            return defaultValue
        }
    }

    @MainActor
    private static func executeURLHandoff(
        urls: [String],
        request: URLHandoffRequest
    ) -> URLHandoffExecutionResult {
        let captures = ChromeAutomationService.captureOpenWindows(includeTabURLs: true)
        let hasChromeWindow = !captures.isEmpty
        // In make-room mode we always create a new managed Chrome window so restore/close
        // remains scoped to that exact handoff window.
        if request.mode != .makeRoom,
           let managedWindowID = resolvedActiveURLHandoffWindowID(from: captures),
           reuseActiveURLHandoffWindow(chromeWindowID: managedWindowID, urls: urls) {
            return URLHandoffExecutionResult(outcome: .openedExistingChrome, restoreToastContext: nil)
        }

        switch request.mode {
        case .auto:
            if hasChromeWindow, openURLsInExistingChrome(urls: urls, captures: captures) {
                return URLHandoffExecutionResult(outcome: .openedExistingChrome, restoreToastContext: nil)
            }
            let makeRoomResult = makeRoomAndOpenURLsInNewChrome(
                urls: urls,
                direction: request.direction,
                cwd: request.cwd,
                requestedScreenIndex: request.requestedScreenIndex,
                animateDisplacedWindow: request.animateDisplacedWindow,
                createRestoreAction: false,
                toastMessage: nil,
                toastSubtext: nil,
                requester: request.requester
            )
            if makeRoomResult.opened {
                return URLHandoffExecutionResult(outcome: .openedMakeRoomChrome, restoreToastContext: nil)
            }
        case .tabs:
            if hasChromeWindow, openURLsInExistingChrome(urls: urls, captures: captures) {
                return URLHandoffExecutionResult(outcome: .openedExistingChrome, restoreToastContext: nil)
            }
            if ChromeAutomationService.openURLsInNewWindow(urls) {
                return URLHandoffExecutionResult(outcome: .openedNewChrome, restoreToastContext: nil)
            }
        case .makeRoom:
            let makeRoomResult = makeRoomAndOpenURLsInNewChrome(
                urls: urls,
                direction: request.direction,
                cwd: request.cwd,
                requestedScreenIndex: request.requestedScreenIndex,
                animateDisplacedWindow: request.animateDisplacedWindow,
                createRestoreAction: request.shouldPresentRestoreToast,
                toastMessage: request.toastMessage,
                toastSubtext: request.toastSubtext,
                requester: request.requester
            )
            if makeRoomResult.opened {
                return URLHandoffExecutionResult(
                    outcome: .openedMakeRoomChrome,
                    restoreToastContext: makeRoomResult.restoreToastContext
                )
            }
        }

        guard let fallback = URL(string: urls[0]) else {
            return URLHandoffExecutionResult(outcome: .failed, restoreToastContext: nil)
        }
        NSWorkspace.shared.open(fallback)
        return URLHandoffExecutionResult(outcome: .failed, restoreToastContext: nil)
    }

    private static func openURLsInExistingChrome(
        urls: [String],
        captures: [ChromeAppleScriptWindowCapture]
    ) -> Bool {
        let preferredWindowIDs = captures.compactMap(\.chromeWindowId)
        var handledAny = false
        for url in urls {
            let handled = ChromeAutomationService.focusOrOpenURL(url, preferredChromeWindowIds: preferredWindowIDs)
            handledAny = handledAny || handled
        }
        return handledAny
    }

    /// Poll for a Chrome AX window handle at the given frame.
    @MainActor
    private static func frameMatchesWithinTolerance(_ lhs: CGRect, _ rhs: CGRect, tolerance: CGFloat) -> Bool {
        abs(lhs.origin.x - rhs.origin.x) <= tolerance
            && abs(lhs.origin.y - rhs.origin.y) <= tolerance
            && abs(lhs.width - rhs.width) <= tolerance
            && abs(lhs.height - rhs.height) <= tolerance
    }

    @MainActor
    private static func chromeWindowHandles(matchingFrame frame: CGRect, tolerance: CGFloat) -> [WindowHandle] {
        let primary = (App.Chrome?.windows(filter: .visibleOnly) ?? []).filter { handle in
            guard let handleFrame = handle.frame else { return false }
            return frameMatchesWithinTolerance(handleFrame, frame, tolerance: tolerance)
        }
        if !primary.isEmpty {
            return primary
        }

        let fallback = (App.find(bundleID: BundleRegistry.chrome)?.windows(filter: .visibleOnly) ?? []).filter { handle in
            guard let handleFrame = handle.frame else { return false }
            return frameMatchesWithinTolerance(handleFrame, frame, tolerance: tolerance)
        }
        return fallback
    }

    @MainActor
    private static func singleChromeWindowHandle(
        matchingFrame frame: CGRect,
        tolerance: CGFloat,
        context: String
    ) -> WindowHandle? {
        let matches = chromeWindowHandles(matchingFrame: frame, tolerance: tolerance)
        if matches.count > 1 {
            DeskJigLog.warn(.app, "URL handoff: ambiguous Chrome AX window match", fields: [
                "context": context,
                "matchCount": "\(matches.count)",
                "targetFrame": String(format: "(%.1f, %.1f, %.1f, %.1f)", frame.minX, frame.minY, frame.width, frame.height),
                "tolerance": String(format: "%.1f", tolerance)
            ])
            return nil
        }
        return matches.first
    }

    @MainActor
    private static func findNewChromeWindowHandle(
        matchingFrame frame: CGRect,
        tolerance: CGFloat = 20,
        maxAttempts: Int = 10,
        intervalMs: UInt32 = 50
    ) -> WindowHandle? {
        for _ in 0..<maxAttempts {
            if let handle = singleChromeWindowHandle(
                matchingFrame: frame,
                tolerance: tolerance,
                context: "poll"
            ) {
                return handle
            }
            usleep(intervalMs * 1000)
        }
        return nil
    }

    private static func activeTabURL(from capture: ChromeAppleScriptWindowCapture) -> String? {
        guard let activeTabIndex = capture.activeTabIndex else {
            return nil
        }
        let index = activeTabIndex - 1
        guard index >= 0, index < capture.tabURLs.count else {
            return nil
        }
        return capture.tabURLs[index]
    }

    /// Waits until the freshly-created handoff window reports a real active tab
    /// URL (or the poll budget runs out) so subsequent frame work does not race
    /// Chrome's initial navigation.
    private static func logCreatedChromeWindowURLVerification(
        createdWindowID: Int,
        expectedURL: String,
        phase: String
    ) {
        let maxAttempts = 6
        let pollIntervalMs: UInt32 = 120

        var observedActiveURL: String?

        for _ in 1...maxAttempts {
            guard let capture = ChromeAutomationService.captureTabs(forWindowWithChromeId: createdWindowID) else {
                usleep(pollIntervalMs * 1000)
                continue
            }

            observedActiveURL = activeTabURL(from: capture)
            if let observedActiveURL, !observedActiveURL.isEmpty, observedActiveURL != "about:blank" {
                break
            }
            usleep(pollIntervalMs * 1000)
        }

    }

    @MainActor
    private static func makeRoomAndOpenURLsInNewChrome(
        urls: [String],
        direction: URLHandoffDirection,
        cwd: String?,
        requestedScreenIndex: Int?,
        animateDisplacedWindow: Bool,
        createRestoreAction: Bool,
        toastMessage: String?,
        toastSubtext: String?,
        requester: URLHandoffRequesterContext
    ) -> URLHandoffMakeRoomResult {
        let priorFrontmostApp = NSWorkspace.shared.frontmostApplication
        let animationPreset = URLHandoffAnimationPreferences.currentPreset()
        let animationProfile = URLHandoffAnimationPreferences.profile(for: animationPreset)
        let priorTopmost = Window.topmost()
        let screenIndex = preferredScreenIndexForURLHandoff(
            referenceFrame: priorTopmost?.frame,
            requestedScreenIndex: requestedScreenIndex
        )
        let displacedSelection = selectDisplacedWindowForURLHandoff(
            referenceTopmost: priorTopmost,
            screenIndex: screenIndex
        )
        let displacedWindow = displacedSelection.window
        let displacedWindowOriginalFrame = displacedWindow?.frame
        DeskJigLog.info(.app, "URL handoff displaced window target", fields: [
            "screen": "\(screenIndex)",
            "source": displacedSelection.source,
            "app": displacedWindow?.appName ?? "nil",
            "bundleID": displacedWindow?.bundleIdentifier ?? "nil",
            "frame": displacedWindow.map {
                String(format: "(%.1f,%.1f %.1fx%.1f)", $0.frame?.minX ?? 0, $0.frame?.minY ?? 0, $0.frame?.width ?? 0, $0.frame?.height ?? 0)
            } ?? "nil"
        ])

        guard let splitFrames = computeAdaptiveSplit(
            for: screenIndex,
            direction: direction,
            displacedWindow: displacedWindow
        ) else {
            // Fallback: just open Chrome without layout changes
            let opened = ChromeAutomationService.openURLsInNewWindow(urls)
            return URLHandoffMakeRoomResult(opened: opened, restoreToastContext: nil)
        }

        let chromeBounds = splitFrames.chromeSide
        let displacedBounds = splitFrames.displacedSide
        let resolvedDirection = splitFrames.resolvedDirection
        let screenVisibleFrame = splitFrames.screenVisibleFrame
        let shouldAdjustDisplacedWindow = splitFrames.layoutMode == .push
        let shouldAnimateDisplacedWindow = shouldAdjustDisplacedWindow && animateDisplacedWindow
        let shouldGateSlideInWithAttentionToast = createRestoreAction
            && (toastMessage != nil || toastSubtext != nil)

        let screens = orderedHandoffScreensLeftToRight()
        let clampedScreenIndex = min(max(screenIndex, 0), max(screens.count - 1, 0))
        let hasLeftNeighbor = clampedScreenIndex > 0
        let hasRightNeighbor = clampedScreenIndex < (screens.count - 1)
        let hasEntrySideNeighbor: Bool = {
            switch resolvedDirection {
            case .leftToRight, .auto:
                return hasLeftNeighbor
            case .rightToLeft:
                return hasRightNeighbor
            }
        }()

        let stagingBounds = computeHandoffStagingBounds(
            chromeBounds: chromeBounds,
            screenVisibleFrame: screenVisibleFrame,
            resolvedDirection: resolvedDirection,
            hasEntrySideNeighbor: hasEntrySideNeighbor
        )
        let slideOutBounds = computeHandoffSlideOutBounds(
            chromeBounds: chromeBounds,
            screenVisibleFrame: screenVisibleFrame,
            resolvedDirection: resolvedDirection,
            hasEntrySideNeighbor: hasEntrySideNeighbor
        )

        let existingChromeIDs = Set(
            ChromeAutomationService
                .captureOpenWindows(includeTabURLs: false)
                .compactMap(\.chromeWindowId)
        )

        // Create Chrome at staging position (offscreen)
        let openResult = ChromeAutomationService.openURLsInNewWindowWithResult(
            urls,
            centeredBounds: stagingBounds,
            activateApp: false
        )
        guard openResult.opened else {
            return URLHandoffMakeRoomResult(opened: false, restoreToastContext: nil)
        }

        let afterOpenCaptures = ChromeAutomationService.captureOpenWindows(includeTabURLs: false)
        let createdChromeWindow = resolveCreatedChromeWindow(
            idsBefore: existingChromeIDs,
            capturesAfter: afterOpenCaptures,
            reportedWindowID: openResult.windowID,
            targetBounds: chromeBounds
        )
        DeskJigLog.debug(.app, "URL handoff created-window resolution", fields: [
            "reportedWindowID": openResult.windowID.map(String.init) ?? "nil",
            "resolvedWindowID": createdChromeWindow.map { String($0.windowID) } ?? "nil",
            "idCloseSafe": createdChromeWindow.map { $0.closeByIDSafe ? "true" : "false" } ?? "false"
        ])

        let createdWindowBounds = createdChromeWindow.flatMap { createdWindow in
            afterOpenCaptures.first(where: { $0.chromeWindowId == createdWindow.windowID })?.bounds
        }

        if let createdChromeWindow,
           createdChromeWindow.closeByIDSafe,
           let expectedPrimaryURL = urls.first {
            DispatchQueue.global(qos: .utility).async {
                logCreatedChromeWindowURLVerification(
                    createdWindowID: createdChromeWindow.windowID,
                    expectedURL: expectedPrimaryURL,
                    phase: "post-open"
                )
            }
        }

        // Resolve AX handle for the created Chrome window. Use ID-derived bounds first,
        // then fall back to staging/target only when unambiguous.
        let chromeHandle = createdWindowBounds.flatMap {
            findNewChromeWindowHandle(matchingFrame: $0, tolerance: 24)
        } ?? findNewChromeWindowHandle(matchingFrame: stagingBounds, tolerance: 20)
            ?? findNewChromeWindowHandle(matchingFrame: chromeBounds, tolerance: 20)

        // Align to exact staging bounds before any animation to reduce visible jitter.
        if let createdChromeWindow, createdChromeWindow.closeByIDSafe {
            _ = ChromeAutomationService.setBounds(
                chromeWindowId: createdChromeWindow.windowID,
                bounds: stagingBounds
            )
        }

        let performSlideIn: @MainActor () -> Void = {
            let displacedWindowForSlideIn = displacedWindow?.refresh() ?? displacedWindow
            let displacedAnimationSemaphore = DispatchSemaphore(value: 0)
            var displacedAnimationStarted = false

            var chromeAnimated = false

            if shouldAdjustDisplacedWindow, let displacedWindowForSlideIn {
                if shouldAnimateDisplacedWindow {
                    displacedAnimationStarted = true
                    DispatchQueue.global(qos: .userInitiated).async {
                        let animatedResult = displacedWindowForSlideIn.setFrame(
                            displacedBounds,
                            animated: true,
                            options: animationProfile.slideInOptions
                        ) != nil
                        if !animatedResult {
                            _ = displacedWindowForSlideIn.setFrame(displacedBounds, animated: false)
                        }
                        displacedAnimationSemaphore.signal()
                    }
                } else {
                    _ = displacedWindowForSlideIn.setFrame(displacedBounds, animated: false)
                }
            }

            if let chromeHandle {
                _ = chromeHandle.setFrame(stagingBounds, animated: false)
                chromeAnimated = chromeHandle.setFrame(
                    chromeBounds,
                    animated: true,
                    options: animationProfile.slideInOptions
                ) != nil
                if !chromeAnimated {
                    _ = chromeHandle.setFrame(chromeBounds, animated: false)
                }
            } else {
                // Fallback: no AX handle — move Chrome via AppleScript, animate displaced alone
                DeskJigLog.warn(.app, "URL handoff: Chrome AX handle not found at staging position, using AppleScript fallback")

                if let createdChromeWindow, createdChromeWindow.closeByIDSafe {
                    _ = ChromeAutomationService.setBounds(
                        chromeWindowId: createdChromeWindow.windowID,
                        bounds: stagingBounds
                    )
                    _ = ChromeAutomationService.setBounds(
                        chromeWindowId: createdChromeWindow.windowID,
                        bounds: chromeBounds
                    )
                }
            }

            if displacedAnimationStarted {
                let waitTimeout = max(animationProfile.slideInOptions.duration + 1.5, 2.0)
                let waitResult = displacedAnimationSemaphore.wait(timeout: .now() + waitTimeout)
                if waitResult == .success {
                    // Animation completed; result available in displacedAnimationResult if needed.
                } else if let displacedWindowForSlideIn {
                    DeskJigLog.warn(.app, "URL handoff displaced animation wait timed out during slide-in; snapping to target", fields: [
                        "timeoutSeconds": String(format: "%.2f", waitTimeout),
                        "screen": "\(screenIndex)",
                        "direction": resolvedDirection.rawValue
                    ])
                    _ = displacedWindowForSlideIn.setFrame(displacedBounds, animated: false)
                }
            }

            // Track safely-resolved window ID for reuse/cleanup.
            if let createdChromeWindow, createdChromeWindow.closeByIDSafe {
                activeURLHandoffChromeWindowID = createdChromeWindow.windowID
            }

            // Keep user context stable. Chrome sometimes becomes frontmost when creating
            // a new window via AppleScript even without explicit activate.
            if let priorFrontmostApp,
               priorFrontmostApp.bundleIdentifier != BundleRegistry.chrome,
               priorFrontmostApp.isTerminated == false {
                _ = priorFrontmostApp.activate()
            }

        }

        // Build restore-on-dismiss closure with slide-out animation.
        let restoreToastContext: URLHandoffRestoreToastContext? = {
            guard createRestoreAction else {
                return nil
            }
            let capturedChromeTargetBounds = chromeBounds
            let capturedChromeSlideOutBounds = slideOutBounds
            let capturedCreatedChromeWindow = createdChromeWindow
            let capturedDisplacedWindow = displacedWindow
            let capturedOriginalFrame = displacedWindowOriginalFrame
            let capturedLayoutMode = splitFrames.layoutMode
            let capturedShouldAnimateDisplacedWindow = shouldAnimateDisplacedWindow
            let capturedCWD = cwd?.trimmingCharacters(in: .whitespacesAndNewlines)

            let restoreOnDismiss: @MainActor () -> Void = {
                let shouldRestoreDisplaced = capturedLayoutMode == .push
                    && capturedDisplacedWindow != nil
                    && capturedOriginalFrame != nil
                let displacedWindowForRestore = capturedDisplacedWindow?.refresh() ?? capturedDisplacedWindow
                let displacedAnimationSemaphore = DispatchSemaphore(value: 0)
                var displacedAnimationStarted = false

                var chromeSlideOutAnimated = false

                if shouldRestoreDisplaced,
                   capturedShouldAnimateDisplacedWindow,
                   let displacedWindowForRestore,
                   let originalFrame = capturedOriginalFrame {
                    displacedAnimationStarted = true
                    DispatchQueue.global(qos: .userInitiated).async {
                        let animatedResult = displacedWindowForRestore.setFrame(
                            originalFrame,
                            animated: true,
                            options: animationProfile.returnOptions
                        ) != nil
                        if !animatedResult {
                            _ = displacedWindowForRestore.setFrame(originalFrame, animated: false)
                        }
                        displacedAnimationSemaphore.signal()
                    }
                }

                let chromeHandleAtDismiss: WindowHandle? = {
                    if let createdChromeWindow = capturedCreatedChromeWindow, createdChromeWindow.closeByIDSafe {
                        let capturesAtDismiss = ChromeAutomationService.captureOpenWindows(includeTabURLs: false)
                        guard let createdBounds = capturesAtDismiss.first(where: {
                            $0.chromeWindowId == createdChromeWindow.windowID
                        })?.bounds else {
                            DeskJigLog.warn(.app, "URL handoff dismiss: created Chrome window capture missing; skipping AX handle resolution", fields: [
                                "createdChromeWindowID": "\(createdChromeWindow.windowID)"
                            ])
                            return nil
                        }
                        return singleChromeWindowHandle(
                            matchingFrame: createdBounds,
                            tolerance: 24,
                            context: "dismiss-created-id-\(createdChromeWindow.windowID)"
                        )
                    }

                    return singleChromeWindowHandle(
                        matchingFrame: capturedChromeTargetBounds,
                        tolerance: 30,
                        context: "dismiss-target-bounds"
                    )
                }()

                if let chromeHandleAtDismiss {
                    chromeSlideOutAnimated = chromeHandleAtDismiss.setFrame(
                        capturedChromeSlideOutBounds,
                        animated: true,
                        options: animationProfile.slideOutOptions
                    ) != nil
                    if !chromeSlideOutAnimated {
                        _ = chromeHandleAtDismiss.setFrame(capturedChromeSlideOutBounds, animated: false)
                    }
                } else if let capturedCreatedChromeWindow, capturedCreatedChromeWindow.closeByIDSafe {
                    _ = ChromeAutomationService.setBounds(
                        chromeWindowId: capturedCreatedChromeWindow.windowID,
                        bounds: capturedChromeSlideOutBounds
                    )
                }

                if displacedAnimationStarted {
                    let waitTimeout = max(animationProfile.returnOptions.duration + 1.5, 2.0)
                    let waitResult = displacedAnimationSemaphore.wait(timeout: .now() + waitTimeout)
                    if waitResult == .success {
                        // Animation completed; result available in displacedAnimationResult if needed.
                    } else if let displacedWindowForRestore, let originalFrame = capturedOriginalFrame {
                        DeskJigLog.warn(.app, "URL handoff displaced animation wait timed out during restore; snapping to original frame", fields: [
                            "timeoutSeconds": String(format: "%.2f", waitTimeout),
                            "screen": "\(screenIndex)",
                            "direction": resolvedDirection.rawValue
                        ])
                        _ = displacedWindowForRestore.setFrame(originalFrame, animated: false)
                    }
                } else if shouldRestoreDisplaced, let displacedWindowForRestore, let originalFrame = capturedOriginalFrame {
                    _ = displacedWindowForRestore.setFrame(originalFrame, animated: false)
                }

                if let priorFrontmostApp,
                   priorFrontmostApp.bundleIdentifier != BundleRegistry.chrome,
                   priorFrontmostApp.isTerminated == false {
                    _ = priorFrontmostApp.activate()
                }

                _ = closeURLHandoffChromeWindow(
                    chromeHandle: chromeHandleAtDismiss,
                    createdChromeWindow: capturedCreatedChromeWindow,
                    context: "restore-dismiss"
                )

                if let priorFrontmostApp,
                   priorFrontmostApp.bundleIdentifier != BundleRegistry.chrome,
                   priorFrontmostApp.isTerminated == false {
                    _ = priorFrontmostApp.activate()
                }

                DeskJigLog.info(.app, "URL handoff restore action executed", fields: [
                    "chromeAXFound": chromeHandleAtDismiss != nil ? "true" : "false",
                    "createdChromeWindowID": capturedCreatedChromeWindow.map { String($0.windowID) } ?? "nil",
                    "idCloseSafe": capturedCreatedChromeWindow.map { $0.closeByIDSafe ? "true" : "false" } ?? "false",
                    "direction": resolvedDirection.rawValue,
                    "screen": "\(screenIndex)",
                    "layoutMode": capturedLayoutMode.rawValue
                ])
            }

            let switchToWorkspaceOnDismiss: (@MainActor () -> Void)? = {
                guard let capturedCWD, !capturedCWD.isEmpty else {
                    return nil
                }
                return {
                    openURLHandoffQuickSwitch(
                        cwd: capturedCWD,
                        requester: requester
                    )
                }
            }()

            return URLHandoffRestoreToastContext(
                chromeBounds: capturedChromeTargetBounds,
                screenVisibleFrame: screenVisibleFrame,
                restoreOnDismiss: restoreOnDismiss,
                switchToWorkspaceOnDismiss: switchToWorkspaceOnDismiss
            )
        }()

        if shouldGateSlideInWithAttentionToast, let restoreToastContext {
            let attentionBody = resolveURLHandoffAttentionBody(
                requesterDisplayName: requester.displayName,
                message: toastMessage,
                subtext: toastSubtext
            )

            DeskJigLog.info(.app, "URL handoff attention toast presented", fields: [
                "screen": "\(screenIndex)",
                "direction": resolvedDirection.rawValue,
                "hasMessage": attentionBody == nil ? "false" : "true",
                "requester": requester.displayName
            ])

            let restoreCopy = resolveURLHandoffRestoreToastCopy(
                requesterDisplayName: requester.displayName,
                message: toastMessage,
                subtext: toastSubtext,
                primaryURL: urls.first
            )

            presentURLHandoffAttentionToast(
                requester: requester,
                subtext: attentionBody,
                chromeBounds: chromeBounds,
                screenVisibleFrame: screenVisibleFrame,
                onAccept: {
                    DeskJigLog.info(.app, "URL handoff attention toast accepted", fields: [
                        "screen": "\(screenIndex)",
                        "direction": resolvedDirection.rawValue,
                        "requester": requester.displayName
                    ])
                    performSlideIn()
                    presentURLHandoffRestoreToast(
                        title: restoreCopy.title,
                        subtext: restoreCopy.body,
                        chromeBounds: restoreToastContext.chromeBounds,
                        screenVisibleFrame: restoreToastContext.screenVisibleFrame,
                        restoreOnDismiss: restoreToastContext.restoreOnDismiss,
                        switchToWorkspaceOnDismiss: restoreToastContext.switchToWorkspaceOnDismiss
                    )
                },
                onDismiss: {
                    DeskJigLog.info(.app, "URL handoff attention toast dismissed", fields: [
                        "screen": "\(screenIndex)",
                        "direction": resolvedDirection.rawValue,
                        "requester": requester.displayName
                    ])
                    _ = closeURLHandoffChromeWindow(
                        chromeHandle: chromeHandle,
                        createdChromeWindow: createdChromeWindow,
                        context: "attention-dismiss"
                    )
                    if let priorFrontmostApp,
                       priorFrontmostApp.bundleIdentifier != BundleRegistry.chrome,
                       priorFrontmostApp.isTerminated == false {
                        _ = priorFrontmostApp.activate()
                    }
                }
            )
            return URLHandoffMakeRoomResult(opened: true, restoreToastContext: nil)
        }

        performSlideIn()
        return URLHandoffMakeRoomResult(opened: true, restoreToastContext: restoreToastContext)
    }

    private static func closeCreatedChromeWindow(_ createdChromeWindow: URLHandoffCreatedChromeWindow?) -> Bool {
        guard let createdChromeWindow else { return false }
        guard createdChromeWindow.closeByIDSafe else {
            DeskJigLog.warn(.app, "URL handoff skipped ID close because created window could not be safely resolved", fields: [
                "windowID": "\(createdChromeWindow.windowID)"
            ])
            return false
        }

        let closed = ChromeAutomationService.closeWindow(withChromeId: createdChromeWindow.windowID)
        if closed, activeURLHandoffChromeWindowID == createdChromeWindow.windowID {
            activeURLHandoffChromeWindowID = nil
        }
        return closed
    }

    @MainActor
    private static func closeURLHandoffChromeWindow(
        chromeHandle: WindowHandle?,
        createdChromeWindow: URLHandoffCreatedChromeWindow?,
        context: String
    ) -> Bool {
        if let createdChromeWindow, createdChromeWindow.closeByIDSafe {
            let closedByID = closeCreatedChromeWindow(createdChromeWindow)
            DeskJigLog.debug(.app, "URL handoff close path: ID close attempted", fields: [
                "context": context,
                "windowID": "\(createdChromeWindow.windowID)",
                "closed": closedByID ? "true" : "false"
            ])
            if closedByID {
                return true
            }
        }

        if let chromeHandle, chromeHandle.close() != nil {
            if let createdChromeWindow,
               activeURLHandoffChromeWindowID == createdChromeWindow.windowID {
                activeURLHandoffChromeWindowID = nil
            }
            DeskJigLog.debug(.app, "URL handoff close path: AX close succeeded", fields: [
                "context": context,
                "windowID": createdChromeWindow.map { String($0.windowID) } ?? "nil"
            ])
            return true
        }

        if let createdChromeWindow {
            if createdChromeWindow.closeByIDSafe {
                DeskJigLog.warn(.app, "URL handoff close path failed (ID + AX)", fields: [
                    "context": context,
                    "windowID": "\(createdChromeWindow.windowID)"
                ])
            } else {
                DeskJigLog.warn(.app, "URL handoff close path skipped unsafe ID fallback", fields: [
                    "context": context,
                    "windowID": "\(createdChromeWindow.windowID)",
                    "idCloseSafe": "false"
                ])
            }
        }
        return false
    }

    private static func resolveCreatedChromeWindow(
        idsBefore: Set<Int>,
        capturesAfter: [ChromeAppleScriptWindowCapture],
        reportedWindowID: Int?,
        targetBounds: CGRect
    ) -> URLHandoffCreatedChromeWindow? {
        let idsAfter = Set(capturesAfter.compactMap(\.chromeWindowId))
        let newIDs = idsAfter.subtracting(idsBefore)

        if let reportedWindowID {
            if newIDs.contains(reportedWindowID) {
                return URLHandoffCreatedChromeWindow(windowID: reportedWindowID, closeByIDSafe: true)
            }
            if !idsBefore.contains(reportedWindowID) {
                return URLHandoffCreatedChromeWindow(windowID: reportedWindowID, closeByIDSafe: true)
            }
        }

        if let createdID = newIDs.sorted().last {
            return URLHandoffCreatedChromeWindow(windowID: createdID, closeByIDSafe: true)
        }

        if let matchingByBounds = capturesAfter.first(where: { capture in
            let dx = abs(capture.bounds.origin.x - targetBounds.origin.x)
            let dy = abs(capture.bounds.origin.y - targetBounds.origin.y)
            let dw = abs(capture.bounds.width - targetBounds.width)
            let dh = abs(capture.bounds.height - targetBounds.height)
            return dx <= 5 && dy <= 5 && dw <= 5 && dh <= 5
        })?.chromeWindowId {
            return URLHandoffCreatedChromeWindow(windowID: matchingByBounds, closeByIDSafe: false)
        }

        if let reportedWindowID {
            return URLHandoffCreatedChromeWindow(windowID: reportedWindowID, closeByIDSafe: false)
        }

        return nil
    }

    private static func computeHandoffStagingBounds(
        chromeBounds: CGRect,
        screenVisibleFrame: CGRect,
        resolvedDirection: URLHandoffDirection,
        hasEntrySideNeighbor: Bool,
        edgeSpill: CGFloat = 24
    ) -> CGRect {
        switch resolvedDirection {
        case .rightToLeft:
            let stagingX = hasEntrySideNeighbor
                ? chromeBounds.origin.x + min(edgeSpill, chromeBounds.width)
                : screenVisibleFrame.maxX
            return CGRect(
                x: stagingX,
                y: chromeBounds.origin.y,
                width: chromeBounds.width,
                height: chromeBounds.height
            )
        case .leftToRight, .auto:
            let stagingX = hasEntrySideNeighbor
                ? chromeBounds.origin.x - min(edgeSpill, chromeBounds.width)
                : screenVisibleFrame.minX - chromeBounds.width
            return CGRect(
                x: stagingX,
                y: chromeBounds.origin.y,
                width: chromeBounds.width,
                height: chromeBounds.height
            )
        }
    }

    private static func computeHandoffSlideOutBounds(
        chromeBounds: CGRect,
        screenVisibleFrame: CGRect,
        resolvedDirection: URLHandoffDirection,
        hasEntrySideNeighbor: Bool,
        edgeSpill: CGFloat = 24
    ) -> CGRect {
        computeHandoffStagingBounds(
            chromeBounds: chromeBounds,
            screenVisibleFrame: screenVisibleFrame,
            resolvedDirection: resolvedDirection,
            hasEntrySideNeighbor: hasEntrySideNeighbor,
            edgeSpill: edgeSpill
        )
    }

    @MainActor
    private static func preferredScreenIndexForURLHandoff(
        referenceFrame: CGRect?,
        requestedScreenIndex: Int?
    ) -> Int {
        let screens = orderedHandoffScreensLeftToRight().map(FullScreenInfo.init(screen:))
        guard !screens.isEmpty else { return 0 }

        if let requestedScreenIndex {
            let clamped = min(max(requestedScreenIndex, 0), screens.count - 1)
            if clamped != requestedScreenIndex {
                DeskJigLog.warn(.app, "URL handoff screen index clamped", fields: [
                    "requested": "\(requestedScreenIndex)",
                    "resolved": "\(clamped)",
                    "screenCount": "\(screens.count)"
                ])
            }
            return clamped
        }

        return URLHandoffScreenGeometry.preferredScreenIndex(
            referenceFrame: referenceFrame,
            screens: screens
        )
    }

    /// Resolve `.auto` direction based on the displaced window's position on screen.
    private static func resolveDirection(
        _ direction: URLHandoffDirection,
        displacedFrame: CGRect?,
        screenVisibleFrame: CGRect
    ) -> URLHandoffDirection {
        switch direction {
        case .leftToRight, .rightToLeft:
            return direction
        case .auto:
            guard let frame = displacedFrame else { return .leftToRight }
            let windowCenterX = frame.midX
            let screenCenterX = screenVisibleFrame.midX
            return windowCenterX <= screenCenterX ? .rightToLeft : .leftToRight
        }
    }

    /// Prefer monitor outer-edge entry for smoother make-room motion.
    ///
    /// On a left-most screen, entering from the right crosses a neighboring monitor and
    /// looks jittery; force left-edge entry instead. Symmetric behavior applies to right-most
    /// screens. Middle screens keep the requested direction.
    private static func enforceOuterEdgeEntryDirection(
        _ direction: URLHandoffDirection,
        screenIndex: Int,
        screenCount: Int
    ) -> URLHandoffDirection {
        guard screenCount > 1 else { return direction }

        let clampedIndex = min(max(screenIndex, 0), screenCount - 1)
        let hasLeftNeighbor = clampedIndex > 0
        let hasRightNeighbor = clampedIndex < (screenCount - 1)

        switch direction {
        case .leftToRight:
            if hasLeftNeighbor && !hasRightNeighbor {
                return .rightToLeft
            }
            return .leftToRight
        case .rightToLeft:
            if hasRightNeighbor && !hasLeftNeighbor {
                return .leftToRight
            }
            return .rightToLeft
        case .auto:
            return .auto
        }
    }

    /// Probe an app's minimum width by briefly shrinking the window and reading back.
    ///
    /// - Returns: The detected minimum width, or `nil` if the app doesn't enforce one
    ///   (i.e. it accepted the target width).
    @MainActor
    private static func probeMinimumWidth(
        window: WindowHandle,
        targetWidth: CGFloat,
        screenVisibleFrame: CGRect
    ) -> CGFloat? {
        guard let originalFrame = window.frame else { return nil }
        let testRect = CGRect(
            x: originalFrame.origin.x,
            y: originalFrame.origin.y,
            width: targetWidth,
            height: originalFrame.height
        )
        _ = window.setFrame(testRect, animated: false)
        guard let actualFrame = window.refresh()?.frame else {
            _ = window.setFrame(originalFrame, animated: false)
            return nil
        }
        _ = window.setFrame(originalFrame, animated: false)
        if actualFrame.width > targetWidth + 20 {
            return actualFrame.width
        }
        return nil
    }

    /// Minimum usable width for the Chrome side of a make-room split.
    private static let chromeMinimumUsableWidth: CGFloat = 450

    @MainActor
    private static func computeAdaptiveSplit(
        for screenIndex: Int,
        direction: URLHandoffDirection,
        displacedWindow: WindowHandle?
    ) -> URLHandoffSplitFrames? {
        let screens = orderedHandoffScreensLeftToRight().map(FullScreenInfo.init(screen:))
        guard !screens.isEmpty else { return nil }

        let clampedIndex = min(max(screenIndex, 0), screens.count - 1)
        guard let visibleFrame = URLHandoffScreenGeometry.screenVisibleFrame(
            for: clampedIndex,
            screens: screens
        ) else {
            return nil
        }

        let requestedResolved = resolveDirection(
            direction,
            displacedFrame: displacedWindow?.frame,
            screenVisibleFrame: visibleFrame
        )
        let resolved = enforceOuterEdgeEntryDirection(
            requestedResolved,
            screenIndex: clampedIndex,
            screenCount: screens.count
        )
        if requestedResolved != resolved {
            DeskJigLog.debug(.app, "URL handoff direction adjusted for outer-edge entry", fields: [
                "requested": requestedResolved.rawValue,
                "resolved": resolved.rawValue,
                "screenIndex": "\(clampedIndex)",
                "screenCount": "\(screens.count)"
            ])
        }
        var layoutMode: URLHandoffLayoutMode = displacedWindow == nil ? .overlay : .push

        var displacedWidth = visibleFrame.width / 2
        var chromeWidth = visibleFrame.width / 2

        // Probe minimum width if we have a displaced window
        if let displacedWindow {
            if let minWidth = probeMinimumWidth(
                window: displacedWindow,
                targetWidth: displacedWidth,
                screenVisibleFrame: visibleFrame
            ) {
                // App enforces a minimum wider than half — give it what it needs
                let adjustedDisplacedWidth = minWidth
                let adjustedChromeWidth = visibleFrame.width - adjustedDisplacedWidth
                if adjustedChromeWidth >= chromeMinimumUsableWidth {
                    displacedWidth = adjustedDisplacedWidth
                    chromeWidth = adjustedChromeWidth
                } else {
                    layoutMode = .overlay
                }
            }
        }
        if chromeWidth < chromeMinimumUsableWidth {
            layoutMode = .overlay
        }

        let chromeSide: CGRect
        let displacedSide: CGRect
        switch resolved {
        case .rightToLeft:
            displacedSide = CGRect(
                x: visibleFrame.origin.x,
                y: visibleFrame.origin.y,
                width: displacedWidth,
                height: visibleFrame.height
            )
            chromeSide = CGRect(
                x: visibleFrame.origin.x + displacedWidth,
                y: visibleFrame.origin.y,
                width: chromeWidth,
                height: visibleFrame.height
            )
        case .leftToRight, .auto:
            chromeSide = CGRect(
                x: visibleFrame.origin.x,
                y: visibleFrame.origin.y,
                width: chromeWidth,
                height: visibleFrame.height
            )
            displacedSide = CGRect(
                x: visibleFrame.origin.x + chromeWidth,
                y: visibleFrame.origin.y,
                width: displacedWidth,
                height: visibleFrame.height
            )
        }

        return URLHandoffSplitFrames(
            chromeSide: chromeSide,
            displacedSide: displacedSide,
            resolvedDirection: resolved,
            screenVisibleFrame: visibleFrame,
            layoutMode: layoutMode
        )
    }

    private static func orderedHandoffScreensLeftToRight() -> [NSScreen] {
        NSScreen.screens.sorted { lhs, rhs in
            if lhs.frame.minX == rhs.frame.minX {
                return lhs.frame.minY < rhs.frame.minY
            }
            return lhs.frame.minX < rhs.frame.minX
        }
    }

    @MainActor
    private static func screenVisibleFrame(for screenIndex: Int) -> CGRect? {
        URLHandoffScreenGeometry.screenVisibleFrame(
            for: screenIndex,
            screens: orderedHandoffScreensLeftToRight().map(FullScreenInfo.init(screen:))
        )
    }

    @MainActor
    private static func topmostWindowOnScreen(screenIndex: Int) -> WindowHandle? {
        guard let targetFrame = screenVisibleFrame(for: screenIndex) else {
            return nil
        }

        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let windowList = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }

        for cgWindow in windowList {
            let layer = cgWindow[kCGWindowLayer as String] as? Int ?? 0
            guard layer == 0 else { continue }
            guard let ownerPID = cgWindow[kCGWindowOwnerPID as String] as? pid_t else { continue }

            guard let ownerApp = NSWorkspace.shared.runningApplications.first(where: {
                $0.processIdentifier == ownerPID && $0.activationPolicy == .regular
            }) else { continue }
            if excludedBundleIdentifiersForURLHandoffDisplacement().contains(ownerApp.bundleIdentifier ?? "") {
                continue
            }

            guard let boundsDict = cgWindow[kCGWindowBounds as String] as? [String: CGFloat],
                  let cgX = boundsDict["X"],
                  let cgY = boundsDict["Y"],
                  let cgWidth = boundsDict["Width"],
                  let cgHeight = boundsDict["Height"] else {
                continue
            }

            if cgWidth < 65 || cgHeight < 65 {
                continue
            }

            let cgFrame = CGRect(x: cgX, y: cgY, width: cgWidth, height: cgHeight)
            guard cgFrame.intersects(targetFrame) else { continue }

            guard let rawWindowID = cgWindow[kCGWindowNumber as String] as? NSNumber else { continue }
            let windowID = CGWindowID(rawWindowID.uint32Value)
            if let handle = Window.find(windowId: windowID, filter: .visibleOnly) {
                return handle
            }
        }

        return nil
    }

    private static func excludedBundleIdentifiersForURLHandoffDisplacement() -> Set<String> {
        var excluded = Set<String>()
        excluded.insert(BundleRegistry.chrome)
        if let appBundleID = Bundle.main.bundleIdentifier {
            excluded.insert(appBundleID)
        }
        // Guard against contexts where Bundle.main may not match the app bundle.
        excluded.insert(BundleIdentity.bundleID)
        return excluded
    }

    @MainActor
    private static func isEligibleURLHandoffDisplacedWindow(
        _ window: WindowHandle,
        targetFrame: CGRect
    ) -> Bool {
        guard let frame = window.frame else { return false }
        guard frame.width >= 65, frame.height >= 65 else { return false }
        guard frame.intersects(targetFrame) else { return false }
        let bundleID = window.bundleIdentifier ?? ""
        if excludedBundleIdentifiersForURLHandoffDisplacement().contains(bundleID) {
            return false
        }
        return true
    }

    @MainActor
    private static func selectDisplacedWindowForURLHandoff(
        referenceTopmost: WindowHandle?,
        screenIndex: Int
    ) -> URLHandoffDisplacedSelection {
        guard let targetFrame = screenVisibleFrame(for: screenIndex) else {
            return URLHandoffDisplacedSelection(window: nil, source: "no-screen")
        }

        if let referenceTopmost,
           isEligibleURLHandoffDisplacedWindow(referenceTopmost, targetFrame: targetFrame) {
            return URLHandoffDisplacedSelection(window: referenceTopmost, source: "reference-topmost")
        }

        if let screenTopmost = topmostWindowOnScreen(screenIndex: screenIndex) {
            return URLHandoffDisplacedSelection(window: screenTopmost, source: "screen-topmost")
        }

        return URLHandoffDisplacedSelection(window: nil, source: "none")
    }

    private static func resolvedActiveURLHandoffWindowID(
        from captures: [ChromeAppleScriptWindowCapture]
    ) -> Int? {
        guard let activeURLHandoffChromeWindowID else { return nil }
        let stillExists = captures.contains(where: { $0.chromeWindowId == activeURLHandoffChromeWindowID })
        if stillExists {
            return activeURLHandoffChromeWindowID
        }
        self.activeURLHandoffChromeWindowID = nil
        return nil
    }

    private static func reuseActiveURLHandoffWindow(
        chromeWindowID: Int,
        urls: [String]
    ) -> Bool {
        guard let firstURL = urls.first else {
            return false
        }
        guard ChromeAutomationService.setActiveTabURL(firstURL, inWindowWithChromeId: chromeWindowID) else {
            activeURLHandoffChromeWindowID = nil
            return false
        }
        let additionalURLs = Array(urls.dropFirst())
        if !additionalURLs.isEmpty {
            ChromeAutomationService.openMissingTabs(additionalURLs, inWindowWithChromeId: chromeWindowID)
        }
        return true
    }

    @MainActor
    private static func presentURLHandoffAttentionToast(
        requester: URLHandoffRequesterContext,
        subtext: String?,
        chromeBounds: CGRect,
        screenVisibleFrame: CGRect,
        onAccept: @escaping @MainActor () -> Void,
        onDismiss: @escaping @MainActor () -> Void
    ) {
        _ = chromeBounds
        _ = screenVisibleFrame

        let title = resolveQuickSwitchApprovalTitle(
            explicitTitle: nil,
            requesterName: requester.displayName
        )
        let body = subtext ?? "A temporary preview is ready. Click Open Preview to slide it in."
        let onceGate = URLHandoffOnceGate()
        let hasResolvedIcon = requester.iconPath != nil || requester.iconAssetName != nil
        let requesterFallbackIcon = resolveQuickSwitchRequesterFallbackIcon(
            bundleIdentifier: requester.bundleIdentifier,
            appName: requester.appName ?? requester.displayName,
            hasResolvedIcon: hasResolvedIcon
        )

        let notification = NotificationPresenter.NotificationContent(
            title,
            text: body,
            icon: requesterFallbackIcon.symbol,
            iconColor: requesterFallbackIcon.color,
            appIconPath: requester.iconPath,
            appIconName: requester.iconAssetName,
            actionTitle: "Open Preview",
            forceDarkAppearance: true,
            actionUsesGreenStyle: true,
            actionPulses: true
        )

        NotificationPresenter.present(
            notification,
            tapAction: {
                onceGate.run(onAccept)
            },
            edge: .topTrailing,
            for: .persistent,
            onDismiss: { reason in
                guard reason != .action else { return }
                onceGate.run(onDismiss)
            }
        )
    }

    @MainActor
    private static func openURLHandoffQuickSwitch(
        cwd: String,
        requester: URLHandoffRequesterContext
    ) {
        var components = URLComponents()
        components.scheme = BundleIdentity.urlScheme
        components.host = "quick-switch"
        var queryItems: [URLQueryItem] = [
            URLQueryItem(name: "cwd", value: cwd),
            URLQueryItem(name: "subtext", value: "Returning to your workspace after preview."),
            URLQueryItem(name: "requester_app_name", value: requester.displayName)
        ]

        if let bundleIdentifier = requester.bundleIdentifier, !bundleIdentifier.isEmpty {
            queryItems.append(URLQueryItem(name: "requester_bundle_id", value: bundleIdentifier))
        }
        if let iconPath = requester.iconPath, !iconPath.isEmpty {
            queryItems.append(URLQueryItem(name: "requester_icon_path", value: iconPath))
        }
        components.queryItems = queryItems

        guard let quickSwitchURL = components.url else {
            DeskJigLog.error(.app, "URL handoff quick-switch action could not build URL", fields: [
                "cwd": cwd
            ])
            return
        }

        let opened = NSWorkspace.shared.open(quickSwitchURL)
        DeskJigLog.info(.app, "URL handoff quick-switch action triggered", fields: [
            "cwd": cwd,
            "opened": opened ? "true" : "false",
            "requester": requester.displayName
        ])
    }

    @MainActor
    private static func presentURLHandoffRestoreToast(
        title: String,
        subtext: String,
        chromeBounds: CGRect,
        screenVisibleFrame: CGRect,
        restoreOnDismiss: @escaping @MainActor () -> Void,
        switchToWorkspaceOnDismiss: (@MainActor () -> Void)?
    ) {
        let onceGate = URLHandoffOnceGate()

        URLHandoffChromeToastController.shared.present(
            message: title,
            subtext: subtext,
            chromeBounds: chromeBounds,
            screenVisibleFrame: screenVisibleFrame,
            actionTitle: "Close Preview Window",
            actionUsesGreenStyle: true,
            actionPulses: false,
            secondaryActionTitle: switchToWorkspaceOnDismiss == nil ? nil : "Switch to Workspace",
            secondaryActionUsesGreenStyle: false,
            secondaryActionPulses: false,
            showsCloseControl: false,
            onAction: {
                onceGate.run(restoreOnDismiss)
            },
            onSecondaryAction: switchToWorkspaceOnDismiss.map { switchToWorkspaceOnDismiss in
                {
                    onceGate.run {
                        restoreOnDismiss()
                        switchToWorkspaceOnDismiss()
                    }
                }
            },
            onClose: {
                onceGate.run(restoreOnDismiss)
            }
        )
    }

    private static func resolveURLHandoffRequesterContext(
        bundleIdentifier: String?,
        appName: String?,
        iconPathOverride: String?
    ) -> URLHandoffRequesterContext {
        let normalizedBundleIdentifier = bundleIdentifier?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedAppName = appName?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let requesterInfo = resolveRequesterApp(
            bundleIdentifier: normalizedBundleIdentifier,
            appName: normalizedAppName,
            iconPathOverride: iconPathOverride
        )
        let displayName = requesterInfo?.displayName
            ?? normalizedAppName
            ?? "Codex"

        return URLHandoffRequesterContext(
            displayName: displayName,
            bundleIdentifier: normalizedBundleIdentifier,
            appName: normalizedAppName,
            iconPath: requesterInfo?.iconPath,
            iconAssetName: requesterInfo?.iconAssetName
        )
    }

    private static func resolveURLHandoffAttentionBody(
        requesterDisplayName: String,
        message: String?,
        subtext: String?
    ) -> String? {
        let title = resolveQuickSwitchApprovalTitle(
            explicitTitle: nil,
            requesterName: requesterDisplayName
        )
        let inputs = [message, subtext]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        var seen = Set<String>()
        var filtered: [String] = []
        for line in inputs {
            let normalized = normalizeURLHandoffAttentionLineForComparison(line)
            guard !normalized.isEmpty else { continue }
            if isURLHandoffAttentionBoilerplate(
                normalizedLine: normalized,
                requesterDisplayName: requesterDisplayName,
                title: title
            ) {
                continue
            }
            if seen.insert(normalized).inserted {
                filtered.append(line)
            }
        }

        guard !filtered.isEmpty else { return nil }
        return filtered.joined(separator: "\n")
    }

    private static func normalizeURLHandoffAttentionLineForComparison(_ line: String) -> String {
        line
            .lowercased()
            .replacingOccurrences(of: "[^a-z0-9]+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func isURLHandoffAttentionBoilerplate(
        normalizedLine: String,
        requesterDisplayName: String,
        title: String
    ) -> Bool {
        let normalizedTitle = normalizeURLHandoffAttentionLineForComparison(title)
        if normalizedLine == normalizedTitle {
            return true
        }
        if normalizedLine.contains("wants your attention") {
            return true
        }

        let normalizedRequester = normalizeURLHandoffAttentionLineForComparison(requesterDisplayName)
        if normalizedRequester.isEmpty {
            return false
        }
        return normalizedLine == normalizedRequester
            || normalizedLine == "\(normalizedRequester) wants your attention"
    }

    private static func resolveURLHandoffRestoreToastCopy(
        requesterDisplayName: String,
        message: String?,
        subtext: String?,
        primaryURL: String?
    ) -> (title: String, body: String) {
        let cleanedBody = resolveURLHandoffAttentionBody(
            requesterDisplayName: requesterDisplayName,
            message: message,
            subtext: subtext
        )
        let cleanedLines = cleanedBody?
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty } ?? []
        let cleanedTitleCandidate = cleanedLines.first
        let cleanedDetail = cleanedLines.dropFirst().joined(separator: " ")

        let title: String = {
            guard let cleanedTitleCandidate, !cleanedTitleCandidate.isEmpty else {
                return "Preview from \(requesterDisplayName)"
            }
            let limit = 72
            if cleanedTitleCandidate.count <= limit {
                return cleanedTitleCandidate
            }
            let endIndex = cleanedTitleCandidate.index(cleanedTitleCandidate.startIndex, offsetBy: limit)
            return String(cleanedTitleCandidate[..<endIndex]).trimmingCharacters(in: .whitespacesAndNewlines) + "…"
        }()

        var parts: [String] = []
        if !cleanedDetail.isEmpty {
            let detailSentence = cleanedDetail.hasSuffix(".") ? cleanedDetail : "\(cleanedDetail)."
            parts.append(detailSentence)
        } else if let urlDisplay = quickSwitchURLDisplayValue(primaryURL) {
            parts.append("Showing context from \(urlDisplay).")
        }

        parts.append("Click Close Preview Window to dismiss this temporary preview, or click Switch to Workspace to close and return to your workspace.")
        return (title: title, body: parts.joined(separator: " "))
    }

    @MainActor
    private func handleQuickSwitchURL(_ url: URL) {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            DeskJigLog.error(.app, "Quick-switch URL invalid", fields: ["url": url.absoluteString])
            return
        }

        let queryItems = components.queryItems ?? []
        guard let cwd = queryItems.first(where: { $0.name == "cwd" })?.value else {
            DeskJigLog.error(.app, "Quick-switch URL missing cwd parameter")
            return
        }
        let workspaceNameOverride = queryItems.first(where: { $0.name == "workspace" })?.value
        let workspaceIDOverrideRaw = queryItems.first(where: { $0.name == "workspace_id" })?.value?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let approvalValue = queryItems.first(where: { $0.name == "approve" })?.value
        let requiresApproval = Self.isTruthyQueryValue(approvalValue)
        let approvalTitle = queryItems.first(where: { $0.name == "title" })?.value?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let approvalSubtext = queryItems.first(where: { $0.name == "subtext" })?.value?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let approvalMessage = queryItems.first(where: { $0.name == "message" })?.value?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let requesterBundleIdentifier = queryItems.first(where: { $0.name == "requester_bundle_id" })?.value?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let requesterAppName = queryItems.first(where: { $0.name == "requester_app_name" })?.value?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let requesterIconPath = queryItems.first(where: { $0.name == "requester_icon_path" })?.value?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let requestedURL = queryItems.first(where: { $0.name == "url" })?.value?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let forceChromeValue = queryItems.first(where: { $0.name == "force_chrome" })?.value
        let forceChrome = Self.isTruthyQueryValue(forceChromeValue)
        let requesterApp = Self.resolveRequesterApp(
            bundleIdentifier: requesterBundleIdentifier,
            appName: requesterAppName,
            iconPathOverride: requesterIconPath
        )

        DeskJigLog.info(.app, "Quick-switch URL received", fields: [
            "cwd": cwd,
            "workspaceOverride": workspaceNameOverride ?? "nil",
            "workspaceIDOverride": workspaceIDOverrideRaw ?? "nil",
            "requiresApproval": requiresApproval ? "true" : "false",
            "approvalTitle": (approvalTitle?.isEmpty == false) ? "provided" : "nil",
            "approvalSubtext": (approvalSubtext?.isEmpty == false) ? "provided" : "nil",
            "approvalMessage": (approvalMessage?.isEmpty == false) ? "provided" : "nil",
            "requesterBundleIdentifier": requesterBundleIdentifier ?? "nil",
            "requesterAppName": requesterAppName ?? "nil",
            "requesterIconPath": (requesterIconPath?.isEmpty == false) ? "provided" : "nil",
            "resolvedRequesterAppName": requesterApp?.displayName ?? "nil",
            "hasURL": (requestedURL?.isEmpty == false) ? "true" : "false",
            "forceChrome": forceChrome ? "true" : "false"
        ])

        guard let windowManager, let workspaceVM = workspaceViewModel else {
            DeskJigLog.error(.app, "Quick-switch URL: windowManager or workspaceViewModel not available")
            return
        }

        let quickSwitchVM = QuickSwitchViewModel()
        let initialSavedWorkspaces = windowManager.savedWorkspaces
        let initialLookup = Self.lookupQuickSwitchWorkspace(
            cwd: cwd,
            workspaceNameOverride: workspaceNameOverride,
            workspaceIDOverrideRaw: workspaceIDOverrideRaw,
            savedWorkspaces: initialSavedWorkspaces,
            quickSwitchViewModel: quickSwitchVM
        )
        Self.logQuickSwitchLookupDiagnostic(
            initialLookup,
            cwd: cwd,
            savedWorkspaceCount: initialSavedWorkspaces.count,
            attempt: "initial"
        )

        var savedWorkspaces = initialSavedWorkspaces
        var lookup = initialLookup
        var resolvedAfterReload = false
        if lookup.workspace == nil {
            DeskJigLog.info(.app, "Quick-switch: reloading saved workspaces before retry", fields: [
                "cwd": cwd,
                "workspaceOverride": workspaceNameOverride ?? "nil",
                "workspaceIDOverride": workspaceIDOverrideRaw ?? "nil",
                "initialSavedWorkspaceCount": "\(initialSavedWorkspaces.count)"
            ])
            windowManager.reloadWorkspaces()
            savedWorkspaces = windowManager.savedWorkspaces
            lookup = Self.lookupQuickSwitchWorkspace(
                cwd: cwd,
                workspaceNameOverride: workspaceNameOverride,
                workspaceIDOverrideRaw: workspaceIDOverrideRaw,
                savedWorkspaces: savedWorkspaces,
                quickSwitchViewModel: quickSwitchVM
            )
            Self.logQuickSwitchLookupDiagnostic(
                lookup,
                cwd: cwd,
                savedWorkspaceCount: savedWorkspaces.count,
                attempt: "after-reload"
            )
            resolvedAfterReload = lookup.workspace != nil
        }

        // Resolve workspace
        let resolvedWorkspace = lookup.workspace
        let resolutionSource = lookup.resolutionSource

        guard let workspace = resolvedWorkspace else {
            let dirName = URL(fileURLWithPath: cwd).lastPathComponent
            var failureDetails: [String] = []
            failureDetails.append("Directory: \(dirName)")
            if let workspaceIDOverrideRaw, !workspaceIDOverrideRaw.isEmpty {
                failureDetails.append("Requested layout ID: \(workspaceIDOverrideRaw)")
            }
            if let workspaceNameOverride, !workspaceNameOverride.isEmpty {
                failureDetails.append("Requested layout: \(workspaceNameOverride)")
            }
            failureDetails.append("No matching layout was found.")
            failureDetails.append("Set the directory's layout in Quick Switch settings.")

            NotificationPresenter.present(
                .init(
                    "Quick Switch failed",
                    text: failureDetails.joined(separator: "\n"),
                    icon: "exclamationmark.triangle.fill",
                    iconColor: .red,
                    forceDarkAppearance: true
                )
            )

            DeskJigLog.error(.app, "Quick-switch: no workspace resolved for directory", fields: [
                "cwd": cwd,
                "resolutionSource": resolutionSource,
                "workspaceOverride": workspaceNameOverride ?? "nil",
                "workspaceIDOverride": workspaceIDOverrideRaw ?? "nil",
                "savedWorkspaceCount": "\(savedWorkspaces.count)",
                "initialSavedWorkspaceCount": "\(initialSavedWorkspaces.count)",
                "resolvedAfterReload": resolvedAfterReload ? "true" : "false"
            ])
            return
        }

        DeskJigLog.info(.app, "Quick-switch: workspace resolved", fields: [
            "cwd": cwd,
            "workspace": workspace.name,
            "workspaceID": workspace.id.uuidString,
            "resolutionSource": resolutionSource,
            "resolvedAfterReload": resolvedAfterReload ? "true" : "false",
            "initialSavedWorkspaceCount": "\(initialSavedWorkspaces.count)",
            "finalSavedWorkspaceCount": "\(savedWorkspaces.count)"
        ])
        let runtimeCurrentWorkspace = windowManager.workspaceManagerService.lastRestoredWorkspaceSnapshot
        let runtimePreviousWorkspace = windowManager.workspaceManagerService.previousRestoredWorkspaceSnapshot
        let previousWorkspace = Self.resolveQuickSwitchPreviousWorkspace(
            switchingToWorkspaceID: workspace.id,
            runtimeCurrentWorkspace: runtimeCurrentWorkspace,
            runtimePreviousWorkspace: runtimePreviousWorkspace
        )
        if let previousWorkspace {
            let previousWorkspaceSource: String
            if runtimeCurrentWorkspace?.id == previousWorkspace.id {
                previousWorkspaceSource = "runtime-current"
            } else if runtimePreviousWorkspace?.id == previousWorkspace.id {
                previousWorkspaceSource = "runtime-previous"
            } else {
                previousWorkspaceSource = "unknown"
            }
            DeskJigLog.info(.app, "Quick-switch: previous workspace resolved for go-back toast", fields: [
                "workspace": previousWorkspace.name,
                "workspaceID": previousWorkspace.id.uuidString,
                "source": previousWorkspaceSource
            ])
        } else {
            DeskJigLog.info(.app, "Quick-switch: previous workspace unavailable for go-back toast", fields: [
                "targetWorkspaceID": workspace.id.uuidString
            ])
        }

        let quickSwitchTransform = quickSwitchVM.makeQuickSwitchWorkspaceTransformResult(
            from: workspace,
            targetDirectoryPath: cwd
        )
        var transformedWorkspace = quickSwitchTransform.workspace
        let dirName = URL(fileURLWithPath: cwd).lastPathComponent
        var shouldApplyPostRestoreURL = false
        var shouldForceNewChromeWindowPostRestore = false
        var forceChromeScreenIndex: Int?
        if let requestedURL, !requestedURL.isEmpty {
            let trimmedURL = requestedURL.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedURL.isEmpty else {
                DeskJigLog.warn(.app, "Quick-switch URL ignored because it is empty after trimming", fields: ["cwd": cwd])
                return
            }

            let workspaceHasChrome = transformedWorkspace.windows.contains(where: { BundleRegistry.isChrome($0.bundleIdentifier) })
            if workspaceHasChrome {
                let injection = AppURLHelper.injectChromeURL(
                    trimmedURL,
                    into: transformedWorkspace,
                    forceChrome: false
                )
                transformedWorkspace = injection.workspace
                shouldApplyPostRestoreURL = (injection.mode == .reusedExistingChrome)
                DeskJigLog.info(.app, "Quick-switch URL injection result", fields: [
                    "mode": injection.mode.rawValue,
                    "hasURL": "true",
                    "forceChrome": forceChrome ? "true" : "false"
                ])
            } else if forceChrome {
                shouldApplyPostRestoreURL = true
                shouldForceNewChromeWindowPostRestore = true
                forceChromeScreenIndex = Self.forceChromePreferredScreenIndex(in: transformedWorkspace)
                DeskJigLog.info(.app, "Quick-switch URL injection result", fields: [
                    "mode": ChromeURLInjectionMode.addedForcedChrome.rawValue,
                    "hasURL": "true",
                    "forceChrome": "true",
                    "screenIndex": "\(forceChromeScreenIndex ?? 0)"
                ])
            } else {
                DeskJigLog.info(.app, "Quick-switch URL injection result", fields: [
                    "mode": ChromeURLInjectionMode.skippedNoChrome.rawValue,
                    "hasURL": "true",
                    "forceChrome": "false"
                ])
            }
        } else if forceChrome {
            DeskJigLog.warn(.app, "Quick-switch force_chrome ignored because URL is missing", fields: ["cwd": cwd])
        }

        let postRestoreAction: (() -> Void)? = {
            guard shouldApplyPostRestoreURL, let requestedURL, !requestedURL.isEmpty else { return nil }
            let workspaceForFocus = transformedWorkspace
            let forceNewChromeWindow = shouldForceNewChromeWindowPostRestore
            let preferredScreenIndex = forceChromeScreenIndex
            return {
                Self.focusOrOpenQuickSwitchURLAfterRestore(
                    requestedURL,
                    workspace: workspaceForFocus,
                    forceNewChromeWindow: forceNewChromeWindow,
                    preferredScreenIndex: preferredScreenIndex
                )
            }
        }()
        let goBackAction: (() -> Void)? = {
            guard let previousWorkspace else { return nil }
            let switchedWorkspaceName = workspace.name
            return { [weak workspaceVM] in
                Self.presentQuickSwitchGoBackToast(
                    switchedWorkspaceName: switchedWorkspaceName,
                    previousWorkspace: previousWorkspace,
                    workspaceViewModel: workspaceVM
                )
            }
        }()
        let xcodeSkipNoticeAction: (() -> Void)? = {
            guard let notification = Self.quickSwitchSkippedXcodeNotificationContent(
                for: quickSwitchTransform,
                targetDirectoryPath: cwd
            ) else {
                return nil
            }
            return {
                NotificationPresenter.present(
                    notification,
                    for: .seconds(5)
                )
            }
        }()
        let completionAction: (() -> Void)? = {
            guard postRestoreAction != nil || xcodeSkipNoticeAction != nil || goBackAction != nil else { return nil }
            return {
                postRestoreAction?()
                xcodeSkipNoticeAction?()
                goBackAction?()
            }
        }()

        if requiresApproval {
            let displayName = "Quick Switch: \(dirName)"
            let requesterFallbackIcon = Self.resolveQuickSwitchRequesterFallbackIcon(
                bundleIdentifier: requesterBundleIdentifier,
                appName: requesterAppName,
                hasResolvedIcon: requesterApp?.iconPath != nil || requesterApp?.iconAssetName != nil
            )
            let notification = NotificationPresenter.NotificationContent(
                Self.resolveQuickSwitchApprovalTitle(
                    explicitTitle: approvalTitle,
                    requesterName: (requesterAppName?.isEmpty == false) ? requesterAppName : requesterApp?.displayName
                ),
                text: Self.resolveQuickSwitchApprovalSubtext(
                    preferredSubtext: approvalSubtext,
                    legacyMessage: approvalMessage
                ),
                detailLines: Self.resolveQuickSwitchDetailLines(
                    workspaceName: workspace.name,
                    cwd: cwd,
                    requestedURL: requestedURL
                ),
                icon: requesterFallbackIcon.symbol,
                iconColor: requesterFallbackIcon.color,
                appIconPath: requesterApp?.iconPath,
                appIconName: requesterApp?.iconAssetName,
                actionTitle: "Switch Workspace",
                actionContext: nil,
                forceDarkAppearance: true,
                actionUsesGreenStyle: true,
                actionPulses: true
            )

            NotificationPresenter.present(
                notification,
                tapAction: { [weak workspaceVM] in
                    Task<Void, Never> { @MainActor in
                        workspaceVM?.openWorkspace(
                            transformedWorkspace,
                            source: WorkspaceViewModel.quickSwitchLaunchSource,
                            launchDisplayName: displayName,
                            onComplete: completionAction
                        )
                    }
                },
                for: .persistent,
                onDismiss: { reason in
                    if reason == .action {
                        DeskJigLog.info(.app, "Quick-switch approved by user", fields: ["cwd": cwd])
                    } else {
                        DeskJigLog.info(.app, "Quick-switch approval dismissed", fields: [
                            "cwd": cwd,
                            "reason": "\(reason)"
                        ])
                    }
                }
            )

            logAnalyticsEvent("quick_switch_url_received", parameters: [
                "cwd_dir": dirName,
                "workspace": workspace.name,
                "has_override": workspaceNameOverride != nil,
                "has_workspace_id_override": workspaceIDOverrideRaw != nil,
                "requires_approval": true,
                "has_requester_bundle": requesterBundleIdentifier != nil,
                "has_url": requestedURL?.isEmpty == false,
                "force_chrome": forceChrome
            ])
            return
        }

        // Show toast with Cancel button
        let toastID = UUID()
        let notification = NotificationPresenter.NotificationContent(
            "Switching to \(workspace.name)...",
            text: dirName,
            icon: "arrow.triangle.swap",
            iconColor: .blue,
            actionTitle: "Cancel"
        )

        // Start delayed restore — cancel via Task cancellation if user taps Cancel
        let restoreTask = Task { @MainActor [weak workspaceVM] in
            try await Task.sleep(for: .milliseconds(1500))
            try Task.checkCancellation()

            let displayName = "Quick Switch: \(dirName)"
            workspaceVM?.openWorkspace(
                transformedWorkspace,
                source: WorkspaceViewModel.quickSwitchLaunchSource,
                launchDisplayName: displayName,
                onComplete: completionAction
            )

            NotificationPresenter.dismiss(notificationWithID: toastID)
        }

        NotificationPresenter.present(
            notification,
            withID: toastID,
            tapAction: nil,
            for: .persistent,
            onDismiss: { reason in
                if reason == .action {
                    // User tapped Cancel
                    restoreTask.cancel()
                    DeskJigLog.info(.app, "Quick-switch cancelled by user", fields: ["cwd": cwd])
                }
            }
        )

        logAnalyticsEvent("quick_switch_url_received", parameters: [
            "cwd_dir": dirName,
            "workspace": workspace.name,
            "has_override": workspaceNameOverride != nil,
            "has_workspace_id_override": workspaceIDOverrideRaw != nil,
            "requires_approval": false,
            "has_requester_bundle": requesterBundleIdentifier != nil,
            "has_url": requestedURL?.isEmpty == false,
            "force_chrome": forceChrome
        ])
    }

    private static func isTruthyQueryValue(_ value: String?) -> Bool {
        guard let normalized = value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !normalized.isEmpty
        else {
            return false
        }
        return normalized == "1" || normalized == "true" || normalized == "yes" || normalized == "y"
    }

    private struct RequesterAppInfo {
        let displayName: String
        let iconPath: String?
        let iconAssetName: String?
    }

    private static func resolveRequesterApp(
        bundleIdentifier: String?,
        appName: String?,
        iconPathOverride: String?
    ) -> RequesterAppInfo? {
        let normalizedIconPath = normalizeRequesterIconPath(iconPathOverride)
        let normalizedAppName = appName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedBundleIdentifier = bundleIdentifier?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        func makeRequesterInfo(displayName: String, iconPath: String?) -> RequesterAppInfo {
            RequesterAppInfo(
                displayName: displayName,
                iconPath: iconPath,
                iconAssetName: resolveQuickSwitchRequesterFallbackIconAssetName(
                    bundleIdentifier: normalizedBundleIdentifier,
                    appName: normalizedAppName,
                    hasResolvedIcon: iconPath != nil
                )
            )
        }

        if normalizedBundleIdentifier?.isEmpty != false {
            if let normalizedAppName, !normalizedAppName.isEmpty,
               let foundURL = appURL(forName: normalizedAppName) {
                return makeRequesterInfo(
                    displayName: foundURL.deletingPathExtension().lastPathComponent,
                    iconPath: normalizedIconPath ?? foundURL.path
                )
            }
            if let normalizedIconPath {
                let displayName = URL(fileURLWithPath: normalizedIconPath)
                    .deletingPathExtension()
                    .lastPathComponent
                return makeRequesterInfo(displayName: displayName, iconPath: normalizedIconPath)
            }
            return nil
        }

        guard
            let bundleIdentifier = normalizedBundleIdentifier,
            !bundleIdentifier.isEmpty
        else {
            return nil
        }

        guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) else {
            if let launchServicesAppURL = launchServicesApplicationURL(bundleIdentifier: bundleIdentifier) {
                let bundle = Bundle(url: launchServicesAppURL)
                let launchServicesDisplayName = (bundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
                    ?? (bundle?.object(forInfoDictionaryKey: "CFBundleName") as? String)
                    ?? normalizedAppName
                    ?? launchServicesAppURL.deletingPathExtension().lastPathComponent
                return makeRequesterInfo(
                    displayName: launchServicesDisplayName,
                    iconPath: normalizedIconPath ?? launchServicesAppURL.path
                )
            }
            if let normalizedAppName, !normalizedAppName.isEmpty,
               let foundURL = appURL(forName: normalizedAppName) {
                return makeRequesterInfo(
                    displayName: normalizedAppName,
                    iconPath: normalizedIconPath ?? foundURL.path
                )
            }
            if let runningApp = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).first {
                let runningLocalizedName = runningApp.localizedName?.trimmingCharacters(in: .whitespacesAndNewlines)
                let preferredDisplayName: String
                if let runningLocalizedName, !runningLocalizedName.isEmpty {
                    preferredDisplayName = runningLocalizedName
                } else if let normalizedAppName, !normalizedAppName.isEmpty {
                    preferredDisplayName = normalizedAppName
                } else {
                    preferredDisplayName = bundleIdentifier
                }
                return makeRequesterInfo(
                    displayName: preferredDisplayName,
                    iconPath: normalizedIconPath ?? runningApp.bundleURL?.path
                )
            }
            if let normalizedAppName, !normalizedAppName.isEmpty {
                return makeRequesterInfo(displayName: normalizedAppName, iconPath: normalizedIconPath)
            }
            return makeRequesterInfo(displayName: bundleIdentifier, iconPath: normalizedIconPath)
        }

        let bundle = Bundle(url: appURL)
        let displayName = (bundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (bundle?.object(forInfoDictionaryKey: "CFBundleName") as? String)
            ?? appURL.deletingPathExtension().lastPathComponent
        return makeRequesterInfo(displayName: displayName, iconPath: normalizedIconPath ?? appURL.path)
    }

    private static func appURL(forName name: String) -> URL? {
        NSWorkspace.shared.runningApplications
            .first { $0.localizedName == name }
            .flatMap { $0.bundleURL }
    }

    private static func launchServicesApplicationURL(bundleIdentifier: String) -> URL? {
        guard
            let appURLs = LSCopyApplicationURLsForBundleIdentifier(bundleIdentifier as CFString, nil)?
                .takeRetainedValue() as? [URL]
        else {
            return nil
        }
        return appURLs.first
    }

    private static func normalizeRequesterIconPath(_ iconPath: String?) -> String? {
        guard let iconPath = iconPath?.trimmingCharacters(in: .whitespacesAndNewlines), !iconPath.isEmpty else {
            return nil
        }

        let expandedPath = (iconPath as NSString).expandingTildeInPath
        let standardizedPath = URL(fileURLWithPath: expandedPath).standardizedFileURL.path
        guard FileManager.default.fileExists(atPath: standardizedPath) else {
            return nil
        }
        return standardizedPath
    }

    private static func resolveQuickSwitchApprovalTitle(
        explicitTitle: String?,
        requesterName: String?
    ) -> String {
        if let explicitTitle, !explicitTitle.isEmpty {
            return explicitTitle
        }

        if let requesterName, !requesterName.isEmpty {
            return "\(requesterName) wants your attention"
        }

        return "Codex wants your attention"
    }

    private static func resolveQuickSwitchApprovalSubtext(
        preferredSubtext: String?,
        legacyMessage: String?
    ) -> String {
        let reservedHeadline = "codex wants your attention"
        let candidates = [preferredSubtext, legacyMessage]
        for candidate in candidates {
            guard let trimmed = candidate?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
                continue
            }
            if trimmed.lowercased() == reservedHeadline {
                continue
            }
            return trimmed
        }
        return "Ready for you to test this workspace."
    }

    private static func resolveQuickSwitchDetailLines(
        workspaceName: String,
        cwd: String,
        requestedURL: String?
    ) -> [ToastDetailLine] {
        var lines: [ToastDetailLine] = []
        lines.append(ToastDetailLine(label: "Layout", value: workspaceName))
        lines.append(ToastDetailLine(label: "Directory", value: compactPathForToast(cwd)))
        if let urlDisplay = quickSwitchURLDisplayValue(requestedURL) {
            lines.append(ToastDetailLine(label: "URL", value: urlDisplay))
        }
        return lines
    }

    private struct RequesterFallbackIcon {
        let symbol: String
        let color: NotificationPresenter.NotificationContent.IconColor
    }

    private static func resolveQuickSwitchRequesterFallbackIcon(
        bundleIdentifier: String?,
        appName: String?,
        hasResolvedIcon: Bool
    ) -> RequesterFallbackIcon {
        if hasResolvedIcon {
            return RequesterFallbackIcon(symbol: "arrow.triangle.swap", color: .blue)
        }

        let tokens = [
            bundleIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? "",
            appName?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        ]
        let combined = tokens.joined(separator: " ")

        if combined.contains("anthropic") || combined.contains("claude") {
            return RequesterFallbackIcon(symbol: "sparkles", color: .yellow)
        }
        if combined.contains("openai") || combined.contains("codex") {
            return RequesterFallbackIcon(symbol: "terminal", color: .green)
        }
        return RequesterFallbackIcon(symbol: "arrow.triangle.swap", color: .blue)
    }

    private static func resolveQuickSwitchRequesterFallbackIconAssetName(
        bundleIdentifier: String?,
        appName: String?,
        hasResolvedIcon: Bool
    ) -> String? {
        if hasResolvedIcon {
            return nil
        }

        let tokens = [
            bundleIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? "",
            appName?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        ]
        let combined = tokens.joined(separator: " ")

        // CLI-based agents usually don't have an app bundle icon available.
        // Use a bundled placeholder so toasts remain visually identifiable.
        if combined.contains("anthropic") || combined.contains("claude") {
            return "ClaudeCodePlaceholder"
        }
        return nil
    }

    private static func quickSwitchURLDisplayValue(_ requestedURL: String?) -> String? {
        guard let trimmed = requestedURL?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }

        guard let components = URLComponents(string: trimmed), let host = components.host, !host.isEmpty else {
            return trimmed
        }

        let hostDisplay: String
        if let port = components.port {
            hostDisplay = "\(host):\(port)"
        } else {
            hostDisplay = host
        }

        let path = components.path.trimmingCharacters(in: .whitespacesAndNewlines)
        if path.isEmpty || path == "/" {
            return hostDisplay
        }

        let normalizedPath = path.hasPrefix("/") ? path : "/\(path)"
        return "\(hostDisplay)\(normalizedPath)"
    }

    private static func compactPathForToast(_ path: String) -> String {
        let standardizedPath = URL(fileURLWithPath: path).standardizedFileURL.path
        let homePath = NSHomeDirectory()
        if standardizedPath.hasPrefix(homePath) {
            let relativeToHome = String(standardizedPath.dropFirst(homePath.count))
            return "~\(relativeToHome)"
        }
        return standardizedPath
    }

    static func resolveQuickSwitchPreviousWorkspace(
        switchingToWorkspaceID targetWorkspaceID: UUID,
        runtimeCurrentWorkspace: Workspace?,
        runtimePreviousWorkspace: Workspace?
    ) -> Workspace? {
        if let runtimeCurrentWorkspace, runtimeCurrentWorkspace.id != targetWorkspaceID {
            return runtimeCurrentWorkspace
        }

        if let runtimePreviousWorkspace, runtimePreviousWorkspace.id != targetWorkspaceID {
            return runtimePreviousWorkspace
        }

        return nil
    }

    struct QuickSwitchWorkspaceLookupResult {
        let workspace: Workspace?
        let resolutionSource: String
        let diagnosticMessage: String?
        let diagnosticFields: [String: String]
    }

    @MainActor
    static func lookupQuickSwitchWorkspace(
        cwd: String,
        workspaceNameOverride: String?,
        workspaceIDOverrideRaw: String?,
        savedWorkspaces: [Workspace],
        quickSwitchViewModel: QuickSwitchViewModel
    ) -> QuickSwitchWorkspaceLookupResult {
        if let workspaceIDOverrideRaw, !workspaceIDOverrideRaw.isEmpty {
            let resolutionSource = "workspace-id-override"
            guard let workspaceID = UUID(uuidString: workspaceIDOverrideRaw) else {
                return QuickSwitchWorkspaceLookupResult(
                    workspace: nil,
                    resolutionSource: resolutionSource,
                    diagnosticMessage: "Quick-switch: invalid workspace ID override",
                    diagnosticFields: [
                        "workspaceID": workspaceIDOverrideRaw,
                        "cwd": cwd
                    ]
                )
            }

            let workspace = savedWorkspaces.first(where: { $0.id == workspaceID })
            return QuickSwitchWorkspaceLookupResult(
                workspace: workspace,
                resolutionSource: resolutionSource,
                diagnosticMessage: workspace == nil ? "Quick-switch: workspace ID override not found" : nil,
                diagnosticFields: [
                    "workspaceID": workspaceIDOverrideRaw,
                    "cwd": cwd
                ]
            )
        }

        if let workspaceNameOverride, !workspaceNameOverride.isEmpty {
            let resolutionSource = "workspace-name-override"
            let workspace = savedWorkspaces.first {
                $0.name.compare(workspaceNameOverride, options: [.caseInsensitive]) == .orderedSame
            }
            return QuickSwitchWorkspaceLookupResult(
                workspace: workspace,
                resolutionSource: resolutionSource,
                diagnosticMessage: workspace == nil ? "Quick-switch: workspace override not found" : nil,
                diagnosticFields: [
                    "name": workspaceNameOverride,
                    "cwd": cwd
                ]
            )
        }

        return QuickSwitchWorkspaceLookupResult(
            workspace: quickSwitchViewModel.resolveDefaultWorkspace(
                for: cwd,
                savedWorkspaces: savedWorkspaces
            ),
            resolutionSource: "quick-switch-default-chain",
            diagnosticMessage: nil,
            diagnosticFields: [:]
        )
    }

    static func logQuickSwitchLookupDiagnostic(
        _ lookup: QuickSwitchWorkspaceLookupResult,
        cwd: String,
        savedWorkspaceCount: Int,
        attempt: String
    ) {
        guard let diagnosticMessage = lookup.diagnosticMessage else {
            return
        }

        var fields = lookup.diagnosticFields
        fields["cwd"] = cwd
        fields["savedWorkspaceCount"] = "\(savedWorkspaceCount)"
        fields["attempt"] = attempt
        DeskJigLog.error(.app, diagnosticMessage, fields: fields)
    }

    static func resolveQuickSwitchPreviousWorkspace(
        switchingToWorkspaceID targetWorkspaceID: UUID,
        savedWorkspaces: [Workspace]
    ) -> Workspace? {
        savedWorkspaces
            .filter { $0.id != targetWorkspaceID }
            .max(by: isWorkspaceLessRecent)
    }

    enum ChromeURLInjectionMode: String {
        case reusedExistingChrome = "reused-existing-chrome"
        case addedForcedChrome = "added-forced-chrome"
        case skippedNoChrome = "skipped-no-chrome"
        case invalidURL = "invalid-url"
    }

    @MainActor
    private static func presentQuickSwitchGoBackToast(
        switchedWorkspaceName: String,
        previousWorkspace: Workspace,
        workspaceViewModel: WorkspaceViewModel?
    ) {
        let goBackDestination = quickSwitchGoBackDestinationLabel(for: previousWorkspace)
        let goBackDirectoryPath = quickSwitchGoBackDirectoryPath(for: previousWorkspace)
        let notification = NotificationPresenter.NotificationContent(
            "Switched to \(switchedWorkspaceName)",
            text: "Go back to \(goBackDestination)",
            icon: "arrow.uturn.backward.circle.fill",
            iconColor: .blue,
            actionTitle: "Go Back",
            actionContext: goBackDirectoryPath,
            forceDarkAppearance: true
        )

        NotificationPresenter.present(
            notification,
            tapAction: { [weak workspaceViewModel] in
                Task<Void, Never> { @MainActor in
                    guard let workspaceVM = workspaceViewModel else {
                        DeskJigLog.warn(.app, "Quick-switch go-back ignored because workspace view model is unavailable")
                        return
                    }

                    workspaceVM.openWorkspace(
                        previousWorkspace,
                        source: WorkspaceViewModel.quickSwitchLaunchSource,
                        launchDisplayName: "Quick Switch: \(previousWorkspace.name)"
                    )
                }
            },
            for: .persistent,
            onDismiss: { reason in
                DeskJigLog.info(.app, "Quick-switch go-back toast dismissed", fields: [
                    "reason": "\(reason)",
                    "previousWorkspace": previousWorkspace.name,
                    "previousWorkspaceID": previousWorkspace.id.uuidString
                ])
            }
        )
    }

    static func quickSwitchGoBackDestinationLabel(for workspace: Workspace) -> String {
        if let standardizedPath = quickSwitchGoBackStandardizedPath(for: workspace) {
            let lastComponent = URL(fileURLWithPath: standardizedPath).lastPathComponent
            let trimmedLeadingDots = lastComponent.trimmingCharacters(in: CharacterSet(charactersIn: "."))
            let basename = trimmedLeadingDots.isEmpty ? lastComponent : trimmedLeadingDots
            if let first = basename.first {
                return first.uppercased() + basename.dropFirst()
            }
        }

        return workspace.name
    }

    static func quickSwitchSkippedXcodeNotificationContent(
        for result: QuickSwitchWorkspaceTransformResult,
        targetDirectoryPath: String
    ) -> NotificationPresenter.NotificationContent? {
        guard result.skippedXcodeForNonProjectTarget, result.skippedXcodeWindowCount > 0 else {
            return nil
        }

        let directoryName = URL(fileURLWithPath: targetDirectoryPath)
            .standardizedFileURL
            .lastPathComponent

        return NotificationPresenter.NotificationContent(
            "No Xcode project detected in \(directoryName). Skipping Xcode.",
            icon: "hammer.circle.fill",
            iconColor: .yellow,
            forceDarkAppearance: true
        )
    }

    static func quickSwitchGoBackDirectoryPath(for workspace: Workspace) -> String? {
        guard let standardizedPath = quickSwitchGoBackStandardizedPath(for: workspace) else {
            return nil
        }
        return compactPathForToast(standardizedPath)
    }

    private static func quickSwitchGoBackStandardizedPath(for workspace: Workspace) -> String? {
        guard let openPath = workspace.windows
            .compactMap(\.openPath)
            .map({ $0.trimmingCharacters(in: .whitespacesAndNewlines) })
            .first(where: { !$0.isEmpty })
        else {
            return nil
        }
        return URL(fileURLWithPath: openPath).standardizedFileURL.path
    }

    private static func isWorkspaceLessRecent(_ lhs: Workspace, _ rhs: Workspace) -> Bool {
        let lhsDate = lhs.lastActivatedAt ?? lhs.createdAt
        let rhsDate = rhs.lastActivatedAt ?? rhs.createdAt
        if lhsDate != rhsDate {
            return lhsDate < rhsDate
        }

        let lhsUpdated = lhs.updatedAt ?? lhs.createdAt
        let rhsUpdated = rhs.updatedAt ?? rhs.createdAt
        if lhsUpdated != rhsUpdated {
            return lhsUpdated < rhsUpdated
        }

        return lhs.id.uuidString < rhs.id.uuidString
    }

    private static func focusOrOpenQuickSwitchURLAfterRestore(
        _ urlString: String,
        workspace: Workspace,
        forceNewChromeWindow: Bool = false,
        preferredScreenIndex: Int? = nil
    ) {
        if forceNewChromeWindow {
            let centeredFrame = centeredForceChromeFrame(for: preferredScreenIndex ?? 0)
            let handled = ChromeAutomationService.openURLInNewWindow(
                urlString,
                centeredBounds: centeredFrame
            )
            guard !handled, let fallbackURL = URL(string: urlString) else {
                return
            }
            NSWorkspace.shared.open(fallbackURL)
            return
        }

        let preferredChromeWindowIDs = workspace.windows
            .filter { BundleRegistry.isChrome($0.bundleIdentifier) }
            .compactMap { $0.chromeState?.chromeWindowId }
        let handled = ChromeAutomationService.focusOrOpenURL(
            urlString,
            preferredChromeWindowIds: preferredChromeWindowIDs
        )
        guard !handled, let fallbackURL = URL(string: urlString) else {
            return
        }
        NSWorkspace.shared.open(fallbackURL)
    }

    private static func forceChromePreferredScreenIndex(in workspace: Workspace) -> Int {
        workspace.windows.compactMap(\.screenIndex).first ?? 0
    }

    private static func centeredForceChromeFrame(for screenIndex: Int) -> CGRect? {
        URLHandoffScreenGeometry.centeredForceChromeFrame(
            for: screenIndex,
            screens: NSScreen.screens.map(FullScreenInfo.init(screen:))
        )
    }

    /// Whether the hidden defaults flag enabling bento://restore in Release builds
    /// is set. DEBUG builds always handle it.
    static var allowsAppRestoreURL: Bool {
        #if DEBUG
        return true
        #else
        return UserDefaults.standard.bool(forKey: BundleIdentity.allowAppRestoreURLKey)
        #endif
    }

    /// Runs an in-app restore loop for bento://restore / bento://test-restore
    /// (triggered by `bentoctl app restore`). Accepts `workspace` (repeatable) /
    /// `workspaces` (CSV), `iterations`, `sleepMs`, and `output` (JSON report path)
    /// query parameters.
    @MainActor
    private func runGUIRestoreParity(url: URL) async {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            DeskJigLog.error(.app, "GUI parity restore URL invalid", fields: ["url": url.absoluteString])
            return
        }

        let queryItems = components.queryItems ?? []
        let workspaceNames = parseWorkspaceNames(from: queryItems)
        guard !workspaceNames.isEmpty else {
            DeskJigLog.error(.app, "GUI parity restore URL missing workspace parameter")
            return
        }

        let iterations = max(1, Int(valueForQueryItem("iterations", in: queryItems) ?? "") ?? 1)
        let sleepMs = max(0, Int(valueForQueryItem("sleepMs", in: queryItems) ?? "") ?? 350)
        let outputPath = valueForQueryItem("output", in: queryItems)

        DeskJigLog.info(.app, "GUI parity restore requested", fields: ["workspaces": workspaceNames.joined(separator: ","), "iterations": iterations, "sleepMs": sleepMs, "output": outputPath ?? "default"])

        let guiRestoreParityRunner = GUIRestoreParityRunner()
        await guiRestoreParityRunner.run(
            workspaceNames: workspaceNames,
            iterations: iterations,
            sleepMs: sleepMs,
            outputPath: outputPath,
            windowManager: windowManager
        )
    }

    private func parseWorkspaceNames(from queryItems: [URLQueryItem]) -> [String] {
        var names: [String] = []

        let repeated = queryItems
            .filter { $0.name == "workspace" }
            .compactMap(\.value)
            .flatMap { item in
                item
                    .split(separator: ",")
                    .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            }
            .filter { !$0.isEmpty }
        names.append(contentsOf: repeated)

        if let csv = valueForQueryItem("workspaces", in: queryItems) {
            let csvNames = csv
                .split(separator: ",")
                .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            names.append(contentsOf: csvNames)
        }

        var unique: [String] = []
        var seen = Set<String>()
        for name in names where !seen.contains(name) {
            seen.insert(name)
            unique.append(name)
        }
        return unique
    }

    private func valueForQueryItem(_ name: String, in queryItems: [URLQueryItem]) -> String? {
        queryItems.first(where: { $0.name == name })?.value
    }
}
