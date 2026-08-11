//  ActionPanelManager.swift
//  DeskJig
//  Created by Jake Sax on 10/20/25.


import SwiftUI
import AppKit
import DeskJigShared
import KeyboardShortcuts

@Observable @MainActor
final class ActionPanelManager {
    
    // MARK: - Dependencies
    private(set) var workspaceVM: WorkspaceViewModel
    private let dispatcher: MenuActionDispatcher
    
    // MARK: - Workspace Editor Panel
    private(set) var workspaceEditorPanel: WorkspaceEditorPanelManager?
    
    /// The openSettings action from SwiftUI environment, set by ActionPanelContent
    var openSettingsAction: (() -> Void)?
    /// Opens the main settings window to the workspaces section with a specific action.
    var openWorkspacesAction: ((WorkspaceViewModel.SettingsWorkspaceAction) -> Void)?

    // MARK: - Configuration
    private(set) var configuration: MenuConfiguration

    // MARK: - Properties
    /// Whether the panel window is expanded or compact.
    private(set) var isExpanded: Bool = false {
        didSet {
            // Enable/disable topmost window highlight when panel expands/collapses
//            workspaceVM.overlayWindowManager.isTopmostWindowHighlightEnabled = isExpanded

            // Handle visibility-based overlays based on expansion state
            if isExpanded {
                // Only enable overlays on expansion if the auto-enable setting is turned on
                if workspaceVM.overlayWindowManager.shouldAutoEnableVisibilityOverlays {
                    workspaceVM.overlayWindowManager.isVisibilityBasedOverlaysEnabled = true
                    DeskJigLog.info(.app, "ActionPanel expanded - enabling visibility overlays")
                } else {
                    DeskJigLog.info(.app, "ActionPanel expanded but auto-enable visibility overlays is disabled")
                }

                // Start the auto-close timer when panel expands
                startMouseExitTimer()
            } else {
                // Always disable overlays on contraction, regardless of settings
                // This ensures overlays are cleaned up when the panel closes
                if workspaceVM.overlayWindowManager.isVisibilityBasedOverlaysEnabled {
                    workspaceVM.overlayWindowManager.isVisibilityBasedOverlaysEnabled = false
                    DeskJigLog.info(.app, "ActionPanel contracted - disabling visibility overlays")
                }

                // Cancel the auto-close timer when panel collapses
                cancelMouseExitTimer()
            }
        }
    }
    /// The currently selected panel section ID, displaying its sub-actions.
    private(set) var selectedSection: String? = nil
    private(set) var isCollapsing: Bool = false
    
    /// The panel window itself that contains the action panel.
    public private(set) var panel: FloatingPanel

    /// The details for the current active screen, tracked to keep the action panel
    /// pinned to the active screen.
    private var activeScreen: FullScreenInfo? = nil

    /// Combine observation for window changes that move the
    /// action panel to active screen.
    private var windowsObservation: AnyCancellable?
    
    /// Combine observation for workspace changes that update the menu.
    private var workspacesObservation: AnyCancellable?
    private var userDefaultsObservation: AnyCancellable?
    
    /// Delayed task that executes to close the panel after mouse exits
    private var mouseExitTask: Task<Void,Error>?
    
    /// Delayed task that executes to collapse the current submenu after mouse exits
    private var submenuExitTask: Task<Void,Error>?

    /// Global click monitor to keep the panel pinned to the clicked screen.
    @ObservationIgnored
    private var globalMouseDownMonitor: GlobalEventMonitor?
    
    // MARK: - Dynamic Content
    /// Dynamically generated menu items (e.g., workspace list)
    private(set) var dynamicItems: [String: [MenuItem]] = [:]
    private var runtimePresentationVersion: Int = 0

    /// Tracks workspace IDs that already have keyboard shortcut handlers registered.
    /// Prevents duplicate handler registration when `updateDynamicContent()` is called multiple times.
    private var registeredWorkspaceShortcutIds: Set<UUID> = []

    // MARK: Size Constants
    /// The width of the action panel when opened up.
    /// Width is somewhat arbitrary, large enough to not clip any content.
    static let expandedWidth: CGFloat = 1600
    /// Padding applied to the panel from the edges of the screen.
    static let panelPadding: CGFloat = 24
    
    /// Calculates the expanded size for a given screen, using the full visible height
    static func expandedSize(for screen: FullScreenInfo) -> NSSize {
        // Use the visible frame height (which already excludes dock and menu bar)
        // Subtract padding only from the top
        let height = screen.visibleFrame.height - panelPadding
        return NSSize(width: expandedWidth, height: height)
    }

    // MARK: - Initialization
    init(
        workspaceVM: WorkspaceViewModel,
        configurationFile: String = "menu-default"
    ) {
        self.workspaceVM = workspaceVM

        // Load configuration
        var loadedConfig: MenuConfiguration
        do {
            loadedConfig = try MenuConfigurationLoader.loadBundled(filename: configurationFile)
            try MenuConfigurationLoader.validate(loadedConfig)
        } catch {
            DeskJigLog.error(.app, "Failed to load menu configuration, using fallback", fields: ["error": error.localizedDescription])
            // Fallback to minimal configuration
            loadedConfig = MenuConfiguration(
                version: "1.0",
                rootItems: [],
                settings: nil
            )
        }
        self.configuration = loadedConfig

        // Initialize dispatcher
        self.dispatcher = MenuActionDispatcher(
            windowManager: workspaceVM.windowManager,
            workspaceViewModel: workspaceVM
        )

        // Initialize panel with default size (will be updated based on screen)
        self.panel = Self.makeActionPanel()
        
        // Position at bottom right screen corner and size to fit visible area
        if let screen = NSScreen.main {
            let screenInfo = FullScreenInfo(screen: screen)
            activeScreen = screenInfo
            let panelSize = Self.expandedSize(for: screenInfo)
            panel.setFrame(
                NSRect(origin: Self.panelOrigin(inScreen: screenInfo, panelSize: panelSize),
                       size: panelSize),
                display: true
            )
        } else {
            DeskJigLog.error(.app, "No screen available to launch action panel")
        }
        self.isExpanded = false

        // Populate dynamic content
        updateDynamicContent()

        self.panel.contentView = NSHostingView(
            rootView: ActionPanelContent(manager: self)
        )
    
        self.windowsObservation = workspaceVM.windowManager.$windows
            .sink { [weak self] newWindows in
                self?.moveToActiveScreen(in: newWindows)
            }
        
        // Subscribe to workspace changes to automatically update menu
        // Debounce to prevent rapid-fire updates during SnapshotViewer live mode
        self.workspacesObservation = workspaceVM.windowManager.$savedWorkspaces
            .debounce(for: .milliseconds(500), scheduler: DispatchQueue.main)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] workspaces in
                DeskJigLog.info(.app, "Workspaces changed, updating dynamic content", fields: ["count": workspaces.count])
                self?.updateDynamicContent()
            }

        self.userDefaultsObservation = NotificationCenter.default.publisher(
            for: UserDefaults.didChangeNotification
        )
        .receive(on: DispatchQueue.main)
        .sink { [weak self] _ in
            self?.runtimePresentationVersion &+= 1
        }
        
        // Initialize workspace editor panel
        self.workspaceEditorPanel = WorkspaceEditorPanelManager(
            workspaceVM: workspaceVM,
            actionPanelManager: self
        )
        
        // Set the action panel manager reference in the dispatcher
        self.dispatcher.setActionPanelManager(self)

        // Observe workspaceBeingEdited changes to show/hide the editor panel
        setupWorkspaceEditorObserver()

        setupGlobalClickMonitor()
    }
    
    // MARK: - Methods
    func presentPanel() {
        DeskJigLog.info(.app, "Presenting action panel")
        panel.orderFrontRegardless()
        panel.makeKey()
    }

    /// Toggles between compact and expanded states
    func toggleExpansion() {
        DeskJigLog.info(.app, "Action panel toggle requested", fields: ["isExpanded": "\(isExpanded)"])

        // we try to keep all animations within the View, but these
        // sequenced animations are simpler to perform here
        if selectedSection != nil {
            withAnimation(.snappy(duration: 0.20)) {
                selectedSection = nil
            }
            MainActor.async(after: .seconds(0.1)) {
                withAnimation(.bouncy(duration: 0.20, extraBounce: 0.1)) {
                    self.isExpanded.toggle()
                }
            }
        } else {
            withAnimation(.bouncy(duration: 0.25, extraBounce: 0.05)) {
                self.isExpanded.toggle()
            }
        }
    }

    func toggleSection(_ sectionID: String) {
        guard !isCollapsing else {
            return
        }
        selectedSection = (selectedSection == sectionID) ? nil : sectionID
    }
    
    func selectSection(_ sectionID: String) {
        guard !isCollapsing else {
            return
        }
        selectedSection = sectionID
    }

    func deselectAnySection() {
        selectedSection = nil
    }
    
    func collapseToRoot() {
        guard !isCollapsing else {
            return
        }
        isCollapsing = true
        cancelMouseExitTimer()
        deselectAnySection()
        MainActor.async(after: .seconds(0.5)) {
            self.isCollapsing = false
        }
    }
    
    /// Closes the panel completely by collapsing it
    func closePanel() {
        cancelMouseExitTimer()
        if selectedSection != nil {
            withAnimation(.snappy(duration: 0.20)) {
                selectedSection = nil
            }
            MainActor.async(after: .seconds(0.1)) {
                withAnimation(.bouncy(duration: 0.20, extraBounce: 0.1)) {
                    self.isExpanded = false
                }
            }
        } else {
            withAnimation(.bouncy(duration: 0.25, extraBounce: 0.05)) {
                isExpanded = false
            }
        }
    }
    
    // MARK: - Mouse Exit Timer
    
    /// Starts a timer that will close the panel after the configured delay
    func startMouseExitTimer() {
        // Only start timer if panel is expanded
        guard isExpanded else { return }

        // Check if auto-close is enabled
        let isEnabled = UserDefaults.standard.object(forKey: "menuAutoCloseEnabled") as? Bool ?? true
        guard isEnabled else { return }

        // Cancel any existing timer
        cancelMouseExitTimer()

        // Get auto-close delay from UserDefaults first, then configuration file, then default to 5 seconds
        let delay: Double
        if let userDefaultsDelay = UserDefaults.standard.object(forKey: "menuAutoCloseDelaySeconds") as? Double {
            delay = userDefaultsDelay
        } else {
            delay = configuration.settings?.autoCloseDelaySeconds ?? 5.0
        }

        // Create new timer on main thread
        mouseExitTask = MainActor.async(after: .seconds(delay)) { [weak self] in
            self?.closePanel()
        }
    }
    
    /// Cancels the mouse exit timer if it's running
    func cancelMouseExitTimer() {
        mouseExitTask?.cancel()
        mouseExitTask = nil
    }
    
    // MARK: - Submenu Exit Timer
    
    /// Starts a timer that will collapse the current submenu after 1 second
    func startSubmenuExitTimer() {
        // Only start timer if there's a selected section (submenu is open)
        guard selectedSection != nil else { return }
        
        // Cancel any existing timer
        cancelSubmenuExitTimer()
        
        // Create new timer on main thread
        submenuExitTask = MainActor.async(after: .seconds(1)) { [weak self] in
            guard let self else { return }
            // Collapse the submenu (deselect current section)
            self.selectedSection = nil
        }
    }
    
    /// Cancels the submenu exit timer if it's running
    func cancelSubmenuExitTimer() {
        submenuExitTask?.cancel()
        submenuExitTask = nil
    }

    // MARK: - Configuration Management

    /// Updates dynamic menu items based on current app state
    func updateDynamicContent() {
        findDynamicItems(in: configuration.rootItems)
    }

    /// Forces a refresh of dynamic content (workspaces, etc.)
    /// Call this after workspace data changes if automatic updates aren't propagating
    func forceRefreshDynamicContent() {
        DeskJigLog.info(.app, "ActionPanelManager: Force refreshing dynamic content")
        updateDynamicContent()
    }
    
    private func findDynamicItems(in items: [MenuItem]) {
        for item in items {
            if item.type == .dynamic {
                dynamicItems[item.id] = generateDynamicItems(for: item)
            }
            
            if let children = item.children {
                findDynamicItems(in: children)
            }
        }
    }
    
    /// Generates dynamic menu items based on item ID
    private func generateDynamicItems(for item: MenuItem) -> [MenuItem] {
        // Get static children from configuration
        let staticChildren = item.children ?? []

        // Generate dynamic items
        let dynamicChildren: [MenuItem]
        switch item.id {
        case "workspaces", "workspaces.list":
            dynamicChildren = generateWorkspaceItems()
            if !staticChildren.isEmpty {
                let staticTitles = staticChildren.map(\.title).joined(separator: " | ")
                DeskJigLog.trace(.app, "RESTORE-DEBUG: [ActionPanel] workspace static items", fields: ["count": staticChildren.count, "titles": staticTitles])
            } else {
                DeskJigLog.trace(.app, "RESTORE-DEBUG: [ActionPanel] workspace static items=0")
            }
        case "directoryWorkspaces", "directoryWorkspaces.list":
            dynamicChildren = []
        default:
            DeskJigLog.warn(.app, "Unknown dynamic item", fields: ["id": item.id])
            dynamicChildren = []
        }

        // Combine static children first, then dynamic items
        return staticChildren + dynamicChildren
    }
    
    /// Generates menu items for all saved workspaces
    private func generateWorkspaceItems() -> [MenuItem] {
        let workspaces = workspaceVM.windowManager.savedWorkspaces
            .sorted(by: { $0.createdAt > $1.createdAt })

        if !workspaces.isEmpty {
            let descriptors = workspaces.map {
                "\($0.name)(\(Int($0.createdAt.timeIntervalSince1970)))"
            }.joined(separator: " | ")
            DeskJigLog.trace(.app, "RESTORE-DEBUG: [ActionPanel] workspace dynamic items", fields: ["count": workspaces.count, "names": descriptors])
        } else {
            DeskJigLog.trace(.app, "RESTORE-DEBUG: [ActionPanel] workspace dynamic items=0")
        }

        // Clean up shortcuts for workspaces that have been deleted
        let currentWorkspaceIds = Set(workspaces.map(\.id))
        let removedWorkspaceIds = registeredWorkspaceShortcutIds.subtracting(currentWorkspaceIds)
        for workspaceId in removedWorkspaceIds {
            unregisterWorkspaceShortcut(workspaceId)
        }

        // Register keyboard shortcuts for workspaces (skips already-registered ones)
        registerWorkspaceShortcuts(workspaces)
        
        return workspaces.enumerated().map { (index, workspace) in
                MenuItem(
                    id: "workspace.\(workspace.id)",
                    title: workspace.name,
                    subtitle: "\(workspace.windows.count) windows",
                    icon: MenuItem.MenuIcon(
                        type: .emoji,
                        value: workspace.icon ?? "📁"
                    ),
                    type: .leaf,
                    children: nil,
                    contextAction: .init(
                        id: "workspace.edit.\(workspace.id)",
                        title: "Edit",
                        subtitle: "Edit Workspace",
                        icon: .init(type: .systemImage, value: "square.and.pencil"),
                        action: .editWorkspace,
                        actionParameters: .init(workspace: workspace)
                    ),
                    action: .openWorkspace,
                    actionParameters: ActionParameters(workspace: workspace),
                    visibilityRule: nil,
                    shortcuts: index < 9 ? ["cmd+\(index + 1)"] : nil
                )
            }
    }
    
    /// Registers keyboard shortcuts for all workspaces.
    /// Only registers handlers for workspaces that haven't been registered yet to prevent
    /// duplicate handlers from accumulating when `updateDynamicContent()` is called multiple times.
    private func registerWorkspaceShortcuts(_ workspaces: [Workspace]) {
        for workspace in workspaces {
            // Skip if already registered to prevent duplicate handlers
            guard !registeredWorkspaceShortcutIds.contains(workspace.id) else {
                continue
            }
            registeredWorkspaceShortcutIds.insert(workspace.id)

            KeyboardShortcuts.onKeyUp(for: .workspace(workspace.id)) { [weak self] in
                guard let self else { return }
                // Execute openWorkspace action
                DeskJigLog.info(.workspace, "Workspace shortcut triggered", fields: ["name": workspace.name])
                let parameters = ActionParameters(workspace: workspace)
                self.executeAction(.openWorkspace, parameters: parameters)
            }
        }
    }

    /// Unregisters a keyboard shortcut for a workspace that has been deleted
    private func unregisterWorkspaceShortcut(_ workspaceId: UUID) {
        KeyboardShortcuts.disable(.workspace(workspaceId))
        registeredWorkspaceShortcutIds.remove(workspaceId)
    }

    // MARK: - Action Execution
    
    /// Executes a menu action with optional parameters
    func executeAction(_ action: MenuAction, parameters: ActionParameters? = nil) {
        // Cancel timers when user interacts with menu
        cancelMouseExitTimer()
        cancelSubmenuExitTimer()

        // For settings, close the panel first to avoid visual lock if opening settings
        // triggers any expensive or stalled work.
        if action == .openSettings, let openSettings = openSettingsAction {
            DeskJigLog.info(.app, "[ActionPanel] openSettings requested — closing panel before dispatch")
            closePanel()
            DispatchQueue.main.async {
                DeskJigLog.info(.app, "[ActionPanel] openSettings dispatching after panel close")
                openSettings()
            }
            DeskJigLog.info(.app, "Action executed successfully", fields: ["action": action.rawValue])
            DeskJigLog.info(.app, "Post-action: closed panel (pre-dispatch)")
            updateDynamicContent()
            runtimePresentationVersion &+= 1
            return
        }
        
        Task {
            do {
                try await dispatcher.dispatch(action, parameters: parameters)
                DeskJigLog.info(.app, "Action executed successfully", fields: ["action": action.rawValue])

                // Apply post-action behavior based on the action type
                switch action.postActionBehavior {
                case .stayOpen:
                    // Do nothing, keep panel expanded as is
                    DeskJigLog.info(.app, "Post-action: staying open")
                case .collapseToRoot:
                    // Collapse to root level but stay expanded
                    collapseToRoot()
                    DeskJigLog.info(.app, "Post-action: collapsed to root")
                case .close:
                    // Close the panel completely
                    closePanel()
                    DeskJigLog.info(.app, "Post-action: closed panel")
                }
                
                // Refresh dynamic content after action
                updateDynamicContent()
                runtimePresentationVersion &+= 1
            } catch {
                DeskJigLog.error(.app, "Failed to execute action", fields: ["error": error.localizedDescription])
            }
        }
    }
    
    // MARK: - Visibility Rules
    
    /// Checks if a menu item should be visible based on its visibility rule
    func isItemVisible(_ item: MenuItem) -> Bool {
        return switch item.visibilityRule?.condition {
        case .hasWorkspaces: !workspaceVM.windowManager.savedWorkspaces.isEmpty
        case .isWindowFocused: NSWorkspace.shared.frontmostApplication != nil
        case .hasMultipleScreens: NSScreen.screens.count > 1
        case nil: true
        }
    }
    
    // MARK: - Panel Window Following
    /// Moves the action panel to the active screen, if the active screen has changed.
    private func moveToActiveScreen(in newWindows: [WindowInfo]) {
        // Ensure there's a new main/key screen
        guard let newScreen = newActiveScreen() else {
            return
        }
        DeskJigLog.trace(.app, "Moving action panel to active screen")
        updatePanelFrame(for: newScreen, animate: true)
    }
    
    /// Gets the new active screen, if it has changed.
    private func newActiveScreen() -> FullScreenInfo? {
        // Ensure there's a main/key screen
        guard let newActiveScreen = NSScreen.main else {
            return nil
        }
        
        let newScreen = FullScreenInfo(screen: newActiveScreen)
        
        // Ensure the main/key screen has changed
        guard (newScreen.displayID != activeScreen?.displayID) || (newScreen.visibleFrame != activeScreen?.visibleFrame)
        else {
            return nil
        }
        
        activeScreen = newScreen
        return newScreen
    }

    private func setupGlobalClickMonitor() {
        globalMouseDownMonitor = GlobalEventMonitor(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            guard let self else { return }
            let mouseLocation = NSEvent.mouseLocation
            Task { @MainActor in
                self.moveToScreen(at: mouseLocation)
            }
        }
    }

    private func moveToScreen(at location: CGPoint) {
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(location) }) else {
            return
        }
        let newScreen = FullScreenInfo(screen: screen)
        guard (newScreen.displayID != activeScreen?.displayID) || (newScreen.visibleFrame != activeScreen?.visibleFrame) else {
            return
        }
        DeskJigLog.trace(.app, "Moving action panel to clicked screen")
        activeScreen = newScreen
        updatePanelFrame(for: newScreen, animate: true)
    }

    private func updatePanelFrame(for screen: FullScreenInfo, animate: Bool) {
        let panelSize = Self.expandedSize(for: screen)
        panel.setFrame(
            NSRect(origin: Self.panelOrigin(inScreen: screen, panelSize: panelSize),
                   size: panelSize),
            display: true,
            animate: animate
        )
    }
    
    /// Gets all visible items at the root level
    var visibleRootItems: [MenuItem] {
        _ = runtimePresentationVersion
        return configuration.rootItems
            .filter { isItemVisible($0) }
            .map { decorateRuntimeItem($0) }
    }
    
    /// Gets children for an item, including dynamic items
    func getChildren(for item: MenuItem) -> [MenuItem] {
        let baseChildren: [MenuItem]
        if item.type == .dynamic {
            baseChildren = dynamicItems[item.id] ?? []
        } else {
            baseChildren = item.children ?? []
        }

        return baseChildren
            .filter { isItemVisible($0) }
            .map { attachShortcutHintIfNeeded(to: $0) }
    }

    func isMenuItemActivelySelected(_ item: MenuItem) -> Bool {
        return selectedSection == item.id
    }
    
    // MARK: - Workspace Editor Panel Management
    
    /// Sets up observer for workspaceBeingEdited changes
    private func setupWorkspaceEditorObserver() {
        // Since WorkspaceViewModel is @Observable, we need to manually observe changes
        // We'll check in the execute action after createWorkspace is called
    }
    
    /// Shows the workspace editor panel when a workspace is being edited
    func showWorkspaceEditorIfNeeded() {
        if let editingWorkspace = workspaceVM.workspaceBeingEdited {
            workspaceEditorPanel?.show(editingWorkspace: editingWorkspace)
        } else if let editingDirectoryWorkspace = workspaceVM.directoryWorkspaceBeingEdited {
            workspaceEditorPanel?.showDirectoryWorkspaceEditor(editing: editingDirectoryWorkspace)
        } else {
            workspaceEditorPanel?.hide()
        }
    }
    
}

private extension ActionPanelManager {
    func decorateRuntimeItem(_ item: MenuItem) -> MenuItem {
        item
    }

    func attachShortcutHintIfNeeded(to item: MenuItem) -> MenuItem {
        guard item.contextAction == nil else {
            return item
        }

        guard let action = item.action else {
            return item
        }

        let shortcutName = action.shortcutName
        let recordedShortcut = shortcutName.flatMap { KeyboardShortcuts.getShortcut(for: $0) }
        let fallbackShortcut = item.shortcuts?.first
        let hint = makeShortcutHint(
            recorded: recordedShortcut,
            fallback: fallbackShortcut,
            expectsUserShortcut: shortcutName != nil
        )

        guard let hint else {
            return item
        }

        let contextAction = MenuItem.ContextAction(
            id: "\(item.id).shortcutHint",
            title: hint.title,
            subtitle: nil,
            icon: .init(type: .systemImage, value: hint.icon),
            action: .openSettings,
            actionParameters: nil
        )

        return MenuItem(
            id: item.id,
            title: item.title,
            subtitle: item.subtitle,
            icon: item.icon,
            type: item.type,
            children: item.children,
            contextAction: contextAction,
            action: item.action,
            actionParameters: item.actionParameters,
            visibilityRule: item.visibilityRule,
            shortcuts: item.shortcuts
        )
    }
}

private extension ActionPanelManager {
    typealias ShortcutHint = (title: String, icon: String)

    func makeShortcutHint(
        recorded: KeyboardShortcuts.Shortcut?,
        fallback: String?,
        expectsUserShortcut: Bool
    ) -> ShortcutHint? {
        if let recorded {
            let title = recorded.description.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else { return nil }
            return (title, "keyboard")
        }

        if let fallback,
           let formatted = formatShortcutString(fallback) {
            return (formatted, "keyboard")
        }

        if expectsUserShortcut {
            return ("Set Shortcut", "plus")
        }

        return nil
    }

    func formatShortcutString(_ string: String) -> String? {
        let components = string.split(separator: "+").map { String($0).trimmingCharacters(in: .whitespaces) }
        guard !components.isEmpty else { return nil }

        let mapped = components.compactMap { token -> String? in
            switch token.lowercased() {
            case "cmd", "command": return "⌘"
            case "ctrl", "control": return "⌃"
            case "option", "alt": return "⌥"
            case "shift": return "⇧"
            case "fn": return "fn"
            case "left": return "←"
            case "right": return "→"
            case "up": return "↑"
            case "down": return "↓"
            case "return", "enter": return "↩︎"
            case "space": return "⎵"
            default:
                if token.count == 1 {
                    return token.uppercased()
                } else {
                    return token.capitalized
                }
            }
        }

        guard !mapped.isEmpty else { return nil }
        return mapped.joined()
    }
}

private final class GlobalEventMonitor {
    private var monitor: Any?

    init(matching mask: NSEvent.EventTypeMask, handler: @escaping (NSEvent) -> Void) {
        monitor = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: handler)
    }

    deinit {
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
    }
}

// MARK: - Data Structures
extension ActionPanelManager {
    /// The different sections of actions that can be selected in the panel.
    enum Section: String, Hashable, Sendable, Identifiable {
        case workspaces, positioning
        var id: Self { self }
    }
}

// MARK: - Window
extension ActionPanelManager {
    
    static func makeActionPanel() -> FloatingPanel {
        // Create panel with a default size (will be updated based on actual screen)
        let defaultSize = NSSize(width: expandedWidth, height: 800)
        let panel = FloatingPanel(
            contentRect: .init(origin: .zero, size: defaultSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        
        return panel
    }

    static func panelOrigin(inScreen screen: FullScreenInfo, panelSize: NSSize) -> CGPoint {
        CGPoint(
            x: screen.visibleFrame.maxX - panelSize.width,
            y: screen.visibleFrame.minY
        )
    }
    
    /// A floating panel that can accept keyboard input while remaining non-activating.
    final class FloatingPanel: NSPanel {
        
        /// Returns `true` to allow the panel to become key window for keyboard input.
        override var canBecomeKey: Bool {
            true
        }
        
        /// Returns `true` to allow the panel to become main window if needed.
        override var canBecomeMain: Bool {
            true
        }
    }
    
}
