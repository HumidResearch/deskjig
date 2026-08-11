//  WindowLookupWindowDictionaryTests.swift
//  DeskJigSharedTests

import Testing
import CoreGraphics
@testable import DeskJigShared

// Gated: queries the live CGWindowList; `candidatesChecked` is machine-dependent
// and a window server must be present. Absent from the Headless whitelist.
@Suite(.enabled(if: TestEnvironment.envTestsEnabled, TestEnvironment.gateReason))
struct WindowLookupWindowDictionaryTests {

    /// A CGWindowID that cannot correspond to a real on-screen window in any environment.
    private static let nonexistentWindowId: CGWindowID = .max

    @Test("Window.info(windowId:) returns nil for a nonexistent window ID")
    func infoReturnsNilForNonexistentWindowId() {
        let window = Window.info(windowId: Self.nonexistentWindowId)
        #expect(window == nil)
    }

    @Test("Window.infoWithResult(windowId:) reports not-found for a nonexistent window ID via the scan fallback")
    func infoWithResultReportsNotFoundForNonexistentWindowId() {
        let result = Window.infoWithResult(windowId: Self.nonexistentWindowId)

        #expect(result.window == nil)
        #expect(!result.isSuccess)
        // Both the (bridging-bug) direct path and the pointer-valued fix fall through to the
        // full-list scan for an ID that doesn't exist on-screen, then report not-found with
        // however many windows the scan checked (>= 0, machine-dependent) rather than 1 — the
        // "direct"-only candidate count that a spurious/incorrect single-descriptor hit would
        // otherwise produce.
        #expect(result.candidatesChecked != 1)
    }
}
