//
//  QuickSwitchViewModel.swift
//  DeskJig
//

import SwiftUI
import DeskJigShared

// MARK: - Data Types

struct QuickSwitchRootFolder: Codable, Identifiable, Hashable {
    let id: UUID
    var path: String
    var scanDepth: Int  // 1-3, default 1
    var isEnabled: Bool

    init(id: UUID = UUID(), path: String, scanDepth: Int = 1, isEnabled: Bool = true) {
        self.id = id
        self.path = path
        self.scanDepth = min(max(scanDepth, 1), 3)
        self.isEnabled = isEnabled
    }
}

struct ScannedDirectory: Identifiable, Hashable {
    var id: String { path }
    let name: String             // last path component
    let path: String             // absolute path
    let rootFolder: String       // which root folder this came from
    var gitBranch: String?       // current git branch when directory is a repository/worktree
    let isWorktree: Bool         // true when .git is a file (not directory) — linked worktree
    let parentRepoPath: String?  // resolved main repo path (nil for non-worktrees)

    init(
        name: String,
        path: String,
        rootFolder: String,
        gitBranch: String? = nil,
        isWorktree: Bool = false,
        parentRepoPath: String? = nil
    ) {
        self.name = name
        self.path = path
        self.rootFolder = rootFolder
        self.gitBranch = gitBranch
        self.isWorktree = isWorktree
        self.parentRepoPath = parentRepoPath
    }
}

struct QuickSwitchWorkspaceTransformResult {
    let workspace: Workspace
    let rewrittenWindowCount: Int
    let skippedXcodeWindowCount: Int
    let skippedXcodeForNonProjectTarget: Bool
}

// MARK: - QuickSwitchViewModel

@MainActor @Observable
final class QuickSwitchViewModel {
    enum LegacyImportResult: Equatable {
        case imported
        case noChanges
        case unavailable
        case failed(String)
    }

    @ObservationIgnored private var isHydratingFromDefaults = false
    @ObservationIgnored private let perUserDefaultsManager: PerUserDefaultsManager
    @ObservationIgnored private let userDefaults: UserDefaults
    @ObservationIgnored private let legacyPreferencesURLOverride: URL?
    @ObservationIgnored private var lastLoggedSettingsHash: Int = 0

    private static let rootFoldersKey = "quickSwitch.rootFolders"
    private static let directoryOverridesKey = "quickSwitch.directoryOverrides"
    private static let favoriteDirectoriesKey = "quickSwitch.favoriteDirectories"
    private static let globalDefaultWorkspaceIdKey = "quickSwitch.globalDefaultWorkspaceId"
    private static let worktreeStoragePathKey = "quickSwitch.worktreeStoragePath"
    private static let worktreeBranchPrefixKey = "quickSwitch.worktreeBranchPrefix"
    private static let legacyImportLastImportedAtKey = "quickSwitch.legacyImport.lastImportedAt"
    private static let dataSettingKeys = [
        rootFoldersKey,
        directoryOverridesKey,
        favoriteDirectoriesKey
    ]
    private static let stringSettingKeys = [
        globalDefaultWorkspaceIdKey,
        worktreeStoragePathKey,
        worktreeBranchPrefixKey
    ]
    private static let legacyPreferencesRelativePath =
        "Library/Containers/com.mscontrol.bento/Data/Library/Preferences/com.mscontrol.bento.plist"

    // Renamed from the legacy "~/.bento/worktrees" default (2026-08-25). Only
    // affects installs that never customized the path: new worktrees land in
    // the DeskJig location, while worktrees already created under the old
    // path stay valid on disk and keep appearing via root-folder scanning.
    static let defaultWorktreeStoragePath = "~/.deskjig/worktrees"

    // MARK: - Persisted State

    var rootFolders: [QuickSwitchRootFolder] = [] {
        didSet {
            guard !isHydratingFromDefaults, oldValue != rootFolders else { return }
            saveRootFolders()
        }
    }

    /// Per-directory workspace override: directory path -> workspace ID
    var directoryOverrides: [String: String] = [:] {
        didSet {
            guard !isHydratingFromDefaults, oldValue != directoryOverrides else { return }
            saveDirectoryOverrides()
        }
    }

    /// Per-directory favorites for Quick Switch ordering
    var favoriteDirectories: Set<String> = [] {
        didSet {
            guard !isHydratingFromDefaults, oldValue != favoriteDirectories else { return }
            saveFavoriteDirectories()
        }
    }

    /// Global default workspace ID
    var globalDefaultWorkspaceId: String? = nil {
        didSet {
            guard !isHydratingFromDefaults, oldValue != globalDefaultWorkspaceId else { return }
            perUserDefaultsManager.set(globalDefaultWorkspaceId, forKey: Self.globalDefaultWorkspaceIdKey)
        }
    }

    /// Worktree storage base path (default: ~/.deskjig/worktrees)
    var worktreeStoragePath: String = defaultWorktreeStoragePath {
        didSet {
            guard !isHydratingFromDefaults, oldValue != worktreeStoragePath else { return }
            perUserDefaultsManager.set(worktreeStoragePath, forKey: Self.worktreeStoragePathKey)
        }
    }

    /// Optional prefix for worktree branch names (e.g., "wt/", "andrew/")
    var worktreeBranchPrefix: String = "" {
        didSet {
            guard !isHydratingFromDefaults, oldValue != worktreeBranchPrefix else { return }
            perUserDefaultsManager.set(worktreeBranchPrefix, forKey: Self.worktreeBranchPrefixKey)
        }
    }

    var lastLegacyImportAt: Date? = nil

    // MARK: - Transient State

    var scannedDirectories: [ScannedDirectory] = []
    var isScanning: Bool = false

    // MARK: - Worktree Transient State

    var isWorktreeSheetPresented: Bool = false
    var worktreeSourceDirectory: ScannedDirectory? = nil
    var worktreeResolvedRepoPath: String? = nil
    var worktreeNewBranchName: String = ""
    var worktreeBaseBranch: String = "main"
    var worktreeAvailableBranches: [String] = []
    var worktreeCreationInProgress: Bool = false
    var worktreeCreationError: String? = nil

    var isArchiveWorktreePresented: Bool = false
    var archiveWorktreeDirectory: ScannedDirectory? = nil
    var archiveWorktreeDeleteBranch: Bool = false
    var archiveWorktreeHasChanges: Bool = false

    // MARK: - Filtered directories excluded from scanning
    private static let excludedDirectoryNames: Set<String> = [
        "node_modules", ".git", "build", "DerivedData", ".Trash",
        ".DS_Store", "Pods", ".build", "dist", "vendor", "__pycache__",
        ".cache", ".npm", ".yarn"
    ]

    // MARK: - Init

    init(
        perUserDefaultsManager: PerUserDefaultsManager = .shared,
        userDefaults: UserDefaults = .standard,
        legacyPreferencesURL: URL? = nil
    ) {
        self.perUserDefaultsManager = perUserDefaultsManager
        self.userDefaults = userDefaults
        self.legacyPreferencesURLOverride = legacyPreferencesURL
        reloadForCurrentUserContext()
    }

    func reloadForCurrentUserContext(scanImmediately: Bool = false) {
        isHydratingFromDefaults = true
        rootFolders = loadRootFoldersValue()
        directoryOverrides = loadDirectoryOverridesValue()
        favoriteDirectories = loadFavoriteDirectoriesValue()
        globalDefaultWorkspaceId = perUserDefaultsManager.string(forKey: Self.globalDefaultWorkspaceIdKey)
        worktreeStoragePath = perUserDefaultsManager.string(forKey: Self.worktreeStoragePathKey) ?? Self.defaultWorktreeStoragePath
        worktreeBranchPrefix = perUserDefaultsManager.string(forKey: Self.worktreeBranchPrefixKey) ?? ""
        lastLegacyImportAt = loadLastLegacyImportAt()
        isHydratingFromDefaults = false

        scannedDirectories = []
        if scanImmediately {
            scanDirectories()
        }

        let settingsHash = rootFolders.count &* 31 &+ directoryOverrides.count &* 17 &+ favoriteDirectories.count &* 13 &+ (globalDefaultWorkspaceId != nil ? 1 : 0)
        if settingsHash != lastLoggedSettingsHash {
            lastLoggedSettingsHash = settingsHash
            DeskJigLog.trace(.workspace, "QuickSwitch: Loaded settings", fields: [
                "rootFolders": rootFolders.count,
                "overrides": directoryOverrides.count,
                "favorites": favoriteDirectories.count,
                "hasGlobalDefault": globalDefaultWorkspaceId != nil
            ])
        }
    }

    // MARK: - Directory Scanning

    func scanDirectories() {
        isScanning = true
        let enabledFolders = rootFolders.filter(\.isEnabled)

        var results: [ScannedDirectory] = []
        var seenPaths: Set<String> = []

        for folder in enabledFolders {
            let expandedPath = (folder.path as NSString).expandingTildeInPath
            let rootURL = URL(fileURLWithPath: expandedPath).standardizedFileURL

            let scanned = scanDirectory(at: rootURL, rootFolder: folder.path, currentDepth: 1, maxDepth: folder.scanDepth)
            for dir in scanned {
                if !seenPaths.contains(dir.path) {
                    seenPaths.insert(dir.path)
                    results.append(dir)
                }
            }
        }

        scannedDirectories = results.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        isScanning = false
        DeskJigLog.info(.workspace, "QuickSwitch: Scanned directories", fields: ["directories": results.count, "rootFolders": enabledFolders.count])
    }

    /// Refreshes only the git branch information for existing scanned directories.
    ///
    /// This is much cheaper than `scanDirectories()` because it doesn't re-enumerate
    /// the filesystem — it only reads `.git/HEAD` files (~sub-millisecond per directory).
    /// Only replaces entries whose branch actually changed (avoids unnecessary SwiftUI diffing).
    func refreshGitBranches() {
        var changed = false
        var updated = scannedDirectories

        for i in updated.indices {
            let directoryURL = URL(fileURLWithPath: updated[i].path)
            let gitInfo = resolveGitInfo(at: directoryURL)
            if updated[i].gitBranch != gitInfo.branch {
                updated[i].gitBranch = gitInfo.branch
                changed = true
            }
        }

        if changed {
            scannedDirectories = updated
            DeskJigLog.info(.workspace, "QuickSwitch: Refreshed git branches (some changed)")
        }
    }

    private func scanDirectory(at url: URL, rootFolder: String, currentDepth: Int, maxDepth: Int) -> [ScannedDirectory] {
        guard currentDepth <= maxDepth else { return [] }

        let fm = FileManager.default
        let contents: [URL]
        do {
            contents = try fm.contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )
        } catch {
            // An unreadable root folder would otherwise silently show zero directories.
            DeskJigLog.debug(.workspace, "QuickSwitch: Failed to scan directory", fields: [
                "path": url.path,
                "error": error.localizedDescription
            ])
            return []
        }

        var results: [ScannedDirectory] = []

        for itemURL in contents {
            let resourceValues = try? itemURL.resourceValues(forKeys: [.isDirectoryKey])
            guard resourceValues?.isDirectory == true else { continue }

            let name = itemURL.lastPathComponent
            guard !Self.excludedDirectoryNames.contains(name) else { continue }

            let gitInfo = resolveGitInfo(at: itemURL)

            // Skip non-git directories from the listing (still recurse into
            // them to find actual repos/worktrees at deeper levels)
            let isGitRepo = gitInfo.branch != nil || gitInfo.isWorktree
            let skipEntry = !isGitRepo

            if !skipEntry {
                let entry = ScannedDirectory(
                    name: name,
                    path: itemURL.standardizedFileURL.path,
                    rootFolder: rootFolder,
                    gitBranch: gitInfo.branch,
                    isWorktree: gitInfo.isWorktree,
                    parentRepoPath: gitInfo.parentRepoPath
                )
                results.append(entry)
            }

            // Recurse for deeper scanning
            if currentDepth < maxDepth {
                let children = scanDirectory(at: itemURL, rootFolder: rootFolder, currentDepth: currentDepth + 1, maxDepth: maxDepth)
                results.append(contentsOf: children)
            }
        }

        return results
    }

    // MARK: - Layout Resolution

    /// Resolve which workspace to use for a directory, following the priority chain:
    /// 1. Per-directory override
    /// 2. Global default
    /// 3. Stable fallback (earliest created workspace, then ID)
    func resolveDefaultWorkspace(for directoryPath: String, savedWorkspaces: [Workspace]) -> Workspace? {
        let normalizedDirectoryPath = Self.normalizeDirectoryPath(directoryPath)

        // 1. Per-directory override
        if let overrideIdStr = directoryOverrides[normalizedDirectoryPath],
           let overrideId = UUID(uuidString: overrideIdStr),
           let workspace = savedWorkspaces.first(where: { $0.id == overrideId }) {
            DeskJigLog.trace(.workspace, "QuickSwitch: Resolved via directory override", fields: ["directory": normalizedDirectoryPath, "workspace": workspace.name])
            return workspace
        } else if directoryOverrides[normalizedDirectoryPath] != nil {
            DeskJigLog.info(.workspace, "QuickSwitch: Directory override missing from saved workspaces", fields: ["directory": normalizedDirectoryPath])
        }

        // 2. Global default
        if let globalIdStr = globalDefaultWorkspaceId,
           let globalId = UUID(uuidString: globalIdStr),
           let workspace = savedWorkspaces.first(where: { $0.id == globalId }) {
            DeskJigLog.trace(.workspace, "QuickSwitch: Resolved via global default", fields: ["directory": normalizedDirectoryPath, "workspace": workspace.name])
            return workspace
        } else if globalDefaultWorkspaceId != nil {
            DeskJigLog.info(.workspace, "QuickSwitch: Global default missing from saved workspaces, falling back")
        }

        // 3. Stable fallback (oldest created, then UUID)
        let fallback = savedWorkspaces.sorted { lhs, rhs in
            if lhs.createdAt != rhs.createdAt {
                return lhs.createdAt < rhs.createdAt
            }
            return lhs.id.uuidString < rhs.id.uuidString
        }.first
        if let fallback {
            DeskJigLog.trace(.workspace, "QuickSwitch: Resolved via stable fallback", fields: ["directory": normalizedDirectoryPath, "workspace": fallback.name])
        }
        return fallback
    }

    func setDirectoryOverride(for directoryPath: String, workspaceId: UUID) {
        let normalizedPath = Self.normalizeDirectoryPath(directoryPath)
        directoryOverrides[normalizedPath] = workspaceId.uuidString
    }

    func clearDirectoryOverride(for directoryPath: String) {
        let normalizedPath = Self.normalizeDirectoryPath(directoryPath)
        directoryOverrides.removeValue(forKey: normalizedPath)
    }

    func directoryOverrideWorkspaceId(for directoryPath: String) -> UUID? {
        let normalizedPath = Self.normalizeDirectoryPath(directoryPath)
        guard let rawId = directoryOverrides[normalizedPath] else {
            return nil
        }
        return UUID(uuidString: rawId)
    }

    func setDirectoryFavorite(for directoryPath: String, isFavorite: Bool) {
        let normalizedPath = Self.normalizeDirectoryPath(directoryPath)
        if isFavorite {
            favoriteDirectories.insert(normalizedPath)
        } else {
            favoriteDirectories.remove(normalizedPath)
        }
    }

    func toggleDirectoryFavorite(for directoryPath: String) {
        let normalizedPath = Self.normalizeDirectoryPath(directoryPath)
        if favoriteDirectories.contains(normalizedPath) {
            favoriteDirectories.remove(normalizedPath)
        } else {
            favoriteDirectories.insert(normalizedPath)
        }
    }

    func isDirectoryFavorite(_ directoryPath: String) -> Bool {
        let normalizedPath = Self.normalizeDirectoryPath(directoryPath)
        return favoriteDirectories.contains(normalizedPath)
    }

    func pruneInvalidLayoutSelections(savedWorkspaces: [Workspace]) {
        // Avoid destructive clearing while workspace data is still hydrating.
        guard !savedWorkspaces.isEmpty else { return }

        let validIds = Set(savedWorkspaces.map { $0.id.uuidString })
        let filteredOverrides = directoryOverrides.filter { validIds.contains($0.value) }
        if filteredOverrides != directoryOverrides {
            directoryOverrides = filteredOverrides
        }

        if let globalDefaultWorkspaceId, !validIds.contains(globalDefaultWorkspaceId) {
            self.globalDefaultWorkspaceId = nil
        }
    }

    // MARK: - Switch Action

    func switchToDirectory(
        _ directory: ScannedDirectory,
        layout workspace: Workspace,
        workspaceVM: WorkspaceViewModel
    ) {
        DeskJigLog.info(.workspace, "QuickSwitch: Switching to directory", fields: ["directory": directory.name, "layout": workspace.name])

        let transformed = makeQuickSwitchWorkspaceTransformResult(
            from: workspace,
            targetDirectoryPath: directory.path
        )

        DeskJigLog.info(.workspace, "QuickSwitch: Launching standard restore with rewritten windows", fields: [
            "rewrittenCount": transformed.rewrittenWindowCount,
            "skippedXcodeCount": transformed.skippedXcodeWindowCount,
            "totalCount": workspace.windows.count
        ])

        let onComplete: (() -> Void)? = {
            guard let notification = AppDelegate.quickSwitchSkippedXcodeNotificationContent(
                for: transformed,
                targetDirectoryPath: directory.path
            ) else {
                return nil
            }
            return {
                NotificationPresenter.present(
                    notification,
                    for: .seconds(5)
                )
            }
        }()

        workspaceVM.openWorkspace(
            transformed.workspace,
            source: WorkspaceViewModel.quickSwitchLaunchSource,
            launchDisplayName: "Quick Switch: \(directory.name)",
            onComplete: onComplete
        )
    }

    @discardableResult
    func switchToDirectory(
        _ directory: ScannedDirectory,
        layout workspace: Workspace,
        openWorkspace: (Workspace, String, String, (() -> Void)?) -> Void
    ) -> QuickSwitchWorkspaceTransformResult {
        DeskJigLog.info(.workspace, "QuickSwitch: Switching to directory", fields: ["directory": directory.name, "layout": workspace.name])

        let transformed = makeQuickSwitchWorkspaceTransformResult(
            from: workspace,
            targetDirectoryPath: directory.path
        )

        DeskJigLog.info(.workspace, "QuickSwitch: Launching standard restore with rewritten windows", fields: [
            "rewrittenCount": transformed.rewrittenWindowCount,
            "skippedXcodeCount": transformed.skippedXcodeWindowCount,
            "totalCount": workspace.windows.count
        ])

        openWorkspace(
            transformed.workspace,
            WorkspaceViewModel.quickSwitchLaunchSource,
            "Quick Switch: \(directory.name)",
            nil
        )

        return transformed
    }

    // MARK: - Layout Extraction

    /// Builds a workspace payload for Quick Switch:
    /// - rewrites openPath for OpenByPath windows
    /// - rewrites terminal keys for terminal windows so tmux session mapping remains directory-scoped
    func makeQuickSwitchWorkspace(
        from workspace: Workspace,
        targetDirectoryPath: String
    ) -> Workspace {
        makeQuickSwitchWorkspaceTransformResult(
            from: workspace,
            targetDirectoryPath: targetDirectoryPath
        ).workspace
    }

    func makeQuickSwitchWorkspaceTransformResult(
        from workspace: Workspace,
        targetDirectoryPath: String
    ) -> QuickSwitchWorkspaceTransformResult {
        let normalizedTargetPath = URL(fileURLWithPath: targetDirectoryPath).standardizedFileURL.path
        let shouldRewriteXcodePath = Self.isXcodeProjectTarget(normalizedTargetPath)
        let terminalSlotAssignments = Self.quickSwitchTerminalSlotAssignments(for: workspace.windows)
        let directoryToken = TmuxSessionManager.quickSwitchDirectoryToken(forDirectoryPath: normalizedTargetPath)
        var rewrittenWindowCount = 0
        var skippedXcodeWindowCount = 0

        let rewrittenWindows = workspace.windows.compactMap { window in
            guard OpenByPathBundleIdentifiers.supported.contains(window.bundleIdentifier) else {
                return window
            }

            if window.bundleIdentifier == OpenByPathBundleIdentifiers.xcode {
                if shouldRewriteXcodePath {
                    DeskJigLog.debug(.workspace, "QuickSwitch: Xcode path rewrite enabled for project target", fields: [
                        "targetPath": normalizedTargetPath,
                        "windowId": window.id.uuidString
                    ])
                    if window.openPath != normalizedTargetPath {
                        rewrittenWindowCount += 1
                    }
                    return window.withOpenPath(normalizedTargetPath)
                }

                skippedXcodeWindowCount += 1
                DeskJigLog.debug(.workspace, "QuickSwitch: Xcode window skipped for non-project target", fields: [
                    "targetPath": normalizedTargetPath,
                    "windowId": window.id.uuidString,
                    "savedOpenPath": window.openPath ?? "nil"
                ])
                return nil
            }

            if BundleRegistry.isTerminal(window.bundleIdentifier) {
                var rewrittenTerminalWindow = window.withOpenPath(normalizedTargetPath)
                let slotIndex = terminalSlotAssignments[window.id] ?? 0

                let tmuxTerminalKey = TmuxSessionManager.quickSwitchTerminalKey(
                    forDirectoryPath: normalizedTargetPath,
                    slotIndex: slotIndex
                )
                rewrittenTerminalWindow = rewrittenTerminalWindow.withTerminalKey(tmuxTerminalKey)

                if let tmuxState = rewrittenTerminalWindow.tmuxState {
                    rewrittenTerminalWindow = rewrittenTerminalWindow.withTmuxState(
                        TmuxSessionState(
                            sessionName: tmuxState.sessionName,
                            initialWorkingDirectory: normalizedTargetPath
                        )
                    )
                }

                if window.openPath != normalizedTargetPath ||
                    window.terminalKey != tmuxTerminalKey ||
                    window.tmuxState?.initialWorkingDirectory != normalizedTargetPath {
                    rewrittenWindowCount += 1
                }

                DeskJigLog.debug(.workspace, "QuickSwitch: directory-slot terminal mapping", fields: [
                    "windowId": window.id.uuidString,
                    "slot": slotIndex,
                    "directoryToken": directoryToken
                ])

                return rewrittenTerminalWindow
            }

            if window.openPath != normalizedTargetPath {
                rewrittenWindowCount += 1
            }
            return window.withOpenPath(normalizedTargetPath)
        }

        return QuickSwitchWorkspaceTransformResult(
            workspace: workspace.withNewWindows(rewrittenWindows),
            rewrittenWindowCount: rewrittenWindowCount,
            skippedXcodeWindowCount: skippedXcodeWindowCount,
            skippedXcodeForNonProjectTarget: skippedXcodeWindowCount > 0
        )
    }

    private static func isXcodeProjectTarget(_ path: String) -> Bool {
        let normalizedPath = URL(fileURLWithPath: path).standardizedFileURL.path
        let lowercasedPath = normalizedPath.lowercased()
        if lowercasedPath.hasSuffix(".xcworkspace") || lowercasedPath.hasSuffix(".xcodeproj") {
            return true
        }

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: normalizedPath, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            return false
        }

        // best-effort: an unreadable directory is treated as a non-Xcode target
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: URL(fileURLWithPath: normalizedPath),
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return false
        }

        return contents.contains { url in
            let ext = url.pathExtension.lowercased()
            return ext == "xcworkspace" || ext == "xcodeproj"
        }
    }

    private static func quickSwitchTerminalSlotAssignments(for windows: [WorkspaceWindow]) -> [UUID: Int] {
        let sortedTerminalWindows = windows
            .filter { BundleRegistry.isTerminal($0.bundleIdentifier) }
            .sorted { lhs, rhs in
                let lhsScreenIndex = lhs.screenIndex ?? Int.max
                let rhsScreenIndex = rhs.screenIndex ?? Int.max
                if lhsScreenIndex != rhsScreenIndex {
                    return lhsScreenIndex < rhsScreenIndex
                }

                let lhsY = lhs.relativeFrame?.yPercent ?? Double.greatestFiniteMagnitude
                let rhsY = rhs.relativeFrame?.yPercent ?? Double.greatestFiniteMagnitude
                if lhsY != rhsY {
                    return lhsY < rhsY
                }

                let lhsX = lhs.relativeFrame?.xPercent ?? Double.greatestFiniteMagnitude
                let rhsX = rhs.relativeFrame?.xPercent ?? Double.greatestFiniteMagnitude
                if lhsX != rhsX {
                    return lhsX < rhsX
                }

                if lhs.bundleIdentifier != rhs.bundleIdentifier {
                    return lhs.bundleIdentifier < rhs.bundleIdentifier
                }

                return lhs.id.uuidString < rhs.id.uuidString
            }

        return Dictionary(uniqueKeysWithValues: sortedTerminalWindows.enumerated().map { index, window in
            (window.id, index)
        })
    }

    private static func normalizeDirectoryPath(_ directoryPath: String) -> String {
        let expanded = (directoryPath as NSString).expandingTildeInPath
        return URL(fileURLWithPath: expanded).standardizedFileURL.path
    }

    private struct GitInfo {
        let branch: String?
        let isWorktree: Bool
        let parentRepoPath: String?
    }

    private func resolveGitInfo(at directoryURL: URL) -> GitInfo {
        let fileManager = FileManager.default
        let gitMetadataURL = directoryURL.appendingPathComponent(".git")

        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: gitMetadataURL.path, isDirectory: &isDirectory) else {
            return GitInfo(branch: nil, isWorktree: false, parentRepoPath: nil)
        }

        let gitDirectoryURL: URL
        var detectedWorktree = false
        var detectedParentRepoPath: String?

        if isDirectory.boolValue {
            gitDirectoryURL = gitMetadataURL
        } else {
            // .git is a file → this is a worktree
            detectedWorktree = true

            let contents: String
            do {
                contents = try String(contentsOf: gitMetadataURL, encoding: .utf8)
            } catch {
                // Unreadable .git file hides the worktree's branch/parent in the UI.
                DeskJigLog.debug(.workspace, "QuickSwitch: Failed to read worktree .git file", fields: [
                    "path": gitMetadataURL.path,
                    "error": error.localizedDescription
                ])
                return GitInfo(branch: nil, isWorktree: true, parentRepoPath: nil)
            }

            let firstLine = contents
                .components(separatedBy: .newlines)
                .first?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard firstLine.hasPrefix("gitdir:") else {
                return GitInfo(branch: nil, isWorktree: true, parentRepoPath: nil)
            }

            let rawGitDir = firstLine
                .dropFirst("gitdir:".count)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !rawGitDir.isEmpty else {
                return GitInfo(branch: nil, isWorktree: true, parentRepoPath: nil)
            }

            if rawGitDir.hasPrefix("/") {
                gitDirectoryURL = URL(fileURLWithPath: rawGitDir).standardizedFileURL
            } else {
                gitDirectoryURL = URL(fileURLWithPath: rawGitDir, relativeTo: directoryURL).standardizedFileURL
            }

            // Resolve parent repo: worktree gitdir typically looks like
            // /path/to/main-repo/.git/worktrees/<name>
            // So parent = gitdir/../../../
            let worktreesDir = gitDirectoryURL.deletingLastPathComponent()
            if worktreesDir.lastPathComponent == "worktrees" {
                let gitDir = worktreesDir.deletingLastPathComponent()
                if gitDir.lastPathComponent == ".git" {
                    detectedParentRepoPath = gitDir.deletingLastPathComponent().standardizedFileURL.path
                }
            }
        }

        let headURL = gitDirectoryURL.appendingPathComponent("HEAD")
        let head: String
        do {
            head = try String(contentsOf: headURL, encoding: .utf8)
        } catch {
            // A repo with an unreadable HEAD silently disappears from the listing.
            DeskJigLog.debug(.workspace, "QuickSwitch: Failed to read git HEAD", fields: [
                "path": headURL.path,
                "error": error.localizedDescription
            ])
            return GitInfo(branch: nil, isWorktree: detectedWorktree, parentRepoPath: detectedParentRepoPath)
        }

        let trimmedHead = head.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedHead.isEmpty else {
            return GitInfo(branch: nil, isWorktree: detectedWorktree, parentRepoPath: detectedParentRepoPath)
        }

        let prefix = "ref:"
        if trimmedHead.hasPrefix(prefix) {
            let refPath = trimmedHead
                .dropFirst(prefix.count)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let refsHeadsPrefix = "refs/heads/"
            let branch = refPath.hasPrefix(refsHeadsPrefix)
                ? String(refPath.dropFirst(refsHeadsPrefix.count))
                : (refPath as NSString).lastPathComponent
            return GitInfo(
                branch: branch.isEmpty ? nil : branch,
                isWorktree: detectedWorktree,
                parentRepoPath: detectedParentRepoPath
            )
        }

        // Detached HEAD; display a short commit hint.
        let shortHash = String(trimmedHead.prefix(7))
        return GitInfo(
            branch: shortHash.isEmpty ? nil : "detached@\(shortHash)",
            isWorktree: detectedWorktree,
            parentRepoPath: detectedParentRepoPath
        )
    }

    // MARK: - Worktree Management

    private let gitService = GitCommandService()

    /// Opens the worktree creation sheet for a directory.
    /// Validates it's a git repo, resolves to main repo if already a worktree, loads branches.
    func beginWorktreeCreation(for directory: ScannedDirectory) {
        worktreeSourceDirectory = directory
        worktreeNewBranchName = ""
        worktreeBaseBranch = "main"
        worktreeAvailableBranches = []
        worktreeCreationError = nil
        worktreeCreationInProgress = false

        // Resolve to main repo if this is already a worktree
        let repoPath = directory.parentRepoPath ?? directory.path
        worktreeResolvedRepoPath = repoPath

        Task { @MainActor in
            do {
                let branches = try await gitService.listBranches(repoPath: repoPath)
                worktreeAvailableBranches = branches
                // Default to main/master if available
                if branches.contains("main") {
                    worktreeBaseBranch = "main"
                } else if branches.contains("master") {
                    worktreeBaseBranch = "master"
                } else if let first = branches.first {
                    worktreeBaseBranch = first
                }
            } catch {
                DeskJigLog.warn(.workspace, "QuickSwitch: Failed to list branches", fields: ["repoPath": repoPath, "error": "\(error)"])
            }
            isWorktreeSheetPresented = true
        }
    }

    /// Creates a worktree with the current sheet state.
    func createWorktree() {
        guard let repoPath = worktreeResolvedRepoPath else { return }
        let branchName = worktreeBranchPrefix + worktreeNewBranchName
        let repoName = URL(fileURLWithPath: repoPath).lastPathComponent
        let expandedStoragePath = (worktreeStoragePath as NSString).expandingTildeInPath
        let worktreeStorageDir = (expandedStoragePath as NSString).appendingPathComponent(repoName)
        let worktreePath = (worktreeStorageDir as NSString).appendingPathComponent(worktreeNewBranchName)

        worktreeCreationInProgress = true
        worktreeCreationError = nil

        Task { @MainActor in
            do {
                // Ensure storage directory exists
                let fm = FileManager.default
                if !fm.fileExists(atPath: worktreeStorageDir) {
                    try fm.createDirectory(atPath: worktreeStorageDir, withIntermediateDirectories: true)
                }

                let _ = try await gitService.createWorktree(
                    repoPath: repoPath,
                    worktreePath: worktreePath,
                    branchName: branchName,
                    baseBranch: worktreeBaseBranch
                )

                DeskJigLog.info(.workspace, "QuickSwitch: Created worktree", fields: ["worktreePath": worktreePath, "branch": branchName])

                // Auto-add worktree root folder if not already present
                autoAddWorktreeRootFolderIfNeeded()

                // Re-scan to pick up the new worktree
                scanDirectories()

                isWorktreeSheetPresented = false
                worktreeCreationInProgress = false
            } catch {
                worktreeCreationError = error.localizedDescription
                worktreeCreationInProgress = false
                DeskJigLog.warn(.workspace, "QuickSwitch: Worktree creation failed", fields: ["error": "\(error)"])
            }
        }
    }

    /// Opens the archive confirmation for a worktree directory.
    func beginArchiveWorktree(for directory: ScannedDirectory) {
        archiveWorktreeDirectory = directory
        archiveWorktreeDeleteBranch = false
        archiveWorktreeHasChanges = false

        Task { @MainActor in
            archiveWorktreeHasChanges = await gitService.hasUncommittedChanges(at: directory.path)
            isArchiveWorktreePresented = true
        }
    }

    /// Archives (removes) a worktree.
    func archiveWorktree(force: Bool = false) {
        guard let directory = archiveWorktreeDirectory else { return }
        let repoPath = directory.parentRepoPath ?? directory.path
        let branchToDelete = archiveWorktreeDeleteBranch ? directory.gitBranch : nil

        Task { @MainActor in
            do {
                try await gitService.removeWorktree(
                    repoPath: repoPath,
                    worktreePath: directory.path,
                    force: force
                )

                if let branchName = branchToDelete {
                    do {
                        try await gitService.deleteBranch(
                            repoPath: repoPath,
                            branchName: branchName,
                            force: true
                        )
                        DeskJigLog.info(.workspace, "QuickSwitch: Deleted branch after worktree archive", fields: ["branch": branchName])
                    } catch {
                        // The worktree is already gone; don't fail the archive, but the
                        // user asked for the branch to be deleted — surface the miss.
                        DeskJigLog.warn(.workspace, "QuickSwitch: Failed to delete branch after worktree archive", fields: [
                            "branch": branchName,
                            "error": error.localizedDescription
                        ])
                    }
                }

                DeskJigLog.info(.workspace, "QuickSwitch: Archived worktree", fields: ["path": directory.path])
                isArchiveWorktreePresented = false
                scanDirectories()
            } catch {
                DeskJigLog.warn(.workspace, "QuickSwitch: Worktree archive failed", fields: ["error": "\(error)"])
            }
        }
    }

    /// Checks if git is available on this system.
    var isGitAvailable: Bool {
        get async {
            await gitService.isAvailable
        }
    }

    /// Auto-adds the worktree storage root as a QuickSwitch root folder when the first worktree is created.
    private func autoAddWorktreeRootFolderIfNeeded() {
        let expandedPath = (worktreeStoragePath as NSString).expandingTildeInPath
        let alreadyPresent = rootFolders.contains { folder in
            (folder.path as NSString).expandingTildeInPath == expandedPath
        }
        guard !alreadyPresent else { return }

        let folder = QuickSwitchRootFolder(path: worktreeStoragePath, scanDepth: 2)
        rootFolders.append(folder)
        DeskJigLog.info(.workspace, "QuickSwitch: Auto-added worktree root folder", fields: ["path": worktreeStoragePath])
    }

    /// Client-side branch name validation (quick check before git validates).
    static func isValidBranchName(_ name: String) -> Bool {
        guard !name.isEmpty else { return false }
        guard !name.hasPrefix(".") && !name.hasSuffix(".") else { return false }
        guard !name.hasSuffix(".lock") else { return false }
        guard !name.contains("..") else { return false }

        let invalidChars = CharacterSet(charactersIn: " ~^:?*[\\")
        guard name.rangeOfCharacter(from: invalidChars) == nil else { return false }

        // No ASCII control characters
        let controlChars = CharacterSet.controlCharacters
        guard name.unicodeScalars.allSatisfy({ !controlChars.contains($0) }) else { return false }

        return true
    }

    // MARK: - Root Folder Management

    func addRootFolder(path: String) {
        let expanded = (path as NSString).expandingTildeInPath
        // Don't add duplicates
        guard !rootFolders.contains(where: { ($0.path as NSString).expandingTildeInPath == expanded }) else {
            return
        }
        let folder = QuickSwitchRootFolder(path: path)
        rootFolders.append(folder)
        scanDirectories()
    }

    func removeRootFolder(_ folder: QuickSwitchRootFolder) {
        rootFolders.removeAll { $0.id == folder.id }
        scanDirectories()
    }

    func updateScanDepth(for folder: QuickSwitchRootFolder, depth: Int) {
        if let index = rootFolders.firstIndex(where: { $0.id == folder.id }) {
            rootFolders[index] = QuickSwitchRootFolder(
                id: folder.id,
                path: folder.path,
                scanDepth: depth,
                isEnabled: folder.isEnabled
            )
            scanDirectories()
        }
    }

    func toggleFolder(_ folder: QuickSwitchRootFolder) {
        if let index = rootFolders.firstIndex(where: { $0.id == folder.id }) {
            rootFolders[index] = QuickSwitchRootFolder(
                id: folder.id,
                path: folder.path,
                scanDepth: folder.scanDepth,
                isEnabled: !folder.isEnabled
            )
            scanDirectories()
        }
    }

    // MARK: - Persistence

    /// Legacy Quick Switch settings live in the pre-sandbox-migration preferences
    /// container. The account era stored them under `"<userID>.<key>"`; DeskJig is a
    /// local single-user app and stores them under the bare key, so an import accepts
    /// either shape (bare key first, then any per-user-prefixed value).
    func importLegacyQuickSwitchSettings() -> LegacyImportResult {
        let legacyPreferencesURL = resolvedLegacyPreferencesURL()
        let legacyDefaults: [String: Any]
        do {
            legacyDefaults = try loadLegacyPreferences(from: legacyPreferencesURL)
        } catch {
            if let cocoaError = error as? CocoaError,
               cocoaError.code == .fileReadNoSuchFile {
                return .unavailable
            }

            return .failed(error.localizedDescription)
        }

        let importedKeys = importLegacyQuickSwitchSettingsIfNeeded(legacyDefaults: legacyDefaults)

        if importedKeys.isEmpty {
            return .noChanges
        }

        let importedAt = Date()
        userDefaults.set(importedAt.timeIntervalSince1970, forKey: Self.legacyImportLastImportedAtKey)
        reloadForCurrentUserContext()
        lastLegacyImportAt = importedAt
        return .imported
    }

    private func importLegacyQuickSwitchSettingsIfNeeded(legacyDefaults: [String: Any]) -> [String] {
        var importedKeys: [String] = []

        for key in Self.dataSettingKeys + Self.stringSettingKeys {
            // Never clobber a setting the user already configured locally.
            guard userDefaults.object(forKey: key) == nil else { continue }
            guard let legacyValue = legacyValue(for: key, in: legacyDefaults) else { continue }

            userDefaults.set(legacyValue, forKey: key)
            importedKeys.append(key)
            DeskJigLog.info(.workspace, "QuickSwitch: Imported legacy setting", fields: ["key": key])
        }

        return importedKeys
    }

    /// Resolves a legacy value for `key`, preferring the bare key and falling back to
    /// the account-era `"<userID>.<key>"` form. Any owner matches: a DeskJig install
    /// has exactly one user, so there is no longer an ownership question to arbitrate.
    private func legacyValue(for key: String, in legacyDefaults: [String: Any]) -> Any? {
        if let bareValue = legacyDefaults[key] {
            return bareValue
        }

        let suffix = ".\(key)"
        return legacyDefaults
            .sorted { $0.key < $1.key }
            .first { $0.key.hasSuffix(suffix) }?
            .value
    }

    private func loadLegacyPreferences(from legacyPreferencesURL: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: legacyPreferencesURL)
        do {
            let propertyList = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
            return propertyList as? [String: Any] ?? [:]
        } catch {
            DeskJigLog.warn(.workspace, "QuickSwitch: Failed to load legacy preferences", fields: [
                "path": legacyPreferencesURL.path,
                "error": error.localizedDescription
            ])
            throw error
        }
    }

    private static func defaultLegacyPreferencesURL() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(Self.legacyPreferencesRelativePath)
    }

    private func resolvedLegacyPreferencesURL() -> URL {
        legacyPreferencesURLOverride ?? Self.defaultLegacyPreferencesURL()
    }

    private func loadLastLegacyImportAt() -> Date? {
        let timestamp = userDefaults.double(forKey: Self.legacyImportLastImportedAtKey)
        guard timestamp > 0 else { return nil }
        return Date(timeIntervalSince1970: timestamp)
    }

    private func saveRootFolders() {
        if let data = try? JSONEncoder().encode(rootFolders) {
            perUserDefaultsManager.set(data, forKey: Self.rootFoldersKey)
        }
    }

    private func loadRootFoldersValue() -> [QuickSwitchRootFolder] {
        guard let data = perUserDefaultsManager.data(forKey: Self.rootFoldersKey) else { return [] }
        do {
            return try JSONDecoder().decode([QuickSwitchRootFolder].self, from: data)
        } catch {
            // Corrupt prefs would otherwise look like the user never configured folders.
            DeskJigLog.warn(.workspace, "QuickSwitch: Failed to decode saved root folders", fields: ["error": error.localizedDescription])
            return []
        }
    }

    private func saveDirectoryOverrides() {
        if let data = try? JSONEncoder().encode(directoryOverrides) {
            perUserDefaultsManager.set(data, forKey: Self.directoryOverridesKey)
        }
    }

    private func loadDirectoryOverridesValue() -> [String: String] {
        guard let data = perUserDefaultsManager.data(forKey: Self.directoryOverridesKey) else { return [:] }
        do {
            return try JSONDecoder().decode([String: String].self, from: data)
        } catch {
            DeskJigLog.warn(.workspace, "QuickSwitch: Failed to decode saved directory overrides", fields: ["error": error.localizedDescription])
            return [:]
        }
    }

    private func saveFavoriteDirectories() {
        let favoritePaths = Array(favoriteDirectories).sorted()
        if let data = try? JSONEncoder().encode(favoritePaths) {
            perUserDefaultsManager.set(data, forKey: Self.favoriteDirectoriesKey)
        }
    }

    private func loadFavoriteDirectoriesValue() -> Set<String> {
        guard let data = perUserDefaultsManager.data(forKey: Self.favoriteDirectoriesKey) else { return [] }
        do {
            let favoritePaths = try JSONDecoder().decode([String].self, from: data)
            return Set(favoritePaths.map(Self.normalizeDirectoryPath))
        } catch {
            DeskJigLog.warn(.workspace, "QuickSwitch: Failed to decode saved favorite directories", fields: ["error": error.localizedDescription])
            return []
        }
    }
}
