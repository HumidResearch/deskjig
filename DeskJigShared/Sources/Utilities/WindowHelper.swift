//
//  WindowHelper.swift
//  DeskJigShared
//

import AppKit

/// Helper utilities for managing NSWindow instances in macOS apps
public enum WindowHelper {

    /// Finds the best available window for presenting sheets and modals.
    ///
    /// This function handles apps with custom NSPanel architectures where `NSApplication.shared.keyWindow`
    /// may return nil. It attempts to find a suitable window in the following order:
    /// 1. Regular NSWindow (not NSPanel)
    /// 2. Current key window if available
    /// 3. First visible NSPanel (for custom panel-based apps)
    /// 4. Any window (as last resort)
    ///
    /// - Returns: An NSWindow suitable for presenting sheets, or nil if no window is available
    public static func findPresentingWindow() -> NSWindow? {
        let windows = NSApplication.shared.windows

        // First, try to find a regular NSWindow (not NSPanel or special system windows).
        // NSStatusBarWindow and other special windows cannot be used as presentation anchors.
        if let regularWindow = windows.first(where: { window in
            let className = String(describing: type(of: window))
            let isSpecialWindow = className.contains("StatusBar") ||
                                  className.contains("Carbon") ||
                                  className.contains("Popup")
            return !(window is NSPanel) &&
                   !isSpecialWindow &&
                   window.isVisible &&
                   !window.isSheet
        }) {
            DeskJigLog.info(.window, "Using regular NSWindow (preferred): \(regularWindow)")
            return regularWindow
        }

        // Try the key window
        if let keyWindow = NSApplication.shared.keyWindow {
            DeskJigLog.info(.window, "Using key window: \(keyWindow) (type: \(type(of: keyWindow)))")
            return keyWindow
        }

        DeskJigLog.info(.window, "No key window or regular window found, searching through all windows...")

        // Try to find a visible NSPanel (for custom panel architectures)
        if let panel = windows.first(where: { window in
            window is NSPanel && window.isVisible && !window.isSheet
        }) {
            DeskJigLog.info(.window, "Found visible NSPanel: \(panel)")
            return panel
        }

        // Try to find any visible window that's not a sheet
        if let visibleWindow = windows.first(where: { window in
            window.isVisible && !window.isSheet
        }) {
            DeskJigLog.info(.window, "Found visible NSWindow: \(visibleWindow)")
            return visibleWindow
        }

        // Last resort: return any window
        if let anyWindow = windows.first {
            DeskJigLog.info(.window, "Using first available window (may not be visible): \(anyWindow)")
            return anyWindow
        }

        DeskJigLog.error(.window, "No windows available for presenting")
        return nil
    }

    /// Ensures a window is ready to present sheets by making it key and ordered front if needed.
    ///
    /// - Parameter window: The window to prepare
    /// - Returns: The same window for chaining
    @discardableResult
    public static func prepareWindowForPresentation(_ window: NSWindow) -> NSWindow {
        if !window.isKeyWindow {
            DeskJigLog.info(.window, "Making window key and ordered front: \(window)")
            window.makeKeyAndOrderFront(nil)
        }
        return window
    }
}
