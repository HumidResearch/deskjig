//  WorkspaceCommand.swift
//  DeskJigCLI

import ArgumentParser
import Foundation
import DeskJigShared

struct WorkspaceCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "workspace",
        abstract: "Workspace operations",
        subcommands: [
            List.self,
            CreateFromSpec.self,
            Info.self,
            Edit.self,
            Window.self,
            Restore.self,
            RestoreFile.self,
            Delete.self,
            Import.self,
            QuickSwitch.self
        ]
    )

    @OptionGroup var globalOptions: GlobalOptions

    mutating func run() async throws {
        throw CleanExit.helpRequest(self)
    }

    struct List: AsyncParsableCommand {
        @OptionGroup var globalOptions: GlobalOptions

        mutating func run() async throws {
            try await DeskJigRunner.run(
                actions: [.listWorkspaces],
                options: globalOptions,
                requireAccessibility: false
            )
        }
    }

    struct Info: AsyncParsableCommand {
        @Argument(help: "Workspace name")
        var name: String

        @OptionGroup var globalOptions: GlobalOptions

        mutating func run() async throws {
            try await DeskJigRunner.run(
                actions: [.workspaceInfo(name: name)],
                options: globalOptions,
                requireAccessibility: false
            )
        }
    }

    struct CreateFromSpec: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "create-from-spec",
            abstract: "Create or replace a saved workspace from a JSON spec"
        )

        @Flag(name: .customLong("stdin"), help: "Read the workspace spec from stdin")
        var readFromStdin: Bool = false

        @Option(name: .customLong("file"), help: "Read the workspace spec from a JSON file")
        var file: String?

        @OptionGroup var globalOptions: GlobalOptions

        mutating func run() async throws {
            if readFromStdin == (file != nil) {
                throw ValidationError("Specify exactly one of --stdin or --file.")
            }

            let data: Data
            if readFromStdin {
                data = FileHandle.standardInput.readDataToEndOfFile()
            } else {
                let url = URL(fileURLWithPath: file!).standardizedFileURL
                data = try Data(contentsOf: url)
            }

            guard !data.isEmpty else {
                throw ValidationError("Workspace spec input was empty.")
            }

            let decoder = JSONDecoder()
            let spec: WorkspaceCreationSpec
            do {
                spec = try decoder.decode(WorkspaceCreationSpec.self, from: data)
            } catch {
                throw ValidationError("Failed to decode workspace spec JSON: \(error.localizedDescription)")
            }

            try await DeskJigRunner.run(
                actions: [.workspaceCreateFromSpec(spec: spec)],
                options: globalOptions,
                requireAccessibility: false
            )
        }
    }

    struct Edit: AsyncParsableCommand {
        @Option(name: .customLong("name"), help: "Workspace name")
        var name: String

        @Option(name: .customLong("rename"), help: "New workspace name")
        var rename: String?

        @Option(name: .customLong("icon"), help: "New workspace icon")
        var icon: String?

        @Option(name: .customLong("shortcut"), help: "Keyboard shortcut (e.g. cmd+shift+1)")
        var shortcut: String?

        @OptionGroup var globalOptions: GlobalOptions

        mutating func run() async throws {
            let action = CLIAction.workspaceEdit(
                name: name,
                rename: rename,
                icon: icon,
                shortcut: shortcut
            )
            try await DeskJigRunner.run(actions: [action], options: globalOptions, requireAccessibility: false)
        }
    }

    struct Window: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "window",
            abstract: "Edit workspace windows",
            subcommands: [
                List.self,
                Update.self,
                Add.self,
                Remove.self
            ]
        )

        @OptionGroup var globalOptions: GlobalOptions

        mutating func run() async throws {
            throw CleanExit.helpRequest(self)
        }

        struct List: AsyncParsableCommand {
            @Option(name: .customLong("name"), help: "Workspace name")
            var name: String

            @OptionGroup var globalOptions: GlobalOptions

            mutating func run() async throws {
                let action = CLIAction.workspaceWindowList(name: name)
                try await DeskJigRunner.run(actions: [action], options: globalOptions, requireAccessibility: false)
            }
        }

        struct Update: AsyncParsableCommand {
            @Option(name: .customLong("name"), help: "Workspace name")
            var name: String

            @Option(name: .customLong("index"), help: "Window index (0-based)")
            var index: Int

            @Option(name: .customLong("position"), help: "Position preset (left-half, top-left-quarter, etc.)")
            var position: WindowPosition?

            @Option(name: .customLong("screen"), help: "Target screen index (0-based)")
            var screen: Int?

            @Option(name: .customLong("open-path"), help: "Directory path to open")
            var openPath: String?

            @Option(name: .customLong("title"), help: "Window title override")
            var title: String?

            @OptionGroup var globalOptions: GlobalOptions

            mutating func run() async throws {
                let action = CLIAction.workspaceWindowUpdate(
                    name: name,
                    index: index,
                    position: position?.rawValue,
                    screen: screen,
                    openPath: openPath,
                    title: title
                )
                try await DeskJigRunner.run(actions: [action], options: globalOptions, requireAccessibility: false)
            }
        }

        struct Add: AsyncParsableCommand {
            @Option(name: .customLong("name"), help: "Workspace name")
            var name: String

            @Option(name: .customLong("app"), help: "Known app alias (ghostty, terminal, iterm, kitty, alacritty, cursor, codex, vscode, xcode)")
            var app: String?

            @Option(name: .customLong("bundle-id"), help: "App bundle identifier")
            var bundleID: String?

            @Option(name: .customLong("app-name"), help: "App display name")
            var appName: String?

            @Option(name: .customLong("title"), help: "Window title")
            var title: String?

            @Option(name: .customLong("open-path"), help: "Directory path to open")
            var openPath: String?

            @Option(name: .customLong("position"), help: "Position preset (left-half, top-left-quarter, etc.)")
            var position: WindowPosition?

            @Option(name: .customLong("screen"), help: "Target screen index (0-based)")
            var screen: Int?

            @OptionGroup var globalOptions: GlobalOptions

            mutating func run() async throws {
                if app == nil && bundleID == nil {
                    throw ValidationError("Specify --app or --bundle-id.")
                }

                let action = CLIAction.workspaceWindowAdd(
                    name: name,
                    bundleID: bundleID,
                    appAlias: app,
                    appName: appName,
                    title: title,
                    openPath: openPath,
                    position: position?.rawValue,
                    screen: screen
                )
                try await DeskJigRunner.run(actions: [action], options: globalOptions, requireAccessibility: false)
            }
        }

        struct Remove: AsyncParsableCommand {
            @Option(name: .customLong("name"), help: "Workspace name")
            var name: String

            @Option(name: .customLong("index"), help: "Window index (0-based)")
            var index: Int

            @OptionGroup var globalOptions: GlobalOptions

            mutating func run() async throws {
                let action = CLIAction.workspaceWindowRemove(name: name, index: index)
                try await DeskJigRunner.run(actions: [action], options: globalOptions, requireAccessibility: false)
            }
        }
    }

    struct Restore: AsyncParsableCommand {
        @Argument(help: "Workspace name")
        var name: String

        @Flag(name: .customLong("hide-all-apps"), help: "Hide all apps before restore")
        var hideAllApps: Bool = false

        @Option(name: .customLong("override-file"), help: "Path to JSON overrides file")
        var overrideFile: String?

        @Option(name: .customLong("window-path"), help: "Override open path by window index (index:path)")
        var windowPaths: [String] = []

        @Option(name: .customLong("chrome-profile"), help: "Override Chrome profile (index:profileDir:displayName[:hostedDomain])")
        var chromeProfiles: [String] = []

        @Option(name: .customLong("chrome-tabs"), help: "Override Chrome tabs (index:url1,url2,...)")
        var chromeTabs: [String] = []

        @Option(name: .customLong("chrome-tabs-file"), help: "Override Chrome tabs from file (index:path)")
        var chromeTabsFiles: [String] = []

        @OptionGroup var globalOptions: GlobalOptions

        mutating func run() async throws {
            let windowOverrides = try WorkspaceOverrideParsing.parseWindowOverrides(
                windowPaths: windowPaths,
                chromeProfiles: chromeProfiles,
                chromeTabs: chromeTabs,
                chromeTabsFiles: chromeTabsFiles
            )
            let options = RestoreWorkspaceOptions(
                name: name,
                hideAllApps: hideAllApps ? true : nil,
                overrideFilePath: overrideFile,
                windowOverrides: windowOverrides
            )
            try await DeskJigRunner.run(actions: [.restoreWorkspace(options: options)], options: globalOptions)
        }
    }

    struct RestoreFile: AsyncParsableCommand {
        static let configuration = CommandConfiguration(commandName: "restore-file")

        @Argument(help: "Path to workspace file")
        var path: String

        @Option(name: .customLong("override-file"), help: "Path to JSON overrides file")
        var overrideFile: String?

        @Option(name: .customLong("window-path"), help: "Override open path by window index (index:path)")
        var windowPaths: [String] = []

        @Option(name: .customLong("chrome-profile"), help: "Override Chrome profile (index:profileDir:displayName[:hostedDomain])")
        var chromeProfiles: [String] = []

        @Option(name: .customLong("chrome-tabs"), help: "Override Chrome tabs (index:url1,url2,...)")
        var chromeTabs: [String] = []

        @Option(name: .customLong("chrome-tabs-file"), help: "Override Chrome tabs from file (index:path)")
        var chromeTabsFiles: [String] = []

        @OptionGroup var globalOptions: GlobalOptions

        mutating func run() async throws {
            let windowOverrides = try WorkspaceOverrideParsing.parseWindowOverrides(
                windowPaths: windowPaths,
                chromeProfiles: chromeProfiles,
                chromeTabs: chromeTabs,
                chromeTabsFiles: chromeTabsFiles
            )
            let options = RestoreWorkspaceFileOptions(
                path: path,
                overrideFilePath: overrideFile,
                windowOverrides: windowOverrides
            )
            try await DeskJigRunner.run(actions: [.restoreWorkspaceFile(options: options)], options: globalOptions)
        }
    }

    struct Delete: AsyncParsableCommand {
        @Argument(help: "Workspace name")
        var name: String

        @OptionGroup var globalOptions: GlobalOptions

        mutating func run() async throws {
            try await DeskJigRunner.run(
                actions: [.deleteWorkspace(name: name)],
                options: globalOptions,
                requireAccessibility: false
            )
        }
    }

    struct Import: AsyncParsableCommand {
        @Argument(help: "Path to workspace file")
        var path: String

        @Flag(name: .customLong("replace"), help: "Replace existing workspace if name matches")
        var replaceExisting: Bool = false

        @OptionGroup var globalOptions: GlobalOptions

        mutating func run() async throws {
            let action = CLIAction.workspaceImportFile(path: path, replaceExisting: replaceExisting)
            try await DeskJigRunner.run(
                actions: [action],
                options: globalOptions,
                requireAccessibility: false
            )
        }
    }

    struct QuickSwitch: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "quick-switch",
            abstract: "Quick-switch workspace by directory",
            discussion: """
            Triggers a quick-switch workspace restore via the running DeskJig.app.
            Uses the bento://quick-switch URL scheme to delegate to the app.

            Examples:
              deskjig workspace quick-switch                          # Switch using cwd
              deskjig workspace quick-switch deskjig                    # Switch by name or path
              deskjig workspace quick-switch --directory ~/code/foo   # Switch by flag
              deskjig workspace quick-switch --workspace "backend"    # Override workspace
              deskjig workspace quick-switch --approve                # Ask for approval first
              deskjig workspace quick-switch --approve --title "Codex wants your attention"
              deskjig workspace quick-switch --approve --subtext "Ready for you to test workspace restore." # Custom subline
              deskjig workspace quick-switch --approve --requester-app "Codex"
              deskjig workspace quick-switch --approve --requester-bundle-id com.example.app
              deskjig workspace quick-switch --approve --requester-icon-path /Applications/Codex.app
              deskjig workspace quick-switch --url http://localhost:3000
              deskjig workspace quick-switch --url http://localhost:3000 --force-chrome
              deskjig workspace quick-switch list                     # List directories
              deskjig workspace quick-switch list --format json       # JSON output
            """,
            subcommands: [
                Switch.self,
                ListDirectories.self
            ],
            defaultSubcommand: Switch.self
        )

        struct Switch: AsyncParsableCommand {
            static let configuration = CommandConfiguration(
                commandName: "switch",
                abstract: "Switch to a workspace for a directory (default)"
            )

            @Argument(help: "Directory name or path (defaults to cwd if omitted)")
            var directory: String?

            @Option(name: .customLong("directory"), help: "Directory path (alternative to positional argument)")
            var directoryFlag: String?

            @Option(name: .customLong("workspace"), help: "Override workspace name (bypasses resolution chain)")
            var workspace: String?

            @Flag(name: .customLong("approve"), help: "Ask for approval in DeskJig before switching")
            var approve: Bool = false

            @Option(name: .customLong("title"), help: "Approval headline text (defaults to '<requester> wants your attention')")
            var title: String?

            @Option(name: .customLong("subtext"), help: "Approval subline shown under the headline (used with --approve)")
            var subtext: String?

            @Option(name: .customLong("message"), help: "Legacy alias for approval subline (used with --approve)")
            var message: String?

            @Option(name: .customLong("requester-bundle-id"), help: "Bundle identifier of the requesting app (used for approval card icon)")
            var requesterBundleID: String?

            @Option(name: .customLong("requester-app"), help: "Requester application name (used to resolve display name/icon)")
            var requesterAppName: String?

            @Option(name: .customLong("requester-icon-path"), help: "Path to requesting app bundle used for approval card icon")
            var requesterIconPath: String?

            @Option(name: .customLong("url"), help: "URL to focus/open in Chrome after switch")
            var urlToOpen: String?

            @Flag(name: .customLong("force-chrome"), help: "When used with --url, inject a temporary Chrome window if the workspace has no Chrome")
            var forceChrome: Bool = false

            @OptionGroup var globalOptions: GlobalOptions

            mutating func run() async throws {
                if forceChrome {
                    guard let urlToOpen, !urlToOpen.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                        throw ValidationError("--force-chrome requires --url")
                    }
                }

                let resolvedDirectory: String
                if let directory {
                    // Positional argument: treat as path if it contains / or ~, otherwise resolve as name in cwd parent
                    if directory.contains("/") || directory.hasPrefix("~") {
                        resolvedDirectory = (directory as NSString).expandingTildeInPath
                    } else {
                        // Treat as a subdirectory name — check if it exists relative to cwd
                        let cwdChild = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                            .appendingPathComponent(directory).path
                        if FileManager.default.fileExists(atPath: cwdChild) {
                            resolvedDirectory = cwdChild
                        } else {
                            // Use as-is, let DeskJig resolve it
                            resolvedDirectory = directory
                        }
                    }
                } else if let directoryFlag {
                    resolvedDirectory = (directoryFlag as NSString).expandingTildeInPath
                } else {
                    resolvedDirectory = FileManager.default.currentDirectoryPath
                }

                let normalizedDirectory = Self.normalizeDirectoryPath(resolvedDirectory)
                let explicitWorkspaceID = workspace.flatMap {
                    Self.resolveWorkspaceID(named: $0)
                }
                let autoResolvedWorkspaceID = workspace == nil
                    ? Self.resolveDirectoryOverrideWorkspaceID(for: normalizedDirectory)
                    : nil

                var components = URLComponents()
                components.scheme = BundleIdentity.urlScheme
                components.host = "quick-switch"
                components.queryItems = [
                    URLQueryItem(name: "cwd", value: normalizedDirectory)
                ]
                if let workspace {
                    components.queryItems?.append(URLQueryItem(name: "workspace", value: workspace))
                    if let explicitWorkspaceID {
                        components.queryItems?.append(URLQueryItem(name: "workspace_id", value: explicitWorkspaceID))
                    }
                } else if let autoResolvedWorkspaceID {
                    components.queryItems?.append(URLQueryItem(name: "workspace_id", value: autoResolvedWorkspaceID))
                }
                if approve {
                    components.queryItems?.append(URLQueryItem(name: "approve", value: "1"))
                    if let title, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        components.queryItems?.append(URLQueryItem(name: "title", value: title))
                    }
                    if let subtext, !subtext.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        components.queryItems?.append(URLQueryItem(name: "subtext", value: subtext))
                    }
                    if let message, !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        components.queryItems?.append(URLQueryItem(name: "message", value: message))
                    }
                }
                if let requesterBundleID, !requesterBundleID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    components.queryItems?.append(URLQueryItem(name: "requester_bundle_id", value: requesterBundleID))
                }
                if let requesterAppName, !requesterAppName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    components.queryItems?.append(URLQueryItem(name: "requester_app_name", value: requesterAppName))
                }
                if let requesterIconPath, !requesterIconPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    components.queryItems?.append(URLQueryItem(name: "requester_icon_path", value: requesterIconPath))
                }
                if let urlToOpen, !urlToOpen.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    components.queryItems?.append(URLQueryItem(name: "url", value: urlToOpen))
                }
                if forceChrome {
                    components.queryItems?.append(URLQueryItem(name: "force_chrome", value: "1"))
                }

                guard let url = components.url else {
                    print("Failed to construct quick-switch URL")
                    fflush(stdout)
                    Foundation.exit(1)
                }

                try await DeskJigAppResolver.openDeskJigURL(url)
            }

            private static func resolveDirectoryOverrideWorkspaceID(for normalizedDirectory: String) -> String? {
                guard let globalValue = BundleIdentity.sharedDefaults.object(forKey: "quickSwitch.directoryOverrides"),
                      let globalOverrides = decodeDirectoryOverrides(from: globalValue) else {
                    return nil
                }
                return globalOverrides[normalizedDirectory]
            }

            private static func normalizeDirectoryPath(_ path: String) -> String {
                let expanded = (path as NSString).expandingTildeInPath
                if expanded.hasPrefix("/") {
                    return URL(fileURLWithPath: expanded).standardizedFileURL.path
                }

                let absoluteURL = URL(
                    fileURLWithPath: expanded,
                    relativeTo: URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                )
                return absoluteURL.standardizedFileURL.path
            }

            private static func resolveWorkspaceID(named workspaceName: String) -> String? {
                createSharedWorkspaceManager().resolveWorkspaceID(named: workspaceName)?.uuidString
            }

            private static func decodeDirectoryOverrides(from rawValue: Any) -> [String: String]? {
                if let data = rawValue as? Data {
                    return try? JSONDecoder().decode([String: String].self, from: data)
                }

                if let jsonString = rawValue as? String,
                   let data = jsonString.data(using: .utf8) {
                    return try? JSONDecoder().decode([String: String].self, from: data)
                }

                return nil
            }
        }

        struct ListDirectories: AsyncParsableCommand {
            static let configuration = CommandConfiguration(
                commandName: "list",
                abstract: "List configured quick-switch directories"
            )

            @OptionGroup var globalOptions: GlobalOptions

            mutating func run() async throws {
                try await DeskJigRunner.run(
                    actions: [.quickSwitchListDirectories],
                    options: globalOptions,
                    requireAccessibility: false
                )
            }
        }

    }
}

private enum WorkspaceOverrideParsing {
    static func parseWindowOverrides(
        windowPaths: [String],
        chromeProfiles: [String],
        chromeTabs: [String],
        chromeTabsFiles: [String]
    ) throws -> [WindowOverride] {
        var overridesByIndex: [Int: WindowOverride] = [:]

        func updateOverride(
            index: Int,
            openPath: String? = nil,
            chrome: ChromeOverride? = nil
        ) {
            let existing = overridesByIndex[index]
            let mergedChrome = mergeChrome(existing?.chrome, chrome)
            let merged = WindowOverride(
                index: index,
                openPath: openPath ?? existing?.openPath,
                chrome: mergedChrome ?? existing?.chrome
            )
            overridesByIndex[index] = merged
        }

        for entry in windowPaths {
            let (index, path) = try parseIndexAndValue(entry, flag: "--window-path")
            updateOverride(index: index, openPath: path)
        }

        for entry in chromeProfiles {
            let (index, override) = try parseChromeProfile(entry)
            updateOverride(index: index, chrome: override)
        }

        for entry in chromeTabs {
            let (index, tabs) = try parseTabs(entry, flag: "--chrome-tabs")
            updateOverride(index: index, chrome: ChromeOverride(profileDirectory: nil, profileDisplayName: nil, profileHostedDomain: nil, tabs: tabs, focusedTabIndex: nil))
        }

        for entry in chromeTabsFiles {
            let (index, path) = try parseIndexAndValue(entry, flag: "--chrome-tabs-file")
            let tabs = try readTabsFile(path: path)
            updateOverride(index: index, chrome: ChromeOverride(profileDirectory: nil, profileDisplayName: nil, profileHostedDomain: nil, tabs: tabs, focusedTabIndex: nil))
        }

        return overridesByIndex.values.sorted { $0.index < $1.index }
    }

    private static func parseIndexAndValue(_ raw: String, flag: String) throws -> (Int, String) {
        let parts = raw.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2, let index = Int(parts[0]) else {
            throw ValidationError("Invalid \(flag) value '\(raw)'. Expected format: index:value")
        }
        return (index, parts[1])
    }

    private static func parseChromeProfile(_ raw: String) throws -> (Int, ChromeOverride) {
        let parts = raw.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        guard parts.count >= 3, let index = Int(parts[0]) else {
            throw ValidationError("Invalid --chrome-profile value '\(raw)'. Expected format: index:profileDir:displayName[:hostedDomain]")
        }
        let profileDir = parts[1]
        let displayName = parts[2]
        let hostedDomain = parts.count > 3 ? parts[3...].joined(separator: ":") : nil
        return (
            index,
            ChromeOverride(
                profileDirectory: profileDir,
                profileDisplayName: displayName,
                profileHostedDomain: hostedDomain,
                tabs: nil,
                focusedTabIndex: nil
            )
        )
    }

    private static func parseTabs(_ raw: String, flag: String) throws -> (Int, [String]) {
        let (index, value) = try parseIndexAndValue(raw, flag: flag)
        let tabs = value
            .split(separator: ",", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return (index, tabs)
    }

    private static func readTabsFile(path: String) throws -> [String] {
        let content = try String(contentsOfFile: path, encoding: .utf8)
        return content
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private static func mergeChrome(_ base: ChromeOverride?, _ incoming: ChromeOverride?) -> ChromeOverride? {
        guard let incoming else { return base }
        guard let base else { return incoming }
        return ChromeOverride(
            profileDirectory: incoming.profileDirectory ?? base.profileDirectory,
            profileDisplayName: incoming.profileDisplayName ?? base.profileDisplayName,
            profileHostedDomain: incoming.profileHostedDomain ?? base.profileHostedDomain,
            tabs: incoming.tabs ?? base.tabs,
            focusedTabIndex: incoming.focusedTabIndex ?? base.focusedTabIndex
        )
    }
}
