//  AppLauncher.swift
//  DeskJigShared

import Foundation
import CoreGraphics

// MARK: - LaunchedWindow

/// Result of successfully launching and positioning a window
public struct LaunchedWindow: Sendable {
    /// The window handle for the launched window
    public let windowHandle: WindowHandle
    
    /// The process ID of the launched app
    public let processID: pid_t
    
    /// The directory path the window was opened with
    public let directoryPath: String
    
    public init(
        windowHandle: WindowHandle,
        processID: pid_t,
        directoryPath: String
    ) {
        self.windowHandle = windowHandle
        self.processID = processID
        self.directoryPath = directoryPath
    }
}

// MARK: - AppLauncher

/// Protocol for app-specific launch behavior
public protocol AppLauncher: Sendable {
    /// The bundle identifier for this app
    var bundleIdentifier: String { get }

    /// The human-readable name of the app
    var appName: String { get }

    /// Launch the app with the given window specification
    /// - Parameter spec: Window configuration including directory, position, screen
    /// - Returns: The launched window with handle and metadata
    /// - Throws: LauncherError if launch fails
    func launch(spec: WindowSpec) async throws -> LaunchedWindow

    /// Find an existing window that is open to the given directory
    /// - Parameter path: The directory path to search for
    /// - Returns: The window handle if found, nil otherwise
    func findByDirectory(_ path: String) async -> WindowHandle?

    /// Find all windows that match the given directory with confidence scoring
    /// - Parameter path: The directory path to search for
    /// - Returns: A result containing all matches sorted by confidence
    func findWindowsMatching(directory path: String) async -> WindowMatchResult
}

// MARK: - WindowMatch (Multi-Strategy Matching)

/// Confidence level for window matching
public enum MatchConfidence: String, Codable, Sendable, Comparable {
    case high = "high"       // AX document path matches exactly
    case medium = "medium"   // Title pattern matches folder name
    case low = "low"         // Title contains folder name (ambiguous)

    public static func < (lhs: MatchConfidence, rhs: MatchConfidence) -> Bool {
        let order: [MatchConfidence] = [.low, .medium, .high]
        return order.firstIndex(of: lhs)! < order.firstIndex(of: rhs)!
    }
}

/// Method used to match a window to a directory
public enum DirectoryMatchMethod: String, Codable, Sendable {
    case stateFile = "stateFile"           // Cursor's internal storage.json (most reliable)
    case documentPath = "documentPath"     // AX kAXDocumentAttribute
    case documentPathPrefix = "documentPathPrefix"  // Document path is inside target directory
    case titleExact = "titleExact"         // Title contains " — foldername" pattern
    case titleContains = "titleContains"   // Title contains folder name somewhere
}

/// Result of matching a window to a directory
public struct WindowMatch: Sendable {
    /// The matched window
    public let window: WindowHandle

    /// Confidence level of the match
    public let confidence: MatchConfidence

    /// Method used to find this match
    public let matchedBy: DirectoryMatchMethod

    /// Additional details about the match (e.g., what part of title matched)
    public let details: String?

    public init(
        window: WindowHandle,
        confidence: MatchConfidence,
        matchedBy: DirectoryMatchMethod,
        details: String? = nil
    ) {
        self.window = window
        self.confidence = confidence
        self.matchedBy = matchedBy
        self.details = details
    }
}

/// Result of searching for windows matching a directory
public struct WindowMatchResult: Sendable {
    /// All matches found, sorted by confidence (highest first)
    public let matches: [WindowMatch]

    /// The best match (highest confidence), if any
    public var bestMatch: WindowMatch? { matches.first }

    /// Whether there are multiple matches at the same confidence level
    public var isAmbiguous: Bool {
        guard matches.count > 1 else { return false }
        return matches[0].confidence == matches[1].confidence
    }

    /// Number of matches found
    public var count: Int { matches.count }

    public init(matches: [WindowMatch]) {
        // Sort by confidence descending
        self.matches = matches.sorted { $0.confidence > $1.confidence }
    }

    public static let empty = WindowMatchResult(matches: [])
}

/// Serializable info about a window match (for error reporting)
public struct WindowMatchInfo: Codable, Sendable {
    public let title: String?
    public let confidence: String
    public let matchedBy: String
    public let pid: Int32

    public init(from match: WindowMatch) {
        self.title = match.window.title
        self.confidence = match.confidence.rawValue
        self.matchedBy = match.matchedBy.rawValue
        self.pid = match.window.processID ?? 0
    }
}

// MARK: - LauncherError

/// Errors that can occur during app launching
public enum LauncherError: Error, LocalizedError, Sendable {
    case appNotFound(bundleID: String)
    case directoryNotFound(path: String)
    case invalidPosition(String)
    case launchFailed(reason: String)
    case windowNotFound(reason: String)
    case positioningFailed(reason: String)
    case timeout(operation: String)
    case ambiguousMatch(matches: [WindowMatchInfo])
    
    public var errorDescription: String? {
        switch self {
        case .appNotFound(let bundleID):
            return "App not found: \(bundleID)"
        case .directoryNotFound(let path):
            return "Directory not found: \(path)"
        case .invalidPosition(let position):
            return "Invalid position: \(position)"
        case .launchFailed(let reason):
            return "Failed to launch app: \(reason)"
        case .windowNotFound(let reason):
            return "Window not found: \(reason)"
        case .positioningFailed(let reason):
            return "Failed to position window: \(reason)"
        case .timeout(let operation):
            return "Operation timed out: \(operation)"
        case .ambiguousMatch(let matches):
            let titles = matches.map { $0.title ?? "untitled" }.joined(separator: ", ")
            return "Multiple windows match (\(matches.count) found): \(titles). Use --new to force a new window or specify a unique identifier."
        }
    }
}
