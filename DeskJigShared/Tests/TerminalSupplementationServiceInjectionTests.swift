//  TerminalSupplementationServiceInjectionTests.swift
//  DeskJigSharedTests

import Foundation
import ApplicationServices
import CoreGraphics
import Testing
@testable import DeskJigShared

@Suite("TerminalSupplementationService AX injection (#481)")
struct TerminalSupplementationServiceInjectionTests {

    private static let terminalPid: pid_t = 555

    private func makeSnapshot(windows: [SnapshotWindow]) -> SystemSnapshot {
        SystemSnapshot(
            captureTime: Date(),
            captureDurationMs: 0,
            runId: "test-481",
            displays: [],
            windows: windows
        )
    }

    private func makeTerminalWindow(id: CGWindowID, frame: CGRect) -> SnapshotWindow {
        SnapshotWindow(
            windowId: id,
            pid: Self.terminalPid,
            bundleId: BundleRegistry.terminal,
            appName: "Terminal",
            title: "project — zsh",
            frame: frame,
            layer: 0,
            isOnScreen: true
        )
    }

    @Test("Injected enumerator supplies the AX working directory")
    func injectedEnumeratorSuppliesWorkingDirectory() async throws {
        let frame = CGRect(x: 0, y: 0, width: 600, height: 400)
        let mock = MockAXWindowEnumerator(
            processIDsByBundleID: [BundleRegistry.terminal: Self.terminalPid],
            windowsToReturn: [
                AXWindowService.AXEnumeratedWindow(
                    element: AXUIElementCreateApplication(Self.terminalPid),
                    frame: frame,
                    title: nil,
                    windowNumber: nil,
                    documentPath: "/Users/test/project"
                )
            ]
        )
        let service = TerminalSupplementationService(axService: mock)
        let snapshot = makeSnapshot(windows: [makeTerminalWindow(id: 11, frame: frame)])

        let enriched = await service.supplementTerminalWindows(
            in: snapshot,
            method: .axAPI,
            runId: "test-481"
        )

        let window = try #require(enriched.windows.first)
        #expect(window.freshWorkingDirectory == "/Users/test/project")
        #expect(window.workingDirectorySource == .axDocument)
        #expect(window.terminalSupplementationStatus == .completed)
        #expect(window.documentPath == "/Users/test/project")

        // The service must have gone through the injected dependency.
        #expect(mock.processIDLookups == [BundleRegistry.terminal])
        #expect(mock.enumerateCalls.count == 1)
        #expect(mock.enumerateCalls.first?.pid == Self.terminalPid)
        #expect(mock.enumerateCalls.first?.includeDocumentPath == true)
    }

    @Test("AX enumeration failure (per injected dependency) marks windows failed")
    func axFailureMarksFailed() async throws {
        let mock = MockAXWindowEnumerator(
            processIDsByBundleID: [BundleRegistry.terminal: Self.terminalPid],
            windowsToReturn: nil  // simulates kAXWindows copy failure
        )
        let service = TerminalSupplementationService(axService: mock)
        let snapshot = makeSnapshot(windows: [
            makeTerminalWindow(id: 11, frame: CGRect(x: 0, y: 0, width: 600, height: 400))
        ])

        let enriched = await service.supplementTerminalWindows(
            in: snapshot,
            method: .axAPI,
            runId: "test-481"
        )

        let window = try #require(enriched.windows.first)
        #expect(window.freshWorkingDirectory == nil)
        #expect(window.terminalSupplementationStatus == .failed)
        #expect(mock.enumerateCalls.count == 1)
    }
}

// NOTE: `MockAXWindowEnumerator` lives in the shared `MockAXWindowService.swift`
// (one copy per test target, matching the upstream BentoTests layout).
