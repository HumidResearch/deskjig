//  ChromeCommand.swift
//  DeskJigCLI

import ArgumentParser
import DeskJigShared

struct ChromeCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "chrome",
        abstract: "Chrome operations",
        subcommands: [
            List.self,
            LaunchProfile.self,
            OpenTabs.self,
            ExportTabs.self
        ]
    )

    @OptionGroup var globalOptions: GlobalOptions

    mutating func run() async throws {
        throw CleanExit.helpRequest(self)
    }

    struct List: AsyncParsableCommand {
        @OptionGroup var globalOptions: GlobalOptions

        mutating func run() async throws {
            try await DeskJigRunner.run(actions: [.listChromeWindows], options: globalOptions)
        }
    }

    struct LaunchProfile: AsyncParsableCommand {
        @Argument(help: "Chrome profile directory name")
        var profile: String

        @Option(name: .customLong("urls"), parsing: .upToNextOption, help: "URLs to open")
        var urls: [String] = []

        @OptionGroup var globalOptions: GlobalOptions

        mutating func run() async throws {
            let action = CLIAction.launchChromeProfile(profile: profile, urls: urls)
            try await DeskJigRunner.run(actions: [action], options: globalOptions)
        }
    }

    struct OpenTabs: AsyncParsableCommand {
        @OptionGroup var targetOptions: WindowTargetOptions

        @Option(name: .customLong("urls"), parsing: .upToNextOption, help: "URLs to open (required)")
        var urls: [String] = []

        @OptionGroup var globalOptions: GlobalOptions

        mutating func run() async throws {
            if urls.isEmpty {
                throw ValidationError("--urls is required")
            }
            let target = try targetOptions.resolve()
            let action = CLIAction.openChromeTabs(target: target, urls: urls)
            try await DeskJigRunner.run(actions: [action], options: globalOptions)
        }
    }

    struct ExportTabs: AsyncParsableCommand {
        @OptionGroup var targetOptions: WindowTargetOptions
        @OptionGroup var globalOptions: GlobalOptions

        mutating func run() async throws {
            let providedTarget = hasTargetOption() ? try targetOptions.resolve(defaultToTopmost: false) : nil
            let action = CLIAction.exportChromeTabs(target: providedTarget)
            try await DeskJigRunner.run(actions: [action], options: globalOptions)
        }

        private func hasTargetOption() -> Bool {
            return targetOptions.app != nil
                || targetOptions.bundleID != nil
                || targetOptions.title != nil
                || targetOptions.titleContains != nil
                || targetOptions.topmost
        }
    }
}
