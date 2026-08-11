//  AppCommand.swift
//  DeskJigCLI

import ArgumentParser
import CoreGraphics
import DeskJigShared
import Foundation

struct AppCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "app",
        abstract: "App operations (and DeskJig in-app triggers: restore, status, open-url)",
        subcommands: [
            List.self,
            Query.self,
            Launch.self,
            Activate.self,
            Hide.self,
            Unhide.self,
            Terminate.self,
            HideAll.self,
            UnhideAll.self,
            // DeskJig-app-targeting subcommands (see AppCommandGroup.swift, #465)
            Restore.self,
            Status.self,
            OpenURL.self
        ]
    )

    @OptionGroup var globalOptions: GlobalOptions

    mutating func run() async throws {
        throw CleanExit.helpRequest(self)
    }

    struct List: AsyncParsableCommand {
        @OptionGroup var globalOptions: GlobalOptions

        mutating func run() async throws {
            try await DeskJigRunner.run(actions: [.listRunningApps], options: globalOptions)
        }
    }

    struct Query: AsyncParsableCommand {
        @Option(name: .customLong("name-contains"), help: "Filter by app name substring")
        var nameContains: String?

        @Option(name: .customLong("bundle-id-contains"), help: "Filter by bundle identifier substring")
        var bundleIDContains: String?

        @OptionGroup var globalOptions: GlobalOptions

        mutating func run() async throws {
            let filter = AppFilter(nameContains: nameContains, bundleIDContains: bundleIDContains, runningOnly: true)
            try await DeskJigRunner.run(actions: [.queryApps(filter: filter)], options: globalOptions)
        }
    }

    struct Launch: AsyncParsableCommand {
        @Argument(help: "Bundle identifier")
        var bundleID: String

        @Option(name: .customLong("urls"), parsing: .upToNextOption, help: "URLs to open")
        var urls: [String] = []

        @OptionGroup var globalOptions: GlobalOptions

        mutating func run() async throws {
            let action = CLIAction.launchApp(bundleID: bundleID, urls: urls.isEmpty ? nil : urls)
            try await DeskJigRunner.run(actions: [action], options: globalOptions)
        }
    }

    struct Activate: AsyncParsableCommand {
        @OptionGroup var targetOptions: WindowTargetOptions
        @OptionGroup var globalOptions: GlobalOptions

        mutating func run() async throws {
            let target = try targetOptions.resolve()
            try await DeskJigRunner.run(actions: [.activateApp(target: target)], options: globalOptions)
        }
    }

    struct Hide: AsyncParsableCommand {
        @OptionGroup var targetOptions: WindowTargetOptions
        @OptionGroup var globalOptions: GlobalOptions

        mutating func run() async throws {
            let target = try targetOptions.resolve()
            try await DeskJigRunner.run(actions: [.hideApp(target: target)], options: globalOptions)
        }
    }

    struct Unhide: AsyncParsableCommand {
        @OptionGroup var targetOptions: WindowTargetOptions
        @OptionGroup var globalOptions: GlobalOptions

        mutating func run() async throws {
            let target = try targetOptions.resolve()
            try await DeskJigRunner.run(actions: [.unhideApp(target: target)], options: globalOptions)
        }
    }

    struct Terminate: AsyncParsableCommand {
        @OptionGroup var targetOptions: WindowTargetOptions
        @OptionGroup var globalOptions: GlobalOptions

        mutating func run() async throws {
            let target = try targetOptions.resolve()
            try await DeskJigRunner.run(actions: [.terminateApp(target: target)], options: globalOptions)
        }
    }

    struct HideAll: AsyncParsableCommand {
        @Option(name: .customLong("min-window-size"), help: "Minimum window size in pixels (default: 100)")
        var minWindowSize: Int = 100

        @OptionGroup var globalOptions: GlobalOptions

        mutating func run() async throws {
            guard minWindowSize >= 0 else {
                throw ValidationError("--min-window-size must be non-negative")
            }
            let size = CGSize(width: minWindowSize, height: minWindowSize)
            let action = CLIAction.hideAllApps(minWindowSize: size)
            try await DeskJigRunner.run(actions: [action], options: globalOptions)
        }
    }

    struct UnhideAll: AsyncParsableCommand {
        @OptionGroup var globalOptions: GlobalOptions

        mutating func run() async throws {
            try await DeskJigRunner.run(actions: [.unhideAllApps], options: globalOptions)
        }
    }
}
