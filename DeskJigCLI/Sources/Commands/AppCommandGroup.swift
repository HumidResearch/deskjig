//  AppCommandGroup.swift
//  DeskJigCLI

import ArgumentParser
import DeskJigShared
import Foundation

// `deskjig app` subcommands that target the RUNNING DeskJig app via the bento://
// URL scheme (#465), unlike the sibling subcommands in AppCommand.swift which
// operate on arbitrary macOS applications from the deskjig process.
//
// The key distinction: `deskjig workspace restore` runs the restore in the
// deskjig process with deskjig's OWN Accessibility grant, while
// `deskjig app restore` triggers an IN-APP restore inside DeskJig.app — the
// user's real permission context. In-app log lines lack the `[CLI]` prefix.
//
// bento://restore is always handled by DEBUG builds of DeskJig; Release builds
// only handle it when the hidden `BentoAllowAppRestoreURL` defaults flag is
// set (`defaults write com.mscontrol.bento BentoAllowAppRestoreURL -bool true`).

extension AppCommand {
    struct Restore: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "restore",
            abstract: "Trigger an in-app workspace restore in the running DeskJig app",
            discussion: """
            Opens bento://restore at the resolved DeskJig.app, which restores the
            workspace INSIDE the app process (the user's real Accessibility
            context), and asks the app to write a JSON completion report.

            With --wait, polls for that report, prints the restoration run ID,
            and exits 0 only when the app reports a successful restore with no
            failed windows. Inspect the run afterwards with:
              deskjig logs show <run-id>

            Requires a DEBUG build of DeskJig, or a Release build with the hidden
            defaults flag enabled:
              defaults write com.mscontrol.bento BentoAllowAppRestoreURL -bool true
            """
        )

        @Argument(help: "Workspace name to restore")
        var workspace: String

        @Flag(name: .customLong("wait"), help: "Wait for the in-app restore to complete and verify its result")
        var wait: Bool = false

        @Option(name: .customLong("timeout"), help: "Seconds to wait for completion with --wait (default: 120)")
        var timeout: Int = 120

        @OptionGroup var globalOptions: GlobalOptions

        mutating func run() async throws {
            guard timeout > 0 else {
                throw ValidationError("--timeout must be a positive number of seconds")
            }

            let start = Date()
            let reportPath = Self.makeReportPath()

            var components = URLComponents()
            components.scheme = BundleIdentity.urlScheme
            components.host = "restore"
            components.queryItems = [
                URLQueryItem(name: "workspace", value: workspace),
                URLQueryItem(name: "output", value: reportPath)
            ]
            guard let url = components.url else {
                DeskJigAppURLCommandOutput.emit(
                    .failure(action: "app-restore", exitCode: .invalidArguments, error: "Failed to construct bento://restore URL for workspace \"\(workspace)\""),
                    format: globalOptions.format,
                    start: start
                )
                return
            }

            try await DeskJigAppResolver.openDeskJigURL(url)

            guard wait else {
                DeskJigAppURLCommandOutput.emit(
                    .success(
                        action: "app-restore",
                        message: "Triggered in-app restore of \"\(workspace)\" (fire-and-forget; use --wait to verify completion)",
                        data: .dictionary([
                            "url": .string(url.absoluteString),
                            "reportPath": .string(reportPath),
                            "workspace": .string(workspace)
                        ])
                    ),
                    format: globalOptions.format,
                    start: start
                )
                return
            }

            guard let report = await Self.awaitReport(atPath: reportPath, timeoutSeconds: timeout) else {
                DeskJigAppURLCommandOutput.emit(
                    .failure(
                        action: "app-restore",
                        exitCode: .generalError,
                        error: "Timed out after \(timeout)s waiting for the in-app restore report at \(reportPath). "
                            + "Is DeskJig.app running? Release builds also require: "
                            + "defaults write com.mscontrol.bento BentoAllowAppRestoreURL -bool true"
                    ),
                    format: globalOptions.format,
                    start: start
                )
                return
            }

            guard let iteration = report.iterations.last else {
                let notes = report.notes.isEmpty ? "no iterations ran" : report.notes.joined(separator: "; ")
                DeskJigAppURLCommandOutput.emit(
                    .failure(action: "app-restore", exitCode: .actionFailed, error: "In-app restore did not run: \(notes)"),
                    format: globalOptions.format,
                    start: start
                )
                return
            }

            let succeeded = iteration.success && iteration.windowsFailed == 0
            let summary = "runId=\(iteration.runId) workspace=\"\(iteration.workspace)\" "
                + "restored=\(iteration.windowsRestored) failed=\(iteration.windowsFailed) appPid=\(report.appPid)"
            var data: [String: AnyCodableValue] = [
                "runId": .string(iteration.runId),
                "workspace": .string(iteration.workspace),
                "restored": .int(iteration.windowsRestored),
                "failed": .int(iteration.windowsFailed),
                "success": .bool(iteration.success),
                "appPid": .int(Int(report.appPid)),
                "appExecutable": .string(report.appExecutable),
                "reportPath": .string(reportPath)
            ]
            if !report.notes.isEmpty {
                data["notes"] = .array(report.notes.map { .string($0) })
            }

            let result: CommandResult = succeeded
                ? .success(action: "app-restore", message: "In-app restore completed: \(summary)", data: .dictionary(data))
                : CommandResult(
                    success: false,
                    exitCode: .actionFailed,
                    action: "app-restore",
                    data: .dictionary(data),
                    error: "In-app restore failed: \(summary)"
                )
            DeskJigAppURLCommandOutput.emit(result, format: globalOptions.format, start: start)
        }

        private static func makeReportPath() -> String {
            let timestamp = Int(Date().timeIntervalSince1970 * 1000)
            let pid = ProcessInfo.processInfo.processIdentifier
            return "/tmp/deskjig-app-restore-\(timestamp)-\(pid).json"
        }

        private static func awaitReport(atPath path: String, timeoutSeconds: Int) async -> AppRestoreReport? {
            let deadline = Date().addingTimeInterval(TimeInterval(timeoutSeconds))
            let url = URL(fileURLWithPath: path)
            while Date() < deadline {
                if FileManager.default.fileExists(atPath: path),
                   let data = try? Data(contentsOf: url),
                   let report = try? JSONDecoder().decode(AppRestoreReport.self, from: data) {
                    return report
                }
                guard await Task.sleepUnlessCancelled(nanoseconds: 500_000_000) else { return nil }
            }
            return nil
        }
    }

    struct Status: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "status",
            abstract: "Show whether DeskJig.app is running and which bundle receives bento:// URLs"
        )

        @OptionGroup var globalOptions: GlobalOptions

        mutating func run() async throws {
            let start = Date()
            let running = DeskJigAppResolver.runningDeskJigApps()
            let resolvedAppPath = DeskJigAppResolver.findDeskJigApp()

            let instances: [AnyCodableValue] = running.map { app in
                .dictionary([
                    "pid": .int(Int(app.pid)),
                    "bundlePath": .string(app.bundlePath),
                    "version": app.version.map { .string($0) } ?? .null
                ])
            }
            let data: AnyCodableValue = .dictionary([
                "running": .bool(!running.isEmpty),
                "instances": .array(instances),
                "resolvedAppPath": resolvedAppPath.map { .string($0) } ?? .null
            ])

            let message: String
            if let first = running.first {
                let extra = running.count > 1 ? " (+\(running.count - 1) more instance(s))" : ""
                message = "DeskJig is running (pid \(first.pid), version \(first.version ?? "unknown")) at \(first.bundlePath)\(extra)"
            } else if let resolvedAppPath {
                message = "DeskJig is not running; bento:// URLs would launch \(resolvedAppPath)"
            } else {
                message = "DeskJig is not running and no DeskJig.app bundle could be resolved"
            }

            DeskJigAppURLCommandOutput.emit(
                .success(action: "app-status", message: message, data: data),
                format: globalOptions.format,
                start: start
            )
        }
    }

    struct OpenURL: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "open-url",
            abstract: "Open a raw bento:// URL at the resolved DeskJig.app (escape hatch for scheme testing)"
        )

        @Argument(help: "bento:// URL to open")
        var url: String

        @OptionGroup var globalOptions: GlobalOptions

        mutating func run() async throws {
            let start = Date()
            guard let parsed = URL(string: url), parsed.scheme == BundleIdentity.urlScheme else {
                throw ValidationError("Expected a bento:// URL, got: \(url)")
            }

            try await DeskJigAppResolver.openDeskJigURL(parsed)
            DeskJigAppURLCommandOutput.emit(
                .success(
                    action: "app-open-url",
                    message: "Opened \(parsed.absoluteString) via DeskJig",
                    data: .dictionary(["url": .string(parsed.absoluteString)])
                ),
                format: globalOptions.format,
                start: start
            )
        }
    }
}

/// Report written by the app's GUIRestoreParityRunner to the `output` path
/// passed in the bento://restore URL.
private struct AppRestoreReport: Decodable {
    struct Iteration: Decodable {
        let workspace: String
        let runId: String
        let success: Bool
        let windowsRestored: Int
        let windowsFailed: Int
    }

    let startedAt: String
    let finishedAt: String
    let appPid: Int32
    let appExecutable: String
    let iterations: [Iteration]
    let notes: [String]
}

/// Output emission for the bento://-URL-backed `app` subcommands, matching the
/// envelope conventions of DeskJigRunner / PermissionsCommand.
private enum DeskJigAppURLCommandOutput {
    static func emit(_ result: CommandResult, format: OutputFormat, start: Date) {
        let durationMs = Date().timeIntervalSince(start) * 1000
        let agentResult = AgentCommandResult(from: result, durationMs: durationMs)
        if format == .json {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            if let encoded = try? encoder.encode(agentResult),
               let json = String(data: encoded, encoding: .utf8) {
                print(json)
            } else {
                print("{\"success\":false,\"exitCode\":\(result.exitCode)}")
            }
        } else {
            print(AgentOutputFormatter.formatText(agentResult))
        }
        fflush(stdout)

        if !result.success {
            Foundation.exit(Int32(result.exitCode))
        }
    }
}
