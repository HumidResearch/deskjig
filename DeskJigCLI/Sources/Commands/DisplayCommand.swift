//  DisplayCommand.swift
//  DeskJigCLI

import ArgumentParser
import DeskJigShared

struct DisplayCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "display",
        abstract: "Display operations",
        subcommands: [List.self]
    )

    @OptionGroup var globalOptions: GlobalOptions

    mutating func run() async throws {
        throw CleanExit.helpRequest(self)
    }

    struct List: AsyncParsableCommand {
        @OptionGroup var globalOptions: GlobalOptions

        mutating func run() async throws {
            try await DeskJigRunner.run(actions: [.listDisplays], options: globalOptions)
        }
    }
}
