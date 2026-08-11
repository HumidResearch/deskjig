//
//  LoggingController.swift
//  DeskJig
//

import Foundation
import CocoaLumberjackSwift

/// Supported logging destinations that can be configured centrally.
enum LogDestination: String, CaseIterable {
    case console
    case file
}

/// Rule set describing filtering behaviour for a destination.
struct LogRuleSet {
    var isEnabled: Bool
    var minimumLevel: DDLogLevel
    var excludedFiles: Set<String>
    var includedFiles: Set<String>?
    var excludedFunctions: Set<String>
    var includedFunctions: Set<String>?
    var excludedKeywords: Set<String>
    var includedKeywords: Set<String>?
}

/// Complete logging configuration with global + destination specific rules.
struct LoggingConfiguration {
    var globalRules: LogRuleSet
    var destinationRules: [LogDestination: LogRuleSet]
}

/// Central controller that evaluates log destinations and filtering.
final class LoggingController {
    static let shared = LoggingController()

    private let queue = DispatchQueue(label: "com.deskjig.logging.controller", attributes: .concurrent)
    private var configuration: LoggingConfiguration

    private init() {
        configuration = LoggingConfiguration.defaultConfiguration()
    }

    /// Apply a new configuration or load defaults when nil.
    func configure(_ configuration: LoggingConfiguration? = nil) {
        queue.async(flags: .barrier) {
            if let configuration {
                self.configuration = configuration
            } else {
                self.configuration = LoggingConfiguration.defaultConfiguration()
            }
        }
    }

    /// Determine whether a log message should be routed to the destination.
    func shouldAllow(_ message: DDLogMessage, for destination: LogDestination) -> Bool {
        var currentConfig: LoggingConfiguration!
        queue.sync {
            currentConfig = configuration
        }

        guard destinationIsEnabled(destination, configuration: currentConfig) else { return false }
        guard currentConfig.globalRules.allows(message) else { return false }

        if let destinationRules = currentConfig.destinationRules[destination] {
            return destinationRules.allows(message)
        }

        return true
    }

    /// Whether the destination is globally enabled (used for direct event routing).
    func isDestinationEnabled(_ destination: LogDestination) -> Bool {
        var currentConfig: LoggingConfiguration!
        queue.sync {
            currentConfig = configuration
        }
        return destinationIsEnabled(destination, configuration: currentConfig)
    }

    /// Retrieve the configured log level for a destination.
    func level(for destination: LogDestination) -> DDLogLevel {
        var level: DDLogLevel = .info
        queue.sync {
            level = configuration.destinationRules[destination]?.minimumLevel ?? .info
        }
        return level
    }

    /// Update enabled/disabled state for a destination without changing other rules.
    func setDestinationEnabled(_ destination: LogDestination, isEnabled: Bool) {
        queue.sync(flags: .barrier) {
            var rules = self.configuration.destinationRules[destination] ?? LogRuleSet(
                isEnabled: true,
                minimumLevel: .info,
                excludedFiles: [],
                includedFiles: nil,
                excludedFunctions: [],
                includedFunctions: nil,
                excludedKeywords: [],
                includedKeywords: nil
            )
            rules.isEnabled = isEnabled
            self.configuration.destinationRules[destination] = rules
        }
    }

    /// Provide a formatter that automatically filters based on destination rules.
    func formatter(for destination: LogDestination, base: DDLogFormatter? = nil) -> DDLogFormatter {
        return DestinationFilteringFormatter(destination: destination, wrapped: base)
    }

    private func destinationIsEnabled(_ destination: LogDestination, configuration: LoggingConfiguration) -> Bool {
        configuration.destinationRules[destination]?.isEnabled ?? true
    }
}

// MARK: - Rule evaluation

private extension LogRuleSet {
    func allows(_ message: DDLogMessage) -> Bool {
        guard isEnabled else { return false }

        // Level filtering mirrors CocoaLumberjack behaviour
        if message.flag.rawValue & minimumLevel.rawValue == 0 {
            return false
        }

        let fileName = (message.file as NSString).lastPathComponent
        let fileStem = (fileName as NSString).deletingPathExtension

        if excludedFiles.contains(fileName) || excludedFiles.contains(fileStem) {
            return false
        }

        if let includedFiles, !includedFiles.isEmpty {
            let matches = includedFiles.contains(fileName) || includedFiles.contains(fileStem)
            if !matches { return false }
        }

        let functionName = message.function ?? ""
        if excludedFunctions.contains(functionName) {
            return false
        }
        if let includedFunctions, !includedFunctions.isEmpty, !includedFunctions.contains(functionName) {
            return false
        }

        if !excludedKeywords.isEmpty {
            let lowercasedMessage = message.message.lowercased()
            if excludedKeywords.contains(where: { lowercasedMessage.contains($0) }) {
                return false
            }
        }

        if let includedKeywords, !includedKeywords.isEmpty {
            let lowercasedMessage = message.message.lowercased()
            let matches = includedKeywords.contains(where: { lowercasedMessage.contains($0) })
            if !matches { return false }
        }

        return true
    }
}

// MARK: - Default configuration

extension LoggingConfiguration {
    static func defaultConfiguration(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> LoggingConfiguration {
        let verboseLoggingRequested = !(environment["BENTO_LOG_VERBOSE"] ?? "").isEmpty
        let fileConsoleMinimumLevel: DDLogLevel = verboseLoggingRequested ? .verbose : .debug
        let consoleNoisyFiles: Set<String> = [
            "WindowScreenshotService",
            "ScreenIndicatorManager",
            "WindowLayoutManager",
            "OverlayWindowManager",
            "ActionPanelContent"
        ]
        // Keep file logs useful for restoration debugging while still trimming
        // the noisiest UI sources.
        let fileNoisyFiles: Set<String> = [
            "WindowScreenshotService",
            "ScreenIndicatorManager",
            "ActionPanelContent"
        ]

        let globalRules = LogRuleSet(
            isEnabled: true,
            minimumLevel: .verbose,
            excludedFiles: [],
            includedFiles: nil,
            excludedFunctions: [],
            includedFunctions: nil,
            excludedKeywords: [],
            includedKeywords: nil
        )

        let destinationRules: [LogDestination: LogRuleSet] = [
            .console: LogRuleSet(
                isEnabled: true,
                minimumLevel: fileConsoleMinimumLevel,
                excludedFiles: consoleNoisyFiles,
                includedFiles: nil,
                excludedFunctions: [],
                includedFunctions: nil,
                excludedKeywords: [
                    "flushing",
                    "no data found for tutorial"
                ],
                includedKeywords: nil
            ),
            .file: LogRuleSet(
                isEnabled: true,
                minimumLevel: fileConsoleMinimumLevel,
                excludedFiles: fileNoisyFiles,
                includedFiles: nil,
                excludedFunctions: [],
                includedFunctions: nil,
                excludedKeywords: [],
                includedKeywords: nil
            )
        ]

        return LoggingConfiguration(
            globalRules: globalRules,
            destinationRules: destinationRules
        )
    }
}

// MARK: - Formatter wrapper

final class DestinationFilteringFormatter: NSObject, DDLogFormatter {
    private let destination: LogDestination
    private let wrapped: DDLogFormatter?

    init(destination: LogDestination, wrapped: DDLogFormatter?) {
        self.destination = destination
        self.wrapped = wrapped
        super.init()
    }

    func format(message logMessage: DDLogMessage) -> String? {
        guard LoggingController.shared.shouldAllow(logMessage, for: destination) else {
            return nil
        }
        return wrapped?.format(message: logMessage) ?? logMessage.message
    }
}
