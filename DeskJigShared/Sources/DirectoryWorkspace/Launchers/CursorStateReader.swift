//  CursorStateReader.swift
//  DeskJigShared

import Foundation

// MARK: - CursorStateReader

/// Reads Cursor's internal state files from disk to get window-folder mappings.
///
/// Cursor stores window state in:
/// ~/Library/Application Support/Cursor/User/globalStorage/storage.json
///
/// The `windowsState` key contains:
/// - `lastActiveWindow`: The most recently active window
/// - `openedWindows`: Array of all open windows with folder paths and positions
public final class CursorStateReader {

    // MARK: - Types

    /// Represents a window entry from Cursor's state file
    public struct CursorWindowState: Codable {
        public let folder: String?  // file:// URL
        public let backupPath: String?
        public let uiState: UIState?

        public struct UIState: Codable {
            public let mode: Int?
            public let x: Int
            public let y: Int
            public let width: Int
            public let height: Int
        }

        /// Converts file:// URL to regular path
        public var folderPath: String? {
            guard let folder = folder else { return nil }

            // Remove file:// prefix and decode URL encoding
            if folder.hasPrefix("file://") {
                let withoutPrefix = String(folder.dropFirst(7))
                return withoutPrefix.removingPercentEncoding ?? withoutPrefix
            }
            return folder
        }

        /// Returns the frame as CGRect
        public var frame: CGRect? {
            guard let ui = uiState else { return nil }
            return CGRect(x: ui.x, y: ui.y, width: ui.width, height: ui.height)
        }
    }

    /// Complete windows state from storage.json
    public struct WindowsState: Codable {
        public let lastActiveWindow: CursorWindowState?
        public let openedWindows: [CursorWindowState]?
    }

    /// Root structure of storage.json (we only care about windowsState)
    private struct StorageJSON: Codable {
        let windowsState: WindowsState?
    }

    // MARK: - Properties

    /// Path to Cursor's storage.json
    private let storagePath: String

    // MARK: - Initialization

    public init() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        self.storagePath = "\(home)/Library/Application Support/Cursor/User/globalStorage/storage.json"
    }

    public init(storagePath: String) {
        self.storagePath = storagePath
    }

    // MARK: - Public API

    /// Reads the current window state from Cursor's storage.json
    /// Returns nil if the file can't be read or parsed
    public func readWindowsState() -> WindowsState? {
        guard FileManager.default.fileExists(atPath: storagePath) else {
            DeskJigLog.warn(.restorationExecutor, "CursorStateReader: storage.json not found at \(storagePath)")
            return nil
        }

        do {
            let data = try Data(contentsOf: URL(fileURLWithPath: storagePath))
            let storage = try JSONDecoder().decode(StorageJSON.self, from: data)

            if let state = storage.windowsState {
                let windowCount = (state.openedWindows?.count ?? 0) + (state.lastActiveWindow != nil ? 1 : 0)
                DeskJigLog.debug(.restorationExecutor, "CursorStateReader: Read \(windowCount) windows from storage.json")
            }

            return storage.windowsState
        } catch {
            DeskJigLog.error(.restorationExecutor, "CursorStateReader: Failed to read/parse storage.json: \(error)")
            return nil
        }
    }

    /// Gets all unique window states (combines lastActiveWindow and openedWindows)
    public func getAllWindowStates() -> [CursorWindowState] {
        guard let state = readWindowsState() else { return [] }

        var windows: [CursorWindowState] = []

        // Add opened windows
        if let opened = state.openedWindows {
            windows.append(contentsOf: opened)
        }

        // Add last active if not already in list (by folder path)
        if let last = state.lastActiveWindow,
           let lastPath = last.folderPath,
           !windows.contains(where: { $0.folderPath == lastPath }) {
            windows.append(last)
        }

        return windows
    }

    /// Finds window state for a specific directory path
    /// Returns the window state if found, with position info
    public func findWindowState(forDirectory path: String) -> CursorWindowState? {
        let normalizedPath = normalizePath(path)
        let windows = getAllWindowStates()

        // Exact match first
        if let exact = windows.first(where: {
            guard let folderPath = $0.folderPath else { return false }
            return normalizePath(folderPath) == normalizedPath
        }) {
            DeskJigLog.debug(.restorationExecutor, "CursorStateReader: Found exact match for '\(path)'")
            return exact
        }

        // No match
        DeskJigLog.debug(.restorationExecutor, "CursorStateReader: No match found for '\(path)'")
        return nil
    }

    // MARK: - Private Helpers

    private func normalizePath(_ path: String) -> String {
        let expanded = (path as NSString).expandingTildeInPath
        let url = URL(fileURLWithPath: expanded).standardized
        return url.path
    }
}
