//
//  AXWindowService.swift
//  DeskJigShared
//
//  Created by Marco Freedom on 27.11.2025.
//

import Foundation
import Cocoa
import ApplicationServices

// MARK: - AXWindow (Generic AX Window Representation)

public enum AXOperationError: Error, CustomStringConvertible {
    case valueCreationFailed(attribute: String)
    case axFailure(operation: String, status: AXError)
    case appNotFound(processID: pid_t)
    /// The operation targeted a window owned by the current (host) process, which is
    /// refused for AppKit window-coordinator mutations (move / setFrame / minimize /
    /// deminiaturize / raise / activate / close).
    /// See ``AXWindowService/selfProcessRefusal(_:operation:)`` and issue #618.
    case selfProcessWindow(operation: String)

    public var description: String {
        switch self {
        case .valueCreationFailed(let attribute):
            return "Failed to create AX value for \(attribute)"
        case .axFailure(let operation, let status):
            return "AX operation '\(operation)' failed with status \(status.rawValue)"
        case .appNotFound(let processID):
            return "Running application not found for PID \(processID)"
        case .selfProcessWindow(let operation):
            return "AX operation '\(operation)' refused on a window owned by the current process"
        }
    }
}

/// Represents a window queried directly from Accessibility API.
/// Used by restoration handlers to avoid snapshot-level dependencies.
public struct AXWindow: Hashable {
    public let axElement: AXUIElement
    public let frame: CGRect
    public let title: String
    public let isMinimized: Bool
    public let isHidden: Bool
    public let processID: pid_t
    public let bundleIdentifier: String?

    public init(
        axElement: AXUIElement,
        frame: CGRect,
        title: String,
        isMinimized: Bool,
        isHidden: Bool,
        processID: pid_t,
        bundleIdentifier: String? = nil
    ) {
        self.axElement = axElement
        self.frame = frame
        self.title = title
        self.isMinimized = isMinimized
        self.isHidden = isHidden
        self.processID = processID
        self.bundleIdentifier = bundleIdentifier
    }

    /// Unique identity based on frame + title + processID (no CGWindowID available from AX)
    public func hash(into hasher: inout Hasher) {
        hasher.combine(frame.origin.x)
        hasher.combine(frame.origin.y)
        hasher.combine(frame.width)
        hasher.combine(frame.height)
        hasher.combine(title)
        hasher.combine(processID)
    }

    public static func == (lhs: AXWindow, rhs: AXWindow) -> Bool {
        return lhs.frame == rhs.frame &&
               lhs.title == rhs.title &&
               lhs.processID == rhs.processID
    }

    /// Check if this window's frame matches a target frame (with tolerance)
    public func frameMatches(_ targetFrame: CGRect, tolerance: CGFloat = 10.0) -> Bool {
        let originDiff = abs(frame.origin.x - targetFrame.origin.x) + abs(frame.origin.y - targetFrame.origin.y)
        let sizeDiff = abs(frame.size.width - targetFrame.size.width) + abs(frame.size.height - targetFrame.size.height)
        return originDiff <= tolerance && sizeDiff <= tolerance
    }

    /// Create a unique string key for this window (for tracking positioned windows)
    public var identityKey: String {
        return "\(Int(frame.origin.x)),\(Int(frame.origin.y)),\(Int(frame.width)),\(Int(frame.height))|\(title)"
    }
}

// MARK: - AXWindowService Protocol

/// Protocol for AX window operations to enable testing.
/// This service works ONLY with AXWindow and AXUIElement - no WindowInfo dependency.
public protocol AXWindowServiceProtocol: AnyObject {
    // Process Discovery
    func getProcessID(for bundleIdentifier: String) -> pid_t?
    func getProcessIDs(for bundleIdentifier: String) -> [pid_t]
    func getProcessID(forAnyOf bundleIdentifiers: [String]) -> pid_t?

    // App Element Operations
    func createAppElement(for processID: pid_t) -> AXUIElement?
    func validateAppElement(_ element: AXUIElement, for processID: pid_t) -> Bool
    func hideApp(_ appElement: AXUIElement) -> Bool

    // Window Discovery
    func getWindows(forProcessID processID: pid_t, bundleIdentifier: String?) -> [AXWindow]
    func getWindowElements(from appElement: AXUIElement) -> [AXUIElement]
    func findWindowElement(in appElement: AXUIElement, matchingFrame frame: CGRect, title: String?) -> AXUIElement?
    func createWindow(from axElement: AXUIElement, processID: pid_t, bundleIdentifier: String?) -> AXWindow?
    func refresh(_ window: AXWindow) -> AXWindow?

    // Window Properties
    func getTitle(for window: AXWindow) -> String
    func getFrame(for element: AXUIElement) -> CGRect?
    func getTitle(for element: AXUIElement) -> String?

    // Window Manipulation (AXWindow-based)
    func move(_ window: AXWindow, to frame: CGRect) -> Bool
    func restore(_ window: AXWindow) -> Bool
    func activate(_ window: AXWindow) -> Bool
    func minimize(_ window: AXWindow) -> Bool
    func close(_ window: AXWindow) -> Bool
    func raise(_ window: AXWindow) -> Bool

    // Window Manipulation (AXUIElement-based)
    func moveResult(_ element: AXUIElement, to frame: CGRect) -> Result<Void, AXOperationError>
    func move(_ element: AXUIElement, to frame: CGRect) -> Bool
    func restore(_ element: AXUIElement) -> Bool
    func activateResult(_ element: AXUIElement, processID: pid_t) -> Result<Void, AXOperationError>
    func activate(_ element: AXUIElement, processID: pid_t) -> Bool
    func minimizeResult(_ element: AXUIElement) -> Result<Void, AXOperationError>
    func minimize(_ element: AXUIElement) -> Bool
    func closeResult(_ element: AXUIElement) -> Result<Void, AXOperationError>
    func close(_ element: AXUIElement) -> Bool
    func raiseResult(_ element: AXUIElement) -> Result<Void, AXOperationError>
    func raise(_ element: AXUIElement) -> Bool
}

// MARK: - AXWindowEnumerating Protocol

/// Minimal AX capability surface used by the snapshot supplementation services
/// (Chrome/Terminal/IDE): resolve a running app's PID and enumerate its raw AX
/// windows. Kept deliberately small so consumers can inject a mock without
/// implementing all of `AXWindowServiceProtocol` (#481).
public protocol AXWindowEnumerating: AnyObject {
    /// Get process ID for a bundle identifier from running applications.
    func getProcessID(for bundleIdentifier: String) -> pid_t?

    /// Enumerate an application's AX windows directly via `kAXWindows`.
    /// See ``AXWindowService/enumerateWindows(pid:includeTitle:includeWindowNumber:includeDocumentPath:)``.
    func enumerateWindows(
        pid: pid_t,
        includeTitle: Bool,
        includeWindowNumber: Bool,
        includeDocumentPath: Bool
    ) -> [AXWindowService.AXEnumeratedWindow]?
}

// MARK: - AXWindowService Implementation

/// Service for querying and manipulating windows via macOS Accessibility API.
/// This service works ONLY with AXWindow and AXUIElement - no WindowInfo dependency.
/// Provides a reusable, testable interface for pure AX window operations.
public class AXWindowService: AXWindowServiceProtocol, AXWindowEnumerating {

    public static let shared = AXWindowService()

    public init() {}

    // MARK: - Enhanced UI Workaround

    /// Temporarily disables `kAXEnhancedUserInterface` on the owning app before executing a
    /// block, then restores the original value. Some apps (and screen readers) set this
    /// attribute, which causes AX position/size operations to fail or behave erratically.
    /// Inspired by yabai's `AX_ENHANCED_UI_WORKAROUND` macro.
    private func withEnhancedUIDisabled<T>(for windowElement: AXUIElement, body: () -> T) -> T {
        var pidValue: pid_t = 0
        AXUIElementGetPid(windowElement, &pidValue)
        guard pidValue != 0 else { return body() }

        let appElement = AXUIElementCreateApplication(pidValue)
        var euiRef: CFTypeRef?
        let queryResult = AXUIElementCopyAttributeValue(
            appElement,
            "AXEnhancedUserInterface" as CFString,
            &euiRef
        )
        let wasEnabled: Bool = {
            guard queryResult == .success, let ref = euiRef, CFGetTypeID(ref) == CFBooleanGetTypeID() else { return false }
            return CFBooleanGetValue((ref as! CFBoolean))
        }()

        if wasEnabled {
            AXUIElementSetAttributeValue(
                appElement,
                "AXEnhancedUserInterface" as CFString,
                kCFBooleanFalse
            )
        }
        let result = body()
        if wasEnabled {
            AXUIElementSetAttributeValue(
                appElement,
                "AXEnhancedUserInterface" as CFString,
                kCFBooleanTrue
            )
        }
        return result
    }

    // MARK: - Self-Process Guard (#618)

    /// Returns the PID owning an AX element, or `nil` if it cannot be resolved.
    private func pid(of element: AXUIElement) -> pid_t? {
        var pidValue: pid_t = 0
        guard AXUIElementGetPid(element, &pidValue) == .success, pidValue != 0 else { return nil }
        return pidValue
    }

    /// `true` when the AX element belongs to the current (host) process.
    ///
    /// Mutating a window-coordinator attribute such as `kAXMinimizedAttribute` on a
    /// window owned by the *current* process does not go out-of-process via XMIG to the
    /// WindowServer. macOS short-circuits it to AppKit's in-process accessibility entry
    /// point (`NSAccessibilityEntryPointSetValueForAttribute`), which drives
    /// `-[NSWindow(NSWindow_Theme) _minimizeToDock]` / `_miniaturizeWindows:forRestoration:`
    /// **synchronously on the calling thread**. When that thread is not the main thread
    /// (e.g. the Swift Testing "REAL SYSTEM" suite runs on a background cooperative
    /// thread), `-[NSWMWindowCoordinator performTransactionUsingBlock:]` trips an
    /// assertion and crashes the process with `EXC_BREAKPOINT` (issue #618).
    ///
    /// DeskJig only ever *manages other apps'* windows, so a coordinator mutation targeting
    /// a self-owned window is never a legitimate operation — we refuse it rather than risk
    /// the crash. This is a real fix, not a test-only shim: production never AX-minimizes
    /// its own windows through this service.
    private func isCurrentProcessElement(_ element: AXUIElement) -> Bool {
        pid(of: element) == getpid()
    }

    /// Single chokepoint for the #618 self-process hazard.
    ///
    /// Every AX window-*mutation* on a self-owned element — setting a coordinator
    /// attribute (`kAXPosition` / `kAXSize` / `kAXMinimized`) or performing a coordinator
    /// action (raise / focus) — short-circuits to AppKit's in-process accessibility entry
    /// point (`NSAccessibilityEntryPointSetValueForAttribute`) and drives the mutation
    /// (`_setFrameCommon` / `_minimizeToDock` / `clearDisplayAffinityForWindow:`)
    /// **synchronously on the calling thread**. Off the main thread — e.g. the Swift
    /// Testing "REAL SYSTEM" suite, which runs on a background cooperative thread and can
    /// pick up the DeskJig test host's own windows — that trips
    /// `-[NSWMWindowCoordinator performTransactionUsingBlock:]` and crashes the host with
    /// `EXC_BREAKPOINT` (issue #618). The crash is not specific to minimize: it migrated
    /// from `minimizeResult` to `moveResult` once minimize alone was guarded.
    ///
    /// DeskJig only ever manages *other* apps' windows, so no legitimate caller mutates a
    /// self-owned window through this service (verified across the restoration / directory
    /// / BSP paths — all target foreign windows). Routing every element-based mutation
    /// through this one refusal keeps production behavior unchanged for foreign windows
    /// while ensuring the crash cannot migrate to the next setter that gets added.
    ///
    /// Returns the refusal error when `element` is self-owned (and logs it), else `nil`.
    private func selfProcessRefusal(_ element: AXUIElement, operation: String) -> AXOperationError? {
        guard isCurrentProcessElement(element) else { return nil }
        DeskJigLog.info(
            .restorationPositioning,
            "Refusing AX '\(operation)' on a window owned by the current process (self-process window mutation is unsupported; see #618)"
        )
        return .selfProcessWindow(operation: operation)
    }

    // MARK: - Process Discovery

    /// Get process ID for a bundle identifier from running applications
    public func getProcessID(for bundleIdentifier: String) -> pid_t? {
        return NSWorkspace.shared.runningApplications
            .first { $0.bundleIdentifier == bundleIdentifier }?
            .processIdentifier
    }

    public func getProcessIDs(for bundleIdentifier: String) -> [pid_t] {
        let pids = NSWorkspace.shared.runningApplications
            .filter { $0.bundleIdentifier == bundleIdentifier }
            .map { $0.processIdentifier }
        return Array(Set(pids)).sorted()
    }

    /// Get process ID for any of the given bundle identifiers (for apps with multiple bundle IDs like Chrome)
    public func getProcessID(forAnyOf bundleIdentifiers: [String]) -> pid_t? {
        return NSWorkspace.shared.runningApplications
            .first { bundleIdentifiers.contains($0.bundleIdentifier ?? "") }?
            .processIdentifier
    }

    // MARK: - App Element Operations

    /// Creates and validates an AXUIElement for the given process
    public func createAppElement(for processID: pid_t) -> AXUIElement? {
        let appElement = AXUIElementCreateApplication(processID)

        guard validateAppElement(appElement, for: processID) else {
            DeskJigLog.info(.restorationPositioning, "Application \(processID) is not accessible via Accessibility API")
            return nil
        }

        return appElement
    }

    /// Validates that an app AXUIElement is accessible
    public func validateAppElement(_ element: AXUIElement, for processID: pid_t) -> Bool {
        // Test if we can get basic attributes from the element
        var roleRef: CFTypeRef?
        let roleResult = AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleRef)

        if roleResult != .success {
            DeskJigLog.info(.restorationPositioning, "Cannot access role attribute for PID \(processID), error: \(roleResult)")
            return false
        }

        // Test if we can get the window list (this is what we actually need)
        var windowsRef: CFTypeRef?
        let windowsResult = AXUIElementCopyAttributeValue(element, kAXWindowsAttribute as CFString, &windowsRef)

        if windowsResult == .cannotComplete {
            DeskJigLog.info(.restorationPositioning, "Application \(processID) returned kAXErrorCannotComplete for windows attribute")
            return false
        } else if windowsResult != .success {
            DeskJigLog.info(.restorationPositioning, "Cannot access windows attribute for PID \(processID), error: \(windowsResult)")
            return false
        }

        return true
    }

    /// Hide an application using AX API
    public func hideApp(_ appElement: AXUIElement) -> Bool {
        var pid: pid_t = 0
        AXUIElementGetPid(appElement, &pid)
        let app = NSWorkspace.shared.runningApplications.first(where: { $0.processIdentifier == pid })
        let appName = app?.localizedName ?? "unknown"
        let bundleId = app?.bundleIdentifier ?? "unknown"

        let hiddenValue: CFTypeRef = kCFBooleanTrue
        let hiddenResult = AXUIElementSetAttributeValue(appElement, kAXHiddenAttribute as CFString, hiddenValue)
        if hiddenResult == .success {
            DeskJigLog.trace(.restorationPositioning, "Successfully hid application name='\(appName)' bundle='\(bundleId)' pid=\(pid)")
            return true
        } else {
            DeskJigLog.error(.restorationPositioning, "Failed to hide application name='\(appName)' bundle='\(bundleId)' pid=\(pid) error=\(hiddenResult)")
        }
        return false
    }

    // MARK: - Window Discovery

    /// Get all windows for a process directly from Accessibility API.
    /// Returns fresh data every time - no caching issues.
    public func getWindows(forProcessID processID: pid_t, bundleIdentifier: String? = nil) -> [AXWindow] {
        let axApp = AXUIElementCreateApplication(processID)
        let elements = getWindowElements(from: axApp)

        var hiddenRef: CFTypeRef?
        AXUIElementCopyAttributeValue(axApp, kAXHiddenAttribute as CFString, &hiddenRef)
        let isHidden = (hiddenRef as? Bool) ?? false

        // Debug logging when AX returns no window elements
        if elements.isEmpty {
            DeskJigLog.debug(.window, "🔍 [HandleDebug] PID \(processID) bundleId=\(bundleIdentifier ?? "nil") - AXUIElementCopyAttributeValue returned 0 window elements")
        }

        var result: [AXWindow] = []
        for axWindow in elements {
            if let window = createWindow(from: axWindow, processID: processID, bundleIdentifier: bundleIdentifier, isHidden: isHidden) {
                result.append(window)
            }
        }

        // Debug logging when createWindow filters out all windows
        if !elements.isEmpty && result.isEmpty {
            DeskJigLog.debug(.window, "🔍 [HandleDebug] PID \(processID) bundleId=\(bundleIdentifier ?? "nil") - All \(elements.count) AX window(s) filtered out by createWindow (likely small windows <=64px)")
        }

        // DeskJigLog.debug(.window, "🔧 AX: Found \(result.count) window(s) for process \(processID)")
        return result
    }

    /// Get all window AXUIElements from an app element
    public func getWindowElements(from appElement: AXUIElement) -> [AXUIElement] {
        var windowsRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowsRef) == .success,
           let windows = windowsRef as? [AXUIElement],
           !windows.isEmpty {
            return windows
        }

        // Fallback: some apps only expose a focused/main window when hidden or inactive.
        var focusedRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, &focusedRef) == .success,
           let focusedWindow = axElement(from: focusedRef) {
            DeskJigLog.debug(.restorationPositioning, "Fallback to focused window for app element")
            return [focusedWindow]
        }

        var mainRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(appElement, kAXMainWindowAttribute as CFString, &mainRef) == .success,
           let mainWindow = axElement(from: mainRef) {
            DeskJigLog.debug(.restorationPositioning, "Fallback to main window for app element")
            return [mainWindow]
        }

        DeskJigLog.warn(.restorationPositioning, "Failed to get windows from app element")
        return []
    }

    /// Find a window element matching a frame and optional title
    public func findWindowElement(in appElement: AXUIElement, matchingFrame targetFrame: CGRect, title: String? = nil) -> AXUIElement? {
        let windows = getWindowElements(from: appElement)

        // Find all windows matching by frame
        var matchingWindows: [AXUIElement] = []
        for window in windows {
            if let frame = getFrame(for: window), frameMatches(frame, targetFrame) {
                matchingWindows.append(window)
            }
        }

        // If no matches found, return first window as fallback
        guard !matchingWindows.isEmpty else {
            DeskJigLog.info(.restorationPositioning, "Could not find matching window, trying first window")
            return windows.first
        }

        // If only one match, return it
        if matchingWindows.count == 1 {
            return matchingWindows.first
        }

        // Multiple windows with same frame - try to match by title if available
        if let targetTitle = title, !targetTitle.isEmpty {
            DeskJigLog.info(.restorationPositioning, "Found \(matchingWindows.count) windows with matching frame, attempting title match for '\(targetTitle)'")

            for window in matchingWindows {
                if let windowTitle = getTitle(for: window), windowTitle == targetTitle {
                    DeskJigLog.info(.restorationPositioning, "Found exact title match: '\(windowTitle)'")
                    return window
                }
            }

            DeskJigLog.warn(.restorationPositioning, "No exact title match found among \(matchingWindows.count) windows, using first match")
        }

        // No title match or no title available - return first matching window
        return matchingWindows.first
    }

    /// Check if two frames match within tolerance
    private func frameMatches(_ frame1: CGRect, _ frame2: CGRect, tolerance: CGFloat = 5.0) -> Bool {
        return abs(frame1.origin.x - frame2.origin.x) < tolerance &&
               abs(frame1.origin.y - frame2.origin.y) < tolerance &&
               abs(frame1.size.width - frame2.size.width) < tolerance &&
               abs(frame1.size.height - frame2.size.height) < tolerance
    }

    private func axElement(from reference: CFTypeRef?) -> AXUIElement? {
        guard let reference, CFGetTypeID(reference) == AXUIElementGetTypeID() else {
            return nil
        }

        return unsafeBitCast(reference, to: AXUIElement.self)
    }

    /// Returns an AXValue only when the Accessibility API result has the expected runtime type.
    private func axValue(from reference: CFTypeRef?) -> AXValue? {
        guard let reference, CFGetTypeID(reference) == AXValueGetTypeID() else {
            return nil
        }

        return unsafeBitCast(reference, to: AXValue.self)
    }

    // MARK: - Window Creation

    /// Create an AXWindow from an AXUIElement
    public func createWindow(from axWindow: AXUIElement, processID: pid_t, bundleIdentifier: String? = nil) -> AXWindow? {
        // Get hidden status (check if app is hidden)
        var hiddenRef: CFTypeRef?
        let axApp = AXUIElementCreateApplication(processID)
        AXUIElementCopyAttributeValue(axApp, kAXHiddenAttribute as CFString, &hiddenRef)
        let isHidden = (hiddenRef as? Bool) ?? false

        return createWindow(from: axWindow, processID: processID, bundleIdentifier: bundleIdentifier, isHidden: isHidden)
    }

    /// Create an AXWindow from an AXUIElement with a known app hidden status
    public func createWindow(from axWindow: AXUIElement, processID: pid_t, bundleIdentifier: String? = nil, isHidden: Bool) -> AXWindow? {
        guard let frame = getFrame(for: axWindow) else {
            return nil
        }

        // Filter out small windows (toolbars, popups, etc.)
        if frame.size.width <= 64 || frame.size.height <= 64 {
            return nil
        }

        // Get title
        let title = getTitle(for: axWindow) ?? ""

        // Get minimized status
        var minRef: CFTypeRef?
        AXUIElementCopyAttributeValue(axWindow, kAXMinimizedAttribute as CFString, &minRef)
        let isMinimized = (minRef as? Bool) ?? false

        return AXWindow(
            axElement: axWindow,
            frame: frame,
            title: title,
            isMinimized: isMinimized,
            isHidden: isHidden,
            processID: processID,
            bundleIdentifier: bundleIdentifier
        )
    }

    /// Refresh an AXWindow to get current state (title, frame, etc.)
    public func refresh(_ window: AXWindow) -> AXWindow? {
        return createWindow(from: window.axElement, processID: window.processID, bundleIdentifier: window.bundleIdentifier)
    }

    // MARK: - Window Properties

    /// Get fresh title for an AXWindow directly from AX
    public func getTitle(for window: AXWindow) -> String {
        return getTitle(for: window.axElement) ?? window.title
    }

    /// Get title for an AXUIElement
    public func getTitle(for element: AXUIElement) -> String? {
        var titleRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXTitleAttribute as CFString, &titleRef) == .success,
           let title = titleRef as? String {
            return title
        }
        return nil
    }

    /// Get frame for an AXUIElement
    public func getFrame(for element: AXUIElement) -> CGRect? {
        var posRef: CFTypeRef?, sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &posRef) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeRef) == .success,
              let posValue = axValue(from: posRef),
              let sizeValue = axValue(from: sizeRef) else {
            return nil
        }

        var position = CGPoint.zero, size = CGSize.zero
        guard AXValueGetValue(posValue, .cgPoint, &position),
              AXValueGetValue(sizeValue, .cgSize, &size) else {
            return nil
        }

        return CGRect(origin: position, size: size)
    }

    // MARK: - Raw Window Enumeration (shared AX skeleton)

    /// One AX window element enumerated directly from an app's `kAXWindows`, carrying only
    /// the optional attributes that were requested. Returned in AX order, one entry per
    /// element with no `<=64px` size filtering and no focused/main-window fallback, so call
    /// sites can keep their own matching/filtering logic.
    public struct AXEnumeratedWindow {
        public let element: AXUIElement
        /// Frame from `kAXPosition` + `kAXSize`; nil if either read failed.
        public let frame: CGRect?
        /// Raw `kAXTitle` string (untrimmed); nil when not requested or unavailable.
        public let title: String?
        /// `AXWindowNumber` coerced to `CGWindowID`; nil when not requested or unavailable.
        public let windowNumber: CGWindowID?
        /// `kAXDocument` coerced to a filesystem path (`file://` URLs decoded); nil when not
        /// requested or unavailable.
        public let documentPath: String?
    }

    /// Enumerate an application's AX windows directly via `kAXWindows`, reading only the
    /// requested optional attributes. Consolidates the raw `AXUIElementCreateApplication` ->
    /// `kAXWindows` -> per-window `kAXPosition`/`kAXSize`/`kAXTitle`/`AXWindowNumber`/`kAXDocument`
    /// skeleton that was copy-pasted across the snapshot/supplementation capture paths.
    ///
    /// Returns nil when the `kAXWindows` copy fails (so callers can distinguish "AX failed"
    /// from "zero windows"); returns `[]` when the app exposes no windows. Deliberately does
    /// NOT apply the `<=64px` filter or the focused/main fallback used elsewhere.
    public func enumerateWindows(
        pid: pid_t,
        includeTitle: Bool = false,
        includeWindowNumber: Bool = false,
        includeDocumentPath: Bool = false
    ) -> [AXEnumeratedWindow]? {
        let axApp = AXUIElementCreateApplication(pid)
        var windowsRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &windowsRef) == .success,
              let axWindows = windowsRef as? [AXUIElement] else {
            return nil
        }

        return axWindows.map { axWindow in
            var frame: CGRect? = nil
            var positionRef: CFTypeRef?
            var sizeRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(axWindow, kAXPositionAttribute as CFString, &positionRef) == .success,
               AXUIElementCopyAttributeValue(axWindow, kAXSizeAttribute as CFString, &sizeRef) == .success,
               let positionValue = axValue(from: positionRef),
               let sizeValue = axValue(from: sizeRef) {
                var position = CGPoint.zero
                var size = CGSize.zero
                AXValueGetValue(positionValue, .cgPoint, &position)
                AXValueGetValue(sizeValue, .cgSize, &size)
                frame = CGRect(origin: position, size: size)
            }

            var title: String? = nil
            if includeTitle {
                var titleRef: CFTypeRef?
                AXUIElementCopyAttributeValue(axWindow, kAXTitleAttribute as CFString, &titleRef)
                title = titleRef as? String
            }

            var windowNumber: CGWindowID? = nil
            if includeWindowNumber {
                var windowNumberRef: CFTypeRef?
                if AXUIElementCopyAttributeValue(axWindow, "AXWindowNumber" as CFString, &windowNumberRef) == .success {
                    if let number = windowNumberRef as? NSNumber {
                        windowNumber = CGWindowID(number.uint32Value)
                    } else if let intValue = windowNumberRef as? Int {
                        windowNumber = CGWindowID(UInt32(intValue))
                    }
                }
            }

            var documentPath: String? = nil
            if includeDocumentPath {
                var docRef: CFTypeRef?
                if AXUIElementCopyAttributeValue(axWindow, kAXDocumentAttribute as CFString, &docRef) == .success,
                   let docString = docRef as? String {
                    documentPath = docString.hasPrefix("file://")
                        ? URL(string: docString)?.path
                        : docString
                }
            }

            return AXEnumeratedWindow(
                element: axWindow,
                frame: frame,
                title: title,
                windowNumber: windowNumber,
                documentPath: documentPath
            )
        }
    }

    // MARK: - Window Manipulation (AXWindow-based)

    /// Move a window directly using AX API
    public func move(_ window: AXWindow, to frame: CGRect) -> Bool {
        let success = move(window.axElement, to: frame)


        if success {
            DeskJigLog.info(.restorationPositioning, "Moved window '\(window.title)' to \(frame)")
        } else {
            DeskJigLog.error(.restorationPositioning, "Failed to move window '\(window.title)'")
        }
        return success
    }

    /// Unminimize (restore) a window using AX API
    public func restore(_ window: AXWindow) -> Bool {
        let success = restore(window.axElement)
        if success {
            DeskJigLog.info(.restorationPositioning, "Restored (unminimized) window '\(window.title)'")
        } else {
            DeskJigLog.error(.restorationPositioning, "Failed to restore window '\(window.title)'")
        }
        return success
    }

    /// Activate (bring to front / unhide) a window using AX API
    public func activate(_ window: AXWindow) -> Bool {
        return activate(window.axElement, processID: window.processID)
    }

    /// Minimize a window using AX API
    public func minimize(_ window: AXWindow) -> Bool {
        let success = minimize(window.axElement)
        if success {
            DeskJigLog.info(.restorationPositioning, "Minimized window '\(window.title)'")
        } else {
            DeskJigLog.error(.restorationPositioning, "Failed to minimize window '\(window.title)'")
        }
        return success
    }

    /// Close a window using AX API
    public func close(_ window: AXWindow) -> Bool {
        let success = close(window.axElement)
        if success {
            DeskJigLog.info(.restorationPositioning, "Closed window '\(window.title)'")
        } else {
            DeskJigLog.error(.restorationPositioning, "Failed to close window '\(window.title)'")
        }
        return success
    }

    /// Raise a window to front using AX API
    public func raise(_ window: AXWindow) -> Bool {
        let success = raise(window.axElement)


        if success {
            DeskJigLog.debug(.restorationPositioning, "Raised window '\(window.title)'")
        } else {
            DeskJigLog.error(.restorationPositioning, "Failed to raise window '\(window.title)'")
        }
        return success
    }

    // MARK: - Window Manipulation (AXUIElement-based)

    public func moveResult(_ element: AXUIElement, to frame: CGRect) -> Result<Void, AXOperationError> {
        // #618: Setting kAXPosition / kAXSize on a self-owned window drives AppKit's
        // _setFrameCommon → clearDisplayAffinityForWindow: transaction on the calling
        // thread and trips the same NSWMWindowCoordinator assertion off the main thread
        // (this is where the crash migrated to after minimize alone was guarded).
        if let refusal = selfProcessRefusal(element, operation: "move") {
            return .failure(refusal)
        }

        return withEnhancedUIDisabled(for: element) {
            var newPosition = frame.origin
            var newSize = frame.size

            guard let posValue = AXValueCreate(.cgPoint, &newPosition) else {
                return .failure(.valueCreationFailed(attribute: kAXPositionAttribute as String))
            }
            guard let sizeValue = AXValueCreate(.cgSize, &newSize) else {
                return .failure(.valueCreationFailed(attribute: kAXSizeAttribute as String))
            }

            let posResult = AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, posValue)
            guard posResult == .success else {
                return .failure(.axFailure(operation: "setPosition", status: posResult))
            }

            let sizeResult = AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, sizeValue)
            guard sizeResult == .success else {
                return .failure(.axFailure(operation: "setSize", status: sizeResult))
            }

            return .success(())
        }
    }

    /// Move an AXUIElement window to a frame
    public func move(_ element: AXUIElement, to frame: CGRect) -> Bool {
        switch moveResult(element, to: frame) {
        case .success:
            return true
        case .failure(let error):
            DeskJigLog.error(.restorationPositioning, "Failed to move AX element", fields: ["error": String(describing: error)])
            return false
        }
    }

    /// Restore (unminimize) an AXUIElement window
    public func restore(_ element: AXUIElement) -> Bool {
        // #618: Same window-coordinator hazard as minimize — clearing kAXMinimizedAttribute
        // (deminiaturize) on a self-owned window drives AppKit's transaction on the calling
        // thread and can trip the same assertion off the main thread. DeskJig never restores
        // its own windows via AX, so refuse it at the shared chokepoint.
        if selfProcessRefusal(element, operation: "unminimize") != nil {
            return false
        }

        let minimizedValue: CFTypeRef = kCFBooleanFalse
        let result = AXUIElementSetAttributeValue(element, kAXMinimizedAttribute as CFString, minimizedValue)

        if result == .success {
            return true
        }

        // Fallback: try raise action
        let raiseResult = AXUIElementPerformAction(element, kAXRaiseAction as CFString)
        return raiseResult == .success
    }

    public func activateResult(_ element: AXUIElement, processID: pid_t) -> Result<Void, AXOperationError> {
        // #618: Raising / focusing / setting kAXMain on a self-owned window drives an
        // in-process AppKit coordinator transaction on the calling thread — the same
        // hazard class as move/minimize. DeskJig never activates its own windows through
        // this service (it uses AppKit/NSApp for that), so refuse at the chokepoint.
        if let refusal = selfProcessRefusal(element, operation: "activate") {
            return .failure(refusal)
        }

        let raiseResult = AXUIElementPerformAction(element, kAXRaiseAction as CFString)
        guard raiseResult == .success else {
            return .failure(.axFailure(operation: "raise", status: raiseResult))
        }

        let appElement = AXUIElementCreateApplication(processID)
        let focusResult = AXUIElementSetAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, element)
        guard focusResult == .success else {
            return .failure(.axFailure(operation: "focusWindow", status: focusResult))
        }

        let mainResult = AXUIElementSetAttributeValue(element, kAXMainAttribute as CFString, kCFBooleanTrue)
        guard mainResult == .success else {
            return .failure(.axFailure(operation: "setMain", status: mainResult))
        }

        let focusedResult = AXUIElementSetAttributeValue(element, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        guard focusedResult == .success else {
            return .failure(.axFailure(operation: "setFocused", status: focusedResult))
        }

        guard let app = NSWorkspace.shared.runningApplications.first(where: { $0.processIdentifier == processID }) else {
            return .failure(.appNotFound(processID: processID))
        }

        if #available(macOS 14.0, *) {
            app.activate()
        } else {
            app.activate(options: [.activateIgnoringOtherApps])
        }

        return .success(())
    }

    /// Activate an AXUIElement window
    public func activate(_ element: AXUIElement, processID: pid_t) -> Bool {
        switch activateResult(element, processID: processID) {
        case .success:
            let windowTitle = getTitle(for: element) ?? "unknown"
            let appName = NSWorkspace.shared.runningApplications.first(where: { $0.processIdentifier == processID })?.localizedName ?? "unknown"
            DeskJigLog.info(.restorationPositioning, "Activated '\(windowTitle)' in \(appName)")
            return true
        case .failure(let error):
            DeskJigLog.error(.restorationPositioning, "Failed to activate AX element", fields: ["processID": "\(processID)", "error": String(describing: error)])
            return false
        }
    }

    public func minimizeResult(_ element: AXUIElement) -> Result<Void, AXOperationError> {
        // #618: Setting kAXMinimizedAttribute on a self-owned window drives AppKit's
        // _minimizeToDock synchronously on the calling thread; off the main thread that
        // trips an NSWMWindowCoordinator assertion and crashes the host (EXC_BREAKPOINT).
        // DeskJig only manages other apps' windows, so refuse at the shared chokepoint.
        if let refusal = selfProcessRefusal(element, operation: "minimize") {
            return .failure(refusal)
        }

        let minimizedValue: CFTypeRef = kCFBooleanTrue
        let minimizedResult = AXUIElementSetAttributeValue(element, kAXMinimizedAttribute as CFString, minimizedValue)
        if minimizedResult == .success {
            return .success(())
        }

        var minimizeButtonRef: CFTypeRef?
        let minimizeButtonResult = AXUIElementCopyAttributeValue(element, kAXMinimizeButtonAttribute as CFString, &minimizeButtonRef)
        guard minimizeButtonResult == .success else {
            return .failure(.axFailure(operation: "getMinimizeButton", status: minimizeButtonResult))
        }
        guard let minimizeButton = axElement(from: minimizeButtonRef) else {
            return .failure(.axFailure(operation: "getMinimizeButtonType", status: .illegalArgument))
        }

        let pressResult = AXUIElementPerformAction(minimizeButton, kAXPressAction as CFString)
        guard pressResult == .success else {
            return .failure(.axFailure(operation: "pressMinimize", status: pressResult))
        }

        return .success(())
    }

    /// Minimize an AXUIElement window
    public func minimize(_ element: AXUIElement) -> Bool {
        switch minimizeResult(element) {
        case .success:
            return true
        case .failure(let error):
            DeskJigLog.error(.restorationPositioning, "Failed to minimize AX element", fields: ["error": String(describing: error)])
            return false
        }
    }

    public func closeResult(_ element: AXUIElement) -> Result<Void, AXOperationError> {
        // #618: Closing a self-owned window (pressing kAXCloseButton / kAXCancelAction)
        // drives an in-process AppKit window-coordinator transaction on the calling
        // thread — same hazard class. DeskJig never closes its own windows via AX, so
        // refuse at the chokepoint so the crash cannot migrate here.
        if let refusal = selfProcessRefusal(element, operation: "close") {
            return .failure(refusal)
        }

        var closeButtonRef: CFTypeRef?
        let closeButtonResult = AXUIElementCopyAttributeValue(element, kAXCloseButtonAttribute as CFString, &closeButtonRef)
        if closeButtonResult == .success, let closeButton = axElement(from: closeButtonRef) {
            let pressResult = AXUIElementPerformAction(closeButton, kAXPressAction as CFString)
            if pressResult == .success {
                return .success(())
            }
            return .failure(.axFailure(operation: "pressClose", status: pressResult))
        }

        let cancelResult = AXUIElementPerformAction(element, kAXCancelAction as CFString)
        guard cancelResult == .success else {
            return .failure(.axFailure(operation: "cancel", status: cancelResult))
        }

        return .success(())
    }

    /// Close an AXUIElement window
    public func close(_ element: AXUIElement) -> Bool {
        switch closeResult(element) {
        case .success:
            return true
        case .failure(let error):
            DeskJigLog.error(.restorationPositioning, "Failed to close AX element", fields: ["error": String(describing: error)])
            return false
        }
    }

    public func raiseResult(_ element: AXUIElement) -> Result<Void, AXOperationError> {
        // #618: Raising a self-owned window drives an in-process AppKit coordinator
        // transaction (window ordering) on the calling thread — same hazard class as
        // move/minimize. DeskJig never raises its own windows via AX, so refuse here.
        if let refusal = selfProcessRefusal(element, operation: "raise") {
            return .failure(refusal)
        }

        return withEnhancedUIDisabled(for: element) {
            let raiseResult = AXUIElementPerformAction(element, kAXRaiseAction as CFString)
            guard raiseResult == .success else {
                return .failure(.axFailure(operation: "raise", status: raiseResult))
            }

            return .success(())
        }
    }

    /// Raise an AXUIElement window to front
    public func raise(_ element: AXUIElement) -> Bool {
        switch raiseResult(element) {
        case .success:
            return true
        case .failure(let error):
            DeskJigLog.error(.restorationPositioning, "Failed to raise AX element", fields: ["error": String(describing: error)])
            return false
        }
    }
}
