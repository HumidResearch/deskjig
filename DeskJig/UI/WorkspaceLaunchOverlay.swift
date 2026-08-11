//  WorkspaceLaunchOverlay.swift
//  DeskJig
//
//  Created by Jake Sax on 10/6/25.
//


import SwiftUI
import DeskJigShared

/// A full-screen overlay window that displays launch progress for workspaces.
final class WorkspaceLaunchOverlay: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
    
    /// An internal state that enables using SwiftUI transitions for window content
    private let state = WindowContentState()
    private let workspaceName: String
    /// Additional overlay windows for secondary displays
    private var extraWindows: [NSWindow] = []
    /// The duration for the transition of the window's content when displaying.
    fileprivate static let animationDuration: TimeInterval = 0.3
    /// Optional watchdog to auto-dismiss if the launch hangs.
    private var autoDismissTask: Task<Void, Never>?
    private let autoDismissInterval: Duration?
    private var dismissTask: Task<Void, Error>?
    private let onCancel: () -> Void
    /// Callback invoked when user confirms screen mappings in selection phase
    private let onMappingsSelected: (([ScreenMappingInfo]) -> Void)?
    /// Application manager for icon loading in screen selection
    private let applicationManager: ApplicationManager

    private static func displayID(for screen: NSScreen?) -> Int? {
        guard let screen,
              let displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else {
            return nil
        }
        return Int(displayID)
    }

    /// Creates a new launch overlay window for each screen.
    ///
    /// - Parameters:
    ///   - workspace: The name of the workspace being launched.
    ///   - cancelWorkspaceLaunch: Callback when user cancels the launch.
    ///   - autoDismissInterval: Optional auto-dismiss timeout.
    ///   - initialPhase: Initial phase for the overlay (default: .loading).
    ///   - onMappingsSelected: Callback when user confirms screen mappings (required for screenSelection phase).
    ///   - applicationManager: Application manager for icon loading in screen selection.
    init(
        workspace: String,
        cancelWorkspaceLaunch: @escaping () -> Void,
        autoDismissInterval: Duration? = nil,
        initialPhase: LaunchPhase = .loading,
        onMappingsSelected: (([ScreenMappingInfo]) -> Void)? = nil,
        applicationManager: ApplicationManager = ApplicationManager()
    ) {
        // Determine the primary screen and set this window to that screen's frame
        let screens = NSScreen.screens
        let primaryScreen = NSScreen.main ?? screens.first
        let primaryFrame = primaryScreen?.frame ?? screens.first?.frame ?? .zero

        self.autoDismissInterval = autoDismissInterval
        self.onCancel = cancelWorkspaceLaunch
        self.workspaceName = workspace
        self.onMappingsSelected = onMappingsSelected
        self.applicationManager = applicationManager

        super.init(
            contentRect: primaryFrame,
            styleMask: [.borderless, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        // Set initial phase
        self.state.phase = initialPhase
        if case .screenSelection(let analysis, _) = initialPhase {
            self.state.screenSelectionState = InlineScreenSelectionState(analysis: analysis)
        }

        let overlayView = LaunchOverlayView(
            workspace: workspace,
            state: state,
            presentedDisplayID: Self.displayID(for: primaryScreen),
            applicationManager: applicationManager,
            cancelWorkspaceLaunch: {
                cancelWorkspaceLaunch()
                self.dismiss()
            },
            onMappingsSelected: { [weak self] mappings in
                self?.setPhase(.restoring)
                onMappingsSelected?(mappings)
            }
        )
        self.configureAsLaunchOverlay(content: overlayView)

        // Create additional windows for all other screens
        if let primaryScreen {
            for screen in screens where screen !== primaryScreen {
                let window = NSWindow(
                    contentRect: screen.frame,
                    styleMask: [.borderless, .fullSizeContentView],
                    backing: .buffered,
                    defer: false
                )
                let windowOverlayView = LaunchOverlayView(
                    workspace: workspace,
                    state: state,
                    presentedDisplayID: Self.displayID(for: screen),
                    applicationManager: applicationManager,
                    cancelWorkspaceLaunch: {
                        cancelWorkspaceLaunch()
                        self.dismiss()
                    },
                    onMappingsSelected: { [weak self] mappings in
                        self?.setPhase(.restoring)
                        onMappingsSelected?(mappings)
                    }
                )
                window.configureAsLaunchOverlay(content: windowOverlayView)
                self.extraWindows.append(window)
            }
        }
    }
    
    /// Displays the overlay window, letting the View perform a presentation animation.
    func show() {
        DeskJigLog.debug(.workspace, "WorkspaceLaunchOverlay: show", fields: ["workspace": workspaceName])
        dismissTask?.cancel()
        dismissTask = nil
        self.state.isPresented = true
        presentWindows(for: state.phase, reason: "show")
        startAutoDismissWatchdog()
    }
    
    /// Dismisses the overlay window, letting the View perform a dismiss animation.
    ///
    /// - Parameter completion: Called after the window is closed.
    func dismiss() {
        guard state.isPresented else {
            return
        }
        DeskJigLog.debug(.workspace, "WorkspaceLaunchOverlay: dismiss requested", fields: ["workspace": workspaceName])
        state.isPresented = false
        autoDismissTask?.cancel()
        autoDismissTask = nil

        // Wait for SwiftUI transition to complete
        dismissTask?.cancel()
        dismissTask = MainActor.async(after: .seconds(WorkspaceLaunchOverlay.animationDuration + 0.2), checksCancellation: false) {
            self.orderOut(nil)
            for window in self.extraWindows {
                window.orderOut(nil)
            }
            DeskJigLog.debug(.workspace, "WorkspaceLaunchOverlay: dismissed", fields: ["workspace": self.workspaceName])
            self.dismissTask = nil
        }
    }
    
    @Observable
    final class WindowContentState {
        var isPresented: Bool = false
        var phase: LaunchPhase = .loading
        var screenSelectionState: InlineScreenSelectionState?
    }

    /// Represents the current phase of the workspace launch overlay
    enum LaunchPhase: Equatable {
        /// Standard loading indicator while restoring
        case loading
        /// Prompting user to select screen mappings due to monitor mismatch
        case screenSelection(ScreenMismatchAnalysis, Workspace)
        /// Restoring after user confirmed screen selection
        case restoring

        static func == (lhs: LaunchPhase, rhs: LaunchPhase) -> Bool {
            switch (lhs, rhs) {
            case (.loading, .loading), (.restoring, .restoring):
                return true
            case (.screenSelection(let lhsAnalysis, _), .screenSelection(let rhsAnalysis, _)):
                return lhsAnalysis.savedScreenCount == rhsAnalysis.savedScreenCount
                    && lhsAnalysis.currentScreenCount == rhsAnalysis.currentScreenCount
            default:
                return false
            }
        }
    }

    /// Transition from screen selection phase to restoring phase
    func transitionToRestoring() {
        setPhase(.restoring)
    }

    /// Reset the watchdog timer. Call this when progress is received
    /// to prevent premature auto-dismiss during long operations.
    func resetWatchdog() {
        guard autoDismissInterval != nil else { return }
        DeskJigLog.debug(.workspace, "WorkspaceLaunchOverlay: Watchdog reset (progress received)")
        autoDismissTask?.cancel()
        autoDismissTask = nil
        startAutoDismissWatchdog()
    }
}

// MARK: - Watchdog
private extension WorkspaceLaunchOverlay {
    func setPhase(_ phase: LaunchPhase) {
        state.phase = phase
        switch phase {
        case .screenSelection(let analysis, _):
            state.screenSelectionState = InlineScreenSelectionState(analysis: analysis)
        case .loading, .restoring:
            state.screenSelectionState = nil
        }
        guard state.isPresented else { return }
        presentWindows(for: phase, reason: "phase-change")
    }

    func presentWindows(for phase: LaunchPhase, reason: String) {
        switch phase {
        case .screenSelection:
            DeskJigLog.debug(.workspace, "WorkspaceLaunchOverlay: interactive key mode", fields: ["reason": reason, "workspace": workspaceName])
            NSApp.activate(ignoringOtherApps: true)
            makeKeyAndOrderFront(nil)
            if let contentView {
                makeFirstResponder(contentView)
            }
        case .loading, .restoring:
            // During restore execution we intentionally avoid forcing key focus
            // so launched apps can become active naturally.
            orderFrontRegardless()
        }

        for window in extraWindows {
            window.orderFrontRegardless()
        }
    }

    func startAutoDismissWatchdog() {
        guard let autoDismissInterval else { return }
        // Avoid multiple timers if show() is called twice.
        guard autoDismissTask == nil else { return }

        autoDismissTask = Task { [weak self] in
            guard let self = self else { return }
            // Sleep on a background priority task to avoid blocking UI.
            await Task.sleepUnlessCancelled(for: autoDismissInterval)
            if Task.isCancelled { return }

            await MainActor.run {
                // If still visible, cancel the launch and dismiss.
                guard self.state.isPresented else { return }
                self.onCancel()
                self.dismiss()
            }
        }
    }
}

private extension NSWindow {
    func configureAsLaunchOverlay<T: View>(content: T) {
        isOpaque = false
        backgroundColor = .clear
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        ignoresMouseEvents = false
        
        contentView = NSHostingView(rootView: content)
        // Configure layer for blur effects
        contentView?.wantsLayer = true
        contentView?.layer?.masksToBounds = false  // Important for blur
        contentView?.layer?.backgroundColor = NSColor.clear.cgColor
        contentView?.layerContentsRedrawPolicy = .duringViewResize
        hasShadow = false
        animationBehavior = .none
    }
}

extension WorkspaceLaunchOverlay {
    /// The visual content for the launch overlay.
    struct LaunchOverlayView: View {
        /// The name of the workspace being launched.
        let workspace: String
        let state: WindowContentState
        let presentedDisplayID: Int?
        let applicationManager: ApplicationManager
        let cancelWorkspaceLaunch: () -> Void
        let onMappingsSelected: (([ScreenMappingInfo]) -> Void)?
        @FocusState private var isFocused: Bool

        init(
            workspace: String,
            state: WindowContentState,
            presentedDisplayID: Int? = nil,
            applicationManager: ApplicationManager = ApplicationManager(),
            cancelWorkspaceLaunch: @escaping () -> Void,
            onMappingsSelected: (([ScreenMappingInfo]) -> Void)? = nil
        ) {
            self.workspace = workspace
            self.state = state
            self.presentedDisplayID = presentedDisplayID
            self.applicationManager = applicationManager
            self.cancelWorkspaceLaunch = cancelWorkspaceLaunch
            self.onMappingsSelected = onMappingsSelected
        }

        var body: some View {
            ZStack {
                if state.isPresented {
                    Rectangle()
                        .fill(.ultraThinMaterial)
                        .opacity(0.75)
                        .ignoresSafeArea()
                        .transition(
                            .blurReplace(.upUp)
                            .animation(
                                .smooth(duration: WorkspaceLaunchOverlay.animationDuration)
                            )
                        )
                }
                if state.isPresented {
                    phaseContent
                        .transition(
                            .blurTransition(blurRadius: 4, scale: 0.96, reversesOnExit: true)
                                .animation(
                                    .smooth(duration: WorkspaceLaunchOverlay.animationDuration).speed(1.2)
                                )
                        )
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .focusable()
            .focused($isFocused)
            .onKeyPress(.leftArrow, phases: [.down, .repeat]) { _ in
                guard case .screenSelection = state.phase else { return .ignored }
                NotificationCenter.default.post(name: .inlineScreenSelectionMoveLeft, object: nil)
                return .handled
            }
            .onKeyPress(.rightArrow, phases: [.down, .repeat]) { _ in
                guard case .screenSelection = state.phase else { return .ignored }
                NotificationCenter.default.post(name: .inlineScreenSelectionMoveRight, object: nil)
                return .handled
            }
            .onKeyPress(.return, phases: .down) { _ in
                guard case .screenSelection = state.phase else { return .ignored }
                NotificationCenter.default.post(name: .inlineScreenSelectionConfirm, object: nil)
                return .handled
            }
            .onKeyPress(.escape) {
                cancelWorkspaceLaunch()
                return .handled
            }
            .onAppear {
                MainActor.async {
                    isFocused = true
                }
            }
        }

        @ViewBuilder
        private var phaseContent: some View {
            switch state.phase {
            case .loading, .restoring:
                loadingContent

            case .screenSelection(let analysis, let workspaceData):
                if let selectionState = state.screenSelectionState {
                    let presentedCurrentScreenIndex = presentedDisplayID.flatMap { displayID in
                        analysis.currentScreens.firstIndex(where: { $0.displayID == displayID })
                    }
                    InlineScreenSelectionView(
                        workspaceName: workspace,
                        workspace: workspaceData,
                        analysis: analysis,
                        selectionState: selectionState,
                        presentedCurrentScreenIndex: presentedCurrentScreenIndex,
                        applicationManager: applicationManager,
                        onConfirm: { mappings in
                            onMappingsSelected?(mappings)
                        },
                        onCancel: cancelWorkspaceLaunch
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                }
            }
        }

        private var loadingContent: some View {
            VStack(spacing: 64) {
                DeskJigLoadingIndicator(size: 100)

                Text(workspace)
                    .font(brand: Font.brandHeading(size: Double(48)))
                    .foregroundStyle(DesignTokens.Text.primary)

                Button(action: cancelWorkspaceLaunch) {
                    Text("Cancel")
                        .font(brand: .h5)
                        .foregroundStyle(DesignTokens.Text.primary)
                        .padding(12)
                        .padding(.horizontal, 8)
                        .background {
                            Capsule()
                                .fill(.thickMaterial)
                        }
                }
                .buttonStyle(.plain)
            }
        }
    }
}

// MARK: - Preview
#Preview("Launch Overlay - Loading") {
    @Previewable @State var state: WorkspaceLaunchOverlay.WindowContentState = .init()
    WorkspaceLaunchOverlay.LaunchOverlayView(
        workspace: "Development Setup",
        state: state,
        cancelWorkspaceLaunch: { DeskJigLog.debug(.workspace, "WorkspaceLaunchOverlay: cancel workspace launch") }
    )
    .frame(width: 800, height: 600)
    .onAppear { state.isPresented = true }
}

#Preview("Launch Overlay - Screen Selection") {
    @Previewable @State var state: WorkspaceLaunchOverlay.WindowContentState = {
        let s = WorkspaceLaunchOverlay.WindowContentState()
        let mockWorkspace = Workspace(name: "Development Setup", workspaceWindows: [])
        s.phase = .screenSelection(ScreenMismatchAnalysis(
            savedScreenCount: 3,
            currentScreenCount: 1,
            savedScreens: [],
            currentScreens: [],
            suggestedMappings: []
        ), mockWorkspace)
        return s
    }()
    WorkspaceLaunchOverlay.LaunchOverlayView(
        workspace: "Development Setup",
        state: state,
        cancelWorkspaceLaunch: { DeskJigLog.debug(.workspace, "WorkspaceLaunchOverlay: cancel workspace launch") },
        onMappingsSelected: { mappings in
            DeskJigLog.debug(.workspace, "WorkspaceLaunchOverlay: mappings selected", fields: ["count": mappings.count])
        }
    )
    .frame(width: 1000, height: 800)
    .onAppear { state.isPresented = true }
}
