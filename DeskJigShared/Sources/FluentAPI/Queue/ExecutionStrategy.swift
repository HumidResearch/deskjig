//  ExecutionStrategy.swift
//  DeskJigShared

import Foundation

// MARK: - Execution Mode

/// How operations in a queue should be executed.
///
/// `ExecutionMode` determines the concurrency behavior of queue execution.
/// Choose based on your requirements for parallelism, ordering, and resource usage.
///
/// ## Overview
///
/// | Mode | Behavior | Use Case |
/// |------|----------|----------|
/// | `.sequential` | One at a time, in order | Dependencies, rate limiting |
/// | `.parallel` | All at once | Independent operations |
/// | `.batched(size:)` | Groups of N | Balanced throughput |
/// | `.concurrent(max:)` | Limited parallelism | Resource constraints |
///
/// ## Example
///
/// ```swift
/// // Run operations one at a time
/// Queue.windows()
///     .sequential()
///     .execute()
///
/// // Run up to 3 operations concurrently
/// Queue.windows()
///     .concurrent(max: 3)
///     .execute()
/// ```
///
/// ## See Also
/// - ``OperationQueueBuilder`` for setting execution mode
/// - ``AsyncSemaphore`` for concurrency limiting implementation
public enum ExecutionMode: Sendable, Equatable {
    /// Execute operations one at a time, in order.
    ///
    /// Each operation waits for the previous one to complete before starting.
    /// This is the safest mode for operations with dependencies or when
    /// operations must not overlap.
    case sequential

    /// Execute all operations simultaneously.
    ///
    /// All operations start at the same time (or as quickly as the system allows).
    /// Best for independent operations that don't share state.
    case parallel

    /// Execute operations in batches of the specified size.
    ///
    /// Operations are grouped into batches of `size`. Each batch runs in parallel,
    /// but the next batch waits for all operations in the current batch to complete.
    ///
    /// - Parameter size: The maximum number of operations per batch.
    case batched(size: Int)

    /// Execute with limited concurrency using a semaphore.
    ///
    /// Up to `maxConcurrency` operations run at once. As operations complete,
    /// new ones start to maintain the concurrency level. Uses ``AsyncSemaphore``
    /// internally.
    ///
    /// - Parameter maxConcurrency: Maximum concurrent operations.
    case concurrent(maxConcurrency: Int)
}

// MARK: - Error Handling Strategy

/// How errors should be handled during queue execution.
///
/// `ErrorHandlingStrategy` determines what happens when an operation fails.
/// This affects whether remaining operations continue or are cancelled.
///
/// ## Overview
///
/// | Strategy | Behavior |
/// |----------|----------|
/// | `.failFast` | Stop on first error, cancel remaining |
/// | `.continueOnError` | Continue executing all operations |
///
/// ## Example
///
/// ```swift
/// // Stop immediately if any operation fails
/// Queue.windows()
///     .failFast()
///     .execute()
///
/// // Continue even if some operations fail
/// Queue.windows()
///     .continueOnError()
///     .execute()
/// ```
///
/// ## See Also
/// - ``CompletionStrategy`` for how completion is determined
public enum ErrorHandlingStrategy: Sendable, Equatable {
    /// Stop execution on the first error.
    ///
    /// When an operation fails, all remaining operations are cancelled and
    /// the queue completes immediately. Results include all operations that
    /// completed before the failure.
    case failFast

    /// Continue execution even when errors occur.
    ///
    /// All operations run regardless of individual failures. The final result
    /// contains the outcomes of all operations, including failures.
    case continueOnError
}

// MARK: - Completion Strategy

/// When and how a queue completes.
///
/// `CompletionStrategy` provides Promise-like semantics for determining
/// when a queue is considered complete and what results are returned.
///
/// ## Overview
///
/// | Strategy | Completes When | Fails When |
/// |----------|---------------|------------|
/// | `.all` | All succeed | Any fails |
/// | `.race` | First succeeds | First completes (if error) |
/// | `.allSettled` | All complete | Never (always succeeds) |
/// | `.any` | First succeeds | All fail |
///
/// ## Example
///
/// ```swift
/// // Wait for all - fail if any fails
/// let result = await Queue.all([op1, op2, op3])
///
/// // First successful result wins
/// let browser = await Queue.race([
///     QueueOperations.find(bundleID: "com.google.Chrome"),
///     QueueOperations.find(bundleID: "com.apple.Safari"),
/// ])
///
/// // Get all results, including failures
/// let settled = await Queue.allSettled([op1, op2, op3])
///
/// // Any success is enough
/// let any = await Queue.any([op1, op2, op3])
/// ```
///
/// ## See Also
/// - ``Queue`` for static methods using these strategies
public enum CompletionStrategy: Sendable, Equatable {
    /// Wait for all operations; fail if any fails.
    ///
    /// Similar to `Promise.all()`. The queue succeeds only if all operations
    /// succeed. If any operation fails, the queue fails with that error.
    ///
    /// - Results contain all operation outcomes
    /// - `QueueResult.succeeded` is `true` only if all operations succeeded
    case all

    /// Return on first success; cancel remaining operations.
    ///
    /// Similar to `Promise.race()`. As soon as one operation succeeds, remaining
    /// operations are cancelled and the queue completes with that result.
    /// If the first operation to complete fails, that error is returned.
    ///
    /// - Remaining operations are cancelled after first success
    /// - Useful for finding the first available resource
    case race

    /// Wait for all operations; never fails.
    ///
    /// Similar to `Promise.allSettled()`. All operations run to completion
    /// regardless of individual outcomes. The queue itself never fails.
    ///
    /// - Results contain all operation outcomes (success, failure, cancelled, timeout)
    /// - `QueueResult.succeeded` reflects whether all operations succeeded
    /// - Useful when you need to know the outcome of every operation
    case allSettled

    /// Return on first success; fail only if all fail.
    ///
    /// Similar to `Promise.any()`. The queue succeeds as soon as any operation
    /// succeeds. It only fails if every single operation fails.
    ///
    /// - Continues running until first success or all complete
    /// - Useful when any successful result is acceptable
    case any
}

// MARK: - Thread Configuration

/// Task priority configuration for queue execution.
///
/// `ThreadConfiguration` controls the priority at which operations execute.
/// Higher priority operations are scheduled before lower priority ones.
///
/// ## Overview
///
/// ```swift
/// // High priority for user-visible operations
/// Queue.windows()
///     .highPriority()
///     .execute()
///
/// // Background priority for non-urgent work
/// Queue.windows()
///     .backgroundPriority()
///     .execute()
/// ```
///
/// ## Priority Levels
///
/// From highest to lowest:
/// 1. `.userInitiated` - Direct user action
/// 2. `.high` - High priority system work
/// 3. `.medium` - Default priority
/// 4. `.low` - Low priority work
/// 5. `.utility` - Long-running utility work
/// 6. `.background` - Non-time-sensitive work
///
/// ## See Also
/// - `TaskPriority` for underlying Swift Concurrency priorities
public enum ThreadConfiguration: Sendable, Equatable {
    /// Inherit priority from the calling task.
    ///
    /// The queue runs at the same priority as the code that calls `execute()`.
    case inherit

    /// Run at a specific task priority.
    ///
    /// - Parameter priority: The `TaskPriority` to use.
    case priority(TaskPriority)

    // MARK: - Convenience Presets

    /// High priority - for important, user-visible work.
    public static var high: ThreadConfiguration { .priority(.high) }

    /// Medium priority - the default.
    public static var medium: ThreadConfiguration { .priority(.medium) }

    /// Low priority - for less important work.
    public static var low: ThreadConfiguration { .priority(.low) }

    /// Background priority - for non-time-sensitive work.
    public static var background: ThreadConfiguration { .priority(.background) }

    /// User-initiated priority - for direct user actions.
    public static var userInitiated: ThreadConfiguration { .priority(.userInitiated) }

    /// Utility priority - for long-running utility work.
    public static var utility: ThreadConfiguration { .priority(.utility) }

    /// The underlying TaskPriority value.
    public var taskPriority: TaskPriority? {
        switch self {
        case .inherit:
            return nil
        case .priority(let p):
            return p
        }
    }
}
