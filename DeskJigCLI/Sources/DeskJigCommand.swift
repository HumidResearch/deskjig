//  DeskJigCommand.swift
//  DeskJigCLI

import ArgumentParser

@main
@available(macOS 10.15, macCatalyst 13, iOS 13, tvOS 13, watchOS 6, *)
struct DeskJigCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "deskjig",
        abstract: "DeskJig command-line interface",
        discussion: """
        Open a directory in a supported app (ghostty, cursor, codex, vscode, \
        xcode, terminal, iterm, kitty, alacritty):
          deskjig open codex --directory "/path/to/project"
        """,
        version: DeskJigVersion.current,
        subcommands: [
            WorkspaceCommand.self,
            URLHandoffCommand.self,
            WindowCommand.self,
            AppCommand.self,
            ChromeCommand.self,
            DisplayCommand.self,
            DebugCommand.self,
            LogsCommand.self,
            OpenCommand.self,
            PermissionsCommand.self,
            InstallCommand.self,
            NotifyCommand.self
        ]
    )

    @OptionGroup var globalOptions: GlobalOptions

    mutating func run() async throws {
        throw CleanExit.helpRequest(self)
    }
}
