//  OperationResult.swift
//  DeskJigShared

import Foundation

// MARK: - Operation Outcome

/// The outcome of a single queue operation.
///
/// `OperationOutcome` represents the final state of an operation after execution.
/// It distinguishes between successful completion, failure with an error,
/// cancellation, and timeout - allowing precise handling of each case.
///
/// ## Overview
///
/// ```swift
/// switch result.outcome {
/// case .success(let window):
///     print("Operation succeeded: \(window?.title ?? "nil")")
/// case .failure(let error):
///     print("Operation failed: \(error)")
/// case .cancelled:
///     print("Operation was cancelled")
/// case .timedOut:
///     print("Operation timed out")
/// }
/// ```
///
/// ## See Also
/// - ``SettledResult`` for the complete result including timing
/// - ``QueueResult`` for aggregate results
public enum OperationOutcome<T: Sendable>: Sendable {
    /// The operation completed successfully with a value.
    case success(T)

    /// The operation failed with an error.
    case failure(OperationError)

    /// The operation was cancelled before completion.
    case cancelled

    /// The operation exceeded its timeout duration.
    case timedOut

    /// Returns the success value if present, otherwise `nil`.
    public var value: T? {
        if case .success(let value) = self {
            return value
        }
        return nil
    }

    /// Returns the error if the outcome is a failure, otherwise `nil`.
    public var error: OperationError? {
        if case .failure(let error) = self {
            return error
        }
        return nil
    }

    /// Returns `true` if the operation succeeded.
    public var isSuccess: Bool {
        if case .success = self {
            return true
        }
        return false
    }

    /// Returns `true` if the operation failed (not cancelled or timed out).
    public var isFailure: Bool {
        if case .failure = self {
            return true
        }
        return false
    }

    /// Returns `true` if the operation was cancelled.
    public var isCancelled: Bool {
        if case .cancelled = self {
            return true
        }
        return false
    }

    /// Returns `true` if the operation timed out.
    public var isTimedOut: Bool {
        if case .timedOut = self {
            return true
        }
        return false
    }
}

// MARK: - Operation Error

/// Errors that can occur during queue operation execution.
///
/// `OperationError` provides detailed error information for queue operations,
/// allowing precise error handling and debugging.
///
/// ## Error Categories
///
/// - **Window errors**: Operations that fail due to missing windows
/// - **Operation errors**: General operation failures
/// - **Timing errors**: Timeouts and cancellations
/// - **Dependency errors**: Failed or circular dependencies
/// - **Aggregate errors**: All operations in a queue failed
///
/// ## Example
///
/// ```swift
/// switch error {
/// case .windowNotFound(let description):
///     print("Window not found: \(description)")
/// case .timeout(let duration):
///     print("Timed out after \(duration)")
/// case .dependencyFailed(let opId):
///     print("Dependency '\(opId)' failed")
/// case .circularDependency(let cycle):
///     print("Circular dependency: \(cycle.joined(separator: " -> "))")
/// default:
///     print("Error: \(error)")
/// }
/// ```
public enum OperationError: Error, Sendable, CustomStringConvertible {
    /// A required window was not found.
    ///
    /// - Parameter description: Details about what window was expected.
    case windowNotFound(String)

    /// A general operation failure occurred.
    ///
    /// - Parameter description: Details about what went wrong.
    case operationFailed(String)

    /// The operation exceeded its timeout duration.
    ///
    /// - Parameter duration: The timeout that was exceeded.
    case timeout(Duration)

    /// The operation was explicitly cancelled.
    case cancelled

    /// The entire queue was cancelled.
    case queueCancelled

    /// All operations in the queue failed (for `any` completion strategy).
    ///
    /// - Parameter errors: The individual errors from each operation.
    case allOperationsFailed([OperationError])

    /// No operation succeeded (for `race` or `any` strategies).
    case noSuccessfulOperation

    /// A dependency operation failed, preventing this operation from running.
    ///
    /// - Parameter operationId: The ID of the failed dependency.
    case dependencyFailed(operationId: String)

    /// A circular dependency was detected in the operation graph.
    ///
    /// - Parameter cycle: The operation IDs forming the cycle.
    case circularDependency([String])

    /// The operation threw an unexpected error.
    ///
    /// - Parameter error: The underlying error that was thrown.
    case underlying(any Error & Sendable)

    public var description: String {
        switch self {
        case .windowNotFound(let desc):
            return "Window not found: \(desc)"
        case .operationFailed(let desc):
            return "Operation failed: \(desc)"
        case .timeout(let duration):
            return "Timeout after \(duration)"
        case .cancelled:
            return "Operation cancelled"
        case .queueCancelled:
            return "Queue cancelled"
        case .allOperationsFailed(let errors):
            return "All operations failed (\(errors.count) errors)"
        case .noSuccessfulOperation:
            return "No successful operation"
        case .dependencyFailed(let opId):
            return "Dependency '\(opId)' failed"
        case .circularDependency(let cycle):
            return "Circular dependency: \(cycle.joined(separator: " -> "))"
        case .underlying(let error):
            return "Underlying error: \(error)"
        }
    }
}

// MARK: - Progress Phase

/// The phase of an operation's lifecycle.
///
/// Used in progress callbacks to indicate when an operation starts
/// and when it completes (with its outcome).
public enum ProgressPhase: Sendable {
    /// The operation has started executing.
    case started

    /// The operation has completed with the given outcome.
    case completed
}

// MARK: - Progress Event

/// A progress event emitted during queue execution.
///
/// `ProgressEvent` provides real-time visibility into queue execution,
/// allowing UI updates, logging, and monitoring of operation progress.
///
/// ## Overview
///
/// Progress events are emitted at two points in each operation's lifecycle:
/// 1. When the operation starts (`.started` phase)
/// 2. When the operation completes (`.completed` phase)
///
/// ## Example
///
/// ```swift
/// let result = await Queue.windows()
///     .add(name: "Find Safari") { Window.find(bundleID: "com.apple.Safari") }
///     .add(name: "Find Chrome") { Window.find(bundleID: "com.google.Chrome") }
///     .progress { event in
///         print("[\(event.phase)] \(event.operationName)")
///         print("Progress: \(event.completed)/\(event.total)")
///     }
///     .execute()
/// ```
///
/// ## See Also
/// - ``ProgressPhase`` for the event phases
/// - ``OperationQueueBuilder/progress(_:)`` for setting up progress callbacks
public struct ProgressEvent: Sendable {
    /// The unique identifier of the operation.
    public let operationId: String

    /// The human-readable name of the operation.
    public let operationName: String

    /// The current phase of the operation.
    public let phase: ProgressPhase

    /// The number of operations completed so far.
    public let completed: Int

    /// The total number of operations in the queue.
    public let total: Int

    /// When this event occurred.
    public let timestamp: Date

    /// The index of this operation in the queue.
    public let index: Int

    /// Creates a new progress event.
    public init(
        operationId: String,
        operationName: String,
        phase: ProgressPhase,
        completed: Int,
        total: Int,
        timestamp: Date = Date(),
        index: Int
    ) {
        self.operationId = operationId
        self.operationName = operationName
        self.phase = phase
        self.completed = completed
        self.total = total
        self.timestamp = timestamp
        self.index = index
    }

    /// The completion percentage (0.0 to 1.0).
    public var progress: Double {
        guard total > 0 else { return 0 }
        return Double(completed) / Double(total)
    }

    /// The completion percentage as an integer (0 to 100).
    public var progressPercent: Int {
        Int(progress * 100)
    }
}

// MARK: - Settled Result

/// The complete result of a single operation after execution.
///
/// `SettledResult` captures everything about an operation's execution:
/// its outcome, timing information, and identification details. This is
/// returned for each operation in a queue regardless of success or failure.
///
/// ## Overview
///
/// ```swift
/// for result in queueResult.results {
///     print("[\(result.index)] \(result.operationName)")
///     print("  Duration: \(result.durationMs)ms")
///     print("  Outcome: \(result.outcome.isSuccess ? "success" : "failed")")
/// }
/// ```
///
/// ## See Also
/// - ``QueueResult`` for the aggregate result
/// - ``OperationOutcome`` for the outcome type
public struct SettledResult<T: Sendable>: Sendable {
    /// The unique identifier of the operation.
    public let operationId: String

    /// The human-readable name of the operation.
    public let operationName: String

    /// The index of this operation in the original queue.
    public let index: Int

    /// The outcome of the operation.
    public let outcome: OperationOutcome<T>

    /// The duration of the operation in milliseconds.
    public let durationMs: Int

    /// When the operation started executing.
    public let startedAt: Date

    /// When the operation completed.
    public let completedAt: Date

    /// Creates a new settled result.
    public init(
        operationId: String,
        operationName: String,
        index: Int,
        outcome: OperationOutcome<T>,
        durationMs: Int,
        startedAt: Date,
        completedAt: Date
    ) {
        self.operationId = operationId
        self.operationName = operationName
        self.index = index
        self.outcome = outcome
        self.durationMs = durationMs
        self.startedAt = startedAt
        self.completedAt = completedAt
    }

    /// Returns `true` if this operation succeeded.
    public var succeeded: Bool {
        outcome.isSuccess
    }

    /// Returns the success value if present.
    public var value: T? {
        outcome.value
    }

    /// Returns the error if this operation failed.
    public var error: OperationError? {
        outcome.error
    }
}

// MARK: - Queue Result

/// The aggregate result of executing a queue of operations.
///
/// `QueueResult` provides a comprehensive view of queue execution, including
/// all individual results, aggregate statistics, and timing information.
///
/// ## Overview
///
/// ```swift
/// let result = await Queue.windows()
///     .add(name: "Op 1") { ... }
///     .add(name: "Op 2") { ... }
///     .execute()
///
/// print("Total time: \(result.totalDurationMs)ms")
/// print("Success: \(result.successCount)/\(result.results.count)")
/// print("All succeeded: \(result.succeeded)")
/// ```
///
/// ## Accessing Results
///
/// ```swift
/// // Get the first successful result
/// if let first = result.firstSuccess {
///     print("First success: \(first)")
/// }
///
/// // Get all successful values
/// let windows = result.successfulValues
///
/// // Check for errors
/// if let error = result.firstError {
///     print("First error: \(error)")
/// }
/// ```
///
/// ## See Also
/// - ``SettledResult`` for individual operation results
/// - ``OperationQueue/execute()`` for executing the queue
public struct QueueResult<T: Sendable>: Sendable {
    /// All individual operation results.
    public let results: [SettledResult<T>]

    /// Total duration of queue execution in milliseconds.
    public let totalDurationMs: Int

    /// When queue execution started.
    public let startedAt: Date

    /// When queue execution completed.
    public let completedAt: Date

    /// Whether the queue was cancelled during execution.
    public let wasCancelled: Bool

    /// Creates a new queue result.
    public init(
        results: [SettledResult<T>],
        totalDurationMs: Int,
        startedAt: Date,
        completedAt: Date,
        wasCancelled: Bool = false
    ) {
        self.results = results
        self.totalDurationMs = totalDurationMs
        self.startedAt = startedAt
        self.completedAt = completedAt
        self.wasCancelled = wasCancelled
    }

    // MARK: - Computed Statistics

    /// The number of operations that succeeded.
    public var successCount: Int {
        results.filter { $0.outcome.isSuccess }.count
    }

    /// The number of operations that failed.
    public var failureCount: Int {
        results.filter { $0.outcome.isFailure }.count
    }

    /// The number of operations that were cancelled.
    public var cancelledCount: Int {
        results.filter { $0.outcome.isCancelled }.count
    }

    /// The number of operations that timed out.
    public var timedOutCount: Int {
        results.filter { $0.outcome.isTimedOut }.count
    }

    /// Returns `true` if all operations succeeded.
    public var succeeded: Bool {
        !results.isEmpty && results.allSatisfy { $0.outcome.isSuccess }
    }

    /// Returns `true` if any operation succeeded.
    public var hasSuccess: Bool {
        results.contains { $0.outcome.isSuccess }
    }

    /// Returns `true` if any operation failed.
    public var hasFailure: Bool {
        results.contains { $0.outcome.isFailure }
    }

    /// The first successful value, if any.
    public var firstSuccess: T? {
        results.first { $0.outcome.isSuccess }?.value
    }

    /// The first error encountered, if any.
    public var firstError: OperationError? {
        results.first { $0.outcome.isFailure }?.error
    }

    /// All successful values from the queue.
    public var successfulValues: [T] {
        results.compactMap { $0.value }
    }

    /// All errors from the queue.
    public var errors: [OperationError] {
        results.compactMap { $0.error }
    }

    /// Results sorted by their original index.
    public var resultsByIndex: [SettledResult<T>] {
        results.sorted { $0.index < $1.index }
    }

    /// Results sorted by completion time.
    public var resultsByCompletionTime: [SettledResult<T>] {
        results.sorted { $0.completedAt < $1.completedAt }
    }

    /// The longest running operation, if any.
    public var slowestOperation: SettledResult<T>? {
        results.max { $0.durationMs < $1.durationMs }
    }

    /// The fastest completed operation, if any.
    public var fastestOperation: SettledResult<T>? {
        results.min { $0.durationMs < $1.durationMs }
    }

    /// Average operation duration in milliseconds.
    public var averageDurationMs: Int {
        guard !results.isEmpty else { return 0 }
        let total = results.reduce(0) { $0 + $1.durationMs }
        return total / results.count
    }
}

// MARK: - CustomStringConvertible

extension QueueResult: CustomStringConvertible {
    /// A debug description of the queue result.
    public var description: String {
        var lines: [String] = []
        lines.append("QueueResult:")
        lines.append("  Total: \(results.count) operations in \(totalDurationMs)ms")
        lines.append("  Success: \(successCount), Failed: \(failureCount), Cancelled: \(cancelledCount), Timed out: \(timedOutCount)")

        if let slowest = slowestOperation {
            lines.append("  Slowest: \(slowest.operationName) (\(slowest.durationMs)ms)")
        }

        if let firstErr = firstError {
            lines.append("  First error: \(firstErr)")
        }

        return lines.joined(separator: "\n")
    }
}
