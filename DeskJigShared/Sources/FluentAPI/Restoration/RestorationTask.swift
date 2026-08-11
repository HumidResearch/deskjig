//  RestorationTask.swift
//  DeskJigShared

import Foundation
import CoreGraphics

// MARK: - Restoration Decision

/// Decision for how to restore a workspace window.
///
/// Each workspace window is analyzed against the current system state
/// to determine the best restoration action. The decision captures
/// both what to do and the necessary parameters.
///
/// ## Overview
///
/// Possible decisions:
/// - `.positionExisting`: Move an already-open window to the target frame
/// - `.openNewWithPath`: Launch an app with a specific directory/file
/// - `.launchApp`: Launch an app that isn't running
/// - `.createChromeWindow`: Create a new Chrome window with profile and tabs
/// - `.reuseChromeWindow`: Reuse an existing Chrome window, restore tabs
/// - `.skip`: Skip restoration (window already in position, etc.)
/// - `.failed`: Cannot determine how to restore
///
/// ## Example
///
/// ```swift
/// switch task.decision {
/// case .positionExisting(let windowId, let frame):
///     await positionWindow(windowId, to: frame)
///
/// case .openNewWithPath(let bundleId, let path, let frame):
///     let window = await launchAppWithPath(bundleId, path: path)
///     await positionWindow(window.id, to: frame)
///
/// case .createChromeWindow(let profile, let tabs, let frame):
///     await ChromeOperations.createWindow(profile: profile, tabs: tabs)
///     // Position the new window
///
/// case .skip(let reason):
///     print("Skipped: \(reason)")
///
/// case .failed(let reason):
///     print("Failed: \(reason)")
/// }
/// ```
///
/// ## See Also
/// - ``RestorationTask``
/// - ``RestorationPlanBuilder``
public indirect enum RestorationDecision: Sendable, CustomStringConvertible {
    /// Position an existing window at the target frame
    case positionExisting(windowId: CGWindowID, targetFrame: CGRect)

    /// Open a new window with a specific path (terminal, IDE)
    case openNewWithPath(bundleId: String, path: String, targetFrame: CGRect)

    /// Launch an app that isn't running, optionally with a follow-up decision
    case launchApp(bundleId: String, then: RestorationDecision?)

    /// Create a new Chrome window with profile and tabs
    case createChromeWindow(profile: String, tabs: [String], targetFrame: CGRect)

    /// Reuse an existing Chrome window, restore tabs
    case reuseChromeWindow(windowId: CGWindowID, tabs: [String], targetFrame: CGRect)

    /// Switch a tmux client in an existing terminal window to a different session
    case switchTmuxSession(windowId: CGWindowID, sessionName: String, targetFrame: CGRect)

    /// Skip restoration with a reason
    case skip(reason: String)

    /// Cannot determine how to restore
    case failed(reason: String)

    public var description: String {
        switch self {
        case .positionExisting(let windowId, let frame):
            return "positionExisting(window=\(windowId), frame=\(Int(frame.origin.x)),\(Int(frame.origin.y)) \(Int(frame.width))x\(Int(frame.height)))"
        case .openNewWithPath(let bundleId, let path, _):
            return "openNewWithPath(bundle=\(bundleId), path=\(path))"
        case .launchApp(let bundleId, let then):
            let thenStr = then.map { ", then=\($0)" } ?? ""
            return "launchApp(bundle=\(bundleId)\(thenStr))"
        case .createChromeWindow(let profile, let tabs, _):
            return "createChromeWindow(profile=\(profile), tabs=\(tabs.count))"
        case .reuseChromeWindow(let windowId, let tabs, _):
            return "reuseChromeWindow(window=\(windowId), tabs=\(tabs.count))"
        case .switchTmuxSession(let windowId, let sessionName, let frame):
            return "switchTmuxSession(window=\(windowId), session=\(sessionName), frame=\(Int(frame.origin.x)),\(Int(frame.origin.y)) \(Int(frame.width))x\(Int(frame.height)))"
        case .skip(let reason):
            return "skip(\(reason))"
        case .failed(let reason):
            return "failed(\(reason))"
        }
    }

    /// Whether this decision requires launching or opening something new.
    public var requiresLaunch: Bool {
        switch self {
        case .openNewWithPath, .launchApp, .createChromeWindow:
            return true
        default:
            return false
        }
    }

    /// Whether this decision positions an existing window.
    public var positionsExisting: Bool {
        switch self {
        case .positionExisting, .reuseChromeWindow, .switchTmuxSession:
            return true
        default:
            return false
        }
    }

    /// Whether this is a failure or skip.
    public var isTerminal: Bool {
        switch self {
        case .skip, .failed:
            return true
        default:
            return false
        }
    }

    /// The target frame if this decision involves positioning.
    public var targetFrame: CGRect? {
        switch self {
        case .positionExisting(_, let frame):
            return frame
        case .openNewWithPath(_, _, let frame):
            return frame
        case .createChromeWindow(_, _, let frame):
            return frame
        case .reuseChromeWindow(_, _, let frame):
            return frame
        case .switchTmuxSession(_, _, let frame):
            return frame
        default:
            return nil
        }
    }

    /// The window ID if this decision involves an existing window.
    public var existingWindowId: CGWindowID? {
        switch self {
        case .positionExisting(let windowId, _):
            return windowId
        case .reuseChromeWindow(let windowId, _, _):
            return windowId
        case .switchTmuxSession(let windowId, _, _):
            return windowId
        default:
            return nil
        }
    }
}

// MARK: - Restoration Task

/// A single restoration task with lock and decision.
///
/// Each `RestorationTask` represents one window from the workspace that
/// needs to be restored. It includes:
/// - The workspace window configuration
/// - The calculated target frame
/// - The restoration decision (position, open, launch, etc.)
/// - The lock held for conflict prevention
/// - The match result explaining how the decision was made
///
/// ## Overview
///
/// Tasks are created by ``RestorationPlanBuilder`` during the analysis
/// phase. Each task goes through these states:
/// 1. Created with decision
/// 2. Lock acquired (if needed)
/// 3. Executed by ``RestorationExecutor``
/// 4. Lock released
///
/// ## Example
///
/// ```swift
/// let task = RestorationTask(
///     workspaceWindow: workspaceWindow,
///     targetFrame: calculatedFrame,
///     decision: .positionExisting(windowId: 12345, targetFrame: calculatedFrame),
///     matchResult: matchResult
/// )
///
/// // Execute the task
/// let result = await executor.execute(task)
/// ```
///
/// ## See Also
/// - ``RestorationDecision``
/// - ``RestorationPlanBuilder``
/// - ``RestorationExecutor``
public struct RestorationTask: Sendable, Identifiable {

    // MARK: - Properties

    /// Unique identifier for this task
    public let id: String

    /// The workspace window configuration being restored
    public let workspaceWindow: WorkspaceWindow

    /// The calculated target frame for positioning
    public let targetFrame: CGRect

    /// The target screen index, if known from workspace mapping.
    public let targetScreenIndex: Int?

    /// The restoration decision
    public var decision: RestorationDecision

    /// The lock held for this task (if any)
    public var lock: WindowLock?

    /// The last lock acquisition result (if any)
    public var lockResult: LockResult?

    /// The match result explaining how the decision was made
    public let matchResult: MatchResult

    /// The Chrome window ID captured during matching (if applicable).
    public let chromeWindowId: Int?

    /// The Chrome match method used during matching (if applicable).
    public let chromeMatchMethod: ChromeWindowMatchMethod?

    /// Resolved Chrome profile identity used for this task (if applicable).
    public let chromeTargetProfile: ChromeTargetProfile?

    /// Per-bundle-ID index for tmux-managed terminal windows (0, 1, 2...).
    /// Used to generate indexed titles like `bento:tmux:managed:0` so multiple
    /// tmux windows of the same terminal can be distinguished during restoration.
    public let tmuxManagedIndex: Int?

    /// Planner-selected tmux binding metadata used to keep execution and cleanup
    /// on the same reuse-vs-launch decision.
    var tmuxBindingPlan: TmuxTerminalBindingPlan?

    /// When this task was created
    public let createdAt: Date

    // MARK: - Initialization

    /// Creates a new restoration task.
    ///
    /// - Parameters:
    ///   - id: Unique identifier (defaults to UUID)
    ///   - workspaceWindow: The saved window configuration
    ///   - targetFrame: Calculated target frame
    ///   - targetScreenIndex: Target screen index
    ///   - decision: The restoration decision
    ///   - lock: Lock held for this task
    ///   - matchResult: How the decision was made
    init(
        id: String = UUID().uuidString,
        workspaceWindow: WorkspaceWindow,
        targetFrame: CGRect,
        targetScreenIndex: Int?,
        decision: RestorationDecision,
        lock: WindowLock? = nil,
        lockResult: LockResult? = nil,
        matchResult: MatchResult,
        chromeWindowId: Int? = nil,
        chromeMatchMethod: ChromeWindowMatchMethod? = nil,
        chromeTargetProfile: ChromeTargetProfile? = nil,
        tmuxManagedIndex: Int? = nil,
        tmuxBindingPlan: TmuxTerminalBindingPlan? = nil
    ) {
        self.id = id
        self.workspaceWindow = workspaceWindow
        self.targetFrame = targetFrame
        self.targetScreenIndex = targetScreenIndex
        self.decision = decision
        self.lock = lock
        self.lockResult = lockResult
        self.matchResult = matchResult
        self.chromeWindowId = chromeWindowId
        self.chromeMatchMethod = chromeMatchMethod
        self.chromeTargetProfile = chromeTargetProfile
        self.tmuxManagedIndex = tmuxManagedIndex
        self.tmuxBindingPlan = tmuxBindingPlan
        self.createdAt = Date()
    }

    // MARK: - Computed Properties

    /// The required lock priority based on the match result.
    public var requiredPriority: LockPriority {
        max(matchResult.suggestedPriority, matchResult.confidencePriority)
    }

    /// Whether this task requires a lock.
    public var requiresLock: Bool {
        decision.positionsExisting
    }

    /// Whether this task has a lock.
    public var hasLock: Bool {
        lock != nil
    }

    /// Whether this task is ready to execute.
    public var isReady: Bool {
        if requiresLock {
            return hasLock
        }
        return !decision.isTerminal
    }

    /// Short description for logging.
    public var shortDescription: String {
        "\(workspaceWindow.appName): \(decision)"
    }
}

// MARK: - Task Result

/// Result of executing a restoration task.
///
/// Captures the outcome of a single task execution including timing
/// and any notes about what happened.
///
/// ## Example
///
/// ```swift
/// let result = await executor.executeTask(task)
///
/// if result.success {
///     print("Restored window \(result.windowId ?? 0) in \(result.durationMs)ms")
/// } else {
///     print("Failed: \(result.notes.joined(separator: ", "))")
/// }
/// ```
public struct TaskResult: Sendable {
    /// The task ID
    public let taskId: String

    /// Whether the task succeeded
    public let success: Bool

    /// The window ID that was restored (if any)
    public let windowId: CGWindowID?

    /// The decision that was executed
    public let decision: RestorationDecision

    /// Execution duration in milliseconds
    public let durationMs: Int

    /// Notes about the execution
    public let notes: [String]

    /// Whether a lock was acquired for this task
    public let lockAcquired: Bool

    /// Time spent waiting for lock in milliseconds
    public let lockWaitMs: Int?

    /// The originally planned window ID when a fallback selected a different window.
    /// Used to protect the planned window from post-restore cleanup even when a
    /// different window was actually operated on.
    public let plannedWindowId: CGWindowID?

    /// tmux terminal binding metadata captured during execution.
    let terminalBinding: TerminalBindingResult?

    init(
        taskId: String,
        success: Bool,
        windowId: CGWindowID? = nil,
        decision: RestorationDecision,
        durationMs: Int,
        notes: [String] = [],
        lockAcquired: Bool = false,
        lockWaitMs: Int? = nil,
        plannedWindowId: CGWindowID? = nil,
        terminalBinding: TerminalBindingResult? = nil
    ) {
        self.taskId = taskId
        self.success = success
        self.windowId = windowId
        self.decision = decision
        self.durationMs = durationMs
        self.notes = notes
        self.lockAcquired = lockAcquired
        self.lockWaitMs = lockWaitMs
        self.plannedWindowId = plannedWindowId
        self.terminalBinding = terminalBinding
    }
}

// MARK: - Restoration Result

/// Aggregate result of executing a restoration plan.
///
/// Summarizes the outcome of all tasks in a restoration plan.
///
/// ## Example
///
/// ```swift
/// let result = await executor.execute(plan)
///
/// print("Restoration complete:")
/// print("  Success: \(result.successCount)/\(result.totalCount)")
/// print("  Duration: \(result.totalDurationMs)ms")
/// ```
public struct RestorationResult: Sendable {
    /// The run ID
    public let runId: String

    /// Whether the overall restoration succeeded
    public let success: Bool

    /// Total execution duration in milliseconds
    public let totalDurationMs: Int

    /// Number of successfully restored windows
    public let successCount: Int

    /// Number of failed windows
    public let failureCount: Int

    /// Number of skipped windows
    public let skippedCount: Int

    /// Individual task results
    public let taskResults: [TaskResult]

    /// Total number of tasks
    public var totalCount: Int {
        taskResults.count
    }

    public init(
        runId: String,
        success: Bool,
        totalDurationMs: Int,
        successCount: Int,
        failureCount: Int,
        skippedCount: Int,
        taskResults: [TaskResult]
    ) {
        self.runId = runId
        self.success = success
        self.totalDurationMs = totalDurationMs
        self.successCount = successCount
        self.failureCount = failureCount
        self.skippedCount = skippedCount
        self.taskResults = taskResults
    }
}
