// QuickSwitchViewModelTests.swift
// DeskJigTests


import Testing
import Foundation
import CoreGraphics
@testable import DeskJig
@testable import DeskJigShared

struct QuickSwitchViewModelTests {

    @Test("QuickSwitch rewrites non-tmux OpenByPath windows to target directory")
    func rewritesOpenByPathWindows() async {
        let viewModel = await MainActor.run { QuickSwitchViewModel() }
        let targetDirectory = "/tmp/quick-switch-target"

        let terminalWindow = WorkspaceWindow(
            id: UUID(),
            bundleIdentifier: OpenByPathBundleIdentifiers.terminal,
            appName: "Terminal",
            windowTitle: "Terminal Window",
            openPath: "/tmp/original-terminal"
        )

        let ideWindow = WorkspaceWindow(
            id: UUID(),
            bundleIdentifier: OpenByPathBundleIdentifiers.cursor,
            appName: "Cursor",
            windowTitle: "Cursor Window",
            openPath: nil
        )

        let workspace = Workspace(
            name: "Test Workspace",
            workspaceWindows: [terminalWindow, ideWindow]
        )

        let transformed = await MainActor.run {
            viewModel.makeQuickSwitchWorkspace(
                from: workspace,
                targetDirectoryPath: targetDirectory
            )
        }

        let transformedByID = Dictionary(uniqueKeysWithValues: transformed.windows.map { ($0.id, $0) })
        #expect(transformedByID[terminalWindow.id]?.openPath == targetDirectory)
        #expect((transformedByID[terminalWindow.id]?.terminalKey?.isEmpty == false))
        #expect(transformedByID[terminalWindow.id]?.tmuxState == nil)
        #expect(transformedByID[ideWindow.id]?.openPath == targetDirectory)
    }

    @Test("QuickSwitch preserves folder metadata while rewriting window paths")
    func preservesFolderMetadataDuringRewrite() async {
        let viewModel = await MainActor.run { QuickSwitchViewModel() }
        let targetDirectory = "/tmp/quick-switch-target"
        let folderGroupID = UUID()

        let firstWindow = WorkspaceWindow(
            id: UUID(),
            bundleIdentifier: OpenByPathBundleIdentifiers.ghostty,
            appName: "Ghostty",
            windowTitle: "Terminal 1",
            openPath: "/tmp/original-a",
            folderGroupID: folderGroupID,
            folderOrder: 0
        )

        let secondWindow = WorkspaceWindow(
            id: UUID(),
            bundleIdentifier: OpenByPathBundleIdentifiers.cursor,
            appName: "Cursor",
            windowTitle: "Editor",
            openPath: "/tmp/original-b",
            folderGroupID: folderGroupID,
            folderOrder: 1
        )

        let workspace = Workspace(
            name: "Folder Workspace",
            workspaceWindows: [firstWindow, secondWindow]
        )

        let transformed = await MainActor.run {
            viewModel.makeQuickSwitchWorkspace(
                from: workspace,
                targetDirectoryPath: targetDirectory
            )
        }

        let transformedByID = Dictionary(uniqueKeysWithValues: transformed.windows.map { ($0.id, $0) })
        #expect(transformedByID[firstWindow.id]?.folderGroupID == folderGroupID)
        #expect(transformedByID[firstWindow.id]?.folderOrder == 0)
        #expect(transformedByID[secondWindow.id]?.folderGroupID == folderGroupID)
        #expect(transformedByID[secondWindow.id]?.folderOrder == 1)
        #expect(transformedByID[firstWindow.id]?.openPath == targetDirectory)
        #expect(transformedByID[secondWindow.id]?.openPath == targetDirectory)
    }

    @Test("QuickSwitch rewrites tmux terminals to target directory while preserving tmux mode")
    func rewritesTmuxAndPreservesNonOpenByPathWindows() async {
        let viewModel = await MainActor.run { QuickSwitchViewModel() }
        let targetDirectory = "/tmp/quick-switch-target"

        let tmuxState = TmuxSessionState(
            sessionName: "bento_test_session",
            initialWorkingDirectory: "/tmp/tmux-home"
        )

        let tmuxTerminalWindow = WorkspaceWindow(
            id: UUID(),
            bundleIdentifier: OpenByPathBundleIdentifiers.ghostty,
            appName: "Ghostty",
            windowTitle: "tmux window",
            openPath: "/tmp/original-tmux-path",
            tmuxState: tmuxState
        )

        let chromeWindow = WorkspaceWindow(
            id: UUID(),
            bundleIdentifier: BundleRegistry.chrome,
            appName: "Google Chrome",
            windowTitle: "Chrome Window"
        )

        let workspace = Workspace(
            name: "Test Workspace",
            workspaceWindows: [tmuxTerminalWindow, chromeWindow]
        )

        let transformed = await MainActor.run {
            viewModel.makeQuickSwitchWorkspace(
                from: workspace,
                targetDirectoryPath: targetDirectory
            )
        }

        let transformedByID = Dictionary(uniqueKeysWithValues: transformed.windows.map { ($0.id, $0) })
        let transformedTmux = transformedByID[tmuxTerminalWindow.id]
        #expect(transformedTmux?.openPath == targetDirectory)
        #expect(transformedTmux?.tmuxState?.sessionName == tmuxState.sessionName)
        #expect(transformedTmux?.tmuxState?.initialWorkingDirectory == targetDirectory)
        #expect(transformedTmux?.terminalKey != nil)
        #expect(transformedTmux?.terminalKey != tmuxTerminalWindow.terminalKey)
        #expect(transformedByID[chromeWindow.id]?.openPath == nil)
    }

    @Test("QuickSwitch terminal keys stay stable for shared directory slots across layouts")
    func tmuxTerminalKeysStableAcrossLayoutsForSameDirectory() async {
        let viewModel = await MainActor.run { QuickSwitchViewModel() }
        let targetDirectory = "/tmp/shared-layout-directory"

        let leftColumn = RelativeWindowFrame(xPercent: 0.0, yPercent: 0.0, widthPercent: 0.5, heightPercent: 0.5)
        let rightColumn = RelativeWindowFrame(xPercent: 0.5, yPercent: 0.0, widthPercent: 0.5, heightPercent: 0.5)
        let lowerRow = RelativeWindowFrame(xPercent: 0.0, yPercent: 0.5, widthPercent: 0.5, heightPercent: 0.5)

        let layoutA = Workspace(
            name: "Layout A",
            workspaceWindows: [
                WorkspaceWindow(
                    id: UUID(),
                    bundleIdentifier: OpenByPathBundleIdentifiers.ghostty,
                    appName: "Ghostty",
                    windowTitle: "left",
                    openPath: "/tmp/original",
                    tmuxState: TmuxSessionState(sessionName: "layoutA_left", initialWorkingDirectory: "/tmp/original"),
                    screenIndex: 0,
                    relativeFrame: leftColumn
                ),
                WorkspaceWindow(
                    id: UUID(),
                    bundleIdentifier: OpenByPathBundleIdentifiers.ghostty,
                    appName: "Ghostty",
                    windowTitle: "right",
                    openPath: "/tmp/original",
                    tmuxState: TmuxSessionState(sessionName: "layoutA_right", initialWorkingDirectory: "/tmp/original"),
                    screenIndex: 0,
                    relativeFrame: rightColumn
                )
            ]
        )

        let layoutBLeft = WorkspaceWindow(
            id: UUID(),
            bundleIdentifier: OpenByPathBundleIdentifiers.ghostty,
            appName: "Ghostty",
            windowTitle: "left-b",
            openPath: "/tmp/original",
            tmuxState: TmuxSessionState(sessionName: "layoutB_left", initialWorkingDirectory: "/tmp/original"),
            screenIndex: 0,
            relativeFrame: leftColumn
        )
        let layoutBRight = WorkspaceWindow(
            id: UUID(),
            bundleIdentifier: OpenByPathBundleIdentifiers.ghostty,
            appName: "Ghostty",
            windowTitle: "right-b",
            openPath: "/tmp/original",
            tmuxState: TmuxSessionState(sessionName: "layoutB_right", initialWorkingDirectory: "/tmp/original"),
            screenIndex: 0,
            relativeFrame: rightColumn
        )
        let layoutBLower = WorkspaceWindow(
            id: UUID(),
            bundleIdentifier: OpenByPathBundleIdentifiers.ghostty,
            appName: "Ghostty",
            windowTitle: "lower-b",
            openPath: "/tmp/original",
            tmuxState: TmuxSessionState(sessionName: "layoutB_lower", initialWorkingDirectory: "/tmp/original"),
            screenIndex: 0,
            relativeFrame: lowerRow
        )
        let layoutB = Workspace(
            name: "Layout B",
            workspaceWindows: [
                layoutBLower,
                layoutBRight,
                layoutBLeft
            ]
        )

        let transformedA = await MainActor.run {
            viewModel.makeQuickSwitchWorkspace(from: layoutA, targetDirectoryPath: targetDirectory)
        }
        let transformedB = await MainActor.run {
            viewModel.makeQuickSwitchWorkspace(from: layoutB, targetDirectoryPath: targetDirectory)
        }

        let transformedAById = Dictionary(uniqueKeysWithValues: transformedA.windows.map { ($0.id, $0) })
        let transformedBById = Dictionary(uniqueKeysWithValues: transformedB.windows.map { ($0.id, $0) })

        let layoutALeftKey = transformedAById[layoutA.windows[0].id]?.terminalKey
        let layoutARightKey = transformedAById[layoutA.windows[1].id]?.terminalKey
        let layoutBLeftKey = transformedBById[layoutBLeft.id]?.terminalKey
        let layoutBRightKey = transformedBById[layoutBRight.id]?.terminalKey
        let layoutBLowerKey = transformedBById[layoutBLower.id]?.terminalKey

        #expect(layoutALeftKey == layoutBLeftKey)
        #expect(layoutARightKey == layoutBRightKey)
        #expect(layoutBLowerKey != nil)
        #expect(layoutBLowerKey != layoutBLeftKey)
        #expect(layoutBLowerKey != layoutBRightKey)
    }

    @Test("QuickSwitch terminal keys vary by target directory")
    func tmuxTerminalKeysVaryByTargetDirectory() async {
        let viewModel = await MainActor.run { QuickSwitchViewModel() }

        let tmuxWindow = WorkspaceWindow(
            id: UUID(),
            bundleIdentifier: OpenByPathBundleIdentifiers.ghostty,
            appName: "Ghostty",
            windowTitle: "tmux window",
            terminalKey: "ghostty-main-0",
            openPath: "/tmp/original",
            tmuxState: TmuxSessionState(
                sessionName: "bento_test_session",
                initialWorkingDirectory: "/tmp/original"
            )
        )
        let workspace = Workspace(name: "Test Workspace", workspaceWindows: [tmuxWindow])

        let transformedA = await MainActor.run {
            viewModel.makeQuickSwitchWorkspace(
                from: workspace,
                targetDirectoryPath: "/tmp/dir-a"
            )
        }
        let transformedB = await MainActor.run {
            viewModel.makeQuickSwitchWorkspace(
                from: workspace,
                targetDirectoryPath: "/tmp/dir-b"
            )
        }

        #expect(transformedA.windows.first?.terminalKey != transformedB.windows.first?.terminalKey)
    }

    @Test("QuickSwitch skips Xcode for non-project targets while preserving other rewrites")
    func xcodeNonProjectTargetSkipsXcodeAndPreservesOtherRewrites() async throws {
        let viewModel = await MainActor.run { QuickSwitchViewModel() }
        let targetDirectory = try makeTempDirectory(name: "quick-switch-xcode-nonproject")
        defer { try? FileManager.default.removeItem(at: targetDirectory) }

        let xcodeWindow = WorkspaceWindow(
            id: UUID(),
            bundleIdentifier: OpenByPathBundleIdentifiers.xcode,
            appName: "Xcode",
            windowTitle: "Xcode",
            openPath: "/tmp/original/DeskJig.xcodeproj"
        )
        let ghosttyState = TmuxSessionState(
            sessionName: "bento_test_session",
            initialWorkingDirectory: "/tmp/tmux-home"
        )
        let ghosttyWindow = WorkspaceWindow(
            id: UUID(),
            bundleIdentifier: OpenByPathBundleIdentifiers.ghostty,
            appName: "Ghostty",
            windowTitle: "Ghostty",
            openPath: "/tmp/original-terminal",
            tmuxState: ghosttyState
        )
        let codexWindow = WorkspaceWindow(
            id: UUID(),
            bundleIdentifier: BundleRegistry.codex,
            appName: "Codex",
            windowTitle: "Codex",
            openPath: nil
        )

        let workspace = Workspace(
            name: "Test Workspace",
            workspaceWindows: [xcodeWindow, ghosttyWindow, codexWindow]
        )
        let transformed = await MainActor.run {
            viewModel.makeQuickSwitchWorkspaceTransformResult(
                from: workspace,
                targetDirectoryPath: targetDirectory.path
            )
        }

        let transformedByID = Dictionary(uniqueKeysWithValues: transformed.workspace.windows.map { ($0.id, $0) })

        #expect(transformed.workspace.windows.count == 2)
        #expect(transformedByID[xcodeWindow.id] == nil)
        #expect(transformed.skippedXcodeWindowCount == 1)
        #expect(transformed.skippedXcodeForNonProjectTarget)
        #expect(transformed.rewrittenWindowCount == 2)
        #expect(transformedByID[ghosttyWindow.id]?.openPath == targetDirectory.path)
        #expect(transformedByID[ghosttyWindow.id]?.tmuxState?.sessionName == ghosttyState.sessionName)
        #expect(transformedByID[ghosttyWindow.id]?.tmuxState?.initialWorkingDirectory == targetDirectory.path)
        #expect((transformedByID[ghosttyWindow.id]?.terminalKey?.isEmpty == false))
        #expect(transformedByID[codexWindow.id]?.openPath == targetDirectory.path)
    }

    @Test("QuickSwitch rewrites Xcode openPath when target directory contains project")
    func xcodeProjectDirectoryTargetRewritesOpenPath() async throws {
        let viewModel = await MainActor.run { QuickSwitchViewModel() }
        let targetDirectory = try makeTempDirectory(name: "quick-switch-xcode-project-dir")
        defer { try? FileManager.default.removeItem(at: targetDirectory) }

        let projectURL = targetDirectory.appendingPathComponent("Sample.xcodeproj", isDirectory: true)
        try FileManager.default.createDirectory(at: projectURL, withIntermediateDirectories: true)

        let xcodeWindow = WorkspaceWindow(
            id: UUID(),
            bundleIdentifier: OpenByPathBundleIdentifiers.xcode,
            appName: "Xcode",
            windowTitle: "Xcode",
            openPath: "/tmp/original/DeskJig.xcodeproj"
        )
        let workspace = Workspace(name: "Test Workspace", workspaceWindows: [xcodeWindow])

        let transformed = await MainActor.run {
            viewModel.makeQuickSwitchWorkspaceTransformResult(
                from: workspace,
                targetDirectoryPath: targetDirectory.path
            )
        }

        #expect(transformed.workspace.windows.first?.openPath == targetDirectory.path)
        #expect(transformed.rewrittenWindowCount == 1)
        #expect(transformed.skippedXcodeWindowCount == 0)
        #expect(!transformed.skippedXcodeForNonProjectTarget)
    }

    @Test("QuickSwitch rewrites Xcode openPath for explicit project path target")
    func xcodeExplicitProjectPathRewritesOpenPath() async throws {
        let viewModel = await MainActor.run { QuickSwitchViewModel() }
        let targetDirectory = try makeTempDirectory(name: "quick-switch-xcode-explicit-project")
        defer { try? FileManager.default.removeItem(at: targetDirectory) }

        let projectURL = targetDirectory.appendingPathComponent("Sample.xcworkspace", isDirectory: true)
        try FileManager.default.createDirectory(at: projectURL, withIntermediateDirectories: true)

        let xcodeWindow = WorkspaceWindow(
            id: UUID(),
            bundleIdentifier: OpenByPathBundleIdentifiers.xcode,
            appName: "Xcode",
            windowTitle: "Xcode",
            openPath: "/tmp/original/DeskJig.xcodeproj"
        )
        let workspace = Workspace(name: "Test Workspace", workspaceWindows: [xcodeWindow])

        let transformed = await MainActor.run {
            viewModel.makeQuickSwitchWorkspace(
                from: workspace,
                targetDirectoryPath: projectURL.path
            )
        }

        #expect(transformed.windows.first?.openPath == projectURL.path)
    }

    @Test("QuickSwitch mixed matching keeps strict filtering and name-dominant ranking")
    func quickSwitchSearchRankingAndFiltering() {
        let directories = [
            ScannedDirectory(name: "deskjig", path: "/Users/andrew/code/deskjig", rootFolder: "~/code"),
            ScannedDirectory(name: "alexandria", path: "/Users/andrew/code/alexandria", rootFolder: "~/code"),
            ScannedDirectory(name: "toolbox", path: "/Users/andrew/code/deskjig-tools/toolbox", rootFolder: "~/code")
        ]

        let ranked = QuickSwitchSearch.rankedDirectories(
            directories,
            query: "deskjig",
            favoriteDirectoryPaths: []
        )
        #expect(ranked.count == 2)
        #expect(ranked.first?.name == "deskjig")
        #expect(ranked.map(\.name).contains("toolbox"))
        #expect(!ranked.map(\.name).contains("alexandria"))
    }

    @Test("QuickSwitch mixed matching accepts path tokens")
    func quickSwitchSearchPathTokens() {
        let directories = [
            ScannedDirectory(name: "archive", path: "/Users/andrew/code/archived_code", rootFolder: "~/code"),
            ScannedDirectory(name: "deskjig", path: "/Users/andrew/code/deskjig", rootFolder: "~/code")
        ]

        let ranked = QuickSwitchSearch.rankedDirectories(
            directories,
            query: "archived/code",
            favoriteDirectoryPaths: []
        )
        #expect(ranked.count == 1)
        #expect(ranked.first?.name == "archive")
    }

    @Test("QuickSwitch favorites rank above stronger score matches")
    func quickSwitchSearchFavoritesPrecedeScore() {
        let directories = [
            ScannedDirectory(name: "deskjig", path: "/Users/andrew/code/deskjig", rootFolder: "~/code"),
            ScannedDirectory(name: "deskjig-tools", path: "/Users/andrew/code/deskjig-tools", rootFolder: "~/code")
        ]

        let ranked = QuickSwitchSearch.rankedDirectories(
            directories,
            query: "deskjig",
            favoriteDirectoryPaths: ["/Users/andrew/code/deskjig-tools"]
        )

        #expect(ranked.first?.path == "/Users/andrew/code/deskjig-tools")
    }

    @Test("QuickSwitch same-name ranking prefers shorter paths")
    func quickSwitchSearchShorterPathPreference() {
        let directories = [
            ScannedDirectory(name: "api", path: "/Users/andrew/code/team/api", rootFolder: "~/code"),
            ScannedDirectory(name: "api", path: "/Users/andrew/code/api", rootFolder: "~/code"),
            ScannedDirectory(name: "api", path: "/Users/andrew/projects/xx/api", rootFolder: "~/projects")
        ]

        let ranked = QuickSwitchSearch.rankedDirectories(
            directories,
            query: "api",
            favoriteDirectoryPaths: []
        )

        #expect(ranked[0].path == "/Users/andrew/code/api")
    }

    @Test("QuickSwitch empty query still keeps favorites at top")
    func quickSwitchSearchEmptyQueryFavoriteOrder() {
        let directories = [
            ScannedDirectory(name: "beta", path: "/Users/andrew/code/beta", rootFolder: "~/code"),
            ScannedDirectory(name: "alpha", path: "/Users/andrew/code/alpha", rootFolder: "~/code")
        ]

        let ranked = QuickSwitchSearch.rankedDirectories(
            directories,
            query: "",
            favoriteDirectoryPaths: ["/Users/andrew/code/beta"]
        )

        #expect(ranked.first?.path == "/Users/andrew/code/beta")
    }

    @Test("QuickSwitch resolve prefers directory override over global and recent")
    func resolvePrefersOverride() async {
        let (viewModel, defaults, suiteName) = await makeIsolatedQuickSwitchViewModel()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let directoryPath = "/tmp/override-priority"

        let globalWorkspace = Workspace(name: "Global", workspaceWindows: [])
        let recentWorkspace = Workspace(name: "Recent", workspaceWindows: []).withActivationTime(Date())
        let overrideWorkspace = Workspace(name: "Override", workspaceWindows: [])
        let savedWorkspaces = [globalWorkspace, recentWorkspace, overrideWorkspace]

        await MainActor.run {
            viewModel.globalDefaultWorkspaceId = globalWorkspace.id.uuidString
            viewModel.setDirectoryOverride(for: directoryPath, workspaceId: overrideWorkspace.id)
        }

        let resolved = await MainActor.run {
            viewModel.resolveDefaultWorkspace(for: directoryPath, savedWorkspaces: savedWorkspaces)
        }

        #expect(resolved?.id == overrideWorkspace.id)
    }

    @Test("QuickSwitch resolve prefers global default over most recent when no override")
    func resolvePrefersGlobalOverRecent() async {
        let (viewModel, defaults, suiteName) = await makeIsolatedQuickSwitchViewModel()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let directoryPath = "/tmp/global-priority"

        let globalWorkspace = Workspace(name: "Global", workspaceWindows: [])
        let recentWorkspace = Workspace(name: "Recent", workspaceWindows: []).withActivationTime(Date())
        let savedWorkspaces = [recentWorkspace, globalWorkspace]

        await MainActor.run {
            viewModel.globalDefaultWorkspaceId = globalWorkspace.id.uuidString
        }

        let resolved = await MainActor.run {
            viewModel.resolveDefaultWorkspace(for: directoryPath, savedWorkspaces: savedWorkspaces)
        }

        #expect(resolved?.id == globalWorkspace.id)
    }

    @Test("QuickSwitch resolve falls back to oldest created workspace when no override or global default")
    func resolveFallsBackToOldestCreatedOverRecent() async {
        let (viewModel, defaults, suiteName) = await makeIsolatedQuickSwitchViewModel()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let directoryPath = "/tmp/stable-fallback-priority"

        let oldestWorkspace = Workspace.migrated(
            id: UUID(),
            name: "Oldest",
            icon: nil,
            createdAt: Date(timeIntervalSince1970: 1_000),
            lastActivatedAt: nil,
            windows: [],
            screens: nil
        )
        let recentWorkspace = Workspace.migrated(
            id: UUID(),
            name: "Recent",
            icon: nil,
            createdAt: Date(timeIntervalSince1970: 2_000),
            lastActivatedAt: Date(),
            windows: [],
            screens: nil
        )
        // Recently-activated workspace listed first: neither array order nor
        // recency may beat the stable fallback (oldest createdAt wins).
        let savedWorkspaces = [recentWorkspace, oldestWorkspace]

        let resolved = await MainActor.run {
            viewModel.resolveDefaultWorkspace(for: directoryPath, savedWorkspaces: savedWorkspaces)
        }

        #expect(resolved?.id == oldestWorkspace.id)
    }

    @Test("QuickSwitch set and clear directory override APIs persist lookup values")
    func directoryOverrideAPIs() async {
        let (viewModel, defaults, suiteName) = await makeIsolatedQuickSwitchViewModel()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let directoryPath = "/tmp/override-api"
        let workspaceId = UUID()

        await MainActor.run {
            viewModel.setDirectoryOverride(for: directoryPath, workspaceId: workspaceId)
        }

        let storedId = await MainActor.run {
            viewModel.directoryOverrideWorkspaceId(for: directoryPath)
        }
        #expect(storedId == workspaceId)

        await MainActor.run {
            viewModel.clearDirectoryOverride(for: directoryPath)
        }

        let clearedId = await MainActor.run {
            viewModel.directoryOverrideWorkspaceId(for: directoryPath)
        }
        #expect(clearedId == nil)
    }

    @Test("QuickSwitch prune skips clearing selections when workspace list is temporarily empty")
    func pruneSkipsEmptyWorkspaceHydration() async {
        let (viewModel, defaults, suiteName) = await makeIsolatedQuickSwitchViewModel()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let directoryPath = "/tmp/prune-hydration"
        let workspaceId = UUID()

        await MainActor.run {
            viewModel.globalDefaultWorkspaceId = workspaceId.uuidString
            viewModel.setDirectoryOverride(for: directoryPath, workspaceId: workspaceId)
            viewModel.pruneInvalidLayoutSelections(savedWorkspaces: [])
        }

        let overrideId = await MainActor.run {
            viewModel.directoryOverrideWorkspaceId(for: directoryPath)
        }

        #expect(overrideId == workspaceId)
        #expect(await MainActor.run { viewModel.globalDefaultWorkspaceId } == workspaceId.uuidString)
    }

    @Test("QuickSwitch favorite APIs persist lookup values and normalize paths")
    func directoryFavoriteAPIs() async {
        let (viewModel, defaults, suiteName) = await makeIsolatedQuickSwitchViewModel()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let normalizedPath = "/tmp/favorite-api"
        let nonNormalizedPath = "/tmp/quick-switch/../favorite-api"

        await MainActor.run {
            viewModel.setDirectoryFavorite(for: nonNormalizedPath, isFavorite: true)
        }

        let isFavorited = await MainActor.run {
            viewModel.isDirectoryFavorite(normalizedPath)
        }
        #expect(isFavorited)

        await MainActor.run {
            viewModel.toggleDirectoryFavorite(for: normalizedPath)
        }

        let toggledOff = await MainActor.run {
            viewModel.isDirectoryFavorite(normalizedPath)
        }
        #expect(!toggledOff)

        await MainActor.run {
            viewModel.setDirectoryFavorite(for: normalizedPath, isFavorite: false)
        }

        let clearedFavorite = await MainActor.run {
            viewModel.isDirectoryFavorite(normalizedPath)
        }
        #expect(!clearedFavorite)
    }

    @Test("QuickSwitch reload does not auto-import legacy container preferences")
    func reloadDoesNotAutoImportLegacyContainerPreferences() async throws {
        let suiteName = "QuickSwitchViewModelTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            fatalError("Failed to create isolated UserDefaults suite \(suiteName)")
        }
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let userID = "test-user-id"
        let perUserDefaultsManager = PerUserDefaultsManager(userDefaults: defaults)

        let rootFolders = [
            QuickSwitchRootFolder(
                id: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!,
                path: "/Users/brutus/code",
                scanDepth: 2,
                isEnabled: true
            )
        ]
        let directoryOverrides = ["/Users/brutus/code/nexus": UUID().uuidString]
        let favoriteDirectories = ["/Users/brutus/code/nexus"]
        let rootFolderData = try JSONEncoder().encode(rootFolders)
        let directoryOverrideData = try JSONEncoder().encode(directoryOverrides)
        let favoriteDirectoriesData = try JSONEncoder().encode(favoriteDirectories)

        let legacyPreferencesURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("quick-switch-legacy-\(UUID().uuidString).plist")
        defer { try? FileManager.default.removeItem(at: legacyPreferencesURL) }

        let legacyPreferences: NSDictionary = [
            "\(userID).quickSwitch.rootFolders": rootFolderData,
            "\(userID).quickSwitch.directoryOverrides": directoryOverrideData,
            "\(userID).quickSwitch.favoriteDirectories": favoriteDirectoriesData,
            "\(userID).quickSwitch.globalDefaultWorkspaceId": "workspace-id-123",
            "\(userID).quickSwitch.worktreeStoragePath": "/Users/brutus/.codex/worktrees",
            "\(userID).quickSwitch.worktreeBranchPrefix": "wt/",
            "quickSwitch.migrationOwner": userID
        ]
        #expect(legacyPreferences.write(to: legacyPreferencesURL, atomically: true))

        let viewModel = await MainActor.run {
            QuickSwitchViewModel(
                perUserDefaultsManager: perUserDefaultsManager,
                userDefaults: defaults,
                legacyPreferencesURL: legacyPreferencesURL
            )
        }

        #expect(await MainActor.run { viewModel.rootFolders.isEmpty })
        #expect(await MainActor.run { viewModel.directoryOverrides.isEmpty })
        #expect(await MainActor.run { viewModel.favoriteDirectories.isEmpty })
        #expect(await MainActor.run { viewModel.globalDefaultWorkspaceId } == nil)
        #expect(defaults.data(forKey: "quickSwitch.rootFolders") == nil)
        #expect(defaults.data(forKey: "quickSwitch.directoryOverrides") == nil)
        #expect(defaults.data(forKey: "quickSwitch.favoriteDirectories") == nil)
        #expect(defaults.string(forKey: "quickSwitch.globalDefaultWorkspaceId") == nil)
    }

    @Test("QuickSwitch manual legacy import recovers missing settings from legacy container preferences")
    func manualImportRecoversLegacyContainerPreferences() async throws {
        let suiteName = "QuickSwitchViewModelTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            fatalError("Failed to create isolated UserDefaults suite \(suiteName)")
        }
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let userID = "test-user-id"
        let perUserDefaultsManager = PerUserDefaultsManager(userDefaults: defaults)

        let rootFolders = [
            QuickSwitchRootFolder(
                id: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!,
                path: "/Users/brutus/code",
                scanDepth: 2,
                isEnabled: true
            )
        ]
        let directoryOverrides = ["/Users/brutus/code/nexus": UUID().uuidString]
        let favoriteDirectories = ["/Users/brutus/code/nexus"]
        let rootFolderData = try JSONEncoder().encode(rootFolders)
        let directoryOverrideData = try JSONEncoder().encode(directoryOverrides)
        let favoriteDirectoriesData = try JSONEncoder().encode(favoriteDirectories)

        let legacyPreferencesURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("quick-switch-legacy-\(UUID().uuidString).plist")
        defer { try? FileManager.default.removeItem(at: legacyPreferencesURL) }

        let legacyPreferences: NSDictionary = [
            "\(userID).quickSwitch.rootFolders": rootFolderData,
            "\(userID).quickSwitch.directoryOverrides": directoryOverrideData,
            "\(userID).quickSwitch.favoriteDirectories": favoriteDirectoriesData,
            "\(userID).quickSwitch.globalDefaultWorkspaceId": "workspace-id-123",
            "\(userID).quickSwitch.worktreeStoragePath": "/Users/brutus/.codex/worktrees",
            "\(userID).quickSwitch.worktreeBranchPrefix": "wt/",
            "quickSwitch.migrationOwner": userID
        ]
        #expect(legacyPreferences.write(to: legacyPreferencesURL, atomically: true))

        let viewModel = await MainActor.run {
            QuickSwitchViewModel(
                perUserDefaultsManager: perUserDefaultsManager,
                userDefaults: defaults,
                legacyPreferencesURL: legacyPreferencesURL
            )
        }

        let result = await MainActor.run {
            viewModel.importLegacyQuickSwitchSettings()
        }

        #expect(result == .imported)
        #expect(await MainActor.run { viewModel.rootFolders } == rootFolders)
        #expect(await MainActor.run { viewModel.directoryOverrides } == directoryOverrides)
        #expect(await MainActor.run { viewModel.favoriteDirectories } == Set(favoriteDirectories))
        #expect(await MainActor.run { viewModel.globalDefaultWorkspaceId } == "workspace-id-123")
        #expect(await MainActor.run { viewModel.worktreeStoragePath } == "/Users/brutus/.codex/worktrees")
        #expect(await MainActor.run { viewModel.worktreeBranchPrefix } == "wt/")
        #expect(await MainActor.run { viewModel.lastLegacyImportAt } != nil)

        #expect(defaults.data(forKey: "quickSwitch.rootFolders") == rootFolderData)
        #expect(defaults.data(forKey: "quickSwitch.directoryOverrides") == directoryOverrideData)
        #expect(defaults.data(forKey: "quickSwitch.favoriteDirectories") == favoriteDirectoriesData)
        #expect(defaults.string(forKey: "quickSwitch.globalDefaultWorkspaceId") == "workspace-id-123")
        #expect(defaults.string(forKey: "quickSwitch.worktreeStoragePath") == "/Users/brutus/.codex/worktrees")
        #expect(defaults.string(forKey: "quickSwitch.worktreeBranchPrefix") == "wt/")
    }

    @Test("QuickSwitch launch does not mutate directory overrides")
    func launchDoesNotMutateOverrides() async {
        let (viewModel, defaults, suiteName) = await makeIsolatedQuickSwitchViewModel()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let targetDirectory = ScannedDirectory(name: "deskjig", path: "/tmp/deskjig", rootFolder: "/tmp")
        let untouchedDirectoryPath = "/tmp/untouched"
        let existingWorkspaceId = UUID()
        var launchCalled = false

        let workspace = Workspace(name: "Launch Workspace", workspaceWindows: [])

        await MainActor.run {
            viewModel.setDirectoryOverride(for: untouchedDirectoryPath, workspaceId: existingWorkspaceId)
            viewModel.switchToDirectory(targetDirectory, layout: workspace) { _, _, _, _ in
                launchCalled = true
            }
        }

        let targetOverride = await MainActor.run {
            viewModel.directoryOverrideWorkspaceId(for: targetDirectory.path)
        }
        let untouchedOverride = await MainActor.run {
            viewModel.directoryOverrideWorkspaceId(for: untouchedDirectoryPath)
        }

        #expect(launchCalled)
        #expect(targetOverride == nil)
        #expect(untouchedOverride == existingWorkspaceId)
    }

    private func makeIsolatedQuickSwitchViewModel() async -> (QuickSwitchViewModel, UserDefaults, String) {
        let suiteName = "QuickSwitchViewModelTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            fatalError("Failed to create isolated UserDefaults suite \(suiteName)")
        }
        defaults.removePersistentDomain(forName: suiteName)
        let perUserDefaultsManager = PerUserDefaultsManager(userDefaults: defaults)
        let viewModel = await MainActor.run {
            QuickSwitchViewModel(
                perUserDefaultsManager: perUserDefaultsManager,
                userDefaults: defaults
            )
        }
        return (viewModel, defaults, suiteName)
    }

    @Test("Clamp compensation shrinks left neighbor when right app expands left")
    func clampCompensationLeftNeighbor() {
        let leftNeighbor = CGRect(x: 0, y: 0, width: 600, height: 900)
        let clampedOriginal = CGRect(x: 600, y: 0, width: 600, height: 900)
        let clampedActual = CGRect(x: 500, y: 0, width: 700, height: 900)

        let adjusted = WindowPositioningService.compensatedFrame(
            for: leftNeighbor,
            clampedOriginal: clampedOriginal,
            clampedActual: clampedActual
        )

        #expect(adjusted.origin.x == 0)
        #expect(abs(adjusted.width - 500) < 0.1)
    }

    @Test("Clamp compensation shifts and shrinks right neighbor when left app expands right")
    func clampCompensationRightNeighbor() {
        let rightNeighbor = CGRect(x: 600, y: 0, width: 600, height: 900)
        let clampedOriginal = CGRect(x: 0, y: 0, width: 600, height: 900)
        let clampedActual = CGRect(x: 0, y: 0, width: 700, height: 900)

        let adjusted = WindowPositioningService.compensatedFrame(
            for: rightNeighbor,
            clampedOriginal: clampedOriginal,
            clampedActual: clampedActual
        )

        #expect(abs(adjusted.origin.x - 700) < 0.1)
        #expect(abs(adjusted.width - 500) < 0.1)
    }

    @Test("Clamp compensation shifts and shrinks lower neighbor for vertical expansion")
    func clampCompensationVerticalNeighbor() {
        let lowerNeighbor = CGRect(x: 0, y: 500, width: 1200, height: 500)
        let clampedOriginal = CGRect(x: 0, y: 0, width: 1200, height: 500)
        let clampedActual = CGRect(x: 0, y: 0, width: 1200, height: 600)

        let adjusted = WindowPositioningService.compensatedFrame(
            for: lowerNeighbor,
            clampedOriginal: clampedOriginal,
            clampedActual: clampedActual
        )

        #expect(abs(adjusted.origin.y - 600) < 0.1)
        #expect(abs(adjusted.height - 400) < 0.1)
    }

    @Test("Clamp compensation uses bounded fallback when expansion exceeds available width")
    func clampCompensationBoundedFallback() {
        let rightNeighbor = CGRect(x: 600, y: 0, width: 600, height: 900)
        let clampedOriginal = CGRect(x: 0, y: 0, width: 600, height: 900)
        let clampedActual = CGRect(x: 0, y: 0, width: 1500, height: 900)

        let adjusted = WindowPositioningService.compensatedFrame(
            for: rightNeighbor,
            clampedOriginal: clampedOriginal,
            clampedActual: clampedActual
        )

        #expect(abs(adjusted.width - 1) < 0.1)
    }

    @Test("Xcode left-expansion compensation rebalances two iTerm siblings equally")
    func rowRedistributionBalancesITermSiblingsAfterXcodeExpansion() {
        let siblingLeft = WindowLockManager.PositionedFrame(
            windowId: 1001,
            bundleId: OpenByPathBundleIdentifiers.iterm2,
            originalTarget: CGRect(x: 0, y: 552.5, width: 672, height: 527.5),
            effectiveTarget: CGRect(x: 0, y: 552.5, width: 672, height: 527.5),
            finalFrame: CGRect(x: 0, y: 552.5, width: 672, height: 527.5)
        )
        let siblingRight = WindowLockManager.PositionedFrame(
            windowId: 1002,
            bundleId: OpenByPathBundleIdentifiers.iterm2,
            originalTarget: CGRect(x: 672, y: 552.5, width: 672, height: 527.5),
            effectiveTarget: CGRect(x: 672, y: 552.5, width: 672, height: 527.5),
            finalFrame: CGRect(x: 672, y: 552.5, width: 672, height: 527.5)
        )
        let clampedFrame = WindowLockManager.ClampedFrame(
            windowId: 2001,
            originalTarget: CGRect(x: 1344, y: 0, width: 576, height: 1055),
            actualFrame: CGRect(x: 980, y: 0, width: 940, height: 1055)
        )

        let targets = WindowPositioningService.calculateRowRedistributionTargets(
            rowSiblings: [siblingLeft, siblingRight],
            clampedFrame: clampedFrame
        )
        #expect(targets.count == 2)

        let widths = targets.map { Int($0.targetFrame.width.rounded()) }.sorted()
        #expect(widths == [490, 490])
    }

    @Test("Clamp registration upserts latest clamp for same window")
    func clampedFrameUpsertReplacesPriorWindowState() async {
        let lockManager = WindowLockManager()
        let runId = "test-run-\(UUID().uuidString)"
        let windowId: CGWindowID = 4242

        await lockManager.registerClampedFrame(
            runId: runId,
            windowId: windowId,
            originalTarget: CGRect(x: 100, y: 0, width: 400, height: 800),
            actualFrame: CGRect(x: 80, y: 0, width: 420, height: 800)
        )
        await lockManager.registerClampedFrame(
            runId: runId,
            windowId: windowId,
            originalTarget: CGRect(x: 120, y: 0, width: 380, height: 800),
            actualFrame: CGRect(x: 90, y: 0, width: 410, height: 800)
        )

        let clampedFrames = await lockManager.getClampedFrames(for: runId)
        #expect(clampedFrames.count == 1)
        #expect(clampedFrames.first?.windowId == windowId)
        #expect(clampedFrames.first?.originalTarget == CGRect(x: 120, y: 0, width: 380, height: 800))
        #expect(clampedFrames.first?.actualFrame == CGRect(x: 90, y: 0, width: 410, height: 800))
    }

    @Test("Row redistribution uses effective targets for proportions")
    func rowRedistributionUsesEffectiveTargetsNotOriginalTargets() {
        let left = WindowLockManager.PositionedFrame(
            windowId: 3001,
            bundleId: OpenByPathBundleIdentifiers.iterm2,
            originalTarget: CGRect(x: 0, y: 500, width: 500, height: 500),
            effectiveTarget: CGRect(x: 0, y: 500, width: 300, height: 500),
            finalFrame: CGRect(x: 0, y: 500, width: 300, height: 500)
        )
        let right = WindowLockManager.PositionedFrame(
            windowId: 3002,
            bundleId: OpenByPathBundleIdentifiers.iterm2,
            originalTarget: CGRect(x: 500, y: 500, width: 500, height: 500),
            effectiveTarget: CGRect(x: 300, y: 500, width: 700, height: 500),
            finalFrame: CGRect(x: 300, y: 500, width: 700, height: 500)
        )
        let clampedFrame = WindowLockManager.ClampedFrame(
            windowId: 3999,
            originalTarget: CGRect(x: 1000, y: 0, width: 600, height: 1000),
            actualFrame: CGRect(x: 900, y: 0, width: 700, height: 1000)
        )

        let targets = WindowPositioningService.calculateRowRedistributionTargets(
            rowSiblings: [left, right],
            clampedFrame: clampedFrame
        )
        #expect(targets.count == 2)

        let targetsByWindowId = Dictionary(uniqueKeysWithValues: targets.map { ($0.windowId, $0.targetFrame) })
        let leftWidth = Int((targetsByWindowId[CGWindowID(3001)]?.width ?? 0).rounded())
        let rightWidth = Int((targetsByWindowId[CGWindowID(3002)]?.width ?? 0).rounded())
        #expect(leftWidth == 270)
        #expect(rightWidth == 630)
        #expect(Int((targetsByWindowId[CGWindowID(3002)]?.origin.x ?? 0).rounded()) == 270)
    }

    @Test("Top-row Ghostty width reduces when Xcode expands left")
    func topRowGhosttyRightEdgeCompensatesForXcodeExpansion() {
        let ghosttyTarget = CGRect(x: 0, y: 25, width: 1344, height: 527.5)
        let xcodeOriginal = CGRect(x: 1344, y: 0, width: 576, height: 1055)
        let xcodeActual = CGRect(x: 980, y: 0, width: 940, height: 1055)

        let adjusted = WindowPositioningService.compensatedFrame(
            for: ghosttyTarget,
            clampedOriginal: xcodeOriginal,
            clampedActual: xcodeActual
        )

        #expect(abs(adjusted.origin.x - 0) < 0.1)
        #expect(abs(adjusted.width - 980) < 0.1)
    }

    private func makeTempDirectory(name: String) throws -> URL {
        let base = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        let url = base.appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
