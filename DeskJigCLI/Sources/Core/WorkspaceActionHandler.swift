//  WorkspaceActionHandler.swift
//  DeskJigCLI

import Foundation
import CoreGraphics
import DeskJigShared

/// Handler for workspace-related CLI actions
final class WorkspaceActionHandler: ActionHandler {

    private weak var executor: ActionExecutor?

    init(executor: ActionExecutor) {
        self.executor = executor
    }

    func canHandle(action: CLIAction) -> Bool {
        switch action {
        case .listWorkspaces, .workspaceCreateFromSpec, .workspaceInfo, .deleteWorkspace, .workspaceEdit,
             .workspaceWindowList, .workspaceWindowUpdate, .workspaceWindowAdd, .workspaceWindowRemove,
             .restoreWorkspace, .restoreWorkspaceFile, .workspaceImportFile,
             .debugRestoreLoop, .createTestWorkspaces,
             .createRichWorkspace, .dumpWindows, .listDisplays:
            return true
        default:
            return false
        }
    }

    func execute(action: CLIAction) async -> CommandResult {
        guard let executor = executor else {
            return .failure(action: "workspace", exitCode: .generalError, error: "Executor deallocated")
        }

        switch action {
        case .listWorkspaces:
            return executeListWorkspaces(executor: executor)
        case .workspaceCreateFromSpec(let spec):
            return executeWorkspaceCreateFromSpec(spec: spec, executor: executor)
        case .workspaceInfo(let name):
            return executeWorkspaceInfo(name: name, executor: executor)
        case .deleteWorkspace(let name):
            return executeDeleteWorkspace(name: name, executor: executor)
        case .workspaceEdit(let name, let rename, let icon, let shortcut):
            return executeWorkspaceEdit(name: name, rename: rename, icon: icon, shortcut: shortcut, executor: executor)
        case .workspaceWindowList(let name):
            return executeWorkspaceWindowList(name: name, executor: executor)
        case .workspaceWindowUpdate(let name, let index, let position, let screen, let openPath, let title):
            return executeWorkspaceWindowUpdate(
                name: name,
                index: index,
                position: position,
                screen: screen,
                openPath: openPath,
                title: title,
                executor: executor
            )
        case .workspaceWindowAdd(let name, let bundleID, let appAlias, let appName, let title, let openPath, let position, let screen):
            return executeWorkspaceWindowAdd(
                name: name,
                bundleID: bundleID,
                appAlias: appAlias,
                appName: appName,
                title: title,
                openPath: openPath,
                position: position,
                screen: screen,
                executor: executor
            )
        case .workspaceWindowRemove(let name, let index):
            return executeWorkspaceWindowRemove(name: name, index: index, executor: executor)
        case .restoreWorkspace(let options):
            return await executeRestoreWorkspace(options: options, executor: executor)
        case .restoreWorkspaceFile(let options):
            return await executeRestoreWorkspaceFile(options: options, executor: executor)
        case .workspaceImportFile(let path, let replaceExisting):
            return executeWorkspaceImportFile(path: path, replaceExisting: replaceExisting, executor: executor)
        case .debugRestoreLoop(let options):
            return await executeDebugRestoreLoop(options: options, executor: executor)
        case .createTestWorkspaces(let options):
            return executeCreateTestWorkspaces(options: options, executor: executor)
        case .createRichWorkspace(let options):
            return executeCreateRichWorkspace(options: options, executor: executor)
        case .dumpWindows:
            return executeDumpWindows(executor: executor)
        case .listDisplays:
            return executeListDisplays(executor: executor)
        default:
            return .failure(action: action.description, exitCode: .generalError, error: "Action not handled by WorkspaceActionHandler")
        }
    }

    // MARK: - Private Implementation

    private func executeListWorkspaces(executor: ActionExecutor) -> CommandResult {
        let workspaces = executor.workspaceManager.savedWorkspaces

        if executor.shouldEmitTextOutput {
            let output = OutputFormatter.formatWorkspaces(workspaces, format: executor.format)
            print(output)
        }

        return .success(
            action: "list-workspaces",
            message: "Found \(workspaces.count) workspace(s)",
            data: AnyCodableValue.from(workspaces.map { WorkspaceOutput(from: $0) })
        )
    }

    private struct WorkspaceCreateOutput: Codable {
        let id: String
        let name: String
        let windowCount: Int
        let replacedExisting: Bool
    }

    private struct WorkspaceInfoOutput: Codable {
        let id: String
        let name: String
        let createdAt: String
        let lastActivatedAt: String?
        let windowCount: Int
        let screenCount: Int
        let windows: [WindowDetailOutput]
        // GH #579: additive key — pre-restore portability findings.
        let portability: WorkspacePortabilityReport
    }

    private struct WorkspaceWindowListOutput: Codable {
        let workspace: String
        let windowCount: Int
        let windows: [IndexedWindowDetailOutput]
    }

    private func executeWorkspaceInfo(name: String, executor: ActionExecutor) -> CommandResult {
        let workspaces = executor.workspaceManager.savedWorkspaces

        let exactMatch = workspaces.first { $0.name.compare(name, options: [.caseInsensitive]) == .orderedSame }
        let partialMatches = workspaces.filter { $0.name.localizedCaseInsensitiveContains(name) }

        let workspace: Workspace
        if let exact = exactMatch {
            workspace = exact
        } else if partialMatches.count == 1 {
            workspace = partialMatches[0]
        } else if partialMatches.count > 1 {
            return .failure(
                action: "workspace-info",
                exitCode: .invalidArguments,
                error: "Multiple workspaces matched '\(name)'. Please be more specific."
            )
        } else {
            return .failure(
                action: "workspace-info",
                exitCode: .notFound,
                error: "No workspace found matching '\(name)'"
            )
        }

        let portabilityReport = WorkspacePortabilityAnalyzer().analyze(
            workspace: workspace,
            currentDisplayCount: currentEffectiveScreens(executor: executor).count
        )

        if executor.shouldEmitTextOutput {
            let formatter = DateFormatter()
            formatter.dateStyle = .medium
            formatter.timeStyle = .short

            print("Workspace: \(workspace.name)")
            print("ID: \(workspace.id)")
            print("Windows: \(workspace.windows.count)")
            print("Screens: \(workspace.screens?.count ?? 0)")
            print("Created: \(formatter.string(from: workspace.createdAt))")
            if let lastActivated = workspace.lastActivatedAt {
                print("Last Activated: \(formatter.string(from: lastActivated))")
            }
            print("")
            print("Windows:")

            for (index, window) in workspace.windows.enumerated() {
                let title = window.windowTitle.isEmpty ? "<No Title>" : window.windowTitle
                let openPath = window.openPath ?? "<none>"
                let screenLabel = window.screenIndex.map { "\($0)" } ?? "<none>"
                print("  [\(index)] \(window.appName) (\(window.bundleIdentifier))")
                print("       Title: \(title)")
                print("       Open Path: \(openPath)")
                print("       Screen: \(screenLabel)")
                if let relative = window.relativeFrame {
                    print(String(format: "       Relative: x=%.2f%% y=%.2f%% w=%.2f%% h=%.2f%%",
                                 relative.xPercent * 100,
                                 relative.yPercent * 100,
                                 relative.widthPercent * 100,
                                 relative.heightPercent * 100))
                } else {
                    print("       Relative: <none>")
                }
            }

            print("")
            print("Portability:")
            if portabilityReport.hasFindings {
                for warning in portabilityReport.warnings {
                    print("  ⚠️  \(warning)")
                }
            } else {
                print("  ✓ No issues — all apps, folders, and displays are available.")
            }
        }

        let formatter = ISO8601DateFormatter()
        let windowsOutput = workspace.windows.map { window -> WindowDetailOutput in
            let relative = window.relativeFrame.map {
                RelativeFrameDetail(
                    xPercent: $0.xPercent,
                    yPercent: $0.yPercent,
                    widthPercent: $0.widthPercent,
                    heightPercent: $0.heightPercent
                )
            }

            return WindowDetailOutput(
                id: window.id.uuidString,
                appName: window.appName,
                bundleID: window.bundleIdentifier,
                title: window.windowTitle,
                openPath: window.openPath,
                screenIndex: window.screenIndex,
                relativeFrame: relative
            )
        }

        let output = WorkspaceInfoOutput(
            id: workspace.id.uuidString,
            name: workspace.name,
            createdAt: formatter.string(from: workspace.createdAt),
            lastActivatedAt: workspace.lastActivatedAt.map { formatter.string(from: $0) },
            windowCount: workspace.windows.count,
            screenCount: workspace.screens?.count ?? 0,
            windows: windowsOutput,
            portability: portabilityReport
        )

        // Surface portability findings in the message too: deskjig's text mode
        // renders only the result envelope (message), not handler stdout.
        var infoMessage = "Workspace info for '\(workspace.name)'"
        if portabilityReport.hasFindings {
            infoMessage += " — portability: \(portabilitySummary(for: portabilityReport))"
        }

        return .success(
            action: "workspace-info",
            message: executor.format == .text ? nil : infoMessage,
            data: AnyCodableValue.from(output)
        )
    }

    private func executeWorkspaceEdit(
        name: String,
        rename: String?,
        icon: String?,
        shortcut: String?,
        executor: ActionExecutor
    ) -> CommandResult {
        let workspaces = executor.workspaceManager.savedWorkspaces
        let resolution = resolveWorkspace(named: name, from: workspaces, action: "workspace-edit")

        guard case let .success(workspace) = resolution else {
            return resolution.failureResult
        }

        var updated = workspace
        var updates: [String] = []

        if let rename, !rename.isEmpty, rename != workspace.name {
            updated = updated.withNewName(rename)
            updates.append("name")
        }

        if let icon, !icon.isEmpty {
            updated = updated.withNewIcon(icon)
            updates.append("icon")
        }

        if let shortcut, !shortcut.isEmpty {
            guard let parsed = parseShortcut(shortcut) else {
                return .failure(
                    action: "workspace-edit",
                    exitCode: .invalidArguments,
                    error: "Invalid shortcut format. Example: cmd+shift+1"
                )
            }
            updated = updated.withNewKeyboardShortcut(parsed)
            updates.append("shortcut")
        }

        guard !updates.isEmpty else {
            return .failure(
                action: "workspace-edit",
                exitCode: .invalidArguments,
                error: "No updates provided."
            )
        }

        executor.workspaceManager.updateWorkspace(updated)
        let changes = updates.joined(separator: ", ")
        return .success(
            action: "workspace-edit",
            message: "Updated workspace '\(updated.name)' (\(changes))"
        )
    }

    private func executeWorkspaceCreateFromSpec(
        spec: WorkspaceCreationSpec,
        executor: ActionExecutor
    ) -> CommandResult {
        let existingWorkspace = executor.workspaceManager.savedWorkspaces.first {
            $0.name.compare(spec.name, options: [.caseInsensitive]) == .orderedSame
        }
        let resolution = WorkspaceCreationSpecResolver.resolve(
            spec: spec,
            displayManager: executor.workspaceManager.displayManager,
            replacing: spec.replaceExisting ? existingWorkspace : nil
        )

        switch resolution {
        case .failure(let message):
            return .failure(
                action: "workspace-create-from-spec",
                exitCode: .invalidArguments,
                error: message
            )
        case .success(let workspace):
            let outcome = executor.workspaceManager.importWorkspace(
                workspace,
                replaceExisting: spec.replaceExisting
            )

            switch outcome {
            case .added:
                let output = WorkspaceCreateOutput(
                    id: workspace.id.uuidString,
                    name: workspace.name,
                    windowCount: workspace.windows.count,
                    replacedExisting: false
                )
                return .success(
                    action: "workspace-create-from-spec",
                    message: "Created workspace '\(workspace.name)'",
                    data: AnyCodableValue.from(output)
                )
            case .replaced:
                let output = WorkspaceCreateOutput(
                    id: workspace.id.uuidString,
                    name: workspace.name,
                    windowCount: workspace.windows.count,
                    replacedExisting: true
                )
                return .success(
                    action: "workspace-create-from-spec",
                    message: "Replaced workspace '\(workspace.name)'",
                    data: AnyCodableValue.from(output)
                )
            case .skipped(let reason):
                return .failure(
                    action: "workspace-create-from-spec",
                    exitCode: .actionFailed,
                    error: reason
                )
            }
        }
    }

    private func executeWorkspaceWindowList(name: String, executor: ActionExecutor) -> CommandResult {
        let workspaces = executor.workspaceManager.savedWorkspaces
        let resolution = resolveWorkspace(named: name, from: workspaces, action: "workspace-window-list")

        guard case let .success(workspace) = resolution else {
            return resolution.failureResult
        }

        let windows = workspace.windows.enumerated().map { index, window in
            IndexedWindowDetailOutput(
                index: index,
                id: window.id.uuidString,
                appName: window.appName,
                bundleID: window.bundleIdentifier,
                title: window.windowTitle,
                openPath: window.openPath,
                screenIndex: window.screenIndex,
                relativeFrame: window.relativeFrame.map {
                    .init(
                        xPercent: $0.xPercent,
                        yPercent: $0.yPercent,
                        widthPercent: $0.widthPercent,
                        heightPercent: $0.heightPercent
                    )
                }
            )
        }

        let output = WorkspaceWindowListOutput(
            workspace: workspace.name,
            windowCount: workspace.windows.count,
            windows: windows
        )

        return .success(
            action: "workspace-window-list",
            message: "Found \(workspace.windows.count) window(s) in '\(workspace.name)'",
            data: AnyCodableValue.from(output)
        )
    }

    private func executeWorkspaceWindowUpdate(
        name: String,
        index: Int,
        position: String?,
        screen: Int?,
        openPath: String?,
        title: String?,
        executor: ActionExecutor
    ) -> CommandResult {
        let workspaces = executor.workspaceManager.savedWorkspaces
        let resolution = resolveWorkspace(named: name, from: workspaces, action: "workspace-window-update")

        guard case let .success(workspace) = resolution else {
            return resolution.failureResult
        }

        guard workspace.windows.indices.contains(index) else {
            return .failure(
                action: "workspace-window-update",
                exitCode: .invalidArguments,
                error: "Window index out of range."
            )
        }

        let existing = workspace.windows[index]
        var updated = existing

        if let title {
            updated = updated.withWindowTitle(title)
        }

        if let openPath {
            updated = updated.withOpenPath(openPath)
        }

        if let screen {
            updated = updated.withScreenMapping(screenIndex: screen)
        }

        if let position {
            guard let windowPosition = DeskJigShared.WindowPosition.parse(position) else {
                return .failure(
                    action: "workspace-window-update",
                    exitCode: .invalidArguments,
                    error: "Invalid position: \(position)"
                )
            }
            updated = updated.withRelativeFrame(windowPosition.toRelativeFrame())
        }

        let updatedWorkspace = workspace.withUpdatedWindow(updated)
        executor.workspaceManager.updateWorkspace(updatedWorkspace)

        return .success(
            action: "workspace-window-update",
            message: "Updated window [\(index)] in '\(updatedWorkspace.name)'"
        )
    }

    private func executeWorkspaceWindowAdd(
        name: String,
        bundleID: String?,
        appAlias: String?,
        appName: String?,
        title: String?,
        openPath: String?,
        position: String?,
        screen: Int?,
        executor: ActionExecutor
    ) -> CommandResult {
        let workspaces = executor.workspaceManager.savedWorkspaces
        let resolution = resolveWorkspace(named: name, from: workspaces, action: "workspace-window-add")

        guard case let .success(workspace) = resolution else {
            return resolution.failureResult
        }

        let resolvedApp = WorkspaceCreationSpecResolver.resolveAppDescriptor(
            bundleId: bundleID,
            appAlias: appAlias,
            appName: appName
        )
        switch resolvedApp {
        case .failure(let message):
            return .failure(
                action: "workspace-window-add",
                exitCode: .invalidArguments,
                error: message.message
            )
        case .success(let appDescriptor):
            let relativeFrame: RelativeWindowFrame?
            if let position {
                guard let windowPosition = DeskJigShared.WindowPosition.parse(position) else {
                    return .failure(
                        action: "workspace-window-add",
                        exitCode: .invalidArguments,
                        error: "Invalid position: \(position)"
                    )
                }
                relativeFrame = windowPosition.toRelativeFrame()
            } else {
                relativeFrame = nil
            }

            let window = WorkspaceWindow(
                bundleIdentifier: appDescriptor.bundleId,
                appName: appDescriptor.appName,
                windowTitle: title ?? appDescriptor.defaultWindowTitle,
                openPath: openPath,
                applicationPath: nil,
                chromeState: nil,
                screenIndex: screen,
                relativeFrame: relativeFrame
            )

            let updatedWorkspace = workspace.withNewWindows(workspace.windows + [window])
            executor.workspaceManager.updateWorkspace(updatedWorkspace)

            return .success(
                action: "workspace-window-add",
                message: "Added window to '\(updatedWorkspace.name)'"
            )
        }
    }

    private func executeWorkspaceWindowRemove(
        name: String,
        index: Int,
        executor: ActionExecutor
    ) -> CommandResult {
        let workspaces = executor.workspaceManager.savedWorkspaces
        let resolution = resolveWorkspace(named: name, from: workspaces, action: "workspace-window-remove")

        guard case let .success(workspace) = resolution else {
            return resolution.failureResult
        }

        guard workspace.windows.indices.contains(index) else {
            return .failure(
                action: "workspace-window-remove",
                exitCode: .invalidArguments,
                error: "Window index out of range."
            )
        }

        var updatedWindows = workspace.windows
        updatedWindows.remove(at: index)
        let updatedWorkspace = workspace.withNewWindows(updatedWindows)
        executor.workspaceManager.updateWorkspace(updatedWorkspace)

        return .success(
            action: "workspace-window-remove",
            message: "Removed window [\(index)] from '\(updatedWorkspace.name)'"
        )
    }

    private func parseShortcut(_ value: String) -> WorkspaceKeyboardShortcut? {
        let parts = value
            .lowercased()
            .split(separator: "+")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        guard !parts.isEmpty else { return nil }

        let modifiers = Set(["cmd", "command", "shift", "ctrl", "control", "option", "alt"])
        var keys: [String] = []
        var parsedModifiers: [String] = []

        for part in parts {
            if modifiers.contains(part) {
                let normalized: String
                switch part {
                case "command":
                    normalized = "command"
                case "ctrl":
                    normalized = "control"
                case "alt":
                    normalized = "option"
                default:
                    normalized = String(part)
                }
                parsedModifiers.append(normalized)
            } else {
                keys.append(String(part))
            }
        }

        guard keys.count == 1 else { return nil }
        return WorkspaceKeyboardShortcut(key: keys[0], modifiers: parsedModifiers)
    }

    private func executeDeleteWorkspace(name: String, executor: ActionExecutor) -> CommandResult {
        let workspaces = executor.workspaceManager.savedWorkspaces
        let resolution = resolveWorkspace(named: name, from: workspaces, action: "delete-workspace")

        guard case let .success(workspaceToDelete) = resolution else {
            return resolution.failureResult
        }

        let deleted = executor.workspaceManager.deleteWorkspace(workspaceToDelete)
        if deleted {
            return .success(
                action: "delete-workspace",
                message: "Deleted workspace '\(workspaceToDelete.name)'"
            )
        }

        return .failure(
            action: "delete-workspace",
            exitCode: .actionFailed,
            error: "Failed to delete workspace '\(workspaceToDelete.name)'"
        )
    }

    private func executeRestoreWorkspace(options: RestoreWorkspaceOptions, executor: ActionExecutor) async -> CommandResult {
        let workspaces = executor.workspaceManager.savedWorkspaces
        let resolution = resolveWorkspace(named: options.name, from: workspaces, action: "restore-workspace")

        guard case let .success(workspaceToRestore) = resolution else {
            return resolution.failureResult
        }

        let (overrides, overridesError) = resolveWorkspaceOverrides(
            overrideFilePath: options.overrideFilePath,
            cliOverrides: options.windowOverrides,
            action: "restore-workspace"
        )
        if let overridesError { return overridesError }

        let (resolvedWorkspace, workspaceError) = applyOverridesIfNeeded(
            workspace: workspaceToRestore,
            overrides: overrides,
            action: "restore-workspace"
        )
        if let workspaceError { return workspaceError }

        // Resolve hideAllApps: explicit flag > UserDefaults preference
        let hideAllApps = options.hideAllApps ?? UserDefaults.standard.bool(forKey: "restoreHideAllApps")
        DeskJigLog.info(.cli, "hideAllApps resolved to \(hideAllApps) (explicit: \(options.hideAllApps != nil), userDefault: \(UserDefaults.standard.bool(forKey: "restoreHideAllApps")))")

        // GH #579: pre-restore portability validation + deterministic degradation.
        let portability = analyzePortabilityForRestore(
            workspace: resolvedWorkspace,
            action: "restore-workspace",
            executor: executor
        )
        if let failure = portability.failure { return failure }

        let result = await restoreFluentWorkspace(
            portability.degradation.workspace,
            hideAllApps: hideAllApps,
            displayAssignments: portability.degradation.displayAssignments,
            executor: executor
        )
        return commandResult(
            for: result,
            workspace: portability.degradation.workspace,
            action: "restore-workspace",
            portability: portability.report,
            degradation: portability.degradation
        )
    }

    private func executeRestoreWorkspaceFile(options: RestoreWorkspaceFileOptions, executor: ActionExecutor) async -> CommandResult {
        let url = URL(fileURLWithPath: options.path).standardizedFileURL

        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            return .failure(
                action: "restore-workspace-file",
                exitCode: .notFound,
                error: "Failed to read workspace file: \(url.path) (\(error.localizedDescription))"
            )
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = WorkspaceJSONDateCoding.decodingStrategy

        let workspaceToRestore: Workspace
        do {
            workspaceToRestore = try decoder.decode(Workspace.self, from: data)
        } catch {
            if let arr = try? decoder.decode([Workspace].self, from: data), let first = arr.first, arr.count == 1 {
                workspaceToRestore = first
            } else {
                return .failure(
                    action: "restore-workspace-file",
                    exitCode: .invalidArguments,
                    error: "Failed to decode workspace JSON: \(error.localizedDescription)"
                )
            }
        }

        let (overrides, overridesError) = resolveWorkspaceOverrides(
            overrideFilePath: options.overrideFilePath,
            cliOverrides: options.windowOverrides,
            action: "restore-workspace-file"
        )
        if let overridesError { return overridesError }

        let (resolvedWorkspace, workspaceError) = applyOverridesIfNeeded(
            workspace: workspaceToRestore,
            overrides: overrides,
            action: "restore-workspace-file"
        )
        if let workspaceError { return workspaceError }

        // Read hideAllApps from UserDefaults (matching GUI behavior)
        let hideAllApps = UserDefaults.standard.bool(forKey: "restoreHideAllApps")
        DeskJigLog.info(.cli, "restore-workspace-file: hideAllApps=\(hideAllApps) (from UserDefaults)")

        // GH #579: pre-restore portability validation + deterministic degradation.
        let portability = analyzePortabilityForRestore(
            workspace: resolvedWorkspace,
            action: "restore-workspace-file",
            executor: executor
        )
        if let failure = portability.failure { return failure }

        let result = await restoreFluentWorkspace(
            portability.degradation.workspace,
            hideAllApps: hideAllApps,
            displayAssignments: portability.degradation.displayAssignments,
            executor: executor
        )
        return commandResult(
            for: result,
            workspace: portability.degradation.workspace,
            action: "restore-workspace-file",
            portability: portability.report,
            degradation: portability.degradation
        )
    }

    private func resolveWorkspaceOverrides(
        overrideFilePath: String?,
        cliOverrides: [WindowOverride],
        action: String
    ) -> (WorkspaceRestoreOverrides?, CommandResult?) {
        var fileOverrides: WorkspaceRestoreOverrides?

        if let overrideFilePath {
            let url = URL(fileURLWithPath: overrideFilePath).standardizedFileURL
            do {
                let data = try Data(contentsOf: url)
                let decoder = JSONDecoder()
                fileOverrides = try decoder.decode(WorkspaceRestoreOverrides.self, from: data)
            } catch {
                return (
                    nil,
                    CommandResult.failure(
                        action: action,
                        exitCode: .invalidArguments,
                        error: "Failed to read overrides file: \(overrideFilePath) (\(error.localizedDescription))"
                    )
                )
            }
        }

        if (fileOverrides?.windows.isEmpty ?? true) && cliOverrides.isEmpty {
            return (nil, nil)
        }

        var mergedByIndex: [Int: WindowOverride] = [:]
        if let fileOverrides {
            for override in fileOverrides.windows {
                mergedByIndex[override.index] = override
            }
        }

        for override in cliOverrides {
            if let existing = mergedByIndex[override.index] {
                mergedByIndex[override.index] = mergeWindowOverride(base: existing, incoming: override)
            } else {
                mergedByIndex[override.index] = override
            }
        }

        let merged = WorkspaceRestoreOverrides(
            windows: mergedByIndex.values.sorted { $0.index < $1.index }
        )
        return (merged, nil)
    }

    private func applyOverridesIfNeeded(
        workspace: Workspace,
        overrides: WorkspaceRestoreOverrides?,
        action: String
    ) -> (Workspace, CommandResult?) {
        guard let overrides else { return (workspace, nil) }

        var windows = workspace.windows
        var didChangeOpenPath = false

        for override in overrides.windows {
            guard override.index >= 0, override.index < windows.count else {
                return (
                    workspace,
                    CommandResult.failure(
                        action: action,
                        exitCode: .invalidArguments,
                        error: "Override index \(override.index) out of range (0-\(max(0, windows.count - 1)))"
                    )
                )
            }

            var window = windows[override.index]

            if let openPath = override.openPath {
                window = window.withOpenPath(openPath)
                didChangeOpenPath = true
            }

            if let chromeOverride = override.chrome {
                let isChromeWindow = chromeBundleIdentifiers.contains(window.bundleIdentifier) || window.chromeState != nil
                guard isChromeWindow else {
                    return (
                        workspace,
                        CommandResult.failure(
                            action: action,
                            exitCode: .invalidArguments,
                            error: "Chrome override provided for non-Chrome window at index \(override.index)"
                        )
                    )
                }

                let (updatedWindow, updateError) = applyChromeOverride(
                    to: window,
                    override: chromeOverride,
                    action: action,
                    index: override.index
                )
                if let updateError {
                    return (workspace, updateError)
                }
                window = updatedWindow
            }

            windows[override.index] = window
        }

        if didChangeOpenPath {
            windows = OpenByPathTitleAssigner.apply(to: windows)
        }

        return (workspace.withNewWindows(windows), nil)
    }

    private func applyChromeOverride(
        to window: WorkspaceWindow,
        override: ChromeOverride,
        action: String,
        index: Int
    ) -> (WorkspaceWindow, CommandResult?) {
        if let existing = window.chromeState {
            let shouldForceSpecific = override.profileDirectory != nil || override.profileDisplayName != nil
            let updated = ChromeWindowState(
                profileDirectory: override.profileDirectory ?? existing.profileDirectory,
                profileDisplayName: override.profileDisplayName ?? existing.profileDisplayName,
                profileHostedDomain: override.profileHostedDomain ?? existing.profileHostedDomain,
                profileMatchMode: shouldForceSpecific ? .specific : existing.profileMatchMode,
                shouldRestoreTabs: override.tabs != nil ? true : existing.shouldRestoreTabs,
                savedTabURLs: override.tabs ?? existing.savedTabURLs,
                focusedTabIndex: override.focusedTabIndex ?? existing.focusedTabIndex,
                chromeWindowId: existing.chromeWindowId
            )
            return (window.withChromeState(updated), nil)
        }

        guard let profileDirectory = override.profileDirectory,
              let profileDisplayName = override.profileDisplayName else {
            return (
                window,
                CommandResult.failure(
                    action: action,
                    exitCode: .invalidArguments,
                    error: "Chrome override for index \(index) requires profileDirectory and profileDisplayName when no existing chromeState is present"
                )
            )
        }

        let created = ChromeWindowState(
            profileDirectory: profileDirectory,
            profileDisplayName: profileDisplayName,
            profileHostedDomain: override.profileHostedDomain,
            profileMatchMode: .specific,
            shouldRestoreTabs: override.tabs != nil,
            savedTabURLs: override.tabs ?? [],
            focusedTabIndex: override.focusedTabIndex,
            chromeWindowId: nil
        )
        return (window.withChromeState(created), nil)
    }

    private func mergeWindowOverride(base: WindowOverride, incoming: WindowOverride) -> WindowOverride {
        let mergedChrome = mergeChromeOverride(base: base.chrome, incoming: incoming.chrome)
        return WindowOverride(
            index: base.index,
            openPath: incoming.openPath ?? base.openPath,
            chrome: mergedChrome ?? base.chrome
        )
    }

    private func mergeChromeOverride(base: ChromeOverride?, incoming: ChromeOverride?) -> ChromeOverride? {
        guard let incoming else { return base }
        guard let base else { return incoming }
        return ChromeOverride(
            profileDirectory: incoming.profileDirectory ?? base.profileDirectory,
            profileDisplayName: incoming.profileDisplayName ?? base.profileDisplayName,
            profileHostedDomain: incoming.profileHostedDomain ?? base.profileHostedDomain,
            tabs: incoming.tabs ?? base.tabs,
            focusedTabIndex: incoming.focusedTabIndex ?? base.focusedTabIndex
        )
    }

    private func executeWorkspaceImportFile(
        path: String,
        replaceExisting: Bool,
        executor: ActionExecutor
    ) -> CommandResult {
        let url = URL(fileURLWithPath: path).standardizedFileURL

        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            return .failure(
                action: "workspace-import-file",
                exitCode: .notFound,
                error: "Failed to read workspace file: \(url.path) (\(error.localizedDescription))"
            )
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = WorkspaceJSONDateCoding.decodingStrategy
        let workspace: Workspace
        do {
            workspace = try decoder.decode(Workspace.self, from: data)
        } catch {
            return .failure(
                action: "workspace-import-file",
                exitCode: .invalidArguments,
                error: "Failed to decode workspace JSON: \(error.localizedDescription)"
            )
        }

        let outcome = executor.workspaceManager.importWorkspace(
            workspace,
            replaceExisting: replaceExisting
        )

        switch outcome {
        case .added:
            return .success(
                action: "workspace-import-file",
                message: "Imported workspace '\(workspace.name)'"
            )
        case .replaced:
            return .success(
                action: "workspace-import-file",
                message: "Replaced workspace '\(workspace.name)'"
            )
        case .skipped(let reason):
            return .failure(
                action: "workspace-import-file",
                exitCode: .actionFailed,
                error: reason
            )
        }
    }

    private enum WorkspaceResolution {
        case success(Workspace)
        case failure(CommandResult)

        var failureResult: CommandResult {
            switch self {
            case .success:
                return .failure(action: "workspace-resolution", exitCode: .generalError, error: "Unknown workspace resolution error")
            case .failure(let result):
                return result
            }
        }
    }

    private func resolveWorkspace(
        named name: String,
        from workspaces: [Workspace],
        action: String
    ) -> WorkspaceResolution {
        let exactMatch = workspaces.first { $0.name.compare(name, options: [.caseInsensitive]) == .orderedSame }
        let partialMatches = workspaces.filter { $0.name.localizedCaseInsensitiveContains(name) }

        if let exact = exactMatch {
            return .success(exact)
        }
        if partialMatches.count == 1 {
            return .success(partialMatches[0])
        }
        if partialMatches.count > 1 {
            return .failure(CommandResult.failure(
                action: action,
                exitCode: .invalidArguments,
                error: "Multiple workspaces matched '\(name)'. Please be more specific."
            ))
        }
        return .failure(CommandResult.failure(
            action: action,
            exitCode: .notFound,
            error: "No workspace found matching '\(name)'"
        ))
    }

    private struct FluentRestoreOutput: Codable {
        let workspaceName: String
        let runId: String
        let success: Bool
        let restored: Int
        let failed: Int
        let skipped: Int
        let durationMs: Int
        // GH #579: additive keys — portability report + applied degradations.
        let portability: WorkspacePortabilityReport?
        let skippedForMissingApps: Int?
        let remappedWindows: Int?

        init(
            from result: FluentRestorationResult,
            workspace: Workspace,
            portability: WorkspacePortabilityReport? = nil,
            degradation: WorkspacePortabilityDegradation? = nil
        ) {
            self.workspaceName = workspace.name
            self.runId = result.runId
            self.success = result.success
            self.restored = result.windowsRestored
            self.failed = result.windowsFailed
            self.skipped = result.windowsSkipped
            self.durationMs = result.totalDurationMs
            self.portability = portability
            self.skippedForMissingApps = degradation.map { $0.skippedWindows.count }
            self.remappedWindows = degradation.map { $0.remappedWindowCount }
        }
    }

    /// Outcome of the GH #579 pre-restore portability pass.
    private struct PortabilityRestorePreparation {
        let report: WorkspacePortabilityReport
        let degradation: WorkspacePortabilityDegradation
        /// Non-nil when the degraded workspace has nothing left to restore.
        let failure: CommandResult?
    }

    private func currentEffectiveScreens(executor: ActionExecutor) -> [FullScreenInfo] {
        executor.displayManager.refreshScreens()
        return WorkspaceDisplayTopology.effectiveScreens(from: executor.displayManager)
    }

    /// Compact single-line summary of portability findings for result messages.
    private func portabilitySummary(for report: WorkspacePortabilityReport) -> String {
        var parts: [String] = []
        if !report.missingApps.isEmpty {
            let names = report.missingApps.map(\.appName).joined(separator: ", ")
            parts.append("\(report.missingApps.count) missing app(s) [\(names)]")
        }
        if !report.missingPaths.isEmpty {
            parts.append("\(report.missingPaths.count) missing folder(s)")
        }
        if report.displayRemap != nil {
            parts.append("saved on \(report.savedDisplayCount) display(s), \(report.currentDisplayCount) connected")
        }
        return parts.joined(separator: "; ")
    }

    /// Analyzes portability, emits warnings (text mode), and applies the
    /// deterministic degradations (skip missing-app windows, remap windows on
    /// unavailable display slots to the highest available display).
    private func analyzePortabilityForRestore(
        workspace: Workspace,
        action: String,
        executor: ActionExecutor
    ) -> PortabilityRestorePreparation {
        let currentScreens = currentEffectiveScreens(executor: executor)
        let analyzer = WorkspacePortabilityAnalyzer()
        let report = analyzer.analyze(workspace: workspace, currentDisplayCount: currentScreens.count)
        let degradation = analyzer.applyDegradations(
            to: workspace,
            currentScreens: currentScreens,
            report: report
        )

        if report.hasFindings {
            DeskJigLog.warn(.cli, "Workspace portability findings before restore", fields: [
                "workspace": workspace.name,
                "missingApps": "\(report.missingApps.count)",
                "missingPaths": "\(report.missingPaths.count)",
                "savedDisplayCount": "\(report.savedDisplayCount)",
                "currentDisplayCount": "\(report.currentDisplayCount)",
                "skippedWindows": "\(degradation.skippedWindows.count)",
                "remappedWindows": "\(degradation.remappedWindowCount)"
            ])
            if executor.shouldEmitTextOutput {
                print("Portability warnings for '\(workspace.name)':")
                for warning in report.warnings {
                    print("  ⚠️  \(warning)")
                }
            }
        }

        var failure: CommandResult?
        if degradation.workspace.windows.isEmpty {
            let missingAppNames = report.missingApps.map(\.appName).joined(separator: ", ")
            failure = .failure(
                action: action,
                exitCode: .actionFailed,
                error: "Cannot restore '\(workspace.name)': all \(workspace.windows.count) window(s) belong to apps " +
                    "that are not installed (\(missingAppNames))."
            )
        }

        return PortabilityRestorePreparation(report: report, degradation: degradation, failure: failure)
    }

    private func restoreFluentWorkspace(
        _ workspace: Workspace,
        hideAllApps: Bool = false,
        displayAssignments: [WorkspaceDisplayAssignment] = [],
        executor: ActionExecutor
    ) async -> FluentRestorationResult {
        DeskJigLog.info(.cli, "Fluent v2 restore started for '\(workspace.name)'")

        let outcome = await executor.workspaceManager.restoreWorkspace(
            workspace,
            hideAllApps: hideAllApps,
            displayAssignments: displayAssignments,
            onProgress: nil
        )
        return outcome.result
    }

    private func commandResult(
        for result: FluentRestorationResult,
        workspace: Workspace,
        action: String,
        portability: WorkspacePortabilityReport? = nil,
        degradation: WorkspacePortabilityDegradation? = nil
    ) -> CommandResult {
        let output = FluentRestoreOutput(
            from: result,
            workspace: workspace,
            portability: portability,
            degradation: degradation
        )

        var degradationSuffix = ""
        if let degradation, let portability, portability.hasFindings {
            var parts: [String] = []
            if !degradation.skippedWindows.isEmpty {
                parts.append("skipped \(degradation.skippedWindows.count) window(s) for missing apps")
            }
            if degradation.remappedWindowCount > 0 {
                parts.append("remapped \(degradation.remappedWindowCount) window(s) to available displays")
            }
            if !parts.isEmpty {
                degradationSuffix = " [portability: \(parts.joined(separator: "; "))]"
            }
        }

        if result.windowsFailed == 0 {
            return .success(
                action: action,
                message: "Fluent v2 restored '\(workspace.name)': \(result.windowsRestored) window(s) (runId: \(result.runId))\(degradationSuffix)",
                data: AnyCodableValue.from(output)
            )
        }

        if result.windowsRestored > 0 {
            return CommandResult(
                success: true,
                exitCode: .partialSuccess,
                action: action,
                message: "Fluent v2 partially restored '\(workspace.name)': \(result.windowsRestored)/\(result.windowsTotal) succeeded (runId: \(result.runId))\(degradationSuffix)",
                data: AnyCodableValue.from(output)
            )
        }

        return .failure(
            action: action,
            exitCode: .actionFailed,
            error: "Fluent v2 failed to restore '\(workspace.name)' (\(result.windowsFailed) failures)\(degradationSuffix)"
        )
    }

    private struct TestWorkspacePathsOutput: Codable {
        struct ScreenSummary: Codable {
            let index: Int
            let displayID: Int
            let name: String
            let isPrimary: Bool
        }

        let terminalApp: String
        let rootDir: String
        let workspaceAFile: String
        let workspaceBFile: String
        let directoryA: String
        let directoryB: String
        let targetScreenIndex: Int
        let screens: [ScreenSummary]
    }

    private func executeCreateTestWorkspaces(
        options: CreateTestWorkspacesOptions,
        executor: ActionExecutor
    ) -> CommandResult {
        let fileManager = FileManager.default

        executor.displayManager.refreshScreens()
        let screens = executor.displayManager.screens

        guard !screens.isEmpty else {
            return .failure(
                action: "create-test-workspaces",
                exitCode: .actionFailed,
                error: "No screens detected; cannot create workspace screen configuration."
            )
        }

        let targetScreenIndex = screens.firstIndex(where: { !$0.isPrimary }) ?? 0

        let token = String(UUID().uuidString.prefix(8))
        let rootDirName = "deskjig-cli-test-workspaces-\(token)"
        let rootURL = fileManager.temporaryDirectory.appendingPathComponent(rootDirName, isDirectory: true)
        let workspaceAURL = rootURL.appendingPathComponent("workspace-a.json", isDirectory: false)
        let workspaceBURL = rootURL.appendingPathComponent("workspace-b.json", isDirectory: false)

        do {
            try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)
        } catch {
            return .failure(
                action: "create-test-workspaces",
                exitCode: .actionFailed,
                error: "Failed to create workspace output directory: \(error.localizedDescription)"
            )
        }

        func resolveDirectory(overridePath: String?, defaultName: String) throws -> (URL, Bool) {
            if let overridePath {
                let expanded = (overridePath as NSString).expandingTildeInPath
                let url = URL(fileURLWithPath: expanded).standardizedFileURL
                var isDirectory: ObjCBool = false
                guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
                    throw ArgumentParserError.invalidValue(
                        argument: "path",
                        value: url.path,
                        expected: "an existing directory"
                    )
                }
                return (url, false)
            }

            let url = rootURL.appendingPathComponent(defaultName, isDirectory: true)
            try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
            return (url, true)
        }

        let dirAURL: URL
        let dirBURL: URL
        let createdA: Bool
        let createdB: Bool

        do {
            (dirAURL, createdA) = try resolveDirectory(
                overridePath: options.pathA,
                defaultName: "project-a-\(token)"
            )
            (dirBURL, createdB) = try resolveDirectory(
                overridePath: options.pathB,
                defaultName: "project-b-\(token)"
            )

            let marker = "Temporary test directory created by DeskJigCLI.\n"
            if createdA {
                try marker.write(
                    to: dirAURL.appendingPathComponent("DESKJIG_TEST_DIR.txt"),
                    atomically: true,
                    encoding: .utf8
                )
            }
            if createdB {
                try marker.write(
                    to: dirBURL.appendingPathComponent("DESKJIG_TEST_DIR.txt"),
                    atomically: true,
                    encoding: .utf8
                )
            }
        } catch {
            return .failure(
                action: "create-test-workspaces",
                exitCode: .actionFailed,
                error: "Failed to prepare test directories: \(error.localizedDescription)"
            )
        }

        let workspaceScreens = screens.map { WorkspaceScreen(from: $0) }

        let leftHalf = RelativeWindowFrame(xPercent: 0.0, yPercent: 0.0, widthPercent: 0.5, heightPercent: 1.0)
        let rightHalf = RelativeWindowFrame(xPercent: 0.5, yPercent: 0.0, widthPercent: 0.5, heightPercent: 1.0)

        func makeWorkspace(name: String, directory: URL) -> Workspace {
            let terminalWindow = WorkspaceWindow(
                bundleIdentifier: options.terminalApp.bundleID,
                appName: options.terminalApp.appName,
                windowTitle: options.terminalApp.appName,
                openPath: directory.path,
                applicationPath: nil,
                chromeState: nil,
                screenIndex: targetScreenIndex,
                relativeFrame: leftHalf
            )
            let cursor = WorkspaceWindow(
                bundleIdentifier: OpenByPathBundleIdentifiers.cursor,
                appName: "Cursor",
                windowTitle: directory.lastPathComponent,
                openPath: directory.path,
                applicationPath: nil,
                chromeState: nil,
                screenIndex: targetScreenIndex,
                relativeFrame: rightHalf
            )
            let windows = OpenByPathTitleAssigner.apply(to: [terminalWindow, cursor])
            return Workspace(
                name: name,
                icon: "🧪",
                keyboardShortcut: nil,
                workspaceWindows: windows,
                screens: workspaceScreens
            )
        }

        let workspaceA = makeWorkspace(name: "DeskJig CLI Test Workspace A", directory: dirAURL)
        let workspaceB = makeWorkspace(name: "DeskJig CLI Test Workspace B", directory: dirBURL)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = WorkspaceJSONDateCoding.encodingStrategy

        do {
            let aData = try encoder.encode(workspaceA)
            let bData = try encoder.encode(workspaceB)

            try aData.write(to: workspaceAURL, options: [.atomic])
            try bData.write(to: workspaceBURL, options: [.atomic])
        } catch {
            return .failure(
                action: "create-test-workspaces",
                exitCode: .actionFailed,
                error: "Failed to write workspace JSON: \(error.localizedDescription)"
            )
        }

        let output = TestWorkspacePathsOutput(
            terminalApp: options.terminalApp.appName,
            rootDir: rootURL.path,
            workspaceAFile: workspaceAURL.path,
            workspaceBFile: workspaceBURL.path,
            directoryA: dirAURL.path,
            directoryB: dirBURL.path,
            targetScreenIndex: targetScreenIndex,
            screens: screens.enumerated().map { idx, screen in
                TestWorkspacePathsOutput.ScreenSummary(
                    index: idx,
                    displayID: screen.displayID,
                    name: screen.name,
                    isPrimary: screen.isPrimary
                )
            }
        )

        if executor.shouldEmitTextOutput {
            let dirALabel = createdA ? "Dir" : "Dir (provided)"
            let dirBLabel = createdB ? "Dir" : "Dir (provided)"
            print("Created test workspaces in: \(rootURL.path)")
            print("Terminal app: \(options.terminalApp.appName)")
            print("")
            print("Workspace A:")
            print("  \(dirALabel):  \(dirAURL.path)")
            print("  JSON: \(workspaceAURL.path)")
            print("")
            print("Workspace B:")
            print("  \(dirBLabel):  \(dirBURL.path)")
            print("  JSON: \(workspaceBURL.path)")
            print("")
            print("Detected screens:")
            for screen in output.screens {
                print("  [\(screen.index)] \(screen.name) (displayID=\(screen.displayID))\(screen.isPrimary ? " (primary)" : "")")
            }
            print("")
            print("Next:")
            print("  deskjig workspace restore-file \(workspaceAURL.path)")
            print("  deskjig workspace restore-file \(workspaceBURL.path)")

            return .success(
                action: "create-test-workspaces",
                message: "Created 2 test workspaces (target screen index: \(targetScreenIndex))"
            )
        }

        return .success(
            action: "create-test-workspaces",
            message: nil,
            data: AnyCodableValue.from(output)
        )
    }

    private func executeCreateRichWorkspace(
        options: CreateRichWorkspaceOptions,
        executor: ActionExecutor
    ) -> CommandResult {
        executor.displayManager.refreshScreens()
        let screens = executor.displayManager.screens

        guard !screens.isEmpty else {
            return .failure(
                action: "create-rich-workspace",
                exitCode: .actionFailed,
                error: "No screens detected; cannot create workspace screen configuration."
            )
        }

        let screenRange = "0-\(screens.count - 1)"
        let screenTargets: [(String, Int)] = [
            ("Chrome", options.chromeScreenIndex),
            ("Terminal", options.terminalScreenIndex),
            ("VS Code", options.vscodeScreenIndex),
            ("kitty", options.kittyScreenIndex)
        ]

        for (label, index) in screenTargets {
            guard screens.indices.contains(index) else {
                return .failure(
                    action: "create-rich-workspace",
                    exitCode: .invalidArguments,
                    error: "\(label) screen index \(index) is out of range (\(screenRange))."
                )
            }
        }

        if options.terminalApp == .kitty || options.terminalApp == .alacritty {
            return .failure(
                action: "create-rich-workspace",
                exitCode: .invalidArguments,
                error: "terminal-app must be ghostty, terminal, or iterm when kitty-path is provided."
            )
        }

        func normalizeDirectory(_ path: String, label: String) -> (path: String?, failure: CommandResult?) {
            let expanded = (path as NSString).expandingTildeInPath
            let url = URL(fileURLWithPath: expanded).standardizedFileURL
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
                  isDirectory.boolValue else {
                return (nil, .failure(
                    action: "create-rich-workspace",
                    exitCode: .invalidArguments,
                    error: "\(label) directory not found: \(url.path)"
                ))
            }
            return (url.path, nil)
        }

        let terminalResult = normalizeDirectory(options.terminalPath, label: "Terminal")
        if let failure = terminalResult.failure { return failure }
        let vscodeResult = normalizeDirectory(options.vscodePath, label: "VS Code")
        if let failure = vscodeResult.failure { return failure }
        let kittyResult = normalizeDirectory(options.kittyPath, label: "kitty")
        if let failure = kittyResult.failure { return failure }

        guard let terminalPath = terminalResult.path,
              let vscodePath = vscodeResult.path,
              let kittyPath = kittyResult.path else {
            return .failure(
                action: "create-rich-workspace",
                exitCode: .invalidArguments,
                error: "Failed to resolve workspace paths."
            )
        }

        func relativeFrame(for position: WindowPosition) -> RelativeWindowFrame? {
            guard let shared = DeskJigShared.WindowPosition(rawValue: position.rawValue) else { return nil }
            return shared.toRelativeFrame()
        }

        guard let chromeFrame = relativeFrame(for: options.chromePosition),
              let terminalFrame = relativeFrame(for: options.terminalPosition),
              let vscodeFrame = relativeFrame(for: options.vscodePosition),
              let kittyFrame = relativeFrame(for: options.kittyPosition) else {
            return .failure(
                action: "create-rich-workspace",
                exitCode: .invalidArguments,
                error: "Invalid window position preset."
            )
        }

        let chromeUrls = options.chromeUrls
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        let chromeState = ChromeWindowState(
            profileDirectory: options.chromeProfileDirectory,
            profileDisplayName: options.chromeProfileName,
            profileHostedDomain: options.chromeHostedDomain,
            profileMatchMode: .specific,
            shouldRestoreTabs: !chromeUrls.isEmpty,
            savedTabURLs: chromeUrls,
            focusedTabIndex: chromeUrls.isEmpty ? nil : 0,
            chromeWindowId: nil
        )

        let chromeWindow = WorkspaceWindow(
            bundleIdentifier: "com.google.Chrome",
            appName: "Google Chrome",
            windowTitle: "Google Chrome",
            openPath: nil,
            applicationPath: nil,
            chromeState: chromeState,
            screenIndex: options.chromeScreenIndex,
            relativeFrame: chromeFrame
        )

        let terminalWindow = WorkspaceWindow(
            bundleIdentifier: options.terminalApp.bundleID,
            appName: options.terminalApp.appName,
            windowTitle: URL(fileURLWithPath: terminalPath).lastPathComponent,
            openPath: terminalPath,
            applicationPath: nil,
            chromeState: nil,
            screenIndex: options.terminalScreenIndex,
            relativeFrame: terminalFrame
        )

        let vscodeWindow = WorkspaceWindow(
            bundleIdentifier: OpenByPathBundleIdentifiers.vscode,
            appName: "VS Code",
            windowTitle: URL(fileURLWithPath: vscodePath).lastPathComponent,
            openPath: vscodePath,
            applicationPath: nil,
            chromeState: nil,
            screenIndex: options.vscodeScreenIndex,
            relativeFrame: vscodeFrame
        )

        let kittyWindow = WorkspaceWindow(
            bundleIdentifier: OpenByPathBundleIdentifiers.kitty,
            appName: "kitty",
            windowTitle: URL(fileURLWithPath: kittyPath).lastPathComponent,
            openPath: kittyPath,
            applicationPath: nil,
            chromeState: nil,
            screenIndex: options.kittyScreenIndex,
            relativeFrame: kittyFrame
        )

        let windows = OpenByPathTitleAssigner.apply(
            to: [chromeWindow, terminalWindow, vscodeWindow, kittyWindow]
        )

        let workspaceScreens = screens.map { WorkspaceScreen(from: $0) }
        let workspace = Workspace(
            name: options.name,
            icon: options.icon,
            keyboardShortcut: nil,
            workspaceWindows: windows,
            screens: workspaceScreens
        )

        let outcome = executor.workspaceManager.importWorkspace(
            workspace,
            replaceExisting: options.replaceExisting
        )

        switch outcome {
        case .added:
            return .success(
                action: "create-rich-workspace",
                message: "Created workspace '\(workspace.name)'"
            )
        case .replaced:
            return .success(
                action: "create-rich-workspace",
                message: "Replaced workspace '\(workspace.name)'"
            )
        case .skipped(let reason):
            return .failure(
                action: "create-rich-workspace",
                exitCode: .actionFailed,
                error: reason
            )
        }
    }

    private func executeDumpWindows(executor: ActionExecutor) -> CommandResult {
        let windows = executor.captureWindows()
        let zIndexMap = fetchZIndexMap()
        let onScreenMap = fetchOnScreenMap()
        let outputs = windows.map { window in
            WindowOutput(
                from: window,
                zIndex: zIndexMap[window.id],
                isOnScreen: onScreenMap[window.id]
            )
        }

        if executor.shouldEmitTextOutput {
            let output = OutputFormatter.formatWindowOutputs(outputs, format: executor.format)
            print(output)
        }

        return .success(
            action: "dump-windows",
            message: "Found \(windows.count) window(s)",
            data: AnyCodableValue.from(outputs)
        )
    }

    private func fetchZIndexMap() -> [Int: Int] {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let windowList = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return [:]
        }

        var zIndexMap: [Int: Int] = [:]
        var zIndex = 0
        for windowInfo in windowList {
            guard let windowLayer = windowInfo[kCGWindowLayer as String] as? Int,
                  windowLayer == 0 else { continue }
            if let windowID = windowInfo[kCGWindowNumber as String] as? Int {
                zIndexMap[windowID] = zIndex
                zIndex += 1
            }
        }

        return zIndexMap
    }

    private func fetchOnScreenMap() -> [Int: Bool] {
        let options: CGWindowListOption = [.optionAll, .excludeDesktopElements]
        guard let windowList = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return [:]
        }

        var onScreenMap: [Int: Bool] = [:]
        for windowInfo in windowList {
            guard let windowLayer = windowInfo[kCGWindowLayer as String] as? Int,
                  windowLayer == 0 else { continue }
            guard let windowID = windowInfo[kCGWindowNumber as String] as? Int else { continue }
            let isOnScreen = windowInfo[kCGWindowIsOnscreen as String] as? Bool ?? false
            onScreenMap[windowID] = isOnScreen
        }

        return onScreenMap
    }

    private func executeListDisplays(executor: ActionExecutor) -> CommandResult {
        executor.displayManager.refreshScreens()
        let screens = executor.displayManager.screens

        let output = screens.enumerated().map { (index, screen) in
            DisplayOutput(
                index: index,
                displayID: screen.displayID,
                name: screen.name,
                frame: FrameOutput(
                    x: screen.frame.origin.x,
                    y: screen.frame.origin.y,
                    width: screen.frame.size.width,
                    height: screen.frame.size.height
                ),
                visibleFrame: FrameOutput(
                    x: screen.visibleFrame.origin.x,
                    y: screen.visibleFrame.origin.y,
                    width: screen.visibleFrame.size.width,
                    height: screen.visibleFrame.size.height
                ),
                isPrimary: screen.isPrimary
            )
        }

        if executor.shouldEmitTextOutput {
            print("Detected \(output.count) display(s):")
            for display in output {
                print(
                    String(
                        format: "  %d. ID: %-4d Name: %@ Origin: (%.0f, %.0f) Size: %.0fx%.0f%@",
                        display.index,
                        display.displayID,
                        display.name,
                        display.frame.x,
                        display.frame.y,
                        display.frame.width,
                        display.frame.height,
                        display.isPrimary ? " (primary)" : ""
                    )
                )
            }
        }

        return .success(
            action: "list-displays",
            message: "Found \(output.count) display(s)",
            data: AnyCodableValue.from(output)
        )
    }

    private func executeDebugRestoreLoop(
        options: CLIAction.DebugRestoreLoopOptions,
        executor: ActionExecutor
    ) async -> CommandResult {
        let availableWorkspaces = executor.workspaceManager.savedWorkspaces
        var resolved: [Workspace] = []

        for name in options.workspaces {
            let resolvedResult = resolveWorkspace(named: name, from: availableWorkspaces)
            if let error = resolvedResult.error {
                return .failure(action: "debug-restore-loop", exitCode: .notFound, error: error)
            }
            if let workspace = resolvedResult.workspace {
                resolved.append(workspace)
            }
        }

        let runner = RestoreDebugLoopRunner(
            options: options,
            workspaces: resolved,
            executor: executor
        )
        let output = await runner.run()

        if executor.shouldEmitTextOutput {
            print("Restore debug loop complete.")
            print("Output dir: \(output.outputDir)")
            print("Iterations: \(output.iterations.count)")
        }

        return .success(
            action: "debug-restore-loop",
            message: "Saved artifacts to \(output.outputDir)",
            data: AnyCodableValue.from(output)
        )
    }

    private func resolveWorkspace(
        named name: String,
        from workspaces: [Workspace]
    ) -> (workspace: Workspace?, error: String?) {
        let exactMatch = workspaces.first { $0.name.compare(name, options: [.caseInsensitive]) == .orderedSame }
        let partialMatches = workspaces.filter { $0.name.localizedCaseInsensitiveContains(name) }

        if let exact = exactMatch {
            return (exact, nil)
        }

        if partialMatches.count == 1 {
            return (partialMatches[0], nil)
        }

        if partialMatches.count > 1 {
            return (nil, "Multiple workspaces matched '\(name)'. Please be more specific.")
        }

        return (nil, "No workspace found matching '\(name)'")
    }
}

private struct RestoreDebugLoopRunner {
    struct Output: Codable {
        struct Iteration: Codable {
            let index: Int
            let workspace: String
            let runId: String
            let killedApps: Bool
            let successCount: Int
            let failureCount: Int
            let failureMessages: [String]
            let artifacts: Artifacts
        }

        struct Artifacts: Codable {
            let runId: String?
            let displays: String?
            let ghosttyWindows: String?
            let cursorWindows: String?
            let ghosttyPids: String?
            let cursorPids: String?
            let zorderOutput: String?
            let zorderJson: String?
            let topmost: String?
            let screenshots: [String]
            let logs: String?
        }

        let outputDir: String
        let iterations: [Iteration]
    }

    /// Leading token of a managed terminal window title (`bento:<dir>:<idx>`).
    /// Lowercased to compare against `normalizeTitle` output; the value is frozen.
    private static let terminalTitlePrefix = "\(BundleIdentity.terminalTitleTokenPrefix):"

    private let options: CLIAction.DebugRestoreLoopOptions
    private let workspaces: [Workspace]
    private let executor: ActionExecutor
    private let fileManager = FileManager.default

    init(options: CLIAction.DebugRestoreLoopOptions, workspaces: [Workspace], executor: ActionExecutor) {
        self.options = options
        self.workspaces = workspaces
        self.executor = executor
    }

    func run() async -> Output {
        let outputDirURL = resolveOutputDir()
        let totalIterations = options.iterations * workspaces.count
        var captures: [Output.Iteration] = []

        // Resolve hideAllApps: explicit flag > UserDefaults preference
        let hideAllApps = options.hideAllApps ?? UserDefaults.standard.bool(forKey: "restoreHideAllApps")
        DeskJigLog.info(.cli, "debug-restore-loop: hideAllApps resolved to \(hideAllApps) (explicit: \(options.hideAllApps != nil), userDefault: \(UserDefaults.standard.bool(forKey: "restoreHideAllApps")))")

        for iteration in 0..<totalIterations {
            let workspace = workspaces[iteration % workspaces.count]
            let iterationIndex = iteration + 1

            let killed = maybeKillApps(iterationIndex: iterationIndex)

            let progressCallback: (String) -> Void = { message in
                DeskJigLog.info(.cli, message)
                if self.executor.shouldEmitTextOutput && self.executor.verbose {
                    print(message)
                }
            }

            let restoreOutcome = await executor.workspaceManager.restoreWorkspace(
                workspace,
                hideAllApps: hideAllApps,
                onProgress: progressCallback
            )

            if options.sleepSeconds > 0 {
                let sleepNanos = UInt64(options.sleepSeconds * 1_000_000_000)
                await Task.sleepUnlessCancelled(nanoseconds: sleepNanos)
            }

            let runId = restoreOutcome.result.runId
            let artifacts = await captureArtifacts(
                workspace: workspace,
                iterationIndex: iterationIndex,
                runId: runId,
                outputDir: outputDirURL
            )

            let failures = restoreOutcome.failures.map {
                "\($0.window.appName): \($0.message ?? "failed")"
            }
            let failureCount = restoreOutcome.result.windowsFailed + restoreOutcome.result.windowsSkipped

            captures.append(Output.Iteration(
                index: iterationIndex,
                workspace: workspace.name,
                runId: runId,
                killedApps: killed,
                successCount: restoreOutcome.result.windowsRestored,
                failureCount: failureCount,
                failureMessages: failures,
                artifacts: artifacts
            ))
        }

        return Output(
            outputDir: outputDirURL.path,
            iterations: captures
        )
    }

    private func resolveOutputDir() -> URL {
        let outputDir: URL
        if let provided = options.outputDir {
            let expanded = (provided as NSString).expandingTildeInPath
            outputDir = URL(fileURLWithPath: expanded)
        } else {
            let timestamp = Int(Date().timeIntervalSince1970)
            outputDir = URL(fileURLWithPath: "/tmp", isDirectory: true)
                .appendingPathComponent("deskjig-debug-loop-\(timestamp)", isDirectory: true)
        }

        if !fileManager.fileExists(atPath: outputDir.path) {
            do {
                try fileManager.createDirectory(at: outputDir, withIntermediateDirectories: true)
            } catch {
                // Every artifact write below would silently fail without this directory.
                DeskJigLog.warn(.cli, "debug-restore-loop: failed to create output directory \(outputDir.path): \(error.localizedDescription)")
            }
        }
        return outputDir
    }

    private func maybeKillApps(iterationIndex: Int) -> Bool {
        guard let killEvery = options.killEvery else { return false }
        guard iterationIndex % killEvery == 0 else { return false }

        killProcess(
            names: ["Ghostty", "ghostty"],
            appPaths: [
                "/Applications/Ghostty.app/Contents/MacOS/Ghostty",
                "/Applications/Ghostty.app/Contents/MacOS/ghostty"
            ]
        )
        killProcess(
            names: ["Cursor"],
            appPaths: [
                "/Applications/Cursor.app/Contents/MacOS/Cursor"
            ]
        )
        return true
    }

    private func captureArtifacts(
        workspace: Workspace,
        iterationIndex: Int,
        runId: String,
        outputDir: URL
    ) async -> Output.Artifacts {
        let runIdPath = outputDir.appendingPathComponent("run-id-\(iterationIndex).txt")
        let displaysPath = outputDir.appendingPathComponent("displays-\(iterationIndex).json")
        let ghosttyPath = outputDir.appendingPathComponent("ghostty-\(iterationIndex).json")
        let cursorPath = outputDir.appendingPathComponent("cursor-\(iterationIndex).json")
        let ghosttyPidsPath = outputDir.appendingPathComponent("ghostty-pids-\(iterationIndex).txt")
        let cursorPidsPath = outputDir.appendingPathComponent("cursor-pids-\(iterationIndex).txt")
        let zorderOutputPath = outputDir.appendingPathComponent("zorder-\(iterationIndex).txt")
        let topmostPath = outputDir.appendingPathComponent("topmost-\(iterationIndex).txt")
        let logsPath = outputDir.appendingPathComponent("logs-\(iterationIndex).txt")

        writeString("\(runId)\n", to: runIdPath)
        writeDisplayData(to: displaysPath)
        await writeActionData(.windowsList(app: "ghostty", axInfo: true, allAxAttributes: false), to: ghosttyPath)
        await writeActionData(.windowsList(app: "cursor", axInfo: true, allAxAttributes: false), to: cursorPath)

        writeCommandOutput(
            runCommand(launchPath: "/usr/bin/pgrep", arguments: ["-x", "Ghostty"]),
            to: ghosttyPidsPath
        )
        writeCommandOutput(
            runCommand(launchPath: "/usr/bin/pgrep", arguments: ["-x", "Cursor"]),
            to: cursorPidsPath
        )

        let zorderResult = runSwiftScript(
            named: "window-zorder.swift",
            arguments: ["--save", "--apps-only", "--ax-doc"]
        )
        writeCommandOutput(zorderResult, to: zorderOutputPath)
        let zorderJson = extractSavedPath(from: zorderResult.stdout)

        let topmostResult = runSwiftScript(named: "topmost-window.swift", arguments: [])
        writeCommandOutput(topmostResult, to: topmostPath)

        let screenshotSaved = captureScreenshots(iterationIndex: iterationIndex, outputDir: outputDir)

        let logsSaved = captureAppLogs(
            runId: runId,
            lines: options.logLines,
            query: options.logQuery,
            to: logsPath
        )

        let artifacts = Output.Artifacts(
            runId: fileExists(runIdPath),
            displays: fileExists(displaysPath),
            ghosttyWindows: fileExists(ghosttyPath),
            cursorWindows: fileExists(cursorPath),
            ghosttyPids: fileExists(ghosttyPidsPath),
            cursorPids: fileExists(cursorPidsPath),
            zorderOutput: fileExists(zorderOutputPath),
            zorderJson: zorderJson,
            topmost: fileExists(topmostPath),
            screenshots: screenshotSaved,
            logs: logsSaved
        )

        appendReport(
            workspace: workspace,
            iterationIndex: iterationIndex,
            runId: runId,
            killedApps: options.killEvery.map { iterationIndex % $0 == 0 } ?? false,
            outputDir: outputDir,
            artifacts: artifacts
        )

        return artifacts
    }

    private func writeActionData(_ action: CLIAction, to path: URL) async {
        let result = await executor.executeSingle(action)
        guard let data = result.data else {
            writeString("No data for action: \(action.description)", to: path)
            return
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            let jsonData = try encoder.encode(data)
            try jsonData.write(to: path)
        } catch {
            writeString("Failed to encode data: \(error.localizedDescription)", to: path)
        }
    }

    private func captureScreenshots(iterationIndex: Int, outputDir: URL) -> [String] {
        guard options.captureScreenshots else { return [] }
        executor.displayManager.refreshScreens()
        let screens = executor.displayManager.screens

        if screens.isEmpty {
            let fallbackPath = outputDir.appendingPathComponent("screen-\(iterationIndex).png")
            if captureScreenshot(displayID: nil, to: fallbackPath, allowFallback: true) {
                return [fallbackPath.path]
            }
            return []
        }

        var indices: [Int] = []
        if options.captureAllDisplays {
            indices = Array(screens.indices)
        } else if let index = options.screenshotDisplayIndex, index >= 0, index < screens.count {
            indices = [index]
        }
        if indices.isEmpty {
            indices = [0]
        }

        var results: [String] = []
        for index in indices {
            let displayID = screens[index].displayID
            let path = outputDir.appendingPathComponent("screen-\(iterationIndex)-display-\(index).png")
            let allowFallback = !options.captureAllDisplays
            if captureScreenshot(displayID: displayID, to: path, allowFallback: allowFallback) {
                results.append(path.path)
            }
        }
        return results
    }

    private func captureScreenshot(displayID: Int?, to path: URL, allowFallback: Bool) -> Bool {
        let arguments: [String]
        if let displayID,
           let captureIndex = screencaptureIndex(for: displayID) {
            arguments = ["-x", "-D", "\(captureIndex)", path.path]
        } else {
            guard allowFallback else { return false }
            arguments = ["-x", path.path]
        }
        let primaryAttempt = runCommand(
            launchPath: "/usr/sbin/screencapture",
            arguments: arguments
        )
        if primaryAttempt.exitCode == 0 {
            return true
        }
        guard allowFallback else { return false }
        let fallback = runCommand(launchPath: "/usr/sbin/screencapture", arguments: ["-x", path.path])
        return fallback.exitCode == 0
    }

    private func screencaptureIndex(for displayID: Int) -> Int? {
        let maxDisplays: UInt32 = 16
        var displayIDs = [CGDirectDisplayID](repeating: 0, count: Int(maxDisplays))
        var displayCount: UInt32 = 0

        let result = CGGetActiveDisplayList(maxDisplays, &displayIDs, &displayCount)
        guard result == .success else { return nil }

        let activeDisplays = displayIDs.prefix(Int(displayCount))
        guard let index = activeDisplays.firstIndex(of: CGDirectDisplayID(displayID)) else { return nil }
        return index + 1
    }

    private func captureAppLogs(
        runId: String,
        lines: Int,
        query: String?,
        to path: URL
    ) -> String? {
        guard lines > 0 else { return nil }

        // Legacy path ~/Library/Logs/Bento — frozen, shared with the app.
        let logsDir = BundleIdentity.logDirectoryURL
        guard let latestLog = latestLogFile(in: logsDir) else { return nil }

        let content: String
        do {
            content = try String(contentsOf: latestLog, encoding: .utf8)
        } catch {
            // An unreadable log must not be reported as "no matching log lines".
            DeskJigLog.warn(.cli, "captureAppLogs: failed to read \(latestLog.path): \(error.localizedDescription)")
            writeString("Failed to read log file \(latestLog.path): \(error.localizedDescription)\n", to: path)
            return path.path
        }
        let filtered = content
            .split(separator: "\n")
            .filter { line in
                let value = String(line)
                // Always anchor to the restore run id, even when a secondary query is provided.
                guard value.localizedCaseInsensitiveContains(runId) else { return false }
                if let query {
                    return value.localizedCaseInsensitiveContains(query)
                }
                return true
            }
            .suffix(lines)
            .joined(separator: "\n")

        let output = filtered.isEmpty ? "No matching log lines for runId '\(runId)' (query='\(query ?? "")').\n" : "\(filtered)\n"
        writeString(output, to: path)
        return path.path
    }

    private func latestLogFile(in directory: URL) -> URL? {
        let entries: [URL]
        do {
            entries = try fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles]
            )
        } catch {
            DeskJigLog.warn(.cli, "latestLogFile: failed to list \(directory.path): \(error.localizedDescription)")
            return nil
        }

        let logFiles = entries.filter { $0.pathExtension == "log" }
        return logFiles.max { lhs, rhs in
            let lhsDate = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let rhsDate = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return lhsDate < rhsDate
        }
    }

    private func extractSavedPath(from output: String) -> String? {
        let lines = output.split(separator: "\n")
        for line in lines {
            if line.hasPrefix("Saved output to: ") {
                return String(line.dropFirst("Saved output to: ".count))
            }
        }
        return nil
    }

    private func writeDisplayData(to path: URL) {
        executor.displayManager.refreshScreens()
        let screens = executor.displayManager.screens

        let output = screens.enumerated().map { (index, screen) in
            DisplayOutput(
                index: index,
                displayID: screen.displayID,
                name: screen.name,
                frame: FrameOutput(
                    x: screen.frame.origin.x,
                    y: screen.frame.origin.y,
                    width: screen.frame.size.width,
                    height: screen.frame.size.height
                ),
                visibleFrame: FrameOutput(
                    x: screen.visibleFrame.origin.x,
                    y: screen.visibleFrame.origin.y,
                    width: screen.visibleFrame.size.width,
                    height: screen.visibleFrame.size.height
                ),
                isPrimary: screen.isPrimary
            )
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            let jsonData = try encoder.encode(output)
            try jsonData.write(to: path)
        } catch {
            writeString("Failed to encode displays: \(error.localizedDescription)", to: path)
        }
    }

    private func fileExists(_ url: URL) -> String? {
        fileManager.fileExists(atPath: url.path) ? url.path : nil
    }

    private func runCommand(
        launchPath: String,
        arguments: [String],
        currentDirectory: URL? = nil
    ) -> (exitCode: Int32, stdout: String, stderr: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments
        if let currentDirectory {
            process.currentDirectoryURL = currentDirectory
        }

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do {
            try process.run()
        } catch {
            return (exitCode: 1, stdout: "", stderr: error.localizedDescription)
        }

        process.waitUntilExit()

        let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()

        let stdoutString = String(data: stdoutData, encoding: .utf8) ?? ""
        let stderrString = String(data: stderrData, encoding: .utf8) ?? ""

        return (exitCode: process.terminationStatus, stdout: stdoutString, stderr: stderrString)
    }

    private func runSwiftScript(
        named fileName: String,
        arguments: [String]
    ) -> (exitCode: Int32, stdout: String, stderr: String) {
        if let resolved = RepositoryScriptLocator.resolveScript(named: fileName) {
            return runCommand(
                launchPath: "/usr/bin/swift",
                arguments: [resolved.scriptURL.path] + arguments,
                currentDirectory: resolved.repositoryRoot
            )
        }

        return runCommand(
            launchPath: "/usr/bin/swift",
            arguments: ["scripts/\(fileName)"] + arguments,
            currentDirectory: URL(fileURLWithPath: fileManager.currentDirectoryPath)
        )
    }

    private func writeCommandOutput(
        _ result: (exitCode: Int32, stdout: String, stderr: String),
        to path: URL
    ) {
        var output = result.stdout
        if !result.stderr.isEmpty {
            output += "\n" + result.stderr
        }
        writeString(output, to: path)
    }

    private func writeString(_ content: String, to path: URL) {
        do {
            try content.write(to: path, atomically: true, encoding: .utf8)
        } catch {
            // Best-effort writes only.
        }
    }

    private func killProcess(names: [String], appPaths: [String]) {
        let before = listPids(names: names, appPaths: appPaths)
        if !before.isEmpty {
            for pid in before {
                _ = runCommand(launchPath: "/bin/kill", arguments: ["-TERM", pid])
            }
            Thread.sleep(forTimeInterval: 0.2)
        }

        let after = listPids(names: names, appPaths: appPaths)
        if !after.isEmpty {
            for pid in after {
                _ = runCommand(launchPath: "/bin/kill", arguments: ["-9", pid])
            }
            Thread.sleep(forTimeInterval: 0.2)
        }

        let final = listPids(names: names, appPaths: appPaths)
        let label = names.joined(separator: "|")
        let summary = "Debug restore loop: kill \(label) before=\(before.count) after=\(final.count)"
        DeskJigLog.info(.cli, summary)
        if executor.shouldEmitTextOutput && executor.verbose {
            print(summary)
        }
    }

    private func listPids(names: [String], appPaths: [String]) -> [String] {
        var pids = Set<String>()
        for name in names {
            let byName = runCommand(launchPath: "/usr/bin/pgrep", arguments: ["-x", name])
            pids.formUnion(parsePids(from: byName.stdout))
        }
        for path in appPaths {
            let byPath = runCommand(launchPath: "/usr/bin/pgrep", arguments: ["-f", path])
            pids.formUnion(parsePids(from: byPath.stdout))
        }
        return pids.sorted()
    }

    private func parsePids(from output: String) -> [String] {
        output
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private struct WindowSummary {
        let title: String
        let frame: CGRect?
        let documentPath: String?
    }

    private struct ExpectedWindowCheck {
        let window: WorkspaceWindow
        let openPath: String
        let expectedFrame: CGRect?
    }

    private struct DisplaySnapshot {
        let index: Int
        let frame: CGRect
        let visibleFrame: CGRect
        let visibleFrameInWindowCoords: CGRect
    }

    private struct WindowMatch {
        let summary: WindowSummary
        let score: Double
        let reason: String
    }

    private func appendReport(
        workspace: Workspace,
        iterationIndex: Int,
        runId: String,
        killedApps: Bool,
        outputDir: URL,
        artifacts: Output.Artifacts
    ) {
        let reportPath = outputDir.appendingPathComponent("restore-report.txt")
        let timestamp = ISO8601DateFormatter().string(from: Date())

        let ghosttyWindows = readWindowSummaries(from: artifacts.ghosttyWindows)
        let cursorWindows = readWindowSummaries(from: artifacts.cursorWindows)
        let topmost = readTopmostSummary(from: artifacts.topmost)
        let zorderHead = readZOrderHead(from: artifacts.zorderJson)
        let ghosttyBundle = "com.mitchellh.ghostty"
        let cursorBundle = "com.todesktop.230313mzl4w4u92"
        let workspaceScreens = workspace.screens ?? []
        let displaySnapshots = readDisplaySnapshots(from: artifacts.displays)
        let normalizedExpected = expectedWindows(
            in: workspace,
            screens: workspaceScreens,
            displaySnapshots: displaySnapshots,
            bundleIds: [ghosttyBundle, cursorBundle]
        )

        var expectedByBundle: [String: Int] = [:]
        for window in workspace.windows {
            let bundle = window.bundleIdentifier
            expectedByBundle[bundle, default: 0] += 1
        }

        var lines: [String] = []
        lines.append("=== \(timestamp) iteration=\(iterationIndex) workspace=\(workspace.name) runId=\(runId) killed=\(killedApps) ===")
        lines.append("expected: \(expectedByBundle.map { "\($0.key)=\($0.value)" }.sorted().joined(separator: ", "))")
        lines.append("observed: ghostty=\(ghosttyWindows.count) cursor=\(cursorWindows.count)")

        if !ghosttyWindows.isEmpty {
            lines.append("ghostty:")
            for window in ghosttyWindows {
                lines.append("  - \(window.title) frame=\(formatFrame(window.frame)) doc=\(window.documentPath ?? "nil")")
            }
        }
        if !cursorWindows.isEmpty {
            lines.append("cursor:")
            for window in cursorWindows {
                lines.append("  - \(window.title) frame=\(formatFrame(window.frame)) doc=\(window.documentPath ?? "nil")")
            }
        }

        if let topmost {
            lines.append("topmost: app=\(topmost.app) title=\(topmost.title)")
        }
        if !zorderHead.isEmpty {
            lines.append("zorder-top: \(zorderHead.joined(separator: " | "))")
        }

        if !normalizedExpected.isEmpty {
            lines.append("verify:")
        }

        for (bundleId, checks) in normalizedExpected.sorted(by: { $0.key < $1.key }) {
            var usedIndices = Set<Int>()
            let observed = bundleId == ghosttyBundle ? ghosttyWindows : cursorWindows
            for check in checks {
                if let match = matchWindow(expected: check, observed: observed, usedIndices: &usedIndices) {
                    let title = match.summary.title.isEmpty ? "Untitled" : match.summary.title
                    let docPath = match.summary.documentPath ?? "nil"
                    lines.append("  ✓ \(check.window.appName) openPath=\(check.openPath) title=\(check.window.windowTitle) -> \(title) frame=\(formatFrame(match.summary.frame)) doc=\(docPath) match=\(match.reason)")

                    let observedPath = match.summary.documentPath.map(normalizePath)
                    let hasOpenPathAnchor = match.reason.contains("docPath") || match.reason.contains("openPath-token")
                    let isGhosttyTmuxFallback = check.window.bundleIdentifier == ghosttyBundle &&
                        (match.reason.contains("ghostty-frame-fallback") || match.reason.contains("ghostty-single-window"))
                    let allowTitleMismatch = hasOpenPathAnchor || observedPath == check.openPath || isGhosttyTmuxFallback
                    let expectedTitle = normalizeTitle(check.window.windowTitle)
                    if expectedTitle.hasPrefix(Self.terminalTitlePrefix) {
                        let observedTitle = normalizeTitle(match.summary.title)
                        let token = pathToken(check.openPath)
                        if !allowTitleMismatch &&
                            (!observedTitle.hasPrefix(Self.terminalTitlePrefix) || (token.isEmpty == false && !observedTitle.contains(token))) {
                            lines.append("issue: \(check.window.appName) title pattern mismatch expectedPrefix=\(Self.terminalTitlePrefix) token=\(token) observed=\(match.summary.title)")
                        }
                    } else if !allowTitleMismatch && !expectedTitle.isEmpty && expectedTitle != "untitled" {
                        let observedTitle = normalizeTitle(match.summary.title)
                        if !observedTitle.contains(expectedTitle) {
                            lines.append("issue: \(check.window.appName) title mismatch expected=\(check.window.windowTitle) observed=\(match.summary.title)")
                        }
                    }

                    if let expectedFrame = check.expectedFrame,
                       !framesMatch(expectedFrame, match.summary.frame, tolerance: 20) {
                        lines.append("issue: \(check.window.appName) frame mismatch expected=\(formatFrame(expectedFrame)) observed=\(formatFrame(match.summary.frame))")
                    }

                    if let observedPath = match.summary.documentPath {
                        let normalizedObserved = normalizePath(observedPath)
                        if normalizedObserved != check.openPath {
                            lines.append("issue: \(check.window.appName) openPath mismatch expected=\(check.openPath) observed=\(normalizedObserved)")
                        }
                    } else {
                        let token = pathToken(check.openPath)
                        if !token.isEmpty &&
                            !normalizeTitle(match.summary.title).contains(token) &&
                            !isGhosttyTmuxFallback {
                            lines.append("issue: \(check.window.appName) openPath token missing title=\(match.summary.title) token=\(token)")
                        }
                    }
                } else {
                    lines.append("  ✗ \(check.window.appName) openPath=\(check.openPath) title=\(check.window.windowTitle) missing")
                    lines.append("issue: missing \(check.window.appName) window for openPath=\(check.openPath)")
                }
            }
        }

        lines.append("")
        let output = lines.joined(separator: "\n")
        // best-effort append: the report file doesn't exist on the first iteration
        if let existing = try? String(contentsOf: reportPath, encoding: .utf8) {
            writeString(existing + output, to: reportPath)
        } else {
            writeString(output, to: reportPath)
        }
    }

    private func readWindowSummaries(from path: String?) -> [WindowSummary] {
        guard let path else { return [] }
        // An unreadable/undecodable artifact would make verification report every
        // expected window as missing — log why the observed list is empty.
        let data: Data
        do {
            data = try Data(contentsOf: URL(fileURLWithPath: path))
        } catch {
            DeskJigLog.warn(.cli, "readWindowSummaries: failed to read \(path): \(error.localizedDescription)")
            return []
        }

        struct WindowList: Decodable {
            struct Frame: Decodable {
                let x: Double
                let y: Double
                let width: Double
                let height: Double
            }
            struct AXInfo: Decodable {
                let documentPath: String?
            }
            struct Window: Decodable {
                let title: String
                let frame: Frame?
                let ax: AXInfo?
            }
            let windows: [Window]
        }

        let decoded: WindowList
        do {
            decoded = try JSONDecoder().decode(WindowList.self, from: data)
        } catch {
            DeskJigLog.warn(.cli, "readWindowSummaries: failed to decode \(path): \(error.localizedDescription)")
            return []
        }
        return decoded.windows.map { window in
            let frame = window.frame.map { CGRect(x: $0.x, y: $0.y, width: $0.width, height: $0.height) }
            return WindowSummary(title: window.title, frame: frame, documentPath: window.ax?.documentPath)
        }
    }

    private func expectedWindows(
        in workspace: Workspace,
        screens: [WorkspaceScreen],
        displaySnapshots: [DisplaySnapshot],
        bundleIds: [String]
    ) -> [String: [ExpectedWindowCheck]] {
        var results: [String: [ExpectedWindowCheck]] = [:]
        for window in workspace.windows {
            guard bundleIds.contains(window.bundleIdentifier),
                  let openPath = window.openPath?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !openPath.isEmpty else { continue }
            let expectedFrame = expectedFrame(for: window, screens: screens, displaySnapshots: displaySnapshots)
            let normalizedOpenPath = normalizePath(openPath)
            let check = ExpectedWindowCheck(window: window, openPath: normalizedOpenPath, expectedFrame: expectedFrame)
            results[window.bundleIdentifier, default: []].append(check)
        }
        return results
    }

    private func expectedFrame(
        for window: WorkspaceWindow,
        screens: [WorkspaceScreen],
        displaySnapshots: [DisplaySnapshot]
    ) -> CGRect? {
        guard let relativeFrame = window.relativeFrame,
              let screenIndex = window.screenIndex,
              screenIndex >= 0,
              (screenIndex < screens.count || screenIndex < displaySnapshots.count) else {
            return nil
        }
        if screenIndex < displaySnapshots.count {
            return WindowFrameConverter.toAbsolute(
                relativeFrame: relativeFrame,
                screenFrame: displaySnapshots[screenIndex].visibleFrameInWindowCoords
            )
        }
        return WindowFrameConverter.toAbsolute(
            relativeFrame: relativeFrame,
            screen: screens[screenIndex],
            allScreens: screens
        )
    }

    private func matchWindow(
        expected: ExpectedWindowCheck,
        observed: [WindowSummary],
        usedIndices: inout Set<Int>
    ) -> WindowMatch? {
        let ghosttyBundle = "com.mitchellh.ghostty"
        let isGhostty = expected.window.bundleIdentifier == ghosttyBundle
        let expectedTitle = normalizeTitle(expected.window.windowTitle)
        let expectedToken = pathToken(expected.openPath)
        let normalizedPath = expected.openPath
        var best: WindowMatch?
        var bestIndex: Int?

        for (index, summary) in observed.enumerated() {
            if usedIndices.contains(index) { continue }
            let summaryTitle = normalizeTitle(summary.title)
            let summaryPath = summary.documentPath.map(normalizePath)
            var score = 0.0
            var reasons: [String] = []

            if let summaryPath, summaryPath == normalizedPath {
                score += 220
                reasons.append("docPath")
            }

            if !expectedTitle.isEmpty {
                if summaryTitle == expectedTitle {
                    score += 200
                    reasons.append("title-exact")
                } else if summaryTitle.contains(expectedTitle) || expectedTitle.contains(summaryTitle) {
                    score += 140
                    reasons.append("title-contains")
                }
            }

            if !expectedToken.isEmpty && summaryTitle.contains(expectedToken) {
                score += 160
                reasons.append("openPath-token")
            }

            if let expectedFrame = expected.expectedFrame,
               let observedFrame = summary.frame {
                let dist =
                    abs(expectedFrame.origin.x - observedFrame.origin.x) +
                    abs(expectedFrame.origin.y - observedFrame.origin.y) +
                    abs(expectedFrame.width - observedFrame.width) +
                    abs(expectedFrame.height - observedFrame.height)
                let frameScore = max(0.0, 120.0 - Double(dist) / 10.0)
                if frameScore > 0 {
                    score += frameScore
                    reasons.append("frame")
                }
            }

            var hasAnchor = reasons.contains(where: { $0 == "docPath" || $0 == "openPath-token" || $0.hasPrefix("title-") })

            // tmux-switched Ghostty windows may have neutral titles and no AX doc path.
            // In that mode, accept a strong frame match (or single observed window fallback).
            if !hasAnchor && isGhostty {
                if let expectedFrame = expected.expectedFrame,
                   let observedFrame = summary.frame,
                   framesMatch(expectedFrame, observedFrame, tolerance: 20) {
                    score += 80
                    reasons.append("ghostty-frame-fallback")
                    hasAnchor = true
                } else if expected.expectedFrame == nil && observed.count == 1 {
                    score += 40
                    reasons.append("ghostty-single-window")
                    hasAnchor = true
                }
            }

            if !hasAnchor { continue }
            if best == nil || score > (best?.score ?? -1) {
                best = WindowMatch(summary: summary, score: score, reason: reasons.joined(separator: "+"))
                bestIndex = index
            }
        }

        if let bestIndex {
            usedIndices.insert(bestIndex)
        }
        return best
    }

    private func readDisplaySnapshots(from path: String?) -> [DisplaySnapshot] {
        guard let path else { return [] }
        let data: Data
        do {
            data = try Data(contentsOf: URL(fileURLWithPath: path))
        } catch {
            DeskJigLog.warn(.cli, "readDisplaySnapshots: failed to read \(path): \(error.localizedDescription)")
            return []
        }

        struct DisplaySnapshotFrameInput: Decodable {
            let x: Double
            let y: Double
            let width: Double
            let height: Double
        }

        struct DisplaySnapshotInput: Decodable {
            let index: Int
            let frame: DisplaySnapshotFrameInput
            let visibleFrame: DisplaySnapshotFrameInput
        }

        let decoded: [DisplaySnapshotInput]
        do {
            decoded = try JSONDecoder().decode([DisplaySnapshotInput].self, from: data)
        } catch {
            DeskJigLog.warn(.cli, "readDisplaySnapshots: failed to decode \(path): \(error.localizedDescription)")
            return []
        }
        let sorted = decoded.sorted { $0.index < $1.index }
        let globalMaxY = sorted.first.map { $0.frame.y + $0.frame.height } ?? 0
        return sorted.map { entry in
            let frame = CGRect(x: entry.frame.x, y: entry.frame.y, width: entry.frame.width, height: entry.frame.height)
            let visibleFrame = CGRect(
                x: entry.visibleFrame.x,
                y: entry.visibleFrame.y,
                width: entry.visibleFrame.width,
                height: entry.visibleFrame.height
            )
            let visibleFrameInWindowCoords = CGRect(
                x: visibleFrame.origin.x,
                y: globalMaxY - visibleFrame.maxY,
                width: visibleFrame.width,
                height: visibleFrame.height
            )
            return DisplaySnapshot(
                index: entry.index,
                frame: frame,
                visibleFrame: visibleFrame,
                visibleFrameInWindowCoords: visibleFrameInWindowCoords
            )
        }
    }

    private func framesMatch(_ expected: CGRect, _ observed: CGRect?, tolerance: CGFloat) -> Bool {
        guard let observed else { return false }
        return abs(expected.origin.x - observed.origin.x) <= tolerance &&
            abs(expected.origin.y - observed.origin.y) <= tolerance &&
            abs(expected.width - observed.width) <= tolerance &&
            abs(expected.height - observed.height) <= tolerance
    }

    private func normalizePath(_ raw: String) -> String {
        let expanded = (raw as NSString).expandingTildeInPath
        return URL(fileURLWithPath: expanded).standardizedFileURL.path
    }

    private func normalizeTitle(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private func pathToken(_ path: String) -> String {
        URL(fileURLWithPath: path).lastPathComponent.lowercased()
    }

    private func readTopmostSummary(from path: String?) -> (app: String, title: String)? {
        guard let path else { return nil }
        let content: String
        do {
            content = try String(contentsOfFile: path, encoding: .utf8)
        } catch {
            DeskJigLog.warn(.cli, "readTopmostSummary: failed to read \(path): \(error.localizedDescription)")
            return nil
        }
        var app: String?
        var title: String?
        for line in content.split(separator: "\n") {
            if line.hasPrefix("Frontmost app:") {
                app = line.replacingOccurrences(of: "Frontmost app:", with: "").trimmingCharacters(in: .whitespaces)
            } else if line.trimmingCharacters(in: .whitespaces).hasPrefix("title:") {
                title = line.replacingOccurrences(of: "title:", with: "").trimmingCharacters(in: .whitespaces)
            }
        }
        if let app, let title {
            return (app: app, title: title.trimmingCharacters(in: CharacterSet(charactersIn: "\"")))
        }
        return nil
    }

    private func readZOrderHead(from path: String?) -> [String] {
        guard let path else { return [] }
        let data: Data
        do {
            data = try Data(contentsOf: URL(fileURLWithPath: path))
        } catch {
            DeskJigLog.warn(.cli, "readZOrderHead: failed to read \(path): \(error.localizedDescription)")
            return []
        }
        let json: [String: Any]?
        do {
            json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        } catch {
            DeskJigLog.warn(.cli, "readZOrderHead: failed to parse \(path): \(error.localizedDescription)")
            return []
        }
        guard let entries = json?["entries"] as? [[String: Any]] else {
            return []
        }
        var results: [String] = []
        for entry in entries.prefix(5) {
            let title = (entry["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "(untitled)"
            let owner = (entry["owner"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let zIndex = entry["zIndex"] as? Int
            var parts: [String] = []
            if let zIndex { parts.append("#\(zIndex)") }
            if let owner, !owner.isEmpty { parts.append(owner) }
            parts.append(title)
            results.append(parts.joined(separator: " "))
        }
        return results
    }

    private func formatFrame(_ frame: CGRect?) -> String {
        guard let frame else { return "nil" }
        return "(\(Int(frame.origin.x)), \(Int(frame.origin.y))) \(Int(frame.width))x\(Int(frame.height))"
    }
}
