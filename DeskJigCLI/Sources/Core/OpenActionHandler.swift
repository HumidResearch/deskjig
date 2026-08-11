//  OpenActionHandler.swift
//  DeskJigCLI

import Foundation
import DeskJigShared

/// Handler for open and launch CLI actions
final class OpenActionHandler: ActionHandler {

    private weak var executor: ActionExecutor?

    init(executor: ActionExecutor) {
        self.executor = executor
    }

    func canHandle(action: CLIAction) -> Bool {
        switch action {
        case .openApp,
             .launchCursorPositioned,
             .launchGhosttyPositioned,
             .launchTerminalPositioned,
             .launchKittyPositioned,
             .launchAlacrittyPositioned:
            return true
        default:
            return false
        }
    }

    func execute(action: CLIAction) async -> CommandResult {
        guard let executor = executor else {
            return .failure(action: "open", exitCode: .generalError, error: "Executor deallocated")
        }

        switch action {
        case .openApp(let target, let directory, let position, let screen, let forceNew, let titleOverride):
            return executeOpenApp(target: target, directory: directory, position: position, screen: screen, forceNew: forceNew, titleOverride: titleOverride, executor: executor)
        case .launchCursorPositioned(let path, let position, let screen):
            return executeLaunchCursorPositioned(path: path, position: position, screen: screen, executor: executor)
        case .launchGhosttyPositioned(let path, let position, let screen):
            return executeLaunchGhosttyPositioned(path: path, position: position, screen: screen, executor: executor)
        case .launchTerminalPositioned(let path, let title, let position, let screen):
            return executeLaunchTerminalPositioned(path: path, title: title, position: position, screen: screen, executor: executor)
        case .launchKittyPositioned(let path, let title, let position, let screen):
            return executeLaunchKittyPositioned(path: path, title: title, position: position, screen: screen, executor: executor)
        case .launchAlacrittyPositioned(let path, let title, let position, let screen):
            return executeLaunchAlacrittyPositioned(path: path, title: title, position: position, screen: screen, executor: executor)
        default:
            return .failure(action: action.description, exitCode: .generalError, error: "Action not handled by OpenActionHandler")
        }
    }

    // MARK: - Implementation

    private func executeLaunchCursorPositioned(path: String, position: String, screen: Int?, executor: ActionExecutor) -> CommandResult {
        // Validate directory exists
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return .failure(
                action: "launch-cursor-positioned",
                exitCode: .invalidArguments,
                error: "Directory does not exist: \(path)"
            )
        }

        // Parse position string (use DeskJigShared.WindowPosition for the fluent API)
        guard let windowPosition = DeskJigShared.WindowPosition.parse(position) else {
            return .failure(
                action: "launch-cursor-positioned",
                exitCode: .invalidArguments,
                error: "Invalid position: \(position). Use presets like 'left-half', 'right-half', 'top-right-quarter', etc."
            )
        }

        if executor.shouldEmitTextOutput {
            print("Launching Cursor with directory '\(path)' at position '\(position)'...")
        }

        // Run async code synchronously using a semaphore
        let semaphore = DispatchSemaphore(value: 0)
        var launchedWindow: LaunchedWindow?
        var error: Error?

        Task {
            do {
                launchedWindow = try await DirectoryApp.cursor()
                    .inDirectory(path)
                    .atPosition(windowPosition, screen: screen)
                    .launch()
            } catch let err {
                error = err
            }
            semaphore.signal()
        }

        semaphore.wait()

        if let _ = launchedWindow {
            let output = LaunchOutput(
                app: "Cursor",
                path: path,
                position: position,
                screen: screen ?? 0
            )

            return .success(
                action: "launch-cursor-positioned",
                message: "Launched Cursor at '\(path)' positioned to '\(position)'",
                data: AnyCodableValue.from(output)
            )
        } else {
            return .failure(
                action: "launch-cursor-positioned",
                exitCode: .actionFailed,
                error: error?.localizedDescription ?? "Unknown error"
            )
        }
    }

    private func executeLaunchGhosttyPositioned(path: String, position: String, screen: Int?, executor: ActionExecutor) -> CommandResult {
        // Validate directory exists
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return .failure(
                action: "launch-ghostty-positioned",
                exitCode: .invalidArguments,
                error: "Directory does not exist: \(path)"
            )
        }

        // Parse position string (use DeskJigShared.WindowPosition for the fluent API)
        guard let windowPosition = DeskJigShared.WindowPosition.parse(position) else {
            return .failure(
                action: "launch-ghostty-positioned",
                exitCode: .invalidArguments,
                error: "Invalid position: \(position). Use presets like 'left-half', 'right-half', 'top-right-quarter', etc."
            )
        }

        if executor.shouldEmitTextOutput {
            print("Launching Ghostty with directory '\(path)' at position '\(position)'...")
        }

        // Run async code synchronously using a semaphore
        let semaphore = DispatchSemaphore(value: 0)
        var launchedWindow: LaunchedWindow?
        var error: Error?

        Task {
            do {
                let basename = URL(fileURLWithPath: path).lastPathComponent
                let windowTitle = "\(BundleIdentity.terminalTitleTokenPrefix):\(basename):0"
                launchedWindow = try await DirectoryApp.ghostty()
                    .withWindowTitle(windowTitle)
                    .inDirectory(path)
                    .atPosition(windowPosition, screen: screen)
                    .launch()
            } catch let err {
                error = err
            }
            semaphore.signal()
        }

        semaphore.wait()

        if let _ = launchedWindow {
            let output = LaunchOutput(
                app: "Ghostty",
                path: path,
                position: position,
                screen: screen ?? 0
            )

            return .success(
                action: "launch-ghostty-positioned",
                message: "Launched Ghostty at '\(path)' positioned to '\(position)'",
                data: AnyCodableValue.from(output)
            )
        } else {
            return .failure(
                action: "launch-ghostty-positioned",
                exitCode: .actionFailed,
                error: error?.localizedDescription ?? "Unknown error"
            )
        }
    }

    private func executeLaunchTerminalPositioned(
        path: String,
        title: String?,
        position: String?,
        screen: Int?,
        executor: ActionExecutor
    ) -> CommandResult {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return .failure(
                action: "launch-terminal-positioned",
                exitCode: .invalidArguments,
                error: "Directory does not exist: \(path)"
            )
        }

        let windowPosition: DeskJigShared.WindowPosition?
        if let position {
            guard let parsed = DeskJigShared.WindowPosition.parse(position) else {
                return .failure(
                    action: "launch-terminal-positioned",
                    exitCode: .invalidArguments,
                    error: "Invalid position: \(position). Use presets like 'left-half', 'right-half', 'top-right-quarter', etc."
                )
            }
            windowPosition = parsed
        } else {
            windowPosition = nil
        }

        if executor.shouldEmitTextOutput {
            print("Launching Terminal with directory '\(path)'...")
        }

        let semaphore = DispatchSemaphore(value: 0)
        var launchedWindow: LaunchedWindow?
        var error: Error?

        Task {
            do {
                let basename = URL(fileURLWithPath: path).lastPathComponent
                let effectiveTitle = title ?? "\(BundleIdentity.terminalTitleTokenPrefix):\(basename):0"
                var spec = DirectoryApp.terminal()
                    .withWindowTitle(effectiveTitle)
                    .inDirectory(path)

                if let windowPosition {
                    spec = spec.atPosition(windowPosition, screen: screen)
                }

                launchedWindow = try await spec.launch()
            } catch let err {
                error = err
            }
            semaphore.signal()
        }

        semaphore.wait()

        if let _ = launchedWindow {
            let basename = URL(fileURLWithPath: path).lastPathComponent
            let effectiveTitle = title ?? "\(BundleIdentity.terminalTitleTokenPrefix):\(basename):0"
            let output = TitledLaunchOutput(
                app: "Terminal",
                path: path,
                title: effectiveTitle,
                position: position,
                screen: screen ?? 0
            )

            return .success(
                action: "launch-terminal-positioned",
                message: "Launched Terminal at '\(path)'",
                data: AnyCodableValue.from(output)
            )
        }

        return .failure(
            action: "launch-terminal-positioned",
            exitCode: .actionFailed,
            error: error?.localizedDescription ?? "Unknown error"
        )
    }

    private func executeLaunchKittyPositioned(
        path: String,
        title: String?,
        position: String?,
        screen: Int?,
        executor: ActionExecutor
    ) -> CommandResult {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return .failure(
                action: "launch-kitty-positioned",
                exitCode: .invalidArguments,
                error: "Directory does not exist: \(path)"
            )
        }

        let windowPosition: DeskJigShared.WindowPosition?
        if let position {
            guard let parsed = DeskJigShared.WindowPosition.parse(position) else {
                return .failure(
                    action: "launch-kitty-positioned",
                    exitCode: .invalidArguments,
                    error: "Invalid position: \(position). Use presets like 'left-half', 'right-half', 'top-right-quarter', etc."
                )
            }
            windowPosition = parsed
        } else {
            windowPosition = nil
        }

        if executor.shouldEmitTextOutput {
            print("Launching kitty with directory '\(path)'...")
        }

        let semaphore = DispatchSemaphore(value: 0)
        var launchedWindow: LaunchedWindow?
        var error: Error?

        Task {
            do {
                let basename = URL(fileURLWithPath: path).lastPathComponent
                let effectiveTitle = title ?? "\(BundleIdentity.terminalTitleTokenPrefix):\(basename):0"
                var spec = DirectoryApp.kitty()
                    .withWindowTitle(effectiveTitle)
                    .inDirectory(path)

                if let windowPosition {
                    spec = spec.atPosition(windowPosition, screen: screen)
                }

                launchedWindow = try await spec.launch()
            } catch let err {
                error = err
            }
            semaphore.signal()
        }

        semaphore.wait()

        if let _ = launchedWindow {
            let basename = URL(fileURLWithPath: path).lastPathComponent
            let effectiveTitle = title ?? "\(BundleIdentity.terminalTitleTokenPrefix):\(basename):0"
            let output = TitledLaunchOutput(
                app: "kitty",
                path: path,
                title: effectiveTitle,
                position: position,
                screen: screen ?? 0
            )

            return .success(
                action: "launch-kitty-positioned",
                message: "Launched kitty at '\(path)'",
                data: AnyCodableValue.from(output)
            )
        }

        return .failure(
            action: "launch-kitty-positioned",
            exitCode: .actionFailed,
            error: error?.localizedDescription ?? "Unknown error"
        )
    }

    private func executeLaunchAlacrittyPositioned(
        path: String,
        title: String?,
        position: String?,
        screen: Int?,
        executor: ActionExecutor
    ) -> CommandResult {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return .failure(
                action: "launch-alacritty-positioned",
                exitCode: .invalidArguments,
                error: "Directory does not exist: \(path)"
            )
        }

        let windowPosition: DeskJigShared.WindowPosition?
        if let position {
            guard let parsed = DeskJigShared.WindowPosition.parse(position) else {
                return .failure(
                    action: "launch-alacritty-positioned",
                    exitCode: .invalidArguments,
                    error: "Invalid position: \(position). Use presets like 'left-half', 'right-half', 'top-right-quarter', etc."
                )
            }
            windowPosition = parsed
        } else {
            windowPosition = nil
        }

        if executor.shouldEmitTextOutput {
            print("Launching Alacritty with directory '\(path)'...")
        }

        let semaphore = DispatchSemaphore(value: 0)
        var launchedWindow: LaunchedWindow?
        var error: Error?

        Task {
            do {
                let basename = URL(fileURLWithPath: path).lastPathComponent
                let effectiveTitle = title ?? "\(BundleIdentity.terminalTitleTokenPrefix):\(basename):0"
                var spec = DirectoryApp.alacritty()
                    .withWindowTitle(effectiveTitle)
                    .inDirectory(path)

                if let windowPosition {
                    spec = spec.atPosition(windowPosition, screen: screen)
                }

                launchedWindow = try await spec.launch()
            } catch let err {
                error = err
            }
            semaphore.signal()
        }

        semaphore.wait()

        if let _ = launchedWindow {
            let basename = URL(fileURLWithPath: path).lastPathComponent
            let effectiveTitle = title ?? "\(BundleIdentity.terminalTitleTokenPrefix):\(basename):0"
            let output = TitledLaunchOutput(
                app: "Alacritty",
                path: path,
                title: effectiveTitle,
                position: position,
                screen: screen ?? 0
            )

            return .success(
                action: "launch-alacritty-positioned",
                message: "Launched Alacritty at '\(path)'",
                data: AnyCodableValue.from(output)
            )
        }

        return .failure(
            action: "launch-alacritty-positioned",
            exitCode: .actionFailed,
            error: error?.localizedDescription ?? "Unknown error"
        )
    }

    private func executeOpenApp(
        target: AppTarget,
        directory: String,
        position: String?,
        screen: Int,
        forceNew: Bool,
        titleOverride: String?,
        executor: ActionExecutor
    ) -> CommandResult {
        // Expand ~ in path
        let expandedPath = (directory as NSString).expandingTildeInPath

        // Validate directory exists
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: expandedPath, isDirectory: &isDirectory), isDirectory.boolValue else {
            return .failure(
                action: "open",
                exitCode: .invalidArguments,
                error: "Directory does not exist: \(directory)"
            )
        }

        // Resolve bundle ID from target
        guard let bundleID = target.resolvedBundleID() else {
            return .failure(
                action: "open",
                exitCode: .invalidArguments,
                error: "Unknown app target: \(target.description). Use a known alias (ghostty, cursor, codex, terminal, iterm, kitty, alacritty) or specify --bundle-id."
            )
        }

        // Parse position if provided
        let windowPosition: DeskJigShared.WindowPosition?
        if let pos = position {
            guard let parsed = DeskJigShared.WindowPosition.parse(pos) else {
                return .failure(
                    action: "open",
                    exitCode: .invalidArguments,
                    error: "Invalid position: \(pos). Use presets like 'left-half', 'right-half', 'top-right-quarter', etc."
                )
            }
            windowPosition = parsed
        } else {
            windowPosition = nil
        }

        func appDisplayName(for bundleID: String) -> String {
            switch bundleID {
            case OpenByPathBundleIdentifiers.cursor:
                return "Cursor"
            case OpenByPathBundleIdentifiers.codex:
                return "Codex"
            case OpenByPathBundleIdentifiers.ghostty:
                return "Ghostty"
            case OpenByPathBundleIdentifiers.vscode:
                return "VS Code"
            case OpenByPathBundleIdentifiers.xcode:
                return "Xcode"
            case OpenByPathBundleIdentifiers.terminal:
                return "Terminal"
            case OpenByPathBundleIdentifiers.iterm2:
                return "iTerm"
            case OpenByPathBundleIdentifiers.kitty:
                return "kitty"
            case OpenByPathBundleIdentifiers.alacritty:
                return "Alacritty"
            default:
                return bundleID
            }
        }

        func normalizedPath(_ path: String) -> String {
            let expanded = (path as NSString).expandingTildeInPath
            return URL(fileURLWithPath: expanded).standardizedFileURL.path
        }

        let normalizedDirectory = normalizedPath(expandedPath)

        func windowMatchesDirectory(_ window: WindowHandle) -> Bool {
            guard let documentPath = window.documentPath else { return false }
            return normalizedPath(documentPath) == normalizedDirectory
        }

        func windowIdentityKey(_ window: WindowHandle) -> String? {
            guard let frame = window.frame else { return nil }
            let title = window.title ?? ""
            let pid = window.processID ?? 0
            return "\(pid)|\(title)|\(Int(frame.origin.x)),\(Int(frame.origin.y)),\(Int(frame.width)),\(Int(frame.height))"
        }

        // Determine app type and execute
        let isGhostty = bundleID == OpenByPathBundleIdentifiers.ghostty
        let isCursor = bundleID == OpenByPathBundleIdentifiers.cursor
        let isCodex = bundleID == OpenByPathBundleIdentifiers.codex
        let isXcode = bundleID == OpenByPathBundleIdentifiers.xcode
        let isTerminal = bundleID == OpenByPathBundleIdentifiers.terminal
        let isITerm = bundleID == OpenByPathBundleIdentifiers.iterm2
        let isKitty = bundleID == OpenByPathBundleIdentifiers.kitty
        let isAlacritty = bundleID == OpenByPathBundleIdentifiers.alacritty
        let isVSCode = bundleID == OpenByPathBundleIdentifiers.vscode
        let appName = appDisplayName(for: bundleID)

        if executor.shouldEmitTextOutput {
            print("Opening \(appName) with directory '\(expandedPath)'...")
        }

        // Run async code synchronously
        let semaphore = DispatchSemaphore(value: 0)
        var launchedWindow: LaunchedWindow?
        var error: Error?
        var actionTaken = "created"

        func positionWindowIfNeeded(_ window: WindowHandle, aggressive: Bool = false) {
            guard let pos = windowPosition else { return }
            _ = window.raise()?.activate()
            executor.displayManager.refreshScreens()
            let screens = executor.displayManager.screens
            guard screen < screens.count else { return }
            let targetScreen = screens[screen]
            if let cliPosition = WindowPosition(rawValue: pos.rawValue) {
                let screenFrame = targetScreen.frame
                let globalMaxY = executor.displayManager.globalMaxY
                let windowCoordsFrame = CGRect(
                    x: screenFrame.origin.x,
                    y: globalMaxY - screenFrame.maxY,
                    width: screenFrame.width,
                    height: screenFrame.height
                )
                let absoluteFrame = executor.calculateFrame(for: cliPosition, in: windowCoordsFrame)
                // Retry a few times in case the app adjusts size immediately after launch.
                let attempts = aggressive ? 12 : 4
                let delay: TimeInterval = aggressive ? 0.25 : 0.2
                for attempt in 0..<attempts {
                    _ = window.setFrame(absoluteFrame)
                    if attempt < attempts - 1 {
                        Thread.sleep(forTimeInterval: delay)
                    }
                }
            }
        }

        func topmostWindowForApp(bundleID: String, appName: String) -> WindowHandle? {
            let byBundle = Window.allAcrossProcesses(forBundleID: bundleID, filter: .all)
            if let first = byBundle.first {
                return first
            }
            let byName = Window.all(for: appName, filter: .all)
            return byName.first
        }

        Task {
            do {
                if isGhostty {
                    let basename = URL(fileURLWithPath: expandedPath).lastPathComponent
                    let effectiveTitle = titleOverride ?? "\(BundleIdentity.terminalTitleTokenPrefix):\(basename):0"
                    let preLaunchWindows = Window.allAcrossProcesses(forBundleID: bundleID, filter: .all)
                    let preLaunchIdentityKeys = Set(preLaunchWindows.compactMap { windowIdentityKey($0) })

                    // Check for existing window if --new is not specified
                    if !forceNew {
                        // Find ALL matching windows (by title token)
                        let allGhosttyWindows = Window.allAcrossProcesses(forBundleID: bundleID, filter: .all)
                        let matchingWindows = allGhosttyWindows.filter { $0.title?.contains(effectiveTitle) == true }
                        let matchingByPath = matchingWindows.filter { windowMatchesDirectory($0) }

                        if matchingByPath.count > 1 {
                            throw LauncherError.launchFailed(
                                reason: "Multiple Ghostty windows match title '\(effectiveTitle)' and directory '\(expandedPath)' (\(matchingByPath.count) found). Use --new to force a new window or provide a unique --title."
                            )
                        }

                        if let existingWindow = matchingByPath.first {
                            // Reuse existing window - reposition if needed, always raise
                            actionTaken = "reused"
                            positionWindowIfNeeded(existingWindow, aggressive: false)
                            // Always raise and activate reused windows
                            _ = existingWindow.raise()?.activate()
                            launchedWindow = LaunchedWindow(
                                windowHandle: existingWindow,
                                processID: existingWindow.processID ?? 0,
                                directoryPath: expandedPath
                            )
                            semaphore.signal()
                            return
                        }
                    }

                    // No existing window found or --new specified, create new
                    var spec = DirectoryApp.ghostty()
                        .withWindowTitle(effectiveTitle)
                        .inDirectory(expandedPath)

                    if forceNew {
                        spec = spec.allowReuseExisting(false)
                    }

                    if let pos = windowPosition {
                        spec = spec.atPosition(pos, screen: screen)
                    }

                    do {
                        launchedWindow = try await spec.launch()
                    } catch let launchError {
                        if case LauncherError.windowNotFound = launchError {
                            // Fallback: the window may be slow to appear. Poll by title token.
                            let maxAttempts = 24
                            for _ in 0..<maxAttempts {
                                let allWindows = Window.allAcrossProcesses(forBundleID: bundleID, filter: .all)
                                let newWindows = allWindows.filter { window in
                                    if let key = windowIdentityKey(window) {
                                        return !preLaunchIdentityKeys.contains(key)
                                    }
                                    return true
                                }
                                let matchingWindows = newWindows.filter {
                                    ($0.title ?? "").localizedCaseInsensitiveContains(effectiveTitle)
                                }

                                if matchingWindows.count == 1, let match = matchingWindows.first {
                                    actionTaken = "created"
                                    positionWindowIfNeeded(match, aggressive: true)
                                    _ = match.raise()?.activate()
                                    launchedWindow = LaunchedWindow(
                                        windowHandle: match,
                                        processID: match.processID ?? 0,
                                        directoryPath: expandedPath
                                    )
                                    break
                                }

                                if matchingWindows.count > 1 {
                                    error = LauncherError.launchFailed(
                                        reason: "Multiple \(appName) windows match title token '\(effectiveTitle)' (\(matchingWindows.count) found). Close extras or use a unique --title."
                                    )
                                    break
                                }

                                if matchingWindows.isEmpty, newWindows.count == 1, let match = newWindows.first {
                                    actionTaken = "created"
                                    positionWindowIfNeeded(match, aggressive: true)
                                    _ = match.raise()?.activate()
                                    launchedWindow = LaunchedWindow(
                                        windowHandle: match,
                                        processID: match.processID ?? 0,
                                        directoryPath: expandedPath
                                    )
                                    break
                                }

                                if matchingWindows.isEmpty, newWindows.count > 1 {
                                    let byPath = newWindows.filter { windowMatchesDirectory($0) }
                                    if byPath.count == 1, let match = byPath.first {
                                        actionTaken = "created"
                                        positionWindowIfNeeded(match, aggressive: true)
                                        _ = match.raise()?.activate()
                                        launchedWindow = LaunchedWindow(
                                            windowHandle: match,
                                            processID: match.processID ?? 0,
                                            directoryPath: expandedPath
                                        )
                                        break
                                    }
                                }

                                guard await Task.sleepUnlessCancelled(for: .milliseconds(250)) else { break }
                            }

                            if launchedWindow == nil && error == nil {
                                error = launchError
                            }
                        } else {
                            error = launchError
                        }
                    }
                } else if isCursor {
                    let launcher = OpenByPathAppLauncher.cursor()

                    // Check for existing window if --new is not specified
                    if !forceNew {
                        // Use multi-strategy matching with confidence scoring
                        let matchResult = await launcher.findWindowsMatching(directory: expandedPath)

                        if matchResult.count > 0 {
                            // Check for ambiguous matches at the same confidence level
                            if matchResult.isAmbiguous {
                                let matchInfos = matchResult.matches.map { WindowMatchInfo(from: $0) }
                                throw LauncherError.ambiguousMatch(matches: matchInfos)
                            }

                            // Use the best (highest confidence) match
                            if let best = matchResult.bestMatch {
                                actionTaken = "reused"

                                // Reposition if position was explicitly requested
                                if let pos = windowPosition {
                                    if best.confidence == .low && executor.shouldEmitTextOutput {
                                        print("Note: Low-confidence match (\(best.matchedBy)) - repositioning anyway since --position was specified")
                                    }
                                    executor.displayManager.refreshScreens()
                                    let screens = executor.displayManager.screens
                                    if screen < screens.count {
                                        let targetScreen = screens[screen]
                                        let relativeFrame = pos.toRelativeFrame()
                                        let visibleFrame = targetScreen.visibleFrameInWindowCoordinates(globalMaxY: executor.displayManager.globalMaxY)
                                        let absoluteFrame = WindowFrameConverter.toAbsolute(relativeFrame: relativeFrame, screenFrame: visibleFrame)
                                        _ = best.window.setFrame(absoluteFrame)
                                    }
                                }
                                // Always raise and activate reused Cursor windows
                                _ = best.window.raise()?.activate()

                                launchedWindow = LaunchedWindow(
                                    windowHandle: best.window,
                                    processID: best.window.processID ?? 0,
                                    directoryPath: expandedPath
                                )
                                semaphore.signal()
                                return
                            }
                        }
                    }

                    // No existing window found or --new specified, create new
                    var spec = DirectoryApp.cursor()
                        .inDirectory(expandedPath)

                    if forceNew {
                        spec = spec.allowReuseExisting(false)
                    }

                    if let pos = windowPosition {
                        spec = spec.atPosition(pos, screen: screen)
                    }

                    do {
                        launchedWindow = try await spec.launch()
                    } catch let launchError {
                        if case LauncherError.windowNotFound = launchError, forceNew {
                            if let fallback = topmostWindowForApp(bundleID: bundleID, appName: appName) {
                                actionTaken = "created"
                                positionWindowIfNeeded(fallback, aggressive: true)
                                _ = fallback.raise()?.activate()
                                launchedWindow = LaunchedWindow(
                                    windowHandle: fallback,
                                    processID: fallback.processID ?? 0,
                                    directoryPath: expandedPath
                                )
                            } else {
                                error = launchError
                            }
                        } else {
                            error = launchError
                        }
                    }
                } else if isTerminal || isITerm || isKitty || isAlacritty {
                    let basename = URL(fileURLWithPath: expandedPath).lastPathComponent
                    let effectiveTitle = titleOverride ?? "\(BundleIdentity.terminalTitleTokenPrefix):\(basename):0"
                    let preLaunchWindows = Window.allAcrossProcesses(forBundleID: bundleID, filter: .all)
                    let preLaunchIdentityKeys = Set(preLaunchWindows.compactMap { windowIdentityKey($0) })

                    if !forceNew {
                        let allWindows = Window.allAcrossProcesses(forBundleID: bundleID, filter: .all)
                        let matchingWindows = allWindows.filter {
                            ($0.title ?? "").localizedCaseInsensitiveContains(effectiveTitle)
                        }
                        let matchingByPath = matchingWindows.filter { windowMatchesDirectory($0) }

                        if matchingByPath.count > 1 {
                            throw LauncherError.launchFailed(
                                reason: "Multiple \(appName) windows match title '\(effectiveTitle)' and directory '\(expandedPath)' (\(matchingByPath.count) found). Use --new to force a new window or provide a unique --title."
                            )
                        }

                        if let existingWindow = matchingByPath.first {
                            actionTaken = "reused"
                            positionWindowIfNeeded(existingWindow, aggressive: false)
                            _ = existingWindow.raise()?.activate()
                            launchedWindow = LaunchedWindow(
                                windowHandle: existingWindow,
                                processID: existingWindow.processID ?? 0,
                                directoryPath: expandedPath
                            )
                            semaphore.signal()
                            return
                        }
                    }

                    let baseSpec: WindowSpec
                    switch bundleID {
                    case OpenByPathBundleIdentifiers.terminal:
                        baseSpec = DirectoryApp.terminal().withWindowTitle(effectiveTitle)
                    case OpenByPathBundleIdentifiers.iterm2:
                        baseSpec = DirectoryApp.iterm().withWindowTitle(effectiveTitle)
                    case OpenByPathBundleIdentifiers.kitty:
                        baseSpec = DirectoryApp.kitty().withWindowTitle(effectiveTitle)
                    case OpenByPathBundleIdentifiers.alacritty:
                        baseSpec = DirectoryApp.alacritty().withWindowTitle(effectiveTitle)
                    default:
                        baseSpec = DirectoryApp.terminal().withWindowTitle(effectiveTitle)
                    }

                    var spec = baseSpec.inDirectory(expandedPath)
                    if forceNew {
                        spec = spec.allowReuseExisting(false)
                    }
                    if let pos = windowPosition {
                        spec = spec.atPosition(pos, screen: screen)
                    }

                    do {
                        launchedWindow = try await spec.launch()
                    } catch let launchError {
                        if case LauncherError.windowNotFound = launchError {
                            // Fallback: the window may be slow to appear. Poll by title token.
                            let maxAttempts = 24
                            for _ in 0..<maxAttempts {
                                let allWindows = Window.allAcrossProcesses(forBundleID: bundleID, filter: .all)
                                let newWindows = allWindows.filter { window in
                                    if let key = windowIdentityKey(window) {
                                        return !preLaunchIdentityKeys.contains(key)
                                    }
                                    return true
                                }
                                let matchingWindows = newWindows.filter {
                                    ($0.title ?? "").localizedCaseInsensitiveContains(effectiveTitle)
                                }

                                if matchingWindows.count == 1, let match = matchingWindows.first {
                                    actionTaken = "created"
                                    positionWindowIfNeeded(match, aggressive: isAlacritty)
                                    _ = match.raise()?.activate()
                                    launchedWindow = LaunchedWindow(
                                        windowHandle: match,
                                        processID: match.processID ?? 0,
                                        directoryPath: expandedPath
                                    )
                                    break
                                }

                                if matchingWindows.count > 1 {
                                    error = LauncherError.launchFailed(
                                        reason: "Multiple \(appName) windows match title token '\(effectiveTitle)' (\(matchingWindows.count) found). Close extras or use a unique path."
                                    )
                                    break
                                }

                                if matchingWindows.isEmpty, newWindows.count == 1, let match = newWindows.first {
                                    actionTaken = "created"
                                    positionWindowIfNeeded(match, aggressive: isAlacritty)
                                    _ = match.raise()?.activate()
                                    launchedWindow = LaunchedWindow(
                                        windowHandle: match,
                                        processID: match.processID ?? 0,
                                        directoryPath: expandedPath
                                    )
                                    break
                                }

                                if matchingWindows.isEmpty, newWindows.count > 1 {
                                    let byPath = newWindows.filter { windowMatchesDirectory($0) }
                                    if byPath.count == 1, let match = byPath.first {
                                        actionTaken = "created"
                                        positionWindowIfNeeded(match, aggressive: isAlacritty)
                                        _ = match.raise()?.activate()
                                        launchedWindow = LaunchedWindow(
                                            windowHandle: match,
                                            processID: match.processID ?? 0,
                                            directoryPath: expandedPath
                                        )
                                        break
                                    }
                                }

                                guard await Task.sleepUnlessCancelled(for: .milliseconds(250)) else { break }
                            }

                            if launchedWindow == nil && error == nil {
                                error = launchError
                            }
                        } else {
                            error = launchError
                        }
                    }
                } else if isVSCode || isXcode || isCodex {
                    let launcher: OpenByPathAppLauncher = {
                        if isXcode { return OpenByPathAppLauncher.xcode() }
                        if isCodex { return OpenByPathAppLauncher.codex() }
                        return OpenByPathAppLauncher.vscode()
                    }()
                    let basename = URL(fileURLWithPath: expandedPath).lastPathComponent
                    let preLaunchWindows = Window.allAcrossProcesses(forBundleID: bundleID, filter: .all)
                    let preLaunchIdentityKeys = Set(preLaunchWindows.compactMap { windowIdentityKey($0) })

                    if !forceNew {
                        let matchResult = await launcher.findWindowsMatching(directory: expandedPath)

                        if matchResult.count > 0 {
                            if matchResult.isAmbiguous {
                                let matchInfos = matchResult.matches.map { WindowMatchInfo(from: $0) }
                                throw LauncherError.ambiguousMatch(matches: matchInfos)
                            }

                            if let best = matchResult.bestMatch {
                                actionTaken = "reused"

                                if windowPosition != nil {
                                    if best.confidence == .low && executor.shouldEmitTextOutput {
                                        print("Note: Low-confidence match (\(best.matchedBy)) - repositioning anyway since --position was specified")
                                    }
                                    positionWindowIfNeeded(best.window, aggressive: false)
                                }

                                _ = best.window.raise()?.activate()
                                launchedWindow = LaunchedWindow(
                                    windowHandle: best.window,
                                    processID: best.window.processID ?? 0,
                                    directoryPath: expandedPath
                                )
                                semaphore.signal()
                                return
                            }
                        }
                    }

                    var spec: WindowSpec = {
                        if isXcode { return DirectoryApp.xcode() }
                        if isCodex { return DirectoryApp.codex() }
                        return DirectoryApp.vscode()
                    }()
                        .inDirectory(expandedPath)

                    if forceNew {
                        spec = spec.allowReuseExisting(false)
                    }

                    if let pos = windowPosition {
                        spec = spec.atPosition(pos, screen: screen)
                    }

                    do {
                        launchedWindow = try await spec.launch()
                    } catch let launchError {
                        if case LauncherError.windowNotFound = launchError {
                            let maxAttempts = 24
                            for _ in 0..<maxAttempts {
                                let allWindows = Window.allAcrossProcesses(forBundleID: bundleID, filter: .all)
                                let newWindows = allWindows.filter { window in
                                    if let key = windowIdentityKey(window) {
                                        return !preLaunchIdentityKeys.contains(key)
                                    }
                                    return true
                                }

                                let matchingByPath = allWindows.filter { windowMatchesDirectory($0) }
                                let matchingByTitle = allWindows.filter {
                                    ($0.title ?? "").localizedCaseInsensitiveContains(basename)
                                }

                                if matchingByPath.count == 1, let match = matchingByPath.first {
                                    actionTaken = "created"
                                    positionWindowIfNeeded(match, aggressive: false)
                                    _ = match.raise()?.activate()
                                    launchedWindow = LaunchedWindow(
                                        windowHandle: match,
                                        processID: match.processID ?? 0,
                                        directoryPath: expandedPath
                                    )
                                    break
                                }

                                if matchingByTitle.count == 1, let match = matchingByTitle.first {
                                    actionTaken = "created"
                                    positionWindowIfNeeded(match, aggressive: false)
                                    _ = match.raise()?.activate()
                                    launchedWindow = LaunchedWindow(
                                        windowHandle: match,
                                        processID: match.processID ?? 0,
                                        directoryPath: expandedPath
                                    )
                                    break
                                }

                                if newWindows.count == 1, let match = newWindows.first {
                                    actionTaken = "created"
                                    positionWindowIfNeeded(match, aggressive: false)
                                    _ = match.raise()?.activate()
                                    launchedWindow = LaunchedWindow(
                                        windowHandle: match,
                                        processID: match.processID ?? 0,
                                        directoryPath: expandedPath
                                    )
                                    break
                                }

                                if matchingByPath.count > 1 || matchingByTitle.count > 1 || newWindows.count > 1 {
                                    // Keep waiting in case IDE is still opening documents.
                                }

                                guard await Task.sleepUnlessCancelled(for: .milliseconds(250)) else { break }
                            }

                            if launchedWindow == nil && error == nil {
                                // Skip the topmost-window fallback when the task was
                                // cancelled — don't position/claim a window after cancel.
                                if forceNew, !Task.isCancelled, let fallback = topmostWindowForApp(bundleID: bundleID, appName: appName) {
                                    actionTaken = "created"
                                    positionWindowIfNeeded(fallback, aggressive: true)
                                    _ = fallback.raise()?.activate()
                                    launchedWindow = LaunchedWindow(
                                        windowHandle: fallback,
                                        processID: fallback.processID ?? 0,
                                        directoryPath: expandedPath
                                    )
                                } else {
                                    error = launchError
                                }
                            }
                        } else {
                            error = launchError
                        }
                    }
                } else {
                    throw LauncherError.launchFailed(reason: "Unsupported app: \(bundleID)")
                }
            } catch let err {
                error = err
            }
            semaphore.signal()
        }

        semaphore.wait()

        if let launched = launchedWindow {
            positionWindowIfNeeded(launched.windowHandle, aggressive: isAlacritty && actionTaken == "created")
            // Build JSON output
            struct OpenAppOutput: Codable {
                let status: String
                let action: String
                let window: WindowInfoOutput
            }

            let positionInfo: WindowInfoOutput.PositionInfo?
            if let frame = launched.windowHandle.frame {
                positionInfo = WindowInfoOutput.PositionInfo(
                    x: Double(frame.origin.x),
                    y: Double(frame.origin.y),
                    width: Double(frame.size.width),
                    height: Double(frame.size.height)
                )
            } else {
                positionInfo = nil
            }

            let output = OpenAppOutput(
                status: "success",
                action: actionTaken,
                window: WindowInfoOutput(
                    id: "window-\(launched.processID)",
                    title: launched.windowHandle.title,
                    app: appName,
                    bundleId: bundleID,
                    pid: launched.processID,
                    position: positionInfo,
                    screen: screen,
                    directory: expandedPath
                )
            )

            return .success(
                action: "open",
                message: "\(actionTaken.capitalized) \(appName) window at '\(expandedPath)'",
                data: AnyCodableValue.from(output)
            )
        } else {
            return .failure(
                action: "open",
                exitCode: .actionFailed,
                error: error?.localizedDescription ?? "Unknown error"
            )
        }
    }
}
