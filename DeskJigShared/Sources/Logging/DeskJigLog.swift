import Foundation
import CocoaLumberjackSwift

/// Unified logging facade for DeskJig. Sits on top of CocoaLumberjack.
public enum DeskJigLog {

    // MARK: - Log Methods

    public static func trace(
        _ subsystem: LogSubsystem,
        _ message: @autoclosure () -> String,
        fields: [String: any Sendable] = [:],
        runId: String? = nil,
        file: String = #file,
        function: String = #function,
        line: UInt = #line
    ) {
        guard SubsystemRegistry.shared.shouldLog(.trace, for: subsystem) else { return }
        emit(.trace, subsystem: subsystem, message: message(), fields: fields, runId: runId, file: file, function: function, line: line)
    }

    public static func debug(
        _ subsystem: LogSubsystem,
        _ message: @autoclosure () -> String,
        fields: [String: any Sendable] = [:],
        runId: String? = nil,
        file: String = #file,
        function: String = #function,
        line: UInt = #line
    ) {
        guard SubsystemRegistry.shared.shouldLog(.debug, for: subsystem) else { return }
        emit(.debug, subsystem: subsystem, message: message(), fields: fields, runId: runId, file: file, function: function, line: line)
    }

    public static func info(
        _ subsystem: LogSubsystem,
        _ message: @autoclosure () -> String,
        fields: [String: any Sendable] = [:],
        runId: String? = nil,
        file: String = #file,
        function: String = #function,
        line: UInt = #line
    ) {
        guard SubsystemRegistry.shared.shouldLog(.info, for: subsystem) else { return }
        emit(.info, subsystem: subsystem, message: message(), fields: fields, runId: runId, file: file, function: function, line: line)
    }

    public static func warn(
        _ subsystem: LogSubsystem,
        _ message: @autoclosure () -> String,
        fields: [String: any Sendable] = [:],
        runId: String? = nil,
        file: String = #file,
        function: String = #function,
        line: UInt = #line
    ) {
        guard SubsystemRegistry.shared.shouldLog(.warn, for: subsystem) else { return }
        emit(.warn, subsystem: subsystem, message: message(), fields: fields, runId: runId, file: file, function: function, line: line)
    }

    public static func error(
        _ subsystem: LogSubsystem,
        _ message: @autoclosure () -> String,
        fields: [String: any Sendable] = [:],
        runId: String? = nil,
        file: String = #file,
        function: String = #function,
        line: UInt = #line
    ) {
        guard SubsystemRegistry.shared.shouldLog(.error, for: subsystem) else { return }
        emit(.error, subsystem: subsystem, message: message(), fields: fields, runId: runId, file: file, function: function, line: line)
    }

    // MARK: - Scope Factory

    public static func scope(
        _ subsystem: LogSubsystem,
        runId: String? = nil,
        fields: [String: any Sendable] = [:]
    ) -> LogScope {
        LogScope(subsystem: subsystem, runId: runId, fields: fields)
    }

    // MARK: - Internal Emit

    static func emit(
        _ level: LogLevel,
        subsystem: LogSubsystem,
        message: String,
        fields: [String: any Sendable],
        runId: String?,
        file: String,
        function: String,
        line: UInt
    ) {
        // Build context
        let threadName = Thread.current.name ?? ""
        let queueLabel = String(cString: __dispatch_queue_get_label(nil))
        let isMain = Thread.isMainThread

        // Build formatted message
        let formatted = formatMessage(
            subsystem: subsystem,
            message: message,
            fields: fields,
            runId: runId,
            threadName: threadName,
            queueLabel: queueLabel,
            isMainThread: isMain
        )

        // Route to CocoaLumberjack. Redaction happens here — at the sink — and behaves
        // identically in Debug and Release; see LogRedaction.
        let ddMessage = DDLogMessage(
            message: LogRedaction.redactIfEnabled(formatted),
            level: ddLogLevel(for: level),
            flag: ddLogFlag(for: level),
            context: 0,
            file: file,
            function: function,
            line: line,
            tag: nil,
            options: [.copyFile, .copyFunction],
            timestamp: Date()
        )
        DDLog.sharedInstance.log(asynchronous: level != .error, message: ddMessage)

        // Write trace if enabled for this subsystem
        TraceFileWriter.shared.writeIfEnabled(
            subsystem: subsystem,
            level: level,
            message: LogRedaction.redactIfEnabled(message),
            fields: LogRedaction.redactFields(fields),
            runId: runId,
            threadName: threadName,
            queueLabel: queueLabel,
            isMainThread: isMain,
            file: file,
            function: function,
            line: line
        )
    }

    // MARK: - Formatting

    private static func formatMessage(
        subsystem: LogSubsystem,
        message: String,
        fields: [String: any Sendable],
        runId: String?,
        threadName: String,
        queueLabel: String,
        isMainThread: Bool
    ) -> String {
        var parts: [String] = []

        // Subsystem prefix
        if let runId {
            parts.append("[\(subsystem.rawValue)][\(runId)]")
        } else {
            parts.append("[\(subsystem.rawValue)]")
        }

        // Message
        parts.append(message)

        // Fields
        if !fields.isEmpty {
            let fieldStr = fields
                .sorted(by: { $0.key < $1.key })
                .map { "\($0.key)=\(stringifyValue($0.value))" }
                .joined(separator: " ")
            parts.append("| \(fieldStr)")
        }

        // Thread context (only if not main thread — main is the common case)
        if !isMainThread {
            let threadInfo = threadName.isEmpty ? queueLabel : threadName
            parts.append("thread=\(threadInfo)")
        }

        return parts.joined(separator: " ")
    }

    private static func stringifyValue(_ value: any Sendable) -> String {
        switch value {
        case let rect as CGRect:
            return "(\(Int(rect.origin.x)),\(Int(rect.origin.y)) \(Int(rect.width))x\(Int(rect.height)))"
        case let point as CGPoint:
            return "(\(Int(point.x)),\(Int(point.y)))"
        case let size as CGSize:
            return "\(Int(size.width))x\(Int(size.height))"
        case let bool as Bool:
            return bool ? "true" : "false"
        case let str as String:
            return str.contains(" ") ? "\"\(str)\"" : str
        default:
            return "\(value)"
        }
    }

    private static func ddLogLevel(for level: LogLevel) -> DDLogLevel {
        switch level {
        case .trace: return .verbose
        case .debug: return .debug
        case .info: return .info
        case .warn: return .warning
        case .error: return .error
        }
    }

    private static func ddLogFlag(for level: LogLevel) -> DDLogFlag {
        switch level {
        case .trace: return .verbose
        case .debug: return .debug
        case .info: return .info
        case .warn: return .warning
        case .error: return .error
        }
    }
}
