//  QuickSwitchActionHandler.swift
//  DeskJigCLI

import Foundation
import DeskJigShared

final class QuickSwitchActionHandler: ActionHandler {
    private weak var executor: ActionExecutor?

    init(executor: ActionExecutor) {
        self.executor = executor
    }

    func canHandle(action: CLIAction) -> Bool {
        if case .quickSwitchListDirectories = action {
            return true
        }
        return false
    }

    func execute(action: CLIAction) async -> CommandResult {
        guard let executor else {
            return .failure(action: "quick-switch", exitCode: .generalError, error: "Executor deallocated")
        }

        guard case .quickSwitchListDirectories = action else {
            return .failure(action: action.description, exitCode: .generalError, error: "Action not handled by QuickSwitchActionHandler")
        }

        return executeListDirectories(executor: executor)
    }

    private struct RootFolder: Codable {
        let id: UUID
        var path: String
        var scanDepth: Int
        var isEnabled: Bool
    }

    private static let excludedDirectoryNames: Set<String> = [
        "node_modules", ".git", "build", "DerivedData", ".Trash",
        ".DS_Store", "Pods", ".build", "dist", "vendor", "__pycache__",
        ".cache", ".npm", ".yarn"
    ]

    private func executeListDirectories(executor: ActionExecutor) -> CommandResult {
        let perUser = PerUserDefaultsManager.shared
        let appDefaults = UserDefaults.standard.persistentDomain(forName: BundleIdentity.defaultsSuiteName) ?? [:]

        // Settings are stored unscoped now. The trailing suffix scan stays because
        // installs written by older builds still carry `<accountID>.<setting>` keys
        // on disk, and losing a user's configured root folders on upgrade is worse
        // than one extra dictionary walk.
        func loadQuickSwitchData(setting: String) -> Data? {
            if let data = perUser.data(forKey: setting) {
                return data
            }

            if let data = appDefaults[setting] as? Data {
                return data
            }

            for (key, value) in appDefaults where key.hasSuffix(".\(setting)") {
                if let data = value as? Data {
                    return data
                }
            }

            return nil
        }

        func loadQuickSwitchString(setting: String) -> String? {
            if let value = perUser.string(forKey: setting) {
                return value
            }

            if let value = appDefaults[setting] as? String {
                return value
            }

            for (key, value) in appDefaults where key.hasSuffix(".\(setting)") {
                if let stringValue = value as? String {
                    return stringValue
                }
            }

            return nil
        }

        let rootFolders: [RootFolder] = {
            guard let data = loadQuickSwitchData(setting: "quickSwitch.rootFolders"),
                  let folders = try? JSONDecoder().decode([RootFolder].self, from: data) else {
                return []
            }
            return folders
        }()

        let directoryOverrides: [String: String] = {
            guard let data = loadQuickSwitchData(setting: "quickSwitch.directoryOverrides"),
                  let overrides = try? JSONDecoder().decode([String: String].self, from: data) else {
                return [:]
            }
            return overrides
        }()

        let favoriteDirectories: Set<String> = {
            guard let data = loadQuickSwitchData(setting: "quickSwitch.favoriteDirectories"),
                  let paths = try? JSONDecoder().decode([String].self, from: data) else {
                return []
            }
            return Set(paths.map { Self.normalizeDirectoryPath($0) })
        }()

        let globalDefaultWorkspaceId = loadQuickSwitchString(setting: "quickSwitch.globalDefaultWorkspaceId")
        let enabledFolders = rootFolders.filter(\.isEnabled)

        if enabledFolders.isEmpty {
            if executor.shouldEmitTextOutput {
                print("No quick-switch root folders configured.")
                print("Configure root folders in DeskJig → Settings → Quick Switch.")
            }
            return .success(
                action: "quick-switch-list-directories",
                message: "No root folders configured",
                data: AnyCodableValue.from(ListOutput(directories: [], globalDefaultWorkspace: nil, rootFolderCount: 0))
            )
        }

        var scannedDirectories: [(name: String, path: String, rootFolder: String, gitBranch: String?)] = []
        var seenPaths: Set<String> = []

        for folder in enabledFolders {
            let expandedPath = (folder.path as NSString).expandingTildeInPath
            let rootURL = URL(fileURLWithPath: expandedPath).standardizedFileURL

            let scanned = scanDirectory(
                at: rootURL,
                rootFolder: folder.path,
                currentDepth: 1,
                maxDepth: folder.scanDepth
            )
            for directory in scanned where !seenPaths.contains(directory.path) {
                seenPaths.insert(directory.path)
                scannedDirectories.append(directory)
            }
        }

        scannedDirectories.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }

        let savedWorkspaces = executor.workspaceManager.savedWorkspaces
        let workspaceMap = Dictionary(uniqueKeysWithValues: savedWorkspaces.map { ($0.id.uuidString, $0.name) })
        let globalDefaultName = globalDefaultWorkspaceId.flatMap { workspaceMap[$0] }

        if executor.shouldEmitTextOutput {
            print("Quick Switch Directories (\(scannedDirectories.count)):")
            print()

            let nameWidth = max(scannedDirectories.map(\.name.count).max() ?? 4, 4)

            for directory in scannedDirectories {
                let normalizedPath = Self.normalizeDirectoryPath(directory.path)
                let star = favoriteDirectories.contains(normalizedPath) ? " *" : ""
                let overrideId = directoryOverrides[normalizedPath]
                let workspaceName: String
                if let overrideId, let name = workspaceMap[overrideId] {
                    workspaceName = name
                } else if let globalDefaultName {
                    workspaceName = "\(globalDefaultName) (global)"
                } else {
                    workspaceName = "(none)"
                }

                let branch = directory.gitBranch ?? "-"
                let paddedName = directory.name.padding(toLength: nameWidth, withPad: " ", startingAt: 0)
                print("  \(paddedName)  \(branch.padding(toLength: 20, withPad: " ", startingAt: 0))  \(workspaceName)\(star)")
            }
        }

        let entries = scannedDirectories.map { directory in
            let normalizedPath = Self.normalizeDirectoryPath(directory.path)
            let overrideId = directoryOverrides[normalizedPath]

            return ListOutput.DirectoryEntry(
                name: directory.name,
                path: directory.path,
                rootFolder: directory.rootFolder,
                gitBranch: directory.gitBranch,
                isFavorite: favoriteDirectories.contains(normalizedPath),
                workspaceOverrideId: overrideId,
                workspaceOverrideName: overrideId.flatMap { workspaceMap[$0] }
            )
        }

        let output = ListOutput(
            directories: entries,
            globalDefaultWorkspace: globalDefaultName,
            rootFolderCount: enabledFolders.count
        )

        return .success(
            action: "quick-switch-list-directories",
            message: "\(scannedDirectories.count) directories from \(enabledFolders.count) root folder(s)",
            data: AnyCodableValue.from(output)
        )
    }

    private static func normalizeDirectoryPath(_ path: String) -> String {
        let expanded = (path as NSString).expandingTildeInPath
        return URL(fileURLWithPath: expanded).standardizedFileURL.path
    }

    private func scanDirectory(
        at url: URL,
        rootFolder: String,
        currentDepth: Int,
        maxDepth: Int
    ) -> [(name: String, path: String, rootFolder: String, gitBranch: String?)] {
        guard currentDepth <= maxDepth else { return [] }

        let fileManager = FileManager.default
        guard let contents = try? fileManager.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var results: [(name: String, path: String, rootFolder: String, gitBranch: String?)] = []

        for itemURL in contents {
            let resourceValues = try? itemURL.resourceValues(forKeys: [.isDirectoryKey])
            guard resourceValues?.isDirectory == true else { continue }

            let name = itemURL.lastPathComponent
            guard !Self.excludedDirectoryNames.contains(name) else { continue }

            results.append((
                name: name,
                path: itemURL.standardizedFileURL.path,
                rootFolder: rootFolder,
                gitBranch: resolveGitBranch(at: itemURL)
            ))

            if currentDepth < maxDepth {
                results.append(contentsOf: scanDirectory(
                    at: itemURL,
                    rootFolder: rootFolder,
                    currentDepth: currentDepth + 1,
                    maxDepth: maxDepth
                ))
            }
        }

        return results
    }

    private func resolveGitBranch(at directoryURL: URL) -> String? {
        let fileManager = FileManager.default
        let gitMetadataURL = directoryURL.appendingPathComponent(".git")

        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: gitMetadataURL.path, isDirectory: &isDirectory) else {
            return nil
        }

        let gitDirectoryURL: URL
        if isDirectory.boolValue {
            gitDirectoryURL = gitMetadataURL
        } else {
            guard let contents = try? String(contentsOf: gitMetadataURL, encoding: .utf8) else {
                return nil
            }
            let firstLine = contents
                .components(separatedBy: .newlines)
                .first?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard firstLine.hasPrefix("gitdir:") else {
                return nil
            }
            let rawGitDirectory = firstLine
                .dropFirst("gitdir:".count)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !rawGitDirectory.isEmpty else {
                return nil
            }
            if rawGitDirectory.hasPrefix("/") {
                gitDirectoryURL = URL(fileURLWithPath: rawGitDirectory).standardizedFileURL
            } else {
                gitDirectoryURL = URL(fileURLWithPath: rawGitDirectory, relativeTo: directoryURL).standardizedFileURL
            }
        }

        let headURL = gitDirectoryURL.appendingPathComponent("HEAD")
        guard let head = try? String(contentsOf: headURL, encoding: .utf8) else {
            return nil
        }

        let trimmedHead = head.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedHead.isEmpty else {
            return nil
        }

        if trimmedHead.hasPrefix("ref:") {
            let refPath = trimmedHead
                .dropFirst("ref:".count)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let branch = (refPath as NSString).lastPathComponent
            return branch.isEmpty ? nil : branch
        }

        let shortHash = String(trimmedHead.prefix(7))
        return shortHash.isEmpty ? nil : "detached@\(shortHash)"
    }
}

private struct ListOutput: Codable {
    let directories: [DirectoryEntry]
    let globalDefaultWorkspace: String?
    let rootFolderCount: Int

    struct DirectoryEntry: Codable {
        let name: String
        let path: String
        let rootFolder: String
        let gitBranch: String?
        let isFavorite: Bool
        let workspaceOverrideId: String?
        let workspaceOverrideName: String?
    }
}
