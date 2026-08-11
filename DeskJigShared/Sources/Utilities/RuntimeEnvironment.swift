//
//  RuntimeEnvironment.swift
//  DeskJigShared
//
//  Provides utilities for detecting the runtime environment
//

import Foundation

/// Utilities for detecting the runtime environment of the application
public enum RuntimeEnvironment {

    /// Indicates whether mock tests are currently running
    /// Set this to true at the start of mock tests to disable real services
    public static var isRunningMockTests: Bool = false

    /// Checks if the application is currently running in a test environment
    ///
    /// This method checks multiple indicators to reliably detect test execution:
    /// - XCTest configuration file path environment variable
    /// - XCTest bundle path environment variable
    /// - XCTest in process arguments
    /// - XCTest and XCTestCase classes being loaded
    /// - Explicit mock test flag
    ///
    /// - Returns: `true` if running in test mode, `false` otherwise
    public static func isRunningTests() -> Bool {
        return isRunningMockTests ||
               ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil ||
               ProcessInfo.processInfo.environment["XCTestBundlePath"] != nil ||
               ProcessInfo.processInfo.arguments.contains { $0.contains("XCTest") } ||
               NSClassFromString("XCTest") != nil ||
               NSClassFromString("XCTestCase") != nil
    }
}
