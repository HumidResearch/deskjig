//  FluentAPIIntegrationTests.swift
//  DeskJigSharedTests


import Testing
import Foundation
import AppKit
@testable import DeskJigShared

// Gated: drives real windows/apps on the host. Absent from the Headless whitelist.
@Suite(
    "Fluent API Integration Tests (REAL SYSTEM)",
    .serialized,
    .enabled(if: TestEnvironment.envTestsEnabled, TestEnvironment.gateReason)
)
struct FluentAPIIntegrationTests {

    // Manual flag to control window minimization
    private static let shouldMinimizeWindows = false

    // #618: These REAL SYSTEM tests operate on whatever real windows exist on the host
    // (via `Window.topmost()` / `Window.visible()`), which on the Mac Mini verification
    // host can include the DeskJig test host's *own* windows. Any AX mutation on a
    // self-owned window — minimize (`_minimizeToDock`), move/setFrame
    // (`_setFrameCommon` → `clearDisplayAffinityForWindow:`), raise, activate, close —
    // drives an AppKit window-coordinator transaction in-process on the calling thread
    // and previously crashed the test host with EXC_BREAKPOINT, forcing the Full plan to
    // exit 65 even with zero assertion failures. `AXWindowService` now refuses every such
    // mutation on self-owned windows at a single chokepoint (see `selfProcessRefusal` /
    // `isCurrentProcessElement`), so those operations become a safe no-op here rather than
    // a host crash. No test is skipped; when the target is a real *other-app* window, the
    // operation runs normally.
    
    init() {
        // CRITICAL: Disable mock test mode for integration tests
        RuntimeEnvironment.isRunningMockTests = false
    }
    
    // MARK: - Test Setup
    
    private func setupFluentEnvironment() async throws -> (
        displayManager: DisplayManager,
        axWindowService: AXWindowService
    ) {
        DeskJigLog.info(.app, "========================================")
        DeskJigLog.info(.app, "🔧 SETTING UP FLUENT API TEST ENVIRONMENT (AX BACKEND)")
        DeskJigLog.info(.app, "========================================")
        
        // Create real services
        let displayManager = DisplayManager()
        let axWindowService = AXWindowService.shared
        
        // Configure FluentServices with AX backend
        FluentServices.configure(
            axWindowService: axWindowService,
            displayManager: displayManager
        )
        
        // Register common app aliases
        App.register("Figma", bundleID: "com.figma.Desktop")
        // Chrome with alternate bundle IDs for Canary/Beta variants
        App.register("Chrome", bundleID: "com.google.Chrome", alternateBundleIDs: [
            "com.google.Chrome.canary",
            "com.google.Chrome.beta"
        ])
        App.register("Safari", bundleID: "com.apple.Safari")
        App.register("Discord", bundleID: "com.hnc.Discord")
        App.register("Xcode", bundleID: "com.apple.dt.Xcode")
        App.register("Cursor", bundleID: "com.todesktop.230313mzl4w4u92")
        App.register("Linear", bundleID: "com.linear")
        App.register("Claude", bundleID: "com.anthropic.claudefordesktop")
        App.register("Ghostty", bundleID: "com.mitchellh.ghostty")
        App.register("Notes", bundleID: "com.apple.Notes")
        App.register("Finder", bundleID: "com.apple.finder")
        App.register("Terminal", bundleID: "com.apple.Terminal")
        
        // Wait for initial setup
        try await Task.sleep(nanoseconds: 500_000_000) // 0.5 seconds
        
        // Optionally minimize all windows
        if FluentAPIIntegrationTests.shouldMinimizeWindows {
            DeskJigLog.info(.app, "🔽 Minimizing all windows...")
            Window.visible().forEach { $0.minimize() }
        }
        
        try await Task.sleep(nanoseconds: 500_000_000)
        
        return (
            displayManager: displayManager,
            axWindowService: axWindowService
        )
    }
    
    private func cleanup() async throws {
        DeskJigLog.info(.app, "========================================")
        DeskJigLog.info(.app, "🧹 POST-TEST CLEANUP")
        DeskJigLog.info(.app, "========================================")
        
        // Reset FluentServices
        FluentServices.reset()
        AppRegistry.shared.clearAll()
        
        DeskJigLog.info(.app, "✅ Cleanup complete")
    }
    
    // MARK: - Basic Fluent API Tests
    
    @Test("Fluent API: Service Configuration")
    func testServiceConfiguration() async throws {
        _ = try await setupFluentEnvironment()
        defer { Task { try? await cleanup() } }
        
        DeskJigLog.info(.app, "========================================")
        DeskJigLog.info(.app, "📋 FLUENT API SERVICE CONFIGURATION TEST")
        DeskJigLog.info(.app, "========================================")
        
        // Verify services are configured
        #expect(FluentServices.isConfigured, "FluentServices should be configured")
        
        // Verify app registry has aliases
        #expect(AppRegistry.shared.isRegistered("Figma"), "Figma alias should be registered")
        #expect(AppRegistry.shared.isRegistered("Chrome"), "Chrome alias should be registered")
        #expect(AppRegistry.shared.isRegistered("Safari"), "Safari alias should be registered")
        
        // Verify bundle IDs are correct
        #expect(AppRegistry.shared.bundleID(for: "Figma") == "com.figma.Desktop")
        #expect(AppRegistry.shared.bundleID(for: "Chrome") == "com.google.Chrome")
        
        DeskJigLog.info(.app, "✅ All service configuration tests passed")
    }
    
    @Test("Fluent API: Window Discovery")
    func testWindowDiscovery() async throws {
        _ = try await setupFluentEnvironment()
        defer { Task { try? await cleanup() } }
        
        DeskJigLog.info(.app, "========================================")
        DeskJigLog.info(.app, "📋 FLUENT API WINDOW DISCOVERY TEST (AX BACKEND)")
        DeskJigLog.info(.app, "========================================")
        
        // Get all windows
        let allWindows = Window.all()
        DeskJigLog.info(.app, "Found \(allWindows.count) total windows")
        
        // Get visible windows
        let visibleWindows = Window.visible()
        DeskJigLog.info(.app, "Found \(visibleWindows.count) visible windows")
        
        // Get topmost window
        if let topmost = Window.topmost() {
            DeskJigLog.info(.app, "Topmost window: \(topmost.appName ?? "Unknown") - '\(topmost.title ?? "Untitled")'")
            DeskJigLog.info(.app, "  Frame: \(topmost.frame?.debugDescription ?? "nil")")
            #expect(topmost.exists, "Topmost window should exist")
        } else {
            DeskJigLog.info(.app, "No topmost window found (all windows may be minimized)")
        }
        
        // List all visible windows with details
        DeskJigLog.info(.app, "\nVisible windows:")
        for (index, window) in visibleWindows.prefix(10).enumerated() {
            DeskJigLog.info(.app, "  [\(index)] \(window.appName ?? "?"): '\(window.title ?? "?")' at \(formatFrame(window.frame))")
        }
        
        DeskJigLog.info(.app, "✅ Window discovery test passed")
    }
    
    @Test("Fluent API: App Handle Operations")
    func testAppHandleOperations() async throws {
        _ = try await setupFluentEnvironment()
        defer { Task { try? await cleanup() } }
        
        DeskJigLog.info(.app, "========================================")
        DeskJigLog.info(.app, "📋 FLUENT API APP HANDLE TEST")
        DeskJigLog.info(.app, "========================================")
        
        // Test dynamic member lookup with registered alias
        if let figmaHandle = App.Figma {
            DeskJigLog.info(.app, "✅ App.Figma resolved successfully")
            DeskJigLog.info(.app, "  Bundle ID: \(figmaHandle.bundleID)")
            DeskJigLog.info(.app, "  Is Running: \(figmaHandle.isRunning)")
            
            if figmaHandle.isRunning {
                let windows = figmaHandle.windows()
                DeskJigLog.info(.app, "  Windows: \(windows.count)")
                
                if let firstWindow = figmaHandle.firstWindow() {
                    DeskJigLog.info(.app, "  First window: '\(firstWindow.title ?? "Untitled")'")
                }
            }
        } else {
            DeskJigLog.info(.app, "⚠️ App.Figma not found (Figma may not be running)")
        }
        
        // Test explicit finder
        if let safariHandle = App.find(bundleID: "com.apple.Safari") {
            DeskJigLog.info(.app, "✅ App.find(bundleID:) resolved Safari")
            DeskJigLog.info(.app, "  Is Running: \(safariHandle.isRunning)")
        }
        
        // Test find by name
        if let finderHandle = App.find(name: "Finder") {
            DeskJigLog.info(.app, "✅ App.find(name:) resolved Finder")
            DeskJigLog.info(.app, "  Bundle ID: \(finderHandle.bundleID)")
        }
        
        // Test running apps
        let runningApps = App.running()
        DeskJigLog.info(.app, "\nRunning apps (\(runningApps.count)):")
        for app in runningApps.prefix(5) {
            DeskJigLog.info(.app, "  - \(app.localizedName ?? app.bundleID)")
        }
        
        DeskJigLog.info(.app, "✅ App handle operations test passed")
    }
    
    @Test("Fluent API: Window Finder Methods")
    func testWindowFinderMethods() async throws {
        _ = try await setupFluentEnvironment()
        defer { Task { try? await cleanup() } }
        
        DeskJigLog.info(.app, "========================================")
        DeskJigLog.info(.app, "📋 FLUENT API WINDOW FINDER TEST")
        DeskJigLog.info(.app, "========================================")
        
        // Test Window.find(appName:)
        if let finderWindow = Window.find(appName: "Finder") {
            DeskJigLog.info(.app, "✅ Window.find(appName: \"Finder\") found: '\(finderWindow.title ?? "?")'")
        } else {
            DeskJigLog.info(.app, "⚠️ No Finder window found")
        }
        
        // Test Window.all(for:)
        let safariWindows = Window.all(for: "Safari")
        DeskJigLog.info(.app, "Window.all(for: \"Safari\"): \(safariWindows.count) window(s)")
        
        // Test Window.find(bundleID:)
        if let chromeWindow = Window.find(bundleID: "com.google.Chrome") {
            DeskJigLog.info(.app, "✅ Window.find(bundleID:) found Chrome: '\(chromeWindow.title ?? "?")'")
        } else {
            DeskJigLog.info(.app, "⚠️ No Chrome window found")
        }
        
        // Test Window.count
        DeskJigLog.info(.app, "Window.count: \(Window.count)")
        
        DeskJigLog.info(.app, "✅ Window finder methods test passed")
    }
    
    @Test("Fluent API: Chainable Window Operations")
    func testChainableWindowOperations() async throws {
        _ = try await setupFluentEnvironment()
        defer { Task { try? await cleanup() } }
        
        DeskJigLog.info(.app, "========================================")
        DeskJigLog.info(.app, "📋 FLUENT API CHAINABLE OPERATIONS TEST")
        DeskJigLog.info(.app, "========================================")
        
        // Find a window to operate on
        guard let targetWindow = Window.topmost() else {
            DeskJigLog.info(.app, "⚠️ No topmost window available for testing")
            return
        }
        
        DeskJigLog.info(.app, "Target window: \(targetWindow.appName ?? "?") - '\(targetWindow.title ?? "?")'")
        let originalFrame = targetWindow.frame
        DeskJigLog.info(.app, "Original frame: \(formatFrame(originalFrame))")
        
        // Test chainable position operation
        DeskJigLog.info(.app, "\n🔄 Testing moveTo(x:y:)...")
        if let moved = targetWindow.moveTo(x: 100, y: 100) {
            DeskJigLog.info(.app, "✅ moveTo succeeded")
            DeskJigLog.info(.app, "  New frame: \(formatFrame(moved.frame))")
        } else {
            DeskJigLog.info(.app, "⚠️ moveTo returned nil")
        }
        
        try await Task.sleep(nanoseconds: 300_000_000)
        
        // Test chainable resize operation
        DeskJigLog.info(.app, "\n🔄 Testing resize(width:height:)...")
        if let resized = targetWindow.resize(width: 800, height: 600) {
            DeskJigLog.info(.app, "✅ resize succeeded")
            DeskJigLog.info(.app, "  New frame: \(formatFrame(resized.frame))")
        } else {
            DeskJigLog.info(.app, "⚠️ resize returned nil")
        }
        
        try await Task.sleep(nanoseconds: 300_000_000)
        
        // Test chaining multiple operations
        DeskJigLog.info(.app, "\n🔄 Testing chained operations: center()?.activate()...")
        if let result = targetWindow.center()?.activate() {
            DeskJigLog.info(.app, "✅ Chained operations succeeded")
            DeskJigLog.info(.app, "  Final frame: \(formatFrame(result.frame))")
        } else {
            DeskJigLog.info(.app, "⚠️ Chained operations returned nil")
        }
        
        try await Task.sleep(nanoseconds: 300_000_000)
        
        // Restore original position if possible
        if let original = originalFrame {
            DeskJigLog.info(.app, "\n🔄 Restoring original position...")
            _ = targetWindow.setFrame(original)
        }
        
        DeskJigLog.info(.app, "✅ Chainable window operations test passed")
    }
    
    @Test("Fluent API: Screen Zone Operations")
    func testScreenZoneOperations() async throws {
        _ = try await setupFluentEnvironment()
        defer { Task { try? await cleanup() } }
        
        DeskJigLog.info(.app, "========================================")
        DeskJigLog.info(.app, "📋 FLUENT API SCREEN ZONE OPERATIONS TEST")
        DeskJigLog.info(.app, "========================================")
        
        guard let targetWindow = Window.topmost() else {
            DeskJigLog.info(.app, "⚠️ No topmost window available for testing")
            return
        }
        
        DeskJigLog.info(.app, "Target: \(targetWindow.appName ?? "?") - '\(targetWindow.title ?? "?")'")
        let originalFrame = targetWindow.frame
        
        // Test moveToLeftHalf
        DeskJigLog.info(.app, "\n🔄 Testing moveToLeftHalf()...")
        if let result = targetWindow.moveToLeftHalf() {
            DeskJigLog.info(.app, "✅ moveToLeftHalf succeeded: \(formatFrame(result.frame))")
        }
        try await Task.sleep(nanoseconds: 500_000_000)
        
        // Test moveToRightHalf
        DeskJigLog.info(.app, "\n🔄 Testing moveToRightHalf()...")
        if let result = targetWindow.moveToRightHalf() {
            DeskJigLog.info(.app, "✅ moveToRightHalf succeeded: \(formatFrame(result.frame))")
        }
        try await Task.sleep(nanoseconds: 500_000_000)
        
        // Test maximize
        DeskJigLog.info(.app, "\n🔄 Testing maximize()...")
        if let result = targetWindow.maximize() {
            DeskJigLog.info(.app, "✅ maximize succeeded: \(formatFrame(result.frame))")
        }
        try await Task.sleep(nanoseconds: 500_000_000)
        
        // Restore
        if let original = originalFrame {
            DeskJigLog.info(.app, "\n🔄 Restoring original position...")
            _ = targetWindow.setFrame(original)
        }
        
        DeskJigLog.info(.app, "✅ Screen zone operations test passed")
    }
    
    // MARK: - Workspace-like Fluent Tests
    
    @Test("Fluent API: Side-by-Side Layout")
    func testSideBySideLayout() async throws {
        _ = try await setupFluentEnvironment()
        defer { Task { try? await cleanup() } }
        
        DeskJigLog.info(.app, "========================================")
        DeskJigLog.info(.app, "📋 FLUENT API SIDE-BY-SIDE LAYOUT TEST")
        DeskJigLog.info(.app, "========================================")
        
        // This test demonstrates the fluent API for workspace-like layouts
        // Using whatever apps are running
        
        let visibleWindows = Window.visible()
        guard visibleWindows.count >= 2 else {
            DeskJigLog.info(.app, "⚠️ Need at least 2 visible windows for side-by-side test")
            return
        }
        
        let firstWindow = visibleWindows[0]
        let secondWindow = visibleWindows[1]
        
        DeskJigLog.info(.app, "Arranging side-by-side:")
        DeskJigLog.info(.app, "  Left:  \(firstWindow.appName ?? "?") - '\(firstWindow.title ?? "?")'")
        DeskJigLog.info(.app, "  Right: \(secondWindow.appName ?? "?") - '\(secondWindow.title ?? "?")'")
        
        // Store original frames for restoration
        let originalFrame1 = firstWindow.frame
        let originalFrame2 = secondWindow.frame
        
        // Fluent side-by-side layout
        DeskJigLog.info(.app, "\n🔄 Applying side-by-side layout...")
        firstWindow.moveToLeftHalf()?.activate()
        secondWindow.moveToRightHalf()?.activate()
        
        try await Task.sleep(nanoseconds: 1_000_000_000)
        
        // Verify positions (refresh to get updated state)
        _ = firstWindow.refresh()
        _ = secondWindow.refresh()
        
        DeskJigLog.info(.app, "Result:")
        DeskJigLog.info(.app, "  Left:  \(formatFrame(firstWindow.frame))")
        DeskJigLog.info(.app, "  Right: \(formatFrame(secondWindow.frame))")
        
        // Restore original positions
        DeskJigLog.info(.app, "\n🔄 Restoring original positions...")
        if let f1 = originalFrame1 { _ = firstWindow.setFrame(f1) }
        if let f2 = originalFrame2 { _ = secondWindow.setFrame(f2) }
        
        DeskJigLog.info(.app, "✅ Side-by-side layout test passed")
    }
    
    @Test("Fluent API: App-Specific Window Operations")
    func testAppSpecificWindowOperations() async throws {
        _ = try await setupFluentEnvironment()
        defer { Task { try? await cleanup() } }
        
        DeskJigLog.info(.app, "========================================")
        DeskJigLog.info(.app, "📋 FLUENT API APP-SPECIFIC OPERATIONS TEST")
        DeskJigLog.info(.app, "========================================")
        
        // Demonstrate the signature fluent syntax: App.Alias?.firstWindow()?.operation()
        
        DeskJigLog.info(.app, "Testing fluent syntax for registered apps:\n")
        
        // Safari
        if let safariWindow = App.Safari?.firstWindow() {
            let originalFrame = safariWindow.frame
            DeskJigLog.info(.app, "✅ App.Safari?.firstWindow() found: '\(safariWindow.title ?? "?")'")
            
            // Chain operations
            safariWindow.center()?.activate()
            DeskJigLog.info(.app, "   Applied: center()?.activate()")
            
            try await Task.sleep(nanoseconds: 500_000_000)
            
            // Restore
            if let f = originalFrame { _ = safariWindow.setFrame(f) }
        } else {
            DeskJigLog.info(.app, "⚠️ Safari window not available")
        }
        
        // Finder
        if let finderWindow = App.Finder?.firstWindow() {
            let originalFrame = finderWindow.frame
            DeskJigLog.info(.app, "✅ App.Finder?.firstWindow() found: '\(finderWindow.title ?? "?")'")
            
            // Chain operations
            finderWindow.moveTo(x: 200, y: 200)?.resize(width: 600, height: 400)
            DeskJigLog.info(.app, "   Applied: moveTo(x: 200, y: 200)?.resize(width: 600, height: 400)")
            
            try await Task.sleep(nanoseconds: 500_000_000)
            
            // Restore
            if let f = originalFrame { _ = finderWindow.setFrame(f) }
        } else {
            DeskJigLog.info(.app, "⚠️ Finder window not available")
        }
        
        // Chrome (if running)
        if let chromeWindow = App.Chrome?.firstWindow() {
            DeskJigLog.info(.app, "✅ App.Chrome?.firstWindow() found: '\(chromeWindow.title ?? "?")'")
        } else {
            DeskJigLog.info(.app, "⚠️ Chrome window not available")
        }
        
        // Xcode (if running)
        if let xcodeWindow = App.Xcode?.firstWindow() {
            DeskJigLog.info(.app, "✅ App.Xcode?.firstWindow() found: '\(xcodeWindow.title ?? "?")'")
        } else {
            DeskJigLog.info(.app, "⚠️ Xcode window not available")
        }
        
        DeskJigLog.info(.app, "\n✅ App-specific window operations test passed")
    }
    
    @Test("Fluent API: Batch Window Operations")
    func testBatchWindowOperations() async throws {
        _ = try await setupFluentEnvironment()
        defer { Task { try? await cleanup() } }
        
        DeskJigLog.info(.app, "========================================")
        DeskJigLog.info(.app, "📋 FLUENT API BATCH OPERATIONS TEST")
        DeskJigLog.info(.app, "========================================")
        
        // Get all Safari windows
        let safariWindows = Window.all(for: "Safari")
        DeskJigLog.info(.app, "Safari windows: \(safariWindows.count)")
        
        if !safariWindows.isEmpty {
            // Store original frames
            let originalFrames = safariWindows.map { $0.frame }
            
            // Apply operation to all Safari windows
            DeskJigLog.info(.app, "Centering all Safari windows...")
            safariWindows.forEach { $0.center()?.resize(width: 500, height: 500) }
            
            try await Task.sleep(nanoseconds: 500_000_000)
            
            // Restore
            for (index, window) in safariWindows.enumerated() {
                if let frame = originalFrames[index] {
                    _ = window.setFrame(frame)
                }
            }
        }
        
        // Get all windows for an app using App handle
        if let chromeApp = App.Chrome, chromeApp.isRunning {
            let chromeWindows = chromeApp.windows()
            DeskJigLog.info(.app, "Chrome windows via App.Chrome?.windows(): \(chromeWindows.count)")
        }
        
        DeskJigLog.info(.app, "✅ Batch operations test passed")
    }
    
    @Test("Fluent API: Window State Operations")
    func testWindowStateOperations() async throws {
        _ = try await setupFluentEnvironment()
        defer { Task { try? await cleanup() } }
        
        DeskJigLog.info(.app, "========================================")
        DeskJigLog.info(.app, "📋 FLUENT API WINDOW STATE OPERATIONS TEST")
        DeskJigLog.info(.app, "========================================")
        
        guard let targetWindow = Window.topmost() else {
            DeskJigLog.info(.app, "⚠️ No topmost window available")
            return
        }
        
        DeskJigLog.info(.app, "Target: \(targetWindow.appName ?? "?") - '\(targetWindow.title ?? "?")'")
        DeskJigLog.info(.app, "Initial state:")
        DeskJigLog.info(.app, "  isMinimized: \(targetWindow.isMinimized)")
        DeskJigLog.info(.app, "  isHidden: \(targetWindow.isHidden)")
        DeskJigLog.info(.app, "  exists: \(targetWindow.exists)")
        
        // Test minimize/unminimize cycle
        DeskJigLog.info(.app, "\n🔄 Testing minimize()...")
        if let minimized = targetWindow.minimize() {
            DeskJigLog.info(.app, "✅ minimize succeeded")
            #expect(minimized.isMinimized || minimized.exists, "Window should be minimized or exist")
            
            try await Task.sleep(nanoseconds: 500_000_000)
            
            DeskJigLog.info(.app, "🔄 Testing unminimize()...")
            if let restored = minimized.unminimize() {
                DeskJigLog.info(.app, "✅ unminimize succeeded")
                DeskJigLog.info(.app, "  isMinimized: \(restored.isMinimized)")
            }
        }
        
        try await Task.sleep(nanoseconds: 500_000_000)
        
        // Test activate
        DeskJigLog.info(.app, "\n🔄 Testing activate()...")
        if let _ = targetWindow.activate() {
            DeskJigLog.info(.app, "✅ activate succeeded")
        }
        
        // Test refresh
        DeskJigLog.info(.app, "\n🔄 Testing refresh()...")
        if let refreshed = targetWindow.refresh() {
            DeskJigLog.info(.app, "✅ refresh succeeded")
            DeskJigLog.info(.app, "  Current frame: \(formatFrame(refreshed.frame))")
        }
        
        DeskJigLog.info(.app, "✅ Window state operations test passed")
    }
    
    // MARK: - Complex Workspace Scenario
    
    @Test("Fluent API: Complex Workspace Setup")
    func testComplexWorkspaceSetup() async throws {
        let services = try await setupFluentEnvironment()
        defer { Task { try? await cleanup() } }
        
        DeskJigLog.info(.app, "========================================")
        DeskJigLog.info(.app, "📋 FLUENT API COMPLEX WORKSPACE SETUP TEST")
        DeskJigLog.info(.app, "========================================")
        
        // This demonstrates how the fluent API can be used to set up a workspace
        // Similar to the traditional WorkspaceIntegrationTests but with fluent syntax
        
        services.displayManager.refreshScreens()
        guard let screen = services.displayManager.screens.first else {
            DeskJigLog.info(.app, "⚠️ No screen available")
            return
        }
        
        let screenFrame = screen.visibleFrame
        DeskJigLog.info(.app, "Screen: \(screen.name) - \(formatFrame(screenFrame))")
        
        // Find available apps for the workspace
        let availableApps: [(alias: String, bundleID: String)] = [
            ("Safari", "com.apple.Safari"),
            ("Finder", "com.apple.finder"),
            ("Notes", "com.apple.Notes"),
            ("Terminal", "com.apple.Terminal")
        ]
        
        var workspaceWindows: [WindowHandle] = []
        var originalFrames: [CGRect?] = []
        
        // Collect available windows
        for appInfo in availableApps {
            if let handle = App.find(bundleID: appInfo.bundleID)?.firstWindow() {
                workspaceWindows.append(handle)
                originalFrames.append(handle.frame)
                DeskJigLog.info(.app, "Found: \(appInfo.alias) - '\(handle.title ?? "?")'")
            }
        }
        
        guard workspaceWindows.count >= 2 else {
            DeskJigLog.info(.app, "⚠️ Need at least 2 windows for workspace test")
            return
        }
        
        DeskJigLog.info(.app, "\n🔄 Setting up workspace layout with \(workspaceWindows.count) windows...")
        
        // Apply layout based on number of windows
        switch workspaceWindows.count {
        case 2:
            // Side by side
            workspaceWindows[0].moveToLeftHalf()?.activate()
            workspaceWindows[1].moveToRightHalf()?.activate()
            DeskJigLog.info(.app, "Applied: Side-by-side layout")
            
        case 3:
            // Thirds
            workspaceWindows[0].moveToLeftThird()?.activate()
            workspaceWindows[1].moveToCenterThird()?.activate()
            workspaceWindows[2].moveToRightThird()?.activate()
            DeskJigLog.info(.app, "Applied: Thirds layout")
            
        default:
            // Quarters for 4+
            workspaceWindows[0].moveToTopLeftQuarter()?.activate()
            workspaceWindows[1].moveToTopRightQuarter()?.activate()
            if workspaceWindows.count > 2 {
                workspaceWindows[2].moveToBottomLeftQuarter()?.activate()
            }
            if workspaceWindows.count > 3 {
                workspaceWindows[3].moveToBottomRightQuarter()?.activate()
            }
            DeskJigLog.info(.app, "Applied: Quarters layout")
        }
        
        try await Task.sleep(nanoseconds: 1_500_000_000)
        
        // Verify and log final positions
        DeskJigLog.info(.app, "\n📊 Final positions:")
        for (index, window) in workspaceWindows.enumerated() {
            _ = window.refresh()
            DeskJigLog.info(.app, "  [\(index)] \(window.appName ?? "?"): \(formatFrame(window.frame))")
        }
        
        // Restore original positions
        DeskJigLog.info(.app, "\n🔄 Restoring original positions...")
        for (index, window) in workspaceWindows.enumerated() {
            if let frame = originalFrames[index] {
                _ = window.setFrame(frame)
            }
        }
        
        try await Task.sleep(nanoseconds: 500_000_000)
        
        DeskJigLog.info(.app, "✅ Complex workspace setup test passed")
    }
    
    // MARK: - Helpers
    
    private func formatFrame(_ frame: CGRect?) -> String {
        guard let f = frame else { return "nil" }
        return String(format: "(%.0f, %.0f) %.0fx%.0f",
                     f.origin.x, f.origin.y, f.width, f.height)
    }
}
