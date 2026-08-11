//  CLIFileLogger.swift
//  DeskJigCLI

import Foundation
import CocoaLumberjackSwift
import DeskJigShared

/// Adds the frozen `[CLI]` prefix to every CLI log message.
final class CLILogFormatter: NSObject, DDLogFormatter {
    private let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return formatter
    }()

    func format(message logMessage: DDLogMessage) -> String? {
        let timestamp = dateFormatter.string(from: logMessage.timestamp)
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
        return "[CLI] [\(timestamp)] [\(level)] [\(fileName):\(logMessage.line)] \(logMessage.message)"
    }
}

/// Writes CLI logs under the legacy `~/Library/Logs/Bento` directory.
final class CLIFileLogger {
    static let shared = CLIFileLogger()

    private var fileLogger: DDFileLogger?

    var logURL: URL {
        if let currentLogPath = fileLogger?.currentLogFileInfo?.filePath {
            return URL(fileURLWithPath: currentLogPath)
        }
        return BundleIdentity.logDirectoryURL.appendingPathComponent("deskjig-cli.log")
    }

    private init() {}

    func configure() {
        let fileManager = FileManager.default
        let logsDirectory = BundleIdentity.logDirectoryURL

        if !fileManager.fileExists(atPath: logsDirectory.path) {
            try? fileManager.createDirectory(at: logsDirectory, withIntermediateDirectories: true)
        }

        let logFileManager = DDLogFileManagerDefault(logsDirectory: logsDirectory.path)
        let logger = DDFileLogger(logFileManager: logFileManager)
        logger.rollingFrequency = 60 * 60 * 24
        logger.logFileManager.maximumNumberOfLogFiles = 7
        logger.logFormatter = CLILogFormatter()

        DDLog.add(logger, with: .all)
        fileLogger = logger
    }
}
