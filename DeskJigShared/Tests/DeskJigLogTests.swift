//
//  DeskJigLogTests.swift
//  DeskJigSharedTests
//
//  Tests for the unified DeskJigLog logging facade.
//

import XCTest
import CocoaLumberjackSwift
import Darwin
@testable import DeskJigShared

final class DeskJigLogTests: XCTestCase {

    // MARK: - LogSubsystem Tests

    func testSubsystemCategoryExtraction() {
        // Test that category extracts the first component
        XCTAssertEqual(LogSubsystem.restorationExecutor.category, "restore")
        XCTAssertEqual(LogSubsystem.restorationChrome.category, "restore")
        XCTAssertEqual(LogSubsystem.windowPositioning.category, "window")
        XCTAssertEqual(LogSubsystem.tmux.category, "tmux")
        XCTAssertEqual(LogSubsystem.workspace.category, "workspace")
    }

    func testSubsystemRawValues() {
        XCTAssertEqual(LogSubsystem.restorationOrchestrator.rawValue, "restore.orchestrator")
        XCTAssertEqual(LogSubsystem.restorationExecutor.rawValue, "restore.executor")
        XCTAssertEqual(LogSubsystem.cli.rawValue, "cli")
        XCTAssertEqual(LogSubsystem.app.rawValue, "app")
    }

    // MARK: - LogLevel Tests

    func testLogLevelComparison() {
        XCTAssertTrue(LogLevel.trace < LogLevel.debug)
        XCTAssertTrue(LogLevel.debug < LogLevel.info)
        XCTAssertTrue(LogLevel.info < LogLevel.warn)
        XCTAssertTrue(LogLevel.warn < LogLevel.error)
        XCTAssertFalse(LogLevel.error < LogLevel.trace)
    }

    // MARK: - SubsystemRegistry Tests

    func testRegistryDefaultLevels() {
        let registry = SubsystemRegistry.shared
        // In test builds (DEBUG), restoration should be .debug
        #if DEBUG
        XCTAssertTrue(registry.shouldLog(.debug, for: .restorationExecutor))
        XCTAssertTrue(registry.shouldLog(.info, for: .restorationExecutor))
        XCTAssertFalse(registry.shouldLog(.trace, for: .restorationExecutor))
        #endif
    }

    func testRegistrySetLevel() {
        let registry = SubsystemRegistry.shared
        // Override a subsystem level
        registry.setLevel(.trace, for: .workspace)
        XCTAssertTrue(registry.shouldLog(.trace, for: .workspace))
        // Reset
        registry.setLevel(.info, for: .workspace)
    }

    // MARK: - LogScope Tests

    func testLogScopeFieldMerging() {
        let scope = DeskJigLog.scope(.restorationExecutor, runId: "test_123", fields: ["workspace": "MyWorkspace"])
        // Verify scope properties
        XCTAssertEqual(scope.subsystem, .restorationExecutor)
        XCTAssertEqual(scope.runId, "test_123")
        XCTAssertNotNil(scope.fields["workspace"])
    }

    func testLogScopeChildScope() {
        let parent = DeskJigLog.scope(.restorationOrchestrator, runId: "test_123", fields: ["workspace": "MyWorkspace"])
        let child = parent.childScope(.restorationChrome, extraFields: ["profile": "Default"])

        XCTAssertEqual(child.subsystem, .restorationChrome)
        XCTAssertEqual(child.runId, "test_123")
        // Child should have both parent and extra fields
        XCTAssertNotNil(child.fields["workspace"])
        XCTAssertNotNil(child.fields["profile"])
    }

    func testLogScopeMeasure() async {
        let scope = DeskJigLog.scope(.restorationExecutor, runId: "test_measure")

        let result = await scope.measure("testOperation") {
            // Simulate work
            try? await Task.sleep(for: .milliseconds(50))
            return 42
        }

        XCTAssertEqual(result, 42)
    }

    // MARK: - TraceFileWriter Tests

    func testTraceFileWriterEnabledState() {
        let writer = TraceFileWriter.shared
        #if DEBUG
        XCTAssertTrue(writer.isEnabled, "Should be enabled in DEBUG builds")
        #endif
    }

    func testExtractBaseRunId() {
        XCTAssertEqual(TraceFileWriter.extractBaseRunId("restore_143022_abc123"), "restore_143022_abc123")
        XCTAssertEqual(TraceFileWriter.extractBaseRunId("restore_143022_abc123_retry_1"), "restore_143022_abc123")
        XCTAssertEqual(TraceFileWriter.extractBaseRunId("restore_143022_abc123_retry_10"), "restore_143022_abc123")
    }

    // MARK: - DeskJigLog Integration Tests

    func testDeskJigLogDoesNotCrash() {
        // Verify that calling DeskJigLog methods doesn't crash (smoke test)
        DeskJigLog.info(.app, "Test info message")
        DeskJigLog.debug(.cli, "Test debug message", fields: ["key": "value"])
        DeskJigLog.warn(.workspace, "Test warning")
        DeskJigLog.error(.chrome, "Test error", fields: ["code": 404])
        DeskJigLog.trace(.restorationTrace, "Test trace", runId: "test_run_123")
    }

    func testDeskJigLogWithComplexFields() {
        // Verify complex field types don't crash
        let rect = CGRect(x: 100, y: 200, width: 800, height: 600)
        let point = CGPoint(x: 50, y: 100)
        let size = CGSize(width: 1920, height: 1080)

        DeskJigLog.info(.restorationPositioning, "Position test", fields: [
            "frame": rect,
            "origin": point,
            "screenSize": size,
            "count": 42,
            "ratio": 0.75,
            "success": true,
            "app": "Finder"
        ])
    }
}
