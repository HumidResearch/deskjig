// LoggingConfigurationVerboseSinkTests.swift
// DeskJigTests

import Testing
import CocoaLumberjackSwift
@testable import DeskJig

struct LoggingConfigurationVerboseSinkTests {
    @Test("Verbose logging raises file and console destination levels")
    func verboseLoggingRaisesFileAndConsoleLevels() {
        let configuration = LoggingConfiguration.defaultConfiguration(
            environment: ["BENTO_LOG_VERBOSE": "restore.snapshot.*"]
        )

        #expect(configuration.destinationRules[.file]?.minimumLevel == .verbose)
        #expect(configuration.destinationRules[.console]?.minimumLevel == .verbose)
    }

    @Test("Missing verbose logging environment keeps default destination levels")
    func missingVerboseLoggingKeepsDefaultLevels() {
        let configuration = LoggingConfiguration.defaultConfiguration(environment: [:])

        #expect(configuration.destinationRules[.file]?.minimumLevel == .debug)
        #expect(configuration.destinationRules[.console]?.minimumLevel == .debug)
    }

    @Test("Empty verbose logging environment keeps default destination levels")
    func emptyVerboseLoggingKeepsDefaultLevels() {
        let configuration = LoggingConfiguration.defaultConfiguration(
            environment: ["BENTO_LOG_VERBOSE": ""]
        )

        #expect(configuration.destinationRules[.file]?.minimumLevel == .debug)
        #expect(configuration.destinationRules[.console]?.minimumLevel == .debug)
    }
}

