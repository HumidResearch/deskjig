//  CLIActions.swift
//  DeskJigCLI

import Foundation
import CoreGraphics
import DeskJigShared

// MARK: - Exit Codes

/// Standard exit codes for CLI operations
enum ExitCode: Int32 {
    case success = 0
    case generalError = 1
    case invalidArguments = 2
    case actionFailed = 3
    case partialSuccess = 4
    case notFound = 5
    case permissionDenied = 6
}

// MARK: - Output Format

/// Output format for CLI results
enum OutputFormat: String, CaseIterable {
    case json
    case text
    
    static func from(string: String) -> OutputFormat? {
        return OutputFormat(rawValue: string.lowercased())
    }
}

// MARK: - Window Target

/// Specifies how to target a window for operations
enum WindowTarget: Equatable {
    case byWindowId(Int)
    case byAxHash(Int)
    case byTitle(String)
    case byTitleContaining(String)
    case byApp(String)
    case byBundleID(String)
    case topmost
    case all
    case fromStdin
    
    var description: String {
        switch self {
        case .byWindowId(let windowId): return "window-id='\(windowId)'"
        case .byAxHash(let axHash): return "ax-hash='\(axHash)'"
        case .byTitle(let title): return "title='\(title)'"
        case .byTitleContaining(let text): return "title-contains='\(text)'"
        case .byApp(let app): return "app='\(app)'"
        case .byBundleID(let bundleID): return "bundle-id='\(bundleID)'"
        case .topmost: return "topmost"
        case .all: return "all"
        case .fromStdin: return "from-stdin"
        }
    }
}

// MARK: - Window Position

/// Predefined window positions for move operations
enum WindowPosition: String, CaseIterable {
    case leftHalf = "left-half"
    case rightHalf = "right-half"
    case topHalf = "top-half"
    case bottomHalf = "bottom-half"
    case leftThird = "left-third"
    case centerThird = "center-third"
    case rightThird = "right-third"
    case topLeftThird = "top-left-third"
    case topCenterThird = "top-center-third"
    case topRightThird = "top-right-third"
    case bottomLeftThird = "bottom-left-third"
    case bottomCenterThird = "bottom-center-third"
    case bottomRightThird = "bottom-right-third"
    case topLeftQuarter = "top-left-quarter"
    case topRightQuarter = "top-right-quarter"
    case bottomLeftQuarter = "bottom-left-quarter"
    case bottomRightQuarter = "bottom-right-quarter"
    case center = "center"
    case maximize = "maximize"
    
    static func from(string: String) -> WindowPosition? {
        return WindowPosition(rawValue: string.lowercased())
    }

    /// Parse a position string (alias for from(string:) for compatibility)
    static func parse(_ string: String) -> WindowPosition? {
        return WindowPosition(rawValue: string.lowercased())
    }

    var description: String {
        return rawValue
    }
}

/// Custom window position with coordinates
struct CustomPosition: Equatable {
    let x: CGFloat
    let y: CGFloat
    
    init(x: CGFloat, y: CGFloat) {
        self.x = x
        self.y = y
    }
    
    /// Parse "x,y" format
    static func from(string: String) -> CustomPosition? {
        let parts = string.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count == 2,
              let x = Double(parts[0]),
              let y = Double(parts[1]) else {
            return nil
        }
        return CustomPosition(x: CGFloat(x), y: CGFloat(y))
    }
}

/// Custom window size
struct CustomSize: Equatable {
    let width: CGFloat
    let height: CGFloat
    
    init(width: CGFloat, height: CGFloat) {
        self.width = width
        self.height = height
    }
    
    /// Parse "widthxheight" format
    static func from(string: String) -> CustomSize? {
        let parts = string.lowercased().split(separator: "x").map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count == 2,
              let width = Double(parts[0]),
              let height = Double(parts[1]) else {
            return nil
        }
        return CustomSize(width: CGFloat(width), height: CGFloat(height))
    }
}

// MARK: - Window Filter

/// Filter options for querying windows
struct WindowFilter: Equatable {
    var appName: String?
    var bundleID: String?
    var titleContains: String?
    var titleEquals: String?
    var includeHidden: Bool
    var includeMinimized: Bool
    
    init(
        appName: String? = nil,
        bundleID: String? = nil,
        titleContains: String? = nil,
        titleEquals: String? = nil,
        includeHidden: Bool = false,
        includeMinimized: Bool = true
    ) {
        self.appName = appName
        self.bundleID = bundleID
        self.titleContains = titleContains
        self.titleEquals = titleEquals
        self.includeHidden = includeHidden
        self.includeMinimized = includeMinimized
    }
    
    static let empty = WindowFilter()
}

// MARK: - App Target (for open command)

/// Specifies how to identify an app for the open command
enum AppTarget: Equatable {
    case alias(String)           // ghostty, cursor, codex, vscode, xcode, terminal, iterm, kitty, alacritty
    case appName(String)         // "Visual Studio Code"
    case bundleID(String)        // com.mitchellh.ghostty
    case processID(pid_t)        // Existing process

    var description: String {
        switch self {
        case .alias(let name): return "alias='\(name)'"
        case .appName(let name): return "app='\(name)'"
        case .bundleID(let id): return "bundle-id='\(id)'"
        case .processID(let pid): return "pid=\(pid)"
        }
    }

    /// Known app aliases mapped to bundle IDs
    static let knownAliases: [String: String] = [
        "ghostty": "com.mitchellh.ghostty",
        "cursor": "com.todesktop.230313mzl4w4u92",
        "codex": "com.openai.codex",
        "vscode": "com.microsoft.VSCode",
        "xcode": "com.apple.dt.Xcode",
        "terminal": "com.apple.Terminal",
        "iterm": "com.googlecode.iterm2",
        "iterm2": "com.googlecode.iterm2",
        "kitty": "net.kovidgoyal.kitty",
        "alacritty": "org.alacritty"
    ]

    /// Resolve alias to bundle ID, or return nil if not a known alias
    func resolvedBundleID() -> String? {
        switch self {
        case .alias(let name):
            return AppTarget.knownAliases[name.lowercased()]
        case .bundleID(let id):
            return id
        case .appName, .processID:
            return nil
        }
    }

    /// Check if this target is for a terminal emulator
    var isTerminalEmulator: Bool {
        switch self {
        case .alias(let name):
            return ["ghostty", "terminal", "iterm", "iterm2", "kitty", "alacritty"].contains(name.lowercased())
        case .bundleID(let id):
            return [
                "com.mitchellh.ghostty",
                "com.apple.Terminal",
                "com.googlecode.iterm2",
                "net.kovidgoyal.kitty",
                "org.alacritty"
            ].contains(id)
        default:
            return false
        }
    }
}

// MARK: - App Filter

/// Filter options for querying apps
struct AppFilter: Equatable {
    var nameContains: String?
    var bundleIDContains: String?
    var runningOnly: Bool

    init(
        nameContains: String? = nil,
        bundleIDContains: String? = nil,
        runningOnly: Bool = true
    ) {
        self.nameContains = nameContains
        self.bundleIDContains = bundleIDContains
        self.runningOnly = runningOnly
    }

    static let empty = AppFilter()
}

// MARK: - Test Workspace Options

enum TestTerminalApp: String, CaseIterable, Codable {
    case ghostty
    case terminal
    case iterm
    case kitty
    case alacritty

    var bundleID: String {
        switch self {
        case .ghostty:
            return OpenByPathBundleIdentifiers.ghostty
        case .terminal:
            return OpenByPathBundleIdentifiers.terminal
        case .iterm:
            return OpenByPathBundleIdentifiers.iterm2
        case .kitty:
            return OpenByPathBundleIdentifiers.kitty
        case .alacritty:
            return OpenByPathBundleIdentifiers.alacritty
        }
    }

    var appName: String {
        switch self {
        case .ghostty:
            return "Ghostty"
        case .terminal:
            return "Terminal"
        case .iterm:
            return "iTerm"
        case .kitty:
            return "kitty"
        case .alacritty:
            return "Alacritty"
        }
    }
}

struct CreateTestWorkspacesOptions: Equatable, Codable {
    let terminalApp: TestTerminalApp
    let pathA: String?
    let pathB: String?
}

struct ChromeOverride: Equatable, Codable {
    let profileDirectory: String?
    let profileDisplayName: String?
    let profileHostedDomain: String?
    let tabs: [String]?
    let focusedTabIndex: Int?
}

struct WindowOverride: Equatable, Codable {
    let index: Int
    let openPath: String?
    let chrome: ChromeOverride?
}

struct WorkspaceRestoreOverrides: Equatable, Codable {
    let windows: [WindowOverride]
}

struct RestoreWorkspaceOptions: Equatable {
    let name: String
    /// When nil, reads from UserDefaults "restoreHideAllApps" preference (matching GUI behavior)
    let hideAllApps: Bool?
    let overrideFilePath: String?
    let windowOverrides: [WindowOverride]
}

struct RestoreWorkspaceFileOptions: Equatable {
    let path: String
    let overrideFilePath: String?
    let windowOverrides: [WindowOverride]
}

struct CreateRichWorkspaceOptions: Equatable {
    let name: String
    let icon: String?
    let screenIndex: Int
    let chromeScreenIndex: Int
    let terminalScreenIndex: Int
    let vscodeScreenIndex: Int
    let kittyScreenIndex: Int
    let replaceExisting: Bool
    let terminalApp: TestTerminalApp
    let terminalPath: String
    let vscodePath: String
    let kittyPath: String
    let chromeProfileDirectory: String
    let chromeProfileName: String
    let chromeHostedDomain: String?
    let chromeUrls: [String]
    let chromePosition: WindowPosition
    let terminalPosition: WindowPosition
    let vscodePosition: WindowPosition
    let kittyPosition: WindowPosition
}

struct WorkspaceCreationSpec: Equatable, Codable {
    let name: String
    let icon: String?
    let replaceExisting: Bool
    let windows: [WorkspaceCreationWindowSpec]
}

struct WorkspaceCreationWindowSpec: Equatable, Codable {
    let bundleId: String?
    let appName: String?
    let title: String?
    let openPath: String?
    let screen: WorkspaceCreationScreenTarget?
    let layout: WorkspaceCreationLayoutSpec
}

enum WorkspaceCreationScreenTarget: Equatable, Codable {
    case index(Int)
    case displayID(Int)
    case primary

    private enum CodingKeys: String, CodingKey {
        case index
        case displayID
        case isPrimary
    }

    init(from decoder: Decoder) throws {
        if let singleValue = try? decoder.singleValueContainer(),
           let index = try? singleValue.decode(Int.self) {
            self = .index(index)
            return
        }

        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let index = try container.decodeIfPresent(Int.self, forKey: .index) {
            self = .index(index)
            return
        }
        if let displayID = try container.decodeIfPresent(Int.self, forKey: .displayID) {
            self = .displayID(displayID)
            return
        }
        if try container.decodeIfPresent(Bool.self, forKey: .isPrimary) == true {
            self = .primary
            return
        }

        throw DecodingError.dataCorrupted(
            .init(
                codingPath: decoder.codingPath,
                debugDescription: "screen must be an integer index or an object with index, displayID, or isPrimary=true"
            )
        )
    }

    func encode(to encoder: Encoder) throws {
        switch self {
        case .index(let index):
            var container = encoder.singleValueContainer()
            try container.encode(index)
        case .displayID(let displayID):
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(displayID, forKey: .displayID)
        case .primary:
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(true, forKey: .isPrimary)
        }
    }
}

enum WorkspaceCreationLayoutSpec: Equatable, Codable {
    case preset(String)
    case relativeFrame(RelativeFrameSpec)

    init(from decoder: Decoder) throws {
        if let singleValue = try? decoder.singleValueContainer(),
           let preset = try? singleValue.decode(String.self) {
            self = .preset(preset)
            return
        }

        let frame = try RelativeFrameSpec(from: decoder)
        self = .relativeFrame(frame)
    }

    func encode(to encoder: Encoder) throws {
        switch self {
        case .preset(let preset):
            var container = encoder.singleValueContainer()
            try container.encode(preset)
        case .relativeFrame(let frame):
            try frame.encode(to: encoder)
        }
    }
}

struct RelativeFrameSpec: Equatable, Codable {
    let xPercent: Double
    let yPercent: Double
    let widthPercent: Double
    let heightPercent: Double
}

// MARK: - CLI Action

/// All supported CLI actions
enum CLIAction: Equatable {
    // Workspace Operations (existing, enhanced)
    case listWorkspaces
    case workspaceCreateFromSpec(spec: WorkspaceCreationSpec)
    case workspaceInfo(name: String)
    case deleteWorkspace(name: String)
    case workspaceEdit(name: String, rename: String?, icon: String?, shortcut: String?)
    case workspaceWindowList(name: String)
    case workspaceWindowUpdate(name: String, index: Int, position: String?, screen: Int?, openPath: String?, title: String?)
    case workspaceWindowAdd(name: String, bundleID: String?, appAlias: String?, appName: String?, title: String?, openPath: String?, position: String?, screen: Int?)
    case workspaceWindowRemove(name: String, index: Int)
    case restoreWorkspace(options: RestoreWorkspaceOptions)
    case restoreWorkspaceFile(options: RestoreWorkspaceFileOptions)
    case workspaceImportFile(path: String, replaceExisting: Bool)
    case debugRestoreLoop(options: DebugRestoreLoopOptions)
    case createTestWorkspaces(options: CreateTestWorkspacesOptions)
    case createRichWorkspace(options: CreateRichWorkspaceOptions)
    case dumpWindows
    case listDisplays
    
    // Window Operations (FluentAPI)
    case queryWindows(filter: WindowFilter)
    case getWindowInfo(target: WindowTarget)
    case activateWindow(target: WindowTarget)
    case moveWindow(target: WindowTarget, position: WindowPosition?, customPosition: CustomPosition?, screenIndex: Int?)
    case resizeWindow(target: WindowTarget, size: CustomSize)
    case minimizeWindow(target: WindowTarget)
    case unminimizeWindow(target: WindowTarget)
    case closeWindow(target: WindowTarget)
    case centerWindow(target: WindowTarget)
    case maximizeWindow(target: WindowTarget)

    // Window Query by Directory (for testing/verification)
    case windowsList(app: String?, axInfo: Bool, allAxAttributes: Bool)  // List windows for an app
    case windowsFind(directory: String, app: String?)    // Find window by directory path
    case windowsInfo(directory: String)                  // Get detailed info about a window by directory
    
    // App Operations
    case listRunningApps
    case queryApps(filter: AppFilter)
    case launchApp(bundleID: String, urls: [String]?)
    case activateApp(target: WindowTarget)
    case hideApp(target: WindowTarget)
    case unhideApp(target: WindowTarget)
    case terminateApp(target: WindowTarget)
    case hideAllApps(minWindowSize: CGSize)
    case unhideAllApps

    // Chrome Operations
    case listChromeWindows
    case launchChromeProfile(profile: String, urls: [String])
    case openChromeTabs(target: WindowTarget, urls: [String])
    case switchChromeTab(target: WindowTarget, tabIndex: Int)
    case exportChromeTabs(target: WindowTarget?)

    // Quick Switch
    case quickSwitchListDirectories

    // Standalone Launch with Positioning (for isolated testing)
    case launchCursorPositioned(path: String, position: String, screen: Int?)
    case launchGhosttyPositioned(path: String, position: String, screen: Int?)
    case launchTerminalPositioned(path: String, title: String?, position: String?, screen: Int?)
    case launchKittyPositioned(path: String, title: String?, position: String?, screen: Int?)
    case launchAlacrittyPositioned(path: String, title: String?, position: String?, screen: Int?)

    // Open command - fluent API for launching apps in directories
    case openApp(
        target: AppTarget,
        directory: String,
        position: String?,
        screen: Int,
        forceNew: Bool,
        titleOverride: String?
    )

    // Log Operations
    case listRunIds(lines: Int?, since: String?)
    case showRunId(runId: String, lines: Int?)

    struct DebugRestoreLoopOptions: Equatable, Codable {
        let workspaces: [String]
        let iterations: Int
        let sleepSeconds: Double
        let outputDir: String?
        let screenshotDisplayIndex: Int?
        let captureScreenshots: Bool
        let captureAllDisplays: Bool
        let killEvery: Int?
        let logLines: Int
        let logQuery: String?
        /// When nil, reads from UserDefaults "restoreHideAllApps" preference (matching GUI behavior)
        let hideAllApps: Bool?
    }

    var description: String {
        switch self {
        case .listWorkspaces: return "list-workspaces"
        case .workspaceCreateFromSpec(let spec):
            return "workspace-create-from-spec '\(spec.name)'"
        case .workspaceInfo(let name): return "workspace-info '\(name)'"
        case .deleteWorkspace(let name): return "delete-workspace '\(name)'"
        case .workspaceEdit(let name, _, _, _): return "workspace-edit '\(name)'"
        case .workspaceWindowList(let name): return "workspace-window-list '\(name)'"
        case .workspaceWindowUpdate(let name, let index, _, _, _, _):
            return "workspace-window-update '\(name)' [\(index)]"
        case .workspaceWindowAdd(let name, let bundleID, let appAlias, _, _, _, _, _):
            return "workspace-window-add '\(name)' \(bundleID ?? appAlias ?? "unknown-app")"
        case .workspaceWindowRemove(let name, let index):
            return "workspace-window-remove '\(name)' [\(index)]"
        case .restoreWorkspace(let options):
            let hideFlag = (options.hideAllApps == true) ? " --hide-all-apps" : ""
            return "restore-workspace '\(options.name)'\(hideFlag)"
        case .restoreWorkspaceFile(let options): return "restore-workspace-file '\(options.path)'"
        case .workspaceImportFile(let path, let replace):
            let replaceFlag = replace ? " --replace-existing" : ""
            return "workspace-import-file '\(path)'\(replaceFlag)"
        case .debugRestoreLoop(let options):
            let names = options.workspaces.joined(separator: ", ")
            return "debug-restore-loop [\(names)]"
        case .createTestWorkspaces(let options):
            var parts = ["create-test-workspaces", "terminal=\(options.terminalApp.rawValue)"]
            if let pathA = options.pathA { parts.append("path-a='\(pathA)'") }
            if let pathB = options.pathB { parts.append("path-b='\(pathB)'") }
            return parts.joined(separator: " ")
        case .createRichWorkspace(let options):
            var parts = ["create-rich-workspace", "name='\(options.name)'"]
            parts.append("terminal=\(options.terminalApp.rawValue)")
            parts.append("terminal-path='\(options.terminalPath)'")
            parts.append("vscode-path='\(options.vscodePath)'")
            parts.append("kitty-path='\(options.kittyPath)'")
            if !options.chromeUrls.isEmpty {
                parts.append("chrome-urls=\(options.chromeUrls.joined(separator: ","))")
            }
            return parts.joined(separator: " ")
        case .dumpWindows: return "dump-windows"
        case .listDisplays: return "list-displays"
        case .queryWindows: return "query-windows"
        case .getWindowInfo(let target): return "get-window-info \(target.description)"
        case .activateWindow(let target): return "activate-window \(target.description)"
        case .moveWindow(let target, let pos, let custom, let screen):
            let posStr = pos?.description ?? custom.map { "\($0.x),\($0.y)" } ?? "unknown"
            let screenStr = screen.map { " on screen \($0)" } ?? ""
            return "move-window \(target.description) to \(posStr)\(screenStr)"
        case .resizeWindow(let target, let size): return "resize-window \(target.description) to \(size.width)x\(size.height)"
        case .minimizeWindow(let target): return "minimize-window \(target.description)"
        case .unminimizeWindow(let target): return "unminimize-window \(target.description)"
        case .closeWindow(let target): return "close-window \(target.description)"
        case .centerWindow(let target): return "center-window \(target.description)"
        case .maximizeWindow(let target): return "maximize-window \(target.description)"
        case .windowsList(let app, let axInfo, let allAxAttributes):
            var result = "windows list"
            if let app { result += " --app \(app)" }
            if allAxAttributes { result += " --all-ax-attributes" }
            else if axInfo { result += " --ax-info" }
            return result
        case .windowsFind(let directory, let app):
            var result = "windows find --directory '\(directory)'"
            if let app { result += " --app \(app)" }
            return result
        case .windowsInfo(let directory):
            return "windows info --directory '\(directory)'"
        case .listRunningApps: return "list-running-apps"
        case .queryApps: return "query-apps"
        case .launchApp(let bundleID, _): return "launch-app \(bundleID)"
        case .activateApp(let target): return "activate-app \(target.description)"
        case .hideApp(let target): return "hide-app \(target.description)"
        case .unhideApp(let target): return "unhide-app \(target.description)"
        case .terminateApp(let target): return "terminate-app \(target.description)"
        case .hideAllApps(let minSize):
            if minSize == .zero {
                return "hide-all-apps"
            } else {
                return "hide-all-apps --min-window-size \(Int(minSize.width))"
            }
        case .unhideAllApps: return "unhide-all-apps"
        case .listChromeWindows: return "list-chrome-windows"
        case .launchChromeProfile(let profile, _): return "launch-chrome-profile '\(profile)'"
        case .openChromeTabs(let target, _): return "open-chrome-tabs \(target.description)"
        case .switchChromeTab(let target, let idx): return "switch-chrome-tab \(target.description) \(idx)"
        case .exportChromeTabs: return "export-chrome-tabs"
        case .quickSwitchListDirectories: return "quick-switch-list-directories"
        case .launchCursorPositioned(let path, let position, let screen):
            let screenStr = screen.map { " screen=\($0)" } ?? ""
            return "launch-cursor-positioned path='\(path)' position=\(position)\(screenStr)"
        case .launchGhosttyPositioned(let path, let position, let screen):
            let screenStr = screen.map { " screen=\($0)" } ?? ""
            return "launch-ghostty-positioned path='\(path)' position=\(position)\(screenStr)"
        case .launchTerminalPositioned(let path, let title, let position, let screen):
            let titleStr = title.map { " title='\($0)'" } ?? ""
            let positionStr = position.map { " position=\($0)" } ?? ""
            let screenStr = screen.map { " screen=\($0)" } ?? ""
            return "launch-terminal-positioned path='\(path)'\(titleStr)\(positionStr)\(screenStr)"
        case .launchKittyPositioned(let path, let title, let position, let screen):
            let titleStr = title.map { " title='\($0)'" } ?? ""
            let positionStr = position.map { " position=\($0)" } ?? ""
            let screenStr = screen.map { " screen=\($0)" } ?? ""
            return "launch-kitty-positioned path='\(path)'\(titleStr)\(positionStr)\(screenStr)"
        case .launchAlacrittyPositioned(let path, let title, let position, let screen):
            let titleStr = title.map { " title='\($0)'" } ?? ""
            let positionStr = position.map { " position=\($0)" } ?? ""
            let screenStr = screen.map { " screen=\($0)" } ?? ""
            return "launch-alacritty-positioned path='\(path)'\(titleStr)\(positionStr)\(screenStr)"
        case .openApp(let target, let directory, let position, let screen, let forceNew, let titleOverride):
            var parts = ["open", target.description, "directory='\(directory)'"]
            if let pos = position { parts.append("position=\(pos)") }
            parts.append("screen=\(screen)")
            if forceNew { parts.append("--new") }
            if let title = titleOverride { parts.append("title='\(title)'") }
            return parts.joined(separator: " ")
        case .listRunIds(let lines, let since):
            var result = "list-run-ids"
            if let lines { result += " --lines \(lines)" }
            if let since { result += " --since '\(since)'" }
            return result
        case .showRunId(let runId, let lines):
            var result = "show-run-id '\(runId)'"
            if let lines { result += " --lines \(lines)" }
            return result
        }
    }

}

// MARK: - Parsed Command

/// The result of parsing command-line arguments
struct ParsedCommand {
    let actions: [CLIAction]
    let format: OutputFormat
    let useStdin: Bool
    let continueOnError: Bool
    let verbose: Bool
    
    init(
        actions: [CLIAction],
        format: OutputFormat = .text,
        useStdin: Bool = false,
        continueOnError: Bool = false,
        verbose: Bool = false
    ) {
        self.actions = actions
        self.format = format
        self.useStdin = useStdin
        self.continueOnError = continueOnError
        self.verbose = verbose
    }
    
    /// Returns true if this is a non-interactive command
    var isNonInteractive: Bool {
        return !actions.isEmpty
    }
}

// MARK: - Stdin Input

/// Parsed stdin input for chaining operations
struct StdinInput: Codable {
    let windows: [WindowReference]?
    let apps: [AppReference]?
    
    /// Window reference that matches WindowOutput format for piping
    struct WindowReference: Codable {
        let appName: String
        let title: String
        let bundleID: String?
        let processID: Int32?
        let windowID: Int?
        let axElementHash: Int?
        let documentPath: String?
        // Optional fields from WindowOutput - not required for matching
        let frame: FrameReference?
        let isMinimized: Bool?
        let isHidden: Bool?
        
        struct FrameReference: Codable {
            let x: Double
            let y: Double
            let width: Double
            let height: Double
        }
    }
    
    /// App reference that matches AppOutput format for piping
    struct AppReference: Codable {
        let bundleID: String
        let processID: Int32?
        // Optional fields - can come as 'name' or 'localizedName'
        let name: String?
        let localizedName: String?
        let isRunning: Bool?
        let isHidden: Bool?
        let isActive: Bool?
        
        var resolvedName: String {
            localizedName ?? name ?? bundleID
        }
    }
}

