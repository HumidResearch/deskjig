//  VSCodeStateReader.swift
//  DeskJigShared

import Foundation

public final class VSCodeStateReader {
    public struct WindowState {
        public let folderURI: String?
        public let workspaceConfigURI: String?
    }

    private let storagePath: String

    public init(bundleID: String = OpenByPathBundleIdentifiers.vscode) {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let appSupportFolder: String
        switch bundleID {
        case OpenByPathBundleIdentifiers.vscode:
            appSupportFolder = "Code"
        default:
            appSupportFolder = "Code"
        }
        self.storagePath = "\(home)/Library/Application Support/\(appSupportFolder)/User/globalStorage/storage.json"
    }

    public func findWindowState(forDirectory path: String) -> WindowState? {
        let normalizedPath = URL(fileURLWithPath: path).standardizedFileURL.path
        let targetURI = URL(fileURLWithPath: normalizedPath).absoluteString

        let windows = readState()
        for window in windows {
            if window.folderURI == targetURI {
                return window
            }
            if window.workspaceConfigURI == targetURI {
                return window
            }
        }

        return nil
    }

    public func hasWindow(forDirectory path: String) -> Bool {
        return findWindowState(forDirectory: path) != nil
    }

    private func readState() -> [WindowState] {
        guard FileManager.default.fileExists(atPath: storagePath) else {
            DeskJigLog.warn(.workspace, "VSCodeStateReader: storage.json not found at \(storagePath)")
            return []
        }

        do {
            let data = try Data(contentsOf: URL(fileURLWithPath: storagePath))
            let json = try JSONSerialization.jsonObject(with: data, options: [])
            let windows = collectWindows(from: json)
            DeskJigLog.debug(.workspace, "VSCodeStateReader: Read \(windows.count) window entries from storage.json")
            return windows
        } catch {
            DeskJigLog.error(.workspace, "VSCodeStateReader: Failed to read/parse storage.json: \(error)")
            return []
        }
    }

    private func collectWindows(from object: Any) -> [WindowState] {
        var results: [WindowState] = []

        if let dict = object as? [String: Any] {
            if let opened = dict["openedWindows"] as? [[String: Any]] {
                results.append(contentsOf: opened.compactMap(windowState(from:)))
            }
            if let lastActive = dict["lastActiveWindow"] as? [String: Any],
               let state = windowState(from: lastActive) {
                results.append(state)
            }
            for value in dict.values {
                results.append(contentsOf: collectWindows(from: value))
            }
        } else if let array = object as? [Any] {
            for item in array {
                results.append(contentsOf: collectWindows(from: item))
            }
        }

        return results
    }

    private func windowState(from dict: [String: Any]) -> WindowState? {
        let folderURI = dict["folder"] as? String ?? dict["folderUri"] as? String

        var workspaceConfigURI: String?
        if let workspaceIdentifier = dict["workspaceIdentifier"] as? [String: Any] {
            workspaceConfigURI = workspaceIdentifier["configURIPath"] as? String
        }

        if folderURI == nil && workspaceConfigURI == nil {
            return nil
        }

        return WindowState(folderURI: folderURI, workspaceConfigURI: workspaceConfigURI)
    }
}
