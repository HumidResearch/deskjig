//  DebugCommand.swift
//  DeskJigCLI

import ArgumentParser
import DeskJigShared
import Foundation

enum DebugLaunchApp: String, CaseIterable, ExpressibleByArgument {
    case cursor
    case ghostty
    case terminal
    case kitty
    case alacritty
}

extension TestTerminalApp: ExpressibleByArgument {
    init?(argument: String) {
        self.init(rawValue: argument.lowercased())
    }
}

struct DebugCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "debug",
        abstract: "Diagnostic and restore debugging operations",
        subcommands: [
            DumpWindows.self,
            RestoreLoop.self,
            CreateTestWorkspaces.self,
            CreateRichWorkspace.self,
            LaunchPositioned.self
        ]
    )

    @OptionGroup var globalOptions: GlobalOptions

    mutating func run() async throws {
        throw CleanExit.helpRequest(self)
    }

    struct DumpWindows: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "dump-windows",
            abstract: "List all currently visible windows"
        )

        @OptionGroup var globalOptions: GlobalOptions

        mutating func run() async throws {
            try await DeskJigRunner.run(
                actions: [.dumpWindows],
                options: globalOptions,
                requireAccessibility: true,
                requireWindowRefresh: false
            )
        }
    }

    struct RestoreLoop: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "restore-loop",
            abstract: "Run a restore/debug loop with AX, z-order, log, and screenshot captures"
        )

        @Option(name: .customLong("workspace"), help: "Workspace name to restore (repeatable)")
        var workspaces: [String] = []

        @Option(name: .customLong("workspaces"), help: "Comma-separated workspace names to restore in order")
        var workspaceLists: [String] = []

        @Argument(help: "Additional workspace names to restore in order")
        var positionalWorkspaces: [String] = []

        @Option(name: .customLong("iterations"), help: "Repeat the workspace list this many times")
        var iterations: Int = 1

        @Option(name: .customLong("sleep"), help: "Seconds to wait after each restore before capturing artifacts")
        var sleepSeconds: Double = 8.0

        @Option(name: .customLong("output-dir"), help: "Artifact output directory")
        var outputDir: String?

        @Option(name: .customLong("screenshot-display"), help: "Capture only this display index (0-based)")
        var screenshotDisplayIndex: Int?

        @Flag(name: .customLong("no-screenshots"), help: "Skip screenshot capture")
        var noScreenshots: Bool = false

        @Flag(name: .customLong("capture-all-displays"), help: "Capture all detected displays")
        var captureAllDisplays: Bool = false

        @Flag(name: .customLong("all-displays"), help: "Alias for --capture-all-displays")
        var allDisplays: Bool = false

        @Option(name: .customLong("kill-every"), help: "Kill Ghostty and Cursor every N iterations")
        var killEvery: Int?

        @Option(name: .customLong("log-lines"), help: "Number of DeskJig log lines to capture")
        var logLines: Int = 200

        @Option(name: .customLong("log-query"), help: "Additional text filter for captured DeskJig logs")
        var logQuery: String?

        @Flag(name: .customLong("hide-all-apps"), help: "Hide all apps before restore")
        var hideAllAppsFlag: Bool = false

        @Flag(name: .customLong("no-hide-all-apps"), help: "Do not hide all apps before restore")
        var noHideAllAppsFlag: Bool = false

        @OptionGroup var globalOptions: GlobalOptions

        mutating func run() async throws {
            guard iterations > 0 else {
                throw ValidationError("--iterations must be a positive integer")
            }
            guard sleepSeconds >= 0 else {
                throw ValidationError("--sleep must be a non-negative number")
            }
            if let screenshotDisplayIndex, screenshotDisplayIndex < 0 {
                throw ValidationError("--screenshot-display must be a non-negative integer")
            }
            if let killEvery, killEvery <= 0 {
                throw ValidationError("--kill-every must be a positive integer")
            }
            guard logLines >= 0 else {
                throw ValidationError("--log-lines must be a non-negative integer")
            }
            guard !(hideAllAppsFlag && noHideAllAppsFlag) else {
                throw ValidationError("Specify only one of --hide-all-apps or --no-hide-all-apps")
            }

            let csvWorkspaces = workspaceLists.flatMap { value in
                value.split(separator: ",")
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
            }
            let resolvedWorkspaces = workspaces + csvWorkspaces + positionalWorkspaces
            guard !resolvedWorkspaces.isEmpty else {
                throw ValidationError("--workspace is required")
            }

            let explicitAllDisplays = captureAllDisplays || allDisplays
            let options = CLIAction.DebugRestoreLoopOptions(
                workspaces: resolvedWorkspaces,
                iterations: iterations,
                sleepSeconds: sleepSeconds,
                outputDir: outputDir,
                screenshotDisplayIndex: explicitAllDisplays ? nil : screenshotDisplayIndex,
                captureScreenshots: !noScreenshots,
                captureAllDisplays: explicitAllDisplays || screenshotDisplayIndex == nil,
                killEvery: killEvery,
                logLines: logLines,
                logQuery: logQuery,
                hideAllApps: hideAllAppsFlag ? true : (noHideAllAppsFlag ? false : nil)
            )

            try await DeskJigRunner.run(
                actions: [.debugRestoreLoop(options: options)],
                options: globalOptions,
                requireAccessibility: true
            )
        }
    }

    struct CreateTestWorkspaces: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "create-test-workspaces",
            abstract: "Create two temporary test workspaces"
        )

        @Option(name: .customLong("terminal-app"), help: "Terminal app (ghostty, terminal, iterm, kitty, alacritty)")
        var terminalApp: TestTerminalApp = .ghostty

        @Option(name: .customLong("path-a"), help: "Directory for workspace A")
        var pathA: String?

        @Option(name: .customLong("path-b"), help: "Directory for workspace B")
        var pathB: String?

        @OptionGroup var globalOptions: GlobalOptions

        mutating func run() async throws {
            let options = CreateTestWorkspacesOptions(
                terminalApp: terminalApp,
                pathA: pathA,
                pathB: pathB
            )
            try await DeskJigRunner.run(
                actions: [.createTestWorkspaces(options: options)],
                options: globalOptions,
                requireAccessibility: true
            )
        }
    }

    struct CreateRichWorkspace: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "create-rich-workspace",
            abstract: "Create a workspace with Chrome, terminal, VS Code, and kitty windows"
        )

        @Option(name: .customLong("name"), help: "Workspace name")
        var name: String

        @Option(name: .customLong("icon"), help: "Workspace icon")
        var icon: String?

        @Option(name: .customLong("screen"), help: "Default screen index")
        var screenIndex: Int = 0

        @Option(name: .customLong("chrome-screen"), help: "Chrome screen index")
        var chromeScreenIndex: Int?

        @Option(name: .customLong("terminal-screen"), help: "Terminal screen index")
        var terminalScreenIndex: Int?

        @Option(name: .customLong("vscode-screen"), help: "VS Code screen index")
        var vscodeScreenIndex: Int?

        @Option(name: .customLong("kitty-screen"), help: "kitty screen index")
        var kittyScreenIndex: Int?

        @Flag(name: .customLong("replace-existing"), help: "Replace workspace on name or ID match")
        var replaceExisting: Bool = false

        @Option(name: .customLong("terminal-app"), help: "Terminal app (ghostty, terminal, iterm, kitty, alacritty)")
        var terminalApp: TestTerminalApp = .ghostty

        @Option(name: .customLong("terminal-path"), help: "Terminal directory path")
        var terminalPath: String

        @Option(name: .customLong("vscode-path"), help: "VS Code directory path")
        var vscodePath: String

        @Option(name: .customLong("kitty-path"), help: "kitty directory path")
        var kittyPath: String

        @Option(name: .customLong("chrome-profile-dir"), help: "Chrome profile directory")
        var chromeProfileDirectory: String = "Default"

        @Option(name: .customLong("chrome-profile-name"), help: "Chrome profile display name")
        var chromeProfileName: String = "Default"

        @Option(name: .customLong("chrome-hosted-domain"), help: "Chrome profile hosted domain")
        var chromeHostedDomain: String?

        @Option(name: .customLong("chrome-url"), help: "Chrome URL to restore (repeatable)")
        var chromeURL: [String] = []

        @Option(name: .customLong("chrome-urls"), help: "Comma-separated Chrome URLs")
        var chromeURLs: [String] = []

        @Option(name: .customLong("chrome-position"), help: "Chrome window position preset")
        var chromePosition: WindowPosition = .topLeftQuarter

        @Option(name: .customLong("terminal-position"), help: "Terminal window position preset")
        var terminalPosition: WindowPosition = .topRightQuarter

        @Option(name: .customLong("vscode-position"), help: "VS Code window position preset")
        var vscodePosition: WindowPosition = .bottomLeftQuarter

        @Option(name: .customLong("kitty-position"), help: "kitty window position preset")
        var kittyPosition: WindowPosition = .bottomRightQuarter

        @OptionGroup var globalOptions: GlobalOptions

        mutating func run() async throws {
            let screenValues = [
                ("--screen", screenIndex),
                ("--chrome-screen", chromeScreenIndex),
                ("--terminal-screen", terminalScreenIndex),
                ("--vscode-screen", vscodeScreenIndex),
                ("--kitty-screen", kittyScreenIndex)
            ]
            for (flag, value) in screenValues {
                if let value, value < 0 {
                    throw ValidationError("\(flag) must be a non-negative integer")
                }
            }

            let options = CreateRichWorkspaceOptions(
                name: name,
                icon: icon,
                screenIndex: screenIndex,
                chromeScreenIndex: chromeScreenIndex ?? screenIndex,
                terminalScreenIndex: terminalScreenIndex ?? screenIndex,
                vscodeScreenIndex: vscodeScreenIndex ?? screenIndex,
                kittyScreenIndex: kittyScreenIndex ?? screenIndex,
                replaceExisting: replaceExisting,
                terminalApp: terminalApp,
                terminalPath: terminalPath,
                vscodePath: vscodePath,
                kittyPath: kittyPath,
                chromeProfileDirectory: chromeProfileDirectory,
                chromeProfileName: chromeProfileName,
                chromeHostedDomain: chromeHostedDomain,
                chromeUrls: chromeURL + chromeURLs.flatMap { value in
                    value.split(separator: ",").map(String.init)
                },
                chromePosition: chromePosition,
                terminalPosition: terminalPosition,
                vscodePosition: vscodePosition,
                kittyPosition: kittyPosition
            )

            try await DeskJigRunner.run(
                actions: [.createRichWorkspace(options: options)],
                options: globalOptions,
                requireAccessibility: true
            )
        }
    }

    struct LaunchPositioned: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "launch-positioned",
            abstract: "Launch a supported app at a path and optionally position its window"
        )

        @Option(name: .customLong("app"), help: "App to launch (cursor, ghostty, terminal, kitty, alacritty)")
        var app: DebugLaunchApp

        @Option(name: .customLong("path"), help: "Directory path to open")
        var path: String

        @Option(name: .customLong("position"), help: "Window position preset")
        var position: String?

        @Option(name: .customLong("screen"), help: "Target screen index (0-based)")
        var screen: Int?

        @Option(name: .customLong("title"), help: "Terminal window title")
        var title: String?

        @Option(name: .customLong("name"), help: "Alias for --title")
        var name: String?

        @OptionGroup var globalOptions: GlobalOptions

        mutating func run() async throws {
            if let screen, screen < 0 {
                throw ValidationError("--screen must be a non-negative integer")
            }
            if title != nil, name != nil {
                throw ValidationError("Specify only one of --title or --name")
            }
            let resolvedTitle = title ?? name

            let action: CLIAction
            switch app {
            case .cursor:
                guard let position else {
                    throw ValidationError("--position is required for --app cursor")
                }
                guard resolvedTitle == nil else {
                    throw ValidationError("--title/--name is only valid for terminal, kitty, and alacritty")
                }
                action = .launchCursorPositioned(path: path, position: position, screen: screen)
            case .ghostty:
                guard let position else {
                    throw ValidationError("--position is required for --app ghostty")
                }
                guard resolvedTitle == nil else {
                    throw ValidationError("--title/--name is only valid for terminal, kitty, and alacritty")
                }
                action = .launchGhosttyPositioned(path: path, position: position, screen: screen)
            case .terminal:
                action = .launchTerminalPositioned(path: path, title: resolvedTitle, position: position, screen: screen)
            case .kitty:
                action = .launchKittyPositioned(path: path, title: resolvedTitle, position: position, screen: screen)
            case .alacritty:
                action = .launchAlacrittyPositioned(path: path, title: resolvedTitle, position: position, screen: screen)
            }

            try await DeskJigRunner.run(
                actions: [action],
                options: globalOptions,
                requireAccessibility: true
            )
        }
    }
}

