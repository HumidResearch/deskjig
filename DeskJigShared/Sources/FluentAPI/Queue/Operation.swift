//  Operation.swift
//  DeskJigShared

import Foundation

// MARK: - Queue Operation

/// A single operation in a queue with support for dependencies, timeouts, and priorities.
///
/// `QueueOperation` is the fundamental unit of work in the queue system. Each operation
/// encapsulates an async closure that performs work and returns a result of type `T`.
///
/// ## Overview
///
/// Operations can be:
/// - **Independent**: Run immediately when the queue starts
/// - **Dependent**: Wait for another operation to complete first
/// - **Timed**: Have per-operation timeouts separate from queue timeouts
/// - **Prioritized**: Run at specific task priorities
///
/// ## Creating Operations
///
/// ```swift
/// // Simple operation
/// let findOp = QueueOperation(name: "Find Safari") {
///     Window.find(bundleID: "com.apple.Safari")
/// }
///
/// // Operation with timeout
/// let moveOp = QueueOperation(
///     name: "Position window",
///     timeout: .seconds(5)
/// ) {
///     window?.moveToLeftHalf()
/// }
///
/// // Operation with dependency
/// let activateOp = QueueOperation(
///     id: "activate",
///     name: "Activate",
///     dependsOn: "find"
/// ) { previousResult in
///     previousResult?.activate()
/// }
/// ```
///
/// ## See Also
/// - ``OperationQueueBuilder`` for building queues of operations
/// - ``Queue`` for static factory methods
public struct QueueOperation<T: Sendable>: Sendable {
    /// The unique identifier for this operation.
    ///
    /// Used for dependency references and progress tracking. If not provided,
    /// a UUID is generated automatically.
    public let id: String

    /// The human-readable name of this operation.
    ///
    /// Used in progress callbacks, logging, and error messages.
    public let name: String

    /// The async closure that performs the operation.
    ///
    /// This closure is called when the operation executes. It should perform
    /// the actual work and return a result of type `T`.
    public let execute: @Sendable () async throws -> T

    /// Optional timeout for this specific operation.
    ///
    /// If set, the operation is cancelled if it exceeds this duration.
    /// This is independent of the queue-level timeout.
    public let timeout: Duration?

    /// The task priority for this operation.
    ///
    /// Determines how the operation is scheduled relative to other work.
    public let priority: TaskPriority

    /// The ID of an operation this one depends on.
    ///
    /// If set, this operation waits for the dependency to complete successfully
    /// before executing. If the dependency fails, this operation fails with
    /// ``OperationError/dependencyFailed(operationId:)``.
    public let dependsOn: String?

    /// Creates a new window operation.
    ///
    /// - Parameters:
    ///   - id: Unique identifier. Defaults to a UUID string.
    ///   - name: Human-readable name for the operation.
    ///   - timeout: Optional per-operation timeout.
    ///   - priority: Task priority. Defaults to `.medium`.
    ///   - dependsOn: ID of an operation this depends on.
    ///   - execute: The async closure to execute.
    ///
    /// ## Example
    ///
    /// ```swift
    /// let operation = QueueOperation(
    ///     id: "maximize-safari",
    ///     name: "Maximize Safari",
    ///     timeout: .seconds(3),
    ///     priority: .high
    /// ) {
    ///     Window.find(bundleID: "com.apple.Safari")?.maximize()
    /// }
    /// ```
    public init(
        id: String = UUID().uuidString,
        name: String,
        timeout: Duration? = nil,
        priority: TaskPriority = .medium,
        dependsOn: String? = nil,
        execute: @escaping @Sendable () async throws -> T
    ) {
        self.id = id
        self.name = name
        self.timeout = timeout
        self.priority = priority
        self.dependsOn = dependsOn
        self.execute = execute
    }

    /// Creates a new operation that depends on another operation.
    ///
    /// This is a convenience method for creating dependency chains.
    ///
    /// - Parameter operationId: The ID of the operation to depend on.
    /// - Returns: A new operation with the dependency set.
    ///
    /// ## Example
    ///
    /// ```swift
    /// let findOp = QueueOperation(id: "find", name: "Find") { ... }
    /// let moveOp = QueueOperation(name: "Move") { ... }
    ///     .dependingOn("find")
    /// ```
    public func dependingOn(_ operationId: String) -> QueueOperation<T> {
        QueueOperation(
            id: id,
            name: name,
            timeout: timeout,
            priority: priority,
            dependsOn: operationId,
            execute: execute
        )
    }

    /// Creates a new operation with a different timeout.
    ///
    /// - Parameter duration: The new timeout duration.
    /// - Returns: A new operation with the updated timeout.
    public func withTimeout(_ duration: Duration) -> QueueOperation<T> {
        QueueOperation(
            id: id,
            name: name,
            timeout: duration,
            priority: priority,
            dependsOn: dependsOn,
            execute: execute
        )
    }

    /// Creates a new operation with a different priority.
    ///
    /// - Parameter newPriority: The new task priority.
    /// - Returns: A new operation with the updated priority.
    public func withPriority(_ newPriority: TaskPriority) -> QueueOperation<T> {
        QueueOperation(
            id: id,
            name: name,
            timeout: timeout,
            priority: newPriority,
            dependsOn: dependsOn,
            execute: execute
        )
    }
}


// MARK: - Identifiable

extension QueueOperation: Identifiable {
    // id property already exists
}

// MARK: - CustomStringConvertible

extension QueueOperation: CustomStringConvertible {
    public var description: String {
        var desc = "QueueOperation(\"\(name)\""
        if let dep = dependsOn {
            desc += ", dependsOn: \"\(dep)\""
        }
        if let t = timeout {
            desc += ", timeout: \(t)"
        }
        desc += ")"
        return desc
    }
}
