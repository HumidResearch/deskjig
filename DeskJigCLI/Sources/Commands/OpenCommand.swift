//  OpenCommand.swift
//  DeskJigCLI

import ArgumentParser
import DeskJigShared

struct OpenCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "open",
        abstract: "Open a directory in a supported app",
        discussion: """
        Example:
          deskjig open ghostty --directory "/path/to/worktree" --position top-left-quarter --screen 0
        """
    )

    @Argument(help: "App alias (ghostty, cursor, codex, vscode, xcode, terminal, kitty, alacritty)")
    var app: String

    @Option(name: .customLong("directory"), help: "Directory path")
    var directory: String

    @Option(name: .customLong("position"), help: "Position preset (left-half, right-half, center, etc.)")
    var position: WindowPosition?

    @Option(name: .customLong("screen"), help: "Target screen index (0-based)")
    var screen: Int = 0

    @Option(name: .customLong("title"), help: "Window title override (used for terminal apps)")
    var title: String?

    @Flag(name: .customLong("new"), help: "Force a new window even if one matches the directory")
    var forceNew: Bool = false

    @OptionGroup var globalOptions: GlobalOptions

    mutating func run() async throws {
        let action = CLIAction.openApp(
            target: .alias(app),
            directory: directory,
            position: position?.rawValue,
            screen: screen,
            forceNew: forceNew,
            titleOverride: title
        )
        try await DeskJigRunner.run(
            actions: [action],
            options: globalOptions,
            requireAccessibility: true,
            requireWindowRefresh: false
        )
    }
}
