//  CLIOutputModels.swift
//  DeskJigCLI

import CoreGraphics
import Foundation

/// Launch output for apps that do not expose a CLI window title field.
struct LaunchOutput: Codable {
    let app: String
    let path: String
    let position: String
    let screen: Int
}

/// Launch output for terminal-style apps that include a title and optional position.
struct TitledLaunchOutput: Codable {
    let app: String
    let path: String
    let title: String
    let position: String?
    let screen: Int
}

/// Frame output model for JSON serialization.
struct FrameOutput: Codable {
    let x: Double
    let y: Double
    let width: Double
    let height: Double

    init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    init(from frame: CGRect?) {
        self.x = Double(frame?.origin.x ?? 0)
        self.y = Double(frame?.origin.y ?? 0)
        self.width = Double(frame?.width ?? 0)
        self.height = Double(frame?.height ?? 0)
    }
}

/// Display output model for JSON serialization.
struct DisplayOutput: Codable {
    let index: Int
    let displayID: Int
    let name: String
    let frame: FrameOutput
    let visibleFrame: FrameOutput
    let isPrimary: Bool
}

/// Relative workspace frame output model for JSON serialization.
struct RelativeFrameDetail: Codable {
    let xPercent: Double
    let yPercent: Double
    let widthPercent: Double
    let heightPercent: Double
}

/// Saved workspace window detail output without list index.
struct WindowDetailOutput: Codable {
    let id: String
    let appName: String
    let bundleID: String
    let title: String
    let openPath: String?
    let screenIndex: Int?
    let relativeFrame: RelativeFrameDetail?
}

/// Saved workspace window detail output with list index.
struct IndexedWindowDetailOutput: Codable {
    let index: Int
    let id: String
    let appName: String
    let bundleID: String
    let title: String
    let openPath: String?
    let screenIndex: Int?
    let relativeFrame: RelativeFrameDetail?
}

/// Window output for `open` JSON responses.
struct WindowInfoOutput: Codable {
    struct PositionInfo: Codable {
        let x: Double
        let y: Double
        let width: Double
        let height: Double
    }

    let id: String
    let title: String?
    let app: String
    let bundleId: String
    let pid: Int32
    let position: PositionInfo?
    let screen: Int
    let directory: String
}

/// Window output for `windows find` JSON responses.
struct WindowFindInfoOutput: Codable {
    struct FrameInfo: Codable {
        let x: Double
        let y: Double
        let width: Double
        let height: Double
    }

    let app: String
    let bundleId: String
    let pid: Int32
    let title: String?
    let directory: String
    let confidence: String
    let matchedBy: String
    let frame: FrameInfo?
    let documentPath: String?
}

/// Window output for directory-workspace info JSON responses.
struct DirectoryWindowInfoOutput: Codable {
    let index: Int
    let displayName: String
    let directoryPath: String
    let bundleIdentifier: String
    let isGhostty: Bool
    let isCursor: Bool
    let isCodex: Bool
    let isTerminal: Bool
    let isITerm: Bool
    let isKitty: Bool
    let isAlacritty: Bool
    let position: String
    let screenIndex: Int
    let appName: String
}

