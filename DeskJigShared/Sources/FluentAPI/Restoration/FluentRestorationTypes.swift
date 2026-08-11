//  FluentRestorationTypes.swift
//  DeskJigShared

import Foundation

// MARK: - Fluent Restoration Result

/// Complete result of a Fluent API workspace restoration.
///
/// Contains detailed information about the restoration including:
/// - Overall success status
/// - Timing information
/// - The restoration plan that was executed
/// - Individual task results
///
/// ## Example
///
/// ```swift
/// let result = try await FluentWorkspaceRestorer.shared.restore(workspace: workspace)
///
/// print("Restoration \(result.success ? "succeeded" : "failed")")
/// print("Restored \(result.windowsRestored)/\(result.windowsTotal) windows")
/// print("Duration: \(result.totalDurationMs)ms")
/// ```
///
/// ## See Also
/// - ``FluentWorkspaceRestorer``
/// - ``RestorationPlan``
public struct FluentRestorationResult: Sendable {
    /// Whether the overall restoration succeeded
    public let success: Bool

    /// Unique run ID for this restoration
    public let runId: String

    /// Total duration in milliseconds
    public let totalDurationMs: Int

    /// Number of successfully restored windows
    public let windowsRestored: Int

    /// Number of failed windows
    public let windowsFailed: Int

    /// Number of skipped windows
    public let windowsSkipped: Int

    /// Total number of windows in the workspace
    public var windowsTotal: Int {
        windowsRestored + windowsFailed + windowsSkipped
    }

    /// The restoration plan that was executed
    public let plan: RestorationPlan

    /// Individual task results
    public let taskResults: [TaskResult]

    /// Duration breakdown
    public let snapshotDurationMs: Int
    public let planDurationMs: Int
    public let executeDurationMs: Int

    /// Evaluation of the restoration quality
    public struct Evaluation: Sendable {
        public let isPerfect: Bool
        public let issues: [String]
        
        public init(isPerfect: Bool, issues: [String]) {
            self.isPerfect = isPerfect
            self.issues = issues
        }
    }
    public let evaluation: Evaluation?

    public init(
        success: Bool,
        runId: String,
        totalDurationMs: Int,
        windowsRestored: Int,
        windowsFailed: Int,
        windowsSkipped: Int,
        plan: RestorationPlan,
        taskResults: [TaskResult],
        snapshotDurationMs: Int = 0,
        planDurationMs: Int = 0,
        executeDurationMs: Int = 0,
        evaluation: Evaluation? = nil
    ) {
        self.success = success
        self.runId = runId
        self.totalDurationMs = totalDurationMs
        self.windowsRestored = windowsRestored
        self.windowsFailed = windowsFailed
        self.windowsSkipped = windowsSkipped
        self.plan = plan
        self.taskResults = taskResults
        self.snapshotDurationMs = snapshotDurationMs
        self.planDurationMs = planDurationMs
        self.executeDurationMs = executeDurationMs
        self.evaluation = evaluation
    }
}

// MARK: - Restoration Options

/// Controls how restoration phases are scheduled.
public enum RestorationPhaseExecutionMode: Sendable {
    /// Automatically choose a mode based on other options.
    case automatic
    /// Run phases sequentially (other → slowStart → terminal → IDE → Chrome).
    case sequential
    /// Run phases concurrently once their snapshots are ready.
    /// Note: slowStart phase always runs after other parallel phases.
    case parallel
}

/// Configuration options for workspace restoration.
///
/// Controls various aspects of the restoration process including
/// timeouts, concurrency, and matching behavior.
///
/// ## Example
///
/// ```swift
/// let options = RestorationOptions(
///     lockTimeout: .seconds(15),
///     maxConcurrency: 6,
///     matchConfiguration: .pathFirst
/// )
///
/// let result = try await restorer.restore(workspace: workspace, options: options)
/// ```
public struct RestorationOptions: Sendable {
    /// Whether restore may request user assignment vs fail immediately.
    public var preparationMode: WorkspaceRestorePreparationMode

    /// Timeout for lock acquisition
    public var lockTimeout: Duration

    /// Match configuration for window matching
    public var matchConfiguration: MatchConfiguration

    /// Maximum concurrent task execution
    public var maxConcurrency: Int

    /// Task timeout
    public var taskTimeout: Duration

    /// Phase execution mode (sequential vs parallel).
    public var phaseExecutionMode: RestorationPhaseExecutionMode

    /// Whether to include Chrome capture in snapshot
    public var includeChromeCapture: Bool

    /// Whether to include AX enrichment in snapshot
    public var includeAXEnrichment: Bool

    /// Whether to hide all apps before restore
    public var hideAllAppsBeforeRestore: Bool

    /// Method for Chrome tab supplementation
    public var chromeFetchMethod: ChromeFetchMethod

    /// Method for terminal working directory supplementation
    public var terminalFetchMethod: TerminalFetchMethod

    /// Method for IDE document path supplementation
    public var ideFetchMethod: IDEFetchMethod

    /// Matching strategy for Chrome windows
    public var chromeMatchMethod: MatchMethod

    /// When enabled, force deterministic sequential positioning for clamp compensation.
    public var deterministicPositioningForClampCompensation: Bool

    /// Maximum number of automatic restoration retries
    public var maxRetries: Int

    /// Logical trigger source for this restore (for example, "quick-switch").
    public var launchSource: String

    /// Callback invoked when a missing/deleted app is detected during restoration planning.
    /// Called on MainActor with (appName, bundleId).
    public var onMissingAppDetected: (@MainActor @Sendable (String, String) -> Void)?

    /// Default restoration options.
    public static let `default` = RestorationOptions()

    /// Fast options with reduced timeouts.
    public static let fast = RestorationOptions(
        lockTimeout: .seconds(5),
        maxConcurrency: 8,
        taskTimeout: .seconds(15)
    )

    public init(
        preparationMode: WorkspaceRestorePreparationMode = .nonInteractive,
        lockTimeout: Duration = .seconds(10),
        matchConfiguration: MatchConfiguration = .default,
        maxConcurrency: Int = 4,
        taskTimeout: Duration = .seconds(30),
        phaseExecutionMode: RestorationPhaseExecutionMode = .automatic,
        includeChromeCapture: Bool = true,
        includeAXEnrichment: Bool = true,
        hideAllAppsBeforeRestore: Bool = false,
        chromeFetchMethod: ChromeFetchMethod = .appleScript,
        terminalFetchMethod: TerminalFetchMethod = .axWithLsofFallback,
        ideFetchMethod: IDEFetchMethod = .cursorStateWithAXFallback,
        chromeMatchMethod: MatchMethod = .chromeProfile,
        deterministicPositioningForClampCompensation: Bool = true,
        maxRetries: Int = 1,
        launchSource: String = "unknown",
        onMissingAppDetected: (@MainActor @Sendable (String, String) -> Void)? = nil
    ) {
        self.preparationMode = preparationMode
        self.lockTimeout = lockTimeout
        self.matchConfiguration = matchConfiguration
        self.maxConcurrency = maxConcurrency
        self.taskTimeout = taskTimeout
        self.phaseExecutionMode = phaseExecutionMode
        self.includeChromeCapture = includeChromeCapture
        self.includeAXEnrichment = includeAXEnrichment
        self.hideAllAppsBeforeRestore = hideAllAppsBeforeRestore
        self.chromeFetchMethod = chromeFetchMethod
        self.terminalFetchMethod = terminalFetchMethod
        self.ideFetchMethod = ideFetchMethod
        self.chromeMatchMethod = chromeMatchMethod
        self.deterministicPositioningForClampCompensation = deterministicPositioningForClampCompensation
        self.maxRetries = maxRetries
        self.launchSource = launchSource
        self.onMissingAppDetected = onMissingAppDetected
    }

    /// Returns a copy of these options after applying `mutate`. Single chokepoint so adding
    /// a new field no longer requires editing every copy-builder below.
    public func with(_ mutate: (inout RestorationOptions) -> Void) -> RestorationOptions {
        var copy = self
        mutate(&copy)
        return copy
    }

    /// Creates a copy of these options with the specified missing app callback.
    public func withMissingAppCallback(
        _ callback: @escaping @MainActor @Sendable (String, String) -> Void
    ) -> RestorationOptions {
        with { $0.onMissingAppDetected = callback }
    }

    /// Creates a copy of these options with hide-all-apps behavior overridden.
    public func withHideAllAppsBeforeRestore(_ enabled: Bool) -> RestorationOptions {
        with { $0.hideAllAppsBeforeRestore = enabled }
    }

    /// Creates a copy of these options with deterministic clamp-safe positioning behavior overridden.
    public func withDeterministicPositioningForClampCompensation(_ enabled: Bool) -> RestorationOptions {
        with { $0.deterministicPositioningForClampCompensation = enabled }
    }

    /// Creates a copy of these options with restore launch source metadata.
    public func withLaunchSource(_ source: String) -> RestorationOptions {
        with { $0.launchSource = source }
    }

    public func withPreparationMode(_ mode: WorkspaceRestorePreparationMode) -> RestorationOptions {
        with { $0.preparationMode = mode }
    }
}

// MARK: - Errors

/// Errors that can occur during restoration.
public enum RestorationError: LocalizedError {
    case cancelled
    case noWorkspace
    case snapshotFailed
    case planningFailed(String)
    case executionFailed(String)
    case assignmentRequired(String)
    case invalidWorkspace(String)
    case unresolvedDisplays(String)

    public var errorDescription: String? {
        switch self {
        case .cancelled:
            return "Restoration was cancelled"
        case .noWorkspace:
            return "No workspace provided"
        case .snapshotFailed:
            return "Failed to capture system snapshot"
        case .planningFailed(let reason):
            return "Planning failed: \(reason)"
        case .executionFailed(let reason):
            return "Execution failed: \(reason)"
        case .assignmentRequired(let reason):
            return reason
        case .invalidWorkspace(let reason):
            return reason
        case .unresolvedDisplays(let reason):
            return reason
        }
    }
}
