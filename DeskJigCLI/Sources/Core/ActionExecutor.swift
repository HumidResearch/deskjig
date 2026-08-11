//  ActionExecutor.swift
//  DeskJigCLI

import Foundation
import DeskJigShared
import AppKit
import CoreGraphics
import ApplicationServices

// MARK: - Action Executor

/// Executes CLI actions and manages the execution pipeline.
class ActionExecutor {
    
    // MARK: - Dependencies (internal for handler access)

    internal let workspaceManager: SharedWorkspaceManager
    internal let applicationManager: ApplicationManager
    internal let displayManager: DisplayManager
    internal let format: OutputFormat
    internal let verbose: Bool
    internal let shouldPrintTextOutput: Bool

    internal var shouldEmitTextOutput: Bool {
        format == .text && shouldPrintTextOutput
    }

    // MARK: - Stdin Data

    internal var stdinInput: StdinInput?

    // MARK: - Handlers

    private var handlers: [ActionHandler] = []

    // MARK: - Initialization

    init(
        workspaceManager: SharedWorkspaceManager,
        applicationManager: ApplicationManager,
        displayManager: DisplayManager,
        format: OutputFormat = .text,
        verbose: Bool = false,
        shouldPrintTextOutput: Bool = true
    ) {
        self.workspaceManager = workspaceManager
        self.applicationManager = applicationManager
        self.displayManager = displayManager
        self.format = format
        self.verbose = verbose
        self.shouldPrintTextOutput = shouldPrintTextOutput

        configureFluentServices()
        registerHandlers()
    }

    private func registerHandlers() {
        handlers = [
            WorkspaceActionHandler(executor: self),
            WindowActionHandler(executor: self),
            AppActionHandler(executor: self),
            ChromeActionHandler(executor: self),
            QuickSwitchActionHandler(executor: self),
            OpenActionHandler(executor: self),
            LogActionHandler(executor: self)
        ]
    }

    private func configureFluentServices() {
        let axService = AXWindowService.shared
        
        FluentServices.configure(
            axWindowService: axService,
            displayManager: displayManager,
            applicationManager: applicationManager
        )
        
        App.register("Figma", bundleID: "com.figma.Desktop")
        App.register("Chrome", bundleID: "com.google.Chrome", alternateBundleIDs: [
            "com.google.Chrome.canary",
            "com.google.Chrome.beta"
        ])
        App.register("Safari", bundleID: "com.apple.Safari")
        App.register("Discord", bundleID: "com.hnc.Discord")
        App.register("Xcode", bundleID: "com.apple.dt.Xcode")
        App.register("Cursor", bundleID: "com.todesktop.230313mzl4w4u92")
        App.register("Codex", bundleID: "com.openai.codex")
        App.register("Linear", bundleID: "com.linear")
        App.register("Claude", bundleID: "com.anthropic.claudefordesktop")
        App.register("Ghostty", bundleID: "com.mitchellh.ghostty")
        App.register("Notes", bundleID: "com.apple.Notes")
        App.register("Finder", bundleID: "com.apple.finder")
        App.register("Terminal", bundleID: "com.apple.Terminal")
        App.register("kitty", bundleID: "net.kovidgoyal.kitty")
        App.register("Alacritty", bundleID: "org.alacritty")
    }
    
    // MARK: - Stdin Handling
    
    func loadStdinInput() {
        let isATTY = isatty(STDIN_FILENO) == 1
        
        if isATTY {
            if verbose {
                print("Debug: stdin is a terminal, skipping stdin read")
            }
            return
        }
        
        var stdinData = Data()
        while let line = readLine() {
            stdinData.append(contentsOf: line.utf8)
            stdinData.append(contentsOf: "\n".utf8)
        }
        
        guard !stdinData.isEmpty else {
            if verbose {
                print("Debug: stdin was a pipe but no data received")
            }
            return
        }

        let decoder = JSONDecoder()

        if let json = try? JSONSerialization.jsonObject(with: stdinData) {
            if let array = json as? [[String: Any]] {
                if array.first?["appName"] != nil {
                    if let windows = try? decoder.decode([StdinInput.WindowReference].self, from: stdinData) {
                        stdinInput = StdinInput(windows: windows, apps: nil)
                        if verbose {
                            print("Loaded stdin input: \(windows.count) windows (array format)")
                        }
                        return
                    }
                } else if array.first?["bundleID"] != nil {
                    if let apps = try? decoder.decode([StdinInput.AppReference].self, from: stdinData) {
                        stdinInput = StdinInput(windows: nil, apps: apps)
                        if verbose {
                            print("Loaded stdin input: \(apps.count) apps (array format)")
                        }
                        return
                    }
                }
            } else if let dict = json as? [String: Any] {
                if dict["windows"] != nil || dict["apps"] != nil {
                    if let parsed = try? decoder.decode(StdinInput.self, from: stdinData),
                       (parsed.windows != nil && !parsed.windows!.isEmpty) ||
                       (parsed.apps != nil && !parsed.apps!.isEmpty) {
                        stdinInput = parsed
                        if verbose {
                            print("Loaded stdin input: \(stdinInput?.windows?.count ?? 0) windows, \(stdinInput?.apps?.count ?? 0) apps")
                        }
                        return
                    }
                } else if dict["appName"] != nil {
                    if let window = try? decoder.decode(StdinInput.WindowReference.self, from: stdinData) {
                        stdinInput = StdinInput(windows: [window], apps: nil)
                        if verbose {
                            print("Loaded stdin input: 1 window (single object format) - \(window.appName)")
                        }
                        return
                    }
                } else if dict["bundleID"] != nil {
                    if let app = try? decoder.decode(StdinInput.AppReference.self, from: stdinData) {
                        stdinInput = StdinInput(windows: nil, apps: [app])
                        if verbose {
                            print("Loaded stdin input: 1 app (single object format)")
                        }
                        return
                    }
                }
            }
        }

        if verbose {
            print("Warning: Failed to parse stdin as any known JSON format")
            if let rawString = String(data: stdinData, encoding: .utf8) {
                print("  Raw stdin: \(rawString.prefix(200))")
            }
        }
    }
    
    // MARK: - Batch Execution
    
    func execute(_ actions: [CLIAction], continueOnError: Bool) async -> BatchResult {
        var results: [CommandResult] = []
        
        for action in actions {
            let result = await executeSingle(action)
            results.append(result)
            
            if !result.success && !continueOnError {
                break
            }
        }
        
        let successCount = results.filter { $0.success }.count
        let failureCount = results.filter { !$0.success }.count

        return BatchResult(
            totalActions: results.count,
            successCount: successCount,
            failureCount: failureCount,
            results: results
        )
    }
    
    func executeSingle(_ action: CLIAction) async -> CommandResult {
        if verbose {
            print("Executing: \(action.description)")
        }

        for handler in handlers where handler.canHandle(action: action) {
            return await handler.execute(action: action)
        }

        switch action {
        case .listWorkspaces, .workspaceCreateFromSpec, .workspaceInfo, .deleteWorkspace, .workspaceEdit,
             .workspaceWindowList, .workspaceWindowUpdate, .workspaceWindowAdd, .workspaceWindowRemove,
             .restoreWorkspace, .restoreWorkspaceFile, .workspaceImportFile,
             .debugRestoreLoop, .createTestWorkspaces,
             .createRichWorkspace, .dumpWindows, .listDisplays:
            return .failure(action: action.description, exitCode: .generalError, error: "Handler not found")

        case .queryWindows, .getWindowInfo, .activateWindow,
             .moveWindow, .resizeWindow, .minimizeWindow,
             .unminimizeWindow, .closeWindow, .centerWindow,
             .maximizeWindow, .windowsList, .windowsFind, .windowsInfo:
            return .failure(action: action.description, exitCode: .generalError, error: "Handler not found")

        case .listRunningApps, .queryApps, .launchApp,
             .activateApp, .hideApp, .unhideApp, .terminateApp,
             .hideAllApps, .unhideAllApps:
            return .failure(action: action.description, exitCode: .generalError, error: "Handler not found")
            
        case .listChromeWindows, .launchChromeProfile, .openChromeTabs,
             .switchChromeTab, .exportChromeTabs:
            return .failure(action: action.description, exitCode: .generalError, error: "Handler not found")

        case .quickSwitchListDirectories:
            return .failure(action: action.description, exitCode: .generalError, error: "Handler not found")

        case .openApp,
             .launchCursorPositioned,
             .launchGhosttyPositioned,
             .launchTerminalPositioned,
             .launchKittyPositioned,
             .launchAlacrittyPositioned:
            return .failure(action: action.description, exitCode: .generalError, error: "Handler not found")

        case .listRunIds, .showRunId:
            return .failure(action: action.description, exitCode: .generalError, error: "Handler not found")
        }
    }

    // MARK: - Output Helpers
    
    func printResult(_ result: CommandResult) {
        print(OutputFormatter.format(result, format: format))
    }
    
    func printBatchResult(_ batch: BatchResult) {
        print(OutputFormatter.format(batch, format: format))
    }
    
    // MARK: - Window Target Resolution (internal for handler access)

    internal func resolveWindowTarget(_ target: WindowTarget) -> WindowHandle? {
        switch target {
        case .byWindowId(let windowId):
            return Window.find(windowId: CGWindowID(windowId))
        case .byAxHash(let axHash):
            return Window.all(filter: .all).first { $0.axElementHash == axHash }
        case .byTitle(let title):
            return Window.find(title: title)
        case .byTitleContaining(let text):
            return Window.find(titleContaining: text)
        case .byApp(let appName):
            return Window.find(appName: appName)
        case .byBundleID(let bundleID):
            return Window.find(bundleID: bundleID)
        case .topmost:
            return Window.topmost()
        case .all:
            return Window.all().first
        case .fromStdin:
            guard let windowRef = stdinInput?.windows?.first else { return nil }
            return findWindowFromReference(windowRef)
        }
    }
    
    internal func resolveAllWindowTargets(_ target: WindowTarget) -> [WindowHandle] {
        switch target {
        case .byWindowId(let windowId):
            if let window = Window.find(windowId: CGWindowID(windowId)) {
                return [window]
            }
            return []
        case .byAxHash(let axHash):
            return Window.all(filter: .all).filter { $0.axElementHash == axHash }
        case .byTitle(let title):
            if let window = Window.find(title: title) {
                return [window]
            }
            return []
        case .byTitleContaining(let text):
            return Window.all(titleContaining: text)
        case .byApp(let appName):
            return Window.all(for: appName)
        case .byBundleID(let bundleID):
            return Window.all(forBundleID: bundleID)
        case .topmost:
            if let window = Window.topmost() {
                return [window]
            }
            return []
        case .all:
            return Window.all()
        case .fromStdin:
            guard let windowRefs = stdinInput?.windows else { return [] }
            return windowRefs.compactMap { findWindowFromReference($0) }
        }
    }
    
    internal func resolveAppTarget(_ target: WindowTarget) -> AppHandle? {
        switch target {
        case .byApp(let appName):
            return App.find(name: appName)
        case .byBundleID(let bundleID):
            return App.find(bundleID: bundleID)
        case .fromStdin:
            guard let appRef = stdinInput?.apps?.first else { return nil }
            return App.find(bundleID: appRef.bundleID)
        default:
            if let window = resolveWindowTarget(target),
               let bundleID = window.bundleIdentifier {
                return App.find(bundleID: bundleID)
            }
            return nil
        }
    }
}

// MARK: - Window Capture Helpers

extension ActionExecutor {
    internal func captureWindows(
        includeHidden: Bool = true,
        includeAXEnrichment: Bool = false
    ) -> [WindowInfo] {
        let runId = "cli_\(UUID().uuidString.prefix(8))"
        let semaphore = DispatchSemaphore(value: 0)
        var result: [WindowInfo] = []

        Task.detached {
            result = await SystemSnapshotCapture.captureWindowInfos(
                runId: runId,
                includeHidden: includeHidden,
                includeAXEnrichment: includeAXEnrichment
            )
            semaphore.signal()
        }

        semaphore.wait()
        return result
    }
}

// MARK: - Shared Window Helper Methods

extension ActionExecutor {
    
    internal func calculateFrame(for position: WindowPosition, in screenFrame: CGRect) -> CGRect {
        let x = screenFrame.origin.x
        let y = screenFrame.origin.y
        let w = screenFrame.width
        let h = screenFrame.height

        switch position {
        case .leftHalf:
            return CGRect(x: x, y: y, width: w / 2, height: h)
        case .rightHalf:
            return CGRect(x: x + w / 2, y: y, width: w / 2, height: h)
        case .topHalf:
            return CGRect(x: x, y: y, width: w, height: h / 2)
        case .bottomHalf:
            return CGRect(x: x, y: y + h / 2, width: w, height: h / 2)
        case .leftThird:
            return CGRect(x: x, y: y, width: w / 3, height: h)
        case .centerThird:
            return CGRect(x: x + w / 3, y: y, width: w / 3, height: h)
        case .rightThird:
            return CGRect(x: x + 2 * w / 3, y: y, width: w / 3, height: h)
        case .topLeftThird:
            return CGRect(x: x, y: y, width: w / 3, height: h / 2)
        case .topCenterThird:
            return CGRect(x: x + w / 3, y: y, width: w / 3, height: h / 2)
        case .topRightThird:
            return CGRect(x: x + 2 * w / 3, y: y, width: w / 3, height: h / 2)
        case .bottomLeftThird:
            return CGRect(x: x, y: y + h / 2, width: w / 3, height: h / 2)
        case .bottomCenterThird:
            return CGRect(x: x + w / 3, y: y + h / 2, width: w / 3, height: h / 2)
        case .bottomRightThird:
            return CGRect(x: x + 2 * w / 3, y: y + h / 2, width: w / 3, height: h / 2)
        case .topLeftQuarter:
            return CGRect(x: x, y: y, width: w / 2, height: h / 2)
        case .topRightQuarter:
            return CGRect(x: x + w / 2, y: y, width: w / 2, height: h / 2)
        case .bottomLeftQuarter:
            return CGRect(x: x, y: y + h / 2, width: w / 2, height: h / 2)
        case .bottomRightQuarter:
            return CGRect(x: x + w / 2, y: y + h / 2, width: w / 2, height: h / 2)
        case .center:
            let centerW = w * 0.6
            let centerH = h * 0.6
            return CGRect(x: x + (w - centerW) / 2, y: y + (h - centerH) / 2, width: centerW, height: centerH)
        case .maximize:
            return screenFrame
        }
    }
    
    internal func windowDescription(_ window: WindowHandle) -> String {
        let appName = window.appName ?? "Unknown"
        if let title = window.title, !title.isEmpty, title != appName {
            return "\(appName) - \(title)"
        }
        return appName
    }

    internal func findWindowFromReference(_ ref: StdinInput.WindowReference) -> WindowHandle? {
        if let windowId = ref.windowID {
            return Window.find(windowId: CGWindowID(windowId))
        }
        if let axHash = ref.axElementHash,
           let window = Window.all(filter: .all).first(where: { $0.axElementHash == axHash }) {
            return window
        }

        let appWindows: [WindowHandle]
        if let bundleID = ref.bundleID {
            appWindows = Window.all(forBundleID: bundleID)
        } else {
            appWindows = Window.all(for: ref.appName)
        }

        guard !appWindows.isEmpty else { return nil }

        if let refFrame = ref.frame {
            if let match = appWindows.first(where: { window in
                guard let windowFrame = window.frame else { return false }
                return abs(windowFrame.origin.x - refFrame.x) < 2 &&
                       abs(windowFrame.origin.y - refFrame.y) < 2 &&
                       abs(windowFrame.width - refFrame.width) < 2 &&
                       abs(windowFrame.height - refFrame.height) < 2
            }) {
                return match
            }

            if !ref.title.isEmpty {
                let titleMatches = appWindows.filter { $0.title == ref.title }
                if titleMatches.count == 1 {
                    return titleMatches.first
                }
                if let closest = titleMatches.min(by: { w1, w2 in
                    frameDistance(w1.frame, refFrame) < frameDistance(w2.frame, refFrame)
                }) {
                    return closest
                }
            }
        }

        if !ref.title.isEmpty,
           let match = appWindows.first(where: { $0.title == ref.title }) {
            return match
        }

        return appWindows.first
    }

    internal func frameDistance(_ windowFrame: CGRect?, _ refFrame: StdinInput.WindowReference.FrameReference) -> Double {
        guard let wf = windowFrame else { return Double.infinity }
        let dx = wf.origin.x - refFrame.x
        let dy = wf.origin.y - refFrame.y
        let dw = wf.width - refFrame.width
        let dh = wf.height - refFrame.height
        return sqrt(dx * dx + dy * dy + dw * dw + dh * dh)
    }
}
