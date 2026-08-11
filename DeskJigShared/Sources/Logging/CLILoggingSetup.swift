import Foundation
import CocoaLumberjackSwift

/// Shared stderr logger for CLI tools.
public final class StderrLogger: DDAbstractLogger {
    private let formatter = ISO8601DateFormatter()

    override public func log(message logMessage: DDLogMessage) {
        let timestamp = formatter.string(from: logMessage.timestamp)
        let level: String
        switch logMessage.flag {
        case .error: level = "ERROR"
        case .warning: level = "WARN"
        case .info: level = "INFO"
        case .debug: level = "DEBUG"
        case .verbose: level = "VERBOSE"
        default: level = "LOG"
        }
        let fileName = (logMessage.file as NSString).lastPathComponent
        fputs("[\(timestamp)] [\(level)] [\(fileName):\(logMessage.line)] \(logMessage.message)\n", stderr)
    }
}

extension DeskJigLog {
    /// Configure logging for the CLI.
    /// Call the CLI's file-logger configuration separately before this (it lives in the
    /// CLI target). This sets context flags and optionally adds stderr output.
    public static func configureCLI(verbose: Bool) {
        if verbose {
            let stderrLogger = StderrLogger()
            DDLog.add(stderrLogger, with: .debug)
            SubsystemRegistry.shared.setLevel(.debug, for: .cli)
        }
    }
}
