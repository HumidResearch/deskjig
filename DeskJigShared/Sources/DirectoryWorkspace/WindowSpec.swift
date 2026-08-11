//  WindowSpec.swift
//  DeskJigShared

import Foundation
import CoreGraphics

// MARK: - WindowSpec

/// A specification for launching and positioning an app window
/// Supports fluent API for building configurations
public struct WindowSpec: Sendable {
    /// The app launcher to use for this window
    internal let launcher: any AppLauncher

    /// The bundle identifier of the target app (e.g., Cursor, Ghostty).
    public var bundleIdentifier: String { launcher.bundleIdentifier }

    /// The human-readable app name.
    public var appName: String { launcher.appName }
    
    /// The directory to open
    public let directoryPath: String?
    
    /// The window position (preset name)
    public let position: WindowPosition?
    
    /// The target screen index
    public let screenIndex: Int?
    
    /// Optional window title override (open-by-path apps that support titles)
    public let windowTitle: String?

    /// The window index for multiple windows per directory (0, 1, 2...)
    public let windowIndex: Int?

    /// Whether an existing window can be reused (default true).
    /// When false, the launcher will always attempt to create a new window.
    public let allowReuseExisting: Bool

    // MARK: - Initialization
    
    /// Internal initializer for creating specs
    internal init(
        launcher: any AppLauncher,
        directoryPath: String? = nil,
        position: WindowPosition? = nil,
        screenIndex: Int? = nil,
        windowTitle: String? = nil,
        windowIndex: Int? = nil,
        allowReuseExisting: Bool = true
    ) {
        self.launcher = launcher
        self.directoryPath = directoryPath
        self.position = position
        self.screenIndex = screenIndex
        self.windowTitle = windowTitle
        self.windowIndex = windowIndex
        self.allowReuseExisting = allowReuseExisting
    }
    
    // MARK: - Fluent Builder Methods
    
    /// Set the directory path for this window
    /// - Parameter path: The directory path (will be expanded if contains ~)
    /// - Returns: A new WindowSpec with the directory set
    public func inDirectory(_ path: String) -> WindowSpec {
        WindowSpec(
            launcher: launcher,
            directoryPath: (path as NSString).expandingTildeInPath,
            position: position,
            screenIndex: screenIndex,
            windowTitle: windowTitle,
            windowIndex: windowIndex,
            allowReuseExisting: allowReuseExisting
        )
    }
    
    /// Set the window position and optionally the screen
    /// - Parameters:
    ///   - position: The position preset (e.g., .leftHalf, .rightHalf)
    ///   - screen: Optional screen index (0 = primary)
    /// - Returns: A new WindowSpec with position configured
    public func atPosition(_ position: WindowPosition, screen: Int? = nil) -> WindowSpec {
        WindowSpec(
            launcher: launcher,
            directoryPath: directoryPath,
            position: position,
            screenIndex: screen ?? screenIndex,
            windowTitle: windowTitle,
            windowIndex: windowIndex,
            allowReuseExisting: allowReuseExisting
        )
    }
    
    /// Set the target screen
    /// - Parameter index: The screen index (0 = primary)
    /// - Returns: A new WindowSpec with screen configured
    public func onScreen(_ index: Int) -> WindowSpec {
        WindowSpec(
            launcher: launcher,
            directoryPath: directoryPath,
            position: position,
            screenIndex: index,
            windowTitle: windowTitle,
            windowIndex: windowIndex,
            allowReuseExisting: allowReuseExisting
        )
    }

    /// Set the window title (open-by-path apps that support titles)
    /// - Parameter title: The desired window title
    /// - Returns: A new WindowSpec with window title configured
    public func withWindowTitle(_ title: String?) -> WindowSpec {
        WindowSpec(
            launcher: launcher,
            directoryPath: directoryPath,
            position: position,
            screenIndex: screenIndex,
            windowTitle: title,
            windowIndex: windowIndex,
            allowReuseExisting: allowReuseExisting
        )
    }

    /// Set the window index for multiple windows per directory
    /// - Parameter index: The window index (0, 1, 2...)
    /// - Returns: A new WindowSpec with window index configured
    public func withIndex(_ index: Int) -> WindowSpec {
        WindowSpec(
            launcher: launcher,
            directoryPath: directoryPath,
            position: position,
            screenIndex: screenIndex,
            windowTitle: windowTitle,
            windowIndex: index,
            allowReuseExisting: allowReuseExisting
        )
    }

    /// Control whether existing windows can be reused.
    /// - Parameter allow: true to allow reuse, false to always create a new window
    /// - Returns: A new WindowSpec with reuse behavior configured
    public func allowReuseExisting(_ allow: Bool) -> WindowSpec {
        WindowSpec(
            launcher: launcher,
            directoryPath: directoryPath,
            position: position,
            screenIndex: screenIndex,
            windowTitle: windowTitle,
            windowIndex: windowIndex,
            allowReuseExisting: allow
        )
    }
    
    // MARK: - Launch
    
    /// Launch the window with the current specification
    /// - Returns: The launched window
    /// - Throws: LauncherError if launch fails
    public func launch() async throws -> LaunchedWindow {
        // Validate required fields
        guard let directory = directoryPath else {
            throw LauncherError.directoryNotFound(path: "No directory specified")
        }
        
        // Check directory exists
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw LauncherError.directoryNotFound(path: directory)
        }
        
        // Launch via the launcher
        return try await launcher.launch(spec: self)
    }
}

// MARK: - WindowPosition

/// Standard window position presets
public enum WindowPosition: String, Sendable, Codable, CaseIterable {
    // Halves
    case leftHalf = "left-half"
    case rightHalf = "right-half"
    case topHalf = "top-half"
    case bottomHalf = "bottom-half"
    
    // Thirds
    case leftThird = "left-third"
    case centerThird = "center-third"
    case rightThird = "right-third"

    // 6-grid (thirds x halves)
    case topLeftThird = "top-left-third"
    case topCenterThird = "top-center-third"
    case topRightThird = "top-right-third"
    case bottomLeftThird = "bottom-left-third"
    case bottomCenterThird = "bottom-center-third"
    case bottomRightThird = "bottom-right-third"
    
    // Quarters
    case topLeftQuarter = "top-left-quarter"
    case topRightQuarter = "top-right-quarter"
    case bottomLeftQuarter = "bottom-left-quarter"
    case bottomRightQuarter = "bottom-right-quarter"
    
    // Full screen
    case maximize = "maximize"
    
    // Centered
    case center = "center"
    
    /// Convert position to relative window frame
    public func toRelativeFrame() -> RelativeWindowFrame {
        switch self {
        // Halves
        case .leftHalf:
            return RelativeWindowFrame(xPercent: 0.0, yPercent: 0.0, widthPercent: 0.5, heightPercent: 1.0)
        case .rightHalf:
            return RelativeWindowFrame(xPercent: 0.5, yPercent: 0.0, widthPercent: 0.5, heightPercent: 1.0)
        case .topHalf:
            return RelativeWindowFrame(xPercent: 0.0, yPercent: 0.0, widthPercent: 1.0, heightPercent: 0.5)
        case .bottomHalf:
            return RelativeWindowFrame(xPercent: 0.0, yPercent: 0.5, widthPercent: 1.0, heightPercent: 0.5)
        
        // Thirds
        case .leftThird:
            return RelativeWindowFrame(xPercent: 0.0, yPercent: 0.0, widthPercent: 0.3333, heightPercent: 1.0)
        case .centerThird:
            return RelativeWindowFrame(xPercent: 0.3333, yPercent: 0.0, widthPercent: 0.3334, heightPercent: 1.0)
        case .rightThird:
            return RelativeWindowFrame(xPercent: 0.6667, yPercent: 0.0, widthPercent: 0.3333, heightPercent: 1.0)

        // 6-grid (thirds x halves)
        case .topLeftThird:
            return RelativeWindowFrame(xPercent: 0.0, yPercent: 0.0, widthPercent: 0.3333, heightPercent: 0.5)
        case .topCenterThird:
            return RelativeWindowFrame(xPercent: 0.3333, yPercent: 0.0, widthPercent: 0.3334, heightPercent: 0.5)
        case .topRightThird:
            return RelativeWindowFrame(xPercent: 0.6667, yPercent: 0.0, widthPercent: 0.3333, heightPercent: 0.5)
        case .bottomLeftThird:
            return RelativeWindowFrame(xPercent: 0.0, yPercent: 0.5, widthPercent: 0.3333, heightPercent: 0.5)
        case .bottomCenterThird:
            return RelativeWindowFrame(xPercent: 0.3333, yPercent: 0.5, widthPercent: 0.3334, heightPercent: 0.5)
        case .bottomRightThird:
            return RelativeWindowFrame(xPercent: 0.6667, yPercent: 0.5, widthPercent: 0.3333, heightPercent: 0.5)
        
        // Quarters
        case .topLeftQuarter:
            return RelativeWindowFrame(xPercent: 0.0, yPercent: 0.0, widthPercent: 0.5, heightPercent: 0.5)
        case .topRightQuarter:
            return RelativeWindowFrame(xPercent: 0.5, yPercent: 0.0, widthPercent: 0.5, heightPercent: 0.5)
        case .bottomLeftQuarter:
            return RelativeWindowFrame(xPercent: 0.0, yPercent: 0.5, widthPercent: 0.5, heightPercent: 0.5)
        case .bottomRightQuarter:
            return RelativeWindowFrame(xPercent: 0.5, yPercent: 0.5, widthPercent: 0.5, heightPercent: 0.5)
        
        // Full screen
        case .maximize:
            return RelativeWindowFrame(xPercent: 0.0, yPercent: 0.0, widthPercent: 1.0, heightPercent: 1.0)
        
        // Centered
        case .center:
            return RelativeWindowFrame(xPercent: 0.1, yPercent: 0.1, widthPercent: 0.8, heightPercent: 0.8)
        }
    }
    
    /// Parse a position string into a WindowPosition
    /// - Parameter string: The position string (e.g., "left-half")
    /// - Returns: The WindowPosition if valid, nil otherwise
    public static func parse(_ string: String) -> WindowPosition? {
        return WindowPosition(rawValue: string.lowercased())
    }

    /// Best-effort mapping from an arbitrary relative frame to the closest known preset.
    public static func closest(to frame: RelativeWindowFrame) -> WindowPosition {
        let candidates: [WindowPosition] = [
            .leftHalf, .rightHalf, .topHalf, .bottomHalf,
            .leftThird, .centerThird, .rightThird,
            .topLeftThird, .topCenterThird, .topRightThird,
            .bottomLeftThird, .bottomCenterThird, .bottomRightThird,
            .topLeftQuarter, .topRightQuarter, .bottomLeftQuarter, .bottomRightQuarter,
            .maximize, .center,
        ]

        func distance(to candidate: WindowPosition) -> Double {
            let target = candidate.toRelativeFrame()
            return abs(target.xPercent - frame.xPercent)
                + abs(target.yPercent - frame.yPercent)
                + abs(target.widthPercent - frame.widthPercent)
                + abs(target.heightPercent - frame.heightPercent)
        }

        return candidates.min(by: { distance(to: $0) < distance(to: $1) }) ?? .leftHalf
    }
}
