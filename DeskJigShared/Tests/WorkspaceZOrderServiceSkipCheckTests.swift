//
//  WorkspaceZOrderServiceSkipCheckTests.swift
//  DeskJigSharedTests
//
//  Verifies the zorder-11 (#501) skip condition in validateOpenPathWindows: the
//  "slot already correct" short-circuit may only fire when the SELECTED window itself
//  is the on-screen topmost window at the target frame. Previously the skip was
//  frame-anchored but identity-blind — with two same-bundle windows sharing a
//  normalized open path (one on-screen at the target frame, one minimized), the
//  frame check could pass on the on-screen duplicate while `selected` resolved to
//  the minimized one, leaving the workspace window minimized after restore.
//

import Testing
@testable import DeskJigShared

@Suite("WorkspaceZOrderService zorder-11 skip check")
struct WorkspaceZOrderServiceSkipCheckTests {

    // Repro topology from #501: two Cursor windows share the normalized open path.
    // Window 101 is on-screen at the target frame (it is the CG topmost there and
    // carries the expected document path, so slotAlreadyCorrect passes). Window 202
    // is the minimized duplicate that title/PID/hash ordering resolved as `selected`.
    private let onScreenDuplicateWindowNumber = 101
    private let minimizedSelectedWindowNumber = 202

    @Test("Minimized selected duplicate must take the restore path, not the skip path")
    func minimizedSelectedDuplicateIsNotVerifiedTopmost() {
        // selected = the minimized duplicate; topmost = the on-screen duplicate.
        // The old frame-only check skipped here; the identity check must not.
        #expect(
            !WorkspaceZOrderService.selectedWindowIsVerifiedTopmost(
                selectedWindowNumber: minimizedSelectedWindowNumber,
                selectedIsMinimized: true,
                topmostWindowNumber: onScreenDuplicateWindowNumber
            )
        )
    }

    @Test("Un-minimized selected duplicate distinct from the topmost window still restores")
    func unminimizedButDifferentWindowIsNotVerifiedTopmost() {
        // Even if the selected duplicate is not minimized (e.g. buried behind the
        // topmost one), it is not the window that passed the frame check, so the
        // skip must not fire on its behalf.
        #expect(
            !WorkspaceZOrderService.selectedWindowIsVerifiedTopmost(
                selectedWindowNumber: minimizedSelectedWindowNumber,
                selectedIsMinimized: false,
                topmostWindowNumber: onScreenDuplicateWindowNumber
            )
        )
    }

    @Test("Selected window that IS the on-screen topmost keeps the skip optimization")
    func selectedIsTheOnScreenTopmostWindow() {
        // Healthy single-window case: selected resolved to the same window the
        // frame-anchored check saw on-screen — the redundant restore()/activate()
        // stays skipped.
        #expect(
            WorkspaceZOrderService.selectedWindowIsVerifiedTopmost(
                selectedWindowNumber: onScreenDuplicateWindowNumber,
                selectedIsMinimized: false,
                topmostWindowNumber: onScreenDuplicateWindowNumber
            )
        )
    }

    @Test("Matching window numbers never skip a minimized selected window")
    func minimizedSelectedNeverSkipsEvenOnNumberMatch() {
        // Defensive: if stale AX state ever reports the same window number for a
        // minimized selected handle, the minimized state wins and we restore.
        #expect(
            !WorkspaceZOrderService.selectedWindowIsVerifiedTopmost(
                selectedWindowNumber: onScreenDuplicateWindowNumber,
                selectedIsMinimized: true,
                topmostWindowNumber: onScreenDuplicateWindowNumber
            )
        )
    }

    @Test("Missing selected window number fails closed to the restore path")
    func missingSelectedWindowNumberFailsClosed() {
        #expect(
            !WorkspaceZOrderService.selectedWindowIsVerifiedTopmost(
                selectedWindowNumber: nil,
                selectedIsMinimized: false,
                topmostWindowNumber: onScreenDuplicateWindowNumber
            )
        )
    }

    @Test("Missing topmost window number fails closed to the restore path")
    func missingTopmostWindowNumberFailsClosed() {
        #expect(
            !WorkspaceZOrderService.selectedWindowIsVerifiedTopmost(
                selectedWindowNumber: minimizedSelectedWindowNumber,
                selectedIsMinimized: false,
                topmostWindowNumber: nil
            )
        )
    }
}
