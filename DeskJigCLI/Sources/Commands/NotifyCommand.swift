//  NotifyCommand.swift
//  DeskJigCLI

import ArgumentParser
import DeskJigShared
import Foundation

struct NotifyCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "notify",
        abstract: "Show a DeskJig toast notification with optional workspace switch",
        discussion: """
        Sends a notification to DeskJig.app via the bento://notify URL scheme.
        When the user taps "Switch", DeskJig resolves the workspace for the
        directory using Quick Switch settings and restores it.

        Examples:
          deskjig notify
          deskjig notify --message "Review needed"
          deskjig notify --cwd /path/to/repo
          deskjig notify --message "Tests passed" --action-title "Open"
        """
    )

    @Option(name: .customLong("message"), help: "Toast message (default: \"Claude Code needs your attention\")")
    var message: String = "Claude Code needs your attention"

    @Option(name: .customLong("subtext"), help: "Additional context shown below the message")
    var subtext: String?

    @Option(name: .customLong("cwd"), help: "Directory path (defaults to current working directory)")
    var cwd: String?

    @Option(name: .customLong("action-title"), help: "Action button title (default: \"Switch\")")
    var actionTitle: String = "Switch"

    @Option(name: .customLong("url"), help: "URL to open in Chrome when switching (e.g. http://localhost:3000)")
    var url: String?

    @Option(name: .customLong("open"), help: "File path to open when switching")
    var openFilePath: String?

    @OptionGroup var globalOptions: GlobalOptions

    mutating func run() async throws {
        let directory = cwd ?? FileManager.default.currentDirectoryPath

        var components = URLComponents()
        components.scheme = BundleIdentity.urlScheme
        components.host = "notify"
        components.queryItems = [
            URLQueryItem(name: "cwd", value: directory),
            URLQueryItem(name: "message", value: message),
            URLQueryItem(name: "action_title", value: actionTitle)
        ]
        if let subtext {
            components.queryItems?.append(URLQueryItem(name: "subtext", value: subtext))
        }
        if let url {
            components.queryItems?.append(URLQueryItem(name: "url", value: url))
        }
        if let openFilePath {
            components.queryItems?.append(URLQueryItem(name: "open", value: openFilePath))
        }

        guard let url = components.url else {
            print("Failed to construct notify URL")
            fflush(stdout)
            Foundation.exit(1)
        }

        try await DeskJigAppResolver.openDeskJigURL(url)
    }
}
