//
//  OpenByPathTitleAssigner.swift
//  DeskJigShared
//
//  Assigns stable <token>:{basename}:{index} titles for open-by-path terminal windows.
//  The token is the frozen legacy value in BundleIdentity.terminalTitleTokenPrefix.
//

import Foundation

public enum OpenByPathTitleAssigner {
    private struct GroupKey: Hashable {
        let bundleId: String
        let path: String
    }

    static let titleBundles: Set<String> = [
        OpenByPathBundleIdentifiers.ghostty,
        OpenByPathBundleIdentifiers.terminal,
        OpenByPathBundleIdentifiers.iterm2,
        OpenByPathBundleIdentifiers.kitty,
        OpenByPathBundleIdentifiers.alacritty
    ]

    static func supportsDynamicTitle(bundleId: String) -> Bool {
        titleBundles.contains(bundleId)
    }

    public static func apply(to windows: [WorkspaceWindow]) -> [WorkspaceWindow] {
        guard !windows.isEmpty else { return windows }

        var usedIndices: [GroupKey: Set<Int>] = [:]
        var assignedIndices: [UUID: Int] = [:]

        for window in windows {
            guard titleBundles.contains(window.bundleIdentifier),
                  let path = normalizeOpenPath(window.openPath) else { continue }
            let basename = URL(fileURLWithPath: path).lastPathComponent
            let key = GroupKey(bundleId: window.bundleIdentifier, path: path)
            if let index = parseTitleIndex(from: window.windowTitle, basename: basename) {
                assignedIndices[window.id] = index
                usedIndices[key, default: []].insert(index)
            }
        }

        return windows.map { window in
            guard titleBundles.contains(window.bundleIdentifier),
                  let path = normalizeOpenPath(window.openPath) else { return window }

            let basename = URL(fileURLWithPath: path).lastPathComponent
            let key = GroupKey(bundleId: window.bundleIdentifier, path: path)

            let index: Int
            if let existing = assignedIndices[window.id] {
                index = existing
            } else {
                var used = usedIndices[key, default: []]
                var nextIndex = 0
                while used.contains(nextIndex) { nextIndex += 1 }
                used.insert(nextIndex)
                usedIndices[key] = used
                assignedIndices[window.id] = nextIndex
                index = nextIndex
            }

            let title = "\(BundleIdentity.terminalTitleTokenPrefix):\(basename):\(index)"
            if window.windowTitle == title { return window }
            return window.withWindowTitle(title)
        }
    }

    private static func parseTitleIndex(from title: String, basename: String) -> Int? {
        let prefix = "\(BundleIdentity.terminalTitleTokenPrefix):\(basename):"
        guard title.hasPrefix(prefix) else { return nil }
        return Int(title.dropFirst(prefix.count))
    }

    private static func normalizeOpenPath(_ path: String?) -> String? {
        guard let path else { return nil }
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let expanded = (trimmed as NSString).expandingTildeInPath
        return URL(fileURLWithPath: expanded).standardizedFileURL.path
    }
}
