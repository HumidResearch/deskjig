//  OperationQueueBuilder.swift
//  DeskJigShared

import Foundation

// MARK: - Operation Queue Builder

/// A fluent builder for creating and configuring operation queues.
///
/// `OperationQueueBuilder` provides a chainable API for building queues of
/// operations with configurable execution modes, error handling, timeouts,
/// and progress callbacks.
///
/// ## Overview
///
/// The builder follows a fluent pattern where each configuration method returns
/// `Self`, allowing natural method chaining:
///
/// ```swift
/// let result = await Queue.windows()
///     .add(name: "Find Safari") { Window.find(bundleID: "com.apple.Safari") }
///     .add(name: "Find Chrome") { Window.find(bundleID: "com.google.Chrome") }
///     .parallel()
///     .allSettled()
///     .timeout(.seconds(10))
///     .progress { event in
///         print("[\(event.phase)] \(event.operationName)")
///     }
///     .execute()
/// ```
///
/// ## Building vs Executing
///
/// You can either:
/// - Call `execute()` directly to build and run the queue in one step
/// - Call `build()` to get an `OperationQueue` instance for later execution
///
/// ```swift
/// // Direct execution
/// let result = await builder.execute()
///
/// // Deferred execution
/// let queue = builder.build()
/// // ... later ...
/// let result = await queue.execute()
/// ```
///
/// ## Configuration Options
///
/// | Category | Methods |
/// |----------|---------|
/// | Operations | `add(_:)`, `addAll(_:)` |
/// | Execution | `sequential()`, `parallel()`, `batched(size:)`, `concurrent(max:)` |
/// | Errors | `failFast()`, `continueOnError()` |
/// | Completion | `all()`, `race()`, `allSettled()`, `any()` |
/// | Priority | `highPriority()`, `lowPriority()`, `backgroundPriority()` |
/// | Timeout | `timeout(_:)` |
/// | Callbacks | `progress(_:)`, `onCancellation(_:)` |
///
/// ## See Also
/// - ``Queue`` for static factory methods
/// - ``OperationQueue`` for the queue executor
/// - ``QueueOperation`` for individual operations
@MainActor
public final class OperationQueueBuilder<T: Sendable> {
    private var operations: [QueueOperation<T>] = []
    private var executionMode: ExecutionMode = .parallel
    private var errorStrategy: ErrorHandlingStrategy = .continueOnError
    private var completionStrategy: CompletionStrategy = .allSettled
    private var threadConfig: ThreadConfiguration = .inherit
    private var queueTimeout: Duration?
    private var progressHandler: (@Sendable (ProgressEvent) -> Void)?
    private var cancellationHandler: (@Sendable () -> Void)?

    /// Creates a new empty builder.
    public init() {}

    // MARK: - Adding Operations

    /// Adds an operation to the queue.
    ///
    /// - Parameter operation: The operation to add.
    /// - Returns: Self for chaining.
    ///
    /// ## Example
    ///
    /// ```swift
    /// let findOp = QueueOperation(name: "Find Safari") {
    ///     Window.find(bundleID: "com.apple.Safari")
    /// }
    ///
    /// builder.add(findOp)
    /// ```
    @discardableResult
    public func add(_ operation: QueueOperation<T>) -> Self {
        operations.append(operation)
        return self
    }

    /// Adds an operation with the specified parameters.
    ///
    /// This is a convenience method for creating and adding an operation in one call.
    ///
    /// - Parameters:
    ///   - id: Unique identifier. Defaults to a UUID.
    ///   - name: Human-readable name.
    ///   - timeout: Optional per-operation timeout.
    ///   - dependsOn: ID of an operation this depends on.
    ///   - execute: The async closure to execute.
    /// - Returns: Self for chaining.
    ///
    /// ## Example
    ///
    /// ```swift
    /// builder
    ///     .add(id: "find", name: "Find Safari") {
    ///         Window.find(bundleID: "com.apple.Safari")
    ///     }
    ///     .add(name: "Activate", dependsOn: "find") { result in
    ///         result?.activate()
    ///     }
    /// ```
    @discardableResult
    public func add(
        id: String = UUID().uuidString,
        name: String,
        timeout: Duration? = nil,
        dependsOn: String? = nil,
        execute: @escaping @Sendable () async throws -> T
    ) -> Self {
        let op = QueueOperation(
            id: id,
            name: name,
            timeout: timeout,
            dependsOn: dependsOn,
            execute: execute
        )
        return add(op)
    }

    /// Adds multiple operations to the queue.
    ///
    /// - Parameter operations: The operations to add.
    /// - Returns: Self for chaining.
    @discardableResult
    public func addAll(_ operations: [QueueOperation<T>]) -> Self {
        self.operations.append(contentsOf: operations)
        return self
    }

    // MARK: - Execution Mode

    /// Configures operations to run one at a time, in order.
    ///
    /// - Returns: Self for chaining.
    ///
    /// ## Example
    ///
    /// ```swift
    /// // Operations run in sequence
    /// builder.sequential()
    /// ```
    @discardableResult
    public func sequential() -> Self {
        executionMode = .sequential
        return self
    }

    /// Configures operations to run simultaneously.
    ///
    /// - Returns: Self for chaining.
    ///
    /// ## Example
    ///
    /// ```swift
    /// // All operations start at once
    /// builder.parallel()
    /// ```
    @discardableResult
    public func parallel() -> Self {
        executionMode = .parallel
        return self
    }

    /// Configures operations to run in batches.
    ///
    /// - Parameter size: Maximum operations per batch.
    /// - Returns: Self for chaining.
    ///
    /// ## Example
    ///
    /// ```swift
    /// // Run 5 operations at a time
    /// builder.batched(size: 5)
    /// ```
    @discardableResult
    public func batched(size: Int) -> Self {
        executionMode = .batched(size: size)
        return self
    }

    /// Configures operations to run with limited concurrency.
    ///
    /// Uses an ``AsyncSemaphore`` to limit how many operations run simultaneously.
    ///
    /// - Parameter max: Maximum concurrent operations.
    /// - Returns: Self for chaining.
    ///
    /// ## Example
    ///
    /// ```swift
    /// // Never more than 3 operations running at once
    /// builder.concurrent(max: 3)
    /// ```
    @discardableResult
    public func concurrent(max: Int) -> Self {
        executionMode = .concurrent(maxConcurrency: max)
        return self
    }

    // MARK: - Completion Strategy

    /// Configures the queue to wait for all operations regardless of outcome.
    ///
    /// Similar to `Promise.allSettled()`. The queue never fails.
    ///
    /// - Returns: Self for chaining.
    @discardableResult
    public func allSettled() -> Self {
        completionStrategy = .allSettled
        return self
    }

    // MARK: - Timeout

    /// Sets a timeout for the entire queue.
    ///
    /// If the queue doesn't complete within this duration, all remaining
    /// operations are cancelled.
    ///
    /// - Parameter duration: The timeout duration.
    /// - Returns: Self for chaining.
    ///
    /// ## Example
    ///
    /// ```swift
    /// // Queue must complete within 10 seconds
    /// builder.timeout(.seconds(10))
    /// ```
    @discardableResult
    public func timeout(_ duration: Duration) -> Self {
        queueTimeout = duration
        return self
    }

    // MARK: - Build & Execute

    /// Builds the configured operation queue.
    ///
    /// Returns an ``OperationQueue`` instance that can be executed later
    /// and optionally cancelled.
    ///
    /// - Returns: The configured operation queue.
    ///
    /// ## Example
    ///
    /// ```swift
    /// let queue = builder.build()
    ///
    /// // Execute later
    /// let result = await queue.execute()
    ///
    /// // Or cancel
    /// await queue.cancel()
    /// ```
    public func build() -> OperationQueue<T> {
        OperationQueue(
            operations: operations,
            executionMode: executionMode,
            errorStrategy: errorStrategy,
            completionStrategy: completionStrategy,
            threadConfig: threadConfig,
            queueTimeout: queueTimeout,
            progressHandler: progressHandler,
            onCancellation: cancellationHandler
        )
    }

    /// Builds and executes the queue, returning results.
    ///
    /// This is a convenience method that combines `build()` and `execute()`.
    ///
    /// - Returns: The queue execution results.
    ///
    /// ## Example
    ///
    /// ```swift
    /// let result = await Queue.windows()
    ///     .add(name: "Find Safari") { Window.find(bundleID: "com.apple.Safari") }
    ///     .parallel()
    ///     .execute()
    ///
    /// print("Success: \(result.successCount)/\(result.results.count)")
    /// ```
    public func execute() async -> QueueResult<T> {
        await build().execute()
    }

    // MARK: - Convenience Properties

    /// The number of operations currently in the builder.
    public var operationCount: Int {
        operations.count
    }

    /// Whether the builder has any operations.
    public var isEmpty: Bool {
        operations.isEmpty
    }

    /// The IDs of all operations in the builder.
    public var operationIds: [String] {
        operations.map(\.id)
    }
}
