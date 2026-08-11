//  PermissionsCommand.swift
//  DeskJigCLI

import ArgumentParser
import Foundation
import DeskJigShared

struct PermissionsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "permissions",
        abstract: "Check or prompt for Accessibility permissions"
    )

    @Flag(name: .customLong("prompt"), help: "Prompt for Accessibility permissions if not granted.")
    var prompt: Bool = false

    @OptionGroup var globalOptions: GlobalOptions

    mutating func run() async throws {
        let start = Date()
        let manager = AccessibilityManager()
        let granted = manager.hasAccessibilityPermissions
        var prompted = false

        if prompt && !granted {
            manager.requestAccessibilityPermissions()
            prompted = true
        }

        let isGrantedNow = granted || manager.hasAccessibilityPermissions
        let data: AnyCodableValue = .dictionary([
            "granted": .bool(isGrantedNow),
            "prompted": .bool(prompted)
        ])

        let result: CommandResult
        if isGrantedNow {
            result = .success(action: "permissions", message: "Accessibility permissions granted", data: data)
        } else {
            result = .failure(action: "permissions", exitCode: .permissionDenied, error: "Accessibility permissions required")
        }

        let durationMs = Date().timeIntervalSince(start) * 1000
        let agentResult = AgentCommandResult(from: result, durationMs: durationMs)
        if globalOptions.format == .json {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            if let encoded = try? encoder.encode(agentResult),
               let json = String(data: encoded, encoding: .utf8) {
                print(json)
            } else {
                print("{\"success\":false,\"exitCode\":\(ExitCode.permissionDenied.rawValue)}")
            }
        } else {
            print(AgentOutputFormatter.formatText(agentResult))
            if !isGrantedNow {
                print("hint=\"Grant accessibility permissions in System Settings.\"")
            }
        }
        fflush(stdout)

        if !isGrantedNow {
            Foundation.exit(ExitCode.permissionDenied.rawValue)
        }
    }
}

