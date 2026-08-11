import Foundation

/// Carries logging context (subsystem, runId, parent fields) through operations.
public struct LogScope: Sendable {
    public let subsystem: LogSubsystem
    public let runId: String?
    public let fields: [String: any Sendable]

    public init(subsystem: LogSubsystem, runId: String? = nil, fields: [String: any Sendable] = [:]) {
        self.subsystem = subsystem
        self.runId = runId
        self.fields = fields
    }

    // MARK: - Log Methods

    public func trace(_ message: @autoclosure () -> String, _ extraFields: [String: any Sendable] = [:], file: String = #file, function: String = #function, line: UInt = #line) {
        DeskJigLog.trace(subsystem, message(), fields: mergedFields(extraFields), runId: runId, file: file, function: function, line: line)
    }

    public func debug(_ message: @autoclosure () -> String, _ extraFields: [String: any Sendable] = [:], file: String = #file, function: String = #function, line: UInt = #line) {
        DeskJigLog.debug(subsystem, message(), fields: mergedFields(extraFields), runId: runId, file: file, function: function, line: line)
    }

    public func info(_ message: @autoclosure () -> String, _ extraFields: [String: any Sendable] = [:], file: String = #file, function: String = #function, line: UInt = #line) {
        DeskJigLog.info(subsystem, message(), fields: mergedFields(extraFields), runId: runId, file: file, function: function, line: line)
    }

    public func warn(_ message: @autoclosure () -> String, _ extraFields: [String: any Sendable] = [:], file: String = #file, function: String = #function, line: UInt = #line) {
        DeskJigLog.warn(subsystem, message(), fields: mergedFields(extraFields), runId: runId, file: file, function: function, line: line)
    }

    public func error(_ message: @autoclosure () -> String, _ extraFields: [String: any Sendable] = [:], file: String = #file, function: String = #function, line: UInt = #line) {
        DeskJigLog.error(subsystem, message(), fields: mergedFields(extraFields), runId: runId, file: file, function: function, line: line)
    }

    // MARK: - Measure

    /// Executes a closure and logs its duration.
    @discardableResult
    public func measure<T: Sendable>(
        _ label: String,
        _ body: () async throws -> T
    ) async rethrows -> T {
        let start = ContinuousClock.now
        do {
            let result = try await body()
            let elapsed = start.duration(to: .now)
            let ms = elapsed.components.seconds * 1000 + elapsed.components.attoseconds / 1_000_000_000_000_000
            DeskJigLog.info(subsystem, "\(label) completed", fields: mergedFields(["durationMs": ms]), runId: runId)
            return result
        } catch {
            let elapsed = start.duration(to: .now)
            let ms = elapsed.components.seconds * 1000 + elapsed.components.attoseconds / 1_000_000_000_000_000
            DeskJigLog.error(subsystem, "\(label) failed", fields: mergedFields(["durationMs": ms, "error": error.localizedDescription]), runId: runId)
            throw error
        }
    }

    // MARK: - Child Scope

    /// Creates a child scope with a different subsystem but inheriting runId and parent fields.
    public func childScope(_ subsystem: LogSubsystem, extraFields: [String: any Sendable] = [:]) -> LogScope {
        LogScope(subsystem: subsystem, runId: runId, fields: mergedFields(extraFields))
    }

    // MARK: - Private

    private func mergedFields(_ extra: [String: any Sendable]) -> [String: any Sendable] {
        guard !extra.isEmpty else { return fields }
        var merged = fields
        for (key, value) in extra {
            merged[key] = value
        }
        return merged
    }
}
