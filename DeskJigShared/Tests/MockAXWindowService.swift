//  MockAXWindowService.swift
//  DeskJigSharedTests

import Foundation
import ApplicationServices
import CoreGraphics
@testable import DeskJigShared

// MARK: - MockAXWindowEnumerator

/// Mock for `AXWindowEnumerating` (PID resolution + raw AX window enumeration).
final class MockAXWindowEnumerator: AXWindowEnumerating, @unchecked Sendable {
    private let lock = NSLock()

    /// Bundle ID -> PID mapping returned by `getProcessID(for:)`.
    var processIDsByBundleID: [String: pid_t]

    /// Windows returned by `enumerateWindows`. `nil` simulates an AX failure
    /// (distinct from `[]`, which means "app exposes zero windows").
    var windowsToReturn: [AXWindowService.AXEnumeratedWindow]?

    /// Recorded `enumerateWindows` invocations.
    private(set) var enumerateCalls: [(pid: pid_t, includeTitle: Bool, includeWindowNumber: Bool, includeDocumentPath: Bool)] = []

    /// Recorded `getProcessID(for:)` invocations.
    private(set) var processIDLookups: [String] = []

    init(
        processIDsByBundleID: [String: pid_t] = [:],
        windowsToReturn: [AXWindowService.AXEnumeratedWindow]? = nil
    ) {
        self.processIDsByBundleID = processIDsByBundleID
        self.windowsToReturn = windowsToReturn
    }

    func getProcessID(for bundleIdentifier: String) -> pid_t? {
        lock.lock()
        defer { lock.unlock() }
        processIDLookups.append(bundleIdentifier)
        return processIDsByBundleID[bundleIdentifier]
    }

    func enumerateWindows(
        pid: pid_t,
        includeTitle: Bool,
        includeWindowNumber: Bool,
        includeDocumentPath: Bool
    ) -> [AXWindowService.AXEnumeratedWindow]? {
        lock.lock()
        defer { lock.unlock() }
        enumerateCalls.append((pid, includeTitle, includeWindowNumber, includeDocumentPath))
        return windowsToReturn
    }
}

// MARK: - MockAXWindowService

/// Full-protocol mock for `AXWindowServiceProtocol`. All operations succeed by
/// default (configurable via the `*Result` properties) and mutating calls are
/// recorded for assertions.
final class MockAXWindowService: AXWindowServiceProtocol, @unchecked Sendable {
    private let lock = NSLock()

    // MARK: Configurable results

    var processIDsByBundleID: [String: pid_t] = [:]
    var windowsToReturn: [AXWindow] = []
    var moveSucceeds = true

    /// Optional per-window override for `refresh(_:)`. Return an updated `AXWindow`
    /// to simulate state that changed since enumeration, or `nil` to simulate a
    /// window that no longer exists. When unset, `refresh` echoes the input window.
    var refreshHandler: ((AXWindow) -> AXWindow?)?

    // MARK: Recorded calls

    /// Frames passed to `move(_:to:)` (both AXWindow- and element-based), in order.
    private(set) var movedFrames: [CGRect] = []

    /// Windows passed to `refresh(_:)`, in order.
    private(set) var refreshedWindows: [AXWindow] = []

    private func recordMove(_ frame: CGRect) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        movedFrames.append(frame)
        return moveSucceeds
    }

    // MARK: Process Discovery

    func getProcessID(for bundleIdentifier: String) -> pid_t? {
        lock.lock()
        defer { lock.unlock() }
        return processIDsByBundleID[bundleIdentifier]
    }

    func getProcessIDs(for bundleIdentifier: String) -> [pid_t] {
        lock.lock()
        defer { lock.unlock() }
        return processIDsByBundleID[bundleIdentifier].map { [$0] } ?? []
    }

    func getProcessID(forAnyOf bundleIdentifiers: [String]) -> pid_t? {
        lock.lock()
        defer { lock.unlock() }
        return bundleIdentifiers.compactMap { processIDsByBundleID[$0] }.first
    }

    // MARK: App Element Operations

    func createAppElement(for processID: pid_t) -> AXUIElement? { AXUIElementCreateApplication(processID) }
    func validateAppElement(_ element: AXUIElement, for processID: pid_t) -> Bool { true }
    func hideApp(_ appElement: AXUIElement) -> Bool { true }

    // MARK: Window Discovery

    func getWindows(forProcessID processID: pid_t, bundleIdentifier: String?) -> [AXWindow] {
        lock.lock()
        defer { lock.unlock() }
        return windowsToReturn
    }

    func getWindowElements(from appElement: AXUIElement) -> [AXUIElement] { [] }
    func findWindowElement(in appElement: AXUIElement, matchingFrame frame: CGRect, title: String?) -> AXUIElement? { nil }
    func createWindow(from axElement: AXUIElement, processID: pid_t, bundleIdentifier: String?) -> AXWindow? { nil }

    func refresh(_ window: AXWindow) -> AXWindow? {
        lock.lock()
        defer { lock.unlock() }
        refreshedWindows.append(window)
        if let refreshHandler {
            return refreshHandler(window)
        }
        return window
    }

    // MARK: Window Properties

    func getTitle(for window: AXWindow) -> String { window.title }
    func getFrame(for element: AXUIElement) -> CGRect? { nil }
    func getTitle(for element: AXUIElement) -> String? { nil }

    // MARK: Window Manipulation (AXWindow-based)

    func move(_ window: AXWindow, to frame: CGRect) -> Bool { recordMove(frame) }
    func restore(_ window: AXWindow) -> Bool { true }
    func activate(_ window: AXWindow) -> Bool { true }
    func minimize(_ window: AXWindow) -> Bool { true }
    func close(_ window: AXWindow) -> Bool { true }
    func raise(_ window: AXWindow) -> Bool { true }

    // MARK: Window Manipulation (AXUIElement-based)

    func moveResult(_ element: AXUIElement, to frame: CGRect) -> Result<Void, AXOperationError> {
        recordMove(frame) ? .success(()) : .failure(.axFailure(operation: "move", status: .failure))
    }

    func move(_ element: AXUIElement, to frame: CGRect) -> Bool { recordMove(frame) }
    func restore(_ element: AXUIElement) -> Bool { true }
    func activateResult(_ element: AXUIElement, processID: pid_t) -> Result<Void, AXOperationError> { .success(()) }
    func activate(_ element: AXUIElement, processID: pid_t) -> Bool { true }
    func minimizeResult(_ element: AXUIElement) -> Result<Void, AXOperationError> { .success(()) }
    func minimize(_ element: AXUIElement) -> Bool { true }
    func closeResult(_ element: AXUIElement) -> Result<Void, AXOperationError> { .success(()) }
    func close(_ element: AXUIElement) -> Bool { true }
    func raiseResult(_ element: AXUIElement) -> Result<Void, AXOperationError> { .success(()) }
    func raise(_ element: AXUIElement) -> Bool { true }
}
