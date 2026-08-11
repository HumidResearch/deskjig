//  AXWindowServiceSelfProcessGuardTests.swift
//  DeskJigSharedTests

import Testing
import Foundation
import ApplicationServices
@testable import DeskJigShared

@Suite("AXWindowService self-process guard (#618)")
struct AXWindowServiceSelfProcessGuardTests {

    /// An AX element whose owning PID is the current process.
    private var selfElement: AXUIElement {
        AXUIElementCreateApplication(getpid())
    }

    /// An AX element owned by another process (launchd, PID 1) — used as a control to
    /// prove the guard is PID-scoped rather than a blanket refusal.
    private var foreignElement: AXUIElement {
        AXUIElementCreateApplication(1)
    }

    // MARK: - Minimize / unminimize (fix round 0)

    @Test("minimizeResult refuses a self-owned element")
    func minimizeResultRefusesSelf() {
        let result = AXWindowService.shared.minimizeResult(selfElement)
        guard case .failure(.selfProcessWindow(let operation)) = result else {
            Issue.record("Expected .selfProcessWindow failure, got \(result)")
            return
        }
        #expect(operation == "minimize")
    }

    @Test("minimize returns false for a self-owned element")
    func minimizeReturnsFalseForSelf() {
        #expect(AXWindowService.shared.minimize(selfElement) == false)
    }

    @Test("restore (unminimize) returns false for a self-owned element")
    func restoreReturnsFalseForSelf() {
        #expect(AXWindowService.shared.restore(selfElement) == false)
    }

    // MARK: - Move / setFrame (fix round 1 — where the crash migrated)

    @Test("moveResult refuses a self-owned element (kAXPosition/kAXSize hazard)")
    func moveResultRefusesSelf() {
        let result = AXWindowService.shared.moveResult(selfElement, to: CGRect(x: 0, y: 0, width: 400, height: 300))
        guard case .failure(.selfProcessWindow(let operation)) = result else {
            Issue.record("Expected .selfProcessWindow failure, got \(result)")
            return
        }
        #expect(operation == "move")
    }

    @Test("move returns false for a self-owned element")
    func moveReturnsFalseForSelf() {
        #expect(AXWindowService.shared.move(selfElement, to: CGRect(x: 10, y: 10, width: 200, height: 200)) == false)
    }

    // MARK: - Raise / activate / close (rest of the mutation class)

    @Test("raiseResult refuses a self-owned element")
    func raiseResultRefusesSelf() {
        let result = AXWindowService.shared.raiseResult(selfElement)
        guard case .failure(.selfProcessWindow(let operation)) = result else {
            Issue.record("Expected .selfProcessWindow failure, got \(result)")
            return
        }
        #expect(operation == "raise")
    }

    @Test("activateResult refuses a self-owned element")
    func activateResultRefusesSelf() {
        let result = AXWindowService.shared.activateResult(selfElement, processID: getpid())
        guard case .failure(.selfProcessWindow(let operation)) = result else {
            Issue.record("Expected .selfProcessWindow failure, got \(result)")
            return
        }
        #expect(operation == "activate")
    }

    @Test("closeResult refuses a self-owned element")
    func closeResultRefusesSelf() {
        let result = AXWindowService.shared.closeResult(selfElement)
        guard case .failure(.selfProcessWindow(let operation)) = result else {
            Issue.record("Expected .selfProcessWindow failure, got \(result)")
            return
        }
        #expect(operation == "close")
    }

    // MARK: - PID-scoping controls (guard must not misfire on foreign windows)

    @Test("guard is PID-scoped: a foreign element is not short-circuited as self (minimize)")
    func foreignElementIsNotSelfRefusedMinimize() {
        // A foreign element will still fail (no minimizable window / no permission), but
        // it must NOT fail with `.selfProcessWindow` — that would mean the guard is
        // misfiring on windows DeskJig legitimately manages.
        let result = AXWindowService.shared.minimizeResult(foreignElement)
        if case .failure(.selfProcessWindow) = result {
            Issue.record("Foreign element was incorrectly refused as self-owned (minimize)")
        }
    }

    @Test("guard is PID-scoped: a foreign element is not short-circuited as self (move)")
    func foreignElementIsNotSelfRefusedMove() {
        let result = AXWindowService.shared.moveResult(foreignElement, to: CGRect(x: 0, y: 0, width: 400, height: 300))
        if case .failure(.selfProcessWindow) = result {
            Issue.record("Foreign element was incorrectly refused as self-owned (move)")
        }
    }
}
