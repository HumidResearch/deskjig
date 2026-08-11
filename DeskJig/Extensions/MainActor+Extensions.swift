//
//  MainActor+Extensions.swift
//  DeskJig
//

import Foundation

extension MainActor {
    /// A wrapper around `MainActor.run()` that encapsulates the execution in a `Task`.
    ///
    /// This method provides a convenient way to schedule work on the main actor, optionally with a delay.
    ///
    /// - Parameters:
    ///   - priority: The priority for the `Task`. If `nil`, the system decides the priority.
    ///   - delay: An optional delay before executing the task. If `nil`, the task starts immediately.
    ///   - delayTolerance: Optionally, the amount of tolerance allowed in the delay.
    ///   - checksCancellation: Whether the `Task` should check for cancellation before
    ///   performing the work in`body`. If the `Task` gets cancelled, `body` will not be performed.
    ///   - resultType: The expected result type of `body`. This parameter is used for type inference
    ///   and doesn't need to be explicitly provided in most cases.
    ///   - body: The closure to be executed on the `MainActor`.
    ///
    /// - Returns: A `Task` that represents the asynchronous operation. The result can be discarded
    /// if not needed.
    ///
    /// - Example:
    ///   ```swift
    ///   MainActor.async {
    ///       // Perform some UI updates
    ///   }
    ///
    ///   // With delay
    ///   let task = MainActor.async(after: .seconds(1)) {
    ///       // Perform some UI updates after 1 second
    ///   }
    ///   ```
    @discardableResult static func async<T: Sendable>(
        priority: TaskPriority? = nil,
        after delay: Duration? = nil,
        delayTolerance: Duration? = nil,
        checksCancellation: Bool = true,
        resultType: T.Type = T.self,
        body: @escaping @Sendable @MainActor () throws -> T
    ) -> Task<T, Error> {
        Task(priority: priority) {
            if let delay {
                try await Task.sleep(for: delay, tolerance: delayTolerance)
            }
            if checksCancellation {
                try Task.checkCancellation()
            }
            return try await Self.run {
                try body()
            }
        }
    }
}
