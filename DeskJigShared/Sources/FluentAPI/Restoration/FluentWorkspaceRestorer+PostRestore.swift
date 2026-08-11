//  FluentWorkspaceRestorer+PostRestore.swift
//  DeskJigShared

import Foundation
import CoreGraphics
import AppKit

extension FluentWorkspaceRestorer {

    struct HideAppStats: Sendable {
        let pid: pid_t
        let bundleId: String
        let appName: String
        let hideMethod: String
        let hideRequestSuccess: Bool
        let isHiddenConfirmed: Bool           // NSRunningApplication.isHidden
        let visibleWindowCount: Int           // CGWindowList on-screen windows remaining
        let durationMs: Int                   // Time from hide request to verification
    }

    struct HideAllStats: Sendable {
        let totalDurationMs: Int
        let appsTargeted: Int
        let appsHidden: Int
        let appsFailed: Int
        let appsSkipped: Int                  // Already hidden
        let waitIterations: Int
        let finalPendingCount: Int            // Apps still not fully hidden
        let postHideVisibleWindowCount: Int   // Total on-screen windows after hide
        let perAppStats: [HideAppStats]

        /// Initialize from AppHideUtility's HideAllResult
        init(from result: HideAllResult) {
            self.totalDurationMs = result.durationMs
            self.appsTargeted = result.appsTargeted
            self.appsHidden = result.appsHidden
            self.appsFailed = result.appsFailed
            self.appsSkipped = result.appsSkipped
            self.waitIterations = 0
            self.finalPendingCount = 0
            self.postHideVisibleWindowCount = 0
            self.perAppStats = result.perAppResults.map { appResult in
                HideAppStats(
                    pid: appResult.pid,
                    bundleId: appResult.bundleId,
                    appName: appResult.appName,
                    hideMethod: appResult.method,
                    hideRequestSuccess: appResult.success,
                    isHiddenConfirmed: appResult.success,
                    visibleWindowCount: 0,
                    durationMs: 0
                )
            }
        }
    }

    struct UnhideStats: Sendable {
        let totalDurationMs: Int
        let appsTargeted: Int
        let appsUnhidden: Int
        let appsAlreadyVisible: Int
        let appsNotRunning: Int
    }

    /// Unhide apps belonging to the target workspace that may have been hidden from a previous restoration.
    /// This ensures windows are visible and can be matched during the restoration phases.
    nonisolated static func unhideWorkspaceApps(
        workspace: Workspace,
        runId: String
    ) async -> UnhideStats {
        let startTime = Date()
        let workspaceBundleIds = Set(workspace.windows.map { $0.bundleIdentifier })

        DeskJigLog.debug(.restorationTrace, "Unhide workspace apps start", fields: [
            "workspaceAppCount": "\(workspaceBundleIds.count)",
            "bundleIds": workspaceBundleIds.joined(separator: ", ")
        ], runId: runId)

        let result = await MainActor.run { () -> (unhidden: Int, alreadyVisible: Int, notRunning: Int) in
            let runningApps = NSWorkspace.shared.runningApplications
            var unhidden = 0
            var alreadyVisible = 0
            var notRunning = 0

            for bundleId in workspaceBundleIds {
                // Find ALL running processes for this bundle ID (there can be multiple)
                let matchingApps = runningApps.filter { $0.bundleIdentifier == bundleId }

                if matchingApps.isEmpty {
                    notRunning += 1
                    continue
                }

                // Unhide each matching process
                for app in matchingApps {
                    if app.isHidden {
                        if app.unhide() {
                            unhidden += 1
                            DeskJigLog.debug(.restorationTrace, "Unhid app for workspace", fields: [
                                "app": app.localizedName ?? bundleId,
                                "bundleId": bundleId,
                                "pid": "\(app.processIdentifier)"
                            ], runId: runId)
                        }
                    } else {
                        alreadyVisible += 1
                    }
                }
            }

            return (unhidden, alreadyVisible, notRunning)
        }

        let durationMs = Int(Date().timeIntervalSince(startTime) * 1000)

        DeskJigLog.debug(.restorationTrace, "Unhide workspace apps complete", fields: [
            "durationMs": "\(durationMs)",
            "unhidden": "\(result.unhidden)",
            "alreadyVisible": "\(result.alreadyVisible)",
            "notRunning": "\(result.notRunning)"
        ], runId: runId)

        return UnhideStats(
            totalDurationMs: durationMs,
            appsTargeted: workspaceBundleIds.count,
            appsUnhidden: result.unhidden,
            appsAlreadyVisible: result.alreadyVisible,
            appsNotRunning: result.notRunning
        )
    }

    /// Pre-validates app availability and fires callback for missing apps.
    nonisolated func validateAndNotifyMissingApps(
        workspace: Workspace,
        onMissingAppDetected: (@MainActor @Sendable (String, String) -> Void)?,
        runId: String
    ) async {
        // Use provided callback or fall back to static default
        let effectiveCallback = onMissingAppDetected ?? Self.defaultMissingAppCallback

        var checkedBundleIds = Set<String>()

        for window in workspace.windows {
            let bundleId = window.bundleIdentifier

            // Skip if already checked
            guard !checkedBundleIds.contains(bundleId) else { continue }
            checkedBundleIds.insert(bundleId)

            // Skip if app is currently running
            if !NSRunningApplication.runningApplications(withBundleIdentifier: bundleId).isEmpty {
                continue
            }

            // Check if app exists
            let appAvailable = Self.isAppAvailableStatic(bundleId: bundleId, applicationPath: window.applicationPath)

            if !appAvailable {
                DeskJigLog.debug(.restorationTrace, "Missing app detected during pre-validation", fields: [
                    "app": window.appName,
                    "bundleId": bundleId,
                    "savedPath": window.applicationPath ?? "none",
                    "hasCallback": effectiveCallback != nil ? "true" : "false"
                ], runId: runId)

                if let callback = effectiveCallback {
                    DeskJigLog.debug(.restorationTrace, "Invoking missing app callback", fields: [
                        "app": window.appName,
                        "bundleId": bundleId
                    ], runId: runId)
                    await callback(window.appName, bundleId)
                    DeskJigLog.debug(.restorationTrace, "Missing app callback completed", fields: [
                        "app": window.appName
                    ], runId: runId)
                }
            }
        }
    }

    private nonisolated static func isAppAvailableStatic(bundleId: String, applicationPath: String?) -> Bool {
        if let appPath = applicationPath {
            if FileManager.default.fileExists(atPath: appPath) {
                return true
            }
        }

        if let appUrl = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) {
            if FileManager.default.fileExists(atPath: appUrl.path) {
                return true
            }
        }

        return false
    }

    struct PostRestoreAuthoritativeBundles: Sendable, Equatable {
        let bundlesWithNewLaunch: Set<String>
        let bundlesWithTmuxSwitch: Set<String>
        let bundlesWithAuthoritativeRestore: Set<String>
        let tmuxPreparedTerminalBundles: Set<String>
        let hasSuccessfulTmuxSwitch: Bool
    }

    static func resolvePostRestoreAuthoritativeBundles(
        taskResults: [TaskResult],
        bundleByWindowId: [CGWindowID: String],
        tmuxPreparedTerminalWindowsById: [UUID: WorkspaceWindow]
    ) -> PostRestoreAuthoritativeBundles {
        var bundlesWithNewLaunch = Set<String>()
        var bundlesWithTmuxSwitch = Set<String>()

        for taskResult in taskResults where taskResult.success {
            if let terminalBinding = taskResult.terminalBinding {
                if terminalBinding.wasLaunched {
                    bundlesWithNewLaunch.insert(terminalBinding.bundleId)
                } else if terminalBinding.sessionName != nil {
                    bundlesWithTmuxSwitch.insert(terminalBinding.bundleId)
                }
            } else if case .openNewWithPath(let bundleId, _, _) = taskResult.decision {
                bundlesWithNewLaunch.insert(bundleId)
            }
            if case .switchTmuxSession = taskResult.decision {
                if let windowId = taskResult.windowId,
                   let bundleId = bundleByWindowId[windowId] {
                    bundlesWithTmuxSwitch.insert(bundleId)
                } else if let plannedWindowId = taskResult.plannedWindowId,
                          let bundleId = bundleByWindowId[plannedWindowId] {
                    bundlesWithTmuxSwitch.insert(bundleId)
                }
            }
        }

        let tmuxPreparedTerminalBundles = Set(
            tmuxPreparedTerminalWindowsById.values
                .filter { $0.tmuxState != nil && BundleRegistry.isTerminal($0.bundleIdentifier) }
                .map(\.bundleIdentifier)
        )
        bundlesWithTmuxSwitch.formUnion(tmuxPreparedTerminalBundles)

        let hasSuccessfulTmuxSwitch = taskResults.contains { taskResult in
            guard taskResult.success else { return false }
            if case .switchTmuxSession = taskResult.decision {
                return true
            }
            return false
        }

        if bundlesWithTmuxSwitch.isEmpty && hasSuccessfulTmuxSwitch {
            // Fallback for runs where tmux switch succeeded but snapshot mapping didn't resolve
            // (rare AX timing/capture gaps). Use tmux-prepared windows rather than workspace
            // definitions because tmux state is injected during preparation.
            let terminalBundles = Set(
                tmuxPreparedTerminalWindowsById.values
                    .filter { BundleRegistry.isTerminal($0.bundleIdentifier) }
                    .map(\.bundleIdentifier)
            )
            bundlesWithTmuxSwitch.formUnion(terminalBundles)
        }

        let bundlesWithAuthoritativeRestore = bundlesWithNewLaunch.union(bundlesWithTmuxSwitch)
        return PostRestoreAuthoritativeBundles(
            bundlesWithNewLaunch: bundlesWithNewLaunch,
            bundlesWithTmuxSwitch: bundlesWithTmuxSwitch,
            bundlesWithAuthoritativeRestore: bundlesWithAuthoritativeRestore,
            tmuxPreparedTerminalBundles: tmuxPreparedTerminalBundles,
            hasSuccessfulTmuxSwitch: hasSuccessfulTmuxSwitch
        )
    }

    func postRestore(
        result: RestorationResult,
        runId: String,
        workspace: Workspace,
        snapshot: SystemSnapshot,
        options: RestorationOptions,
        tmuxPreparedTerminalWindowsById: [UUID: WorkspaceWindow],
        deferredReflowWindowIds: Set<CGWindowID> = []
    ) async {
        DeskJigLog.debug(.restorationTrace, "Post-restore start", fields: [
            "runId": runId,
            "workspaceName": workspace.name,
            "windowCount": "\(workspace.windows.count)"
        ])

        // Capture fresh snapshot with updated window frames after restoration positioning.
        // The passed-in snapshot has stale frame data from before windows were moved,
        // which causes Window.find(windowId:) to match wrong windows by frame similarity.
        DeskJigLog.debug(.restorationTrace, "Capturing fresh snapshot for post-restore", fields: ["runId": runId])
        var freshSnapshot = await SystemSnapshotCapture.captureQuickOnScreenOnly(runId: runId)
        let workspaceHasXcodeWindows = workspace.windows.contains { $0.bundleIdentifier == OpenByPathBundleIdentifiers.xcode }
        let xcodeIDESupplementationService = workspaceHasXcodeWindows ? IDESupplementationService() : nil
        if workspaceHasXcodeWindows {
            if let xcodeIDESupplementationService {
                freshSnapshot = await xcodeIDESupplementationService.supplementIDEWindows(
                    in: freshSnapshot,
                    method: options.ideFetchMethod,
                    runId: runId,
                    bundleAllowlist: Set([OpenByPathBundleIdentifiers.xcode])
                )
            }
            DeskJigLog.debug(.restorationTrace, "Post-restore Xcode path supplementation complete", fields: [
                "runId": runId,
                "bundleId": OpenByPathBundleIdentifiers.xcode
            ])
        }

        let displayManager = DisplayManager()
        displayManager.refreshScreens()
        displayManager.screens = WorkspaceDisplayTopology.effectiveScreens(from: displayManager)
        let zOrderService = WorkspaceZOrderService(displayManager: displayManager)

        if workspaceHasXcodeWindows,
           let initialTopology = zOrderService.xcodeCoverageTopology(
            workspaceWindows: workspace.windows,
            snapshot: freshSnapshot
           ),
           !initialTopology.isComplete,
           let missingPathSlot = initialTopology.missingPathSlots.first {
            DeskJigLog.debug(.restorationTrace, "Xcode path coverage incomplete after supplementation (fail closed)", fields: [
                "runId": runId,
                "reason": XcodeIdentityTraceReason.pathConfirmedSelectionAmbiguous.rawValue,
                "expectedPathSlots": initialTopology.expectedPathSlots.joined(separator: " | "),
                "observedPathSlots": initialTopology.observedPathSlots.joined(separator: " | "),
                "missingPathSlots": initialTopology.missingPathSlots.joined(separator: " | "),
                "duplicatePathSlots": initialTopology.duplicatePathSlots.joined(separator: " | ")
            ])

            let bootstrapContext = RestorationTaskContext(
                taskId: "postrestore-xcode-bootstrap",
                taskType: .ide,
                runId: runId
            )
            let xcodeLauncher = FluentXcodeLauncher()
            do {
                let bootstrapResult = try await xcodeLauncher.launch(
                    directory: missingPathSlot,
                    title: nil,
                    task: bootstrapContext
                )
                DeskJigLog.debug(.restorationTrace, "Xcode missing-slot bootstrap launch attempted", fields: [
                    "runId": runId,
                    "missingPathSlot": missingPathSlot,
                    "success": "\(bootstrapResult.success)",
                    "method": bootstrapResult.method.rawValue
                ])
            } catch {
                DeskJigLog.debug(.restorationTrace, "Xcode missing-slot bootstrap launch failed", fields: [
                    "runId": runId,
                    "missingPathSlot": missingPathSlot,
                    "error": error.localizedDescription
                ])
            }

            await Task.sleepUnlessCancelled(for: .milliseconds(700))
            freshSnapshot = await SystemSnapshotCapture.captureQuickOnScreenOnly(runId: runId)
            if let xcodeIDESupplementationService {
                freshSnapshot = await xcodeIDESupplementationService.supplementIDEWindows(
                    in: freshSnapshot,
                    method: options.ideFetchMethod,
                    runId: runId,
                    bundleAllowlist: Set([OpenByPathBundleIdentifiers.xcode])
                )
            }

            if let postBootstrapTopology = zOrderService.xcodeCoverageTopology(
                workspaceWindows: workspace.windows,
                snapshot: freshSnapshot
            ) {
                DeskJigLog.debug(.restorationTrace, "Xcode path coverage topology after bootstrap retry", fields: [
                    "runId": runId,
                    "expectedPathSlots": postBootstrapTopology.expectedPathSlots.joined(separator: " | "),
                    "observedPathSlots": postBootstrapTopology.observedPathSlots.joined(separator: " | "),
                    "missingPathSlots": postBootstrapTopology.missingPathSlots.joined(separator: " | "),
                    "duplicatePathSlots": postBootstrapTopology.duplicatePathSlots.joined(separator: " | ")
                ])
            }
        }

        // Collect ALL restored window IDs (Chrome, terminals, IDEs) to protect from post-restore cleanup.
        // This prevents the flicker where a workspace window is minimized by cleanup, then restored
        // by z-order enforcement, then minimized again (as seen with explicitly managed iTerm windows).
        var protectedWindowIds = Set<CGWindowID>()

        let bundleByWindowId: [CGWindowID: String] = Dictionary(
            uniqueKeysWithValues: freshSnapshot.windows.compactMap { snapshotWindow in
                guard let bundleId = snapshotWindow.bundleId else { return nil }
                return (snapshotWindow.windowId, bundleId)
            }
        )
        for taskResult in result.taskResults where taskResult.success {
            if let windowId = taskResult.windowId {
                protectedWindowIds.insert(windowId)
            }
            if let finalWindowId = taskResult.terminalBinding?.finalWindowId {
                protectedWindowIds.insert(finalWindowId)
            }
            if let selectedWindowId = taskResult.terminalBinding?.selectedWindowId {
                protectedWindowIds.insert(selectedWindowId)
            }
            // Also protect the originally planned window when a fallback selected
            // a different one (e.g. tmux cross-terminal fallback). This prevents
            // the planned window from being minimized during post-restore cleanup.
            if let plannedWindowId = taskResult.plannedWindowId {
                protectedWindowIds.insert(plannedWindowId)
            }
        }

        // Protect windows that were positioned by deferred terminal reflow.
        // These windows (e.g., iTerm side-effect windows) aren't in task results
        // but were explicitly placed by the reflow pass and should not be minimized.
        protectedWindowIds.formUnion(deferredReflowWindowIds)

        let authoritativeBundles = Self.resolvePostRestoreAuthoritativeBundles(
            taskResults: result.taskResults,
            bundleByWindowId: bundleByWindowId,
            tmuxPreparedTerminalWindowsById: tmuxPreparedTerminalWindowsById
        )
        let bundlesWithNewLaunch = authoritativeBundles.bundlesWithNewLaunch
        let bundlesWithTmuxSwitch = authoritativeBundles.bundlesWithTmuxSwitch
        let bundlesWithAuthoritativeRestore = authoritativeBundles.bundlesWithAuthoritativeRestore

        DeskJigLog.trace(
            .restorationPostRestore,
            "RC10_DIAG postrestore-authoritative-bundles tmuxPrepared=\(authoritativeBundles.tmuxPreparedTerminalBundles.sorted().joined(separator: ",")) tmuxSwitch=\(bundlesWithTmuxSwitch.sorted().joined(separator: ",")) newLaunch=\(bundlesWithNewLaunch.sorted().joined(separator: ",")) authoritative=\(bundlesWithAuthoritativeRestore.sorted().joined(separator: ","))",
            runId: runId
        )

        if !protectedWindowIds.isEmpty {
            DeskJigLog.debug(.restorationTrace, "Protecting restored windows from cleanup", fields: [
                "runId": runId,
                "protectedCount": "\(protectedWindowIds.count)",
                "protectedWindowIds": protectedWindowIds.map { "\($0)" }.joined(separator: ","),
                "bundlesWithNewLaunch": bundlesWithNewLaunch.sorted().joined(separator: ","),
                "bundlesWithTmuxSwitch": bundlesWithTmuxSwitch.sorted().joined(separator: ","),
                "bundlesWithAuthoritativeRestore": bundlesWithAuthoritativeRestore.sorted().joined(separator: ","),
                "tmuxPreparedTerminalBundles": authoritativeBundles.tmuxPreparedTerminalBundles.sorted().joined(separator: ","),
                "freshSnapshotBundleMapCount": "\(bundleByWindowId.count)"
            ])
        }

        let needsZOrderAdjustments = zOrderService.needsZOrderAdjustments(
            snapshot: freshSnapshot,
            workspaceWindows: workspace.windows,
            workspaceScreens: workspace.screens
        )

        if !needsZOrderAdjustments {
            DeskJigLog.debug(.restorationTrace, "Post-restore occlusion-driven z-order adjustments skipped (no occlusion detected)", fields: [
                "runId": runId
            ])
        }

        // Freeze compositor so Phases 0-3 (z-order enforcement) appear atomic.
        // All window raise/activate/minimize operations are batched and flushed at once
        // when we reenable, eliminating visible per-window flickering.
        let skylightService = SkyLightService.shared
        skylightService.disableCompositorUpdates()

        // Phase 0: Aggressively minimize non-matching windows from open-by-path apps
        // This cleans up windows that apps restore from their previous sessions
        // We use the fresh snapshot which has updated frame positions after restoration
        DeskJigLog.debug(.restorationTrace, "Phase 0: minimizeNonMatchingOpenByPathWindows", fields: [
            "runId": runId,
            "protectedCount": "\(protectedWindowIds.count)",
            "authoritativeBundles": bundlesWithAuthoritativeRestore.sorted().joined(separator: ",")
        ])
        zOrderService.minimizeNonMatchingOpenByPathWindows(
            workspaceWindows: workspace.windows,
            snapshot: freshSnapshot,
            runId: runId,
            protectedWindowIds: protectedWindowIds,
            bundlesWithAuthoritativeRestore: bundlesWithAuthoritativeRestore
        )

        DeskJigLog.debug(.restorationTrace, "Phase 1: validateOpenPathWindows", fields: [
            "runId": runId,
            "windowCount": "\(workspace.windows.count)",
            "authoritativeBundles": bundlesWithAuthoritativeRestore.sorted().joined(separator: ",")
        ])
        zOrderService.validateOpenPathWindows(
            workspace: workspace,
            workspaceWindows: workspace.windows,
            bundlesWithAuthoritativeRestore: bundlesWithAuthoritativeRestore,
            protectedWindowIds: protectedWindowIds
        )

        if needsZOrderAdjustments {
            DeskJigLog.debug(.restorationTrace, "Phase 2: ensureWorkspaceWindowsOnTop", fields: [
                "runId": runId,
                "windowCount": "\(workspace.windows.count)"
            ])

            let (didAdjustZOrder, phase2HandledWindowIds) = await withCheckedContinuation { continuation in
                zOrderService.ensureWorkspaceWindowsOnTop(
                    runId: runId,
                    workspaceWindows: workspace.windows,
                    workspaceScreens: workspace.screens,
                    shouldMinimizeWindowsInFront: false,
                    forceRaiseWorkspaceWindows: false,
                    preCapturedSnapshot: freshSnapshot
                ) { didAdjust, handledIds in
                    continuation.resume(returning: (didAdjust, handledIds))
                }
            }

            DeskJigLog.debug(.restorationTrace, "Phase 2: ensureWorkspaceWindowsOnTop complete", fields: [
                "runId": runId,
                "didAdjust": "\(didAdjustZOrder)",
                "handledWindowIds": "\(phase2HandledWindowIds.count)"
            ])

            // Only enforce topmost when Phase 2 found windows that needed z-order correction.
            // If Phase 2 reported no adjustments, all workspace windows are already correctly
            // positioned and a full re-enumeration would be redundant (~370ms of AX calls).
            // When Phase 3 does run, skip windows already handled by Phase 2 to avoid
            // redundant AX calls (~45ms per window).
            if didAdjustZOrder {
                DeskJigLog.debug(.restorationTrace, "Phase 3: enforceTopmostForWorkspaceWindows", fields: [
                    "runId": runId,
                    "windowCount": "\(workspace.windows.count)",
                    "didAdjustZOrder": "\(didAdjustZOrder)",
                    "alreadyHandledCount": "\(phase2HandledWindowIds.count)"
                ])
                zOrderService.enforceTopmostForWorkspaceWindows(
                    workspaceWindows: workspace.windows,
                    workspaceScreens: workspace.screens,
                    alreadyRaisedWindowIds: phase2HandledWindowIds
                )
            } else {
                DeskJigLog.debug(.restorationTrace, "Phase 3 skipped (Phase 2 found no adjustments needed)", fields: [
                    "runId": runId
                ])
            }
        } else {
            DeskJigLog.debug(.restorationTrace, "Phase 2/3 skipped (no occlusion); continuing cleanup/minimize phases", fields: [
                "runId": runId
            ])
        }

        // Flush all batched z-order operations from Phases 0-3 at once.
        skylightService.reenableCompositorUpdates()

        DeskJigLog.debug(.restorationTrace, "Phase 4: minimizeNonWorkspaceWindows", fields: [
            "runId": runId,
            "protectedCount": "\(protectedWindowIds.count)",
            "authoritativeBundles": bundlesWithAuthoritativeRestore.sorted().joined(separator: ",")
        ])
        zOrderService.minimizeNonWorkspaceWindows(
            workspaceWindows: workspace.windows,
            snapshot: freshSnapshot,
            runId: runId,
            workspaceScreens: workspace.screens,
            protectedWindowIds: protectedWindowIds,
            bundlesWithAuthoritativeRestore: bundlesWithAuthoritativeRestore
        )

        // Phase 5: Hide visible non-workspace apps (after workspace windows are restored)
        // This completes the hybrid hiding strategy - background apps were hidden early,
        // now we hide the visible non-workspace apps after restoration is complete.
        if options.hideAllAppsBeforeRestore {
            DeskJigLog.debug(.restorationTrace, "Phase 5: hideVisibleNonWorkspaceApps", fields: ["runId": runId])

            let workspaceBundleIds = Set(workspace.windows.map { $0.bundleIdentifier })
            let visibleHideOptions = HideAllOptions(
                workspaceBundleIds: workspaceBundleIds,
                minWindowSize: CGSize(width: 100, height: 100),
                verbose: true,
                backgroundOnlyMode: false
            )

            let hideResult = await AppHideUtility.hideAllApps(options: visibleHideOptions, runId: runId)

            DeskJigLog.debug(.restorationTrace, "Phase 5: hideVisibleNonWorkspaceApps complete", fields: [
                "runId": runId,
                "appsHidden": "\(hideResult.appsHidden)",
                "durationMs": "\(hideResult.durationMs)"
            ])
        }

        await logPostRestoreVisibility(workspace: workspace, runId: runId)

        DeskJigLog.debug(.restorationTrace, "Post-restore complete", fields: ["runId": runId, "success": "\(result.success)"])
    }

    private func logPostRestoreVisibility(workspace: Workspace, runId: String) async {
        let workspaceCounts = Dictionary(grouping: workspace.windows, by: { $0.bundleIdentifier })
            .mapValues { $0.count }

        let bundleIds = Set(workspace.windows.map(\.bundleIdentifier))
        var hiddenApps: [(name: String, bundleId: String)] = []

        for bundleId in bundleIds {
            let appState = await MainActor.run { () -> (name: String, pid: pid_t?, isHidden: Bool, isRunning: Bool) in
                if let app = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == bundleId }) {
                    return (app.localizedName ?? bundleId, app.processIdentifier, app.isHidden, true)
                }
                return (bundleId, nil, false, false)
            }

            let unexpectedlyHidden = appState.isRunning && appState.isHidden
            if unexpectedlyHidden {
                hiddenApps.append((name: appState.name, bundleId: bundleId))
            }
        }

        if hiddenApps.isEmpty {
            DeskJigLog.debug(.restorationTrace, "Post-restore: all \(bundleIds.count) workspace apps visible", runId: runId)
        } else {
            for app in hiddenApps {
                DeskJigLog.debug(.restorationTrace, "Post-restore app unexpectedly hidden", fields: [
                    "app": app.name,
                    "bundleId": app.bundleId,
                    "workspaceWindows": "\(workspaceCounts[app.bundleId] ?? 0)"
                ], runId: runId)
            }
        }
    }
}
