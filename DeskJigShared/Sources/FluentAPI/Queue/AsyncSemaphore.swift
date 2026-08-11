//  AsyncSemaphore.swift
//  DeskJigShared

import Foundation

/// An actor-based semaphore for limiting concurrent async operations.
///
/// `AsyncSemaphore` provides a modern Swift Concurrency approach to limiting the number
/// of concurrent operations. Unlike traditional semaphores, it integrates seamlessly
/// with async/await and cooperative cancellation.
///
/// ## Overview
///
/// Use `AsyncSemaphore` when you need to limit how many operations run simultaneously.
/// Common use cases include:
/// - Limiting concurrent network requests
/// - Throttling window operations to prevent system overload
/// - Rate limiting API calls
///
/// ## Basic Usage
///
/// ```swift
/// let semaphore = AsyncSemaphore(permits: 3)
///
/// // In an async context:
/// await semaphore.wait()
/// defer { Task { await semaphore.signal() } }
///
/// // Critical section - only 3 concurrent executions
/// await performOperation()
/// ```
///
/// ## With TaskGroup
///
/// ```swift
/// let semaphore = AsyncSemaphore(permits: 3)
///
/// await withTaskGroup(of: Void.self) { group in
///     for item in items {
///         group.addTask {
///             await semaphore.wait()
///             defer { Task { await semaphore.signal() } }
///             await process(item)
///         }
///     }
/// }
/// ```
///
/// ## Thread Safety
///
/// As an actor, `AsyncSemaphore` is inherently thread-safe. All access to internal
/// state is serialized through the actor's mailbox, preventing data races.
///
/// ## See Also
/// - ``OperationQueue`` for the queue that uses this semaphore
/// - ``ExecutionMode/concurrent(maxConcurrency:)`` for queue-level concurrency limiting
public actor AsyncSemaphore {
    /// Current number of available permits
    private var permits: Int

    /// Queue of waiters blocked on acquiring a permit
    private var waiters: [CheckedContinuation<Void, Never>] = []

    /// Creates a new semaphore with the specified number of permits.
    ///
    /// - Parameter permits: The maximum number of concurrent operations allowed.
    ///   Must be greater than zero.
    ///
    /// - Precondition: `permits > 0`. A semaphore with zero permits would
    ///   immediately deadlock.
    ///
    /// ## Example
    ///
    /// ```swift
    /// // Allow up to 3 concurrent operations
    /// let semaphore = AsyncSemaphore(permits: 3)
    ///
    /// // Allow only 1 operation at a time (mutex behavior)
    /// let mutex = AsyncSemaphore(permits: 1)
    /// ```
    public init(permits: Int) {
        precondition(permits > 0, "Permits must be positive")
        self.permits = permits
    }

    /// Waits to acquire a permit.
    ///
    /// If a permit is available, it is acquired immediately and the method returns.
    /// If no permits are available, the caller suspends until a permit becomes
    /// available through another task calling ``signal()``.
    ///
    /// Waiters are served in FIFO order - the first task to wait is the first
    /// to be resumed when a permit becomes available.
    ///
    /// ## Example
    ///
    /// ```swift
    /// await semaphore.wait()
    /// defer { Task { await semaphore.signal() } }
    ///
    /// // Protected section
    /// await performOperation()
    /// ```
    ///
    /// ## Cancellation
    ///
    /// This method does not check for task cancellation. If you need cancellation
    /// support, check `Task.isCancelled` before or after waiting.
    ///
    /// ## See Also
    /// - ``signal()`` to release a permit
    public func wait() async {
        if permits > 0 {
            permits -= 1
            return
        }

        // No permits available, suspend until one is released
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    /// Releases a permit, potentially resuming a waiting task.
    ///
    /// If there are tasks waiting for a permit, the first one in the queue is
    /// resumed. If no tasks are waiting, the permit count is incremented,
    /// making it available for future `wait()` calls.
    ///
    /// - Important: Always call `signal()` after acquiring a permit with `wait()`.
    ///   Failing to do so will permanently reduce the semaphore's capacity.
    ///   Use `defer` to ensure `signal()` is called even if errors occur.
    ///
    /// ## Example
    ///
    /// ```swift
    /// await semaphore.wait()
    /// defer { Task { await semaphore.signal() } }
    ///
    /// try await riskyOperation()  // signal() called even if this throws
    /// ```
    ///
    /// ## See Also
    /// - ``wait()`` to acquire a permit
    public func signal() {
        if let waiter = waiters.first {
            waiters.removeFirst()
            waiter.resume()
        } else {
            permits += 1
        }
    }

}
