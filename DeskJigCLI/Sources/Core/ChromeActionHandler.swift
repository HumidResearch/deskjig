//  ChromeActionHandler.swift
//  DeskJigCLI

import Foundation
import DeskJigShared

/// Handler for Chrome-related CLI actions
final class ChromeActionHandler: ActionHandler {

    private weak var executor: ActionExecutor?

    init(executor: ActionExecutor) {
        self.executor = executor
    }

    func canHandle(action: CLIAction) -> Bool {
        switch action {
        case .listChromeWindows, .launchChromeProfile, .openChromeTabs,
             .switchChromeTab, .exportChromeTabs:
            return true
        default:
            return false
        }
    }

    func execute(action: CLIAction) async -> CommandResult {
        guard let executor = executor else {
            return .failure(action: "chrome", exitCode: .generalError, error: "Executor deallocated")
        }

        switch action {
        case .listChromeWindows:
            return executeListChromeWindows(executor: executor)
        case .launchChromeProfile(let profile, let urls):
            return executeLaunchChromeProfile(profile: profile, urls: urls)
        case .openChromeTabs(let target, let urls):
            return executeOpenChromeTabs(target: target, urls: urls)
        case .switchChromeTab(let target, let tabIndex):
            return executeSwitchChromeTab(target: target, tabIndex: tabIndex)
        case .exportChromeTabs(let target):
            return executeExportChromeTabs(target: target, executor: executor)
        default:
            return .failure(action: action.description, exitCode: .generalError, error: "Action not handled by ChromeActionHandler")
        }
    }

    // MARK: - Implementation

    private func executeListChromeWindows(executor: ActionExecutor) -> CommandResult {
        let captures = ChromeAutomationService.captureOpenWindows()

        if executor.shouldEmitTextOutput {
            let output = OutputFormatter.formatChromeWindows(captures, format: executor.format)
            print(output)
        }

        return .success(
            action: "list-chrome-windows",
            message: "Found \(captures.count) Chrome window(s)",
            data: AnyCodableValue.from(captures.map { ChromeWindowOutput(from: $0) })
        )
    }

    private func executeLaunchChromeProfile(profile: String, urls: [String]) -> CommandResult {
        let success = ChromeAutomationService.launchChromeWindow(profileDirectory: profile, urls: urls)

        if success {
            return .success(
                action: "launch-chrome-profile",
                message: "Launched Chrome with profile '\(profile)'"
            )
        } else {
            return .failure(
                action: "launch-chrome-profile",
                exitCode: .actionFailed,
                error: "Failed to launch Chrome with profile '\(profile)'"
            )
        }
    }

    private func executeOpenChromeTabs(target: WindowTarget, urls: [String]) -> CommandResult {
        let captures = ChromeAutomationService.captureOpenWindows()

        guard !captures.isEmpty else {
            return .failure(
                action: "open-chrome-tabs",
                exitCode: .notFound,
                error: "No Chrome windows found"
            )
        }

        let targetCapture: ChromeAppleScriptWindowCapture?
        switch target {
        case .byTitle(let title):
            targetCapture = captures.first { $0.title == title }
        case .byTitleContaining(let text):
            targetCapture = captures.first { $0.title.localizedCaseInsensitiveContains(text) }
        case .byApp(let profile):
            targetCapture = captures.first { $0.profileAppleScriptName?.localizedCaseInsensitiveContains(profile) == true }
        default:
            targetCapture = captures.first
        }

        guard let capture = targetCapture else {
            return .failure(
                action: "open-chrome-tabs",
                exitCode: .notFound,
                error: "No matching Chrome window found"
            )
        }

        ChromeAutomationService.openMissingTabs(urls, inWindowWithBounds: capture.bounds)

        return .success(
            action: "open-chrome-tabs",
            message: "Opened \(urls.count) tab(s) in Chrome"
        )
    }

    private func executeSwitchChromeTab(target: WindowTarget, tabIndex: Int) -> CommandResult {
        let captures = ChromeAutomationService.captureOpenWindows()

        guard !captures.isEmpty else {
            return .failure(
                action: "switch-chrome-tab",
                exitCode: .notFound,
                error: "No Chrome windows found"
            )
        }

        let targetCapture: ChromeAppleScriptWindowCapture?
        switch target {
        case .byTitle(let title):
            targetCapture = captures.first { $0.title == title }
        case .byTitleContaining(let text):
            targetCapture = captures.first { $0.title.localizedCaseInsensitiveContains(text) }
        case .byApp(let profile):
            targetCapture = captures.first { $0.profileAppleScriptName?.localizedCaseInsensitiveContains(profile) == true }
        default:
            targetCapture = captures.first
        }

        guard let capture = targetCapture else {
            return .failure(
                action: "switch-chrome-tab",
                exitCode: .notFound,
                error: "No matching Chrome window found"
            )
        }

        guard tabIndex > 0 && tabIndex <= capture.tabURLs.count else {
            return .failure(
                action: "switch-chrome-tab",
                exitCode: .invalidArguments,
                error: "Tab index \(tabIndex) out of range (1-\(capture.tabURLs.count))"
            )
        }

        ChromeAutomationService.setActiveTab(index: tabIndex, inWindowWithBounds: capture.bounds)

        return .success(
            action: "switch-chrome-tab",
            message: "Switched to tab #\(tabIndex)"
        )
    }

    private func executeExportChromeTabs(target: WindowTarget?, executor: ActionExecutor) -> CommandResult {
        let captures = ChromeAutomationService.captureOpenWindows()

        guard !captures.isEmpty else {
            return .failure(
                action: "export-chrome-tabs",
                exitCode: .notFound,
                error: "No Chrome windows found"
            )
        }

        let targetCaptures: [ChromeAppleScriptWindowCapture]
        if let target = target {
            switch target {
            case .byTitle(let title):
                targetCaptures = captures.filter { $0.title == title }
            case .byTitleContaining(let text):
                targetCaptures = captures.filter { $0.title.localizedCaseInsensitiveContains(text) }
            case .byApp(let profile):
                targetCaptures = captures.filter { $0.profileAppleScriptName?.localizedCaseInsensitiveContains(profile) == true }
            default:
                targetCaptures = captures
            }
        } else {
            targetCaptures = captures
        }

        if executor.shouldEmitTextOutput {
            let output = OutputFormatter.formatChromeWindows(targetCaptures, format: executor.format)
            print(output)
        }

        return .success(
            action: "export-chrome-tabs",
            message: "Exported \(targetCaptures.count) Chrome window(s)",
            data: AnyCodableValue.from(targetCaptures.map { ChromeWindowOutput(from: $0) })
        )
    }
}
