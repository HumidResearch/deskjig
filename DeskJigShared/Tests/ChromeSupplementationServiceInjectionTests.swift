//  ChromeSupplementationServiceInjectionTests.swift
//  DeskJigSharedTests

import Foundation
import ApplicationServices
import CoreGraphics
import Testing
@testable import DeskJigShared

@Suite("ChromeSupplementationService AX injection (#481)")
struct ChromeSupplementationServiceInjectionTests {

    private static let chromeBundleId = "com.google.Chrome"
    private static let chromePid: pid_t = 4242

    private func makeSnapshot(windows: [SnapshotWindow]) -> SystemSnapshot {
        SystemSnapshot(
            captureTime: Date(),
            captureDurationMs: 0,
            runId: "test-481",
            displays: [],
            windows: windows
        )
    }

    private func makeChromeWindow(id: CGWindowID, title: String, frame: CGRect) -> SnapshotWindow {
        SnapshotWindow(
            windowId: id,
            pid: Self.chromePid,
            bundleId: Self.chromeBundleId,
            appName: "Google Chrome",
            title: title,
            frame: frame,
            layer: 0,
            isOnScreen: true
        )
    }

    @Test("Injected enumerator supplies fresh AX titles and the profile name")
    func injectedEnumeratorEnrichesProfile() async throws {
        let frame = CGRect(x: 0, y: 0, width: 800, height: 600)
        let mock = MockAXWindowEnumerator(
            processIDsByBundleID: [Self.chromeBundleId: Self.chromePid],
            windowsToReturn: [
                AXWindowService.AXEnumeratedWindow(
                    element: AXUIElementCreateApplication(Self.chromePid),
                    frame: frame,
                    title: "GitHub - Google Chrome - Person 1",
                    windowNumber: nil,
                    documentPath: nil
                )
            ]
        )
        let service = ChromeSupplementationService(axService: mock)
        let snapshot = makeSnapshot(windows: [
            makeChromeWindow(id: 7, title: "GitHub - Google Chrome", frame: frame)
        ])

        let enriched = await service.supplementChromeWindows(
            in: snapshot,
            method: .appleScript,
            includeTabUrls: false,
            runId: "test-481"
        )

        let window = try #require(enriched.windows.first)
        #expect(window.freshAxTitle == "GitHub - Google Chrome - Person 1")
        #expect(window.chromeProfileFromTitle == "Person 1")
        #expect(window.supplementationStatus == .completed)

        // The service must have gone through the injected dependency.
        #expect(mock.processIDLookups == [Self.chromeBundleId])
        #expect(mock.enumerateCalls.count == 1)
        #expect(mock.enumerateCalls.first?.pid == Self.chromePid)
        #expect(mock.enumerateCalls.first?.includeTitle == true)
    }

    @Test("Chrome not running (per injected dependency) marks windows failed without AX calls")
    func chromeNotRunningMarksFailed() async throws {
        let mock = MockAXWindowEnumerator()  // no PIDs registered
        let service = ChromeSupplementationService(axService: mock)
        let snapshot = makeSnapshot(windows: [
            makeChromeWindow(
                id: 7,
                title: "GitHub - Google Chrome",
                frame: CGRect(x: 0, y: 0, width: 800, height: 600)
            )
        ])

        let enriched = await service.supplementChromeWindows(
            in: snapshot,
            method: .appleScript,
            includeTabUrls: false,
            runId: "test-481"
        )

        let window = try #require(enriched.windows.first)
        #expect(window.freshAxTitle == nil)
        #expect(window.supplementationStatus == .failed)
        #expect(mock.enumerateCalls.isEmpty)
    }
}
