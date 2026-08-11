//  AppActionHandler.swift
//  DeskJigCLI

import Foundation
import DeskJigShared
import AppKit

/// Handler for application-related CLI actions
final class AppActionHandler: ActionHandler {

    private weak var executor: ActionExecutor?

    init(executor: ActionExecutor) {
        self.executor = executor
    }

    func canHandle(action: CLIAction) -> Bool {
        switch action {
        case .listRunningApps, .queryApps, .launchApp,
             .activateApp, .hideApp, .unhideApp, .terminateApp,
             .hideAllApps, .unhideAllApps:
            return true
        default:
            return false
        }
    }

    func execute(action: CLIAction) async -> CommandResult {
        guard let executor = executor else {
            return .failure(action: "app", exitCode: .generalError, error: "Executor deallocated")
        }

        switch action {
        case .listRunningApps:
            return executeListRunningApps(executor: executor)
        case .queryApps(let filter):
            return executeQueryApps(filter: filter, executor: executor)
        case .launchApp(let bundleID, let urls):
            return executeLaunchApp(bundleID: bundleID, urls: urls, executor: executor)
        case .activateApp(let target):
            return executeActivateApp(target: target, executor: executor)
        case .hideApp(let target):
            return executeHideApp(target: target, executor: executor)
        case .unhideApp(let target):
            return executeUnhideApp(target: target, executor: executor)
        case .terminateApp(let target):
            return executeTerminateApp(target: target, executor: executor)
        case .hideAllApps(let minWindowSize):
            return await executeHideAllApps(minWindowSize: minWindowSize, executor: executor)
        case .unhideAllApps:
            return await executeUnhideAllApps(executor: executor)
        default:
            return .failure(action: action.description, exitCode: .generalError, error: "Action not handled by AppActionHandler")
        }
    }

    // MARK: - Implementation

    private func executeListRunningApps(executor: ActionExecutor) -> CommandResult {
        let apps = App.running()

        if executor.shouldEmitTextOutput {
            let output = OutputFormatter.formatApps(apps, format: executor.format)
            print(output)
        }

        return .success(
            action: "list-running-apps",
            message: "Found \(apps.count) running app(s)",
            data: AnyCodableValue.from(apps.map { AppOutput(from: $0) })
        )
    }

    private func executeQueryApps(filter: AppFilter, executor: ActionExecutor) -> CommandResult {
        var apps = App.running()

        if let nameContains = filter.nameContains {
            apps = apps.filter { $0.localizedName?.localizedCaseInsensitiveContains(nameContains) == true }
        }
        if let bundleIDContains = filter.bundleIDContains {
            apps = apps.filter { $0.bundleID.localizedCaseInsensitiveContains(bundleIDContains) }
        }

        if executor.shouldEmitTextOutput {
            let output = OutputFormatter.formatApps(apps, format: executor.format)
            print(output)
        }

        return .success(
            action: "query-apps",
            message: "Found \(apps.count) app(s)",
            data: AnyCodableValue.from(apps.map { AppOutput(from: $0) })
        )
    }

    private func executeLaunchApp(bundleID: String, urls: [String]?, executor: ActionExecutor) -> CommandResult {
        if let appInfo = executor.applicationManager.findApplication(by: bundleID) {
            let success = executor.applicationManager.launchApplication(appInfo)
            if success {
                return .success(
                    action: "launch-app",
                    message: "Launched: \(appInfo.name)"
                )
            } else {
                return .failure(
                    action: "launch-app",
                    exitCode: .actionFailed,
                    error: "Failed to launch: \(appInfo.name)"
                )
            }
        }

        // Fallback: try NSWorkspace
        if let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            let config = NSWorkspace.OpenConfiguration()

            if let urls = urls, !urls.isEmpty {
                let urlObjects = urls.compactMap { URL(string: $0) }
                if !urlObjects.isEmpty {
                    let semaphore = DispatchSemaphore(value: 0)
                    var launchSuccess = false

                    NSWorkspace.shared.open(urlObjects, withApplicationAt: appURL, configuration: config) { _, error in
                        launchSuccess = error == nil
                        semaphore.signal()
                    }

                    _ = semaphore.wait(timeout: .now() + 5.0)

                    if launchSuccess {
                        return .success(action: "launch-app", message: "Launched: \(bundleID) with URLs")
                    }
                }
            }

            let semaphore = DispatchSemaphore(value: 0)
            var launchSuccess = false

            NSWorkspace.shared.openApplication(at: appURL, configuration: config) { _, error in
                launchSuccess = error == nil
                semaphore.signal()
            }

            _ = semaphore.wait(timeout: .now() + 5.0)

            if launchSuccess {
                return .success(action: "launch-app", message: "Launched: \(bundleID)")
            }
        }

        return .failure(
            action: "launch-app",
            exitCode: .notFound,
            error: "Application not found: \(bundleID)"
        )
    }

    private func executeActivateApp(target: WindowTarget, executor: ActionExecutor) -> CommandResult {
        guard let app = executor.resolveAppTarget(target) else {
            return .failure(
                action: "activate-app",
                exitCode: .notFound,
                error: "No app found matching \(target.description)"
            )
        }

        if app.activate() != nil {
            return .success(
                action: "activate-app",
                message: "Activated: \(app.localizedName ?? app.bundleID)"
            )
        } else {
            return .failure(
                action: "activate-app",
                exitCode: .actionFailed,
                error: "Failed to activate app"
            )
        }
    }

    private func executeHideApp(target: WindowTarget, executor: ActionExecutor) -> CommandResult {
        guard let app = executor.resolveAppTarget(target) else {
            return .failure(
                action: "hide-app",
                exitCode: .notFound,
                error: "No app found matching \(target.description)"
            )
        }

        if app.hide() != nil {
            return .success(
                action: "hide-app",
                message: "Hidden: \(app.localizedName ?? app.bundleID)"
            )
        } else {
            return .failure(
                action: "hide-app",
                exitCode: .actionFailed,
                error: "Failed to hide app"
            )
        }
    }

    private func executeUnhideApp(target: WindowTarget, executor: ActionExecutor) -> CommandResult {
        guard let app = executor.resolveAppTarget(target) else {
            return .failure(
                action: "unhide-app",
                exitCode: .notFound,
                error: "No app found matching \(target.description)"
            )
        }

        if app.unhide() != nil {
            return .success(
                action: "unhide-app",
                message: "Unhidden: \(app.localizedName ?? app.bundleID)"
            )
        } else {
            return .failure(
                action: "unhide-app",
                exitCode: .actionFailed,
                error: "Failed to unhide app"
            )
        }
    }

    private func executeTerminateApp(target: WindowTarget, executor: ActionExecutor) -> CommandResult {
        guard let app = executor.resolveAppTarget(target) else {
            return .failure(
                action: "terminate-app",
                exitCode: .notFound,
                error: "No app found matching \(target.description)"
            )
        }

        let appName = app.localizedName ?? app.bundleID

        if app.terminate() != nil {
            return .success(
                action: "terminate-app",
                message: "Terminated: \(appName)"
            )
        } else {
            return .failure(
                action: "terminate-app",
                exitCode: .actionFailed,
                error: "Failed to terminate app"
            )
        }
    }

    private func executeHideAllApps(minWindowSize: CGSize, executor: ActionExecutor) async -> CommandResult {
        let options = HideAllOptions(
            workspaceBundleIds: [],
            minWindowSize: minWindowSize,
            verbose: true
        )
        let result = await AppHideUtility.hideAllApps(options: options)

        if executor.shouldEmitTextOutput {
            print("Hidden: \(result.appsHidden) apps")
            print("Failed: \(result.appsFailed) apps")
            print("Skipped: \(result.appsSkipped) apps")
            print("Duration: \(result.durationMs)ms")

            if !result.hiddenAppNames.isEmpty {
                print("\nHidden apps:")
                for name in result.hiddenAppNames.sorted() {
                    print("  - \(name)")
                }
            }

            if !result.failedAppNames.isEmpty {
                print("\nFailed to hide:")
                for name in result.failedAppNames.sorted() {
                    print("  - \(name)")
                }
            }

            // Show skip reasons grouped
            let skipsByReason = Dictionary(grouping: result.perAppResults.filter { $0.skipped }) { $0.skipReason ?? "unknown" }
            for (reason, apps) in skipsByReason.sorted(by: { $0.key < $1.key }) {
                let reasonLabel = formatSkipReason(reason, minWindowSize: minWindowSize)
                print("\nSkipped (\(reasonLabel)): \(apps.count) apps")
                for app in apps.sorted(by: { $0.appName < $1.appName }) {
                    print("  - \(app.appName)")
                }
            }
        }

        // Build result data for JSON output including per-app results with skip reasons
        let perAppResultsData: [AnyCodableValue] = result.perAppResults.map { appResult in
            var dict: [String: AnyCodableValue] = [
                "bundleId": .string(appResult.bundleId),
                "appName": .string(appResult.appName),
                "pid": .int(Int(appResult.pid)),
                "success": .bool(appResult.success),
                "method": .string(appResult.method),
                "skipped": .bool(appResult.skipped)
            ]
            if let skipReason = appResult.skipReason {
                dict["skipReason"] = .string(skipReason)
            }
            return .dictionary(dict)
        }

        let resultData: [String: AnyCodableValue] = [
            "appsTargeted": .int(result.appsTargeted),
            "appsHidden": .int(result.appsHidden),
            "appsFailed": .int(result.appsFailed),
            "appsSkipped": .int(result.appsSkipped),
            "durationMs": .int(result.durationMs),
            "minWindowSize": .int(Int(minWindowSize.width)),
            "hiddenApps": .array(result.hiddenAppNames.map { .string($0) }),
            "failedApps": .array(result.failedAppNames.map { .string($0) }),
            "skippedApps": .array(result.skippedAppNames.map { .string($0) }),
            "perAppResults": .array(perAppResultsData)
        ]

        // Even if some apps failed, return success with full result data
        // The user can check appsFailed in the output to see if anything failed
        return .success(
            action: "hide-all-apps",
            message: "Hidden \(result.appsHidden) apps, failed \(result.appsFailed), skipped \(result.appsSkipped)",
            data: .dictionary(resultData)
        )
    }

    private func formatSkipReason(_ reason: String, minWindowSize: CGSize) -> String {
        switch reason {
        case "already_hidden": return "already hidden"
        case "workspace_app": return "workspace app"
        case "no_large_windows": return "no windows >= \(Int(minWindowSize.width))px"
        case "already_visible": return "already visible"
        default: return reason
        }
    }

    private func executeUnhideAllApps(executor: ActionExecutor) async -> CommandResult {
        let result = await AppUnhideUtility.unhideAllApps(options: .actionBar)

        if executor.shouldEmitTextOutput {
            print("Unhidden: \(result.appsUnhidden) apps")
            print("Failed: \(result.appsFailed) apps")
            print("Skipped: \(result.appsSkipped) apps")
            print("Duration: \(result.durationMs)ms")

            if !result.unhiddenAppNames.isEmpty {
                print("\nUnhidden apps:")
                for name in result.unhiddenAppNames.sorted() {
                    print("  - \(name)")
                }
            }

            if !result.failedAppNames.isEmpty {
                print("\nFailed to unhide:")
                for name in result.failedAppNames.sorted() {
                    print("  - \(name)")
                }
            }

            // Show skip reasons grouped
            let skipsByReason = Dictionary(grouping: result.perAppResults.filter { $0.skipped }) { $0.skipReason ?? "unknown" }
            for (reason, apps) in skipsByReason.sorted(by: { $0.key < $1.key }) {
                let reasonLabel = formatUnhideSkipReason(reason)
                print("\nSkipped (\(reasonLabel)): \(apps.count) apps")
                for app in apps.sorted(by: { $0.appName < $1.appName }) {
                    print("  - \(app.appName)")
                }
            }
        }

        // Build result data for JSON output including per-app results with skip reasons
        let perAppResultsData: [AnyCodableValue] = result.perAppResults.map { appResult in
            var dict: [String: AnyCodableValue] = [
                "bundleId": .string(appResult.bundleId),
                "appName": .string(appResult.appName),
                "pid": .int(Int(appResult.pid)),
                "success": .bool(appResult.success),
                "method": .string(appResult.method),
                "skipped": .bool(appResult.skipped)
            ]
            if let skipReason = appResult.skipReason {
                dict["skipReason"] = .string(skipReason)
            }
            return .dictionary(dict)
        }

        let resultData: [String: AnyCodableValue] = [
            "appsTargeted": .int(result.appsTargeted),
            "appsUnhidden": .int(result.appsUnhidden),
            "appsFailed": .int(result.appsFailed),
            "appsSkipped": .int(result.appsSkipped),
            "durationMs": .int(result.durationMs),
            "unhiddenApps": .array(result.unhiddenAppNames.map { .string($0) }),
            "failedApps": .array(result.failedAppNames.map { .string($0) }),
            "skippedApps": .array(result.skippedAppNames.map { .string($0) }),
            "perAppResults": .array(perAppResultsData)
        ]

        return .success(
            action: "unhide-all-apps",
            message: "Unhidden \(result.appsUnhidden) apps, failed \(result.appsFailed), skipped \(result.appsSkipped)",
            data: .dictionary(resultData)
        )
    }

    private func formatUnhideSkipReason(_ reason: String) -> String {
        switch reason {
        case "already_visible": return "already visible"
        default: return reason
        }
    }
}

