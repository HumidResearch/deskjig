//  OperationQueue.swift
//  DeskJigShared

import Foundation

// MARK: - Operation Queue

/// An actor that manages and executes a queue of operations.
///
/// `OperationQueue` is the execution engine for the queue system. It coordinates
/// operation execution according to the configured execution mode, error handling
/// strategy, and completion strategy.
///
/// ## Overview
///
/// You typically don't create `OperationQueue` directly. Instead, use
/// ``OperationQueueBuilder`` or the static methods on ``Queue``:
///
/// ```swift
/// // Via builder
/// let result = await Queue.windows()
///     .add(name: "Find Safari") { Window.find(bundleID: "com.apple.Safari") }
///     .parallel()
///     .execute()
///
/// // Via static method
/// let result = await Queue.all([op1, op2, op3])
/// ```
///
/// ## Execution
///
/// When `execute()` is called, the queue:
/// 1. Validates dependencies (checks for circular dependencies)
/// 2. Resolves execution order based on dependencies
/// 3. Executes operations according to the execution mode
/// 4. Emits progress events as operations start and complete
/// 5. Handles timeouts and cancellation
/// 6. Returns a ``QueueResult`` with all outcomes
///
/// ## Cancellation
///
/// Call `cancel()` to immediately cancel all running operations:
///
/// ```swift
/// let queue = Queue.windows()
///     .add(name: "Long operation") { ... }
///     .build()
///
/// Task {
///     await queue.cancel()
/// }
///
/// let result = await queue.execute()
/// print("Cancelled: \(result.wasCancelled)")
/// ```
///
/// ## See Also
/// - ``OperationQueueBuilder`` for building queues
/// - ``Queue`` for static factory methods
/// - ``QueueResult`` for execution results
public actor OperationQueue<T: Sendable> {
    // MARK: - Configuration

    private let operations: [QueueOperation<T>]
    private let executionMode: ExecutionMode
    private let errorStrategy: ErrorHandlingStrategy
    private let completionStrategy: CompletionStrategy
    private let queueTimeout: Duration?
    private let progressHandler: (@Sendable (ProgressEvent) -> Void)?
    private let onCancellation: (@Sendable () -> Void)?

    // MARK: - State

    private var isCancelled = false
    private var completedResults: [String: SettledResult<T>] = [:]
    private var completedCount = 0

    // MARK: - Initialization

    /// Creates a new operation queue with the specified configuration.
    ///
    /// - Parameters:
    ///   - operations: The operations to execute.
    ///   - executionMode: How operations should be scheduled.
    ///   - errorStrategy: How errors should be handled.
    ///   - completionStrategy: When the queue is considered complete.
    ///   - threadConfig: Task priority configuration.
    ///   - queueTimeout: Optional timeout for the entire queue.
    ///   - progressHandler: Callback for progress events.
    ///   - onCancellation: Callback when the queue is cancelled.
    public init(
        operations: [QueueOperation<T>],
        executionMode: ExecutionMode,
        errorStrategy: ErrorHandlingStrategy,
        completionStrategy: CompletionStrategy,
        threadConfig: ThreadConfiguration,
        queueTimeout: Duration?,
        progressHandler: (@Sendable (ProgressEvent) -> Void)?,
        onCancellation: (@Sendable () -> Void)?
    ) {
        self.operations = operations
        self.executionMode = executionMode
        self.errorStrategy = errorStrategy
        self.completionStrategy = completionStrategy
        self.queueTimeout = queueTimeout
        self.progressHandler = progressHandler
        self.onCancellation = onCancellation
    }

    // MARK: - Public API

    /// Executes the queue and returns results.
    ///
    /// This method runs all operations according to the configured execution mode
    /// and completion strategy. It blocks until execution completes, all operations
    /// timeout, or the queue is cancelled.
    ///
    /// - Returns: A ``QueueResult`` containing all operation outcomes.
    ///
    /// ## Example
    ///
    /// ```swift
    /// let queue = OperationQueueBuilder<WindowHandle?>()
    ///     .add(name: "Op 1") { ... }
    ///     .add(name: "Op 2") { ... }
    ///     .build()
    ///
    /// let result = await queue.execute()
    /// print("Success: \(result.successCount)/\(result.results.count)")
    /// ```
    public func execute() async -> QueueResult<T> {
        let startTime = Date()

        // Validate dependencies (skip the graph walk entirely when nothing declares one)
        do {
            if hasDependencies {
                try validateDependencies()
            }
        } catch {
            let endTime = Date()
            // Return empty result with the error
            return QueueResult(
                results: [],
                totalDurationMs: Int(endTime.timeIntervalSince(startTime) * 1000),
                startedAt: startTime,
                completedAt: endTime,
                wasCancelled: false
            )
        }

        // Execute with optional queue-level timeout
        if let timeout = queueTimeout {
            return await withQueueTimeout(timeout, startTime: startTime)
        } else {
            return await executeWithStrategy(startTime: startTime)
        }
    }

    /// Cancels all operations immediately.
    ///
    /// Running operations are cancelled via `Task.cancel()`. Operations that
    /// haven't started yet are skipped. The cancellation callback is invoked
    /// if one was provided.
    ///
    /// ## Example
    ///
    /// ```swift
    /// let queue = builder.build()
    ///
    /// // Start execution in background
    /// async let result = queue.execute()
    ///
    /// // Cancel after 1 second
    /// try await Task.sleep(for: .seconds(1))
    /// await queue.cancel()
    ///
    /// let finalResult = await result
    /// print("Was cancelled: \(finalResult.wasCancelled)")
    /// ```
    public func cancel() {
        guard !isCancelled else { return }
        isCancelled = true
        onCancellation?()

    }

    /// Whether the queue has been cancelled.
    public var cancelled: Bool {
        isCancelled
    }

    // MARK: - Private Execution

    private func withQueueTimeout(_ timeout: Duration, startTime: Date) async -> QueueResult<T> {
        // Execute with timeout
        let result = await withTaskGroup(of: QueueResult<T>?.self) { group in
            // Add the main execution task
            group.addTask {
                await self.executeWithStrategy(startTime: startTime)
            }

            // Add the timeout task
            group.addTask {
                // Bail out without cancelling the queue when the timeout task
                // itself is cancelled (i.e. the operation finished first).
                guard await Task.sleepUnlessCancelled(for: timeout) else { return nil }
                await self.cancel()
                return nil
            }

            // Wait for the first non-nil result
            for await result in group {
                if let result = result {
                    group.cancelAll()
                    return result
                }
            }

            // Shouldn't reach here, but return empty result
            let endTime = Date()
            return QueueResult(
                results: [],
                totalDurationMs: Int(endTime.timeIntervalSince(startTime) * 1000),
                startedAt: startTime,
                completedAt: endTime,
                wasCancelled: true
            )
        }

        return result
    }

    private func executeWithStrategy(startTime: Date) async -> QueueResult<T> {
        switch completionStrategy {
        case .all:
            return await executeAll(startTime: startTime)
        case .race:
            return await executeRace(startTime: startTime)
        case .allSettled:
            return await executeAllSettled(startTime: startTime)
        case .any:
            return await executeAny(startTime: startTime)
        }
    }

    // MARK: - Completion Strategy Implementations

    private func executeAll(startTime: Date) async -> QueueResult<T> {
        let orderedOps = resolveDependencyOrder()
        var results: [SettledResult<T>] = []

        switch executionMode {
        case .sequential:
            for (index, op) in orderedOps.enumerated() {
                guard !isCancelled else { break }

                // Wait for dependency if needed
                if let depId = op.dependsOn {
                    if let depResult = completedResults[depId], !depResult.succeeded {
                        let result = makeFailedResult(op, index: index, error: .dependencyFailed(operationId: depId))
                        results.append(result)
                        if errorStrategy == .failFast {
                            break
                        }
                        continue
                    }
                }

                let result = await executeOperation(op, index: index)
                results.append(result)
                completedResults[op.id] = result

                if errorStrategy == .failFast && !result.succeeded {
                    break
                }
            }

        case .parallel:
            results = await executeParallel(orderedOps, stopOnFirstError: errorStrategy == .failFast)

        case .batched(let size):
            results = await executeBatched(orderedOps, batchSize: size, stopOnFirstError: errorStrategy == .failFast)

        case .concurrent(let maxConcurrency):
            results = await executeConcurrent(orderedOps, maxConcurrency: maxConcurrency, stopOnFirstError: errorStrategy == .failFast)
        }

        let endTime = Date()
        return QueueResult(
            results: results,
            totalDurationMs: Int(endTime.timeIntervalSince(startTime) * 1000),
            startedAt: startTime,
            completedAt: endTime,
            wasCancelled: isCancelled
        )
    }

    private func executeRace(startTime: Date) async -> QueueResult<T> {
        let orderedOps = resolveDependencyOrder()

        return await withTaskGroup(of: SettledResult<T>.self) { group in
            for (index, op) in orderedOps.enumerated() {
                group.addTask {
                    await self.executeOperation(op, index: index)
                }
            }

            var results: [SettledResult<T>] = []

            // Wait for first success or collect all
            for await result in group {
                results.append(result)
                completedResults[result.operationId] = result

                if result.succeeded {
                    // First success - cancel remaining and return
                    group.cancelAll()
                    let endTime = Date()
                    return QueueResult(
                        results: results,
                        totalDurationMs: Int(endTime.timeIntervalSince(startTime) * 1000),
                        startedAt: startTime,
                        completedAt: endTime,
                        wasCancelled: false
                    )
                }
            }

            // All failed
            let endTime = Date()
            return QueueResult(
                results: results,
                totalDurationMs: Int(endTime.timeIntervalSince(startTime) * 1000),
                startedAt: startTime,
                completedAt: endTime,
                wasCancelled: isCancelled
            )
        }
    }

    private func executeAllSettled(startTime: Date) async -> QueueResult<T> {
        let orderedOps = resolveDependencyOrder()
        var results: [SettledResult<T>] = []

        switch executionMode {
        case .sequential:
            for (index, op) in orderedOps.enumerated() {
                guard !isCancelled else { break }

                if let depId = op.dependsOn {
                    if let depResult = completedResults[depId], !depResult.succeeded {
                        let result = makeFailedResult(op, index: index, error: .dependencyFailed(operationId: depId))
                        results.append(result)
                        completedResults[op.id] = result
                        continue
                    }
                }

                let result = await executeOperation(op, index: index)
                results.append(result)
                completedResults[op.id] = result
            }

        case .parallel:
            results = await executeParallel(orderedOps, stopOnFirstError: false)

        case .batched(let size):
            results = await executeBatched(orderedOps, batchSize: size, stopOnFirstError: false)

        case .concurrent(let maxConcurrency):
            results = await executeConcurrent(orderedOps, maxConcurrency: maxConcurrency, stopOnFirstError: false)
        }

        let endTime = Date()
        return QueueResult(
            results: results,
            totalDurationMs: Int(endTime.timeIntervalSince(startTime) * 1000),
            startedAt: startTime,
            completedAt: endTime,
            wasCancelled: isCancelled
        )
    }

    private func executeAny(startTime: Date) async -> QueueResult<T> {
        let orderedOps = resolveDependencyOrder()

        return await withTaskGroup(of: SettledResult<T>.self) { group in
            for (index, op) in orderedOps.enumerated() {
                group.addTask {
                    await self.executeOperation(op, index: index)
                }
            }

            var results: [SettledResult<T>] = []

            for await result in group {
                results.append(result)
                completedResults[result.operationId] = result

                if result.succeeded {
                    // First success - continue running but we have a success
                    // For `any`, we don't cancel - just note we have success
                    group.cancelAll()
                    let endTime = Date()
                    return QueueResult(
                        results: results,
                        totalDurationMs: Int(endTime.timeIntervalSince(startTime) * 1000),
                        startedAt: startTime,
                        completedAt: endTime,
                        wasCancelled: false
                    )
                }
            }

            // All failed
            let endTime = Date()
            return QueueResult(
                results: results,
                totalDurationMs: Int(endTime.timeIntervalSince(startTime) * 1000),
                startedAt: startTime,
                completedAt: endTime,
                wasCancelled: isCancelled
            )
        }
    }

    // MARK: - Execution Mode Implementations

    private func executeParallel(_ ops: [QueueOperation<T>], stopOnFirstError: Bool) async -> [SettledResult<T>] {
        await withTaskGroup(of: SettledResult<T>.self) { group in
            for (index, op) in ops.enumerated() {
                group.addTask {
                    await self.executeOperation(op, index: index)
                }
            }

            var results: [SettledResult<T>] = []
            for await result in group {
                results.append(result)
                completedResults[result.operationId] = result

                if stopOnFirstError && !result.succeeded {
                    group.cancelAll()
                    break
                }
            }
            return results
        }
    }

    private func executeBatched(_ ops: [QueueOperation<T>], batchSize: Int, stopOnFirstError: Bool) async -> [SettledResult<T>] {
        var results: [SettledResult<T>] = []
        let batches = ops.chunked(into: batchSize)

        for (batchIndex, batch) in batches.enumerated() {
            guard !isCancelled else { break }

            let batchResults = await withTaskGroup(of: SettledResult<T>.self) { group in
                for (opIndex, op) in batch.enumerated() {
                    let globalIndex = batchIndex * batchSize + opIndex
                    group.addTask {
                        await self.executeOperation(op, index: globalIndex)
                    }
                }

                var batchResults: [SettledResult<T>] = []
                for await result in group {
                    batchResults.append(result)
                    await self.storeResult(result)
                }
                return batchResults
            }

            results.append(contentsOf: batchResults)

            if stopOnFirstError && batchResults.contains(where: { !$0.succeeded }) {
                break
            }
        }

        return results
    }

    private func executeConcurrent(_ ops: [QueueOperation<T>], maxConcurrency: Int, stopOnFirstError: Bool) async -> [SettledResult<T>] {
        let semaphore = AsyncSemaphore(permits: maxConcurrency)

        return await withTaskGroup(of: SettledResult<T>.self) { group in
            for (index, op) in ops.enumerated() {
                group.addTask {
                    await semaphore.wait()
                    defer { Task { await semaphore.signal() } }
                    return await self.executeOperation(op, index: index)
                }
            }

            var results: [SettledResult<T>] = []
            for await result in group {
                results.append(result)
                completedResults[result.operationId] = result

                if stopOnFirstError && !result.succeeded {
                    group.cancelAll()
                    break
                }
            }
            return results
        }
    }

    // MARK: - Single Operation Execution

    private func executeOperation(_ op: QueueOperation<T>, index: Int) async -> SettledResult<T> {
        let startTime = Date()

        // Emit started event
        await emitProgress(op: op, index: index, phase: .started)

        // Check cancellation
        guard !isCancelled else {
            let result = makeResult(op, index: index, outcome: .cancelled, startTime: startTime)
            await emitProgress(op: op, index: index, phase: .completed)
            return result
        }

        // Check dependency
        if let depId = op.dependsOn {
            if let depResult = completedResults[depId], !depResult.succeeded {
                let result = makeFailedResult(op, index: index, error: .dependencyFailed(operationId: depId))
                await emitProgress(op: op, index: index, phase: .completed)
                return result
            }
        }

        // Execute with optional timeout
        let outcome: OperationOutcome<T>

        if let timeout = op.timeout {
            outcome = await executeWithTimeout(op, timeout: timeout)
        } else {
            outcome = await executeDirectly(op)
        }

        let result = makeResult(op, index: index, outcome: outcome, startTime: startTime)

        // Emit completed event
        incrementCompleted()
        await emitProgress(op: op, index: index, phase: .completed)

        return result
    }

    private func executeWithTimeout(_ op: QueueOperation<T>, timeout: Duration) async -> OperationOutcome<T> {
        await withTaskGroup(of: OperationOutcome<T>?.self) { group in
            // Execution task
            group.addTask {
                await self.executeDirectly(op)
            }

            // Timeout task
            group.addTask {
                await Task.sleepUnlessCancelled(for: timeout)
                return nil  // Indicates timeout
            }

            // Wait for first result
            for await result in group {
                group.cancelAll()
                return result ?? .timedOut
            }

            return .timedOut
        }
    }

    private func executeDirectly(_ op: QueueOperation<T>) async -> OperationOutcome<T> {
        do {
            let value = try await op.execute()
            return .success(value)
        } catch is CancellationError {
            return .cancelled
        } catch let error as OperationError {
            return .failure(error)
        } catch {
            return .failure(.underlying(error))
        }
    }

    // MARK: - Dependency Management

    /// True when at least one operation declares a `dependsOn`. When false, dependency
    /// validation and topological ordering are both no-ops, so `execute()` and
    /// `resolveDependencyOrder()` short-circuit them (queue-07).
    private var hasDependencies: Bool {
        operations.contains { $0.dependsOn != nil }
    }

    private func validateDependencies() throws {
        var visiting: Set<String> = []
        var visited: Set<String> = []

        func visit(_ op: QueueOperation<T>, path: [String]) throws {
            if visiting.contains(op.id) {
                throw OperationError.circularDependency(path + [op.id])
            }
            if visited.contains(op.id) {
                return
            }

            visiting.insert(op.id)

            if let depId = op.dependsOn {
                if let dep = operations.first(where: { $0.id == depId }) {
                    try visit(dep, path: path + [op.id])
                }
            }

            visiting.remove(op.id)
            visited.insert(op.id)
        }

        for op in operations {
            try visit(op, path: [])
        }
    }

    private func resolveDependencyOrder() -> [QueueOperation<T>] {
        // Fast path: nothing depends on anything → preserve insertion order, skip the sort.
        guard hasDependencies else { return operations }

        var resolved: [QueueOperation<T>] = []
        var seen: Set<String> = []

        func visit(_ op: QueueOperation<T>) {
            if seen.contains(op.id) { return }

            if let depId = op.dependsOn,
               let dep = operations.first(where: { $0.id == depId }) {
                visit(dep)
            }

            seen.insert(op.id)
            resolved.append(op)
        }

        for op in operations {
            visit(op)
        }

        return resolved
    }

    // MARK: - Helpers

    private func makeResult(
        _ op: QueueOperation<T>,
        index: Int,
        outcome: OperationOutcome<T>,
        startTime: Date
    ) -> SettledResult<T> {
        let endTime = Date()
        return SettledResult(
            operationId: op.id,
            operationName: op.name,
            index: index,
            outcome: outcome,
            durationMs: Int(endTime.timeIntervalSince(startTime) * 1000),
            startedAt: startTime,
            completedAt: endTime
        )
    }

    private func makeFailedResult(
        _ op: QueueOperation<T>,
        index: Int,
        error: OperationError
    ) -> SettledResult<T> {
        let now = Date()
        return SettledResult(
            operationId: op.id,
            operationName: op.name,
            index: index,
            outcome: .failure(error),
            durationMs: 0,
            startedAt: now,
            completedAt: now
        )
    }

    private func emitProgress(op: QueueOperation<T>, index: Int, phase: ProgressPhase) async {
        guard let handler = progressHandler else { return }

        let event = ProgressEvent(
            operationId: op.id,
            operationName: op.name,
            phase: phase,
            completed: completedCount,
            total: operations.count,
            index: index
        )

        handler(event)
    }

    private func incrementCompleted() {
        completedCount += 1
    }

    private func storeResult(_ result: SettledResult<T>) async {
        completedResults[result.operationId] = result
    }
}

// MARK: - Array Chunking Helper

private extension Array {
    func chunked(into size: Int) -> [[Element]] {
        guard size > 0 else { return [self] }
        return stride(from: 0, to: count, by: size).map {
            Array(self[$0..<Swift.min($0 + size, count)])
        }
    }
}
