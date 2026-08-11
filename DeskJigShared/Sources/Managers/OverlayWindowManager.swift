//
//  OverlayWindowManager.swift
//  DeskJig
//
//  Created by Marco Freedom on 02.09.2025.
//

import Foundation
import SwiftUI
import Cocoa
import Combine

public class OverlayWindowManager: ObservableObject {
    // MARK: - UserDefaults Keys
    /// Legacy `UserDefaults` keys inherited from the commercial predecessor.
    /// The `com.nexus.` prefix is a frozen legacy value — renaming it silently
    /// resets existing users' overlay preferences. See `docs/LEGACY_IDENTIFIERS.md`.
    private enum UserDefaultsKeys {
        static let minVisibilityThreshold = "com.nexus.overlayWindowManager.minVisibilityThreshold"
        static let shouldAutoEnableVisibilityOverlays = "com.nexus.overlayWindowManager.shouldAutoEnableVisibilityOverlays"
    }

    @Published public var isOverlayEnabled = false {
        didSet {
            if self.isOverlayEnabled {
                chromeConfigurationManager.chromeProfileManager.refreshProfiles()
                self.createOverlays()
            } else {
                self.removeAllOverlays()
            }
        }
    }

    @Published public var isSelectiveGridMode = false {
        didSet {
            if isSelectiveGridMode {
                // Don't clear if we're in visibility-based mode (it manages selections automatically)
                if !isVisibilityBasedOverlaysEnabled {
                    selectedWindowsForOverlay.removeAll()
                }
            } else {
                // Remove selected window overlays
                removeSelectedWindowOverlays()
            }
            updateMouseMonitoring()
        }
    }

    @Published public var selectedWindowsForOverlay: Set<Int> = [] // Window IDs selected for overlay in selective mode

    @Published public var isTopmostWindowHighlightEnabled = false {
        didSet {
            if isTopmostWindowHighlightEnabled {
                // Show border around topmost window
                startObservingWindowChanges()
                updateTopmostWindowHighlight()
            } else {
                // Hide topmost window highlight
                stopObservingWindowChanges()
                removeTopmostWindowHighlight()
            }
        }
    }

    @Published public var isVisibilityBasedOverlaysEnabled = false {
        didSet {
            if isVisibilityBasedOverlaysEnabled {
                // Enable overlays for windows with sufficient visibility
                // First refresh windows to ensure we have the latest window list
                DeskJigLog.info(.window, "Visibility-based overlays enabled - refreshing window list first")
                windowManager?.refreshWindows { [weak self] in
                    guard let self = self else { return }
                    // After refresh completes, start observing and update overlays
                    self.startObservingWindowChanges()
                    self.updateVisibilityBasedOverlays()
                }
            } else {
                // Disable visibility-based overlays
                clearVisibilityBasedOverlays()
            }
        }
    }

    @Published public var overlayOpacity: Double = 0.3 {
        didSet {
            forceUpdateAllOverlayStyles()
        }
    }

    @Published public var overlayColor: Color = DesignTokens.Brand.accent {
        didSet {
            forceUpdateAllOverlayStyles()
        }
    }

    @Published public var showBorders = true {
        didSet {
            forceUpdateAllOverlayStyles()
        }
    }

    @Published public var showLabels = false {
        didSet {
            forceUpdateAllOverlayStyles()
        }
    }

    private var overlayWindows: [String: NSWindow] = [:] // Key: unique window identifier
    private var selectedWindowOverlays: [String: NSWindow] = [:] // Key: window identifier
    private var chromeConfigWindows: [String: NSWindow] = [:] // Key: window identifier for Chrome config UIs
    private var topmostWindowHighlightOverlay: NSWindow? // Overlay for the topmost window
    private var currentTopmostWindowId: Int? // Track the current topmost window ID
    private var currentTopmostWindowFrame: CGRect? // Track the current topmost window frame
    private var windowManager: WindowManager?
    private var windowsSubscription: AnyCancellable? // Combine subscription for window changes
    private var globalMouseMonitor: Any?
    private var globalMouseDragMonitor: Any?
    private var globalMouseDownMonitor: Any?
    @Published public var isDragging = false
    @Published public var draggedWindow: WindowInfo? // Window currently being dragged
    private var lastMouseUpTime: TimeInterval = 0
    private var mouseUpDebounceInterval: TimeInterval = 0.1 // 100ms debounce

    // Drag detection with minimum distance threshold
    private var draggedWindowId: Int? // ID of window being dragged
    private var draggedWindowInitialFrame: CGRect? // Initial frame of window
    private var activeFolderDragWindowID: Int?
    private let minimumDragDistance: CGFloat = 5.0

    // Visibility-based overlay tracking
    private var visibilityBasedWindowIDs: Set<Int> = [] // Window IDs tracked for visibility-based overlays

    /// Minimum visibility threshold (0.0 to 1.0) for showing overlays
    /// Default is 0.5 (50%) - windows need at least 50% visible area to be included.
    /// This value is persisted to UserDefaults.
    @Published public var minVisibilityThreshold: Double {
        didSet {
            DeskJigLog.info(.window, "minVisibilityThreshold changed from \(String(format: "%.0f%%", oldValue * 100)) to \(String(format: "%.0f%%", minVisibilityThreshold * 100))")

            // Clamp between 0.0 and 1.0
            if minVisibilityThreshold < 0.0 {
                DeskJigLog.warn(.window, "Threshold below 0%, clamping to 0%")
                minVisibilityThreshold = 0.0
            } else if minVisibilityThreshold > 1.0 {
                DeskJigLog.warn(.window, "Threshold above 100%, clamping to 100%")
                minVisibilityThreshold = 1.0
            }

            // Save to UserDefaults
            UserDefaults.standard.set(minVisibilityThreshold, forKey: UserDefaultsKeys.minVisibilityThreshold)
            DeskJigLog.info(.window, "Saved minVisibilityThreshold to UserDefaults: \(String(format: "%.0f%%", minVisibilityThreshold * 100))")

            // If visibility-based overlays are active, recalculate with new threshold
            if isVisibilityBasedOverlaysEnabled {
                DeskJigLog.info(.window, "Visibility-based overlays are active, recalculating with new threshold: \(String(format: "%.0f%%", minVisibilityThreshold * 100))")
                updateVisibilityBasedOverlays()
            } else {
                DeskJigLog.info(.window, "Visibility-based overlays are not active, threshold will be used on next Action Panel expansion")
            }
        }
    }

    /// Whether to automatically enable visibility-based overlays when Action Panel expands
    /// Default is true. Can be disabled for debugging purposes.
    /// This value is persisted to UserDefaults.
    @Published public var shouldAutoEnableVisibilityOverlays: Bool {
        didSet {
            DeskJigLog.info(.window, "shouldAutoEnableVisibilityOverlays changed to: \(shouldAutoEnableVisibilityOverlays)")

            // Save to UserDefaults
            UserDefaults.standard.set(shouldAutoEnableVisibilityOverlays, forKey: UserDefaultsKeys.shouldAutoEnableVisibilityOverlays)
            DeskJigLog.info(.window, "Saved shouldAutoEnableVisibilityOverlays to UserDefaults: \(shouldAutoEnableVisibilityOverlays)")
        }
    }

    // Chrome configuration manager
    public let chromeConfigurationManager = ChromeWindowConfigurationManager()

    private var visibleWindows: [WindowInfo] {
        get {
            guard let windowManager else { return [] }
            return windowManager.windows.filter { !$0.isMinimized && !$0.isHidden }
        }
    }

    public init() {
        // Load persisted settings from UserDefaults
        // For minVisibilityThreshold, default to 0.5 (50%) if not found
        // Force reset any value below 0.5 back to 0.5 (cleanup from previous 10% default)
        if UserDefaults.standard.object(forKey: UserDefaultsKeys.minVisibilityThreshold) != nil {
            let savedThreshold = UserDefaults.standard.double(forKey: UserDefaultsKeys.minVisibilityThreshold)
            if savedThreshold < 0.5 {
                self.minVisibilityThreshold = 0.5
                UserDefaults.standard.set(0.5, forKey: UserDefaultsKeys.minVisibilityThreshold)
                DeskJigLog.info(.window, "Reset minVisibilityThreshold from \(String(format: "%.0f%%", savedThreshold * 100)) to default 50%")
            } else {
                self.minVisibilityThreshold = savedThreshold
                DeskJigLog.info(.window, "Loaded minVisibilityThreshold from UserDefaults: \(String(format: "%.0f%%", savedThreshold * 100))")
            }
        } else {
            self.minVisibilityThreshold = 0.5 // Default 50% - windows need at least half visible to be included
            DeskJigLog.info(.window, "No saved minVisibilityThreshold found, using default: 50%")
        }

        // For shouldAutoEnableVisibilityOverlays, default to false if not found
        if UserDefaults.standard.object(forKey: UserDefaultsKeys.shouldAutoEnableVisibilityOverlays) != nil {
            let savedAutoEnable = UserDefaults.standard.bool(forKey: UserDefaultsKeys.shouldAutoEnableVisibilityOverlays)
            self.shouldAutoEnableVisibilityOverlays = savedAutoEnable
            DeskJigLog.info(.window, "Loaded shouldAutoEnableVisibilityOverlays from UserDefaults: \(savedAutoEnable)")
        } else {
            self.shouldAutoEnableVisibilityOverlays = false // Default OFF
            DeskJigLog.info(.window, "No saved shouldAutoEnableVisibilityOverlays found, using default: false")
        }

        // Set up mouse monitoring for drag detection
        updateMouseMonitoring()
    }

    public func setWindowManager(_ windowManager: WindowManager) {
        self.windowManager = windowManager
    }

    // MARK: - Chrome Configuration (Delegated to ChromeWindowConfigurationManager)

    public func chromeConfiguration(for windowInfo: WindowInfo) -> ChromeWindowConfiguration? {
        return chromeConfigurationManager.chromeConfiguration(for: windowInfo)
    }

    public func applyChromeState(_ state: ChromeWindowState?, to windowId: Int) {
        chromeConfigurationManager.applyChromeState(state, to: windowId)
    }

    public func chromeState(for windowInfo: WindowInfo, captureIfNeeded: Bool) -> ChromeWindowState? {
        return chromeConfigurationManager.chromeState(for: windowInfo, captureIfNeeded: captureIfNeeded)
    }

    private func cocoaFrame(for windowInfo: WindowInfo) -> CGRect {
        let windowFrame = windowInfo.frame

        // According to COORDINATE_SYSTEMS_AND_SCREEN_FRAMES.md:
        // - WindowInfo.frame uses window coordinates (top-left origin, Y increases downward)
        // - NSWindow uses Cocoa coordinates (bottom-left origin, Y increases upward)
        // - The global coordinate space is anchored to NSScreen.screens.first

        // Get the global coordinate space anchor (first screen's maxY)
        guard let firstScreen = NSScreen.screens.first else {
            DeskJigLog.error(.window, "No screens available for coordinate conversion")
            return windowFrame
        }

        let globalMaxY = firstScreen.frame.maxY

        // Convert from window coordinates to Cocoa coordinates:
        // Window Y=0 is at the global top (globalMaxY in screen coords)
        // Window Y increases downward, Cocoa Y increases upward
        // Formula: cocoaY = globalMaxY - windowY - height
        let cocoaY = globalMaxY - windowFrame.origin.y - windowFrame.height

        let cocoaFrame = CGRect(
            x: windowFrame.origin.x,
            y: cocoaY,
            width: windowFrame.width,
            height: windowFrame.height
        )

        return cocoaFrame
    }

    public func toggleOverlays() {
        isOverlayEnabled.toggle()
    }

    public func toggleTopmostWindowHighlight() {
        isTopmostWindowHighlightEnabled.toggle()
    }

    public func updateOverlays() {
        if isOverlayEnabled {
            smartUpdateOverlays()
        }

        if isSelectiveGridMode {
            updateSelectedWindowOverlays()
        }

        if isTopmostWindowHighlightEnabled {
            updateTopmostWindowHighlight()
        }
    }

    public func forceUpdateAllOverlayStyles() {
        guard isOverlayEnabled else { return }

        for (windowKey, overlayWindow) in overlayWindows {
            if let windowInfo = windowManager?.windows.first(where: { "\($0.id)" == windowKey }) {
                if let bundleIdentifier = windowInfo.bundleIdentifier,
                   chromeBundleIdentifiers.contains(bundleIdentifier) {
                    _ = chromeConfiguration(for: windowInfo)
                }

                // Force update the SwiftUI content for style changes
                let updatedOverlayView = OverlayView(
                    windowInfo: windowInfo,
                    opacity: overlayOpacity,
                    color: overlayColor,
                    showBorders: showBorders,
                    showLabels: showLabels
                )

                if let hostingView = overlayWindow.contentView as? NSHostingView<OverlayView> {
                    hostingView.rootView = updatedOverlayView
                }
            }
        }
    }

    private func generateWindowKey(for windowInfo: WindowInfo) -> String {
        // Use the stable window number from the system as the key
        return "\(windowInfo.id)"
    }

    private func smartUpdateOverlays() {
        var currentWindowKeys = Set<String>()

        // Process current visible windows
        for windowInfo in visibleWindows {
            let windowKey = generateWindowKey(for: windowInfo)
            currentWindowKeys.insert(windowKey)

            if let existingWindow = overlayWindows[windowKey] {
                // Window exists, update its frame and content if needed
                updateOverlayWindow(existingWindow, for: windowInfo)
            } else {
                // New window, create overlay
                if let newOverlay = createOverlayWindow(for: windowInfo) {
                    overlayWindows[windowKey] = newOverlay
                }
            }
        }

        // Remove overlays for windows that no longer exist or are no longer visible
        let keysToRemove = Set(overlayWindows.keys).subtracting(currentWindowKeys)
        for keyToRemove in keysToRemove {
            if let windowToRemove = overlayWindows[keyToRemove] {
                windowToRemove.orderOut(nil)
                overlayWindows.removeValue(forKey: keyToRemove)
            }

            // Also remove corresponding Chrome config window if it exists
            if let configWindow = chromeConfigWindows[keyToRemove] {
                configWindow.orderOut(nil)
                chromeConfigWindows.removeValue(forKey: keyToRemove)
                DeskJigLog.trace(.window, "Removed Chrome config window for key: \(keyToRemove)")
            }
        }
    }

    private func createOverlays() {
        for windowInfo: WindowInfo in visibleWindows {
            let windowKey = generateWindowKey(for: windowInfo)
            if let newOverlay = createOverlayWindow(for: windowInfo) {
                overlayWindows[windowKey] = newOverlay
            }
        }
    }

    private func createOverlayWindow(for windowInfo: WindowInfo) -> NSWindow? {
        let cocoaFrame = cocoaFrame(for: windowInfo)

        let overlayWindow = OverlayWindow(
            contentRect: cocoaFrame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )

        // Configure window properties
        overlayWindow.level = NSWindow.Level.floating
        overlayWindow.isOpaque = false
        overlayWindow.backgroundColor = NSColor.clear
        overlayWindow.collectionBehavior = [NSWindow.CollectionBehavior.canJoinAllSpaces, NSWindow.CollectionBehavior.stationary, NSWindow.CollectionBehavior.ignoresCycle]

        // Important: Don't set a delegate to avoid retain cycles
        overlayWindow.delegate = nil

        // Ensure the window doesn't try to save/restore state
        overlayWindow.isRestorable = false

        // Create SwiftUI OverlayView using NSHostingView
        let overlayView = OverlayView(
            windowInfo: windowInfo,
            opacity: overlayOpacity,
            color: overlayColor,
            showBorders: showBorders,
            showLabels: showLabels
        )
        let hostingView = NSHostingView(rootView: overlayView)
        hostingView.frame = CGRect(origin: .zero, size: cocoaFrame.size)
        overlayWindow.contentView = hostingView

        overlayWindow.orderFront(self)

        // Check if this is a Chrome window - create a separate window for the configuration UI
        if let bundleIdentifier = windowInfo.bundleIdentifier,
           chromeBundleIdentifiers.contains(bundleIdentifier),
           let config = chromeConfiguration(for: windowInfo) {
            createChromeConfigurationWindow(for: windowInfo, configuration: config, baseFrame: cocoaFrame)
        }

        return overlayWindow
    }

    private func createChromeConfigurationWindow(for windowInfo: WindowInfo, configuration: ChromeWindowConfiguration, baseFrame: CGRect) {
        let windowKey = "\(windowInfo.id)"

        // Calculate the frame for the Chrome configuration UI (centered, smaller)
        let configWidth: CGFloat = min(baseFrame.size.width * 0.65, 320)
        let initialConfigHeight: CGFloat = 400
        let configX = baseFrame.origin.x + (baseFrame.size.width - configWidth) / 2
        let configY = baseFrame.origin.y + (baseFrame.size.height - initialConfigHeight) / 2
        let configFrame = CGRect(x: configX, y: configY, width: configWidth, height: initialConfigHeight)

        let configWindow = ChromeConfigurationWindow(
            contentRect: configFrame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )

        // Create SwiftUI view for Chrome configuration with height change callback
        let configView = ChromeConfigurationOverlayView(
            configuration: configuration,
            profiles: chromeConfigurationManager.chromeProfileManager.profiles,
            onRefreshTabs: { [weak self] in
                self?.chromeConfigurationManager.matchChromeCapture(for: windowInfo)
            },
            onConfigurationChange: { [weak self] chromeConfiguration in
                self?.chromeConfigurationManager.updateConfiguration(chromeConfiguration, for: windowInfo.id)
            },
            onDirectoryChange: { [weak self] directory in
                self?.chromeConfigurationManager.setChromeProfile(directory: directory, for: windowInfo)
            },
            onHeightChange: { [weak configWindow] newHeight in
                guard let configWindow = configWindow else { return }

                // Calculate new frame keeping the window centered
                let currentFrame = configWindow.frame
                let heightDiff = newHeight - currentFrame.size.height
                let newY = currentFrame.origin.y - (heightDiff / 2)
                let newFrame = CGRect(
                    x: currentFrame.origin.x,
                    y: newY,
                    width: currentFrame.size.width,
                    height: newHeight
                )

                // Animate the resize
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.2
                    context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                    configWindow.animator().setFrame(newFrame, display: true)
                }

                DeskJigLog.trace(.window, "Resized Chrome config window to height: \(newHeight)")
            }
        )

        let hostingView = NSHostingView(rootView: configView)
        hostingView.frame = CGRect(origin: .zero, size: configFrame.size)
        configWindow.contentView = hostingView

        configWindow.orderFront(self)
        chromeConfigWindows[windowKey] = configWindow

        DeskJigLog.info(.window, "✅ Created Chrome configuration window for: \(windowInfo.windowTitle)")
    }

    private func updateOverlayWindow(_ overlayWindow: NSWindow, for windowInfo: WindowInfo) {
        let newCocoaFrame = cocoaFrame(for: windowInfo)

        // Check if frame has changed with a small tolerance to avoid micro-updates
        let currentFrame = overlayWindow.frame
        let frameChanged = abs(currentFrame.origin.x - newCocoaFrame.origin.x) > 1 ||
                          abs(currentFrame.origin.y - newCocoaFrame.origin.y) > 1 ||
                          abs(currentFrame.size.width - newCocoaFrame.size.width) > 1 ||
                          abs(currentFrame.size.height - newCocoaFrame.size.height) > 1

        if frameChanged {
            overlayWindow.setFrame(newCocoaFrame, display: true, animate: false)

            // Update Chrome configuration window if it exists
            let windowKey = "\(windowInfo.id)"
            if let configWindow = chromeConfigWindows[windowKey] {
                let configWidth: CGFloat = min(newCocoaFrame.size.width * 0.65, 320)
                let configHeight: CGFloat = 400
                let configX = newCocoaFrame.origin.x + (newCocoaFrame.size.width - configWidth) / 2
                let configY = newCocoaFrame.origin.y + (newCocoaFrame.size.height - configHeight) / 2
                let configFrame = CGRect(x: configX, y: configY, width: configWidth, height: configHeight)
                configWindow.setFrame(configFrame, display: true, animate: false)
            }
        }

        // Update hosting view frame if needed
        if let hostingView = overlayWindow.contentView as? NSHostingView<OverlayView> {
            let newSize = newCocoaFrame.size
            if hostingView.frame.size != newSize {
                hostingView.frame = CGRect(origin: .zero, size: newSize)
            }

            // Only update SwiftUI content if frame changed
            if frameChanged {
                let updatedOverlayView = OverlayView(
                    windowInfo: windowInfo,
                    opacity: overlayOpacity,
                    color: overlayColor,
                    showBorders: showBorders,
                    showLabels: showLabels
                )
                hostingView.rootView = updatedOverlayView
            }
        } else {
            // Fallback: create new hosting view
            let updatedOverlayView = OverlayView(
                windowInfo: windowInfo,
                opacity: overlayOpacity,
                color: overlayColor,
                showBorders: showBorders,
                showLabels: showLabels
            )
            let hostingView = NSHostingView(rootView: updatedOverlayView)
            hostingView.frame = CGRect(origin: .zero, size: newCocoaFrame.size)
            overlayWindow.contentView = hostingView
        }
    }

    private func removeAllOverlays() {
        for (_, window) in overlayWindows {
            window.orderOut(nil)
        }
        overlayWindows.removeAll()

        for (_, window) in chromeConfigWindows {
            window.orderOut(nil)
        }
        chromeConfigWindows.removeAll()
    }

    // MARK: - Global Mouse Monitor Methods

    /// Updates mouse monitoring based on current state
    private func updateMouseMonitoring() {
        // Always monitor for drag events - needed for action panel toggle expansion
        // and for selective overlay features
        setupGlobalMouseMonitor()
    }

    private func setupGlobalMouseMonitor() {
        removeGlobalMouseMonitor()

        DeskJigLog.info(.window, "Setting up global mouse monitors for drag detection")

        // Monitor for mouse down events to capture initial position and window
        globalMouseDownMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown]) { [weak self] _ in
            guard let self = self else { return }
            self.isDragging = false
            self.activeFolderDragWindowID = nil
            let mouseLocation = NSEvent.mouseLocation

            // Log coordinate conversion for debugging
            let screenHeight = NSScreen.screens.first?.frame.height ?? 0
            let convertedLocation = CGPoint(
                x: mouseLocation.x,
                y: screenHeight - mouseLocation.y
            )
            DeskJigLog.trace(.window, "🖱️ Mouse down at Cocoa coords: \(mouseLocation)")
            DeskJigLog.trace(.window, "🖱️ Converted to CG coords: \(convertedLocation) (screenHeight: \(screenHeight))")

            // Try to identify the window at this location
            if let window = self.getWindowAtLocation(mouseLocation) {
                self.draggedWindowId = window.id
                self.draggedWindowInitialFrame = self.windowManager?.getCurrentWindowFrame(for: window.id) ?? window.frame
                self.draggedWindow = window
                DeskJigLog.trace(.window, "🖱️ Found window: '\(window.windowTitle)' of '\(window.appName)' (ID: \(window.id))")
            } else {
                self.draggedWindowId = nil
                self.draggedWindowInitialFrame = nil
                self.draggedWindow = nil
                DeskJigLog.warn(.window, "🖱️ No window found at location")
            }
        }

        // Monitor for mouse drag events to track drag state
        globalMouseDragMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDragged]) { [weak self] _ in
            guard let self = self else { return }

            // Only set isDragging to true if a WINDOW has actually moved beyond minimum threshold
            if !self.isDragging {
                guard let windowId = self.draggedWindowId else {
                    DeskJigLog.trace(.window, "🖱️ Drag event but no draggedWindowId set (no window found at mouse down)")
                    return
                }
                guard let initialFrame = self.draggedWindowInitialFrame else {
                    DeskJigLog.warn(.window, "🖱️ Drag event but no initialFrame set")
                    return
                }
                guard let currentFrame = self.windowManager?.getCurrentWindowFrame(for: windowId) else {
                    DeskJigLog.warn(.window, "🖱️ Drag event but getCurrentWindowFrame returned nil for window ID \(windowId)")
                    return
                }

                // Calculate how far the WINDOW has moved (not just the mouse)
                let deltaX = abs(currentFrame.origin.x - initialFrame.origin.x)
                let deltaY = abs(currentFrame.origin.y - initialFrame.origin.y)
                let distanceMoved = max(deltaX, deltaY)

                // Only activate dragging if the window actually moved beyond threshold
                if distanceMoved >= self.minimumDragDistance {
                    if self.windowManager?.folderTabCoordinator.beginMemberDrag(windowID: windowId) == true {
                        self.activeFolderDragWindowID = windowId
                        self.windowManager?.folderTabCoordinator.updateMemberDrag(windowID: windowId, frame: currentFrame)
                        self.isDragging = true
                        DeskJigLog.info(.window, "🖱️ Folder drag started - isDragging = true")
                        return
                    }

                    DeskJigLog.info(.window, "🖱️ Drag started - isDragging = true (window moved \(distanceMoved) points)")
                    self.isDragging = true
                }
            } else if let folderWindowID = self.activeFolderDragWindowID {
                if let currentFrame = self.windowManager?.getCurrentWindowFrame(for: folderWindowID) {
                    self.windowManager?.folderTabCoordinator.updateMemberDrag(windowID: folderWindowID, frame: currentFrame)
                }
            }
        }

        // Monitor for mouse up events
        globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseUp]) { [weak self] _ in
            guard let self = self else { return }
            let currentTime = CFAbsoluteTimeGetCurrent()

            // Debounce multiple mouseUp events
            if currentTime - self.lastMouseUpTime < self.mouseUpDebounceInterval {
                return
            }
            self.lastMouseUpTime = currentTime

            // Get the global mouse location
            let globalLocation = NSEvent.mouseLocation
            let windowFrameAtMouseUp = self.draggedWindowId.flatMap { self.windowManager?.getCurrentWindowFrame(for: $0) }
            let folderDragWindowID = self.activeFolderDragWindowID

            if self.isDragging {
                if let folderDragWindowID {
                    self.windowManager?.folderTabCoordinator.endMemberDrag(
                        windowID: folderDragWindowID,
                        finalFrame: windowFrameAtMouseUp
                    )
                }

                // Reset drag state but don't process the click
                DeskJigLog.info(.window, "Drag ended - isDragging = false")
                self.isDragging = false
            } else {
                // This is a genuine click, process it
                self.handleTap(at: globalLocation)
            }

            // Always clear drag tracking state on mouse up
            self.draggedWindowId = nil
            self.draggedWindowInitialFrame = nil
            self.draggedWindow = nil
            self.activeFolderDragWindowID = nil
        }

        DeskJigLog.info(.window, "Global mouse monitors set up successfully")
    }

    private func removeGlobalMouseMonitor() {
        if let monitor = globalMouseMonitor {
            NSEvent.removeMonitor(monitor)
            globalMouseMonitor = nil
        }

        if let dragMonitor = globalMouseDragMonitor {
            NSEvent.removeMonitor(dragMonitor)
            globalMouseDragMonitor = nil
        }

        if let downMonitor = globalMouseDownMonitor {
            NSEvent.removeMonitor(downMonitor)
            globalMouseDownMonitor = nil
        }

        isDragging = false
        lastMouseUpTime = 0
        draggedWindowId = nil
        draggedWindowInitialFrame = nil
        draggedWindow = nil
        activeFolderDragWindowID = nil
    }

    /// Get the window at a given screen location (Cocoa coordinates)
    private func getWindowAtLocation(_ location: CGPoint) -> WindowInfo? {
        guard let windowManager = windowManager else {
            DeskJigLog.warn(.window, "🔍 getWindowAtLocation: windowManager is nil")
            return nil
        }

        // Find the screen that contains this point
        // Cocoa coordinates: Y=0 at bottom, Y increases upward
        // CG/Window coordinates: Y=0 at top, Y increases downward
        // The global coordinate space is anchored to NSScreen.screens.first
        guard let primaryScreen = NSScreen.screens.first else {
            DeskJigLog.warn(.window, "🔍 getWindowAtLocation: No screens available")
            return nil
        }

        // Convert from Cocoa to CG coordinates using the primary screen's maxY as anchor
        // This is the standard conversion: cgY = primaryScreen.frame.maxY - cocoaY
        let convertedLocation = CGPoint(
            x: location.x,
            y: primaryScreen.frame.maxY - location.y
        )
        DeskJigLog.trace(.window, "🔍 getWindowAtLocation: Cocoa \(location) → CG \(convertedLocation)")

        // Find the topmost window at this location
        return windowManager.findTopmostWindow(at: convertedLocation)
    }

    private func handleTap(at location: CGPoint) {
        guard windowManager != nil else {
            DeskJigLog.info(.window, "WindowManager not available")
            return
        }

        // Don't allow manual toggling when in visibility-based overlay mode
        // (overlays are managed automatically based on visibility)
        guard !isVisibilityBasedOverlaysEnabled else {
            DeskJigLog.trace(.window, "Tap ignored - visibility-based overlays are enabled (automatic mode)")
            return
        }

        // Find the topmost window at this location
        if let windowInfo = getWindowAtLocation(location) {
            DeskJigLog.trace(.window, "Found window: \(windowInfo.appName) (level: \(windowInfo.windowLevel), bundle: \(windowInfo.bundleIdentifier ?? "nil"))")
            // If in selective mode, toggle the window selection for regular overlay
            if isSelectiveGridMode {
                let isOn = toggleWindowForOverlay(windowID: windowInfo.id)
                DeskJigLog.info(.window, "Toggled overlay for \(windowInfo.appName) - \(windowInfo.windowTitle) (Bundle ID: \(windowInfo.bundleIdentifier ?? "Unknown")) isOn:\(isOn)")
            }
        } else {
            let screenHeight = NSScreen.screens.first?.frame.height ?? 0
            let convertedLocation = CGPoint(x: location.x, y: abs(location.y - screenHeight))
            DeskJigLog.info(.window, "No window found at location: x=\(Int(convertedLocation.x)), y=\(Int(convertedLocation.y))")
        }
    }

    // MARK: - Selective Window Overlay Methods

    public func toggleWindowForOverlay(windowID: Int) -> Bool {
        // Don't allow manual toggling when in visibility-based overlay mode
        guard !isVisibilityBasedOverlaysEnabled else {
            DeskJigLog.warn(.window, "Manual toggle ignored for window ID \(windowID) - visibility-based overlays are enabled")
            return selectedWindowsForOverlay.contains(windowID)
        }

        if selectedWindowsForOverlay.contains(windowID) {
            // Remove window from selection
            selectedWindowsForOverlay.remove(windowID)
            removeSelectedWindowOverlay(for: windowID)
            return false
        } else {
            // Add window to selection
            selectedWindowsForOverlay.insert(windowID)
            createSelectedWindowOverlay(for: windowID)
            return true
        }
    }

    private func createSelectedWindowOverlay(for windowID: Int) {
        guard let windowInfo = windowManager?.windows.first(where: { $0.id == windowID }),
              !windowInfo.isMinimized && !windowInfo.isHidden else {
            DeskJigLog.warn(.window, "Cannot create overlay for window ID \(windowID) - window not found or not visible")
            return
        }

        let windowKey = "\(windowID)"

        DeskJigLog.info(.window, "Creating selected window overlay for: \(windowInfo.windowTitle) (ID: \(windowID))")

        let cocoaFrame = cocoaFrame(for: windowInfo)

        let overlayWindow = OverlayWindow(
            contentRect: cocoaFrame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )

        // Configure window properties
        overlayWindow.level = NSWindow.Level.floating
        overlayWindow.isOpaque = false
        overlayWindow.backgroundColor = NSColor.clear
        overlayWindow.collectionBehavior = [NSWindow.CollectionBehavior.canJoinAllSpaces, NSWindow.CollectionBehavior.stationary, NSWindow.CollectionBehavior.ignoresCycle]
        overlayWindow.delegate = nil
        overlayWindow.isRestorable = false

        // Create SwiftUI OverlayView using NSHostingView
        let overlayView = OverlayView(
            windowInfo: windowInfo,
            opacity: overlayOpacity,
            color: overlayColor,
            showBorders: showBorders,
            showLabels: showLabels
        )
        let hostingView = NSHostingView(rootView: overlayView)
        hostingView.frame = CGRect(origin: .zero, size: cocoaFrame.size)
        overlayWindow.contentView = hostingView

        overlayWindow.orderFront(self)
        selectedWindowOverlays[windowKey] = overlayWindow

        // Check if this is a Chrome window - create a separate window for the configuration UI
        if let bundleIdentifier = windowInfo.bundleIdentifier,
           chromeBundleIdentifiers.contains(bundleIdentifier),
           let config = chromeConfiguration(for: windowInfo) {
            createChromeConfigurationWindow(for: windowInfo, configuration: config, baseFrame: cocoaFrame)
        }

        DeskJigLog.info(.window, "✅ Successfully created overlay for window: \(windowInfo.windowTitle) at frame: \(cocoaFrame)")
    }

    private func removeSelectedWindowOverlay(for windowID: Int) {
        let windowKey = "\(windowID)"
        if let window = selectedWindowOverlays[windowKey] {
            window.orderOut(nil)
            selectedWindowOverlays.removeValue(forKey: windowKey)
        }

        if let configWindow = chromeConfigWindows[windowKey] {
            configWindow.orderOut(nil)
            chromeConfigWindows.removeValue(forKey: windowKey)
        }
    }

    private func removeSelectedWindowOverlays() {
        for (_, window) in selectedWindowOverlays {
            window.orderOut(nil)
        }
        selectedWindowOverlays.removeAll()

        for (_, window) in chromeConfigWindows {
            window.orderOut(nil)
        }
        chromeConfigWindows.removeAll()
    }

    func updateSelectedWindowOverlays() {
        guard isSelectiveGridMode else {
            DeskJigLog.trace(.window, "updateSelectedWindowOverlays skipped - not in selective grid mode")
            return
        }

        // Update overlays for currently selected windows
        for windowID in selectedWindowsForOverlay {
            if let windowInfo = windowManager?.windows.first(where: { $0.id == windowID }),
               !windowInfo.isMinimized && !windowInfo.isHidden {
                let windowKey = "\(windowID)"

                if let existingWindow = selectedWindowOverlays[windowKey] {
                    updateSelectedWindowOverlay(existingWindow, for: windowInfo)
                } else {
                    createSelectedWindowOverlay(for: windowID)
                }
            } else {
                // Window is no longer visible, remove its overlay
                removeSelectedWindowOverlay(for: windowID)
            }
        }

        // Remove overlays for windows that are no longer selected
        let keysToRemove = Set(selectedWindowOverlays.keys).subtracting(selectedWindowsForOverlay.map { "\($0)" })
        for keyToRemove in keysToRemove {
            if let windowToRemove = selectedWindowOverlays[keyToRemove] {
                windowToRemove.orderOut(nil)
                selectedWindowOverlays.removeValue(forKey: keyToRemove)
            }

            // Also remove corresponding Chrome config window if it exists
            if let configWindow = chromeConfigWindows[keyToRemove] {
                configWindow.orderOut(nil)
                chromeConfigWindows.removeValue(forKey: keyToRemove)
                DeskJigLog.trace(.window, "Removed Chrome config window for key: \(keyToRemove)")
            }
        }
    }

    private func updateSelectedWindowOverlay(_ overlayWindow: NSWindow, for windowInfo: WindowInfo) {
        let newCocoaFrame = cocoaFrame(for: windowInfo)

        // Check if frame has changed
        let currentFrame = overlayWindow.frame
        let frameChanged = abs(currentFrame.origin.x - newCocoaFrame.origin.x) > 1 ||
                          abs(currentFrame.origin.y - newCocoaFrame.origin.y) > 1 ||
                          abs(currentFrame.size.width - newCocoaFrame.size.width) > 1 ||
                          abs(currentFrame.size.height - newCocoaFrame.size.height) > 1

        if frameChanged {
            overlayWindow.setFrame(newCocoaFrame, display: true, animate: false)

            // Update Chrome configuration window if it exists
            let windowKey = "\(windowInfo.id)"
            if let configWindow = chromeConfigWindows[windowKey] {
                let configWidth: CGFloat = min(newCocoaFrame.size.width * 0.65, 320)
                let configHeight: CGFloat = 400
                let configX = newCocoaFrame.origin.x + (newCocoaFrame.size.width - configWidth) / 2
                let configY = newCocoaFrame.origin.y + (newCocoaFrame.size.height - configHeight) / 2
                let configFrame = CGRect(x: configX, y: configY, width: configWidth, height: configHeight)
                configWindow.setFrame(configFrame, display: true, animate: false)
            }
        }

        // Update hosting view frame and content if needed
        if let hostingView = overlayWindow.contentView as? NSHostingView<OverlayView> {
            let newSize = newCocoaFrame.size
            if hostingView.frame.size != newSize {
                hostingView.frame = CGRect(origin: .zero, size: newSize)
            }

            if frameChanged {
                let updatedOverlayView = OverlayView(
                    windowInfo: windowInfo,
                    opacity: overlayOpacity,
                    color: overlayColor,
                    showBorders: showBorders,
                    showLabels: showLabels
                )
                hostingView.rootView = updatedOverlayView
            }
        }
    }

    // MARK: - Screen Detection Helper Methods

    /// Finds the screen that contains the given frame
    /// - Parameter frame: The frame to check
    /// - Returns: The screen that contains this frame, or nil if not found
    public func findScreenContaining(frame: CGRect) -> NSScreen? {
        let screenHeight = NSScreen.screens.first?.frame.height ?? 0
        let convertedLocation = CGPoint(
            x: frame.midX,
            y: abs(frame.midY - screenHeight)
        )
        return findScreenContaining(point: convertedLocation)
    }

    /// Finds the screen that contains the given point
    /// - Parameter point: The point to check
    /// - Returns: The screen that contains this point, or nil if not found
    private func findScreenContaining(point: CGPoint) -> NSScreen? {
        // Find the screen that contains the point
        for (_, screen) in NSScreen.screens.enumerated() {
            if screen.frame.contains(point) {
                return screen
            }
        }

        DeskJigLog.info(.window, "⚠️ Point \(point) not contained in any screen, finding closest...")

        // If point is not in any screen, find the closest screen
        var closestScreen: NSScreen?
        var minDistance = Double.infinity

        for (index, screen) in NSScreen.screens.enumerated() {
            let distance = distanceFromPointToRect(point: point, rect: screen.frame)
            DeskJigLog.info(.window, "🔍 Distance to screen \(index): \(distance)")
            if distance < minDistance {
                minDistance = distance
                closestScreen = screen
            }
        }

        if let closest = closestScreen {
            let closestIndex = NSScreen.screens.firstIndex(of: closest) ?? -1
            DeskJigLog.info(.window, "📍 Closest screen is \(closestIndex) with distance \(minDistance)")
        }

        return closestScreen
    }

    /// Calculates the distance from a point to the nearest edge of a rectangle
    /// - Parameters:
    ///   - point: The point
    ///   - rect: The rectangle
    /// - Returns: Distance to the rectangle (0 if point is inside)
    private func distanceFromPointToRect(point: CGPoint, rect: CGRect) -> Double {
        let dx = max(0, max(rect.minX - point.x, point.x - rect.maxX))
        let dy = max(0, max(rect.minY - point.y, point.y - rect.maxY))
        return sqrt(dx * dx + dy * dy)
    }

    // MARK: - Topmost Window Highlight Methods

    /// Updates the highlight overlay to follow the topmost window
    public func updateTopmostWindowHighlight() {
        guard isTopmostWindowHighlightEnabled,
              let windowManager = windowManager else {
            return
        }

        // Get the topmost visible window (queries system directly for accuracy)
        guard let topmostWindow = windowManager.getTopmostVisibleWindow() else {
            removeTopmostWindowHighlight()
            return
        }

        // Create or update the highlight overlay
        if let existingOverlay = topmostWindowHighlightOverlay {
            updateTopmostWindowHighlightOverlay(existingOverlay, for: topmostWindow)
        } else {
            topmostWindowHighlightOverlay = createTopmostWindowHighlightOverlay(for: topmostWindow)
        }
    }

    private func createTopmostWindowHighlightOverlay(for windowInfo: WindowInfo) -> NSWindow? {
        let cocoaFrame = cocoaFrame(for: windowInfo)

        let overlayWindow = OverlayWindow(
            contentRect: cocoaFrame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )

        // Configure window properties
        overlayWindow.level = NSWindow.Level.floating
        overlayWindow.isOpaque = false
        overlayWindow.backgroundColor = NSColor.clear
        overlayWindow.ignoresMouseEvents = true // Pass through mouse events
        overlayWindow.collectionBehavior = [NSWindow.CollectionBehavior.canJoinAllSpaces, NSWindow.CollectionBehavior.stationary, NSWindow.CollectionBehavior.ignoresCycle]
        overlayWindow.delegate = nil
        overlayWindow.isRestorable = false

        // Create SwiftUI OverlayView with distinct styling for topmost window
        let overlayView = OverlayView(
            windowInfo: windowInfo,
            opacity: 0.2, // Lower opacity for subtle highlight
            color: DesignTokens.Brand.accent, // Green to indicate active/topmost window
            showBorders: true,
            showLabels: false
        )
        let hostingView = NSHostingView(rootView: overlayView)
        hostingView.frame = CGRect(origin: .zero, size: cocoaFrame.size)
        overlayWindow.contentView = hostingView

        overlayWindow.orderFront(self)
        return overlayWindow
    }

    private func updateTopmostWindowHighlightOverlay(_ overlayWindow: NSWindow, for windowInfo: WindowInfo) {
        let newCocoaFrame = cocoaFrame(for: windowInfo)

        // Check if frame has changed
        let currentFrame = overlayWindow.frame
        let frameChanged = abs(currentFrame.origin.x - newCocoaFrame.origin.x) > 1 ||
                          abs(currentFrame.origin.y - newCocoaFrame.origin.y) > 1 ||
                          abs(currentFrame.size.width - newCocoaFrame.size.width) > 1 ||
                          abs(currentFrame.size.height - newCocoaFrame.size.height) > 1

        if frameChanged {
            overlayWindow.setFrame(newCocoaFrame, display: true, animate: false)
        }

        // Update hosting view frame and content if needed
        if let hostingView = overlayWindow.contentView as? NSHostingView<OverlayView> {
            let newSize = newCocoaFrame.size
            if hostingView.frame.size != newSize {
                hostingView.frame = CGRect(origin: .zero, size: newSize)
            }

            if frameChanged {
                let updatedOverlayView = OverlayView(
                    windowInfo: windowInfo,
                    opacity: 0.2,
                    color: DesignTokens.Brand.accent,
                    showBorders: true,
                    showLabels: true
                )
                hostingView.rootView = updatedOverlayView
            }
        }
    }

    private func removeTopmostWindowHighlight() {
        if let window = topmostWindowHighlightOverlay {
            window.orderOut(nil)
            topmostWindowHighlightOverlay = nil
        }
    }

    // MARK: - Window Change Observation

    /// Start observing window changes via Combine
    private func startObservingWindowChanges() {
        guard let windowManager = windowManager else {
            DeskJigLog.warn(.window, "WindowManager not available for observing window changes")
            return
        }

        // Cancel any existing subscription
        stopObservingWindowChanges()

        DeskJigLog.info(.window, "Starting to observe window changes for topmost window tracking")
        windowManager.startAutoRefresh()

        // Subscribe to changes in the windows array
        windowsSubscription = windowManager.$windows
            .sink { [weak self] newWindows in
                self?.handleWindowsChanged(newWindows)
            }
    }

    /// Stop observing window changes
    private func stopObservingWindowChanges() {
        windowsSubscription?.cancel()
        windowsSubscription = nil
        windowManager?.stopAutoRefresh()
        currentTopmostWindowId = nil
        currentTopmostWindowFrame = nil
        DeskJigLog.info(.window, "Stopped observing window changes for topmost window")
    }

    /// Handle windows changed - update topmost window highlight if needed
    private func handleWindowsChanged(_ currentWindows: [WindowInfo]) {
        // Handle topmost window highlight
        if isTopmostWindowHighlightEnabled {
            // Get the topmost visible window (queries system directly for accuracy)
            if let topmostWindow = windowManager?.getTopmostVisibleWindow() {
                let windowIdChanged = currentTopmostWindowId != topmostWindow.id
                let windowFrameChanged = currentTopmostWindowFrame != topmostWindow.frame

                // Check if the topmost window changed or if its frame changed
                if windowIdChanged {
                    currentTopmostWindowId = topmostWindow.id
                    currentTopmostWindowFrame = topmostWindow.frame
                    updateTopmostWindowHighlight()
                    DeskJigLog.info(.window, "Topmost window changed to: \(topmostWindow.appName) - \(topmostWindow.windowTitle)")
                } else if windowFrameChanged {
                    // Same window but frame changed (moved or resized)
                    currentTopmostWindowFrame = topmostWindow.frame
                    updateTopmostWindowHighlight()
                    DeskJigLog.trace(.window, "Topmost window frame changed for: \(topmostWindow.appName) - \(topmostWindow.windowTitle)")
                }
            } else {
                // No visible windows, remove highlight
                if currentTopmostWindowId != nil {
                    removeTopmostWindowHighlight()
                    currentTopmostWindowId = nil
                    currentTopmostWindowFrame = nil
                }
            }
        }

        // Handle visibility-based overlays
        if isVisibilityBasedOverlaysEnabled {
            updateVisibilityBasedOverlays(currentWindows: currentWindows)
        }
    }

    // MARK: - Visibility-Based Overlay Methods

    /// Updates overlays based on window visibility calculations (≥50% visible)
    private func updateVisibilityBasedOverlays(currentWindows: [WindowInfo]? = nil) {
        guard isVisibilityBasedOverlaysEnabled,
              let windowManager = windowManager else {
            return
        }

        // Calculate visibility for all windows and get those with ≥50% visibility
        // Use provided currentWindows to avoid reading stale @Published property during subscriber callbacks
        let visibleWindows = windowManager.getVisibleWindows(
            minVisibility: minVisibilityThreshold,
            includeMinimized: false,
            includeHidden: false,
            currentWindows: currentWindows
        )

        // Get current window IDs that meet the threshold
        let currentVisibleWindowIDs = Set(visibleWindows.map { $0.id })

        // IMPORTANT: Enable selective mode BEFORE modifying selectedWindowsForOverlay
        // to avoid the didSet clearing our selections
        // Only enable if we have windows to track and mode is not already enabled
        if !currentVisibleWindowIDs.isEmpty && !isSelectiveGridMode {
            isSelectiveGridMode = true
        }

        // Add new windows to overlay selection
        for window in visibleWindows {
            if !visibilityBasedWindowIDs.contains(window.id) {
                // This is a newly visible window (or wasn't tracked before)
                selectedWindowsForOverlay.insert(window.id)
                visibilityBasedWindowIDs.insert(window.id)
                DeskJigLog.info(.window, "OverlayWindowManager: Added visibility-based overlay for '\(window.windowTitle)'")
            }
        }

        // Remove windows that no longer meet the threshold
        let windowsToRemove = visibilityBasedWindowIDs.subtracting(currentVisibleWindowIDs)
        for windowID in windowsToRemove {
            selectedWindowsForOverlay.remove(windowID)
            visibilityBasedWindowIDs.remove(windowID)
            DeskJigLog.info(.window, "OverlayWindowManager: Removed visibility-based overlay for window ID \(windowID) (no longer meets visibility threshold)")
        }

        // Update overlays
        if isSelectiveGridMode {
            updateSelectedWindowOverlays()
        }

        DeskJigLog.info(.window, "OverlayWindowManager: Visibility-based overlays updated. Tracking \(visibilityBasedWindowIDs.count) windows with overlays: \(Array(visibilityBasedWindowIDs))")
    }

    /// Clears all visibility-based overlays
    private func clearVisibilityBasedOverlays() {
        guard !visibilityBasedWindowIDs.isEmpty else { return }

        DeskJigLog.info(.window, "OverlayWindowManager: Clearing all visibility-based overlays (\(visibilityBasedWindowIDs.count) windows)")

        // Remove all tracked windows from overlay selection
        for windowID in visibilityBasedWindowIDs {
            selectedWindowsForOverlay.remove(windowID)
        }

        // Clear tracked set
        visibilityBasedWindowIDs.removeAll()

        // Disable selective mode if it was only used for visibility tracking
        if selectedWindowsForOverlay.isEmpty && isSelectiveGridMode {
            isSelectiveGridMode = false
        }

        // Update overlays
        if isSelectiveGridMode {
            updateSelectedWindowOverlays()
        }
    }

    deinit {
        removeAllOverlays()
        removeSelectedWindowOverlays()
        stopObservingWindowChanges()
        removeTopmostWindowHighlight()
        removeGlobalMouseMonitor()
        clearVisibilityBasedOverlays()
    }
}
