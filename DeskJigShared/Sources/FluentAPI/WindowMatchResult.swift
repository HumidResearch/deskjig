//  WindowMatchResult.swift
//  DeskJigShared

import Foundation
import CoreGraphics

/// Result of a window matching operation with full debug metadata.
/// Use this to understand exactly how a window was found.
public struct WindowFinderResult: Sendable {
    /// The matched window handle (nil if no match found)
    public let window: WindowHandle?

    /// The method used to find the window
    public let matchMethod: WindowFinderMethod

    /// The input criteria provided for matching
    public let inputCriteria: WindowFinderCriteria

    /// Time taken to perform the match
    public let matchDuration: TimeInterval

    /// Number of candidate windows checked
    public let candidatesChecked: Int

    /// Human-readable details about the match (e.g., "Matched by frame within 3px tolerance")
    public let matchDetails: String?

    /// Whether the match was successful
    public var isSuccess: Bool { window != nil }

    public init(
        window: WindowHandle?,
        matchMethod: WindowFinderMethod,
        inputCriteria: WindowFinderCriteria,
        matchDuration: TimeInterval,
        candidatesChecked: Int,
        matchDetails: String?
    ) {
        self.window = window
        self.matchMethod = matchMethod
        self.inputCriteria = inputCriteria
        self.matchDuration = matchDuration
        self.candidatesChecked = candidatesChecked
        self.matchDetails = matchDetails
    }

    /// Create a failed result
    public static func notFound(
        method: WindowFinderMethod,
        criteria: WindowFinderCriteria,
        duration: TimeInterval,
        candidatesChecked: Int,
        reason: String
    ) -> WindowFinderResult {
        WindowFinderResult(
            window: nil,
            matchMethod: method,
            inputCriteria: criteria,
            matchDuration: duration,
            candidatesChecked: candidatesChecked,
            matchDetails: reason
        )
    }
}

/// The method used to find a window.
/// Each method represents a single lookup strategy with no hidden fallbacks.
public enum WindowFinderMethod: String, Sendable, CaseIterable {
    // Single identifier methods
    case windowId = "CGWindowID"
    case processId = "PID"
    case bundleId = "Bundle ID"
    case appName = "App Name"

    // Combined identifier methods
    case processIdAndTitle = "PID + Title"
    case processIdAndFrame = "PID + Frame"
    case processIdTitleAndFrame = "PID + Title + Frame"

    // Single attribute methods
    case frameOnly = "Frame"
    case titleExact = "Exact Title"
    case titleContaining = "Title Contains"

    // Position-based methods
    case zOrder = "Z-Order"
    case screenLocation = "Screen Location"

    /// Human-readable description of the method
    public var description: String {
        switch self {
        case .windowId:
            return "Match by CGWindowID (most precise)"
        case .processId:
            return "Match first window for process ID"
        case .bundleId:
            return "Match by bundle identifier"
        case .appName:
            return "Match by application display name"
        case .processIdAndTitle:
            return "Match by PID + exact window title"
        case .processIdAndFrame:
            return "Match by PID + frame position"
        case .processIdTitleAndFrame:
            return "Match by PID + title + frame (most restrictive)"
        case .frameOnly:
            return "Match by frame position only"
        case .titleExact:
            return "Match by exact window title"
        case .titleContaining:
            return "Match by title substring"
        case .zOrder:
            return "Match topmost visible window"
        case .screenLocation:
            return "Match window at screen point"
        }
    }

    /// Warning message for potentially dangerous methods
    public var warningMessage: String? {
        switch self {
        case .appName:
            return "Warning: May match wrong window for multi-window apps like Chrome"
        case .bundleId:
            return "Warning: May match wrong window for multi-window apps"
        case .processId:
            return "Warning: Returns first window only; may not be the expected one"
        case .frameOnly:
            return "Warning: Frame positions can overlap between windows"
        case .titleContaining:
            return "Warning: May match multiple windows with similar titles"
        default:
            return nil
        }
    }

    /// Precision level (higher = more precise)
    public var precisionLevel: Int {
        switch self {
        case .processIdTitleAndFrame: return 10
        case .windowId: return 9
        case .processIdAndFrame: return 8
        case .processIdAndTitle: return 7
        case .frameOnly: return 6
        case .titleExact: return 5
        case .zOrder: return 4
        case .screenLocation: return 3
        case .bundleId: return 2
        case .appName: return 1
        case .titleContaining: return 1
        case .processId: return 1
        }
    }
}

/// Input criteria provided for a window matching operation.
/// Contains all parameters that were used to search for a window.
public struct WindowFinderCriteria: Sendable {
    public var windowId: CGWindowID?
    public var processId: pid_t?
    public var title: String?
    public var frame: CGRect?
    public var frameTolerance: CGFloat?
    public var bundleId: String?
    public var appName: String?
    public var screenLocation: CGPoint?

    public init(
        windowId: CGWindowID? = nil,
        processId: pid_t? = nil,
        title: String? = nil,
        frame: CGRect? = nil,
        frameTolerance: CGFloat? = nil,
        bundleId: String? = nil,
        appName: String? = nil,
        screenLocation: CGPoint? = nil
    ) {
        self.windowId = windowId
        self.processId = processId
        self.title = title
        self.frame = frame
        self.frameTolerance = frameTolerance
        self.bundleId = bundleId
        self.appName = appName
        self.screenLocation = screenLocation
    }

    /// Human-readable summary of the criteria
    public var summary: String {
        var parts: [String] = []

        if let windowId = windowId {
            parts.append("windowId=\(windowId)")
        }
        if let processId = processId {
            parts.append("pid=\(processId)")
        }
        if let title = title {
            parts.append("title=\"\(title)\"")
        }
        if let frame = frame {
            parts.append("frame=(\(Int(frame.origin.x)),\(Int(frame.origin.y)),\(Int(frame.width)),\(Int(frame.height)))")
            if let tolerance = frameTolerance {
                parts.append("tolerance=\(Int(tolerance))px")
            }
        }
        if let bundleId = bundleId {
            parts.append("bundleId=\"\(bundleId)\"")
        }
        if let appName = appName {
            parts.append("appName=\"\(appName)\"")
        }
        if let screenLocation = screenLocation {
            parts.append("location=(\(Int(screenLocation.x)),\(Int(screenLocation.y)))")
        }

        return parts.isEmpty ? "(no criteria)" : parts.joined(separator: ", ")
    }
}

// MARK: - AX Matching Strategy

/// Strategy for correlating CGWindowID to AXUIElement.
///
/// There is NO direct macOS API to convert CGWindowID to AXUIElement.
/// This enum controls which matching approach is used when `Window.find(windowId:)`
/// needs to find the corresponding AX window.
public enum AXMatchingStrategy: String, Sendable, CaseIterable, Identifiable {
    /// Match by frame position (default, most reliable for static windows)
    case frameOnly = "Frame Only"

    /// Match by exact window title
    case titleOnly = "Title Only"

    /// Match by both frame AND title (most precise, may fail more often)
    case frameAndTitle = "Frame + Title"

    /// Take the first window for the PID (risky for multi-window apps)
    case pidFirstWindow = "PID (First Window)"

    public var id: String { rawValue }

    /// Human-readable description
    public var description: String {
        switch self {
        case .frameOnly:
            return "Match AX window by frame position (5px tolerance)"
        case .titleOnly:
            return "Match AX window by exact title"
        case .frameAndTitle:
            return "Require both frame AND title match (strictest)"
        case .pidFirstWindow:
            return "Take first AX window for process (may be wrong window)"
        }
    }

    /// Warning message for potentially unreliable strategies
    public var warningMessage: String? {
        switch self {
        case .frameOnly:
            return nil // Most reliable
        case .titleOnly:
            return "May fail if CGWindowList and AX report different titles"
        case .frameAndTitle:
            return "May fail if either frame or title doesn't match exactly"
        case .pidFirstWindow:
            return "Dangerous for multi-window apps - may match wrong window"
        }
    }

    /// Reliability level (higher = more likely to find a match)
    public var reliabilityLevel: Int {
        switch self {
        case .frameOnly: return 4
        case .titleOnly: return 3
        case .frameAndTitle: return 2
        case .pidFirstWindow: return 1
        }
    }
}

// MARK: - Info-Only Result (CGWindowList without AX)

/// Result of a window info lookup (CGWindowList only, no AX manipulation capability)
public struct WindowInfoFinderResult: Sendable {
    /// The window info from CGWindowList (nil if not found)
    public let window: SnapshotWindow?

    /// The method used to find the window
    public let matchMethod: WindowFinderMethod

    /// The input criteria provided for matching
    public let inputCriteria: WindowFinderCriteria

    /// Time taken to perform the lookup
    public let matchDuration: TimeInterval

    /// Number of candidate windows checked
    public let candidatesChecked: Int

    /// Human-readable details about the match
    public let matchDetails: String?

    /// Whether the lookup was successful
    public var isSuccess: Bool { window != nil }

    public init(
        window: SnapshotWindow?,
        matchMethod: WindowFinderMethod,
        inputCriteria: WindowFinderCriteria,
        matchDuration: TimeInterval,
        candidatesChecked: Int,
        matchDetails: String?
    ) {
        self.window = window
        self.matchMethod = matchMethod
        self.inputCriteria = inputCriteria
        self.matchDuration = matchDuration
        self.candidatesChecked = candidatesChecked
        self.matchDetails = matchDetails
    }

    /// Create a failed result
    public static func notFound(
        method: WindowFinderMethod,
        criteria: WindowFinderCriteria,
        duration: TimeInterval,
        candidatesChecked: Int,
        reason: String
    ) -> WindowInfoFinderResult {
        WindowInfoFinderResult(
            window: nil,
            matchMethod: method,
            inputCriteria: criteria,
            matchDuration: duration,
            candidatesChecked: candidatesChecked,
            matchDetails: reason
        )
    }
}
