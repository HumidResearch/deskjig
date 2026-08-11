//  RestorationPlanBuilder.swift
//  DeskJigShared

import Foundation
import CoreGraphics

// MARK: - Restoration Plan

/// A complete restoration plan ready for execution.
///
/// Contains all tasks needed to restore a workspace, organized by type
/// and with locks acquired for conflict prevention.
///
/// ## Overview
///
/// A plan is created by ``RestorationPlanBuilder`` and contains:
/// - The workspace being restored
/// - The system snapshot at restoration start
/// - All restoration tasks with decisions
/// - Tasks organized by ready/blocked status
///
/// ## Example
///
/// ```swift
/// let plan = await RestorationPlanBuilder()
///     .forWorkspace(workspace)
///     .withSnapshot(snapshot)
///     .withLockManager(lockManager)
///     .analyze()
///     .acquireLocks()
///     .build()
///
/// print("Ready tasks: \(plan.readyTasks.count)")
/// print("Blocked tasks: \(plan.blockedTasks.count)")
/// ```
///
/// ## See Also
/// - ``RestorationPlanBuilder``
/// - ``RestorationTask``
/// - ``RestorationExecutor``
public struct RestorationPlan: Sendable {

    // MARK: - Properties

    /// Unique run ID for this restoration
    public let runId: String

    /// The workspace being restored
    public let workspace: Workspace

    /// The system snapshot at restoration start
    public let snapshot: EnhancedSnapshot

    /// All restoration tasks
    public let tasks: [RestorationTask]

    /// Shared tmux terminal restore metadata for this plan, when applicable.
    let tmuxTerminalRestoreContext: TmuxTerminalRestoreContext?

    /// When the plan was created
    public let createdAt: Date

    /// Duration to build the plan in milliseconds
    public let buildDurationMs: Int

    // MARK: - Computed Properties

    /// Tasks that are ready to execute (have locks or don't need them).
    public var readyTasks: [RestorationTask] {
        tasks.filter { $0.isReady }
    }

    /// Tasks that are blocked waiting for locks.
    public var blockedTasks: [RestorationTask] {
        tasks.filter { !$0.isReady && !$0.decision.isTerminal }
    }

    /// Tasks that were skipped.
    public var skippedTasks: [RestorationTask] {
        tasks.filter {
            if case .skip = $0.decision { return true }
            return false
        }
    }

    /// Tasks that failed during planning.
    public var failedTasks: [RestorationTask] {
        tasks.filter {
            if case .failed = $0.decision { return true }
            return false
        }
    }

    /// Tasks that will position existing windows.
    public var positionTasks: [RestorationTask] {
        tasks.filter { $0.decision.positionsExisting }
    }

    /// Tasks that will launch or create windows.
    public var launchTasks: [RestorationTask] {
        tasks.filter { $0.decision.requiresLaunch }
    }

    /// Chrome-specific tasks.
    public var chromeTasks: [RestorationTask] {
        tasks.filter { isChromeBundleId($0.workspaceWindow.bundleIdentifier) }
    }

    /// Total number of tasks.
    public var taskCount: Int { tasks.count }

    /// Number of ready tasks.
    public var readyCount: Int { readyTasks.count }

    /// Number of blocked tasks.
    public var blockedCount: Int { blockedTasks.count }

    // MARK: - Helpers

    private func isChromeBundleId(_ bundleId: String) -> Bool {
        bundleId == "com.google.Chrome" || bundleId == "com.google.Chrome.canary"
    }
}

// MARK: - Restoration Plan Builder

/// Fluent builder for creating restoration plans.
///
/// `RestorationPlanBuilder` analyzes a workspace configuration against the
/// current system state and creates a plan of restoration tasks. It handles:
/// - Matching workspace windows to existing system windows
/// - Determining the appropriate restoration decision for each window
/// - Acquiring locks for conflict prevention
/// - Organizing tasks for optimal execution
///
/// ## Overview
///
/// The builder follows a fluent pattern with chainable configuration methods:
///
/// 1. Configure the workspace and snapshot
/// 2. Call `analyze()` to create tasks
/// 3. Call `acquireLocks()` to reserve windows
/// 4. Call `build()` to get the final plan
///
/// ## Example
///
/// ```swift
/// let plan = await RestorationPlanBuilder()
///     .forWorkspace(workspace)
///     .withSnapshot(snapshot)
///     .withLockManager(lockManager)
///     .withCurrentScreens(screens)
///     .analyze()
///     .acquireLocks()
///     .build()
/// ```
///
/// ## See Also
/// - ``RestorationPlan``
/// - ``RestorationTask``
/// - ``WindowLockManager``
@MainActor
public final class RestorationPlanBuilder {

    // MARK: - Properties

    private var runId: String
    private var workspace: Workspace?
    private var snapshot: EnhancedSnapshot?
    private var lockManager: WindowLockManager?
    private var lockTimeout: Duration?
    private var resolvedWindowTargets: [UUID: ResolvedWorkspaceWindowTarget] = [:]
    private var matchConfig: MatchConfiguration = .default
    private var chromeCaptures: [ChromeAppleScriptWindowCapture] = []
    private var chromeMatchMethod: MatchMethod = .chromeProfile
    private var tasks: [RestorationTask] = []
    private var claimedWindows: Set<CGWindowID> = []
    private var buildStartTime: Date?
    private var chromeWorkspaceProfileDirectories: Set<String> = []
    private let chromeMatcher = ChromeWindowMatcher()
    private var tmuxSessionManager: TmuxSessionManager?
    private var tmuxClientWindowMap: [pid_t: CGWindowID] = [:]
    private var tmuxClients: [TmuxClientInfo] = []
    private var tmuxTerminalRestoreContext: TmuxTerminalRestoreContext?
    /// Per-bundle-ID counter for assigning tmux managed window indices.
    private var tmuxTerminalCounters: [String: Int] = [:]
    /// Expected tmux managed indices per terminal bundle (0..N-1).
    private var tmuxExpectedIndicesByBundle: [String: Set<Int>] = [:]
    /// Controls how strictly tmux managed-index coverage is enforced.
    private var tmuxIndexEnforcementPolicy: TmuxIndexEnforcementPolicy = .strictCoverage
    /// Stores the tmux managed index computed in `determineDecision` for the current task.
    private var lastAssignedTmuxIndex: Int?
    /// Stores the tmux binding plan computed in `determineDecision` for the current task.
    private var lastAssignedTmuxBindingPlan: TmuxTerminalBindingPlan?

    // MARK: - Initialization

    /// Creates a new restoration plan builder.
    ///
    /// - Parameter runId: Optional run ID (auto-generated if not provided)
    public init(runId: String? = nil) {
        self.runId = runId ?? Self.generateRunId()
    }

    // MARK: - Configuration

    /// Sets the workspace to restore.
    ///
    /// - Parameter workspace: The workspace configuration
    /// - Returns: Self for chaining
    @discardableResult
    public func forWorkspace(_ workspace: Workspace) -> Self {
        self.workspace = workspace
        return self
    }

    /// Sets the system snapshot to use for matching.
    ///
    /// - Parameter snapshot: The enhanced system snapshot
    /// - Returns: Self for chaining
    @discardableResult
    public func withSnapshot(_ snapshot: EnhancedSnapshot) -> Self {
        self.snapshot = snapshot
        return self
    }

    /// Sets the lock manager for coordination.
    ///
    /// - Parameter manager: The window lock manager
    /// - Returns: Self for chaining
    @discardableResult
    public func withLockManager(_ manager: WindowLockManager) -> Self {
        self.lockManager = manager
        return self
    }

    /// Sets the lock timeout for lock acquisition.
    ///
    /// - Parameter timeout: Lock request timeout
    /// - Returns: Self for chaining
    @discardableResult
    public func withLockTimeout(_ timeout: Duration) -> Self {
        self.lockTimeout = timeout
        return self
    }

    /// Sets the current screen configuration.
    ///
    /// Retained for source compatibility; target frames are supplied through
    /// `withResolvedWindowTargets(_:)`.
    ///
    /// - Parameter screens: Current screen information
    /// - Returns: Self for chaining
    @discardableResult
    public func withCurrentScreens(_ screens: [FullScreenInfo]) -> Self {
        return self
    }

    @discardableResult
    public func withResolvedWindowTargets(_ targets: [UUID: ResolvedWorkspaceWindowTarget]) -> Self {
        self.resolvedWindowTargets = targets
        return self
    }

    /// Configures the matching strategy.
    ///
    /// - Parameter config: Match configuration options
    /// - Returns: Self for chaining
    @discardableResult
    public func withMatchConfiguration(_ config: MatchConfiguration) -> Self {
        self.matchConfig = config
        return self
    }

    /// Sets AppleScript Chrome captures for bounds/title correlation.
    ///
    /// - Parameter captures: Chrome captures from AppleScript
    /// - Returns: Self for chaining
    @discardableResult
    public func withChromeCaptures(_ captures: [ChromeAppleScriptWindowCapture]) -> Self {
        self.chromeCaptures = captures
        return self
    }

    /// Sets the match method for Chrome profile matching.
    ///
    /// - Parameter method: Chrome match method
    /// - Returns: Self for chaining
    @discardableResult
    public func withChromeMatchMethod(_ method: MatchMethod) -> Self {
        self.chromeMatchMethod = method
        return self
    }

    /// Sets the tmux session manager for tmux-aware restoration.
    ///
    /// When set, terminal windows with tmuxState will use
    /// `.switchTmuxSession` decisions instead of legacy-title matching.
    ///
    /// - Parameter manager: The tmux session manager
    /// - Returns: Self for chaining
    @discardableResult
    public func withTmuxSessionManager(_ manager: TmuxSessionManager?) -> Self {
        self.tmuxSessionManager = manager
        return self
    }

    /// Sets the pre-computed tmux client-to-window mapping.
    ///
    /// - Parameter map: Map of tmux client PID to CGWindowID
    /// - Returns: Self for chaining
    @discardableResult
    public func withTmuxClientWindowMap(_ map: [pid_t: CGWindowID]) -> Self {
        self.tmuxClientWindowMap = map
        return self
    }

    /// Sets tmux client metadata for fallback selection when PID mapping misses.
    ///
    /// - Parameter clients: Current tmux clients
    /// - Returns: Self for chaining
    @discardableResult
    public func withTmuxClients(_ clients: [TmuxClientInfo]) -> Self {
        self.tmuxClients = clients
        return self
    }

    /// Sets the shared tmux terminal restore context for this phase.
    @discardableResult
    func withTmuxTerminalRestoreContext(_ context: TmuxTerminalRestoreContext?) -> Self {
        self.tmuxTerminalRestoreContext = context
        return self
    }

    /// Sets tmux managed-index enforcement policy.
    ///
    /// Internal policy: strict index coverage is enabled by default.
    @discardableResult
    func withTmuxIndexEnforcementPolicy(_ policy: TmuxIndexEnforcementPolicy) -> Self {
        self.tmuxIndexEnforcementPolicy = policy
        return self
    }

    // MARK: - Analysis

    /// Analyzes the workspace and creates restoration tasks.
    ///
    /// Matches each workspace window to the best available system window
    /// and determines the appropriate restoration decision.
    ///
    /// - Returns: Self for chaining
    ///
    /// ## Example
    ///
    /// ```swift
    /// let builder = RestorationPlanBuilder()
    ///     .forWorkspace(workspace)
    ///     .withSnapshot(snapshot)
    ///     .analyze()
    ///
    /// // Tasks are now created
    /// let plan = builder.build()
    /// ```
    @discardableResult
    public func analyze() async -> Self {
        buildStartTime = Date()
        guard let workspace = workspace, snapshot != nil else {
            return self
        }

        tasks = []
        claimedWindows = []
        tmuxTerminalCounters = [:]
        tmuxExpectedIndicesByBundle = [:]

        // Pre-calculate legacy terminal titles for terminal/IDE windows
        let windowsWithDeskJigTitles = assignDeskJigTitles(to: workspace.windows)
        if tmuxTerminalRestoreContext == nil, let snapshot {
            tmuxTerminalRestoreContext = TmuxTerminalRestoreContext.initial(
                workspaceWindows: windowsWithDeskJigTitles,
                preparedTerminalWindowsById: [:],
                snapshot: snapshot,
                tmuxClients: tmuxClients,
                tmuxClientWindowMap: tmuxClientWindowMap
            )
        }
        tmuxExpectedIndicesByBundle = tmuxTerminalRestoreContext?.expectedIndicesByBundle
            ?? expectedTmuxManagedIndices(for: windowsWithDeskJigTitles)

        // Process windows in priority order:
        // 1. Path-based windows (terminals, IDEs with openPath) - highest priority
        // 2. Chrome windows (profile-based matching)
        // 3. Default windows (title/frame matching)

        let pathWindows = windowsWithDeskJigTitles.filter { $0.openPath != nil }
        let chromeWindows = windowsWithDeskJigTitles.filter {
            isChromeBundleId($0.bundleIdentifier) && $0.openPath == nil
        }
        let defaultWindows = windowsWithDeskJigTitles.filter {
            $0.openPath == nil && !isChromeBundleId($0.bundleIdentifier)
        }
        chromeWorkspaceProfileDirectories = chromeProfileDirectories(in: chromeWindows)

        // Process path-based windows first
        for window in pathWindows {
            let task = await createTask(for: window)
            tasks.append(task)
        }

        // Process Chrome windows
        for window in chromeWindows {
            let task = await createTask(for: window)
            tasks.append(task)
        }

        // Process default windows
        for window in defaultWindows {
            let task = await createTask(for: window)
            tasks.append(task)
        }

        finalizeTmuxBindingPlans()

        return self
    }

    /// Assigns DeskJig terminal titles using the legacy `bento:<dir>:<idx>` token.
    ///
    /// Groups windows by (bundleId, openPath) and assigns sequential indices:
    /// - First window with openPath "/path/to/project" gets "bento:project:0"
    /// - Second window with the same path gets "bento:project:1"
    ///
    /// Only assigns DeskJig terminal titles to windows that:
    /// 1. Are terminal or IDE apps (supports title setting)
    /// 2. Have an openPath configured
    /// 3. Are NOT tmux-enabled Ghostty windows (tmux handles identity via sessions)
    private func assignDeskJigTitles(to windows: [WorkspaceWindow]) -> [WorkspaceWindow] {
        // Identify groups by (bundleId, openPath) for terminals/IDEs.
        struct DeskJigKey: Hashable {
            let bundleId: String
            let openPath: String
        }

        var result: [WorkspaceWindow] = []

        // Assign sequential indices within each group
        var indexCounters: [DeskJigKey: Int] = [:]

        for window in windows {
            let bundleId = window.bundleIdentifier
            let isTerminalOrIDE = BundleRegistry.isTerminal(bundleId) || BundleRegistry.isIDE(bundleId)

            // Skip tmux-enabled terminal windows - they keep their original titles
            let isTmuxEnabled = window.tmuxState != nil

            if isTerminalOrIDE && !isTmuxEnabled, let path = window.openPath {
                let key = DeskJigKey(bundleId: bundleId, openPath: path)
                let index = indexCounters[key, default: 0]
                indexCounters[key] = index + 1

                // Generate the DeskJig title with the legacy compatibility prefix.
                let basename = (path as NSString).lastPathComponent
                let deskJigTitle = "\(BundleIdentity.terminalTitleTokenPrefix):\(basename):\(index)"

                result.append(window.withWindowTitle(deskJigTitle))
            } else {
                // Keep original window title for non-terminal/IDE windows and tmux-enabled windows
                result.append(window)
            }
        }

        return result
    }

    /// Acquires locks for all tasks that need them.
    ///
    /// Tasks that position existing windows need locks to prevent conflicts.
    /// Locks are acquired based on match priority.
    ///
    /// - Returns: Self for chaining
    ///
    /// ## Example
    ///
    /// ```swift
    /// let builder = await RestorationPlanBuilder()
    ///     .forWorkspace(workspace)
    ///     .withSnapshot(snapshot)
    ///     .withLockManager(lockManager)
    ///     .analyze()
    ///     .acquireLocks()
    /// ```
    @discardableResult
    public func acquireLocks() async -> Self {
        guard let lockManager = lockManager else {
            return self
        }

        // Sort tasks by priority (higher priority acquires first)
        let sortedIndices = tasks.indices.sorted { i, j in
            tasks[i].requiredPriority > tasks[j].requiredPriority
        }

        for index in sortedIndices {
            let task = tasks[index]

            // Only acquire locks for tasks that position existing windows
            guard task.requiresLock,
                  let windowId = task.decision.existingWindowId else {
                continue
            }

            if isChromeBundleId(task.workspaceWindow.bundleIdentifier),
               let matchedWindow = task.matchResult.window,
               matchedWindow.supplementationStatus == .pending {
                tasks[index].lockResult = .awaitingChromeSupplementation
                continue
            }

            let result = await lockManager.requestLock(
                for: windowId,
                requesterId: task.id,
                priority: task.requiredPriority,
                timeout: lockTimeout
            )

            tasks[index].lockResult = result

            if case .acquired(let lock) = result {
                tasks[index].lock = lock
            } else if case .denied(let reason, let holder) = result {
                DeskJigLog.debug(.restorationExecutor, "Lock denied during plan build", fields: [
                    "app": task.workspaceWindow.appName,
                    "taskId": task.id,
                    "windowId": "\(windowId)",
                    "reason": reason,
                    "currentHolder": holder ?? "unknown",
                    "priority": task.requiredPriority.description
                ])
            }
        }

        return self
    }

    /// Builds the final restoration plan.
    ///
    /// - Returns: The complete restoration plan
    ///
    /// ## Example
    ///
    /// ```swift
    /// let plan = await builder
    ///     .analyze()
    ///     .acquireLocks()
    ///     .build()
    /// ```
    public func build() -> RestorationPlan {
        let buildDuration = buildStartTime.map {
            Int(Date().timeIntervalSince($0) * 1000)
        } ?? 0

        return RestorationPlan(
            runId: runId,
            workspace: workspace ?? Workspace(name: "Unknown", workspaceWindows: [], screens: []),
            snapshot: snapshot ?? EnhancedSnapshot.from(
                SystemSnapshot(
                    captureTime: Date(),
                    captureDurationMs: 0,
                    runId: runId,
                    displays: [],
                    windows: []
                )
            ),
            tasks: tasks,
            tmuxTerminalRestoreContext: finalizedTmuxTerminalRestoreContext(),
            createdAt: Date(),
            buildDurationMs: buildDuration
        )
    }

    // MARK: - Private Methods

    private func createTask(for window: WorkspaceWindow) async -> RestorationTask {
        guard let snapshot = snapshot else {
            return RestorationTask(
                workspaceWindow: window,
                targetFrame: .zero,
                targetScreenIndex: nil,
                decision: .failed(reason: "No snapshot available"),
                matchResult: .noMatch()
            )
        }

        guard let resolvedTarget = resolvedWindowTargets[window.id] else {
            return RestorationTask(
                workspaceWindow: window,
                targetFrame: .zero,
                targetScreenIndex: nil,
                decision: .failed(reason: "Missing resolved target geometry for workspace window"),
                matchResult: .noMatch()
            )
        }

        let targetFrame = resolvedTarget.targetFrame
        let targetScreenIndex = resolvedTarget.targetScreenIndex

        // Find best match
        var matchResult: MatchResult
        var chromeWindowId: Int?
        var chromeMatchMethod: ChromeWindowMatchMethod?
        var chromeTargetProfile: ChromeTargetProfile?
        if isChromeBundleId(window.bundleIdentifier) {
            chromeTargetProfile = chromeMatcher.resolveTargetProfile(for: window.chromeState)
            let chromeOutcome = chromeMatchResult(
                for: window,
                in: snapshot
            )
            matchResult = chromeOutcome.matchResult
            chromeWindowId = chromeOutcome.chromeWindowId
            chromeMatchMethod = chromeOutcome.chromeMatchMethod
        } else if shouldUseGenericMatching(for: window) {
            matchResult = snapshot.findGenericMatch(
                for: window,
                excluding: claimedWindows,
                targetFrame: targetFrame,
                config: matchConfig
            )
        } else {
            matchResult = snapshot.findMatch(
                for: window,
                excluding: claimedWindows,
                config: matchConfig
            )
        }

        if matchResult.window == nil,
           (BundleRegistry.isTerminal(window.bundleIdentifier) || BundleRegistry.isIDE(window.bundleIdentifier)),
           window.openPath == nil,
           let candidates = snapshot.windowsByBundleId[window.bundleIdentifier] {
            let unclaimed = candidates.filter { !claimedWindows.contains($0.windowId) }
            if let selected = unclaimed.sorted(by: {
                // Prefer windows on target screen
                let lhsScreen = ($0.displayIndex == targetScreenIndex) ? 0 : 1
                let rhsScreen = ($1.displayIndex == targetScreenIndex) ? 0 : 1
                if lhsScreen != rhsScreen { return lhsScreen < rhsScreen }
                return ($0.zOrderIndex ?? Int.max) < ($1.zOrderIndex ?? Int.max)
            }).first {
                DeskJigLog.debug(.restorationPlanner, "OpenByPath app without openPath matched by bundle-only", fields: [
                    "bundleId": window.bundleIdentifier,
                    "workspaceTitle": window.windowTitle,
                    "windowId": "\(selected.windowId)"
                ], runId: runId)
                matchResult = MatchResult(
                    window: selected,
                    confidence: 0.35,
                    method: .bundleIdOnly,
                    searchDurationMs: 0
                )
            }
        }

        // Determine decision based on match
        lastAssignedTmuxIndex = nil
        lastAssignedTmuxBindingPlan = nil
        let decision = determineDecision(
            for: window,
            match: matchResult,
            targetFrame: targetFrame,
            chromeTargetProfile: chromeTargetProfile,
            targetScreenIndex: targetScreenIndex
        )
        let tmuxIndex = lastAssignedTmuxIndex
        let tmuxBindingPlan = lastAssignedTmuxBindingPlan

        // Claim the window selected by the decision, not just any match candidate.
        // This avoids consuming a real indexed tmux window when the task must
        // bootstrap a missing index via openNewWithPath.
        if let selectedWindowId = decision.existingWindowId {
            claimedWindows.insert(selectedWindowId)
        }

        return RestorationTask(
            workspaceWindow: window,
            targetFrame: targetFrame,
            targetScreenIndex: targetScreenIndex,
            decision: decision,
            matchResult: matchResult,
            chromeWindowId: chromeWindowId,
            chromeMatchMethod: chromeMatchMethod,
            chromeTargetProfile: chromeTargetProfile,
            tmuxManagedIndex: tmuxIndex,
            tmuxBindingPlan: tmuxBindingPlan
        )
    }

    private func shouldUseGenericMatching(for window: WorkspaceWindow) -> Bool {
        if window.openPath != nil { return false }

        let bundleId = window.bundleIdentifier
        if BundleRegistry.isTerminal(bundleId) { return false }

        return true
    }

    private struct ChromeMatchOutcome {
        let matchResult: MatchResult
        let chromeWindowId: Int?
        let chromeMatchMethod: ChromeWindowMatchMethod?
    }

    private func chromeMatchResult(
        for window: WorkspaceWindow,
        in snapshot: EnhancedSnapshot
    ) -> ChromeMatchOutcome {
        let startTime = Date()

        let taskContext = RestorationTaskContext(
            taskId: "chrome-\(window.id.uuidString.prefix(8))",
            taskType: .chrome,
            runId: runId
        )

        let chromeMatch = chromeMatcher.matchExistingWindow(
            workspaceWindow: window,
            snapshot: snapshot.base,
            chromeCaptures: chromeCaptures,
            matchMethod: chromeMatchMethod,
            taskContext: taskContext,
            workspaceProfileDirectories: chromeWorkspaceProfileDirectories,
            excludingWindowIds: claimedWindows
        )

        var matchedWindow = chromeMatch.window
        var matchMethod = chromeMatch.method

        if let existingWindow = matchedWindow, claimedWindows.contains(existingWindow.windowId) {
            DeskJigLog.debug(.restorationPlanner, "Chrome match already claimed - skipping", fields: [
                "windowId": "\(existingWindow.windowId)"
            ], runId: taskContext.runId)
            matchedWindow = nil
            matchMethod = .noMatch
        }

        let durationMs = Int(Date().timeIntervalSince(startTime) * 1000)

        guard let matchedWindow else {
            return ChromeMatchOutcome(
                matchResult: MatchResult.noMatch(searchDurationMs: durationMs),
                chromeWindowId: nil,
                chromeMatchMethod: matchMethod
            )
        }

        let (matchMethodValue, confidence) = chromeMatchMetadata(
            window: window,
            chromeMethod: matchMethod
        )

        return ChromeMatchOutcome(
            matchResult: MatchResult(
                window: matchedWindow,
                confidence: confidence,
                method: matchMethodValue,
                searchDurationMs: durationMs
            ),
            chromeWindowId: chromeMatch.chromeWindowId,
            chromeMatchMethod: matchMethod
        )
    }

    private func chromeMatchMetadata(
        window: WorkspaceWindow,
        chromeMethod: ChromeWindowMatchMethod
    ) -> (WindowMatchMethod, Double) {
        let profileDisplayName = window.chromeState?.appleScriptProfileName ?? ""
        let hasProfile = !profileDisplayName.isEmpty
        let profileMethod: WindowMatchMethod = hasProfile
            ? .chromeProfile(profileDisplayName)
            : .bundleIdOnly

        switch chromeMethod {
        case .chromeWindowId:
            return (profileMethod, 1.0)
        case .axTitle, .supplementationExact:
            return (profileMethod, 0.9)
        case .titleExact:
            return (.titleExact, 0.8)
        case .supplementationBaseName, .titleBaseName:
            let titleValue = hasProfile ? profileDisplayName : window.windowTitle
            return (.titleContains(titleValue), 0.7)
        case .appleScriptBounds:
            return (.frameWithTolerance(tolerance: matchConfig.frameTolerance), 0.6)
        case .tabUrlsSupplementation, .tabUrlsCapture:
            return (profileMethod, 0.75)
        case .noMatch:
            return (.noMatch, 0.0)
        }
    }

    private func determineDecision(
        for window: WorkspaceWindow,
        match: MatchResult,
        targetFrame: CGRect,
        chromeTargetProfile: ChromeTargetProfile? = nil,
        targetScreenIndex: Int? = nil
    ) -> RestorationDecision {
        let bundleId = window.bundleIdentifier

        // tmux fast path: if this is a tmux-enabled terminal window, prefer
        // switching an existing client over launching a new window.
        if let tmuxState = window.tmuxState,
           BundleRegistry.isTerminal(bundleId),
           tmuxSessionManager != nil {

            // Assign a per-bundle tmux index for this window (0, 1, 2...).
            let tmuxIndex = tmuxTerminalCounters[bundleId, default: 0]
            tmuxTerminalCounters[bundleId] = tmuxIndex + 1
            lastAssignedTmuxIndex = tmuxIndex

            let snapshotTerminalWindows = snapshot?.windowsByBundleId[bundleId] ?? []
            let expectedIndices = tmuxTerminalRestoreContext?.expectedIndicesByBundle[bundleId]
                ?? tmuxExpectedIndicesByBundle[bundleId]
                ?? []
            let expectedWindowCount = max(expectedIndices.count, 1)
            let iTermTTYWindowIds = Set(
                tmuxTerminalRestoreContext?.iTermWindowTTYBindings.keys.map { $0 } ?? []
            )
            // For iTerm, filter to windows that are either TTY-backed or have managed
            // titles. This prevents utility/helper windows (hidden "Untitled" windows)
            // from being selected as terminal window candidates.
            let shouldConstrainITermWindows = bundleId == BundleRegistry.iterm2 &&
                expectedWindowCount > 1 &&
                !iTermTTYWindowIds.isEmpty
            let terminalWindows: [SnapshotWindow]
            if shouldConstrainITermWindows {
                let managedPrefix = BundleRegistry.managedTmuxWindowTitle
                terminalWindows = snapshotTerminalWindows.filter {
                    iTermTTYWindowIds.contains($0.windowId) ||
                    ($0.title?.contains(managedPrefix) == true)
                }
            } else {
                terminalWindows = snapshotTerminalWindows
            }
            let clientBackedWindowIds = Set(tmuxClientWindowMap.values)
                .union(bundleId == BundleRegistry.iterm2 ? iTermTTYWindowIds : [])
            let clientBackedBundleWindowCount = terminalWindows.filter { clientBackedWindowIds.contains($0.windowId) }.count
            // Build AX title fallback map for apps where CGWindowList returns nil titles
            // (e.g., Ghostty). This allows the topology to discover managed windows by
            // reading their AX title attribute, which reflects the tmux pane title.
            // Match by PID since each Ghostty process has one window and AX window
            // numbers don't reliably map to CG window IDs.
            let axTitlesByWindowId: [CGWindowID: String]
            if terminalWindows.contains(where: { $0.title == nil }) {
                let axHandles = Window.allAcrossProcesses(forBundleID: bundleId, filter: .all)
                // Build PID → AX title map from handles
                var titlesByPid: [pid_t: String] = [:]
                for handle in axHandles {
                    guard let pid = handle.processID,
                          let title = handle.title,
                          title.contains(BundleRegistry.managedTmuxWindowTitle) else { continue }
                    titlesByPid[pid] = title
                }
                // Map snapshot window CG IDs to AX titles via PID
                var map: [CGWindowID: String] = [:]
                for window in terminalWindows where window.title == nil {
                    if let title = titlesByPid[window.pid] {
                        map[window.windowId] = title
                    }
                }
                axTitlesByWindowId = map
            } else {
                axTitlesByWindowId = [:]
            }

            let topology = TmuxManagedIndexTopology(
                bundleId: bundleId,
                expectedIndices: expectedIndices,
                windows: terminalWindows,
                axTitlesByWindowId: axTitlesByWindowId
            )

            let indexedTitle = BundleRegistry.managedTmuxWindowTitle(bundleId: bundleId, index: tmuxIndex)
            let unclaimedIndexWindows = topology.windows(for: tmuxIndex)
                .filter { !claimedWindows.contains($0.windowId) }
            let unclaimedBundleWindows = terminalWindows
                .filter { !claimedWindows.contains($0.windowId) }
            let fallbackWindowIds = unclaimedBundleWindows.map { $0.windowId }

            func assignBinding(
                selectedWindowId: CGWindowID?,
                evidence: TmuxTerminalBindingEvidence,
                launchAllowed: Bool
            ) {
                lastAssignedTmuxBindingPlan = TmuxTerminalBindingPlan(
                    bundleId: bundleId,
                    sessionName: tmuxState.sessionName,
                    tmuxIndex: tmuxIndex,
                    expectedWindowCount: expectedWindowCount,
                    selectedWindowId: selectedWindowId,
                    fallbackWindowIds: fallbackWindowIds.filter { $0 != selectedWindowId },
                    evidence: evidence,
                    staleWindowIds: [],
                    launchAllowed: launchAllowed
                )
            }

            /// Shared helper for the claim → log → bind → return pattern used
            /// by every tmux window-reuse path. Inserts the window into
            /// `claimedWindows`, emits a topology trace log, records the
            /// binding plan, and returns `.switchTmuxSession`.
            func commitTmuxReuse(
                _ selectedWindow: SnapshotWindow,
                label: String,
                reason: String,
                decisionPath: TmuxIndexDecisionPath = .indexedMatch,
                evidence: TmuxTerminalBindingEvidence,
                launchAllowed: Bool = false,
                extraLogFields: [String: String] = [:]
            ) -> RestorationDecision {
                claimedWindows.insert(selectedWindow.windowId)

                var fields: [String: String] = [
                    "reason": reason,
                    "decisionPath": decisionPath.rawValue,
                    "app": window.appName,
                    "bundleId": bundleId,
                    "windowId": "\(selectedWindow.windowId)",
                    "sessionName": tmuxState.sessionName,
                    "indexedTitle": indexedTitle,
                    "tmuxIndex": "\(tmuxIndex)",
                    "topologyExpectedIndices": topology.expectedIndicesDescription,
                    "topologyObservedIndices": topology.observedIndicesDescription,
                    "topologyMissingIndices": topology.missingIndicesDescription,
                    "topologyDuplicateIndices": topology.duplicateIndicesDescription,
                    "targetFrame": formatFrame(targetFrame)
                ]
                for (key, value) in extraLogFields {
                    fields[key] = value
                }
                DeskJigLog.trace(.tmux, label, fields: fields, runId: runId)

                assignBinding(
                    selectedWindowId: selectedWindow.windowId,
                    evidence: evidence,
                    launchAllowed: launchAllowed
                )

                return .switchTmuxSession(
                    windowId: selectedWindow.windowId,
                    sessionName: tmuxState.sessionName,
                    targetFrame: targetFrame
                )
            }

            // Build window → session map so selectDeterministicTmuxWindow can
            // prefer windows already on the target session (avoids duplicate indices).
            let windowSessionMap: [CGWindowID: String] = Dictionary(
                tmuxClientWindowMap.compactMap { pid, windowId in
                    guard let client = tmuxClients.first(where: { $0.clientPID == pid }) else { return nil }
                    return (key: windowId, value: client.sessionName)
                },
                uniquingKeysWith: { first, _ in first }
            )

            switch tmuxIndexEnforcementPolicy {
            case .strictCoverage:
                let mappedWindowIds = Set(tmuxClientWindowMap.values)
                let coverageSatisfied = clientBackedBundleWindowCount >= expectedWindowCount
                // Only suppress bootstrap launches for Terminal.app when topology is
                // unavailable if existing windows are actually client-backed (have
                // attached tmux clients). Raw window count alone is insufficient —
                // windows from a previous workspace may exist without the right
                // tmux sessions, leading to lock contention when the executor
                // tries to reuse a single window for multiple tmux slots.
                let shouldTreatUnavailableTerminalTopologyAsCovered =
                    bundleId == OpenByPathBundleIdentifiers.terminal &&
                    topology.observedIndices.isEmpty &&
                    terminalWindows.count >= expectedWindowCount &&
                    clientBackedBundleWindowCount >= expectedWindowCount
                let topologyCoverageSatisfied =
                    coverageSatisfied || shouldTreatUnavailableTerminalTopologyAsCovered
                // Include all unclaimed index windows (even minimized/AX-inaccessible) as
                // candidates. Managed titles are reliable evidence — minimized windows from
                // a previous workspace should be reused rather than creating duplicates.
                // selectDeterministicTmuxWindow will prefer AX-accessible ones via sorting.
                let axAccessibleIndexWindows = unclaimedIndexWindows

                // Managed indexed titles are authoritative identity written by
                // DeskJig's own launchers (see TmuxManagedIndexTopology), so an exact
                // indexed-title match is trusted for reuse even without live client
                // backing — the old tmux client may have died, the window may be
                // minimized, or it may survive from a previous workspace (#627).
                // Bootstrapping instead would orphan the managed window and create
                // a duplicate. (Terminal.app additionally depends on this because
                // it is single-process, so tmux client-to-window PID mapping is
                // unreliable — all windows share the same PID.)
                let indexedTitleTopologyTrusted = !axAccessibleIndexWindows.isEmpty
                if let selectedWindow = selectDeterministicTmuxWindow(
                    from: axAccessibleIndexWindows,
                    mappedWindowIds: mappedWindowIds,
                    preferAXAccessible: true,
                    targetSessionName: tmuxState.sessionName,
                    windowSessionMap: windowSessionMap,
                    targetScreenIndex: targetScreenIndex,
                    targetFrame: targetFrame
                ), coverageSatisfied || clientBackedWindowIds.contains(selectedWindow.windowId) || indexedTitleTopologyTrusted {
                    let hasDuplicateForIndex = topology.duplicateIndices.contains(tmuxIndex)
                    return commitTmuxReuse(
                        selectedWindow,
                        label: "tmux fast-switch decision",
                        reason: hasDuplicateForIndex
                            ? TmuxIndexTraceReason.duplicateIndexedManagedWindow.rawValue
                            : "indexed-title-match",
                        decisionPath: hasDuplicateForIndex
                            ? .duplicateIndexSelected
                            : .indexedMatch,
                        evidence: hasDuplicateForIndex
                            ? .indexedCandidateFallback
                            : .indexedTitle,
                        extraLogFields: [
                            "tmuxClientsCount": "\(tmuxClients.count)",
                            "tmuxClientWindowMapCount": "\(tmuxClientWindowMap.count)"
                        ]
                    )
                }

                if !unclaimedIndexWindows.isEmpty,
                   let fallbackWindow = selectDeterministicTmuxWindow(
                    from: unclaimedBundleWindows.filter { $0.isAXAccessible != false },
                    mappedWindowIds: mappedWindowIds,
                    preferAXAccessible: true,
                    targetSessionName: tmuxState.sessionName,
                    windowSessionMap: windowSessionMap,
                    targetScreenIndex: targetScreenIndex,
                    targetFrame: targetFrame
                   ),
                   coverageSatisfied || clientBackedWindowIds.contains(fallbackWindow.windowId) {
                    logRC10Diag("planner-indexed-inaccessible-fallback-reuse", data: [
                        "bundleId": bundleId,
                        "tmuxIndex": "\(tmuxIndex)",
                        "indexedCandidateCount": "\(unclaimedIndexWindows.count)",
                        "indexedAXCount": "\(axAccessibleIndexWindows.count)",
                        "fallbackWindowCount": "\(unclaimedBundleWindows.count)",
                        "selectedWindowId": "\(fallbackWindow.windowId)",
                        "selectedWindowAX": "\(fallbackWindow.isAXAccessible ?? false)"
                    ])
                    return commitTmuxReuse(
                        fallbackWindow,
                        label: "tmux fast-switch decision (indexed candidate inaccessible fallback)",
                        reason: "indexed-candidate-inaccessible-fallback",
                        evidence: .indexedCandidateFallback,
                        extraLogFields: [
                            "tmuxClientsCount": "\(tmuxClients.count)",
                            "tmuxClientWindowMapCount": "\(tmuxClientWindowMap.count)",
                            "indexedCandidateCount": "\(unclaimedIndexWindows.count)",
                            "indexedAXCount": "\(axAccessibleIndexWindows.count)",
                            "fallbackWindowCount": "\(unclaimedBundleWindows.count)"
                        ]
                    )
                }

                // Indexed title topology can be temporarily unavailable in iTerm/CC mode
                // when AX exposes hostname titles instead of managed titles. In that mode,
                // reuse an unclaimed window deterministically to avoid launch storms.
                if topologyCoverageSatisfied,
                   topology.observedIndices.isEmpty,
                   let fallbackWindow = selectDeterministicTmuxWindow(
                    from: unclaimedBundleWindows,
                    mappedWindowIds: mappedWindowIds,
                    preferAXAccessible: true,
                    targetSessionName: tmuxState.sessionName,
                    windowSessionMap: windowSessionMap,
                    targetScreenIndex: targetScreenIndex,
                    targetFrame: targetFrame
                   ) {
                    let unclaimedAXCount = unclaimedBundleWindows.filter { $0.isAXAccessible == true }.count
                    logRC10Diag("planner-topology-unavailable-fallback-reuse", data: [
                        "bundleId": bundleId,
                        "tmuxIndex": "\(tmuxIndex)",
                        "unclaimedWindowCount": "\(unclaimedBundleWindows.count)",
                        "unclaimedAXCount": "\(unclaimedAXCount)",
                        "selectedWindowId": "\(fallbackWindow.windowId)",
                        "selectedWindowAX": "\(fallbackWindow.isAXAccessible ?? false)"
                    ])
                    return commitTmuxReuse(
                        fallbackWindow,
                        label: "tmux fast-switch decision (indexed topology unavailable)",
                        reason: "indexed-topology-unavailable-fallback",
                        evidence: .topologyUnavailableReuse,
                        extraLogFields: [
                            "tmuxClientsCount": "\(tmuxClients.count)",
                            "tmuxClientWindowMapCount": "\(tmuxClientWindowMap.count)",
                            "fallbackWindowCount": "\(unclaimedBundleWindows.count)"
                        ]
                    )
                }

                // Partial topology: some managed indices exist but this specific index is missing.
                // Reuse an unclaimed window rather than launching a new one.
                // Allow reuse without full client backing when there are enough
                // unclaimed windows — shell prompts often override tmux-managed
                // titles, causing partial topology even though windows are valid.
                //
                // The fallback must be title-aware: tasks run in ascending index
                // order, so a lower missing index would otherwise consume a window
                // that carries a *different* index's managed title before that
                // slot's exact-match path runs (#627). Reserve the sole remaining
                // window of each higher, still-unassigned expected index; surplus
                // duplicates stay fair game (their slot only needs one window).
                var foreignReservedWindowIds: Set<CGWindowID> = []
                for reservedIndex in expectedIndices where reservedIndex > tmuxIndex {
                    let unclaimedForIndex = topology.windows(for: reservedIndex)
                        .filter { !claimedWindows.contains($0.windowId) }
                    if unclaimedForIndex.count == 1, let reservedWindow = unclaimedForIndex.first {
                        foreignReservedWindowIds.insert(reservedWindow.windowId)
                    }
                }
                let titleAwareFallbackWindows = unclaimedBundleWindows
                    .filter { !foreignReservedWindowIds.contains($0.windowId) }
                let hasEnoughUnclaimedForMissing = unclaimedBundleWindows.count >= topology.missingIndices.count
                if (coverageSatisfied || hasEnoughUnclaimedForMissing),
                   !topology.observedIndices.isEmpty,
                   !topology.observedIndices.contains(tmuxIndex),
                   let fallbackWindow = selectDeterministicTmuxWindow(
                    from: titleAwareFallbackWindows,
                    mappedWindowIds: mappedWindowIds,
                    preferAXAccessible: true,
                    targetSessionName: tmuxState.sessionName,
                    windowSessionMap: windowSessionMap,
                    targetScreenIndex: targetScreenIndex,
                    targetFrame: targetFrame
                   ) {
                    logRC10Diag("planner-topology-partial-fallback-reuse", data: [
                        "bundleId": bundleId,
                        "tmuxIndex": "\(tmuxIndex)",
                        "observedIndices": topology.observedIndicesDescription,
                        "missingIndices": topology.missingIndicesDescription,
                        "unclaimedWindowCount": "\(unclaimedBundleWindows.count)",
                        "reservedForeignManagedCount": "\(foreignReservedWindowIds.count)",
                        "selectedWindowId": "\(fallbackWindow.windowId)"
                    ])
                    return commitTmuxReuse(
                        fallbackWindow,
                        label: "tmux fast-switch decision (partial topology fallback)",
                        reason: "partial-topology-missing-index-fallback",
                        evidence: .partialTopologyReuse
                    )
                }
            }

            // Terminal.app fallback: topology is always empty because
            // CGWindowList doesn't report tmux pane titles for Terminal.app.
            // When there are enough unclaimed windows, reuse them instead of
            // launching new ones (which creates duplicates).
            if topology.observedIndices.isEmpty,
               bundleId == BundleRegistry.terminal,
               !unclaimedBundleWindows.isEmpty,
               terminalWindows.count >= expectedWindowCount,
               let fallbackWindow = selectDeterministicTmuxWindow(
                from: unclaimedBundleWindows.filter { $0.isAXAccessible != false },
                mappedWindowIds: Set(tmuxClientWindowMap.values),
                preferAXAccessible: true,
                targetSessionName: tmuxState.sessionName,
                windowSessionMap: windowSessionMap,
                targetScreenIndex: targetScreenIndex,
                targetFrame: targetFrame
               ) {
                return commitTmuxReuse(
                    fallbackWindow,
                    label: "Terminal.app topology-empty window reuse",
                    reason: "terminal-topology-empty-reuse",
                    evidence: .topologyUnavailableReuse,
                    extraLogFields: [
                        "unclaimedWindowCount": "\(unclaimedBundleWindows.count)",
                        "terminalWindowCount": "\(terminalWindows.count)",
                        "expectedWindowCount": "\(expectedWindowCount)"
                    ]
                )
            }

            if topology.observedIndices.isEmpty {
                let unclaimedAXCount = unclaimedBundleWindows.filter { $0.isAXAccessible == true }.count
                logRC10Diag("planner-topology-unavailable-fallback-open-new", data: [
                    "bundleId": bundleId,
                    "tmuxIndex": "\(tmuxIndex)",
                    "unclaimedWindowCount": "\(unclaimedBundleWindows.count)",
                    "unclaimedAXCount": "\(unclaimedAXCount)",
                    "reason": unclaimedBundleWindows.isEmpty ? "no-unclaimed-candidates" : "selection-failed"
                ])
            }

            // Required index is missing or unavailable -> bootstrap that index.
            let path = window.openPath ?? tmuxState.initialWorkingDirectory
            DeskJigLog.debug(.tmux, "tmux bootstrap launch required", fields: [
                "reason": TmuxIndexTraceReason.missingIndexedManagedWindow.rawValue,
                "decisionPath": TmuxIndexDecisionPath.bootstrapMissingIndex.rawValue,
                "app": window.appName,
                "bundleId": bundleId,
                "sessionName": tmuxState.sessionName,
                "indexedTitle": indexedTitle,
                "tmuxIndex": "\(tmuxIndex)",
                "tmuxClientsCount": "\(tmuxClients.count)",
                "tmuxClientWindowMapCount": "\(tmuxClientWindowMap.count)",
                "topologyExpectedIndices": topology.expectedIndicesDescription,
                "topologyObservedIndices": topology.observedIndicesDescription,
                "topologyMissingIndices": topology.missingIndicesDescription,
                "topologyDuplicateIndices": topology.duplicateIndicesDescription,
                "path": path
            ], runId: runId)
            assignBinding(
                selectedWindowId: nil,
                evidence: .launchRequiredUnderProvisioned,
                launchAllowed: true
            )
            return .openNewWithPath(
                bundleId: bundleId,
                path: path,
                targetFrame: targetFrame
            )
        }

        // If we have a match, position the existing window
        if let matchedWindow = match.window {
            DeskJigLog.debug(.restorationPlanner, "Matched existing window for workspace entry", fields: [
                "app": window.appName,
                "bundleId": bundleId,
                "workspaceTitle": window.windowTitle,
                "openPath": window.openPath ?? "none",
                "matchMethod": match.method.description,
                "matchConfidence": String(format: "%.2f", match.confidence),
                "matchDurationMs": "\(match.searchDurationMs)",
                "matchedWindowId": "\(matchedWindow.windowId)",
                "matchedTitle": matchedWindow.title ?? "",
                "matchedFrame": formatFrame(matchedWindow.frame)
            ], runId: runId)

            // Codex is single-instance and must still run `codex app <path>` so the
            // existing app switches its view to the target workspace/project.
            if bundleId == BundleRegistry.codex, let path = window.openPath {
                DeskJigLog.debug(.restorationPlanner, "Codex matched existing window but requires CLI path switch", fields: [
                    "bundleId": bundleId,
                    "path": path,
                    "matchedWindowId": "\(matchedWindow.windowId)"
                ], runId: runId)
                return .openNewWithPath(
                    bundleId: bundleId,
                    path: path,
                    targetFrame: targetFrame
                )
            }

            // Chrome gets special handling for tabs
            if isChromeBundleId(bundleId) {
                let tabs = window.chromeState?.savedTabURLs ?? []
                return .reuseChromeWindow(
                    windowId: matchedWindow.windowId,
                    tabs: tabs,
                    targetFrame: targetFrame
                )
            }

            return .positionExisting(
                windowId: matchedWindow.windowId,
                targetFrame: targetFrame
            )
        }

        // No match - need to create/launch

        // Chrome: create new window with profile
        if isChromeBundleId(bundleId) {
            let storedProfileDirectory = window.chromeState?.profileDirectory ?? ""
            let resolvedProfileDirectory = chromeTargetProfile?.resolvedProfileDirectory
            let profile = resolvedProfileDirectory ?? (storedProfileDirectory.isEmpty ? "Default" : storedProfileDirectory)
            let tabs = window.chromeState?.savedTabURLs ?? []

            DeskJigLog.debug(.restorationChrome, "Chrome create decision profile resolution", fields: [
                "app": window.appName,
                "storedProfileDirectory": storedProfileDirectory.isEmpty ? "none" : storedProfileDirectory,
                "resolvedProfileDirectory": resolvedProfileDirectory ?? "none",
                "storedHostedDomain": window.chromeState?.profileHostedDomain ?? "none",
                "resolvedBy": chromeTargetProfile?.resolvedBy ?? "none",
                "fallbackReason": chromeTargetProfile?.fallbackReason ?? "none"
            ], runId: runId)

            return .createChromeWindow(
                profile: profile,
                tabs: tabs,
                targetFrame: targetFrame
            )
        }

        // Path-based apps: open with path
        // For tmux-enabled windows, the openNewWithPath handler will use tmux-attached launch
        if let path = window.openPath {
            return .openNewWithPath(
                bundleId: bundleId,
                path: path,
                targetFrame: targetFrame
            )
        }

        // Check if app is running
        let appRunning = snapshot?.windowsByBundleId[bundleId]?.isEmpty == false

        if appRunning {
            DeskJigLog.debug(.restorationPlanner, "No match found; app is running", fields: [
                "app": window.appName,
                "bundleId": bundleId,
                "workspaceTitle": window.windowTitle,
                "openPath": window.openPath ?? "none",
                "matchMethod": match.method.description,
                "matchConfidence": String(format: "%.2f", match.confidence),
                "matchDurationMs": "\(match.searchDurationMs)"
            ], runId: runId)
            if (BundleRegistry.isTerminal(bundleId) || BundleRegistry.isIDE(bundleId)),
               window.openPath == nil {
                DeskJigLog.debug(.restorationPlanner, "OpenByPath app without openPath - reopening or launching", fields: [
                    "bundleId": bundleId,
                    "workspaceTitle": window.windowTitle
                ], runId: runId)
                return .launchApp(
                    bundleId: bundleId,
                    then: .positionExisting(windowId: 0, targetFrame: targetFrame)
                )
            }

            // App is running but no windows matched - skip or create new
            return .skip(reason: "App running but no matching window found")
        } else {
            // App not running - check if app is available before attempting launch
            let appAvailable = isAppAvailable(bundleId: bundleId, applicationPath: window.applicationPath)

            if !appAvailable {
                DeskJigLog.debug(.restorationPlanner, "App not available - skipping", fields: [
                    "app": window.appName,
                    "bundleId": bundleId,
                    "savedPath": window.applicationPath ?? "none"
                ], runId: runId)
                return .failed(reason: "App not installed: \(window.appName)")
            }

            // App is available - launch it
            return .launchApp(
                bundleId: bundleId,
                then: .positionExisting(windowId: 0, targetFrame: targetFrame)
            )
        }
    }

    private func isChromeBundleId(_ bundleId: String) -> Bool {
        bundleId == "com.google.Chrome" || bundleId == "com.google.Chrome.canary"
    }

    private func expectedTmuxManagedIndices(for windows: [WorkspaceWindow]) -> [String: Set<Int>] {
        let grouped = Dictionary(grouping: windows) { $0.bundleIdentifier }
        var expected: [String: Set<Int>] = [:]

        for (bundleId, bundleWindows) in grouped {
            guard BundleRegistry.isTerminal(bundleId) else { continue }
            let tmuxCount = bundleWindows.filter { $0.tmuxState != nil }.count
            guard tmuxCount > 0 else { continue }
            expected[bundleId] = Set(0..<tmuxCount)
        }
        return expected
    }

    private func finalizeTmuxBindingPlans() {
        guard let snapshot else { return }

        let tmuxTaskIndices = tasks.indices.filter { tasks[$0].tmuxBindingPlan != nil }
        guard !tmuxTaskIndices.isEmpty else { return }

        let selectedWindowIdsByBundle = Dictionary(grouping: tmuxTaskIndices) { index in
            tasks[index].workspaceWindow.bundleIdentifier
        }.mapValues { indices -> Set<CGWindowID> in
            Set(indices.compactMap { tasks[$0].tmuxBindingPlan?.selectedWindowId })
        }

        for index in tmuxTaskIndices {
            guard var bindingPlan = tasks[index].tmuxBindingPlan else { continue }
            let bundleInventory = tmuxTerminalRestoreContext?.bundleWindowInventory[bindingPlan.bundleId]
                ?? snapshot.windowsByBundleId[bindingPlan.bundleId]
                ?? []
            let selectedWindowIds = selectedWindowIdsByBundle[bindingPlan.bundleId] ?? []
            bindingPlan.staleWindowIds = bundleInventory
                .map(\.windowId)
                .filter { !selectedWindowIds.contains($0) }
                .sorted()
            tasks[index].tmuxBindingPlan = bindingPlan
        }
    }

    private func finalizedTmuxTerminalRestoreContext() -> TmuxTerminalRestoreContext? {
        let bindingPlansByTaskId = Dictionary(
            uniqueKeysWithValues: tasks.compactMap { task -> (String, TmuxTerminalBindingPlan)? in
                guard let bindingPlan = task.tmuxBindingPlan else { return nil }
                return (task.id, bindingPlan)
            }
        )

        if let tmuxTerminalRestoreContext {
            return tmuxTerminalRestoreContext.withBindingPlans(bindingPlansByTaskId)
        }

        guard let snapshot, let workspace else { return nil }
        return TmuxTerminalRestoreContext.initial(
            workspaceWindows: workspace.windows,
            preparedTerminalWindowsById: [:],
            snapshot: snapshot,
            tmuxClients: tmuxClients,
            tmuxClientWindowMap: tmuxClientWindowMap
        ).withBindingPlans(bindingPlansByTaskId)
    }

    private func selectDeterministicTmuxWindow(
        from windows: [SnapshotWindow],
        mappedWindowIds: Set<CGWindowID>,
        preferAXAccessible: Bool = false,
        targetSessionName: String? = nil,
        windowSessionMap: [CGWindowID: String] = [:],
        targetScreenIndex: Int? = nil,
        targetFrame: CGRect? = nil
    ) -> SnapshotWindow? {
        windows.sorted { lhs, rhs in
            if preferAXAccessible {
                let lhsAXRank = lhs.isAXAccessible == true ? 0 : 1
                let rhsAXRank = rhs.isAXAccessible == true ? 0 : 1
                if lhsAXRank != rhsAXRank {
                    return lhsAXRank < rhsAXRank
                }
            }

            let lhsMappedRank = mappedWindowIds.contains(lhs.windowId) ? 0 : 1
            let rhsMappedRank = mappedWindowIds.contains(rhs.windowId) ? 0 : 1
            if lhsMappedRank != rhsMappedRank {
                return lhsMappedRank < rhsMappedRank
            }

            // Session affinity: prefer windows whose current tmux client is already
            // on the target session — avoids unnecessary session switches and prevents
            // duplicate-index windows from being selected over the correct one.
            if let targetSession = targetSessionName {
                let lhsSessionRank = windowSessionMap[lhs.windowId] == targetSession ? 0 : 1
                let rhsSessionRank = windowSessionMap[rhs.windowId] == targetSession ? 0 : 1
                if lhsSessionRank != rhsSessionRank {
                    return lhsSessionRank < rhsSessionRank
                }
            }

            // Screen affinity: among equally-mapped windows, prefer ones on the target screen
            if let targetScreen = targetScreenIndex {
                let lhsScreenRank = (lhs.displayIndex == targetScreen) ? 0 : 1
                let rhsScreenRank = (rhs.displayIndex == targetScreen) ? 0 : 1
                if lhsScreenRank != rhsScreenRank {
                    return lhsScreenRank < rhsScreenRank
                }
            }

            // Frame proximity: prefer windows already near the target position.
            // This prevents same-screen windows from swapping positions on each restore.
            if let target = targetFrame {
                let lhsDist = abs(lhs.frame.origin.x - target.origin.x) + abs(lhs.frame.origin.y - target.origin.y)
                let rhsDist = abs(rhs.frame.origin.x - target.origin.x) + abs(rhs.frame.origin.y - target.origin.y)
                if lhsDist != rhsDist {
                    return lhsDist < rhsDist
                }
            }

            let lhsZ = lhs.zOrderIndex ?? Int.max
            let rhsZ = rhs.zOrderIndex ?? Int.max
            if lhsZ != rhsZ {
                return lhsZ < rhsZ
            }

            return lhs.windowId < rhs.windowId
        }.first
    }

    private func formatFrame(_ frame: CGRect) -> String {
        frame.traceDescription
    }

    private func logRC10Diag(_ message: String, data: [String: String] = [:]) {
        let orderedFields = data
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: " ")
        let suffix = orderedFields.isEmpty ? "" : " \(orderedFields)"
        DeskJigLog.trace(.restorationPlanner, "RC10_DIAG \(message)\(suffix)", runId: runId)
    }

    private func chromeProfileDirectories(in windows: [WorkspaceWindow]) -> Set<String> {
        let directories = windows.compactMap { window in
            let dir = window.chromeState?.profileDirectory ?? ""
            return dir.isEmpty ? nil : dir
        }
        return Set(directories)
    }

    /// Checks if an application is available on the system.
    /// Returns true if the app can be found via stored path or LaunchServices.
    private func isAppAvailable(bundleId: String, applicationPath: String?) -> Bool {
        // 1. Check stored application path
        if let appPath = applicationPath {
            if FileManager.default.fileExists(atPath: appPath) {
                return true
            }
        }

        // 2. Try LaunchServices via NSWorkspace
        if let appUrl = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) {
            if FileManager.default.fileExists(atPath: appUrl.path) {
                return true
            }
        }

        return false
    }

    private static func generateRunId() -> String {
        RestorationRunID.make()
    }
}

// MARK: - Convenience Extensions

extension RestorationPlanBuilder {
    /// Creates a plan in one call with all configuration.
    ///
    /// - Parameters:
    ///   - workspace: The workspace to restore
    ///   - snapshot: The system snapshot
    ///   - lockManager: Optional lock manager
    ///   - screens: Current screen configuration
    ///
    /// - Returns: The completed restoration plan
    ///
    /// ## Example
    ///
    /// ```swift
    /// let plan = await RestorationPlanBuilder.createPlan(
    ///     for: workspace,
    ///     snapshot: snapshot,
    ///     lockManager: lockManager,
    ///     screens: screens
    /// )
    /// ```
    public static func createPlan(
        for workspace: Workspace,
        snapshot: EnhancedSnapshot,
        lockManager: WindowLockManager? = nil,
        screens: [FullScreenInfo] = [],
        resolvedWindowTargets: [UUID: ResolvedWorkspaceWindowTarget] = [:]
    ) async -> RestorationPlan {
        var builder = RestorationPlanBuilder()
            .forWorkspace(workspace)
            .withSnapshot(snapshot)
            .withCurrentScreens(screens)
            .withResolvedWindowTargets(resolvedWindowTargets)

        if let lockManager = lockManager {
            builder = builder.withLockManager(lockManager)
        }

        return await builder
            .analyze()
            .acquireLocks()
            .build()
    }
}
