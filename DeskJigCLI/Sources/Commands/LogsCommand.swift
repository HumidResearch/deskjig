//  LogsCommand.swift
//  DeskJigCLI

import ArgumentParser
import DeskJigShared
import Foundation

struct LogsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "logs",
        abstract: "DeskJig log inspection",
        subcommands: [
            RunIDs.self,
            Show.self
        ]
    )

    @OptionGroup var globalOptions: GlobalOptions

    mutating func run() async throws {
        throw CleanExit.helpRequest(self)
    }

    struct RunIDs: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "run-ids",
            abstract: "List workspace restoration run IDs from logs"
        )

        @Option(name: .customLong("lines"), help: "Number of log lines to scan")
        var lines: Int?

        @Option(name: .customLong("since"), help: "Only include entries since this date string")
        var since: String?

        @OptionGroup var globalOptions: GlobalOptions

        mutating func run() async throws {
            if let lines, lines < 0 {
                throw ValidationError("--lines must be a non-negative integer")
            }

            try await DeskJigRunner.run(
                actions: [.listRunIds(lines: lines, since: since)],
                options: globalOptions,
                requireAccessibility: false
            )
        }
    }

    struct Show: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "show",
            abstract: "Show log entries for a specific restoration run ID"
        )

        @Argument(help: "Run ID to show")
        var runId: String

        @Option(name: .customLong("lines"), help: "Number of log lines to show")
        var lines: Int?

        @OptionGroup var globalOptions: GlobalOptions

        mutating func run() async throws {
            if let lines, lines < 0 {
                throw ValidationError("--lines must be a non-negative integer")
            }

            try await DeskJigRunner.run(
                actions: [.showRunId(runId: runId, lines: lines)],
                options: globalOptions,
                requireAccessibility: false
            )
        }
    }
}
