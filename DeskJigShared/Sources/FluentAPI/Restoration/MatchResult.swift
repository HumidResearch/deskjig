//  MatchResult.swift
//  DeskJigShared

import Foundation
import CoreGraphics

// MARK: - Window Match Method

/// Describes how a workspace window was matched to a system window.
///
/// The match method determines the lock priority for restoration:
/// - Path-based matches (`.documentPath`, `.workingDirectory`) get high priority
/// - Profile-based matches (`.chromeProfile`) get high priority
/// - Title matches get medium priority
/// - Frame matches get low priority
///
/// ## Overview
///
/// When restoring a workspace, each saved window configuration needs to be
/// matched to an existing window (if any). The match method tracks which
/// strategy succeeded, enabling appropriate conflict resolution.
///
/// ## Example
///
/// ```swift
/// switch matchResult.method {
/// case .documentPath(let path):
///     print("Matched by document path: \(path)")
/// case .workingDirectory(let dir):
///     print("Matched by working directory: \(dir)")
/// case .chromeProfile(let profile):
///     print("Matched by Chrome profile: \(profile)")
/// case .titleExact:
///     print("Matched by exact title")
/// case .noMatch:
///     print("No existing window found")
/// }
/// ```
///
/// ## See Also
/// - ``WindowMatchResult``
/// - ``LockPriority``
public enum WindowMatchMethod: Sendable, CustomStringConvertible {
    /// Matched by AX document path (IDE, editor files)
    case documentPath(String)

    /// Matched by parsed working directory from terminal title
    case workingDirectory(String)

    /// Matched by the legacy terminal title pattern (bento:dir:index)
    case bentoTitle(String)

    /// Matched by Chrome profile directory
    case chromeProfile(String)

    /// Matched by exact window title
    case titleExact

    /// Matched by partial window title (contains)
    case titleContains(String)

    /// Matched by frame position within tolerance
    case frameWithTolerance(tolerance: CGFloat)

    /// Matched by bundle ID only (weakest match for multi-window apps)
    case bundleIdOnly

    /// No match found - window needs to be created
    case noMatch

    /// The suggested lock priority for this match method.
    public var suggestedPriority: LockPriority {
        switch self {
        case .documentPath, .workingDirectory, .bentoTitle, .chromeProfile:
            return .high
        case .titleExact:
            return .medium
        case .titleContains:
            return .medium
        case .frameWithTolerance:
            return .low
        case .bundleIdOnly:
            return .low
        case .noMatch:
            return .low
        }
    }

    public var description: String {
        switch self {
        case .documentPath(let path):
            return "documentPath(\(path))"
        case .workingDirectory(let dir):
            return "workingDirectory(\(dir))"
        case .bentoTitle(let title):
            return "bentoTitle(\(title))"
        case .chromeProfile(let profile):
            return "chromeProfile(\(profile))"
        case .titleExact:
            return "titleExact"
        case .titleContains(let text):
            return "titleContains(\(text))"
        case .frameWithTolerance(let tolerance):
            return "frameWithTolerance(\(Int(tolerance))px)"
        case .bundleIdOnly:
            return "bundleIdOnly"
        case .noMatch:
            return "noMatch"
        }
    }

    /// Whether this is a strong match (path or profile based).
    public var isStrongMatch: Bool {
        switch self {
        case .documentPath, .workingDirectory, .bentoTitle, .chromeProfile:
            return true
        default:
            return false
        }
    }

    /// Whether any match was found.
    public var hasMatch: Bool {
        if case .noMatch = self { return false }
        return true
    }
}

// MARK: - Match Result

/// Result of matching a workspace window to a system window.
///
/// Contains the matched window (if any), confidence score, and metadata
/// about how the match was made.
///
/// ## Overview
///
/// During restoration analysis, each workspace window is matched against
/// the current system snapshot. The `MatchResult` captures:
/// - The matched system window (or nil if none found)
/// - A confidence score (0.0 to 1.0)
/// - The method used to make the match
/// - Suggested lock priority based on match quality
///
/// ## Example
///
/// ```swift
/// let result = snapshot.findMatch(for: workspaceWindow, excluding: claimedWindows)
///
/// if let window = result.window {
///     print("Found match with \(result.confidence * 100)% confidence")
///     print("Method: \(result.method)")
///     print("Priority: \(result.suggestedPriority)")
/// } else {
///     print("No match found - will create new window")
/// }
/// ```
///
/// ## See Also
/// - ``WindowMatchMethod``
/// - ``EnhancedSnapshot``
public struct MatchResult: Sendable {
    /// The matched system window, or nil if no match found.
    public let window: SnapshotWindow?

    /// Confidence score from 0.0 (no confidence) to 1.0 (certain match).
    public let confidence: Double

    /// The method used to find this match.
    public let method: WindowMatchMethod

    /// Time taken to perform the match in milliseconds.
    public let searchDurationMs: Int

    /// Creates a new match result.
    ///
    /// - Parameters:
    ///   - window: The matched window, or nil
    ///   - confidence: Match confidence from 0.0 to 1.0
    ///   - method: The window matching method used
    ///   - searchDurationMs: Time taken to search
    public init(
        window: SnapshotWindow?,
        confidence: Double,
        method: WindowMatchMethod,
        searchDurationMs: Int = 0
    ) {
        self.window = window
        self.confidence = min(1.0, max(0.0, confidence))
        self.method = method
        self.searchDurationMs = searchDurationMs
    }

    /// The suggested lock priority based on the match method.
    public var suggestedPriority: LockPriority {
        method.suggestedPriority
    }

    /// Suggested lock priority based on match confidence.
    public var confidencePriority: LockPriority {
        switch confidence {
        case let value where value >= 0.95:
            return .critical
        case let value where value >= 0.8:
            return .high
        case let value where value >= 0.6:
            return .medium
        default:
            return .low
        }
    }

    /// Whether a match was found.
    public var hasMatch: Bool {
        window != nil && method.hasMatch
    }

    /// Whether this is a high-confidence match (> 0.8).
    public var isHighConfidence: Bool {
        confidence > 0.8
    }

    /// Creates a "no match" result.
    public static func noMatch(searchDurationMs: Int = 0) -> MatchResult {
        MatchResult(
            window: nil,
            confidence: 0.0,
            method: .noMatch,
            searchDurationMs: searchDurationMs
        )
    }
}

// MARK: - Match Configuration

/// Configuration options for window matching behavior.
///
/// Controls which matching strategies are used and their parameters.
///
/// ## Example
///
/// ```swift
/// let config = MatchConfiguration(
///     frameTolerance: 15.0,
///     enablePathMatching: true,
///     enableProfileMatching: true,
///     preferPathOverFrame: true
/// )
/// ```
public struct MatchConfiguration: Sendable {
    /// Tolerance in points for frame-based matching
    public let frameTolerance: CGFloat

    /// Whether to attempt path-based matching
    public let enablePathMatching: Bool

    /// Whether to attempt Chrome profile matching
    public let enableProfileMatching: Bool

    /// Whether path matches take priority over frame matches
    public let preferPathOverFrame: Bool

    /// Whether to match minimized windows
    public let includeMinimized: Bool

    /// Default configuration.
    public static let `default` = MatchConfiguration()

    public init(
        frameTolerance: CGFloat = 10.0,
        enablePathMatching: Bool = true,
        enableProfileMatching: Bool = true,
        preferPathOverFrame: Bool = true,
        includeMinimized: Bool = false
    ) {
        self.frameTolerance = frameTolerance
        self.enablePathMatching = enablePathMatching
        self.enableProfileMatching = enableProfileMatching
        self.preferPathOverFrame = preferPathOverFrame
        self.includeMinimized = includeMinimized
    }
}

