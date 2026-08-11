//  WindowCommand.swift
//  DeskJigCLI

import ArgumentParser
import DeskJigShared
import Foundation

struct WindowCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "window",
        abstract: "Window operations",
        subcommands: [
            Query.self,
            Info.self,
            Activate.self,
            Move.self,
            Resize.self,
            Minimize.self,
            Unminimize.self,
            Close.self,
            Center.self,
            Maximize.self
        ]
    )

    @OptionGroup var globalOptions: GlobalOptions

    mutating func run() async throws {
        throw CleanExit.helpRequest(self)
    }

    struct Query: AsyncParsableCommand {
        @Option(name: .customLong("app"), help: "Filter by app name")
        var app: String?

        @Option(name: .customLong("bundle-id"), help: "Filter by bundle identifier")
        var bundleID: String?

        @Option(name: .customLong("title"), help: "Filter by exact title")
        var title: String?

        @Option(name: .customLong("title-contains"), help: "Filter by title substring")
        var titleContains: String?

        @OptionGroup var globalOptions: GlobalOptions

        mutating func run() async throws {
            let filter = WindowFilter(
                appName: app,
                bundleID: bundleID,
                titleContains: titleContains,
                titleEquals: title,
                includeHidden: false,
                includeMinimized: true
            )
            try await DeskJigRunner.run(
                actions: [.queryWindows(filter: filter)],
                options: globalOptions,
                requireAccessibility: true,
                requireWindowRefresh: false
            )
        }
    }

    struct Info: AsyncParsableCommand {
        @OptionGroup var targetOptions: WindowTargetOptions
        @OptionGroup var globalOptions: GlobalOptions

        mutating func run() async throws {
            let target = try targetOptions.resolve()
            try await DeskJigRunner.run(
                actions: [.getWindowInfo(target: target)],
                options: globalOptions,
                requireAccessibility: true,
                requireWindowRefresh: false
            )
        }
    }

    struct Activate: AsyncParsableCommand {
        @OptionGroup var targetOptions: WindowTargetOptions
        @OptionGroup var globalOptions: GlobalOptions

        mutating func run() async throws {
            let target = try targetOptions.resolve()
            try await DeskJigRunner.run(
                actions: [.activateWindow(target: target)],
                options: globalOptions,
                requireAccessibility: true,
                requireWindowRefresh: false
            )
        }
    }

    struct Move: AsyncParsableCommand {
        @OptionGroup var targetOptions: WindowTargetOptions

        @Option(name: .customLong("position"), help: "Position preset (left-half, right-half, center, etc.)")
        var position: WindowPosition

        @Option(name: .customLong("screen"), help: "Target screen index (0-based)")
        var screen: Int?

        @OptionGroup var globalOptions: GlobalOptions

        mutating func run() async throws {
            let target = try targetOptions.resolve()
            let action = CLIAction.moveWindow(target: target, position: position, customPosition: nil, screenIndex: screen)
            try await DeskJigRunner.run(
                actions: [action],
                options: globalOptions,
                requireAccessibility: true,
                requireWindowRefresh: false
            )
        }
    }

    struct Resize: AsyncParsableCommand {
        @OptionGroup var targetOptions: WindowTargetOptions

        @Option(name: .customLong("size"), help: "Size in WxH (e.g., 1200x800)")
        var size: CustomSize

        @OptionGroup var globalOptions: GlobalOptions

        mutating func run() async throws {
            let target = try targetOptions.resolve()
            let action = CLIAction.resizeWindow(target: target, size: size)
            try await DeskJigRunner.run(
                actions: [action],
                options: globalOptions,
                requireAccessibility: true,
                requireWindowRefresh: false
            )
        }
    }

    struct Minimize: AsyncParsableCommand {
        @OptionGroup var targetOptions: WindowTargetOptions
        @OptionGroup var globalOptions: GlobalOptions

        mutating func run() async throws {
            let target = try targetOptions.resolve()
            try await DeskJigRunner.run(
                actions: [.minimizeWindow(target: target)],
                options: globalOptions,
                requireAccessibility: true,
                requireWindowRefresh: false
            )
        }
    }

    struct Unminimize: AsyncParsableCommand {
        @OptionGroup var targetOptions: WindowTargetOptions
        @OptionGroup var globalOptions: GlobalOptions

        mutating func run() async throws {
            let target = try targetOptions.resolve()
            try await DeskJigRunner.run(
                actions: [.unminimizeWindow(target: target)],
                options: globalOptions,
                requireAccessibility: true,
                requireWindowRefresh: false
            )
        }
    }

    struct Close: AsyncParsableCommand {
        @OptionGroup var targetOptions: WindowTargetOptions
        @OptionGroup var globalOptions: GlobalOptions

        mutating func run() async throws {
            let target = try targetOptions.resolve()
            try await DeskJigRunner.run(
                actions: [.closeWindow(target: target)],
                options: globalOptions,
                requireAccessibility: true,
                requireWindowRefresh: false
            )
        }
    }

    struct Center: AsyncParsableCommand {
        @OptionGroup var targetOptions: WindowTargetOptions
        @OptionGroup var globalOptions: GlobalOptions

        mutating func run() async throws {
            let target = try targetOptions.resolve()
            try await DeskJigRunner.run(
                actions: [.centerWindow(target: target)],
                options: globalOptions,
                requireAccessibility: true,
                requireWindowRefresh: false
            )
        }
    }

    struct Maximize: AsyncParsableCommand {
        @OptionGroup var targetOptions: WindowTargetOptions
        @OptionGroup var globalOptions: GlobalOptions

        mutating func run() async throws {
            let target = try targetOptions.resolve()
            try await DeskJigRunner.run(
                actions: [.maximizeWindow(target: target)],
                options: globalOptions,
                requireAccessibility: true,
                requireWindowRefresh: false
            )
        }
    }
}

