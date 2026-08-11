//
//  WindowSpaceHelper.swift
//  DeskJigShared
//
//  Created by Cursor on 08.01.2026.
//

import Foundation
import CoreGraphics

/// Helper class for space/screen detection logic, consolidating common operations
/// from various restoration handlers.
public class WindowSpaceHelper {
    
    // MARK: - Dependencies
    
    private let skyLightService: SkyLightService
    
    // MARK: - Initialization
    
    public init(skyLightService: SkyLightService = .shared) {
        self.skyLightService = skyLightService
    }
    
    // MARK: - Space Description
    
    /// Get a human-readable description of which Space a window is on
    /// Uses SkyLight if available, falls back to generic message if not
    /// - Parameters:
    ///   - windowID: The window ID to check (optional)
    ///   - processID: The process ID of the window's app (used for fallback enumeration if needed)
    /// - Returns: A description like "Desktop 2" or "another Space" if SkyLight unavailable
    public func getSpaceDescriptionForWindow(_ windowID: CGWindowID?, processID: pid_t) -> String {
        guard let windowID = windowID else {
            return "another Space"
        }

        // Try to get space info from SkyLight (with processID for fallback enumeration)
        guard let spaceID = skyLightService.getSpaceForWindow(windowID: windowID, processID: processID) else {
            return "another Space"
        }

        // Try to get the user-friendly space index
        let allSpaces = skyLightService.getUserSpaces()
        if let spaceIndex = allSpaces.firstIndex(where: { $0.id == spaceID }) {
            let desktopName = "Desktop \(spaceIndex + 1)"
            return desktopName
        }

        // Fallback: we know the space ID but not the friendly index
        return "Space \(spaceID)"
    }
    
    // MARK: - On-Screen Status
    
    /// Result of checking windows on-screen status for a process
    public struct WindowsOnScreenStatus {
        /// Window IDs found
        public let windowIDs: [CGWindowID]
        /// Whether any of these windows are on a currently visible space (any monitor)
        public let hasAnyOnVisibleSpace: Bool
        
        public init(windowIDs: [CGWindowID], hasAnyOnVisibleSpace: Bool) {
            self.windowIDs = windowIDs
            self.hasAnyOnVisibleSpace = hasAnyOnVisibleSpace
        }
    }
    
    /// Query CGWindowListCopyWindowInfo to check if any windows for a process are on a visible Space
    /// Uses .optionAll to get windows from ALL Spaces, then checks kCGWindowIsOnscreen
    /// - Parameter processID: The process ID to check
    /// - Returns: Status containing all window IDs and whether any are on the current visible space
    public func getWindowsOnScreenStatus(processID: pid_t) -> WindowsOnScreenStatus {
        guard let windowListInfo = CGWindowListCopyWindowInfo(
            [.optionAll, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else {
            return WindowsOnScreenStatus(windowIDs: [], hasAnyOnVisibleSpace: false)
        }

        var windowIDs: [CGWindowID] = []
        var hasAnyOnVisibleSpace = false

        for windowInfo in windowListInfo {
            guard let windowPID = windowInfo[kCGWindowOwnerPID as String] as? pid_t,
                  windowPID == processID,
                  let windowLayer = windowInfo[kCGWindowLayer as String] as? Int,
                  windowLayer == 0,
                  let windowNumber = windowInfo[kCGWindowNumber as String] as? Int,
                  let windowBounds = windowInfo[kCGWindowBounds as String] as? [String: Any] else {
                continue
            }

            let width = windowBounds["Width"] as? CGFloat ?? 0
            let height = windowBounds["Height"] as? CGFloat ?? 0

            // Skip very small windows
            if width <= 64 || height <= 64 {
                continue
            }

            let windowID = CGWindowID(windowNumber)
            // Optional: verify with SkyLight if needed, but CGWindowList is usually sufficient for presence
            
            windowIDs.append(windowID)

            // kCGWindowIsOnscreen indicates if window is on a currently visible space
            let isOnScreen = windowInfo[kCGWindowIsOnscreen as String] as? Bool ?? false
            if isOnScreen {
                hasAnyOnVisibleSpace = true
            } else {
                // Alternative: Use SkyLight for multi-monitor aware check
                if skyLightService.isWindowOnAnyVisibleSpace(windowID: windowID) {
                    hasAnyOnVisibleSpace = true
                }
            }
        }

        return WindowsOnScreenStatus(windowIDs: windowIDs, hasAnyOnVisibleSpace: hasAnyOnVisibleSpace)
    }
    
    // MARK: - Visibility Checks
    
    /// Checks if a specific window is on any visible space
    public func isWindowOnVisibleSpace(_ windowID: CGWindowID) -> Bool {
        return skyLightService.isWindowOnAnyVisibleSpace(windowID: windowID)
    }
}
