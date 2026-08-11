//  OutputFormatter.swift
//  DeskJigCLI

import Foundation
import CoreGraphics
import DeskJigShared

// MARK: - Output Models

/// Result of a command execution
struct CommandResult: Codable {
    let success: Bool
    let exitCode: Int
    let action: String
    let message: String?
    let data: AnyCodableValue?
    let error: String?

    init(
        success: Bool,
        exitCode: ExitCode,
        action: String,
        message: String? = nil,
        data: AnyCodableValue? = nil,
        error: String? = nil
    ) {
        self.success = success
        self.exitCode = Int(exitCode.rawValue)
        self.action = action
        self.message = message
        self.data = data
        self.error = error
    }

    static func success(action: String, message: String? = nil, data: AnyCodableValue? = nil) -> CommandResult {
        return CommandResult(success: true, exitCode: .success, action: action, message: message, data: data)
    }

    static func failure(action: String, exitCode: ExitCode, error: String) -> CommandResult {
        return CommandResult(success: false, exitCode: exitCode, action: action, error: error)
    }
}

/// Batch result for multiple actions
struct BatchResult: Codable {
    let totalActions: Int
    let successCount: Int
    let failureCount: Int
    let results: [CommandResult]

    var overallExitCode: ExitCode {
        if failureCount == 0 {
            return .success
        } else if successCount == 0 {
            return .actionFailed
        } else {
            return .partialSuccess
        }
    }
}

/// Window output model for JSON serialization
struct WindowOutput: Codable {
    let appName: String
    let title: String
    let bundleID: String?
    let processID: Int32?
    let documentPath: String?
    let axElementHash: Int?
    let frame: FrameOutput
    let isMinimized: Bool
    let isHidden: Bool
    let windowID: Int?
    let zIndex: Int?
    let isOnScreen: Bool?

    init(from windowHandle: WindowHandle, zIndex: Int? = nil, isOnScreen: Bool? = nil) {
        self.appName = windowHandle.appName ?? "Unknown"
        self.title = windowHandle.title ?? ""
        self.bundleID = windowHandle.bundleIdentifier
        self.processID = windowHandle.processID
        self.documentPath = windowHandle.documentPath
        self.axElementHash = windowHandle.axElementHash
        self.frame = FrameOutput(from: windowHandle.frame)
        self.isMinimized = windowHandle.isMinimized
        self.isHidden = windowHandle.isHidden
        self.windowID = windowHandle.windowId
        self.zIndex = zIndex
        self.isOnScreen = isOnScreen
    }

    init(from windowInfo: WindowInfo, zIndex: Int? = nil, isOnScreen: Bool? = nil) {
        self.appName = windowInfo.appName
        self.title = windowInfo.windowTitle
        self.bundleID = windowInfo.bundleIdentifier
        self.processID = windowInfo.processID
        self.documentPath = nil
        self.axElementHash = nil
        self.frame = FrameOutput(from: windowInfo.frame)
        self.isMinimized = windowInfo.isMinimized
        self.isHidden = windowInfo.isHidden
        self.windowID = windowInfo.id
        self.zIndex = zIndex
        self.isOnScreen = isOnScreen
    }

    init(from windowInfo: WindowInfo, handle: WindowHandle?, zIndex: Int? = nil, isOnScreen: Bool? = nil) {
        self.appName = windowInfo.appName
        self.title = windowInfo.windowTitle
        self.bundleID = windowInfo.bundleIdentifier
        self.processID = windowInfo.processID
        self.documentPath = handle?.documentPath
        self.axElementHash = handle?.axElementHash
        self.frame = FrameOutput(from: windowInfo.frame)
        self.isMinimized = windowInfo.isMinimized
        self.isHidden = windowInfo.isHidden
        self.windowID = windowInfo.id
        self.zIndex = zIndex
        self.isOnScreen = isOnScreen
    }
}

/// App output model for JSON serialization
struct AppOutput: Codable {
    let name: String
    let bundleID: String
    let processID: Int32?
    let isRunning: Bool
    let isHidden: Bool
    let isActive: Bool

    init(from appHandle: AppHandle) {
        self.name = appHandle.localizedName ?? appHandle.bundleID
        self.bundleID = appHandle.runningBundleID ?? appHandle.bundleID
        self.processID = appHandle.processID
        self.isRunning = appHandle.isRunning
        self.isHidden = appHandle.isHidden
        self.isActive = appHandle.isActive
    }
}

/// Workspace output model for JSON serialization
struct WorkspaceOutput: Codable {
    let id: String
    let name: String
    let icon: String?
    let windowCount: Int
    let screenCount: Int
    let createdAt: String
    let lastActivatedAt: String?

    init(from workspace: Workspace) {
        self.id = workspace.id.uuidString
        self.name = workspace.name
        self.icon = workspace.icon
        self.windowCount = workspace.windows.count
        self.screenCount = workspace.screens?.count ?? 0

        let formatter = ISO8601DateFormatter()
        self.createdAt = formatter.string(from: workspace.createdAt)
        self.lastActivatedAt = workspace.lastActivatedAt.map { formatter.string(from: $0) }
    }
}

/// Chrome window output model for JSON serialization
struct ChromeWindowOutput: Codable {
    let title: String
    let profile: String?
    let tabCount: Int
    let activeTabIndex: Int?
    let tabs: [String]
    let bounds: FrameOutput

    init(from capture: ChromeAppleScriptWindowCapture) {
        self.title = capture.title
        self.profile = capture.profileAppleScriptName
        self.tabCount = capture.tabURLs.count
        self.activeTabIndex = capture.activeTabIndex
        self.tabs = capture.tabURLs
        self.bounds = FrameOutput(from: capture.bounds)
    }
}

// MARK: - AnyCodable Helper

/// Type-erased codable value for flexible JSON data
enum AnyCodableValue: Codable {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
    case array([AnyCodableValue])
    case dictionary([String: AnyCodableValue])
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()

        if container.decodeNil() {
            self = .null
        } else if let bool = try? container.decode(Bool.self) {
            self = .bool(bool)
        } else if let int = try? container.decode(Int.self) {
            self = .int(int)
        } else if let double = try? container.decode(Double.self) {
            self = .double(double)
        } else if let string = try? container.decode(String.self) {
            self = .string(string)
        } else if let array = try? container.decode([AnyCodableValue].self) {
            self = .array(array)
        } else if let dictionary = try? container.decode([String: AnyCodableValue].self) {
            self = .dictionary(dictionary)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unable to decode value")
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()

        switch self {
        case .string(let value): try container.encode(value)
        case .int(let value): try container.encode(value)
        case .double(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .dictionary(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }

    static func from<T: Encodable>(_ value: T) -> AnyCodableValue? {
        do {
            let encoder = JSONEncoder()
            let data = try encoder.encode(value)
            let decoder = JSONDecoder()
            return try decoder.decode(AnyCodableValue.self, from: data)
        } catch {
            return nil
        }
    }
}

// MARK: - Output Formatter

/// Formats command results for output
class OutputFormatter {

    private static let jsonEncoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    // MARK: - Command Result Formatting

    static func format(_ result: CommandResult, format: OutputFormat) -> String {
        switch format {
        case .json:
            return formatJSON(result)
        case .text:
            return formatText(result)
        }
    }

    static func format(_ batch: BatchResult, format: OutputFormat) -> String {
        switch format {
        case .json:
            return formatJSON(batch)
        case .text:
            return formatTextBatch(batch)
        }
    }

    // MARK: - Window Formatting

    static func formatWindows(_ windows: [WindowHandle], format: OutputFormat) -> String {
        let outputs = windows.map { WindowOutput(from: $0) }
        return formatWindowOutputs(outputs, format: format)
    }

    static func formatWindows(_ windows: [WindowInfo], format: OutputFormat) -> String {
        let outputs = windows.map { WindowOutput(from: $0) }
        return formatWindowOutputs(outputs, format: format)
    }

    static func formatWindowOutputs(_ outputs: [WindowOutput], format: OutputFormat) -> String {

        switch format {
        case .json:
            return formatJSON(outputs)
        case .text:
            return formatTextWindows(outputs)
        }
    }

    static func formatWindow(_ window: WindowHandle, format: OutputFormat) -> String {
        let output = WindowOutput(from: window)

        switch format {
        case .json:
            return formatJSON(output)
        case .text:
            return formatTextWindow(output)
        }
    }

    // MARK: - App Formatting

    static func formatApps(_ apps: [AppHandle], format: OutputFormat) -> String {
        let outputs = apps.map { AppOutput(from: $0) }

        switch format {
        case .json:
            return formatJSON(outputs)
        case .text:
            return formatTextApps(outputs)
        }
    }

    // MARK: - Workspace Formatting

    static func formatWorkspaces(_ workspaces: [Workspace], format: OutputFormat) -> String {
        let outputs = workspaces.map { WorkspaceOutput(from: $0) }

        switch format {
        case .json:
            return formatJSON(outputs)
        case .text:
            return formatTextWorkspaces(workspaces)
        }
    }

    // MARK: - Chrome Formatting

    static func formatChromeWindows(_ captures: [ChromeAppleScriptWindowCapture], format: OutputFormat) -> String {
        let outputs = captures.map { ChromeWindowOutput(from: $0) }

        switch format {
        case .json:
            return formatJSON(outputs)
        case .text:
            return formatTextChromeWindows(captures)
        }
    }

    static func formatChromeTabs(_ capture: ChromeAppleScriptWindowCapture, format: OutputFormat) -> String {
        switch format {
        case .json:
            return formatJSON(ChromeWindowOutput(from: capture))
        case .text:
            return formatTextChromeTabs(capture)
        }
    }

    // MARK: - Private JSON Helpers

    private static func formatJSON<T: Encodable>(_ value: T) -> String {
        do {
            let data = try jsonEncoder.encode(value)
            return String(data: data, encoding: .utf8) ?? "{}"
        } catch {
            return "{\"error\": \"Failed to encode JSON: \(error.localizedDescription)\"}"
        }
    }

    // MARK: - Private Text Helpers

    private static func formatText(_ result: CommandResult) -> String {
        var output = ""

        if result.success {
            output += "✓ \(result.action)"
            if let message = result.message {
                output += ": \(message)"
            }
        } else {
            output += "✗ \(result.action)"
            if let error = result.error {
                output += ": \(error)"
            }
        }

        return output
    }

    private static func formatTextBatch(_ batch: BatchResult) -> String {
        var output = ""

        for result in batch.results {
            output += formatText(result) + "\n"
        }

        output += "\n"
        output += String(repeating: "-", count: 40) + "\n"
        output += "Total: \(batch.totalActions) | Success: \(batch.successCount) | Failed: \(batch.failureCount)"

        return output
    }

    private static func formatTextWindows(_ windows: [WindowOutput]) -> String {
        if windows.isEmpty {
            return "No windows found."
        }

        var output = "Found \(windows.count) window(s):\n\n"

        for (index, window) in windows.enumerated() {
            let status = [
                window.isMinimized ? "[M]" : "",
                window.isHidden ? "[H]" : "",
                window.isOnScreen == false ? "[Offscreen]" : ""
            ].filter { !$0.isEmpty }.joined(separator: " ")

            let title = window.title.isEmpty ? "<No Title>" : window.title
            output += String(format: "%3d. %@ - %@%@\n",
                             index + 1,
                             window.appName,
                             title,
                             status.isEmpty ? "" : " \(status)")

            var metadataParts: [String] = []
            if let windowID = window.windowID {
                metadataParts.append("ID \(windowID)")
            }
            if let zIndex = window.zIndex {
                metadataParts.append("Z \(zIndex)")
            }
            if let isOnScreen = window.isOnScreen {
                metadataParts.append(isOnScreen ? "On-screen" : "Off-screen")
            }
            if !metadataParts.isEmpty {
                output += "     " + metadataParts.joined(separator: " | ") + "\n"
            }

            output += String(format: "     Frame: (%.0f, %.0f) %.0fx%.0f\n",
                           window.frame.x, window.frame.y,
                           window.frame.width, window.frame.height)
        }

        return output
    }

    private static func formatTextWindow(_ window: WindowOutput) -> String {
        var output = ""
        let title = window.title.isEmpty ? "<No Title>" : window.title

        output += "Application:  \(window.appName)\n"
        output += "Title:        \(title)\n"
        if let bundleID = window.bundleID {
            output += "Bundle ID:    \(bundleID)\n"
        }
        if let processID = window.processID {
            output += "Process ID:   \(processID)\n"
        }
        if let windowID = window.windowID {
            output += "Window ID:    \(windowID)\n"
        }
        if let documentPath = window.documentPath, !documentPath.isEmpty {
            output += "Document:    \(documentPath)\n"
        }
        if let axElementHash = window.axElementHash {
            output += "AX Hash:     \(axElementHash)\n"
        }
        if let zIndex = window.zIndex {
            output += "Z-Index:      \(zIndex)\n"
        }
        if let isOnScreen = window.isOnScreen {
            output += "On Screen:    \(isOnScreen ? "Yes" : "No")\n"
        }
        output += String(format: "Position:     (%.0f, %.0f)\n", window.frame.x, window.frame.y)
        output += String(format: "Size:         %.0f x %.0f\n", window.frame.width, window.frame.height)
        output += "Minimized:    \(window.isMinimized ? "Yes" : "No")\n"
        output += "Hidden:       \(window.isHidden ? "Yes" : "No")"

        return output
    }

    private static func formatTextApps(_ apps: [AppOutput]) -> String {
        if apps.isEmpty {
            return "No apps found."
        }

        var output = "Found \(apps.count) app(s):\n\n"

        for (index, app) in apps.enumerated() {
            let status = [
                app.isActive ? "[Active]" : "",
                app.isHidden ? "[Hidden]" : ""
            ].filter { !$0.isEmpty }.joined(separator: " ")

            output += String(format: "%3d. %@%@\n", index + 1, app.name, status.isEmpty ? "" : " \(status)")
            output += "     Bundle: \(app.bundleID)\n"
        }

        return output
    }

    private static func formatTextWorkspaces(_ workspaces: [Workspace]) -> String {
        if workspaces.isEmpty {
            return "No saved workspaces found."
        }

        var output = "Found \(workspaces.count) workspace(s):\n\n"

        for (index, workspace) in workspaces.enumerated() {
            let created = dateFormatter.string(from: workspace.createdAt)
            let screenCount = workspace.screens?.count ?? 0
            let screenInfo = screenCount > 0 ? ", \(screenCount) screen(s)" : ""

            output += String(format: "%3d. %@ (%d window(s)%@)\n",
                           index + 1,
                           workspace.name,
                           workspace.windows.count,
                           screenInfo)
            output += "     Created: \(created)\n"
        }

        return output
    }

    private static func formatTextChromeWindows(_ captures: [ChromeAppleScriptWindowCapture]) -> String {
        if captures.isEmpty {
            return "No Chrome windows found."
        }

        var output = "Found \(captures.count) Chrome window(s):\n\n"

        for (index, capture) in captures.enumerated() {
            let profile = capture.profileAppleScriptName ?? "Default"
            let title = capture.title.isEmpty ? "<No Title>" : capture.title

            output += String(format: "%3d. [%@] %@ (%d tabs)\n",
                           index + 1,
                           profile,
                           title,
                           capture.tabURLs.count)
        }

        return output
    }

    private static func formatTextChromeTabs(_ capture: ChromeAppleScriptWindowCapture) -> String {
        let profile = capture.profileAppleScriptName ?? "Default"
        let title = capture.title.isEmpty ? "<No Title>" : capture.title

        var output = "Chrome Window: \(title)\n"
        output += "Profile: \(profile)\n"
        output += "Tabs (\(capture.tabURLs.count)):\n\n"

        for (index, url) in capture.tabURLs.enumerated() {
            let marker = capture.activeTabIndex == index + 1 ? "★ " : "  "
            output += "\(marker)\(index + 1). \(url)\n"
        }

        if capture.activeTabIndex != nil {
            output += "\n★ = Active Tab"
        }

        return output
    }
}

