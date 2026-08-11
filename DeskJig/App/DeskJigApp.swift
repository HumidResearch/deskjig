//
//  DeskJigApp.swift
//  DeskJig
//

import SwiftUI
import DeskJigShared
import CocoaLumberjackSwift
import Combine

@main
struct DeskJigApp: App {

    // MARK: Data
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var appUpdateController: SparkleController
    @StateObject private var windowManager: WindowManager
    @State private var workspaceVM: WorkspaceViewModel
    @State private var actionPanelManager: ActionPanelManager
    @StateObject private var overlayWindowManager: OverlayWindowManager
    @StateObject private var navigationManager: NavigationManager
    @State private var simpleOnboardingVM: SimpleOnboardingViewModel = .init()

    @State private var notificationWindowManager: NotificationWindowManager? = nil

    // MARK: UI
    @State private var mainWindow: NSPanel? = nil
    static let mainWindowTitle: String = "DeskJig"
    static let mainWindowID: String = "main-window"
    /// A publisher for the visibility of the main settings window. Should only be published to via
    /// `AppDelegate`'s `setMainWindowIsVisible()` method.
    static let mainWindowVisibilityPublisher = PassthroughSubject<(wasVisible: Bool, isVisible: Bool), Never>()

    /// True when this process is the XCTest host for the `DeskJigTests` bundle.
    ///
    /// The app-hosted test target launches DeskJig itself, so anything that
    /// claims a system-wide singleton (menu-bar item, floating action panel) or
    /// reaches the network (the Sparkle update probe) must stay dormant — see
    /// the matching bail-out in `AppDelegate.applicationDidFinishLaunching`.
    static let isTestHost = RuntimeEnvironment.isRunningTests()

    // MARK: Initialization
    init() {
        // Set up logging FIRST so everything below is captured.
        Self.setupLogging()

        // Detect a second DeskJig instance (dual-bundle LaunchServices routing,
        // #565) before any startup work claims shared resources. No-op in tests.
        SingleInstanceGuard.detectPrimaryInstance()

        let navManager = NavigationManager()
        let windowManager = WindowManager()
        let overlayManager = OverlayWindowManager()
        let sparkleController = SparkleController()
        let workspaceVM = WorkspaceViewModel(
            navigationManager: navManager,
            windowManager: windowManager,
            overlayWindowManager: overlayManager
        )
        self._navigationManager = StateObject(wrappedValue: navManager)
        self._windowManager = StateObject(wrappedValue: windowManager)
        self._workspaceVM = State(wrappedValue: workspaceVM)
        self._overlayWindowManager = StateObject(wrappedValue: overlayManager)
        self._appUpdateController = StateObject(wrappedValue: sparkleController)

        // Every install is fully licensed, so `ActionPanelManager` no longer
        // carries an `isDisabled` gate at all (it existed only for the
        // subscription-validation wall) — there is nothing left to pass.
        let actionPanel = ActionPanelManager(workspaceVM: workspaceVM)
        self.actionPanelManager = actionPanel
        self.appDelegate.actionPanelManager = actionPanel
        if !SingleInstanceGuard.isSecondaryInstance && !Self.isTestHost {
            actionPanel.presentPanel()
        }
        actionPanel.openSettingsAction = { [weak appDelegate] in
            DeskJigLog.info(.app, "[ActionPanel] openSettingsAction dispatching main window + settings section")
            appDelegate?.setMainWindowIsVisible(true)
            UserDefaults.standard.set(SettingsSidebarSection.settings.rawValue, forKey: "settings.selectedSection")
            DispatchQueue.main.async {
                DeskJigContentView.sectionPublisher.send(.settings)
            }
        }
        actionPanel.openWorkspacesAction = { [weak appDelegate, weak workspaceVM] action in
            appDelegate?.setMainWindowIsVisible(true)
            UserDefaults.standard.set(SettingsSidebarSection.allWorkspaces.rawValue, forKey: "settings.selectedSection")
            DispatchQueue.main.async {
                DeskJigContentView.sectionPublisher.send(.allWorkspaces)
                workspaceVM?.pendingSettingsWorkspaceAction = action
            }
        }

        if !SingleInstanceGuard.isSecondaryInstance && !Self.isTestHost {
            Task { @MainActor in
                sparkleController.probeForUpdates(trigger: .appLaunch)
            }
        }

        if let screen = NSScreen.main {
            self._notificationWindowManager = State(
                wrappedValue: NotificationWindowManager(screen: screen)
            )
            DeskJigLog.info(.app, "Created NotificationWindowManager")
        } else {
            DeskJigLog.error(.app, "No screen available to create NotificationWindowManager")
        }

        windowManager.onWindowRestorationFailure = { window, customMessage in
            if let customMessage {
                // Custom message (e.g., hidden space error) - use title + detailed text
                NotificationPresenter.present(
                    .init(
                        "Workspace Restoration",
                        text: customMessage,
                        icon: "exclamationmark.triangle.fill"
                    ),
                    for: .seconds(8)  // Longer duration for important messages
                )
            } else {
                // Default failure message
                NotificationPresenter.present(
                    .init("\(window.appName) failed to restore, please try again.")
                )
            }
        }

        // Pass references to AppDelegate
        appDelegate.windowManager = windowManager
        appDelegate.simpleOnboardingVM = simpleOnboardingVM
        appDelegate.workspaceViewModel = workspaceVM
        workspaceVM.setAppDelegate(appDelegate)

        DeskJigLog.info(.app, "[DeskJigApp.init]", fields: ["secondaryInstance": SingleInstanceGuard.isSecondaryInstance])
    }

    var body: some Scene {
        // isInserted: a secondary instance (#565) never shows a second menu bar
        // icon and never runs onFirstLoad — it only forwards URLs and exits.
        // Neither does the app-hosted test host, which must not plant a
        // menu-bar item next to a real install's.
        MenuBarExtra(
            "Window Monitor",
            systemImage: "macwindow.badge.plus",
            isInserted: .constant(!SingleInstanceGuard.isSecondaryInstance && !Self.isTestHost)
        ) {
            MenuBarView()
                .environment(appDelegate)
                .environmentObject(windowManager)
                .environmentObject(appUpdateController)
                .onLoad {
                    onFirstLoad()
                }
                .onReceive(Self.mainWindowVisibilityPublisher) { output in
                    if output.wasVisible != output.isVisible {
                        DeskJigLog.info(.app, "Handling main window presentation")
                        handleMainWindowPresentation()
                    } else if output.isVisible {
                        DeskJigLog.info(.app, "Focusing main window")
                        presentMainWindow()
                    }
                }
                // NOTE: Deep links are handled by AppDelegate.handleIncomingURL()
                // Using .onOpenURL with @NSApplicationDelegateAdaptor causes
                // "Cannot use Scene methods for URL" warnings
        }
        .menuBarExtraStyle(.menu)
    }
}

// MARK: Methods
private extension DeskJigApp {
    func onFirstLoad() {
        DeskJigLog.info(.app, "[onFirstLoad] Fired", fields: ["didPerformEarlyStartup": appDelegate.didPerformEarlyStartup])

        actionPanelManager.openSettingsAction = {
            DeskJigLog.info(.app, "[ActionPanel] openSettingsAction dispatching main window + settings section")
            appDelegate.setMainWindowIsVisible(true)
            UserDefaults.standard.set(SettingsSidebarSection.settings.rawValue, forKey: "settings.selectedSection")
            DispatchQueue.main.async {
                DeskJigContentView.sectionPublisher.send(.settings)
            }
        }
        actionPanelManager.openWorkspacesAction = { [weak workspaceVM, weak appDelegate] action in
            appDelegate?.setMainWindowIsVisible(true)
            UserDefaults.standard.set(SettingsSidebarSection.allWorkspaces.rawValue, forKey: "settings.selectedSection")
            DispatchQueue.main.async {
                DeskJigContentView.sectionPublisher.send(.allWorkspaces)
                workspaceVM?.pendingSettingsWorkspaceAction = action
            }
        }

        // Workspaces live in local storage, so startup is unconditional: load
        // them and refresh the dock. `applicationDidFinishLaunching` normally
        // wins this race (it fires reliably on every launch, whereas
        // MenuBarExtra's .onLoad can be delayed 30-50s+ on rapid restarts), so
        // only do the work here when it did not already run.
        if appDelegate.didPerformEarlyStartup {
            DeskJigLog.info(.app, "[onFirstLoad] Early startup already ran — skipping workspace load (already handled)")
        } else {
            DeskJigLog.info(.app, "[onFirstLoad] Early startup did NOT run — loading workspaces here")
            windowManager.reloadWorkspaces()
            actionPanelManager.forceRefreshDynamicContent()
        }

        #if DEBUG
        // Optional debug-only override for auto-opening the main window.
        // Keep disabled by default so it does not interfere with action panel interaction.
        if ProcessInfo.processInfo.environment["BENTO_DEBUG_AUTO_OPEN_MAIN_WINDOW"] == "1" {
            DeskJigLog.info(.app, "DEBUG: Auto-opening settings window (BENTO_DEBUG_AUTO_OPEN_MAIN_WINDOW=1)")
            presentMainWindow()
        }
        #endif
    }

    func handleMainWindowPresentation() {
        if appDelegate.isWindowVisible {
            presentMainWindow()
        } else {
            hideMainWindow()
        }
    }

    func presentMainWindow() {
        DeskJigLog.info(.app, "Presenting main window")
        let window = mainWindow ?? makeMainWindow()
        window.center()
        NSApp.activate(ignoringOtherApps: true)
        window.orderFrontRegardless()
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)
    }

    func hideMainWindow() {
        DeskJigLog.info(.app, "Hiding main window")
        mainWindow?.orderOut(nil)
    }

    func makeMainWindow() -> NSPanel {
        let panel = NSPanel(
            contentRect: .init(origin: .zero, size: MainWindowContent.size),
            styleMask: [
                .titled,               // Provides the title bar area
                .closable,             // Close button
                .miniaturizable,       // Minimize button
                .fullSizeContentView   // Content extends under title bar - KEY for hidden titlebar look
            ],
            backing: .buffered,
            defer: false
        )
        panel.title = Self.mainWindowTitle
        panel.identifier = .init(Self.mainWindowID)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        panel.titlebarAppearsTransparent = true
        panel.titleVisibility = .hidden
        panel.isMovableByWindowBackground = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hidesOnDeactivate = false

        panel.collectionBehavior = [
            .canJoinAllSpaces,        // Appears on all desktops
            .fullScreenAuxiliary      // Can appear over full-screen apps
        ]
        panel.contentView = NSHostingView(
            rootView: MainWindowContent(
                appDelegate: appDelegate,
                appUpdateController: appUpdateController,
                windowManager: windowManager,
                workspaceVM: workspaceVM,
                overlayWindowManager: overlayWindowManager,
                navigationManager: navigationManager,
                simpleOnboardingVM: simpleOnboardingVM
            )
        )
        self.mainWindow = panel
        return panel
    }
}

private extension DeskJigApp {
    static func setupLogging() {
        LoggingController.shared.configure()
        let isRunningTests = RuntimeEnvironment.isRunningTests()

        // Add console logger for development with central filter
        let consoleLogger = DDOSLogger.sharedInstance
        consoleLogger.logFormatter = LoggingController.shared.formatter(
            for: .console
        )
        DDLog.add(consoleLogger)

        // Add file logger with custom path support
        let logDirectory = resolveLogDirectory()
        let fileManager = DDLogFileManagerDefault(logsDirectory: logDirectory.path)
        let fileLogger = DDFileLogger(logFileManager: fileManager)
        fileLogger.rollingFrequency = 60 * 60 * 24 // 24 hours
        fileLogger.logFileManager.maximumNumberOfLogFiles = 7
        fileLogger.logFormatter = LoggingController.shared.formatter(
            for: .file
        )
        DDLog.add(fileLogger)

        // Set default log level
#if DEBUG
        dynamicLogLevel = DDLogLevel.verbose
#else
        dynamicLogLevel = DDLogLevel.info
#endif

        if isRunningTests {
            DeskJigLog.info(.app, "Logging system initialized (TEST MODE)")
        } else {
            DeskJigLog.info(.app, "Logging system initialized")
        }
    }

    static func resolveLogDirectory() -> URL {
        let fm = FileManager.default
        let defaultBase = BundleIdentity.logDirectoryURL

        // 1. Check BENTO_LOG_PATH environment variable
        if let customPath = ProcessInfo.processInfo.environment["BENTO_LOG_PATH"],
           !customPath.trimmingCharacters(in: .whitespaces).isEmpty {
            let url = URL(fileURLWithPath: customPath)
            try? fm.createDirectory(at: url, withIntermediateDirectories: true)
            return url
        }

        // 2. Auto-detect worktree
        if let worktreeName = detectWorktreeName() {
            return defaultBase.appendingPathComponent("worktrees/\(worktreeName)")
        }

        // 3. Default
        return defaultBase
    }

    private static func detectWorktreeName() -> String? {
        let fm = FileManager.default
        let gitPath = fm.currentDirectoryPath + "/.git"

        // Worktrees have a .git FILE (not directory) containing path to main repo
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: gitPath, isDirectory: &isDirectory),
              !isDirectory.boolValue else {
            return nil
        }

        // Extract worktree name from current directory
        return URL(fileURLWithPath: fm.currentDirectoryPath).lastPathComponent
    }
}

// MARK: Supporting Views
private extension DeskJigApp {

    struct MainWindowContent: View {

        let appDelegate: AppDelegate
        @ObservedObject var appUpdateController: SparkleController
        @ObservedObject var windowManager: WindowManager
        @Bindable var workspaceVM: WorkspaceViewModel
        @ObservedObject var overlayWindowManager: OverlayWindowManager
        @ObservedObject var navigationManager: NavigationManager
        @Bindable var simpleOnboardingVM: SimpleOnboardingViewModel

        #if DEBUG
        @State private var showingSplash = false  // Skip splash animation in debug builds
        #else
        @State private var showingSplash = true
        #endif
        @State private var tutorialVM: OnboardingTutorialViewModel = .init()
        #if DEBUG
        @AppStorage("appearance.theme") private var appTheme: AppTheme = .dark
        #endif

        static let size: NSSize = .init(width: 1200, height: 800)

        private var shouldShowSolidWindowBackground: Bool {
            windowManager.shouldShowPermissionsScreen
        }

        @ViewBuilder
        private var windowBackground: some View {
            if shouldShowSolidWindowBackground {
                DesignTokens.Surface.window
            } else {
                AppBackground()
            }
        }

        var body: some View {
            VStack {
                if windowManager.shouldShowPermissionsScreen {
                    PermissionsView()
                        .transition(.animatedBlur)
                } else {
                    DeskJigContentView(simpleOnboardingVM: simpleOnboardingVM, tutorialVM: tutorialVM)
                        .transition(.animatedBlur)
                }
            }
            .overlay {
                if showingSplash {
                    LottieSplashView {
                        showingSplash = false
                    }
                    .transition(.opacity)
                }
            }
            .background(windowBackground)
            #if DEBUG
            .preferredColorScheme(appTheme.preferredColorScheme)
            #else
            .preferredColorScheme(.dark)
            #endif
            .frame(width: Self.size.width, height: Self.size.height)
            .environment(appDelegate)
            .environment(workspaceVM)
            .environmentObject(windowManager)
            .environmentObject(overlayWindowManager)
            .environmentObject(appUpdateController)
            // Safety: auto-dismiss splash after 10 seconds to avoid UI lock if init hangs
            .task {
                guard await Task.sleepUnlessCancelled(for: .seconds(10)) else { return }
                if showingSplash {
                    showingSplash = false
                }
            }
        }
    }

}
