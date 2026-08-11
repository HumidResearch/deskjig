//  FluentWorkspaceRestorer.swift
//  DeskJigShared

import Foundation
import CoreGraphics
import AppKit

// MARK: - Fluent Workspace Restorer

/// Main orchestrator for Fluent API-based workspace restoration.
///
/// `FluentWorkspaceRestorer` coordinates the entire restoration process:
/// 1. Capture system snapshot
/// 2. Build restoration plan with window matching
/// 3. Acquire locks for conflict prevention
/// 4. Execute restoration tasks in parallel
/// 5. Release locks and generate results
///
/// ## Overview
///
/// This is the primary entry point for restoring workspaces using the
/// Fluent API lock system. It replaces the older handler-based restoration
/// system with a more efficient, parallel approach.
///
/// The restorer uses:
/// - ``WindowLockManager`` for conflict prevention
/// - ``EnhancedSnapshot`` for efficient window matching
/// - ``RestorationPlanBuilder`` for task creation
/// - ``RestorationExecutor`` for parallel execution
///
/// ## Example
///
/// ```swift
/// // Basic usage
/// let result = try await FluentWorkspaceRestorer.shared.restore(
///     workspace: myWorkspace
/// )
///
/// // With custom options
/// let result = try await FluentWorkspaceRestorer.shared.restore(
///     workspace: myWorkspace,
///     options: .fast
/// )
///
/// // Check results
/// if result.success {
///     print("Restored \(result.windowsRestored) windows in \(result.totalDurationMs)ms")
/// } else {
///     print("Failed to restore \(result.windowsFailed) windows")
/// }
/// ```
///
/// ## See Also
/// - ``FluentRestorationResult``
/// - ``RestorationOptions``
/// - ``WindowLockManager``
public actor FluentWorkspaceRestorer {

    // MARK: - Properties

    let lockManager: WindowLockManager
    private var isCancelled = false

    /// Internal result type that includes the mapped workspace for verification
    private struct RestorationAttemptResult {
        let result: FluentRestorationResult
        let mappedWorkspace: Workspace
        let launchedChromeProfiles: Set<String>
        /// Screen topology captured at the start of the attempt, reused for verification
        /// (monitors do not change mid-restore) so evaluateRestoration need not re-fetch (fwr-02).
        let currentScreens: [FullScreenInfo]
    }

    /// Shared instance for convenience.
    public static let shared = FluentWorkspaceRestorer()

    /// Default callback for missing app detection.
    /// This is used as a fallback when RestorationOptions doesn't specify a callback.
    /// Set this at app startup (e.g., in DeskJigApp.init) to ensure toast notifications
    /// are shown for missing apps regardless of which code path triggers restoration.
    public static var defaultMissingAppCallback: (@MainActor @Sendable (String, String) -> Void)?
    static let quickSwitchLaunchSource = "quick-switch"

    // MARK: - Initialization

    /// Creates a new workspace restorer.
    ///
    /// - Parameter lockTimeout: Default timeout for lock acquisition
    public init(lockTimeout: Duration = .seconds(10)) {
        self.lockManager = WindowLockManager(defaultTimeout: lockTimeout)
    }

    private nonisolated static func decodeBooleanPreferenceValue(_ value: Any?) -> Bool? {
        switch value {
        case let bool as Bool:
            return bool
        case let number as NSNumber:
            return number.boolValue
        case let string as String:
            switch string.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "1", "true", "yes", "on":
                return true
            case "0", "false", "no", "off":
                return false
            default:
                return nil
            }
        default:
            return nil
        }
    }

    private func resolveBooleanPreference(_ key: String, defaultValue: Bool = false)
        -> (value: Bool, source: String, standardValue: Bool?, helperPerUserValue: Bool?, appValue: Bool?)
    {
        let standardValue = Self.decodeBooleanPreferenceValue(UserDefaults.standard.object(forKey: key))
        let perUserDefaults = PerUserDefaultsManager.shared
        let helperPerUserValue = Self.decodeBooleanPreferenceValue(perUserDefaults.object(forKey: key))
        let appDefaults = UserDefaults.standard.persistentDomain(forName: BundleIdentity.defaultsSuiteName) ?? [:]
        let appValue = Self.decodeBooleanPreferenceValue(appDefaults[key])

        if let helperPerUserValue {
            return (helperPerUserValue, "helperPerUser", standardValue, helperPerUserValue, appValue)
        }
        if let appValue {
            return (appValue, "appDomain", standardValue, helperPerUserValue, appValue)
        }
        if let standardValue {
            return (standardValue, "standard", standardValue, helperPerUserValue, appValue)
        }

        return (defaultValue, "default", standardValue, helperPerUserValue, appValue)
    }

    // MARK: - Restoration

    /// Restores a workspace using the Fluent API system.
    ///
    /// This is the main entry point for workspace restoration. It:
    /// 1. Captures a system snapshot
    /// 2. Analyzes the workspace and creates restoration tasks
    /// 3. Acquires locks for conflict prevention
    /// 4. Executes tasks in parallel
    /// 5. Returns detailed results
    ///
    /// - Parameters:
    ///   - workspace: The workspace to restore
    ///   - options: Restoration options (defaults to `.default`)
    ///   - screenMappings: Optional mapping from workspace screen indices to current screen indices
    ///
    /// - Returns: Detailed restoration result
    ///
    /// - Throws: If restoration cannot proceed (e.g., cancelled)
    ///
    /// ## Example
    ///
    /// ```swift
    /// do {
    ///     let result = try await FluentWorkspaceRestorer.shared.restore(
    ///         workspace: workspace,
    ///         options: .default
    ///     )
    ///
    ///     if result.success {
    ///         print("Success! Restored \(result.windowsRestored) windows")
    ///     }
    /// } catch {
    ///     print("Restoration failed: \(error)")
    /// }
    /// ```
    public func restore(
        workspace: Workspace,
        options: RestorationOptions = .default,
        displayAssignments: [WorkspaceDisplayAssignment] = [],
        screenMappings: [(workspaceScreenIndex: Int, currentScreenIndex: Int)] = [],
        runId: String? = nil
    ) async throws -> FluentRestorationResult {
        let resolvedRunId = runId ?? Self.makeRunId()
        var currentAttempt = 0
        var finalResult: FluentRestorationResult?
        var launchedChromeProfiles: Set<String> = []

        while currentAttempt <= options.maxRetries {
            let attemptRunId = currentAttempt == 0 ? resolvedRunId : "\(resolvedRunId)_retry_\(currentAttempt)"

            if currentAttempt > 0 {
                DeskJigLog.debug(.restorationTrace, "Starting retry attempt \(currentAttempt)", runId: attemptRunId)
            }

            let attemptResult = try await performRestorationAttempt(
                workspace: workspace,
                options: options,
                displayAssignments: displayAssignments,
                screenMappings: screenMappings,
                runId: attemptRunId,
                previouslyLaunchedChromeProfiles: launchedChromeProfiles
            )
            launchedChromeProfiles.formUnion(attemptResult.launchedChromeProfiles)
            let result = attemptResult.result

            // Evaluate if we need a retry - use mappedWorkspace to only verify windows
            // that were actually intended to be restored (after screen filtering)
            let evaluation = await evaluateRestoration(
                workspace: attemptResult.mappedWorkspace,
                screenMappings: screenMappings,
                result: result,
                currentScreens: attemptResult.currentScreens,
                runId: attemptRunId
            )
            await lockManager.clearClampedFrames(for: attemptRunId)
            await lockManager.clearPositionedFrames(for: attemptRunId)

            // Create a final result object with the evaluation attached
            let resultWithEvaluation = FluentRestorationResult(
                success: result.success && evaluation.isPerfect,
                runId: result.runId,
                totalDurationMs: result.totalDurationMs,
                windowsRestored: result.windowsRestored,
                windowsFailed: result.windowsFailed,
                windowsSkipped: result.windowsSkipped,
                plan: result.plan,
                taskResults: result.taskResults,
                snapshotDurationMs: result.snapshotDurationMs,
                planDurationMs: result.planDurationMs,
                executeDurationMs: result.executeDurationMs,
                evaluation: evaluation
            )

            finalResult = resultWithEvaluation

            if evaluation.isPerfect {
                DeskJigLog.debug(.restorationTrace, "Restoration perfect after \(currentAttempt) retries", runId: attemptRunId)
                TraceFileWriter.shared.complete(success: true, windowCount: resultWithEvaluation.windowsRestored)
                return resultWithEvaluation
            }

            if currentAttempt >= options.maxRetries {
                DeskJigLog.debug(.restorationTrace, "Restoration completed with issues after max retries (\(currentAttempt))", fields: ["issues": evaluation.issues.joined(separator: "; ")], runId: attemptRunId)
                TraceFileWriter.shared.complete(success: resultWithEvaluation.success, windowCount: resultWithEvaluation.windowsRestored)
                return resultWithEvaluation
            }

            currentAttempt += 1
            DeskJigLog.debug(.restorationTrace, "Restoration not perfect, triggering retry", fields: ["issues": evaluation.issues.joined(separator: "; ")], runId: attemptRunId)
        }

        // This path should not normally be reached as the loop exits via returns above
        if let result = finalResult {
            TraceFileWriter.shared.complete(success: result.success, windowCount: result.windowsRestored)
        }
        return finalResult!
    }

    public func prepareRestore(
        workspace: Workspace,
        mode: WorkspaceRestorePreparationMode,
        displayAssignments: [WorkspaceDisplayAssignment] = [],
        screenMappings: [(workspaceScreenIndex: Int, currentScreenIndex: Int)] = []
    ) async throws -> WorkspaceRestorePreparationResult {
        let currentScreens = await getCurrentScreens()
        return try WorkspaceDisplayResolutionService.prepare(
            workspace: workspace,
            currentScreens: currentScreens,
            mode: mode,
            explicitAssignments: displayAssignments,
            legacyScreenMappings: screenMappings
        )
    }

    private func performRestorationAttempt(
        workspace: Workspace,
        options: RestorationOptions,
        displayAssignments: [WorkspaceDisplayAssignment],
        screenMappings: [(workspaceScreenIndex: Int, currentScreenIndex: Int)],
        runId: String,
        previouslyLaunchedChromeProfiles: Set<String> = []
    ) async throws -> RestorationAttemptResult {
        isCancelled = false
        let startTime = Date()
        let resolvedRunId = runId
        let shouldSetRunId = WorkspaceManager.currentRestoreRunId == nil
        if shouldSetRunId {
            WorkspaceManager.currentRestoreRunId = resolvedRunId
        }
        defer {
            if shouldSetRunId {
                WorkspaceManager.currentRestoreRunId = nil
            }
        }

        // Start logging
        TraceFileWriter.shared.start(runId: resolvedRunId)

        DeskJigLog.debug(.restorationTrace, "Starting Fluent restoration for \(workspace.name) with \(workspace.windows.count) windows", fields: ["runId": resolvedRunId])

        let currentScreens = await getCurrentScreens()
        DeskJigLog.debug(.restorationTrace, "Current screens fetched", fields: [
            "runId": resolvedRunId,
            "screenCount": "\(currentScreens.count)"
        ])

        let preparation = try WorkspaceDisplayResolutionService.prepare(
            workspace: workspace,
            currentScreens: currentScreens,
            mode: options.preparationMode,
            explicitAssignments: displayAssignments,
            legacyScreenMappings: screenMappings
        )

        let preparationContext: ResolvedWorkspaceRestoreContext
        switch preparation {
        case .ready(let context):
            preparationContext = context
        case .requiresAssignment:
            throw RestorationError.assignmentRequired(
                "Workspace '\(workspace.name)' requires display-slot assignment before restore"
            )
        }

        let mappedWorkspace = preparationContext.resolvedWorkspace
        if let workspaceScreens = preparationContext.normalizedWorkspace.screens, !workspaceScreens.isEmpty {
            DeskJigLog.debug(.restorationTrace, "Workspace saved screens", fields: [
                "runId": resolvedRunId,
                "screens": Self.describe(workspaceScreens: workspaceScreens)
            ])
        }
        DeskJigLog.debug(.restorationTrace, "Runtime current screens", fields: [
            "runId": resolvedRunId,
            "screens": Self.describe(currentScreens: currentScreens)
        ])

        let workspaceBundleIds = Set(mappedWorkspace.windows.map(\.bundleIdentifier))
        let hasChromeWindows = mappedWorkspace.windows.contains { isChromeBundleId($0.bundleIdentifier) }
        let hasIDEWindows = mappedWorkspace.windows.contains { BundleRegistry.isIDE($0.bundleIdentifier) }

        // TCC permission pre-check: ensure async onboarding warmup has completed before any AppleScript work
        if hasChromeWindows {
            let tccVerified = ChromeAutomationService.verifyTCCPermission()
            DeskJigLog.debug(.restorationTrace, "TCC permission pre-check", fields: [
                "runId": resolvedRunId,
                "tccVerified": "\(tccVerified)",
                "hasChromeWindows": "true"
            ])
            if !tccVerified {
                DeskJigLog.warn(.restorationChrome, "TCC permission not verified before Chrome restoration — AppleScript calls may fail")
            }
        }

        let wantsChromeTabUrlsForMatching = options.chromeMatchMethod == .chromeTabUrls || mappedWorkspace.windows.contains { window in
            guard isChromeBundleId(window.bundleIdentifier) else { return false }
            return (window.chromeState?.profileMatchMode ?? .specific) == .anyWindow
        }

        // Capturing full Chrome tab state is expensive; only do it when matching actually needs tab URLs.
        // If Chrome supplementation is enabled, prefer that source and skip snapshot tab capture to avoid duplication.
        let includeChromeCapture = options.includeChromeCapture &&
            hasChromeWindows &&
            wantsChromeTabUrlsForMatching &&
            options.chromeFetchMethod == .disabled
        let includeAXEnrichment = options.includeAXEnrichment && (hasIDEWindows || hasChromeWindows)

        // Phase 1: Capture snapshot
        let snapshotStartTime = Date()
        let baseSnapshot = await SystemSnapshotCapture.capture(
            runId: resolvedRunId,
            includeChromeCapture: includeChromeCapture,
            includeAXEnrichment: includeAXEnrichment,
            axEnrichmentBundleAllowlist: workspaceBundleIds,
            axAccessibilityBundleAllowlist: workspaceBundleIds
        )
        let baseEnhancedSnapshot = EnhancedSnapshot.from(baseSnapshot)
        let postRestoreSnapshotStore = PostRestoreSnapshotStore(baseSnapshot: baseSnapshot)
        let snapshotDurationMs = Int(Date().timeIntervalSince(snapshotStartTime) * 1000)

        DeskJigLog.debug(.restorationTrace, "Snapshot captured: \(baseEnhancedSnapshot.windowCount) windows, \(baseEnhancedSnapshot.displays.count) displays", fields: ["durationMs": "\(snapshotDurationMs)"])

        guard !isCancelled else {
            throw RestorationError.cancelled
        }

        // Phase 2.5: Unhide workspace apps that may have been hidden from previous restoration
        let unhideStats = await Self.unhideWorkspaceApps(
            workspace: mappedWorkspace,
            runId: resolvedRunId
        )

        // Phase 2.6: Hide BACKGROUND-ONLY apps BEFORE restoration
        // Only hides apps that have no visible windows >= 100x100 (menu bar utilities, etc.)
        // Visible non-workspace apps are hidden AFTER restoration completes (Phase 5 in postRestore)
        let hideAllStats: HideAllStats?
        if options.hideAllAppsBeforeRestore {
            let result = await AppHideUtility.hideAllApps(options: .backgroundOnly, runId: resolvedRunId)
            hideAllStats = HideAllStats(from: result)
            DeskJigLog.debug(.restorationTrace, "Hide background-only apps complete", fields: [
                "appsHidden": "\(result.appsHidden)",
                "appsFailed": "\(result.appsFailed)",
                "appsSkipped": "\(result.appsSkipped)",
                "durationMs": "\(result.durationMs)"
            ], runId: resolvedRunId)
        } else {
            hideAllStats = nil
        }

        // Phase 2.7: Pre-validate app availability and notify for missing apps
        await validateAndNotifyMissingApps(
            workspace: mappedWorkspace,
            onMissingAppDetected: options.onMissingAppDetected,
            runId: resolvedRunId
        )

        // Phase 3: Partition windows
        let partitions = partitionWindows(mappedWorkspace.windows)
        DeskJigLog.debug(.restorationTrace, "Windows partitioned for phased restoration", fields: [
            "otherCount": "\(partitions.other.count)",
            "slowStartCount": "\(partitions.slowStarts.count)",
            "terminalCount": "\(partitions.terminals.count)",
            "ideCount": "\(partitions.ides.count)",
            "chromeCount": "\(partitions.chromes.count)"
        ])
        // We need AppleScript Chrome window IDs for tab operations even when we skip full tab capture.
        let shouldCaptureChrome = !partitions.chromes.isEmpty
        let includeTabURLsInChromeCaptures = wantsChromeTabUrlsForMatching && options.chromeFetchMethod == .disabled

        func normalizeOpenPath(_ path: String?) -> String? {
            guard let path else { return nil }
            let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            let expanded = (trimmed as NSString).expandingTildeInPath
            return URL(fileURLWithPath: expanded).standardizedFileURL.path
        }

        func openPathBasenameTokens(for windows: [WorkspaceWindow]) -> Set<String> {
            Set(windows.compactMap { window in
                guard let path = normalizeOpenPath(window.openPath) else { return nil }
                let basename = URL(fileURLWithPath: path).lastPathComponent
                return basename.isEmpty ? nil : basename.lowercased()
            })
        }

        // Phase 3.5: tmux session setup
        // If tmux is available and workspace has terminals, set up tmux mode
        let tmuxCommandService = TmuxCommandService()
        let tmuxSessionManager: TmuxSessionManager?
        let tmuxClientWindowMap: [pid_t: CGWindowID]
        let tmuxClients: [TmuxClientInfo]
        let tmuxEnabledTerminalWindows: [WorkspaceWindow]
        let tmuxPreparedTerminalWindowsById: [UUID: WorkspaceWindow]

        let hasTerminals = !partitions.terminals.isEmpty
        let tmuxPreference = resolveBooleanPreference("tmuxEnabled")
        let tmuxUserEnabled = tmuxPreference.value
        let tmuxIsAvailable = hasTerminals && tmuxUserEnabled
            ? await tmuxCommandService.isAvailable
            : false

        if hasTerminals && tmuxIsAvailable {
            let manager = TmuxSessionManager(commandService: tmuxCommandService)
            tmuxSessionManager = manager

            // Ensure sessions exist for all terminal windows
            let updatedWindows = await manager.ensureSessionsForWorkspace(
                mappedWorkspace,
                launchSource: options.launchSource,
                runId: resolvedRunId
            )
            let preparedTerminalWindows = updatedWindows.filter {
                BundleRegistry.isTerminal($0.bundleIdentifier)
            }
            tmuxPreparedTerminalWindowsById = Dictionary(
                uniqueKeysWithValues: preparedTerminalWindows.map { ($0.id, $0) }
            )
            tmuxEnabledTerminalWindows = preparedTerminalWindows.filter { $0.tmuxState != nil }

            // Capture tmux clients and map them to physical windows
            tmuxClients = await manager.listClients()
            tmuxClientWindowMap = await manager.mapClientsToWindows(snapshot: baseSnapshot)
            let managedTmuxWindowCount = baseSnapshot.windows.filter {
                BundleRegistry.isTerminal($0.bundleId ?? "") &&
                $0.title?.contains(BundleRegistry.managedTmuxWindowTitle) == true
            }.count

            DeskJigLog.debug(.restorationTrace, "tmux mode enabled", fields: [
                "tmuxSessionsCount": "\(tmuxEnabledTerminalWindows.count)",
                "tmuxClientsCount": "\(tmuxClients.count)",
                "tmuxClientWindowMapCount": "\(tmuxClientWindowMap.count)",
                "managedTmuxWindowCount": "\(managedTmuxWindowCount)"
            ], runId: resolvedRunId)
        } else {
            tmuxSessionManager = nil
            tmuxClientWindowMap = [:]
            tmuxClients = []
            tmuxEnabledTerminalWindows = []
            let clearedTerminalWindows = mappedWorkspace.windows
                .filter { BundleRegistry.isTerminal($0.bundleIdentifier) }
                .map { $0.withTmuxState(nil) }
            tmuxPreparedTerminalWindowsById = Dictionary(
                uniqueKeysWithValues: clearedTerminalWindows.map { ($0.id, $0) }
            )

            if hasTerminals && !tmuxUserEnabled {
                DeskJigLog.debug(.restorationTrace, "tmux disabled by user preference, using managed-title fallback", runId: resolvedRunId)
            } else if hasTerminals {
                DeskJigLog.debug(.restorationTrace, "tmux not available, using managed-title fallback", runId: resolvedRunId)
            }
        }

        // Phase 4: Start supplementation tasks
        let terminalSupplementationTask: Task<SystemSnapshot, Never>? = {
            guard !partitions.terminals.isEmpty else { return nil }
            let bundleAllowlist = Set(partitions.terminals.map(\.bundleIdentifier))
            let windowsToSupplement = baseSnapshot.windows.filter { window in
                guard let bundleId = window.bundleId else { return false }
                return bundleAllowlist.contains(bundleId)
            }
            guard !windowsToSupplement.isEmpty else { return nil }
            let snapshotForSupplementation = SupplementationSnapshotMerger.supplementationSnapshot(from: baseSnapshot, windows: windowsToSupplement)
            return Task.detached {
                let service = TerminalSupplementationService()
                return await service.supplementTerminalWindows(
                    in: snapshotForSupplementation,
                    method: options.terminalFetchMethod,
                    runId: resolvedRunId
                )
            }
        }()

        let ideSupplementationTask: Task<SystemSnapshot, Never>? = {
            guard !partitions.ides.isEmpty else { return nil }

            let bundleAllowlist = Set(partitions.ides.map(\.bundleIdentifier))
            let tokens = openPathBasenameTokens(for: partitions.ides)

            // IDE supplementation is by far the most expensive; filter aggressively to likely candidates.
            // If we can't derive any tokens, skip to avoid scanning every IDE window on the system.
            guard !tokens.isEmpty else { return nil }

            let windowsToSupplement = baseSnapshot.windows.filter { window in
                guard let bundleId = window.bundleId, bundleAllowlist.contains(bundleId) else { return false }
                guard let title = window.title?.lowercased(), !title.isEmpty else { return false }
                return tokens.contains(where: { title.contains($0) })
            }

            guard !windowsToSupplement.isEmpty else { return nil }
            let snapshotForSupplementation = SupplementationSnapshotMerger.supplementationSnapshot(from: baseSnapshot, windows: windowsToSupplement)

            return Task.detached {
                let service = IDESupplementationService()
                return await service.supplementIDEWindows(
                    in: snapshotForSupplementation,
                    method: options.ideFetchMethod,
                    runId: resolvedRunId
                )
            }
        }()

        let chromeSupplementationTask: Task<SystemSnapshot, Never>? = {
            guard !partitions.chromes.isEmpty else { return nil }
            // If we already have AX enrichment and we don't need tab URLs for matching, skip Chrome supplementation.
            guard wantsChromeTabUrlsForMatching || !includeAXEnrichment else { return nil }

            return Task.detached {
                let service = ChromeSupplementationService()
                return await service.supplementChromeWindows(
                    in: baseSnapshot,
                    method: options.chromeFetchMethod,
                    includeTabUrls: wantsChromeTabUrlsForMatching,
                    runId: resolvedRunId
                )
            }
        }()

        let executorConfig = RestorationExecutorConfig(
            lockTimeout: options.lockTimeout,
            useWindowLocks: true,
            terminalFetchMethod: options.terminalFetchMethod,
            ideFetchMethod: options.ideFetchMethod,
            chromeMatchMethod: options.chromeMatchMethod,
            launchSource: options.launchSource,
            previouslyLaunchedChromeProfiles: previouslyLaunchedChromeProfiles
        )
        let deterministicPositioningEnabled = options.deterministicPositioningForClampCompensation
        let mappedWindowScreenIndices = mappedWorkspace.windows.compactMap(\.screenIndex)
        let mappedWindowCount = mappedWorkspace.windows.count
        let executionProfile = Self.resolveExecutionProfile(
            deterministicPositioningEnabled: deterministicPositioningEnabled,
            requestedPhaseExecutionMode: options.phaseExecutionMode,
            requestedMaxConcurrency: options.maxConcurrency,
            mappedWindowCount: mappedWindowCount,
            mappedWindowScreenIndices: mappedWindowScreenIndices,
            hasTerminalWindows: !partitions.terminals.isEmpty,
            hasIDEWindows: !partitions.ides.isEmpty,
            launchSource: options.launchSource
        )
        let singleTargetFastPathEnabled = executionProfile.singleTargetFastPathEnabled
        let sharedConcurrency = executionProfile.sharedConcurrency
        let phaseExecutionMode = executionProfile.phaseExecutionMode
        let mappedTargetScreens = Set(mappedWindowScreenIndices).sorted()
        let laneCoordinator = DisplayLaneCoordinator(
            targetScreenIndices: mappedTargetScreens,
            perLaneConcurrency: sharedConcurrency
        )

        let phaseExecutionModeLabel: String = {
            switch phaseExecutionMode {
            case .automatic:
                return "automatic"
            case .sequential:
                return "sequential"
            case .parallel:
                return "parallel"
            }
        }()

        let executionDiagData: [String: String] = [
            "deterministicPositioning": "\(deterministicPositioningEnabled)",
            "mappedWindowCount": "\(mappedWindowCount)",
            "mappedWindowScreenIndexCount": "\(mappedWindowScreenIndices.count)",
            "targetScreenCardinality": "\(executionProfile.targetScreenCardinality)",
            "targetScreens": mappedTargetScreens.map(String.init).joined(separator: ","),
            "hasTerminalPhase": "\(!partitions.terminals.isEmpty)",
            "hasIDEPhase": "\(!partitions.ides.isEmpty)",
            "enabled": "\(singleTargetFastPathEnabled)",
            "reason": executionProfile.reason,
            "mode": phaseExecutionModeLabel,
            "concurrency": "\(sharedConcurrency)"
        ]
        let executionDiagFields = executionDiagData
            .sorted(by: { $0.key < $1.key })
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: " ")
        DeskJigLog.trace(
            .restorationExecutor,
            "RC10_DIAG single-target-fast-path-\(singleTargetFastPathEnabled ? "enabled" : "disabled") \(executionDiagFields)",
            runId: resolvedRunId
        )

        DeskJigLog.debug(.restorationTrace, "Phase execution mode: \(phaseExecutionModeLabel)", fields: [
            "runId": resolvedRunId,
            "maxConcurrency": "\(sharedConcurrency)",
            "deterministicPositioning": "\(deterministicPositioningEnabled)",
            "singleTargetFastPath": "\(singleTargetFastPathEnabled)"
        ])
        DeskJigLog.debug(.restorationTrace, "Lane scheduler configured", fields: [
            "runId": resolvedRunId,
            "laneMode": "per-display",
            "targetScreens": mappedTargetScreens.map(String.init).joined(separator: ","),
            "perLaneConcurrency": "\(sharedConcurrency)"
        ])

        // Global concurrency must be perLane × screenCount so that lanes
        // on different displays can saturate in parallel.  For single-display
        // this is a no-op (multiplied by 1).
        let globalConcurrency = sharedConcurrency * max(1, mappedTargetScreens.count)

        func makeExecutor() -> RestorationExecutor {
            RestorationExecutor(
                lockManager: lockManager,
                maxConcurrency: globalConcurrency,
                taskTimeout: options.taskTimeout,
                config: executorConfig,
                laneCoordinator: laneCoordinator,
                tmuxCommandService: tmuxSessionManager != nil ? tmuxCommandService : nil
            )
        }

        func captureChromeWindowsIfNeeded() async -> [ChromeAppleScriptWindowCapture] {
            guard shouldCaptureChrome else { return [] }

            let captureStart = Date()
            let includeTabURLs = includeTabURLsInChromeCaptures
            let captures: [ChromeAppleScriptWindowCapture]
            if AppleScriptRunner.shouldUseOsascript {
                captures = ChromeAutomationService.captureOpenWindows(includeTabURLs: includeTabURLs)
            } else {
                captures = await MainActor.run {
                    ChromeAutomationService.captureOpenWindows(includeTabURLs: includeTabURLs)
                }
            }
            let durationMs = Int(Date().timeIntervalSince(captureStart) * 1000)

            DeskJigLog.debug(.restorationTrace, "AppleScript captures complete", fields: [
                "count": "\(captures.count)",
                "durationMs": "\(durationMs)",
                "deferred": "true",
                "includeTabURLs": "\(includeTabURLs)"
            ])
            if !captures.isEmpty {
                DeskJigLog.debug(.restorationTrace, "AppleScript Chrome window details", fields: [
                    "count": "\(captures.count)",
                    "windows": ChromeWindowMatcher.formatCapturesForTrace(captures)
                ])
            }

            return captures
        }

        // Phase 5: Restore non-terminal, non-IDE, non-Chrome, non-slowStart windows
        let otherWorkspace = workspaceForPhase(
            base: mappedWorkspace,
            windows: partitions.other
        )
        let slowStartWorkspace = workspaceForPhase(
            base: mappedWorkspace,
            windows: partitions.slowStarts
        )
        let terminalWorkspace = workspaceForPhase(
            base: mappedWorkspace,
            windows: partitions.terminals
        )
        let ideWorkspace = workspaceForPhase(
            base: mappedWorkspace,
            windows: partitions.ides
        )
        let chromeWorkspace = workspaceForPhase(
            base: mappedWorkspace,
            windows: partitions.chromes
        )

        func runOtherPhase() async -> PhaseExecutionResult {
            await executePhase(
                phaseName: "other",
                runId: resolvedRunId,
                workspace: otherWorkspace,
                snapshot: baseEnhancedSnapshot,
                currentScreens: currentScreens,
                resolvedWindowTargets: preparationContext.windowTargetsByWindowID,
                options: options,
                chromeCaptures: [],
                executor: makeExecutor()
            )
        }

        // Run slowStart phase using polling logic
        func runSlowStartPhase() async -> PhaseExecutionResult {
            let pollingPhaseName = "slowStart"
            let slowStartWindowCount = slowStartWorkspace.windows.count
            let pollingTimeoutMs = slowStartWindowCount >= 3 ? 12_000 : 8_000
            let pollIntervalMs = 300
            
            // Build initial plan (just to get the tasks/windows)
            guard !slowStartWorkspace.windows.isEmpty else {
                // Return empty result if no slowStart windows
                return await executePhase(
                    phaseName: pollingPhaseName,
                    runId: resolvedRunId,
                    workspace: slowStartWorkspace,
                    snapshot: baseEnhancedSnapshot,
                    currentScreens: currentScreens,
                    resolvedWindowTargets: preparationContext.windowTargetsByWindowID,
                    options: options,
                    chromeCaptures: [],
                    executor: makeExecutor()
                )
            }

            DeskJigLog.debug(.restorationTrace, "Phase \(pollingPhaseName): Starting polling execution", fields: [
                "windowCount": "\(slowStartWindowCount)",
                "timeoutMs": "\(pollingTimeoutMs)",
                "pollIntervalMs": "\(pollIntervalMs)"
            ])

            let initialPlan = await RestorationPlanBuilder(runId: resolvedRunId)
                .forWorkspace(slowStartWorkspace)
                .withSnapshot(baseEnhancedSnapshot)
                .withLockManager(lockManager)
                .withLockTimeout(options.lockTimeout)
                .withCurrentScreens(currentScreens)
                .withResolvedWindowTargets(preparationContext.windowTargetsByWindowID)
                .withMatchConfiguration(options.matchConfiguration)
                .analyze()
                .acquireLocks()
                .build()

            if !initialPlan.readyTasks.isEmpty {
                DeskJigLog.debug(.restorationTrace, "Phase \(pollingPhaseName): Found ready tasks in base snapshot", fields: [
                    "readyCount": "\(initialPlan.readyTasks.count)"
                ])
                return await executePlan(
                    phaseName: pollingPhaseName,
                    plan: initialPlan,
                    executor: makeExecutor()
                )
            } else {
                let locksToRelease = initialPlan.tasks.compactMap { $0.lock }
                for lock in locksToRelease {
                    await lockManager.releaseLock(lock)
                }
            }

            // Polling loop
            let pollingTimeout = Date().addingTimeInterval(Double(pollingTimeoutMs) / 1000.0)
            let pollIntervalNs: UInt64 = UInt64(pollIntervalMs) * 1_000_000

            while Date() < pollingTimeout {
                if isCancelled { break }

                // Capture quick snapshot
                let pollSnapshot = await SystemSnapshotCapture.captureQuick(runId: resolvedRunId)
                let pollEnhanced = EnhancedSnapshot.from(pollSnapshot)

                // Try to build plan with current snapshot
                let plan = await RestorationPlanBuilder(runId: resolvedRunId)
                    .forWorkspace(slowStartWorkspace)
                    .withSnapshot(pollEnhanced)
                    .withLockManager(lockManager)
                    .withLockTimeout(options.lockTimeout)
                    .withCurrentScreens(currentScreens)
                    .withResolvedWindowTargets(preparationContext.windowTargetsByWindowID)
                    .withMatchConfiguration(options.matchConfiguration)
                    .analyze()
                    .acquireLocks() // Only acquires if window found
                    .build()

                // Execute any ready tasks (windows found)
                if !plan.readyTasks.isEmpty {
                    DeskJigLog.debug(.restorationTrace, "Phase \(pollingPhaseName): Found ready tasks during poll", fields: [
                        "readyCount": "\(plan.readyTasks.count)"
                    ])

                    // Use executePlan to avoid rebuilding and losing locks
                    return await executePlan(
                        phaseName: pollingPhaseName,
                        plan: plan,
                        executor: makeExecutor()
                    )
                }

                // If not found yet, wait and retry
                guard await Task.sleepUnlessCancelled(nanoseconds: pollIntervalNs) else { break }
            }

            // Cancelled mid-poll: do not fall into the timeout path below, which
            // would still launch/restore windows. Return a neutral empty result.
            if isCancelled || Task.isCancelled {
                DeskJigLog.debug(.restorationTrace, "Phase \(pollingPhaseName): Cancelled during polling", fields: [
                    "windowCount": "\(slowStartWindowCount)"
                ])
                return PhaseExecutionResult(
                    phaseName: pollingPhaseName,
                    plan: initialPlan,
                    result: RestorationResult(
                        runId: resolvedRunId,
                        success: false,
                        totalDurationMs: 0,
                        successCount: 0,
                        failureCount: 0,
                        skippedCount: slowStartWindowCount,
                        taskResults: []
                    ),
                    planDurationMs: 0,
                    executeDurationMs: 0
                )
            }

            // Timeout reached - attempt one final execution (will likely fail/launch new)
            DeskJigLog.debug(.restorationTrace, "Phase \(pollingPhaseName): Polling timeout reached", fields: [
                "elapsedMs": "\(pollingTimeoutMs)"
            ])
            return await executePhase(
                phaseName: pollingPhaseName,
                runId: resolvedRunId,
                workspace: slowStartWorkspace,
                snapshot: baseEnhancedSnapshot,
                currentScreens: currentScreens,
                resolvedWindowTargets: preparationContext.windowTargetsByWindowID,
                options: options,
                chromeCaptures: [],
                executor: makeExecutor()
            )
        }

        func scheduleTerminalCleanupIfNeeded() {
            let bundlesToCleanup = [
                OpenByPathBundleIdentifiers.iterm2
            ]

            // Terminal.app: close windows WITHOUT managed titles. Poll until at least
            // one managed title appears (confirms tmux title propagation complete),
            // then close the remaining non-managed windows.
            let terminalWindowCount = terminalWorkspace.windows.filter {
                $0.bundleIdentifier == OpenByPathBundleIdentifiers.terminal
            }.count
            if terminalWindowCount > 0 {
                Task.detached(priority: .utility) {
                    // Poll up to 10s waiting for managed titles to appear in Terminal.app
                    let checkScript = """
                    tell application "Terminal"
                        set managedCount to 0
                        repeat with w in every window
                            repeat with t in tabs of w
                                try
                                    if custom title of t contains "\(BundleIdentity.terminalTitleTokenPrefix):tmux:managed" then
                                        set managedCount to managedCount + 1
                                    end if
                                end try
                            end repeat
                        end repeat
                        return managedCount
                    end tell
                    """
                    for _ in 0..<10 {
                        // Cancelled: abort the cleanup entirely rather than falling
                        // through to the window-closing script below.
                        guard await Task.sleepUnlessCancelled(nanoseconds: 1_000_000_000) else { return }
                        let checkResult = AppleScriptRunner.runOsascript(checkScript, timeout: 2.0)
                        let managedCount = Int(checkResult.trimmedOutput) ?? 0
                        if managedCount >= terminalWindowCount { break }
                    }

                    let script = """
                    tell application "Terminal"
                        set closedCount to 0
                        repeat with w in every window
                            set hasManaged to false
                            repeat with t in tabs of w
                                try
                                    set ct to custom title of t
                                    if ct contains "\(BundleIdentity.terminalTitleTokenPrefix):tmux:managed" then
                                        set hasManaged to true
                                    end if
                                end try
                            end repeat
                            if hasManaged is false then
                                set isBusy to false
                                repeat with t in tabs of w
                                    try
                                        if busy of t is true then set isBusy to true
                                    end try
                                end repeat
                                if isBusy is false then
                                    close w
                                    set closedCount to closedCount + 1
                                end if
                            end if
                        end repeat
                        return closedCount
                    end tell
                    """
                    let result = AppleScriptRunner.runOsascript(script, timeout: 4.0)
                    let closedCount = Int(result.trimmedOutput) ?? 0
                    if closedCount > 0 {
                        DeskJigLog.debug(.restorationTrace, "Terminal.app default window cleanup", fields: [
                            "closed": "\(closedCount)"
                        ], runId: resolvedRunId)
                    }
                }
            }

            let windowsByBundle = Dictionary(grouping: terminalWorkspace.windows) {
                $0.bundleIdentifier
            }

            for bundleId in bundlesToCleanup {
                guard let windows = windowsByBundle[bundleId],
                      !windows.isEmpty else { continue }

                let preExistingCount = baseSnapshot.windows(forBundleID: bundleId).count

                // When tmux sessions are in use, avoid generic managed-title cleanup and
                // run duplicate-aware idle-only cleanup against managed indexed titles.
                // Note: check tmuxPreparedTerminalWindowsById (not the original
                // workspace windows) because tmuxState is injected during the
                // tmux preparation phase, not saved in the workspace definition.
                let hasTmuxWindows = windows.contains { window in
                    tmuxPreparedTerminalWindowsById[window.id]?.tmuxState != nil
                }
                if hasTmuxWindows {
                    let tmuxWindowCount = windows.filter {
                        tmuxPreparedTerminalWindowsById[$0.id]?.tmuxState != nil
                    }.count
                    let expectedManagedTitles = (0..<tmuxWindowCount).map {
                        BundleRegistry.managedTmuxWindowTitle(bundleId: bundleId, index: $0)
                    }

                    DeskJigLog.debug(.restorationTrace, "Skip terminal cleanup (tmux sessions)", fields: [
                        "bundleId": bundleId,
                        "preExistingWindowCount": "\(preExistingCount)",
                        "tmuxWindowCount": "\(tmuxWindowCount)",
                        "cleanupMode": "duplicate-aware-idle-only"
                    ], runId: resolvedRunId)

                    if !expectedManagedTitles.isEmpty {
                        Task.detached(priority: .utility) {
                            // Wait for tmux pane titles to propagate to Terminal.app tab
                            // custom titles before checking. Without this delay, the cleanup
                            // can close managed windows whose titles haven't been set yet.
                            guard await Task.sleepUnlessCancelled(nanoseconds: 3_000_000_000) else { return }
                            _ = FluentTerminalLauncher.closeExtraWindowsIfIdle(
                                bundleId: bundleId,
                                expectedTitles: expectedManagedTitles,
                                runId: resolvedRunId
                            )
                        }
                    }
                    continue
                }

                let expectedTitles = windows
                    .map { $0.windowTitle }
                    .filter { $0.hasPrefix("\(BundleIdentity.terminalTitleTokenPrefix):") }

                guard !expectedTitles.isEmpty else { continue }

                DeskJigLog.debug(.restorationTrace, "Scheduling terminal cleanup", fields: [
                    "bundleId": bundleId,
                    "preExistingWindowCount": "\(preExistingCount)",
                    "expectedTitleCount": "\(expectedTitles.count)"
                ], runId: resolvedRunId)

                Task.detached(priority: .utility) {
                    guard await Task.sleepUnlessCancelled(nanoseconds: 3_000_000_000) else { return }
                    _ = FluentTerminalLauncher.closeExtraWindowsIfIdle(
                        bundleId: bundleId,
                        expectedTitles: expectedTitles,
                        runId: resolvedRunId
                    )
                }
            }
        }

        // Phase 6: Wait for terminal supplementation and restore terminals
        func runTerminalPhase() async -> PhaseExecutionResult {
            let terminalSnapshot = await awaitSupplementation(
                task: terminalSupplementationTask,
                fallback: baseSnapshot,
                runId: resolvedRunId,
                label: "terminal",
                timeout: .seconds(6)
            )
            await postRestoreSnapshotStore.recordTerminal(snapshot: terminalSnapshot)
            let mergedSnapshot = SupplementationSnapshotMerger.mergeSupplementationSnapshot(base: baseSnapshot, overlay: terminalSnapshot)
            let terminalEnhancedSnapshot = EnhancedSnapshot.from(mergedSnapshot)

            // Always apply tmux preparation results for Ghostty windows.
            // This both injects ensured tmux state and clears stale tmux state
            // when we need to fall back to non-tmux restoration.
            let updatedWindows = terminalWorkspace.windows.map { window -> WorkspaceWindow in
                if let tmuxPreparedWindow = tmuxPreparedTerminalWindowsById[window.id] {
                    return tmuxPreparedWindow
                }
                return window
            }
            let effectiveTerminalWorkspace = workspaceForPhase(
                base: terminalWorkspace,
                windows: updatedWindows
            )
            let iTermWindowTTYBindings = fetchITermWindowTTYBindings(runId: resolvedRunId)
            let tmuxTerminalRestoreContext = TmuxTerminalRestoreContext.initial(
                workspaceWindows: effectiveTerminalWorkspace.windows,
                preparedTerminalWindowsById: tmuxPreparedTerminalWindowsById,
                snapshot: terminalEnhancedSnapshot,
                tmuxClients: tmuxClients,
                tmuxClientWindowMap: tmuxClientWindowMap,
                iTermWindowTTYBindings: iTermWindowTTYBindings
            )

            let result = await executePhase(
                phaseName: "terminal",
                runId: resolvedRunId,
                workspace: effectiveTerminalWorkspace,
                snapshot: terminalEnhancedSnapshot,
                currentScreens: currentScreens,
                resolvedWindowTargets: preparationContext.windowTargetsByWindowID,
                options: options,
                chromeCaptures: [],
                executor: makeExecutor(),
                tmuxSessionManager: tmuxSessionManager,
                tmuxClientWindowMap: tmuxClientWindowMap,
                tmuxClients: tmuxClients,
                tmuxTerminalRestoreContext: tmuxTerminalRestoreContext
            )
            if options.launchSource == Self.quickSwitchLaunchSource,
               let tmuxSessionManager {
                // Build client PID → bundle ID map so reconciliation only rebinds
                // clients within the same bundle (prevents Terminal.app clients from
                // being switched to Ghostty sessions when crossing workspaces).
                let snapshotWindows = terminalEnhancedSnapshot.base.windows
                let windowBundleMap = Dictionary(
                    snapshotWindows.compactMap { w -> (CGWindowID, String)? in
                        guard let bundleId = w.bundleId else { return nil }
                        return (w.windowId, bundleId)
                    },
                    uniquingKeysWith: { first, _ in first }
                )
                var clientBundleByPID: [pid_t: String] = [:]
                for (pid, windowId) in tmuxClientWindowMap {
                    if let bundleId = windowBundleMap[windowId] {
                        clientBundleByPID[pid] = bundleId
                    }
                }
                await tmuxSessionManager.reconcileAttachedQuickSwitchClients(
                    targetWindows: effectiveTerminalWorkspace.windows,
                    clientBundleByPID: clientBundleByPID,
                    runId: resolvedRunId
                )
                await reconcileITermQuickSwitchClients(
                    phaseResult: result,
                    runId: resolvedRunId,
                    tmuxCommandService: tmuxCommandService
                )
            }
            scheduleTerminalCleanupIfNeeded()
            return result
        }

        // Phase 7: Wait for IDE supplementation and restore IDEs
        func runIDEPhase() async -> PhaseExecutionResult {
            let ideSnapshot = await awaitSupplementation(
                task: ideSupplementationTask,
                fallback: baseSnapshot,
                runId: resolvedRunId,
                label: "ide",
                timeout: .seconds(6)
            )
            await postRestoreSnapshotStore.recordIDE(snapshot: ideSnapshot)
            let mergedSnapshot = SupplementationSnapshotMerger.mergeSupplementationSnapshot(base: baseSnapshot, overlay: ideSnapshot)
            let ideEnhancedSnapshot = EnhancedSnapshot.from(mergedSnapshot)
            return await executePhase(
                phaseName: "ide",
                runId: resolvedRunId,
                workspace: ideWorkspace,
                snapshot: ideEnhancedSnapshot,
                currentScreens: currentScreens,
                resolvedWindowTargets: preparationContext.windowTargetsByWindowID,
                options: options,
                chromeCaptures: [],
                executor: makeExecutor()
            )
        }

        // Phase 8: Wait for Chrome supplementation and restore Chrome windows
        let chromeExecutor = makeExecutor()
        func runChromePhase() async -> PhaseExecutionResult {
            let chromeSnapshot = await awaitSupplementation(
                task: chromeSupplementationTask,
                fallback: baseSnapshot,
                runId: resolvedRunId,
                label: "chrome",
                timeout: .seconds(6)
            )
            let chromeCaptures = await captureChromeWindowsIfNeeded()
            let mergedSnapshot = SupplementationSnapshotMerger.mergeSupplementationSnapshot(base: baseSnapshot, overlay: chromeSnapshot)
            let chromeEnhancedSnapshot = EnhancedSnapshot.from(mergedSnapshot)
            return await executePhase(
                phaseName: "chrome",
                runId: resolvedRunId,
                workspace: chromeWorkspace,
                snapshot: chromeEnhancedSnapshot,
                currentScreens: currentScreens,
                resolvedWindowTargets: preparationContext.windowTargetsByWindowID,
                options: options,
                chromeCaptures: chromeCaptures,
                executor: chromeExecutor
            )
        }

        let allPhases: [PhaseExecutionResult]
        switch phaseExecutionMode {
        case .sequential, .automatic:
            let otherPhase = await runOtherPhase()
            try await throwIfCancelled(runId: resolvedRunId)

            let slowStartPhase = await runSlowStartPhase()
            try await throwIfCancelled(runId: resolvedRunId)

            let terminalPhase = await runTerminalPhase()
            try await throwIfCancelled(runId: resolvedRunId)

            let idePhase = await runIDEPhase()
            try await throwIfCancelled(runId: resolvedRunId)

            let chromePhase = await runChromePhase()
            allPhases = [otherPhase, slowStartPhase, terminalPhase, idePhase, chromePhase]
        case .parallel:
            // Run slowStart sequentially AFTER parallel phases (needs modal time)
            let parallelPhases = await withTaskGroup(of: PhaseExecutionResult.self) { group in
                group.addTask { await runOtherPhase() }
                group.addTask { await runTerminalPhase() }
                group.addTask { await runIDEPhase() }
                group.addTask { await runChromePhase() }

                var results: [PhaseExecutionResult] = []
                for await result in group {
                    results.append(result)
                }
                return results
            }

            // Run slowStart only after all parallel phases complete.
            let slowStartPhase = await runSlowStartPhase()
            allPhases = parallelPhases + [slowStartPhase]
        }

        try await throwIfCancelled(runId: resolvedRunId)

        var deferredReflowResult: DeferredTerminalReflowResult?
        let clampedFramesBeforeCleanup = await lockManager.getClampedFrames(for: resolvedRunId)
        let hasXcodeWindows = mappedWorkspace.windows.contains { $0.bundleIdentifier == OpenByPathBundleIdentifiers.xcode }
        let hasTerminalWindows = mappedWorkspace.windows.contains { BundleRegistry.isTerminal($0.bundleIdentifier) }
        let shouldRunDeferredTerminalReflow = hasXcodeWindows &&
            hasTerminalWindows &&
            (!clampedFramesBeforeCleanup.isEmpty || singleTargetFastPathEnabled)

        if shouldRunDeferredTerminalReflow {
            let triggerReason = !clampedFramesBeforeCleanup.isEmpty ? "clamped-frames-present" : "single-target-fast-path"
            let reflowResult = await runDeferredTerminalReflowPass(
                runId: resolvedRunId,
                workspace: mappedWorkspace,
                currentScreens: currentScreens,
                lockTimeout: options.lockTimeout,
                triggerReason: triggerReason
            )
            deferredReflowResult = reflowResult
        } else {
            let reason: String
            if !hasXcodeWindows {
                reason = "missing-xcode"
            } else if !hasTerminalWindows {
                reason = "missing-terminal"
            } else {
                reason = "no-trigger"
            }
            DeskJigLog.trace(
                .restorationPostRestore,
                "RC10_DIAG deferred-terminal-reflow-skipped reason=\(reason) clampedFrameCount=\(clampedFramesBeforeCleanup.count) singleTargetFastPath=\(singleTargetFastPathEnabled)",
                runId: resolvedRunId
            )
        }

        let allTaskResults = allPhases.flatMap { $0.result.taskResults }
        let successCount = allTaskResults.filter { $0.success }.count
        let skippedCount = allTaskResults.filter { isSkipped($0.decision) }.count
        let failureCount = allTaskResults.filter { !$0.success && !isSkipped($0.decision) }.count

        let totalPlanDurationMs: Int
        let totalExecuteDurationMs: Int
        switch phaseExecutionMode {
        case .parallel:
            totalPlanDurationMs = allPhases.map { $0.planDurationMs }.max() ?? 0
            totalExecuteDurationMs = allPhases.map { $0.executeDurationMs }.max() ?? 0
        case .sequential, .automatic:
            totalPlanDurationMs = allPhases.map { $0.planDurationMs }.reduce(0, +)
            totalExecuteDurationMs = allPhases.map { $0.executeDurationMs }.reduce(0, +)
        }

        let combinedPlan = mergePlans(
            runId: resolvedRunId,
            workspace: workspace,
            snapshot: baseEnhancedSnapshot,
            phases: allPhases,
            buildDurationMs: totalPlanDurationMs
        )

        let aggregateResult = RestorationResult(
            runId: resolvedRunId,
            success: failureCount == 0,
            totalDurationMs: totalExecuteDurationMs,
            successCount: successCount,
            failureCount: failureCount,
            skippedCount: skippedCount,
            taskResults: allTaskResults
        )

        // Phase 8.5: Verify and correct window positions
        // After parallel positioning, some windows may have been transiently clamped
        // by their app (e.g. Ghostty enforcing minimum width on first resize).
        // Re-read actual frames and re-apply targets where they deviate.
        let verificationService = WindowPositioningService(
            lockManager: lockManager,
            defaultLockTimeout: options.lockTimeout
        )
        let verificationResult = await verificationService.verifyAndCorrectPositions(
            runId: resolvedRunId
        )

        let prePostDurationMs = Int(Date().timeIntervalSince(startTime) * 1000)

        // Phase 9: Post-restore (z-order, etc.)
        // Use mappedWorkspace to respect screen selection filtering - only windows that were
        // actually restored should be activated/raised in post-restore, not filtered-out windows
        let postRestoreSnapshot = await postRestoreSnapshotStore.mergedSnapshot()
        await postRestore(
            result: aggregateResult,
            runId: resolvedRunId,
            workspace: mappedWorkspace,
            snapshot: postRestoreSnapshot,
            options: options,
            tmuxPreparedTerminalWindowsById: tmuxPreparedTerminalWindowsById,
            deferredReflowWindowIds: deferredReflowResult?.movedWindowIds ?? []
        )

        let totalDurationMs = Int(Date().timeIntervalSince(startTime) * 1000)
        let postRestoreDurationMs = max(0, totalDurationMs - prePostDurationMs)
        let phasesByName = Dictionary(uniqueKeysWithValues: allPhases.map { ($0.phaseName, $0) })
        let phaseOrder = ["other", "slowStart", "terminal", "ide", "chrome"]
        let phaseSummary = phaseOrder.compactMap { name -> String? in
            guard let phase = phasesByName[name] else { return nil }
            let counts = "\(phase.result.successCount)s/\(phase.result.failureCount)f/\(phase.result.skippedCount)sk"
            return "\(name):plan=\(phase.planDurationMs)ms exec=\(phase.executeDurationMs)ms \(counts)"
        }.joined(separator: " | ")
        let laneMetrics = await laneCoordinator.metrics()
        let windowPositioningTelemetry = await WindowPositioningService.telemetry(forRunId: resolvedRunId)

        var completionData: [String: Any] = [
            "runId": resolvedRunId,
            "phaseMode": phaseExecutionModeLabel,
            "effectivePhaseMode": phaseExecutionModeLabel,
            "effectiveConcurrency": "\(globalConcurrency)",
            "laneMode": "per-display",
            "laneCount": "\(laneMetrics.laneCount)",
            "laneWaitMs": laneMetrics.waitSummary,
            "windowHandleDirectResolveCount": "\(windowPositioningTelemetry.windowHandleDirectResolveCount)",
            "windowHandleFallbackResolveCount": "\(windowPositioningTelemetry.windowHandleFallbackResolveCount)",
            "activationPollCount": "\(windowPositioningTelemetry.activationPollCount)",
            "activationPollSkippedCount": "\(windowPositioningTelemetry.activationPollSkippedCount)",
            "deterministicPositioning": "\(deterministicPositioningEnabled)",
            "singleTargetFastPath": "\(singleTargetFastPathEnabled)",
            "reflowApplied": "\(deferredReflowResult?.applied ?? false)",
            "verifyChecked": "\(verificationResult.checked)",
            "verifyCorrected": "\(verificationResult.corrected)",
            "verifyFailed": "\(verificationResult.failed)",
            "snapshotMs": "\(snapshotDurationMs)",
            "planMs": "\(totalPlanDurationMs)",
            "executeMs": "\(totalExecuteDurationMs)",
            "postRestoreMs": "\(postRestoreDurationMs)",
            "totalMs": "\(totalDurationMs)",
            "phases": phaseSummary
        ]
        if let hideAllStats {
            completionData["hideAllMs"] = "\(hideAllStats.totalDurationMs)"
            completionData["hideAllPending"] = "\(hideAllStats.finalPendingCount)"
            completionData["hideAllTargets"] = "\(hideAllStats.appsTargeted)"
        }
        DeskJigLog.debug(.restorationTrace, "Restoration summary", fields: completionData.mapValues { "\($0)" })

        var summaryFields: [String: String] = [
            "workspace": workspace.name,
            "windowCount": "\(workspace.windows.count)",
            "restored": "\(successCount)",
            "failed": "\(failureCount)",
            "skipped": "\(skippedCount)",
            "phaseMode": phaseExecutionModeLabel,
            "effectivePhaseMode": phaseExecutionModeLabel,
            "effectiveConcurrency": "\(globalConcurrency)",
            "laneMode": "per-display",
            "laneCount": "\(laneMetrics.laneCount)",
            "laneWaitMs": laneMetrics.waitSummary,
            "windowHandleDirectResolveCount": "\(windowPositioningTelemetry.windowHandleDirectResolveCount)",
            "windowHandleFallbackResolveCount": "\(windowPositioningTelemetry.windowHandleFallbackResolveCount)",
            "activationPollCount": "\(windowPositioningTelemetry.activationPollCount)",
            "activationPollSkippedCount": "\(windowPositioningTelemetry.activationPollSkippedCount)",
            "deterministicPositioning": "\(deterministicPositioningEnabled)",
            "singleTargetFastPath": "\(singleTargetFastPathEnabled)",
            "reflowApplied": "\(deferredReflowResult?.applied ?? false)",
            "snapshotMs": "\(snapshotDurationMs)",
            "planMs": "\(totalPlanDurationMs)",
            "executeMs": "\(totalExecuteDurationMs)",
            "postRestoreMs": "\(postRestoreDurationMs)",
            "totalMs": "\(totalDurationMs)",
            "phases": phaseSummary
        ]
        if let hideAllStats {
            summaryFields["hideAllMs"] = "\(hideAllStats.totalDurationMs)"
            summaryFields["hideAllPending"] = "\(hideAllStats.finalPendingCount)"
            summaryFields["hideAllTargets"] = "\(hideAllStats.appsTargeted)"
        }
        if unhideStats.appsUnhidden > 0 {
            summaryFields["unhideMs"] = "\(unhideStats.totalDurationMs)"
            summaryFields["unhiddenApps"] = "\(unhideStats.appsUnhidden)"
        }
        TraceFileWriter.shared.emitSummary(runId: resolvedRunId, fields: summaryFields)

        // Note: TraceFileWriter.shared.complete() is NOT called here because the retry loop
        // in restore() handles completion logging. Calling complete() here would reset
        // startTime to nil, causing the retry loop's elapsed time to show +0.000s.

        let fluentResult = FluentRestorationResult(
            success: failureCount == 0,
            runId: resolvedRunId,
            totalDurationMs: totalDurationMs,
            windowsRestored: successCount,
            windowsFailed: failureCount,
            windowsSkipped: skippedCount,
            plan: combinedPlan,
            taskResults: allTaskResults,
            snapshotDurationMs: snapshotDurationMs,
            planDurationMs: totalPlanDurationMs,
            executeDurationMs: totalExecuteDurationMs
        )

        let attemptLaunchedProfiles = await chromeExecutor.launchedChromeProfiles

        return RestorationAttemptResult(
            result: fluentResult,
            mappedWorkspace: mappedWorkspace,
            launchedChromeProfiles: attemptLaunchedProfiles,
            currentScreens: currentScreens
        )
    }

    /// Cancels the current restoration if one is in progress.
    public func cancel() {
        isCancelled = true
    }

    /// Resets the lock manager, releasing all locks.
    public func reset() async {
        await lockManager.reset()
        isCancelled = false
    }

    /// Throws `RestorationError.cancelled` (after releasing this run's locks and clearing its
    /// clamped/positioned frames) if a cancellation has been requested. Collapses the five
    /// previously-identical post-phase cancellation guards (fwr-11). Takes `runId` so the
    /// cancellation model can later become per-run without touching the call sites.
    private func throwIfCancelled(runId: String) async throws {
        guard isCancelled else { return }
        await lockManager.releaseAllLocks(for: runId)
        await lockManager.clearClampedFrames(for: runId)
        await lockManager.clearPositionedFrames(for: runId)
        throw RestorationError.cancelled
    }

    // MARK: - Private Methods

    public static func makeRunId() -> String {
        RestorationRunID.make()
    }

    private func getCurrentScreens() async -> [FullScreenInfo] {
        await MainActor.run {
            let displayManager = DisplayManager()
            displayManager.refreshScreens()
            return WorkspaceDisplayTopology.effectiveScreens(from: displayManager)
        }
    }

    private static func describe(currentScreens: [FullScreenInfo]) -> String {
        currentScreens.enumerated().map { index, screen in
            "[\(index)] id=\(screen.displayID) name=\(screen.name) frame=\(formatFrame(screen.frame)) visible=\(formatFrame(screen.visibleFrame)) primary=\(screen.isPrimary)"
        }
        .joined(separator: " | ")
    }

    private static func describe(workspaceScreens: [WorkspaceScreen]) -> String {
        workspaceScreens.enumerated().map { index, screen in
            "[\(index)] id=\(screen.displayID) name=\(screen.name) frame=\(formatFrame(screen.frame)) visible=\(formatFrame(screen.visibleFrame)) primary=\(screen.isPrimary)"
        }
        .joined(separator: " | ")
    }

    private static func formatFrame(_ frame: CGRect) -> String {
        frame.traceDescription
    }
}

// MARK: - Convenience Extensions

extension FluentWorkspaceRestorer {
    /// Restores a workspace with a completion handler (for compatibility).
    ///
    /// - Parameters:
    ///   - workspace: The workspace to restore
    ///   - options: Restoration options
    ///   - completion: Called when restoration completes
    public func restore(
        workspace: Workspace,
        options: RestorationOptions = .default,
        completion: @escaping @Sendable (Result<FluentRestorationResult, Error>) -> Void
    ) {
        Task {
            do {
                let result = try await restore(workspace: workspace, options: options)
                completion(.success(result))
            } catch {
                completion(.failure(error))
            }
        }
    }
}
