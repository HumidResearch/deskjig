//
//  WorkspaceRestorationController.swift
//  DeskJig
//
//  Coordinates Snapshot Viewer workspace restoration logic outside the view layer.
//

import AppKit
import Foundation
import DeskJigShared

final class WorkspaceRestorationController {
    private let strategyManager: LaunchStrategyManager
    private let lockManager: WindowLockManager
    private let chromeMatcher = ChromeWindowMatcher()
    private let positioningService: WindowPositioningService
    private let openByPathRestorationService: OpenByPathRestorationService
    private let genericRestorationService: GenericWindowRestorationService

    init(strategyManager: LaunchStrategyManager, lockManager: WindowLockManager) {
        self.strategyManager = strategyManager
        self.lockManager = lockManager
        let positioningService = WindowPositioningService(lockManager: lockManager)
        self.positioningService = positioningService
        self.openByPathRestorationService = OpenByPathRestorationService(positioningService: positioningService)
        self.genericRestorationService = GenericWindowRestorationService(positioningService: positioningService)
    }

    func launchWorkspace(_ workspace: WorkspaceHandle, source: String) {
        strategyManager.startLaunch()

        Task { @MainActor in
            if strategyManager.isDryRun {
                await simulateDryRun(workspace: workspace)
                strategyManager.endLaunch(success: true, windowCount: workspace.windowCount)
                return
            }

            // Real launch using direct Fluent API calls (not legacy workspace.restore())
            let runId = strategyManager.currentRunId ?? "unknown"

            DeskJigLog.debug(.workspace, "SnapshotViewer: Fluent restore (controller) triggered", fields: [
                "workspace": workspace.name,
                "source": source
            ], runId: runId)
            DeskJigLog.debug(.restorationExecutor, "Starting workspace restoration", fields: [
                "workspace": workspace.name,
                "windowCount": workspace.windowCount,
                "executionMode": strategyManager.executionMode.rawValue,
                "useWindowLocks": strategyManager.useWindowLocks,
                "source": source,
                "chromeSupplementation": strategyManager.enableChromeSupplementation,
                "chromeFetchMethod": strategyManager.chromeFetchMethod.rawValue,
                "terminalSupplementation": strategyManager.enableTerminalSupplementation,
                "terminalFetchMethod": strategyManager.terminalFetchMethod.rawValue
            ], runId: runId)

            // CAPTURE SHARED SNAPSHOT ONCE for all parallel tasks
            // This ensures all tasks see the same initial window state for proper lock coordination
            let sharedSnapshot = await SystemSnapshotCapture.captureQuick(runId: runId)

            // Build app summary for logging
            let windowsByApp = Dictionary(grouping: sharedSnapshot.windows, by: { $0.bundleId ?? "unknown" })
            let appSummary: String = windowsByApp.map { (bundleIdKey: String, appWindows: [SnapshotWindow]) in
                let appName = bundleIdKey.split(separator: ".").last.map(String.init) ?? bundleIdKey
                return "\(appName): \(appWindows.count)"
            }.joined(separator: ", ")

            DeskJigLog.debug(.restorationPlanner, "System snapshot captured", fields: [
                "totalWindows": sharedSnapshot.windows.count,
                "displays": sharedSnapshot.displays.count,
                "apps": appSummary
            ], runId: runId)

            // Partition windows: Chrome, terminal, IDE, and other
            let chromeWindows = workspace.windows.filter { chromeBundleIdentifiers.contains($0.bundleIdentifier) }
            let terminalWindows = workspace.windows.filter { BundleRegistry.isTerminal($0.bundleIdentifier) }
            let ideWindows = workspace.windows.filter { BundleRegistry.isIDE($0.bundleIdentifier) }
            let otherWindows = workspace.windows.filter {
                !chromeBundleIdentifiers.contains($0.bundleIdentifier) &&
                !BundleRegistry.isTerminal($0.bundleIdentifier) &&
                !BundleRegistry.isIDE($0.bundleIdentifier)
            }

            // Capture Chrome profile info via AppleScript (reliable profile extraction)
            // AppleScript parses profiles more reliably than CGWindowList titles
            var chromeAppleScriptCaptures: [ChromeAppleScriptWindowCapture] = []
            if !chromeWindows.isEmpty {
                chromeAppleScriptCaptures = chromeMatcher.captureOpenWindows()
                DeskJigLog.debug(.restorationChrome, "AppleScript captures complete", fields: [
                    "count": chromeAppleScriptCaptures.count,
                    "profiles": chromeAppleScriptCaptures.compactMap { $0.profileAppleScriptName }.joined(separator: "|")
                ], runId: runId)
            }

            DeskJigLog.debug(.restorationPlanner, "Windows partitioned for four-phase restoration", fields: [
                "chromeCount": chromeWindows.count,
                "terminalCount": terminalWindows.count,
                "ideCount": ideWindows.count,
                "otherCount": otherWindows.count,
                "chromeSupplementationEnabled": strategyManager.enableChromeSupplementation,
                "terminalSupplementationEnabled": strategyManager.enableTerminalSupplementation,
                "ideSupplementationEnabled": strategyManager.enableIDESupplementation
            ], runId: runId)

            var successCount = 0
            var failedCount = 0

            // FOUR-PHASE RESTORATION:
            // Phase 1: Start Chrome + Terminal + IDE supplementation in parallel, launch "other" windows immediately
            // Phase 2: Launch terminal windows after terminal supplementation completes
            // Phase 3: Launch IDE windows after IDE supplementation completes
            // Phase 4: Launch Chrome windows after Chrome supplementation completes

            if strategyManager.executionMode == .parallel {
                // Start supplementation tasks in parallel
                let chromeSupplementationService = ChromeSupplementationService()
                let terminalSupplementationService = TerminalSupplementationService()
                let ideSupplementationService = IDESupplementationService()

                // Chrome supplementation task
                let chromeSupplementationTask: Task<SystemSnapshot, Never>?
                if !chromeWindows.isEmpty && strategyManager.enableChromeSupplementation {
                    DeskJigLog.debug(.restorationChrome, "Starting Chrome supplementation", fields: [
                        "chromeWindowCount": chromeWindows.count,
                        "method": strategyManager.chromeFetchMethod.rawValue
                    ], runId: runId)
                    chromeSupplementationTask = Task {
                        await chromeSupplementationService.supplementChromeWindows(
                            in: sharedSnapshot,
                            method: strategyManager.chromeFetchMethod,
                            runId: runId
                        )
                    }
                } else {
                    chromeSupplementationTask = nil
                }

                // Terminal supplementation task
                let terminalSupplementationTask: Task<SystemSnapshot, Never>?
                if !terminalWindows.isEmpty && strategyManager.enableTerminalSupplementation {
                    DeskJigLog.debug(.restorationExecutor, "Starting terminal supplementation", fields: [
                        "terminalWindowCount": terminalWindows.count,
                        "method": strategyManager.terminalFetchMethod.rawValue
                    ], runId: runId)
                    terminalSupplementationTask = Task {
                        await terminalSupplementationService.supplementTerminalWindows(
                            in: sharedSnapshot,
                            method: strategyManager.terminalFetchMethod,
                            runId: runId
                        )
                    }
                } else {
                    terminalSupplementationTask = nil
                }

                // IDE supplementation task
                let ideSupplementationTask: Task<SystemSnapshot, Never>?
                if !ideWindows.isEmpty && strategyManager.enableIDESupplementation {
                    DeskJigLog.debug(.restorationExecutor, "Starting IDE supplementation", fields: [
                        "ideWindowCount": ideWindows.count,
                        "method": strategyManager.ideFetchMethod.rawValue
                    ], runId: runId)
                    ideSupplementationTask = Task {
                        await ideSupplementationService.supplementIDEWindows(
                            in: sharedSnapshot,
                            method: strategyManager.ideFetchMethod,
                            runId: runId
                        )
                    }
                } else {
                    ideSupplementationTask = nil
                }

                // Launch "other" windows immediately (they don't need supplementation)
                if !otherWindows.isEmpty {
                    DeskJigLog.debug(.restorationExecutor, "Launching other windows", fields: ["count": otherWindows.count], runId: runId)

                    await withTaskGroup(of: Bool.self) { group in
                        for window in otherWindows {
                            group.addTask { @MainActor in
                                await self.launchSingleWindowAsync(window, snapshot: sharedSnapshot)
                            }
                        }
                        for await success in group {
                            if success { successCount += 1 }
                            else { failedCount += 1 }
                        }
                    }
                }

                // Wait for terminal supplementation, then launch terminal windows
                if !terminalWindows.isEmpty {
                    let terminalEnrichedSnapshot: SystemSnapshot
                    if let task = terminalSupplementationTask {
                        terminalEnrichedSnapshot = await task.value
                        DeskJigLog.debug(.restorationExecutor, "Terminal supplementation complete", fields: [
                            "enrichedCount": terminalEnrichedSnapshot.supplementedTerminalWindows.count
                        ], runId: runId)
                    } else {
                        terminalEnrichedSnapshot = sharedSnapshot
                    }

                    DeskJigLog.debug(.restorationExecutor, "Launching terminal windows", fields: ["count": terminalWindows.count], runId: runId)

                    await withTaskGroup(of: Bool.self) { group in
                        for window in terminalWindows {
                            group.addTask { @MainActor in
                                await self.launchSingleWindowAsync(window, snapshot: terminalEnrichedSnapshot)
                            }
                        }
                        for await success in group {
                            if success { successCount += 1 }
                            else { failedCount += 1 }
                        }
                    }
                }

                // Wait for IDE supplementation, then launch IDE windows
                if !ideWindows.isEmpty {
                    let ideEnrichedSnapshot: SystemSnapshot
                    if let task = ideSupplementationTask {
                        ideEnrichedSnapshot = await task.value
                        DeskJigLog.debug(.restorationExecutor, "IDE supplementation complete", fields: [
                            "enrichedCount": ideEnrichedSnapshot.supplementedIDEWindows.count
                        ], runId: runId)
                    } else {
                        ideEnrichedSnapshot = sharedSnapshot
                    }

                    DeskJigLog.debug(.restorationExecutor, "Launching IDE windows", fields: ["count": ideWindows.count], runId: runId)

                    await withTaskGroup(of: Bool.self) { group in
                        for window in ideWindows {
                            group.addTask { @MainActor in
                                await self.launchSingleWindowAsync(window, snapshot: ideEnrichedSnapshot)
                            }
                        }
                        for await success in group {
                            if success { successCount += 1 }
                            else { failedCount += 1 }
                        }
                    }
                }

                // Wait for Chrome supplementation, then launch Chrome windows
                if !chromeWindows.isEmpty {
                    let chromeEnrichedSnapshot: SystemSnapshot
                    if let task = chromeSupplementationTask {
                        chromeEnrichedSnapshot = await task.value
                        DeskJigLog.debug(.restorationChrome, "Chrome supplementation complete", fields: [
                            "enrichedCount": chromeEnrichedSnapshot.supplementedChromeWindows.count
                        ], runId: runId)
                    } else {
                        chromeEnrichedSnapshot = sharedSnapshot
                    }

                    DeskJigLog.debug(.restorationExecutor, "Launching Chrome windows", fields: ["count": chromeWindows.count], runId: runId)

                    await withTaskGroup(of: Bool.self) { group in
                        for window in chromeWindows {
                            group.addTask { @MainActor in
                                await self.launchSingleWindowAsync(
                                    window,
                                    snapshot: chromeEnrichedSnapshot,
                                    chromeAppleScriptCaptures: chromeAppleScriptCaptures
                                )
                            }
                        }
                        for await success in group {
                            if success { successCount += 1 }
                            else { failedCount += 1 }
                        }
                    }
                }
            } else {
                // Sequential execution - supplement first if needed, then launch all
                var snapshotToUse = sharedSnapshot

                // Terminal supplementation (sequential)
                if !terminalWindows.isEmpty && strategyManager.enableTerminalSupplementation {
                    DeskJigLog.debug(.restorationExecutor, "Starting terminal supplementation (sequential)", fields: [
                        "terminalWindowCount": terminalWindows.count,
                        "method": strategyManager.terminalFetchMethod.rawValue
                    ], runId: runId)

                    let terminalSupplementationService = TerminalSupplementationService()
                    snapshotToUse = await terminalSupplementationService.supplementTerminalWindows(
                        in: snapshotToUse,
                        method: strategyManager.terminalFetchMethod,
                        runId: runId
                    )

                    DeskJigLog.debug(.restorationExecutor, "Terminal supplementation complete", fields: [
                        "enrichedCount": snapshotToUse.supplementedTerminalWindows.count
                    ], runId: runId)
                }

                // IDE supplementation (sequential)
                if !ideWindows.isEmpty && strategyManager.enableIDESupplementation {
                    DeskJigLog.debug(.restorationExecutor, "Starting IDE supplementation (sequential)", fields: [
                        "ideWindowCount": ideWindows.count,
                        "method": strategyManager.ideFetchMethod.rawValue
                    ], runId: runId)

                    let ideSupplementationService = IDESupplementationService()
                    snapshotToUse = await ideSupplementationService.supplementIDEWindows(
                        in: snapshotToUse,
                        method: strategyManager.ideFetchMethod,
                        runId: runId
                    )

                    DeskJigLog.debug(.restorationExecutor, "IDE supplementation complete", fields: [
                        "enrichedCount": snapshotToUse.supplementedIDEWindows.count
                    ], runId: runId)
                }

                // Chrome supplementation (sequential)
                if !chromeWindows.isEmpty && strategyManager.enableChromeSupplementation {
                    DeskJigLog.debug(.restorationChrome, "Starting Chrome supplementation (sequential)", fields: [
                        "chromeWindowCount": chromeWindows.count,
                        "method": strategyManager.chromeFetchMethod.rawValue
                    ], runId: runId)

                    let chromeSupplementationService = ChromeSupplementationService()
                    snapshotToUse = await chromeSupplementationService.supplementChromeWindows(
                        in: snapshotToUse,
                        method: strategyManager.chromeFetchMethod,
                        runId: runId
                    )

                    DeskJigLog.debug(.restorationChrome, "Chrome supplementation complete", fields: [
                        "enrichedCount": snapshotToUse.supplementedChromeWindows.count
                    ], runId: runId)
                }

                DeskJigLog.debug(.restorationExecutor, "Launching windows sequentially", fields: ["count": workspace.windowCount], runId: runId)

                for window in workspace.windows {
                    let success = await launchSingleWindowAsync(
                        window,
                        snapshot: snapshotToUse,
                        chromeAppleScriptCaptures: chromeAppleScriptCaptures
                    )
                    if success { successCount += 1 }
                    else { failedCount += 1 }
                }
            }

            DeskJigLog.debug(.restorationExecutor, "Workspace restoration finished", fields: [
                "success": successCount,
                "failed": failedCount,
                "total": workspace.windowCount
            ], runId: runId)

            // POST-RESTORATION: Raise all workspace windows to the front
            // This matches what the legacy path does in ensureWorkspaceWindowsOnTop/enforceTopmostForWorkspaceWindows
            // Delegated to LaunchStrategyManager for proper separation of concerns
            await strategyManager.performPostRestoreRaise(
                workspace: workspace,
                chromeBundleIdentifiers: chromeBundleIdentifiers
            )

            // Import NDJSON logs to UI for display
            strategyManager.importFluentApiTraceLogs()

            strategyManager.endLaunch(success: failedCount == 0, windowCount: successCount)
        }
    }

    func launchSingleWindow(_ window: WorkspaceWindow) {
        strategyManager.startLaunch()

        Task { @MainActor in
            let taskId = window.appName.lowercased().replacingOccurrences(of: " ", with: "-")
            let strategy = strategyManager.strategy(for: window.id)
            let screenOverride = strategyManager.screenOverride(for: window.id)
            let runId = strategyManager.currentRunId ?? "ui-single"
            let taskContext = RestorationTaskContext(
                taskId: taskId,
                taskType: chromeBundleIdentifiers.contains(window.bundleIdentifier) ? .chrome :
                          BundleRegistry.isTerminal(window.bundleIdentifier) ? .terminal :
                          OpenByPathBundleIdentifiers.supported.contains(window.bundleIdentifier) ? .ide : .defaultApp,
                runId: runId
            )

            strategyManager.addLogEntry(
                phase: .handler,
                taskId: taskId,
                message: "Launching single window: \(window.appName)",
                data: [
                    "bundleId": window.bundleIdentifier,
                    "windowTitle": window.windowTitle,
                    "openPath": window.openPath ?? "none",
                    "screenOverride": screenOverride.map { "\($0)" } ?? "none",
                    "matchMethod": strategy.matchMethod.rawValue,
                    "launchMethod": strategy.launchMethod.rawValue
                ]
            )

            if strategyManager.isDryRun {
                // Dry run - simulate the launch
                await Task.sleepUnlessCancelled(for: .milliseconds(300))
                strategyManager.addLogEntry(
                    phase: .launch,
                    taskId: taskId,
                    message: "[DRY RUN] Would launch \(window.appName)",
                    data: ["success": "true"]
                )
                strategyManager.endLaunch(success: true, windowCount: 1)
                return
            }

            // Capture snapshot for pre-checking existing windows
            var snapshot = await SystemSnapshotCapture.captureQuick(runId: runId)

            // Log snapshot summary for single window launch
            let singleWindowsByApp = Dictionary(grouping: snapshot.windows, by: { $0.bundleId ?? "unknown" })
            let singleAppSummary: String = singleWindowsByApp.map { (bundleIdKey: String, appWindows: [SnapshotWindow]) in
                let appName = bundleIdKey.split(separator: ".").last.map(String.init) ?? bundleIdKey
                return "\(appName): \(appWindows.count)"
            }.joined(separator: ", ")

            strategyManager.addLogEntry(
                phase: .match,
                taskId: taskId,
                message: "System snapshot captured",
                data: [
                    "totalWindows": "\(snapshot.windows.count)",
                    "apps": singleAppSummary
                ]
            )

            // Capture AppleScript state for Chrome window matching
            var chromeAppleScriptCaptures: [ChromeAppleScriptWindowCapture] = []
            if chromeBundleIdentifiers.contains(window.bundleIdentifier) {
                chromeAppleScriptCaptures = chromeMatcher.captureOpenWindows()
            }

            // If launching Chrome, supplement the snapshot first for profile matching
            if chromeBundleIdentifiers.contains(window.bundleIdentifier) {
                let chromeWindows = snapshot.windows.filter { chromeBundleIdentifiers.contains($0.bundleId ?? "") }
                let needsSupplementation = chromeWindows.contains {
                    $0.supplementationStatus == .pending || $0.supplementationStatus == nil
                }

                if needsSupplementation && !chromeWindows.isEmpty {
                    strategyManager.addLogEntry(
                        phase: .chrome,
                        taskId: taskId,
                        message: "Running Chrome supplementation for single window launch",
                        data: ["chromeWindowCount": "\(chromeWindows.count)"]
                    )

                    let supplementationService = ChromeSupplementationService()
                    snapshot = await supplementationService.supplementChromeWindows(
                        in: snapshot,
                        method: strategyManager.chromeFetchMethod,
                        runId: runId
                    )

                    let supplementedProfiles = snapshot.windows
                        .filter { $0.supplementationStatus == .completed }
                        .compactMap { $0.chromeProfileFromTitle }
                        .joined(separator: ", ")

                    strategyManager.addLogEntry(
                        phase: .chrome,
                        taskId: taskId,
                        message: "Chrome supplementation completed",
                        data: [
                            "supplementedCount": "\(snapshot.supplementedChromeWindows.count)",
                            "profiles": supplementedProfiles
                        ]
                    )
                }
            }

            // If launching an IDE, supplement the snapshot for document path matching
            if OpenByPathBundleIdentifiers.supported.contains(window.bundleIdentifier),
               BundleRegistry.isIDE(window.bundleIdentifier),
               strategyManager.enableIDESupplementation {
                strategyManager.addLogEntry(
                    phase: .ide,
                    taskId: taskId,
                    message: "Running IDE supplementation for single window launch",
                    data: ["method": strategyManager.ideFetchMethod.rawValue]
                )

                let ideSupplementationService = IDESupplementationService()
                snapshot = await ideSupplementationService.supplementIDEWindows(
                    in: snapshot,
                    method: strategyManager.ideFetchMethod,
                    runId: runId
                )

                strategyManager.addLogEntry(
                    phase: .ide,
                    taskId: taskId,
                    message: "IDE supplementation completed",
                    data: ["supplementedCount": "\(snapshot.supplementedIDEWindows.count)"]
                )
            }

            // Calculate target frame based on screen mappings
            let targetFrame = calculateTargetFrame(for: window)

            strategyManager.addLogEntry(
                phase: .handler,
                taskId: taskId,
                message: "Target frame calculated",
                data: ["frame": "\(Int(targetFrame.origin.x)),\(Int(targetFrame.origin.y)) \(Int(targetFrame.width))x\(Int(targetFrame.height))"]
            )

            // Route by app type - pass snapshot for pre-checking existing windows
            let success: Bool
            if chromeBundleIdentifiers.contains(window.bundleIdentifier) {
                // Chrome windows - use ChromeOperations
                success = await launchAndPositionChrome(
                    window,
                    targetFrame: targetFrame,
                    taskId: taskId,
                    snapshot: snapshot,
                    chromeAppleScriptCaptures: chromeAppleScriptCaptures
                )
            } else if OpenByPathBundleIdentifiers.supported.contains(window.bundleIdentifier), window.openPath != nil {
                // Terminals and IDEs with open path - use Fluent launchers
                DeskJigLog.debug(.restorationExecutor, "Strategy config", fields: [
                    "taskId": taskContext.taskId,
                    "matchMethod": strategy.matchMethod.rawValue,
                    "launchMethod": strategy.launchMethod.rawValue,
                    "ideLaunchMode": strategy.ideLaunchMode.rawValue,
                    "searchPath": window.openPath ?? "none",
                    "searchTitle": window.windowTitle
                ], runId: taskContext.runId)

                let openByPathConfig = OpenByPathRestorationConfig(
                    terminalFetchMethod: strategyManager.terminalFetchMethod,
                    enableTerminalSupplementation: strategyManager.enableTerminalSupplementation,
                    ideFetchMethod: strategyManager.ideFetchMethod,
                    enableIDESupplementation: strategyManager.enableIDESupplementation,
                    useWindowLocks: strategyManager.useWindowLocks,
                    lockTimeout: .seconds(strategyManager.lockTimeout)
                )

                let result = await openByPathRestorationService.restore(
                    window: window,
                    targetFrame: targetFrame,
                    snapshot: snapshot,
                    taskContext: taskContext,
                    config: openByPathConfig
                )
                success = result.success
            } else {
                // Generic apps - use NSWorkspace
                DeskJigLog.debug(.restorationExecutor, "Generic app strategy config", fields: [
                    "taskId": taskContext.taskId,
                    "matchMethod": strategy.matchMethod.rawValue,
                    "launchMethod": strategy.launchMethod.rawValue,
                    "bundleId": window.bundleIdentifier,
                    "appName": window.appName
                ], runId: taskContext.runId)

                let genericConfig = GenericWindowRestorationConfig(
                    useWindowLocks: strategyManager.useWindowLocks,
                    lockTimeout: .seconds(strategyManager.lockTimeout)
                )

                success = await genericRestorationService.restore(
                    window: window,
                    targetFrame: targetFrame,
                    snapshot: snapshot,
                    taskContext: taskContext,
                    config: genericConfig
                )
            }

            // Import NDJSON trace logs to UI for display in Debug View
            strategyManager.importFluentApiTraceLogs()
            strategyManager.endLaunch(success: success, windowCount: success ? 1 : 0)
        }
    }

    // MARK: - Single Window Launch Helpers

    /// Simulates a dry run launch - just logs what would happen without lock simulation
    private func simulateDryRun(workspace: WorkspaceHandle) async {
        let isParallel = strategyManager.executionMode == .parallel

        strategyManager.addLogEntry(
            phase: .handler,
            message: "[DRY RUN] Simulating \(isParallel ? "parallel" : "sequential") restoration",
            data: [
                "windowCount": "\(workspace.windowCount)",
                "mode": strategyManager.executionMode.rawValue
            ]
        )

        if isParallel {
            await withTaskGroup(of: Void.self) { group in
                for (index, window) in workspace.windows.enumerated() {
                    group.addTask { @MainActor in
                        await Task.sleepUnlessCancelled(for: .milliseconds(Int.random(in: 100...500)))
                        self.strategyManager.addLogEntry(
                            phase: .launch,
                            taskId: "\(window.appName.lowercased())-\(index)",
                            message: "[DRY RUN] Would launch \(window.appName)",
                            data: [
                                "app": window.appName,
                                "bundleId": window.bundleIdentifier,
                                "directory": window.openPath ?? "none"
                            ]
                        )
                    }
                }
            }
        } else {
            for (index, window) in workspace.windows.enumerated() {
                guard await Task.sleepUnlessCancelled(for: .milliseconds(200)) else { break }
                strategyManager.addLogEntry(
                    phase: .launch,
                    taskId: "\(window.appName.lowercased())-\(index)",
                    message: "[DRY RUN] Would launch \(window.appName)",
                    data: [
                        "app": window.appName,
                        "bundleId": window.bundleIdentifier,
                        "directory": window.openPath ?? "none"
                    ]
                )
            }
        }
    }

    /// Async version of launchSingleWindow that returns success status (for workspace launch)
    /// Uses shared snapshot for pre-checking existing windows before launching
    private func launchSingleWindowAsync(
        _ window: WorkspaceWindow,
        snapshot: SystemSnapshot,
        chromeAppleScriptCaptures: [ChromeAppleScriptWindowCapture] = []
    ) async -> Bool {
        let taskId = window.appName.lowercased().replacingOccurrences(of: " ", with: "-")
        let strategy = strategyManager.strategy(for: window.id)
        let runId = strategyManager.currentRunId ?? "ui-single"

        let taskContext = RestorationTaskContext(
            taskId: taskId,
            taskType: chromeBundleIdentifiers.contains(window.bundleIdentifier) ? .chrome :
                      BundleRegistry.isTerminal(window.bundleIdentifier) ? .terminal :
                      OpenByPathBundleIdentifiers.supported.contains(window.bundleIdentifier) ? .ide : .defaultApp,
            runId: runId
        )

        // Determine routing decision
        let isChrome = chromeBundleIdentifiers.contains(window.bundleIdentifier)
        let isOpenByPath = OpenByPathBundleIdentifiers.supported.contains(window.bundleIdentifier)
        let hasOpenPath = window.openPath != nil
        let route = isChrome ? "chrome" : (isOpenByPath && hasOpenPath ? "openByPath" : "generic")
        let handler = isChrome ? "launchAndPositionChrome" :
                     (isOpenByPath && hasOpenPath) ? "openByPathRestorationService" : "genericRestorationService"

        DeskJigLog.debug(.restorationExecutor, "Routing window to handler", fields: [
            "taskId": taskContext.taskId,
            "bundleId": window.bundleIdentifier,
            "appName": window.appName,
            "windowTitle": window.windowTitle,
            "isChrome": isChrome,
            "isOpenByPath": isOpenByPath,
            "hasOpenPath": hasOpenPath,
            "hasChromeState": window.chromeState != nil,
            "route": route,
            "handler": handler,
            "openPath": window.openPath ?? "none",
            "matchMethod": strategy.matchMethod.rawValue,
            "launchMethod": strategy.launchMethod.rawValue
        ], runId: taskContext.runId)

        // Calculate target frame
        let targetFrame = calculateTargetFrame(for: window)

        DeskJigLog.debug(.restorationExecutor, "Target frame calculated", fields: [
            "taskId": taskContext.taskId,
            "frame": targetFrame
        ], runId: taskContext.runId)

        // Route by app type - pass shared snapshot for pre-checking existing windows
        if chromeBundleIdentifiers.contains(window.bundleIdentifier) {
            return await launchAndPositionChrome(
                window,
                targetFrame: targetFrame,
                taskId: taskId,
                snapshot: snapshot,
                chromeAppleScriptCaptures: chromeAppleScriptCaptures
            )
        } else if OpenByPathBundleIdentifiers.supported.contains(window.bundleIdentifier), window.openPath != nil {
            DeskJigLog.debug(.restorationExecutor, "Strategy config", fields: [
                "taskId": taskContext.taskId,
                "matchMethod": strategy.matchMethod.rawValue,
                "launchMethod": strategy.launchMethod.rawValue,
                "ideLaunchMode": strategy.ideLaunchMode.rawValue,
                "searchPath": window.openPath ?? "none",
                "searchTitle": window.windowTitle
            ], runId: taskContext.runId)

            let openByPathConfig = OpenByPathRestorationConfig(
                terminalFetchMethod: strategyManager.terminalFetchMethod,
                enableTerminalSupplementation: strategyManager.enableTerminalSupplementation,
                ideFetchMethod: strategyManager.ideFetchMethod,
                enableIDESupplementation: strategyManager.enableIDESupplementation,
                useWindowLocks: strategyManager.useWindowLocks,
                lockTimeout: .seconds(strategyManager.lockTimeout)
            )

            let result = await openByPathRestorationService.restore(
                window: window,
                targetFrame: targetFrame,
                snapshot: snapshot,
                taskContext: taskContext,
                config: openByPathConfig
            )
            return result.success
        } else {
            DeskJigLog.debug(.restorationExecutor, "Generic app strategy config", fields: [
                "taskId": taskContext.taskId,
                "matchMethod": strategy.matchMethod.rawValue,
                "launchMethod": strategy.launchMethod.rawValue,
                "bundleId": window.bundleIdentifier,
                "appName": window.appName
            ], runId: taskContext.runId)

            let genericConfig = GenericWindowRestorationConfig(
                useWindowLocks: strategyManager.useWindowLocks,
                lockTimeout: .seconds(strategyManager.lockTimeout)
            )

            return await genericRestorationService.restore(
                window: window,
                targetFrame: targetFrame,
                snapshot: snapshot,
                taskContext: taskContext,
                config: genericConfig
            )
        }
    }

    /// Calculate the target frame for a window based on screen mapping/overrides
    private func calculateTargetFrame(for window: WorkspaceWindow) -> CGRect {
        guard let relativeFrame = window.relativeFrame else {
            return .zero
        }

        let effectiveScreenIndex = strategyManager.effectiveScreen(for: window)
        let currentScreens = NSScreen.screens
        let globalMaxY = globalMaxY(for: currentScreens)
        let screen = effectiveScreenIndex < currentScreens.count
            ? currentScreens[effectiveScreenIndex]
            : (currentScreens.first ?? NSScreen.main ?? NSScreen.screens[0])
        let visibleFrame = visibleFrameInWindowCoordinates(for: screen, globalMaxY: globalMaxY)
        let x = visibleFrame.origin.x + (relativeFrame.xPercent * visibleFrame.width)
        let y = visibleFrame.origin.y + (relativeFrame.yPercent * visibleFrame.height)
        let width = relativeFrame.widthPercent * visibleFrame.width
        let height = relativeFrame.heightPercent * visibleFrame.height
        return CGRect(x: x, y: y, width: width, height: height)
    }

    /// Launch and position a Chrome window with tabs
    /// First checks for existing Chrome window in shared snapshot before launching
    private func launchAndPositionChrome(
        _ window: WorkspaceWindow,
        targetFrame: CGRect,
        taskId: String,
        snapshot: SystemSnapshot,
        chromeAppleScriptCaptures: [ChromeAppleScriptWindowCapture] = []
    ) async -> Bool {
        let strategy = strategyManager.strategy(for: window.id)
        let taskContext = RestorationTaskContext(
            taskId: taskId,
            taskType: .chrome,
            runId: strategyManager.currentRunId ?? "ui-single"
        )

        // Get Chrome state for tab restoration
        let profileDir = window.chromeState?.profileDirectory  // For launch command: --profile-directory="Profile 2"
        let profileDisplayName = window.chromeState?.appleScriptProfileName  // For matching: "Work" or "Work (domain.com)"
        let urls = window.chromeState?.savedTabURLs ?? []

        // Log strategy configuration with Chrome method
        DeskJigLog.debug(.restorationChrome, "Chrome strategy config", fields: [
            "taskId": taskContext.taskId,
            "matchMethod": strategy.matchMethod.rawValue,
            "launchMethod": strategy.launchMethod.rawValue,
            "chromeMethod": strategy.chromeMethod.rawValue,
            "profileDir": profileDir ?? "default",
            "profileDisplayName": profileDisplayName ?? "none",
            "tabCount": urls.count
        ], runId: taskContext.runId)

        // Log native extension status for this restoration
        let extensionStatus = await ChromeExtensionStatusService.getStatus()
        DeskJigLog.debug(.restorationChrome, "Native extension status", fields: [
            "taskId": taskContext.taskId,
            "globalConnected": extensionStatus.isConnected,
            "connectionStatus": extensionStatus.connectionStatus.map { "\($0)" } ?? "nil",
            "windowCount": extensionStatus.windowCount,
            "targetProfile": profileDisplayName ?? "none",
            "selectedMethod": strategy.chromeMethod.rawValue
        ], runId: taskContext.runId)

        // FIRST: Check for existing Chrome window in shared snapshot
        let matchResult = chromeMatcher.matchExistingWindow(
            workspaceWindow: window,
            snapshot: snapshot,
            chromeCaptures: chromeAppleScriptCaptures,
            matchMethod: strategy.matchMethod.toMatchMethod(),
            taskContext: taskContext
        )

        if let existingWindow = matchResult.window {
            // Safety check: If matched window still has pending supplementation, retry with enriched data
            if existingWindow.supplementationStatus == .pending {
                DeskJigLog.debug(.restorationExecutor, "Lock AWAITING_SUPPLEMENTATION - matched window still pending", fields: [
                    "taskId": taskContext.taskId,
                    "windowId": existingWindow.windowId,
                    "action": "retrying with supplementation"
                ], runId: taskContext.runId)

                let supplementationService = ChromeSupplementationService()
                let enrichedSnapshot = await supplementationService.supplementChromeWindows(
                    in: snapshot,
                    method: strategyManager.chromeFetchMethod,
                    runId: strategyManager.currentRunId ?? "ui-single"
                )

                return await launchAndPositionChrome(
                    window,
                    targetFrame: targetFrame,
                    taskId: taskId,
                    snapshot: enrichedSnapshot,
                    chromeAppleScriptCaptures: chromeAppleScriptCaptures
                )
            }

            let matchedCapture = matchResult.capture
            let matchedChromeWindowId = matchResult.chromeWindowId

            DeskJigLog.debug(.restorationPlanner, "Reusing existing Chrome window", fields: [
                "taskId": taskContext.taskId,
                "reused": true,
                "windowId": existingWindow.windowId,
                "profileDir": profileDir ?? "default",
                "profileDisplayName": profileDisplayName ?? "none",
                "title": existingWindow.title ?? "untitled",
                "matchMethod": matchResult.method.rawValue,
                "supplementationStatus": existingWindow.supplementationStatus?.rawValue ?? "nil"
            ], runId: taskContext.runId)

            DeskJigLog.debug(.restorationPlanner, "Acquiring AX window handle", fields: [
                "taskId": taskContext.taskId,
                "windowId": existingWindow.windowId,
                "pid": existingWindow.pid,
                "currentFrame": existingWindow.frame,
                "title": existingWindow.title ?? "(empty)",
                "freshAxTitle": existingWindow.freshAxTitle ?? "nil",
                "profileDisplayName": profileDisplayName ?? "none"
            ], runId: taskContext.runId)

            guard let handle = chromeMatcher.resolveHandle(
                snapshotWindow: existingWindow,
                chromeState: window.chromeState
            ) else {
                let windowStillExists = CGWindowListCopyWindowInfo([.optionIncludingWindow], CGWindowID(existingWindow.windowId)) != nil
                DeskJigLog.debug(.restorationPlanner, "Window handle acquisition FAILED", fields: [
                    "taskId": taskContext.taskId,
                    "windowId": existingWindow.windowId,
                    "title": existingWindow.title ?? "(empty)",
                    "windowStillInCGWindowList": windowStillExists
                ], runId: taskContext.runId)
                return false
            }

            DeskJigLog.debug(.restorationPlanner, "Window handle acquired", fields: [
                "taskId": taskContext.taskId,
                "windowId": existingWindow.windowId,
                "success": true
            ], runId: taskContext.runId)

                // Acquire lock for existing window
                var acquiredLock: WindowLock?
                let lockRequestId = String(UUID().uuidString.prefix(8))
                if strategyManager.useWindowLocks {
                    DeskJigLog.debug(.restorationExecutor, "Requesting lock", fields: [
                        "taskId": taskContext.taskId,
                        "lockRequestId": lockRequestId,
                        "windowId": existingWindow.windowId,
                        "requesterId": taskId,
                        "priority": LockPriority.high.description,
                        "useWindowLocks": strategyManager.useWindowLocks
                    ], runId: taskContext.runId)

                    let lockResult = await lockManager.requestLock(
                        for: CGWindowID(existingWindow.windowId),
                        requesterId: taskId,
                        priority: .high,
                        timeout: .seconds(strategyManager.lockTimeout)
                    )

                    switch lockResult {
                    case .acquired(let lock):
                        acquiredLock = lock
                        DeskJigLog.debug(.restorationExecutor, "Lock ACQUIRED", fields: [
                            "taskId": taskContext.taskId,
                            "lockRequestId": lockRequestId,
                            "windowId": lock.windowId,
                            "holderId": lock.holderId,
                            "priority": lock.priority.description,
                            "expiresAt": lock.expiresAt?.description ?? "never"
                        ], runId: taskContext.runId)
                    case .denied(let reason, let currentHolder):
                        DeskJigLog.debug(.restorationExecutor, "Lock DENIED", fields: [
                            "taskId": taskContext.taskId,
                            "lockRequestId": lockRequestId,
                            "windowId": existingWindow.windowId,
                            "reason": reason,
                            "currentHolder": currentHolder ?? "unknown"
                        ], runId: taskContext.runId)
                        return false
                    case .queued(let position):
                        DeskJigLog.debug(.restorationExecutor, "Lock QUEUED", fields: [
                            "taskId": taskContext.taskId,
                            "lockRequestId": lockRequestId,
                            "windowId": existingWindow.windowId,
                            "queuePosition": position
                        ], runId: taskContext.runId)
                        return false
                    case .timedOut:
                        DeskJigLog.debug(.restorationExecutor, "Lock TIMEOUT", fields: [
                            "taskId": taskContext.taskId,
                            "lockRequestId": lockRequestId,
                            "windowId": existingWindow.windowId
                        ], runId: taskContext.runId)
                        return false
                    case .awaitingChromeSupplementation:
                        DeskJigLog.debug(.restorationExecutor, "Lock AWAITING_SUPPLEMENTATION", fields: [
                            "taskId": taskContext.taskId,
                            "lockRequestId": lockRequestId,
                            "windowId": existingWindow.windowId
                        ], runId: taskContext.runId)
                        return false
                    }
                }

                // Position existing window - log before/after with screen info
                let currentFrame = existingWindow.frame
                let currentScreenIndex = screenIndexForFrame(currentFrame)
                let targetScreenIndex = screenIndexForFrame(targetFrame)

                DeskJigLog.debug(.restorationPositioning, "Positioning window", fields: [
                    "taskId": taskContext.taskId,
                    "windowId": existingWindow.windowId,
                    "beforeFrame": currentFrame,
                    "targetFrame": targetFrame,
                    "beforeScreen": currentScreenIndex,
                    "targetScreen": targetScreenIndex,
                    "operations": "setFrame->raise->activate"
                ], runId: taskContext.runId)

                handle.setFrame(targetFrame)?.raise()?.activate()

                let finalFrame = handle.frame ?? targetFrame
                let finalScreenIndex = screenIndexForFrame(finalFrame)
                let matchesTarget = abs(finalFrame.origin.x - targetFrame.origin.x) < 2 &&
                                   abs(finalFrame.origin.y - targetFrame.origin.y) < 2 &&
                                   abs(finalFrame.width - targetFrame.width) < 2 &&
                                   abs(finalFrame.height - targetFrame.height) < 2

                DeskJigLog.debug(.restorationPositioning, "Window positioned", fields: [
                    "taskId": taskContext.taskId,
                    "windowId": existingWindow.windowId,
                    "finalFrame": finalFrame,
                    "matchesTarget": matchesTarget,
                    "finalScreen": finalScreenIndex,
                    "success": true
                ], runId: taskContext.runId)

                // Restore missing tabs in the reused window
                if let chromeState = window.chromeState,
                   chromeState.shouldRestoreTabs,
                   !chromeState.savedTabURLs.isEmpty {

                    let tabRestorationMethod = strategy.chromeMethod

                    // Get current tabs from the matched window (prefer AppleScript capture)
                    let currentTabUrls = matchedCapture?.tabURLs ?? existingWindow.chromeTabUrls ?? []

                    // Find tabs that need to be opened (not already present)
                    let missingTabUrls = chromeState.savedTabURLs.filter { savedUrl in
                        !currentTabUrls.contains { currentUrl in
                            ChromeAutomationService.urlsAreEquivalent(savedUrl, currentUrl)
                        }
                    }

                    let extensionConnected = ChromeNativeMessagingServiceHolder.shared?.isConnected ?? false

                    DeskJigLog.debug(.restorationChrome, "Tab restoration started", fields: [
                        "taskId": taskContext.taskId,
                        "method": tabRestorationMethod.rawValue,
                        "savedTabCount": chromeState.savedTabURLs.count,
                        "currentTabCount": currentTabUrls.count,
                        "missingCount": missingTabUrls.count,
                        "cgWindowId": existingWindow.windowId,
                        "extensionConnected": extensionConnected
                    ], runId: taskContext.runId)

                    if !missingTabUrls.isEmpty {
                        let tabRestoreStartTime = Date()

                        switch tabRestorationMethod {
                        case .native:
                            await restoreTabsViaNativeMessaging(
                                urls: missingTabUrls,
                                windowId: nil,
                                taskContext: taskContext
                            )
                        case .appleScript:
                            if let chromeWindowId = matchedChromeWindowId {
                                ChromeAutomationService.openMissingTabs(
                                    chromeState.savedTabURLs,
                                    inWindowWithChromeId: chromeWindowId
                                )
                            } else {
                                ChromeAutomationService.openMissingTabs(
                                    chromeState.savedTabURLs,
                                    inWindowWithBounds: existingWindow.frame
                                )
                            }
                        }

                        let tabRestoreDurationMs = Int(Date().timeIntervalSince(tabRestoreStartTime) * 1000)
                        DeskJigLog.debug(.restorationChrome, "Tab restoration complete", fields: [
                            "taskId": taskContext.taskId,
                            "method": tabRestorationMethod.rawValue,
                            "missingCount": missingTabUrls.count,
                            "durationMs": tabRestoreDurationMs
                        ], runId: taskContext.runId)
                    } else {
                        DeskJigLog.debug(.restorationChrome, "All tabs already open", fields: [
                            "taskId": taskContext.taskId,
                            "currentCount": currentTabUrls.count,
                            "savedCount": chromeState.savedTabURLs.count
                        ], runId: taskContext.runId)
                    }

                    // Restore focused tab index if available
                    if let focusedIndex = chromeState.focusedTabIndex {
                        DeskJigLog.debug(.restorationChrome, "Setting active tab", fields: [
                            "taskId": taskContext.taskId,
                            "focusedTabIndex": focusedIndex,
                            "method": tabRestorationMethod.rawValue
                        ], runId: taskContext.runId)

                        switch tabRestorationMethod {
                        case .native:
                            if let chromeWindowId = matchedChromeWindowId {
                                ChromeAutomationService.setActiveTab(index: focusedIndex, inWindowWithChromeId: chromeWindowId)
                            } else {
                                ChromeAutomationService.setActiveTab(index: focusedIndex, inWindowWithBounds: existingWindow.frame)
                            }
                        case .appleScript:
                            if let chromeWindowId = matchedChromeWindowId {
                                ChromeAutomationService.setActiveTab(index: focusedIndex, inWindowWithChromeId: chromeWindowId)
                            } else {
                                ChromeAutomationService.setActiveTab(index: focusedIndex, inWindowWithBounds: existingWindow.frame)
                            }
                        }
                    }
                }

                // Release lock
                if let lock = acquiredLock {
                    await lockManager.releaseLock(lock)
                    DeskJigLog.debug(.restorationExecutor, "Lock RELEASED", fields: [
                        "taskId": taskContext.taskId,
                        "lockRequestId": lockRequestId,
                        "windowId": lock.windowId,
                        "holderId": lock.holderId,
                        "heldDuration": "\(String(format: "%.3f", Date().timeIntervalSince(lock.acquiredAt)))s"
                    ], runId: taskContext.runId)
                }

                DeskJigLog.debug(.restorationExecutor, "Chrome restoration complete", fields: ["taskId": taskContext.taskId, "success": true, "reused": true], runId: taskContext.runId)
                return true
            }
        // No existing window found - launch new Chrome window
        let launchSuccess: Bool
        let actualMethod: String

        switch strategy.chromeMethod {
        case .native:
            actualMethod = "native"
            DeskJigLog.debug(.restorationExecutor, "Calling Chrome launch method", fields: [
                "taskId": taskContext.taskId,
                "chromeMethod": "native",
                "urlCount": urls.count,
                "urls": urls.prefix(5).joined(separator: " | ")
            ], runId: taskContext.runId)
            launchSuccess = await ChromeOperations.launchWindowViaNativeMessaging(urls: urls)

        case .appleScript:
            actualMethod = "appleScript"
            DeskJigLog.debug(.restorationExecutor, "Calling Chrome launch method", fields: [
                "taskId": taskContext.taskId,
                "chromeMethod": "appleScript",
                "profileDirectory": profileDir ?? "default",
                "urlCount": urls.count,
                "urls": urls.prefix(5).joined(separator: " | ")
            ], runId: taskContext.runId)
            launchSuccess = await ChromeOperations.launchWindowViaAppleScript(profileDirectory: profileDir, urls: urls)
        }

        DeskJigLog.debug(.restorationExecutor, "Chrome launch result", fields: [
            "taskId": taskContext.taskId,
            "selectedMethod": strategy.chromeMethod.rawValue,
            "actualMethod": actualMethod,
            "success": launchSuccess
        ], runId: taskContext.runId)

        if !launchSuccess {
            DeskJigLog.debug(.restorationExecutor, "Chrome launch failed", fields: [
                "taskId": taskContext.taskId,
                "success": false,
                "chromeMethod": strategy.chromeMethod.rawValue,
                "actualMethod": actualMethod
            ], runId: taskContext.runId)
            return false
        }

        DeskJigLog.debug(.restorationPlanner, "Waiting for Chrome window to appear", fields: ["taskId": taskContext.taskId], runId: taskContext.runId)
        await Task.sleepUnlessCancelled(for: .milliseconds(800))

        let postLaunchCaptures = chromeMatcher.captureOpenWindows()
        let selectedCapture = chromeMatcher.selectPostLaunchCapture(
            from: postLaunchCaptures,
            preLaunchCaptures: chromeAppleScriptCaptures,
            targetProfile: profileDisplayName,
            profileDirectory: profileDir,
            taskContext: taskContext
        )

        var matchedSnapshotWindow: SnapshotWindow? = nil
        if let capture = selectedCapture {
            let postLaunchSnapshot = await SystemSnapshotCapture.captureQuick(
                runId: strategyManager.currentRunId ?? "ui-single"
            )
            let chromeCandidates = postLaunchSnapshot.windows.filter { $0.bundleId == window.bundleIdentifier }
            matchedSnapshotWindow = chromeMatcher.matchSnapshotWindow(for: capture, candidates: chromeCandidates)
        }

        let chromeWindowHandle: WindowHandle?
        if let matchedSnapshotWindow {
            chromeWindowHandle = chromeMatcher.resolveHandle(
                snapshotWindow: matchedSnapshotWindow,
                chromeState: window.chromeState
            )
        } else if let chromeApp = App.find(bundleID: window.bundleIdentifier) {
            chromeWindowHandle = chromeApp.firstWindow()
            DeskJigLog.debug(.restorationPlanner, "Falling back to first Chrome window", fields: [
                "taskId": taskContext.taskId,
                "reason": "No post-launch capture match",
                "found": chromeWindowHandle != nil
            ], runId: taskContext.runId)
        } else {
            chromeWindowHandle = nil
        }

        guard let chromeWindow = chromeWindowHandle else {
            DeskJigLog.debug(.restorationExecutor, "Chrome window not found after launch", fields: ["taskId": taskContext.taskId, "success": false], runId: taskContext.runId)
            return false
        }

        DeskJigLog.debug(.restorationPlanner, "Chrome window found", fields: [
            "taskId": taskContext.taskId,
            "found": true,
            "captureProfile": selectedCapture?.profileAppleScriptName ?? "none",
            "matchedWindowId": matchedSnapshotWindow.map { "\($0.windowId)" } ?? "none"
        ], runId: taskContext.runId)

        DeskJigLog.debug(.restorationPositioning, "Positioning Chrome window", fields: [
            "taskId": taskContext.taskId,
            "frame": targetFrame
        ], runId: taskContext.runId)

        chromeWindow.setFrame(targetFrame)?.raise()?.activate()

        if let chromeState = window.chromeState,
           chromeState.shouldRestoreTabs,
           !chromeState.savedTabURLs.isEmpty {
            let targetUrls = chromeState.savedTabURLs
            let tabRestoreStartTime = Date()

            if let chromeWindowId = selectedCapture?.chromeWindowId {
                ChromeAutomationService.openMissingTabs(targetUrls, inWindowWithChromeId: chromeWindowId)

                if let focusedIndex = chromeState.focusedTabIndex {
                    ChromeAutomationService.setActiveTab(index: focusedIndex, inWindowWithChromeId: chromeWindowId)
                }
            } else if let frame = chromeWindow.frame {
                ChromeAutomationService.openMissingTabs(targetUrls, inWindowWithBounds: frame)

                if let focusedIndex = chromeState.focusedTabIndex {
                    ChromeAutomationService.setActiveTab(index: focusedIndex, inWindowWithBounds: frame)
                }
            }

            let tabRestoreDurationMs = Int(Date().timeIntervalSince(tabRestoreStartTime) * 1000)
            DeskJigLog.debug(.restorationChrome, "Post-launch tab restoration complete", fields: [
                "taskId": taskContext.taskId,
                "durationMs": tabRestoreDurationMs,
                "method": selectedCapture?.chromeWindowId == nil ? "bounds" : "chromeWindowId"
            ], runId: taskContext.runId)
        }

        DeskJigLog.debug(.restorationPositioning, "Chrome positioned", fields: ["taskId": taskContext.taskId, "success": true], runId: taskContext.runId)
        DeskJigLog.debug(.restorationExecutor, "Chrome restoration complete", fields: ["taskId": taskContext.taskId, "success": true], runId: taskContext.runId)
        return true
    }

    // MARK: - Helpers

    private func globalMaxY(for screens: [NSScreen]) -> CGFloat {
        let maxY = screens.map { $0.frame.maxY }.max()
        if let maxY {
            return maxY
        }
        return NSScreen.main?.frame.maxY ?? 0
    }

    /// Determine which screen index a frame is primarily on based on center point
    private func screenIndexForFrame(_ frame: CGRect) -> Int {
        let screens = NSScreen.screens
        let centerPoint = CGPoint(x: frame.midX, y: frame.midY)

        for (index, screen) in screens.enumerated() {
            if screen.frame.contains(centerPoint) {
                return index
            }
        }
        return 0
    }

    private func visibleFrameInWindowCoordinates(for screen: NSScreen, globalMaxY: CGFloat) -> CGRect {
        let windowY = globalMaxY - screen.visibleFrame.maxY
        return CGRect(
            x: screen.visibleFrame.origin.x,
            y: windowY,
            width: screen.visibleFrame.width,
            height: screen.visibleFrame.height
        )
    }

    /// Restore tabs using Chrome native messaging API
    private func restoreTabsViaNativeMessaging(
        urls: [String],
        windowId: Int?,
        taskContext: RestorationTaskContext
    ) async {
        guard let service = ChromeNativeMessagingServiceHolder.shared, service.isConnected else {
            DeskJigLog.debug(.restorationChrome, "Native messaging not available, skipping", fields: [
                "taskId": taskContext.taskId,
                "reason": "ChromeNativeMessagingServiceHolder.shared is nil or not connected"
            ], runId: taskContext.runId)
            return
        }

        let api = ChromeNativeMessagingAPI(service: service)

        // Get target window ID - either passed in or query the focused window
        var targetWindowId = windowId
        if targetWindowId == nil {
            do {
                if let focusedWindow = try await api.focusedWindow() {
                    targetWindowId = focusedWindow.id
                    DeskJigLog.debug(.restorationChrome, "Using focused Chrome window for native tab creation", fields: [
                        "taskId": taskContext.taskId,
                        "focusedWindowId": focusedWindow.id,
                        "focusedWindowTabCount": focusedWindow.tabs.count
                    ], runId: taskContext.runId)
                } else {
                    DeskJigLog.debug(.restorationChrome, "No focused Chrome window found", fields: [
                        "taskId": taskContext.taskId,
                        "reason": "focusedWindow() returned nil"
                    ], runId: taskContext.runId)
                }
            } catch {
                DeskJigLog.debug(.restorationChrome, "Failed to query focused window", fields: [
                    "taskId": taskContext.taskId,
                    "error": error.localizedDescription
                ], runId: taskContext.runId)
            }
        }

        guard let finalWindowId = targetWindowId else {
            DeskJigLog.debug(.restorationChrome, "Cannot create tabs via native messaging - no window ID", fields: [
                "taskId": taskContext.taskId,
                "reason": "No windowId provided and couldn't find focused window"
            ], runId: taskContext.runId)
            return
        }

        do {
            let currentTabs = try await api.tabs(forWindowId: finalWindowId)

            let missingUrls = urls.filter { url in
                !currentTabs.contains { tab in
                    ChromeAutomationService.urlsAreEquivalent(url, tab.url)
                }
            }

            if missingUrls.isEmpty {
                DeskJigLog.debug(.restorationChrome, "All tabs already open (native)", fields: [
                    "taskId": taskContext.taskId,
                    "currentCount": currentTabs.count,
                    "savedCount": urls.count
                ], runId: taskContext.runId)
                return
            }

            DeskJigLog.debug(.restorationChrome, "Opening missing tabs (native)", fields: [
                "taskId": taskContext.taskId,
                "missingCount": missingUrls.count,
                "windowId": finalWindowId
            ], runId: taskContext.runId)

            var openedCount = 0
            var failedCount = 0
            for url in missingUrls {
                do {
                    _ = try await api.createTab(url: url, windowId: finalWindowId, active: false)
                    openedCount += 1
                } catch {
                    failedCount += 1
                    DeskJigLog.debug(.restorationChrome, "Failed to create tab via native messaging", fields: [
                        "taskId": taskContext.taskId,
                        "url": String(url.prefix(50)),
                        "error": error.localizedDescription
                    ], runId: taskContext.runId)
                }
            }

            DeskJigLog.debug(.restorationChrome, "Native tab restoration finished", fields: [
                "taskId": taskContext.taskId,
                "openedCount": openedCount,
                "failedCount": failedCount
            ], runId: taskContext.runId)
        } catch {
            DeskJigLog.debug(.restorationChrome, "Native messaging failed", fields: [
                "taskId": taskContext.taskId,
                "error": error.localizedDescription
            ], runId: taskContext.runId)
        }
    }

}