//  SharedContext.swift
//  DeskJigCLI

import DeskJigShared
import Foundation

final class SharedContext {
    let format: OutputFormat
    let verbose: Bool
    let workspaceManager: SharedWorkspaceManager
    let applicationManager: ApplicationManager
    let displayManager: DisplayManager
    let executor: ActionExecutor

    private init(
        format: OutputFormat,
        verbose: Bool,
        workspaceManager: SharedWorkspaceManager,
        applicationManager: ApplicationManager,
        displayManager: DisplayManager,
        executor: ActionExecutor
    ) {
        self.format = format
        self.verbose = verbose
        self.workspaceManager = workspaceManager
        self.applicationManager = applicationManager
        self.displayManager = displayManager
        self.executor = executor
    }

    /// Print a structured error (JSON or text) and terminate the process.
    private static func exitWithError(
        action: String,
        message: String,
        exitCode: ExitCode,
        format: OutputFormat,
        textSuffix: String? = nil
    ) -> Never {
        let result = CommandResult.failure(
            action: action,
            exitCode: exitCode,
            error: message
        )
        let agentResult = AgentCommandResult(from: result, durationMs: 0)
        if format == .json {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            if let data = try? encoder.encode(agentResult),
               let jsonString = String(data: data, encoding: .utf8) {
                print(jsonString)
            } else {
                print("{\"success\":false,\"exitCode\":\(exitCode.rawValue)}")
            }
        } else {
            print(AgentOutputFormatter.formatText(agentResult))
            if let suffix = textSuffix {
                print(suffix)
            }
        }
        fflush(stdout)
        Foundation.exit(exitCode.rawValue)
    }

    @MainActor
    static func prepare(
        options: GlobalOptions,
        requireAccessibility: Bool,
        requireWindowRefresh: Bool
    ) async -> SharedContext {
        let format = options.format
        let verbose = options.verbose

        CLIFileLogger.shared.configure()
        DeskJigLog.configureCLI(verbose: verbose)

        if requireAccessibility {
            let accessibilityManager = AccessibilityManager()
            if !accessibilityManager.hasAccessibilityPermissions {
                if format != .json {
                    accessibilityManager.requestAccessibilityPermissions()
                }
                exitWithError(
                    action: "init",
                    message: "Accessibility permissions required",
                    exitCode: .permissionDenied,
                    format: format,
                    textSuffix: "hint=\"Grant accessibility permissions to deskjig in System Settings.\""
                )
            }
        }

        let workspaceManager = SharedWorkspaceManager()
        let applicationManager = ApplicationManager()
        workspaceManager.setApplicationManager(applicationManager)

        let executor = ActionExecutor(
            workspaceManager: workspaceManager,
            applicationManager: applicationManager,
            displayManager: workspaceManager.displayManager,
            format: .json,
            verbose: verbose,
            shouldPrintTextOutput: false
        )

        return SharedContext(
            format: format,
            verbose: verbose,
            workspaceManager: workspaceManager,
            applicationManager: applicationManager,
            displayManager: workspaceManager.displayManager,
            executor: executor
        )
    }
}

enum DeskJigRunner {
    @MainActor
    static func run(
        actions: [CLIAction],
        options: GlobalOptions,
        requireAccessibility: Bool = true,
        requireWindowRefresh: Bool? = nil,
        continueOnError: Bool = false
    ) async throws {
        let runStart = Date()
        let shouldRefreshWindows = requireWindowRefresh ?? requireAccessibility
        let context = await SharedContext.prepare(
            options: options,
            requireAccessibility: requireAccessibility,
            requireWindowRefresh: shouldRefreshWindows
        )
        var results: [AgentCommandResult] = []
        let batchStart = Date()

        for action in actions {
            let actionStart = Date()
            let result = await context.executor.executeSingle(action)
            let durationMs = Date().timeIntervalSince(actionStart) * 1000
            let totalDurationMs = actions.count == 1
                ? Date().timeIntervalSince(runStart) * 1000
                : nil
            results.append(AgentCommandResult(
                from: result,
                durationMs: durationMs,
                totalDurationMs: totalDurationMs
            ))

            if !result.success && !continueOnError {
                break
            }
        }

        let durationMs = Date().timeIntervalSince(batchStart) * 1000
        let successCount = results.filter { $0.success }.count
        let failureCount = results.filter { !$0.success }.count
        let exitCode: ExitCode = failureCount == 0
            ? .success
            : (successCount == 0 ? .actionFailed : .partialSuccess)
        let batchResult = AgentBatchResult(
            success: failureCount == 0,
            exitCode: Int(exitCode.rawValue),
            durationMs: durationMs,
            totalActions: results.count,
            successCount: successCount,
            failureCount: failureCount,
            results: results
        )

        if context.format == .json {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            if results.count == 1, let first = results.first {
                if let data = try? encoder.encode(first),
                   let jsonString = String(data: data, encoding: .utf8) {
                    print(jsonString)
                } else {
                    print("{\"success\":false,\"exitCode\":\(exitCode.rawValue)}")
                }
            } else {
                if let data = try? encoder.encode(batchResult),
                   let jsonString = String(data: data, encoding: .utf8) {
                    print(jsonString)
                } else {
                    print("{\"success\":false,\"exitCode\":\(exitCode.rawValue)}")
                }
            }
        } else {
            if results.count == 1, let first = results.first {
                print(AgentOutputFormatter.formatText(first))
            } else {
                print(AgentOutputFormatter.formatText(batchResult))
            }
        }

        fflush(stdout)
        Foundation.exit(exitCode.rawValue)
    }
}

enum DeskJigVersion {
    static var current: String {
        if let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String {
            return version
        }
        if let version = readVersionFromJSON() {
            return version
        }
        return "unknown"
    }

    private static func readVersionFromJSON() -> String? {
        let fileManager = FileManager.default
        let cwd = URL(fileURLWithPath: fileManager.currentDirectoryPath)
        var candidates: [URL] = [cwd.appendingPathComponent("version.json")]

        let executableURL = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        var dir = executableURL.deletingLastPathComponent()
        for _ in 0..<4 {
            candidates.append(dir.appendingPathComponent("version.json"))
            dir = dir.deletingLastPathComponent()
        }

        for url in candidates {
            guard fileManager.fileExists(atPath: url.path),
                  let data = try? Data(contentsOf: url),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                continue
            }
            if let marketing = json["marketing"] as? String { return marketing }
            if let xcode = json["xcode"] as? String { return xcode }
        }

        return nil
    }
}
