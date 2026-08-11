//  WindowActionHandler.swift
//  DeskJigCLI

import Foundation
import DeskJigShared
import CoreGraphics

/// Handler for window-related CLI actions
final class WindowActionHandler: ActionHandler {

    private weak var executor: ActionExecutor?

    init(executor: ActionExecutor) {
        self.executor = executor
    }

    func canHandle(action: CLIAction) -> Bool {
        switch action {
        case .queryWindows, .getWindowInfo, .activateWindow,
             .moveWindow, .resizeWindow, .minimizeWindow,
             .unminimizeWindow, .closeWindow, .centerWindow,
             .maximizeWindow, .windowsList, .windowsFind, .windowsInfo:
            return true
        default:
            return false
        }
    }

    func execute(action: CLIAction) async -> CommandResult {
        guard let executor = executor else {
            return .failure(action: "window", exitCode: .generalError, error: "Executor deallocated")
        }

        switch action {
        case .queryWindows(let filter):
            return executeQueryWindows(filter: filter, executor: executor)
        case .getWindowInfo(let target):
            return executeGetWindowInfo(target: target, executor: executor)
        case .activateWindow(let target):
            return executeActivateWindow(target: target, executor: executor)
        case .moveWindow(let target, let position, let customPosition, let screenIndex):
            return executeMoveWindow(target: target, position: position, customPosition: customPosition, screenIndex: screenIndex, executor: executor)
        case .resizeWindow(let target, let size):
            return executeResizeWindow(target: target, size: size, executor: executor)
        case .minimizeWindow(let target):
            return executeMinimizeWindow(target: target, executor: executor)
        case .unminimizeWindow(let target):
            return executeUnminimizeWindow(target: target, executor: executor)
        case .closeWindow(let target):
            return executeCloseWindow(target: target, executor: executor)
        case .centerWindow(let target):
            return executeCenterWindow(target: target, executor: executor)
        case .maximizeWindow(let target):
            return executeMaximizeWindow(target: target, executor: executor)
        case .windowsList(let app, let axInfo, let allAxAttributes):
            return executeWindowsList(app: app, axInfo: axInfo, allAxAttributes: allAxAttributes, executor: executor)
        case .windowsFind(let directory, let app):
            return executeWindowsFind(directory: directory, app: app, executor: executor)
        case .windowsInfo(let directory):
            return executeWindowsInfo(directory: directory, executor: executor)
        default:
            return .failure(action: action.description, exitCode: .generalError, error: "Action not handled by WindowActionHandler")
        }
    }

    // MARK: - Query and Info

    private func executeQueryWindows(filter: WindowFilter, executor: ActionExecutor) -> CommandResult {
        var windows = executor.captureWindows(includeHidden: true, includeAXEnrichment: false)

        if let appName = filter.appName {
            windows = windows.filter { $0.appName.localizedCaseInsensitiveContains(appName) }
        }
        if let bundleID = filter.bundleID {
            windows = windows.filter { $0.bundleIdentifier == bundleID }
        }
        if let titleContains = filter.titleContains {
            windows = windows.filter { $0.windowTitle.localizedCaseInsensitiveContains(titleContains) }
        }
        if let titleEquals = filter.titleEquals {
            windows = windows.filter { $0.windowTitle == titleEquals }
        }
        if !filter.includeHidden {
            windows = windows.filter { !$0.isHidden }
        }
        if !filter.includeMinimized {
            windows = windows.filter { !$0.isMinimized }
        }

        let outputs = windows.map { windowInfo in
            let handle = Window.find(windowId: CGWindowID(windowInfo.id))
            return WindowOutput(from: windowInfo, handle: handle)
        }

        if executor.shouldEmitTextOutput {
            let output = OutputFormatter.formatWindowOutputs(outputs, format: executor.format)
            print(output)
        }

        return .success(
            action: "query-windows",
            message: "Found \(windows.count) window(s)",
            data: AnyCodableValue.from(outputs)
        )
    }

    private func executeGetWindowInfo(target: WindowTarget, executor: ActionExecutor) -> CommandResult {
        guard let window = executor.resolveWindowTarget(target) else {
            return .failure(
                action: "get-window-info",
                exitCode: .notFound,
                error: "No window found matching \(target.description)"
            )
        }

        if executor.shouldEmitTextOutput {
            let output = OutputFormatter.formatWindow(window, format: executor.format)
            print(output)
        }

        return .success(
            action: "get-window-info",
            message: window.title ?? window.appName ?? "Window",
            data: AnyCodableValue.from(WindowOutput(from: window))
        )
    }

    // MARK: - Window Actions

    private func executeActivateWindow(target: WindowTarget, executor: ActionExecutor) -> CommandResult {
        guard let window = executor.resolveWindowTarget(target) else {
            return .failure(
                action: "activate-window",
                exitCode: .notFound,
                error: "No window found matching \(target.description)"
            )
        }

        if window.activate() != nil {
            return .success(
                action: "activate-window",
                message: "Activated: \(window.appName ?? "Unknown") - \(window.title ?? "")"
            )
        } else {
            return .failure(
                action: "activate-window",
                exitCode: .actionFailed,
                error: "Failed to activate window"
            )
        }
    }

    private func executeMoveWindow(target: WindowTarget, position: WindowPosition?, customPosition: CustomPosition?, screenIndex: Int?, executor: ActionExecutor) -> CommandResult {
        guard let window = executor.resolveWindowTarget(target) else {
            return .failure(
                action: "move-window",
                exitCode: .notFound,
                error: "No window found matching \(target.description)"
            )
        }

        _ = window.raise()?.activate()

        var success = false
        var positionDesc = ""
        var screenDesc = ""
        let globalMaxY = executor.displayManager.globalMaxY

        func screenFrameInWindowCoordinates(_ screen: FullScreenInfo) -> CGRect {
            let screenFrame = screen.frame
            return CGRect(
                x: screenFrame.origin.x,
                y: globalMaxY - screenFrame.maxY,
                width: screenFrame.width,
                height: screenFrame.height
            )
        }

        if let screenIdx = screenIndex {
            executor.displayManager.refreshScreens()
            let screens = executor.displayManager.screens

            guard screenIdx < screens.count else {
                return .failure(
                    action: "move-window",
                    exitCode: .invalidArguments,
                    error: "Screen index \(screenIdx) out of range (0-\(screens.count - 1) available)"
                )
            }

            let targetScreen = screens[screenIdx]
            let screenFrame = screenFrameInWindowCoordinates(targetScreen)
            screenDesc = " on screen \(screenIdx)"

            if let position = position {
                positionDesc = position.rawValue
                let targetFrame = executor.calculateFrame(for: position, in: screenFrame)
                success = window.setFrame(targetFrame) != nil
            } else if let custom = customPosition {
                let targetFrame = CGRect(
                    x: screenFrame.origin.x + custom.x,
                    y: screenFrame.origin.y + custom.y,
                    width: window.frame?.width ?? 800,
                    height: window.frame?.height ?? 600
                )
                positionDesc = "\(Int(custom.x)),\(Int(custom.y))"
                success = window.setFrame(targetFrame) != nil
            } else {
                return .failure(
                    action: "move-window",
                    exitCode: .invalidArguments,
                    error: "No position specified"
                )
            }
        } else {
            if let position = position {
                positionDesc = position.rawValue
                switch position {
                case .leftHalf:
                    success = window.moveToLeftHalf() != nil
                case .rightHalf:
                    success = window.moveToRightHalf() != nil
                case .topHalf:
                    success = window.moveToTopHalf() != nil
                case .bottomHalf:
                    success = window.moveToBottomHalf() != nil
                case .leftThird:
                    success = window.moveToLeftThird() != nil
                case .centerThird:
                    success = window.moveToCenterThird() != nil
                case .rightThird:
                    success = window.moveToRightThird() != nil
                case .topLeftThird, .topCenterThird, .topRightThird,
                     .bottomLeftThird, .bottomCenterThird, .bottomRightThird:
                    executor.displayManager.refreshScreens()
                    if let windowFrame = window.frame,
                       let screenInfo = executor.displayManager.getBestScreen(for: windowFrame) {
                        let targetFrame = executor.calculateFrame(for: position, in: screenFrameInWindowCoordinates(screenInfo))
                        success = window.setFrame(targetFrame) != nil
                    } else {
                        success = false
                    }
                case .topLeftQuarter:
                    success = window.moveToTopLeftQuarter() != nil
                case .topRightQuarter:
                    success = window.moveToTopRightQuarter() != nil
                case .bottomLeftQuarter:
                    success = window.moveToBottomLeftQuarter() != nil
                case .bottomRightQuarter:
                    success = window.moveToBottomRightQuarter() != nil
                case .center:
                    success = window.center() != nil
                case .maximize:
                    success = window.maximize() != nil
                }
            } else if let custom = customPosition {
                positionDesc = "\(Int(custom.x)),\(Int(custom.y))"
                success = window.moveTo(x: custom.x, y: custom.y) != nil
            } else {
                return .failure(
                    action: "move-window",
                    exitCode: .invalidArguments,
                    error: "No position specified"
                )
            }
        }

        if success {
            let windowDesc = executor.windowDescription(window)
            return .success(
                action: "move-window",
                message: "Moved \(windowDesc) to \(positionDesc)\(screenDesc)"
            )
        } else {
            return .failure(
                action: "move-window",
                exitCode: .actionFailed,
                error: "Failed to move window"
            )
        }
    }

    private func executeResizeWindow(target: WindowTarget, size: CustomSize, executor: ActionExecutor) -> CommandResult {
        guard let window = executor.resolveWindowTarget(target) else {
            return .failure(
                action: "resize-window",
                exitCode: .notFound,
                error: "No window found matching \(target.description)"
            )
        }

        _ = window.raise()?.activate()
        if window.resize(width: size.width, height: size.height) != nil {
            return .success(
                action: "resize-window",
                message: "Resized \(executor.windowDescription(window)) to \(Int(size.width))x\(Int(size.height))"
            )
        } else {
            return .failure(
                action: "resize-window",
                exitCode: .actionFailed,
                error: "Failed to resize window"
            )
        }
    }

    private func executeMinimizeWindow(target: WindowTarget, executor: ActionExecutor) -> CommandResult {
        guard let window = executor.resolveWindowTarget(target) else {
            return .failure(
                action: "minimize-window",
                exitCode: .notFound,
                error: "No window found matching \(target.description)"
            )
        }

        if window.minimize() != nil {
            return .success(
                action: "minimize-window",
                message: "Minimized: \(executor.windowDescription(window))"
            )
        } else {
            return .failure(
                action: "minimize-window",
                exitCode: .actionFailed,
                error: "Failed to minimize window"
            )
        }
    }

    private func executeUnminimizeWindow(target: WindowTarget, executor: ActionExecutor) -> CommandResult {
        guard let window = executor.resolveWindowTarget(target) else {
            return .failure(
                action: "unminimize-window",
                exitCode: .notFound,
                error: "No window found matching \(target.description)"
            )
        }

        if window.unminimize() != nil {
            return .success(
                action: "unminimize-window",
                message: "Unminimized: \(executor.windowDescription(window))"
            )
        } else {
            return .failure(
                action: "unminimize-window",
                exitCode: .actionFailed,
                error: "Failed to unminimize window"
            )
        }
    }

    private func executeCloseWindow(target: WindowTarget, executor: ActionExecutor) -> CommandResult {
        guard let window = executor.resolveWindowTarget(target) else {
            return .failure(
                action: "close-window",
                exitCode: .notFound,
                error: "No window found matching \(target.description)"
            )
        }

        let windowName = executor.windowDescription(window)

        if window.close() != nil {
            return .success(
                action: "close-window",
                message: "Closed: \(windowName)"
            )
        } else {
            return .failure(
                action: "close-window",
                exitCode: .actionFailed,
                error: "Failed to close window"
            )
        }
    }

    private func executeCenterWindow(target: WindowTarget, executor: ActionExecutor) -> CommandResult {
        guard let window = executor.resolveWindowTarget(target) else {
            return .failure(
                action: "center-window",
                exitCode: .notFound,
                error: "No window found matching \(target.description)"
            )
        }

        if window.center() != nil {
            return .success(
                action: "center-window",
                message: "Centered: \(executor.windowDescription(window))"
            )
        } else {
            return .failure(
                action: "center-window",
                exitCode: .actionFailed,
                error: "Failed to center window"
            )
        }
    }

    private func executeMaximizeWindow(target: WindowTarget, executor: ActionExecutor) -> CommandResult {
        guard let window = executor.resolveWindowTarget(target) else {
            return .failure(
                action: "maximize-window",
                exitCode: .notFound,
                error: "No window found matching \(target.description)"
            )
        }

        if window.maximize() != nil {
            return .success(
                action: "maximize-window",
                message: "Maximized: \(executor.windowDescription(window))"
            )
        } else {
            return .failure(
                action: "maximize-window",
                exitCode: .actionFailed,
                error: "Failed to maximize window"
            )
        }
    }

    // MARK: - Window Query by Directory

    private func executeWindowsList(app: String?, axInfo: Bool, allAxAttributes: Bool, executor: ActionExecutor) -> CommandResult {
        // Standard output structure
        struct WindowListOutput: Codable {
            let windows: [WindowEntry]

            struct WindowEntry: Codable {
                let app: String
                let bundleId: String
                let pid: Int32
                let title: String?
                let frame: FrameInfo?
                let documentPath: String?  // AX document path (nil if not exposed by app)

                struct FrameInfo: Codable {
                    let x: Double
                    let y: Double
                    let width: Double
                    let height: Double
                }
            }
        }

        // Extended output structure with full AX data (when --ax-info flag is used)
        struct WindowListExtendedOutput: Codable {
            let windows: [WindowEntryExtended]

            struct WindowEntryExtended: Codable {
                let app: String
                let bundleId: String
                let pid: Int32
                let title: String?
                let frame: FrameInfo?
                let ax: AXInfo  // Extended AX data

                struct FrameInfo: Codable {
                    let x: Double
                    let y: Double
                    let width: Double
                    let height: Double
                }

                struct AXInfo: Codable {
                    let documentPath: String?   // AX document path (nil if empty/not exposed)
                    let isMain: Bool            // AXMain - is this the main window
                    let isFocused: Bool         // AXFocused - is this window focused
                    let isMinimized: Bool       // AXMinimized
                    let isHidden: Bool          // App hidden state
                    let identifier: String?     // AXIdentifier (useful for Xcode, Ghostty)
                    let subrole: String?        // AXSubrole (e.g., "AXStandardWindow", "AXDialog")
                }
            }
        }

        let appsToQuery: [(name: String, bundleID: String)]
        if let appAlias = app?.lowercased() {
            if let bundleID = AppTarget.knownAliases[appAlias] {
                let displayName: String
                switch appAlias {
                case "ghostty":
                    displayName = "Ghostty"
                case "cursor":
                    displayName = "Cursor"
                case "codex":
                    displayName = "Codex"
                case "vscode":
                    displayName = "VS Code"
                case "terminal":
                    displayName = "Terminal"
                case "iterm", "iterm2":
                    displayName = "iTerm"
                case "kitty":
                    displayName = "kitty"
                case "alacritty":
                    displayName = "Alacritty"
                default:
                    displayName = appAlias.capitalized
                }
                appsToQuery = [(name: displayName, bundleID: bundleID)]
            } else {
                return .failure(
                    action: "windows list",
                    exitCode: .invalidArguments,
                    error: "Unknown app alias '\(appAlias)'. Use: ghostty, cursor, codex, vscode, terminal, iterm, kitty, alacritty"
                )
            }
        } else {
            appsToQuery = [
                ("Ghostty", "com.mitchellh.ghostty"),
                ("Cursor", "com.todesktop.230313mzl4w4u92"),
                ("Codex", "com.openai.codex"),
                ("Terminal", "com.apple.Terminal"),
                ("iTerm", "com.googlecode.iterm2"),
                ("kitty", "net.kovidgoyal.kitty"),
                ("Alacritty", "org.alacritty"),
                ("VS Code", "com.microsoft.VSCode")
            ]
        }

        // Helper to get effective document path (nil if empty string)
        func effectiveDocPath(_ window: WindowHandle) -> String? {
            let docPath = window.documentPath
            return (docPath?.isEmpty == true) ? nil : docPath
        }

        // Helper to get AX attribute as string
        func getAXString(_ window: WindowHandle, _ attribute: String) -> String? {
            guard let element = window.axElement else { return nil }
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
            return value as? String
        }

        // Helper to get AX attribute as bool
        func getAXBool(_ window: WindowHandle, _ attribute: String) -> Bool {
            guard let element = window.axElement else { return false }
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return false }
            return (value as? Bool) ?? false
        }

        // Helper to get all AX attribute names
        func getAXAttributeNames(_ window: WindowHandle) -> [String] {
            guard let element = window.axElement else { return [] }
            var names: CFArray?
            guard AXUIElementCopyAttributeNames(element, &names) == .success,
                  let attributeNames = names as? [String] else { return [] }
            return attributeNames
        }

        // Helper to format any AX value as AnyCodableValue
        func formatAXValue(_ value: CFTypeRef) -> AnyCodableValue {
            let typeID = CFGetTypeID(value)

            // Each branch has already matched the runtime CF/AX type ID for its cast.
            if typeID == CFStringGetTypeID() {
                let str = unsafeBitCast(value, to: CFString.self) as String
                return .string(str.isEmpty ? "(empty)" : str)
            } else if typeID == CFBooleanGetTypeID() {
                return .bool(CFBooleanGetValue(unsafeBitCast(value, to: CFBoolean.self)))
            } else if typeID == CFNumberGetTypeID() {
                var intValue: Int64 = 0
                CFNumberGetValue(unsafeBitCast(value, to: CFNumber.self), .sInt64Type, &intValue)
                return .int(Int(intValue))
            } else if typeID == CFArrayGetTypeID() {
                let array = unsafeBitCast(value, to: CFArray.self)
                return .string("[\(CFArrayGetCount(array)) items]")
            } else if typeID == CFURLGetTypeID() {
                let url = unsafeBitCast(value, to: CFURL.self)
                return .string((CFURLGetString(url) as String?) ?? "(url)")
            } else if typeID == AXValueGetTypeID() {
                let axValue = unsafeBitCast(value, to: AXValue.self)
                switch AXValueGetType(axValue) {
                case .cgPoint:
                    var point = CGPoint.zero
                    AXValueGetValue(axValue, .cgPoint, &point)
                    return .dictionary(["x": .double(Double(point.x)), "y": .double(Double(point.y))])
                case .cgSize:
                    var size = CGSize.zero
                    AXValueGetValue(axValue, .cgSize, &size)
                    return .dictionary(["width": .double(Double(size.width)), "height": .double(Double(size.height))])
                case .cgRect:
                    var rect = CGRect.zero
                    AXValueGetValue(axValue, .cgRect, &rect)
                    return .dictionary([
                        "x": .double(Double(rect.origin.x)),
                        "y": .double(Double(rect.origin.y)),
                        "width": .double(Double(rect.width)),
                        "height": .double(Double(rect.height))
                    ])
                default:
                    return .string("(AXValue)")
                }
            } else if typeID == AXUIElementGetTypeID() {
                // Get role of child element
                let childElement = unsafeBitCast(value, to: AXUIElement.self)
                var roleRef: CFTypeRef?
                if AXUIElementCopyAttributeValue(childElement, kAXRoleAttribute as CFString, &roleRef) == .success,
                   let role = roleRef as? String {
                    return .string("(AXUIElement: \(role))")
                }
                return .string("(AXUIElement)")
            } else {
                return .string("(unknown type)")
            }
        }

        // Helper to get all AX attributes as dictionary
        func getAllAXAttributes(_ window: WindowHandle) -> [String: AnyCodableValue] {
            guard let element = window.axElement else { return [:] }
            var result: [String: AnyCodableValue] = [:]

            let names = getAXAttributeNames(window)
            for name in names {
                var value: CFTypeRef?
                if AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success,
                   let val = value {
                    result[name] = formatAXValue(val)
                }
            }
            return result
        }

        // Handle --all-ax-attributes flag: dump ALL AX attributes
        if allAxAttributes {
            var windowsData: [AnyCodableValue] = []

            for (name, bundleID) in appsToQuery {
                let windows = Window.allAcrossProcesses(forBundleID: bundleID, filter: .all)
                for window in windows {
                    let axAttrs = getAllAXAttributes(window)

                    let windowData: [String: AnyCodableValue] = [
                        "app": .string(name),
                        "bundleId": .string(bundleID),
                        "pid": .int(Int(window.processID ?? 0)),
                        "title": .string(window.title ?? "(no title)"),
                        "axAttributeCount": .int(getAXAttributeNames(window).count),
                        "axAttributes": .dictionary(axAttrs)
                    ]

                    windowsData.append(.dictionary(windowData))
                }
            }

            let message = "Found \(windowsData.count) window(s) with all AX attributes"

            return .success(
                action: "windows list",
                message: message,
                data: .dictionary(["windows": .array(windowsData)])
            )
        }

        if axInfo {
            // Extended output with full AX data
            var allWindows: [WindowListExtendedOutput.WindowEntryExtended] = []

            for (name, bundleID) in appsToQuery {
                let windows = Window.allAcrossProcesses(forBundleID: bundleID, filter: .all)
                for window in windows {
                    let frameInfo: WindowListExtendedOutput.WindowEntryExtended.FrameInfo?
                    if let frame = window.frame {
                        frameInfo = WindowListExtendedOutput.WindowEntryExtended.FrameInfo(
                            x: Double(frame.origin.x),
                            y: Double(frame.origin.y),
                            width: Double(frame.size.width),
                            height: Double(frame.size.height)
                        )
                    } else {
                        frameInfo = nil
                    }

                    let axInfoData = WindowListExtendedOutput.WindowEntryExtended.AXInfo(
                        documentPath: effectiveDocPath(window),
                        isMain: getAXBool(window, kAXMainAttribute as String),
                        isFocused: getAXBool(window, kAXFocusedAttribute as String),
                        isMinimized: window.isMinimized,
                        isHidden: window.isHidden,
                        identifier: getAXString(window, kAXIdentifierAttribute as String),
                        subrole: getAXString(window, kAXSubroleAttribute as String)
                    )

                    allWindows.append(WindowListExtendedOutput.WindowEntryExtended(
                        app: name,
                        bundleId: bundleID,
                        pid: window.processID ?? 0,
                        title: window.title,
                        frame: frameInfo,
                        ax: axInfoData
                    ))
                }
            }

            let output = WindowListExtendedOutput(windows: allWindows)
            let windowsWithDoc = allWindows.filter { $0.ax.documentPath != nil }.count
            let message = "Found \(allWindows.count) window(s) with extended AX info (\(windowsWithDoc) with document path)"

            return .success(
                action: "windows list",
                message: message,
                data: AnyCodableValue.from(output)
            )
        } else {
            // Standard output
            var allWindows: [WindowListOutput.WindowEntry] = []

            for (name, bundleID) in appsToQuery {
                let windows = Window.allAcrossProcesses(forBundleID: bundleID, filter: .all)
                for window in windows {
                    let frameInfo: WindowListOutput.WindowEntry.FrameInfo?
                    if let frame = window.frame {
                        frameInfo = WindowListOutput.WindowEntry.FrameInfo(
                            x: Double(frame.origin.x),
                            y: Double(frame.origin.y),
                            width: Double(frame.size.width),
                            height: Double(frame.size.height)
                        )
                    } else {
                        frameInfo = nil
                    }

                    allWindows.append(WindowListOutput.WindowEntry(
                        app: name,
                        bundleId: bundleID,
                        pid: window.processID ?? 0,
                        title: window.title,
                        frame: frameInfo,
                        documentPath: effectiveDocPath(window)
                    ))
                }
            }

            let output = WindowListOutput(windows: allWindows)

            // Build message with AX document data availability info
            let windowsWithDoc = allWindows.filter { $0.documentPath != nil }.count
            let message: String
            if allWindows.isEmpty {
                message = "No windows found"
            } else if windowsWithDoc == allWindows.count {
                message = "Found \(allWindows.count) window(s) (all with AX document data)"
            } else if windowsWithDoc == 0 {
                message = "Found \(allWindows.count) window(s) (no AX document data available)"
            } else {
                message = "Found \(allWindows.count) window(s) (\(windowsWithDoc) with AX document data)"
            }

            return .success(
                action: "windows list",
                message: message,
                data: AnyCodableValue.from(output)
            )
        }
    }

    private func executeWindowsFind(directory: String, app: String?, executor: ActionExecutor) -> CommandResult {
        struct WindowFindOutput: Codable {
            let found: Bool
            let matchCount: Int
            let isAmbiguous: Bool
            let window: WindowFindInfoOutput?
            let allMatches: [MatchInfo]?

            struct MatchInfo: Codable {
                let app: String
                let title: String?
                let confidence: String
                let matchedBy: String
                let details: String?
                let hasDocumentPath: Bool  // Indicates if AX document path was available
            }
        }

        let expandedPath = (directory as NSString).expandingTildeInPath

        let appsToQuery: [(name: String, launcher: any AppLauncher)]
        if let appAlias = app?.lowercased() {
            switch appAlias {
            case "ghostty":
                appsToQuery = [("Ghostty", OpenByPathAppLauncher.ghostty())]
            case "cursor":
                appsToQuery = [("Cursor", OpenByPathAppLauncher.cursor())]
            case "codex":
                appsToQuery = [("Codex", OpenByPathAppLauncher.codex())]
            case "terminal":
                appsToQuery = [("Terminal", OpenByPathAppLauncher.terminal())]
            case "iterm", "iterm2":
                appsToQuery = [("iTerm", OpenByPathAppLauncher.iterm())]
            case "kitty":
                appsToQuery = [("kitty", OpenByPathAppLauncher.kitty())]
            case "alacritty":
                appsToQuery = [("Alacritty", OpenByPathAppLauncher.alacritty())]
            case "vscode":
                appsToQuery = [("VS Code", OpenByPathAppLauncher.vscode())]
            default:
                return .failure(
                    action: "windows find",
                    exitCode: .invalidArguments,
                    error: "Unknown app alias '\(appAlias)'. Use: ghostty, cursor, codex, terminal, iterm, kitty, alacritty, vscode"
                )
            }
        } else {
            appsToQuery = [
                ("Ghostty", OpenByPathAppLauncher.ghostty()),
                ("Cursor", OpenByPathAppLauncher.cursor()),
                ("Codex", OpenByPathAppLauncher.codex()),
                ("Terminal", OpenByPathAppLauncher.terminal()),
                ("iTerm", OpenByPathAppLauncher.iterm()),
                ("kitty", OpenByPathAppLauncher.kitty()),
                ("Alacritty", OpenByPathAppLauncher.alacritty()),
                ("VS Code", OpenByPathAppLauncher.vscode())
            ]
        }

        var allMatches: [(name: String, match: WindowMatch, launcher: any AppLauncher)] = []

        for (name, launcher) in appsToQuery {
            let semaphore = DispatchSemaphore(value: 0)
            var matchResult: WindowMatchResult = .empty

            Task {
                matchResult = await launcher.findWindowsMatching(directory: expandedPath)
                semaphore.signal()
            }
            semaphore.wait()

            for match in matchResult.matches {
                allMatches.append((name: name, match: match, launcher: launcher))
            }
        }

        allMatches.sort { $0.match.confidence > $1.match.confidence }

        // Helper to get effective document path (nil if empty string)
        func effectiveDocPath(_ window: WindowHandle) -> String? {
            let docPath = window.documentPath
            return (docPath?.isEmpty == true) ? nil : docPath
        }

        let matchInfos: [WindowFindOutput.MatchInfo] = allMatches.map { item in
            WindowFindOutput.MatchInfo(
                app: item.name,
                title: item.match.window.title,
                confidence: item.match.confidence.rawValue,
                matchedBy: item.match.matchedBy.rawValue,
                details: item.match.details,
                hasDocumentPath: effectiveDocPath(item.match.window) != nil
            )
        }

        guard let best = allMatches.first else {
            let output = WindowFindOutput(
                found: false,
                matchCount: 0,
                isAmbiguous: false,
                window: nil,
                allMatches: nil
            )
            return CommandResult(
                success: true,
                exitCode: .notFound,
                action: "windows find",
                message: "No window found for '\(expandedPath)'",
                data: AnyCodableValue.from(output),
                error: nil
            )
        }

        let isAmbiguous = allMatches.count > 1 && allMatches[0].match.confidence == allMatches[1].match.confidence

        let frameInfo: WindowFindInfoOutput.FrameInfo?
        if let frame = best.match.window.frame {
            frameInfo = WindowFindInfoOutput.FrameInfo(
                x: Double(frame.origin.x),
                y: Double(frame.origin.y),
                width: Double(frame.size.width),
                height: Double(frame.size.height)
            )
        } else {
            frameInfo = nil
        }

        let bestDocPath = effectiveDocPath(best.match.window)

        let output = WindowFindOutput(
            found: true,
            matchCount: allMatches.count,
            isAmbiguous: isAmbiguous,
            window: WindowFindInfoOutput(
                app: best.name,
                bundleId: best.launcher.bundleIdentifier,
                pid: best.match.window.processID ?? 0,
                title: best.match.window.title,
                directory: expandedPath,
                confidence: best.match.confidence.rawValue,
                matchedBy: best.match.matchedBy.rawValue,
                frame: frameInfo,
                documentPath: bestDocPath
            ),
            allMatches: allMatches.count > 1 ? matchInfos : nil
        )

        let message: String
        if isAmbiguous {
            message = "Warning: \(allMatches.count) ambiguous matches for '\(expandedPath)'"
        } else {
            message = "Found \(best.name) window for '\(expandedPath)' (\(best.match.confidence) confidence via \(best.match.matchedBy))"
        }

        return .success(
            action: "windows find",
            message: message,
            data: AnyCodableValue.from(output)
        )
    }

    private func executeWindowsInfo(directory: String, executor: ActionExecutor) -> CommandResult {
        // This is a simpler version that just returns info about windows for a directory
        // Delegate to windowsFind for now
        return executeWindowsFind(directory: directory, app: nil, executor: executor)
    }
}
