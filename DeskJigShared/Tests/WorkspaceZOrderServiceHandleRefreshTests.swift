//
//  WorkspaceZOrderServiceHandleRefreshTests.swift
//  DeskJigSharedTests
//
//  Hermetic coverage for the #500 fix: WindowHandle.frame/isMinimized are AX
//  snapshots captured at enumeration, and the shared per-bundle handle cache in
//  WorkspaceZOrderService keeps those snapshots across all post-restore phases.
//  Frame- and minimized-state-based tie-breaks must therefore pass their
//  candidates through a HandleTieBreakRefresher, which re-reads AX state at most
//  once per phase and drops handles whose windows no longer exist.
//
//  Uses MockAXWindowService via the FluentServices seam — no Accessibility
//  permission is required because no real AX call is ever made.
//

import Foundation
import CoreGraphics
import ApplicationServices
import Testing
@testable import DeskJigShared

@Suite("WorkspaceZOrderService handle tie-break refresh (#500)", .serialized)
struct WorkspaceZOrderServiceHandleRefreshTests {

    // MARK: - Fixtures

    /// Distinct AX elements per fake window so refreshHandler can key off title
    /// while handles stay distinguishable. AXUIElementCreateApplication does not
    /// touch the AX server until an attribute is read, so this stays hermetic.
    private func makeAXWindow(
        title: String,
        frame: CGRect,
        isMinimized: Bool = false,
        pid: pid_t = 4242
    ) -> AXWindow {
        AXWindow(
            axElement: AXUIElementCreateApplication(pid),
            frame: frame,
            title: title,
            isMinimized: isMinimized,
            isHidden: false,
            processID: pid,
            bundleIdentifier: "com.example.zorder-refresh"
        )
    }

    /// Installs the mock AX service for the duration of `body`, restoring the
    /// previous FluentServices state afterwards.
    private func withMockAXService<T>(
        _ mock: MockAXWindowService,
        _ body: () throws -> T
    ) rethrows -> T {
        let previous = FluentServices.shared.axWindowService
        FluentServices.shared.axWindowService = mock
        defer { FluentServices.shared.axWindowService = previous }
        return try body()
    }

    // MARK: - Tests

    @Test("Refresher updates stale frames so frame-tolerance tie-breaks pick the current window")
    func refreshUpdatesStaleFramesBeforeTieBreak() throws {
        // Two same-title windows of one app (the #500 repro shape). At enumeration
        // time windowA sat at the target slot and windowB far away. An earlier
        // phase then swapped them (moved B into the slot, A out) — the cached
        // snapshots still show the pre-move frames.
        let targetFrame = CGRect(x: 0, y: 0, width: 800, height: 600)
        let awayFrame = CGRect(x: 1200, y: 400, width: 800, height: 600)

        let handleA = WindowHandle(axWindow: makeAXWindow(title: "shared-title A", frame: targetFrame))
        let handleB = WindowHandle(axWindow: makeAXWindow(title: "shared-title B", frame: awayFrame))

        let mock = MockAXWindowService()
        mock.refreshHandler = { window in
            // Post-move reality: A moved away, B now occupies the target slot.
            switch window.title {
            case "shared-title A":
                return AXWindow(
                    axElement: window.axElement,
                    frame: awayFrame,
                    title: window.title,
                    isMinimized: window.isMinimized,
                    isHidden: window.isHidden,
                    processID: window.processID,
                    bundleIdentifier: window.bundleIdentifier
                )
            case "shared-title B":
                return AXWindow(
                    axElement: window.axElement,
                    frame: targetFrame,
                    title: window.title,
                    isMinimized: window.isMinimized,
                    isHidden: window.isHidden,
                    processID: window.processID,
                    bundleIdentifier: window.bundleIdentifier
                )
            default:
                return window
            }
        }

        try withMockAXService(mock) {
            let tolerance: CGFloat = 20.0
            func frameTieBreak(_ candidates: [WindowHandle]) -> WindowHandle? {
                candidates.first(where: { handle in
                    guard let handleFrame = handle.frame else { return false }
                    return abs(handleFrame.origin.x - targetFrame.origin.x) <= tolerance &&
                           abs(handleFrame.origin.y - targetFrame.origin.y) <= tolerance
                })
            }

            // Stale snapshots pick the WRONG window (A) for the target slot.
            #expect(frameTieBreak([handleA, handleB]) === handleA)

            // Routed through the refresher, the tie-break sees current AX frames
            // and picks the window actually occupying the slot (B).
            let refresher = WorkspaceZOrderService.HandleTieBreakRefresher()
            let refreshed = refresher.refreshedForTieBreak([handleA, handleB])
            #expect(refreshed.count == 2)
            let selected = try #require(frameTieBreak(refreshed))
            #expect(selected === handleB)
            #expect(handleA.frame == awayFrame)
            #expect(handleB.frame == targetFrame)
        }
    }

    @Test("Refresher updates stale minimized state for skip decisions (zorder-11 input)")
    func refreshUpdatesStaleMinimizedState() throws {
        // Enumeration-time snapshot says "not minimized"; an earlier phase (via a
        // different handle instance) has since minimized the window.
        let handle = WindowHandle(axWindow: makeAXWindow(
            title: "minimized-later",
            frame: CGRect(x: 10, y: 10, width: 400, height: 300),
            isMinimized: false
        ))

        let mock = MockAXWindowService()
        mock.refreshHandler = { window in
            AXWindow(
                axElement: window.axElement,
                frame: window.frame,
                title: window.title,
                isMinimized: true,
                isHidden: window.isHidden,
                processID: window.processID,
                bundleIdentifier: window.bundleIdentifier
            )
        }

        try withMockAXService(mock) {
            #expect(!handle.isMinimized)
            let refresher = WorkspaceZOrderService.HandleTieBreakRefresher()
            let refreshed = try #require(refresher.refreshedForTieBreak(handle))
            #expect(refreshed === handle)
            #expect(refreshed.isMinimized)
        }
    }

    @Test("Each handle is refreshed at most once per refresher (per phase)")
    func refreshHappensAtMostOncePerRefresher() {
        let handleA = WindowHandle(axWindow: makeAXWindow(title: "once A", frame: .zero))
        let handleB = WindowHandle(axWindow: makeAXWindow(title: "once B", frame: .zero))

        let mock = MockAXWindowService()
        withMockAXService(mock) {
            let refresher = WorkspaceZOrderService.HandleTieBreakRefresher()
            _ = refresher.refreshedForTieBreak([handleA, handleB])
            _ = refresher.refreshedForTieBreak([handleA, handleB])
            _ = refresher.refreshedForTieBreak(handleA)
            #expect(mock.refreshedWindows.count == 2)

            // A NEW refresher (a new phase) refreshes again — the guard is
            // per-phase, not per-restore.
            let nextPhaseRefresher = WorkspaceZOrderService.HandleTieBreakRefresher()
            _ = nextPhaseRefresher.refreshedForTieBreak([handleA, handleB])
            #expect(mock.refreshedWindows.count == 4)
        }
    }

    @Test("Handles whose windows vanished are dropped from tie-break candidates")
    func deadHandlesAreDropped() {
        let liveHandle = WindowHandle(axWindow: makeAXWindow(title: "still-alive", frame: .zero))
        let deadHandle = WindowHandle(axWindow: makeAXWindow(title: "closed-window", frame: .zero))

        let mock = MockAXWindowService()
        mock.refreshHandler = { window in
            window.title == "closed-window" ? nil : window
        }

        withMockAXService(mock) {
            let refresher = WorkspaceZOrderService.HandleTieBreakRefresher()

            let firstPass = refresher.refreshedForTieBreak([liveHandle, deadHandle])
            #expect(firstPass.count == 1)
            #expect(firstPass.first === liveHandle)
            #expect(!deadHandle.exists)

            // The dead handle stays excluded on later passes without extra AX calls.
            let secondPass = refresher.refreshedForTieBreak([liveHandle, deadHandle])
            #expect(secondPass.count == 1)
            #expect(mock.refreshedWindows.count == 2)

            // Single-handle variant reports the vanished window as nil.
            #expect(refresher.refreshedForTieBreak(deadHandle) == nil)
            #expect(refresher.refreshedForTieBreak(liveHandle) === liveHandle)
        }
    }
}
