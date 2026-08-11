//  DirectoryWorkspace.swift
//  DeskJigShared

import Foundation
import AppKit
import CoreGraphics

// MARK: - RestoreProgress

/// Progress events emitted during workspace restoration.
/// Used to update UI and reset watchdog timers.
public enum RestoreProgress: Sendable {
    /// Restoration started
    case started(windowCount: Int)
    /// Starting to restore a specific window
    case windowStarted(index: Int, app: String, directory: String)
    /// A window has been restored (successfully or not)
    case windowCompleted(index: Int, success: Bool)
    /// Restoration finished
    case completed(successCount: Int, failedCount: Int)
}

// MARK: - DirectoryWorkspace

/// A directory-based workspace containing multiple app windows
/// Each window is configured with a directory path and position
public struct DirectoryWorkspace: Codable, Identifiable, Sendable {
    public let id: UUID
    public let name: String
    public let icon: String?
    public let createdAt: Date
    public let lastActivatedAt: Date?
    
    /// The window specifications for this workspace
    /// Note: WindowSpec is not directly Codable due to launcher protocols
    /// We store a serializable representation and reconstruct specs on load
    private let windowConfigs: [WindowConfig]

    // MARK: - WindowConfig Helpers

    internal static func makeWindowConfig(from spec: WindowSpec) -> WindowConfig {
        // Determine app type from launcher
        let appType: WindowConfig.AppType
        switch spec.launcher.bundleIdentifier {
        case OpenByPathBundleIdentifiers.ghostty:
            appType = .ghostty
        case OpenByPathBundleIdentifiers.cursor:
            appType = .cursor
        case OpenByPathBundleIdentifiers.codex:
            appType = .codex
        case OpenByPathBundleIdentifiers.vscode:
            appType = .vscode
        case OpenByPathBundleIdentifiers.terminal:
            appType = .terminal
        case OpenByPathBundleIdentifiers.iterm2:
            appType = .iterm
        case OpenByPathBundleIdentifiers.kitty:
            appType = .kitty
        case OpenByPathBundleIdentifiers.alacritty:
            appType = .alacritty
        case OpenByPathBundleIdentifiers.xcode:
            appType = .xcode
        default:
            // Default to ghostty if unknown
            appType = .ghostty
        }

        return WindowConfig(
            appType: appType,
            directoryPath: spec.directoryPath ?? "",
            position: spec.position,
            screenIndex: spec.screenIndex
        )
    }
    
    // MARK: - WindowConfig (Internal Serializable Representation)

    internal struct WindowConfig: Codable, Sendable {
        let appType: AppType
        let directoryPath: String
        let position: WindowPosition?
        let screenIndex: Int?

        enum AppType: String, Codable {
            case ghostty
            case cursor
            case codex
            case vscode
            case terminal
            case iterm
            case kitty
            case alacritty
            case xcode
        }
    }
    
    // MARK: - Initialization

    internal init(
        id: UUID = UUID(),
        name: String,
        icon: String? = nil,
        createdAt: Date = Date(),
        lastActivatedAt: Date? = nil,
        windowConfigs: [WindowConfig]
    ) {
        self.id = id
        self.name = name
        self.icon = icon
        self.createdAt = createdAt
        self.lastActivatedAt = lastActivatedAt
        self.windowConfigs = windowConfigs
    }
    
    // MARK: - Static Factory Methods
    
    /// Create a new directory workspace builder
    /// - Parameter name: The workspace name
    /// - Returns: A builder for constructing the workspace
    public static func create(_ name: String) -> DirectoryWorkspaceBuilder {
        return DirectoryWorkspaceBuilder(name: name)
    }
    
    /// Load a saved directory workspace by name
    /// - Parameter name: The workspace name
    /// - Returns: The workspace if found, nil otherwise
    public static func named(_ name: String) -> DirectoryWorkspace? {
        return DirectoryWorkspaceManager.shared.getWorkspace(named: name)
    }
    
    /// Load a saved directory workspace by ID
    /// - Parameter id: The workspace ID
    /// - Returns: The workspace if found, nil otherwise
    public static func withID(_ id: UUID) -> DirectoryWorkspace? {
        return DirectoryWorkspaceManager.shared.getWorkspace(withID: id)
    }
    
    /// List all saved directory workspaces
    /// - Returns: Array of saved workspaces
    public static func list() -> [DirectoryWorkspace] {
        return DirectoryWorkspaceManager.shared.savedWorkspaces
    }
    
    // MARK: - Window Specs

    /// Get the window specifications for this workspace
    /// Reconstructs WindowSpec instances from stored configs
    public func windowSpecs() -> [WindowSpec] {
        // Track indices per (appType, path) for terminal apps that use legacy terminal titles
        var ghosttyIndexByPath: [String: Int] = [:]
        var terminalIndexByPath: [String: Int] = [:]
        var itermIndexByPath: [String: Int] = [:]
        var kittyIndexByPath: [String: Int] = [:]
        var alacrittyIndexByPath: [String: Int] = [:]

        return windowConfigs.map { config in
            let launcher: any AppLauncher
            switch config.appType {
            case .ghostty:
                launcher = OpenByPathAppLauncher.ghostty()
            case .cursor:
                launcher = OpenByPathAppLauncher.cursor()
            case .codex:
                launcher = OpenByPathAppLauncher.codex()
            case .vscode:
                launcher = OpenByPathAppLauncher.vscode()
            case .terminal:
                launcher = OpenByPathAppLauncher.terminal()
            case .iterm:
                launcher = OpenByPathAppLauncher.iterm()
            case .kitty:
                launcher = OpenByPathAppLauncher.kitty()
            case .alacritty:
                launcher = OpenByPathAppLauncher.alacritty()
            case .xcode:
                launcher = OpenByPathAppLauncher.xcode()
            }

            // Compute windowTitle and windowIndex for terminal apps
            let normalizedPath = URL(fileURLWithPath: config.directoryPath).standardizedFileURL.path
            let basename = URL(fileURLWithPath: normalizedPath).lastPathComponent

            let windowTitle: String?
            let windowIndex: Int?

            switch config.appType {
            case .ghostty:
                let index = ghosttyIndexByPath[normalizedPath] ?? 0
                ghosttyIndexByPath[normalizedPath] = index + 1
                windowTitle = "\(BundleIdentity.terminalTitleTokenPrefix):\(basename):\(index)"
                windowIndex = index
            case .terminal:
                let index = terminalIndexByPath[normalizedPath] ?? 0
                terminalIndexByPath[normalizedPath] = index + 1
                windowTitle = "\(BundleIdentity.terminalTitleTokenPrefix):\(basename):\(index)"
                windowIndex = index
            case .iterm:
                let index = itermIndexByPath[normalizedPath] ?? 0
                itermIndexByPath[normalizedPath] = index + 1
                windowTitle = "\(BundleIdentity.terminalTitleTokenPrefix):\(basename):\(index)"
                windowIndex = index
            case .kitty:
                let index = kittyIndexByPath[normalizedPath] ?? 0
                kittyIndexByPath[normalizedPath] = index + 1
                windowTitle = "\(BundleIdentity.terminalTitleTokenPrefix):\(basename):\(index)"
                windowIndex = index
            case .alacritty:
                let index = alacrittyIndexByPath[normalizedPath] ?? 0
                alacrittyIndexByPath[normalizedPath] = index + 1
                windowTitle = "\(BundleIdentity.terminalTitleTokenPrefix):\(basename):\(index)"
                windowIndex = index
            case .cursor, .codex, .vscode, .xcode:
                // IDEs don't use legacy terminal titles
                windowTitle = nil
                windowIndex = nil
            }

            return WindowSpec(
                launcher: launcher,
                directoryPath: config.directoryPath,
                position: config.position,
                screenIndex: config.screenIndex,
                windowTitle: windowTitle,
                windowIndex: windowIndex
            )
        }
    }

    /// Convert this DirectoryWorkspace into a standard Workspace.
    public func toWorkspace(screens: [WorkspaceScreen]) -> Workspace {
        let windows = buildWorkspaceWindows()
        return Workspace.migrated(
            id: id,
            name: name,
            icon: icon,
            createdAt: createdAt,
            lastActivatedAt: lastActivatedAt,
            windows: windows,
            screens: screens.isEmpty ? nil : screens
        )
    }
    
    // MARK: - Launch
    
    /// Launch all windows in this workspace
    /// - Returns: Result containing success/failure counts and details
    public func launch() async throws -> LaunchResult {
        DeskJigLog.debug(
            .workspace,
            "DirectoryWorkspace: Launching '\(name)' with \(windowConfigs.count) windows"
        )
        
        // Update activation time
        let updatedWorkspace = withActivationTime(Date())
        DirectoryWorkspaceManager.shared.updateWorkspace(updatedWorkspace)
        
        var launchedWindows: [LaunchedWindow] = []
        var failures: [(spec: WindowSpec, error: Error)] = []
        
        let specs = windowSpecs()
        
        for spec in specs {
            do {
                let launchedWindow = try await spec.launch()
                launchedWindows.append(launchedWindow)
                DeskJigLog.debug(
                    .workspace,
                    "DirectoryWorkspace: Launched window in \(launchedWindow.directoryPath)"
                )
            } catch {
                failures.append((spec: spec, error: error))
                DeskJigLog.error(.workspace, "DirectoryWorkspace: Failed to launch window: \(error)")
            }
        }
        
        let result = LaunchResult(
            successCount: launchedWindows.count,
            failedCount: failures.count,
            launchedWindows: launchedWindows,
            failures: failures
        )
        
        DeskJigLog.debug(
            .workspace,
            "DirectoryWorkspace: Launch complete - \(result.successCount) succeeded, \(result.failedCount) failed"
        )
        return result
    }

    // MARK: - Restore (OpenByPath Restoration Service)

    /// Restore all windows in this workspace using the OpenByPath Restoration Service.
    ///
    /// - Parameters:
    ///   - persist: Whether to save the workspace update to disk. Pass `false` for temporary workspaces (e.g. Quick Switch).
    ///   - hideAllApps: Override for hiding all apps before restore. When `nil`, uses the default (`false`).
    ///   - logger: Optional callback for emitting verbose, deterministic logs (e.g. CLI `--verbose`).
    ///   - onProgress: Optional callback for progress updates. Used by UI to reset watchdog timers.
    /// - Returns: Result containing success/failure counts and details.
    public func restore(
        persist: Bool = true,
        hideAllApps: Bool? = nil,
        logger: ((String) -> Void)? = nil,
        onProgress: ((RestoreProgress) -> Void)? = nil
    ) async throws -> LaunchResult {
        let specs = windowSpecs()
        let total = specs.count

        DeskJigLog.debug(
            .workspace,
            "DirectoryWorkspace: Restoring '\(name)' with \(total) windows via FluentWorkspaceRestorer"
        )
        logCallStack("DirectoryWorkspace.restore name=\(name) windows=\(total)")
        logger?("dw.restore workspace=\"\(name)\" windows=\(total) method=fluent")
        onProgress?(.started(windowCount: total))

        // Update activation time
        let updatedWorkspace = withActivationTime(Date())
        if persist {
            DirectoryWorkspaceManager.shared.updateWorkspace(updatedWorkspace)
        }

        // Convert to standard Workspace for FluentWorkspaceRestorer
        let displayManager = DisplayManager()
        displayManager.refreshScreens()
        let screens = WorkspaceDisplayTopology.effectiveScreens(from: displayManager).map { screen in
            WorkspaceScreen(from: screen)
        }
        let workspace = toWorkspace(screens: screens)
        logger?("dw.restore converted to Workspace with \(workspace.windows.count) windows")

        // Resolve hideAllApps: explicit parameter > UserDefaults > false
        let resolvedHideAllApps = hideAllApps ?? UserDefaults.standard.bool(forKey: "restoreHideAllApps")

        // Use FluentWorkspaceRestorer (same as GUI)
        let restorer = FluentWorkspaceRestorer.shared
        let options = RestorationOptions(
            lockTimeout: .seconds(10),
            matchConfiguration: .default,
            maxConcurrency: 4,
            taskTimeout: .seconds(30),
            phaseExecutionMode: .automatic,
            includeChromeCapture: false,
            includeAXEnrichment: true,
            hideAllAppsBeforeRestore: resolvedHideAllApps,
            chromeFetchMethod: .appleScript,
            terminalFetchMethod: .axWithLsofFallback,
            ideFetchMethod: .cursorStateWithAXFallback,
            chromeMatchMethod: .chromeProfile,
            maxRetries: 1
        )

        let fluentResult = try await restorer.restore(
            workspace: workspace,
            options: options
        )

        // Convert result
        let launchResult = LaunchResult(
            successCount: fluentResult.windowsRestored,
            failedCount: fluentResult.windowsFailed,
            launchedWindows: [],
            failures: []
        )

        logger?("dw.restore workspace=\"\(name)\" status=complete succeeded=\(launchResult.successCount) failed=\(launchResult.failedCount) runId=\(fluentResult.runId)")
        DeskJigLog.debug(
            .workspace,
            "DirectoryWorkspace: Restore complete via FluentWorkspaceRestorer - \(launchResult.successCount) succeeded, \(launchResult.failedCount) failed, runId=\(fluentResult.runId)"
        )
        onProgress?(.completed(successCount: launchResult.successCount, failedCount: launchResult.failedCount))
        return launchResult
    }

    private func buildWorkspaceWindows() -> [WorkspaceWindow] {
        var ghosttyIndexByPath: [String: Int] = [:]
        var terminalIndexByPath: [String: Int] = [:]
        var itermIndexByPath: [String: Int] = [:]
        var kittyIndexByPath: [String: Int] = [:]
        var alacrittyIndexByPath: [String: Int] = [:]

        return windowConfigs.map { config in
            let normalizedPath = URL(fileURLWithPath: config.directoryPath).standardizedFileURL.path
            let basename = URL(fileURLWithPath: normalizedPath).lastPathComponent

            let (bundleId, appName): (String, String) = {
                switch config.appType {
                case .ghostty:
                    return (OpenByPathBundleIdentifiers.ghostty, "Ghostty")
                case .cursor:
                    return (OpenByPathBundleIdentifiers.cursor, "Cursor")
                case .codex:
                    return (OpenByPathBundleIdentifiers.codex, "Codex")
                case .vscode:
                    return (OpenByPathBundleIdentifiers.vscode, "VS Code")
                case .terminal:
                    return (OpenByPathBundleIdentifiers.terminal, "Terminal")
                case .iterm:
                    return (OpenByPathBundleIdentifiers.iterm2, "iTerm")
                case .kitty:
                    return (OpenByPathBundleIdentifiers.kitty, "kitty")
                case .alacritty:
                    return (OpenByPathBundleIdentifiers.alacritty, "Alacritty")
                case .xcode:
                    return (OpenByPathBundleIdentifiers.xcode, "Xcode")
                }
            }()

            let relativeFrame = config.position?.toRelativeFrame() ?? WindowPosition.center.toRelativeFrame()
            let screenIndex = config.screenIndex ?? 0

            let windowTitle: String
            switch config.appType {
            case .ghostty:
                let index = ghosttyIndexByPath[normalizedPath] ?? 0
                ghosttyIndexByPath[normalizedPath] = index + 1
                windowTitle = "\(BundleIdentity.terminalTitleTokenPrefix):\(basename):\(index)"
            case .terminal:
                let index = terminalIndexByPath[normalizedPath] ?? 0
                terminalIndexByPath[normalizedPath] = index + 1
                windowTitle = "\(BundleIdentity.terminalTitleTokenPrefix):\(basename):\(index)"
            case .iterm:
                let index = itermIndexByPath[normalizedPath] ?? 0
                itermIndexByPath[normalizedPath] = index + 1
                windowTitle = "\(BundleIdentity.terminalTitleTokenPrefix):\(basename):\(index)"
            case .kitty:
                let index = kittyIndexByPath[normalizedPath] ?? 0
                kittyIndexByPath[normalizedPath] = index + 1
                windowTitle = "\(BundleIdentity.terminalTitleTokenPrefix):\(basename):\(index)"
            case .alacritty:
                let index = alacrittyIndexByPath[normalizedPath] ?? 0
                alacrittyIndexByPath[normalizedPath] = index + 1
                windowTitle = "\(BundleIdentity.terminalTitleTokenPrefix):\(basename):\(index)"
            case .cursor, .codex, .vscode, .xcode:
                windowTitle = basename
            }

            return WorkspaceWindow(
                bundleIdentifier: bundleId,
                appName: appName,
                windowTitle: windowTitle,
                openPath: normalizedPath,
                screenIndex: screenIndex,
                relativeFrame: relativeFrame
            )
        }
    }
    
    // MARK: - Copy Methods
    
    /// Create a copy with updated activation time
    public func withActivationTime(_ time: Date) -> DirectoryWorkspace {
        DirectoryWorkspace(
            id: id,
            name: name,
            icon: icon,
            createdAt: createdAt,
            lastActivatedAt: time,
            windowConfigs: windowConfigs
        )
    }
    
    /// Create a copy with a new name
    public func withName(_ newName: String) -> DirectoryWorkspace {
        DirectoryWorkspace(
            id: id,
            name: newName,
            icon: icon,
            createdAt: createdAt,
            lastActivatedAt: lastActivatedAt,
            windowConfigs: windowConfigs
        )
    }
    
    /// Create a copy with a new icon
    public func withIcon(_ newIcon: String?) -> DirectoryWorkspace {
        DirectoryWorkspace(
            id: id,
            name: name,
            icon: newIcon,
            createdAt: createdAt,
            lastActivatedAt: lastActivatedAt,
            windowConfigs: windowConfigs
        )
    }

    /// Create a copy with updated window specifications.
    public func withWindowSpecs(_ specs: [WindowSpec]) -> DirectoryWorkspace {
        DirectoryWorkspace(
            id: id,
            name: name,
            icon: icon,
            createdAt: createdAt,
            lastActivatedAt: lastActivatedAt,
            windowConfigs: specs.map(Self.makeWindowConfig(from:))
        )
    }

    /// Create a copy with an added window specification.
    public func addingWindow(_ spec: WindowSpec) -> DirectoryWorkspace {
        var updated = windowConfigs
        updated.append(Self.makeWindowConfig(from: spec))
        return DirectoryWorkspace(
            id: id,
            name: name,
            icon: icon,
            createdAt: createdAt,
            lastActivatedAt: lastActivatedAt,
            windowConfigs: updated
        )
    }

    /// Create a copy with a window removed at index.
    public func removingWindow(at index: Int) throws -> DirectoryWorkspace {
        guard index >= 0 && index < windowConfigs.count else {
            throw DirectoryWorkspaceError.windowIndexOutOfBounds(index: index)
        }
        var updated = windowConfigs
        updated.remove(at: index)
        return DirectoryWorkspace(
            id: id,
            name: name,
            icon: icon,
            createdAt: createdAt,
            lastActivatedAt: lastActivatedAt,
            windowConfigs: updated
        )
    }
}

// MARK: - DirectoryWorkspace Errors

public enum DirectoryWorkspaceError: Error, LocalizedError {
    case windowIndexOutOfBounds(index: Int)

    public var errorDescription: String? {
        switch self {
        case .windowIndexOutOfBounds(let index):
            return "Window index \(index) is out of bounds"
        }
    }
}

// MARK: - Restore Helpers

extension DirectoryWorkspace {
    private struct RestoredWindowEntry {
        let index: Int
        let spec: WindowSpec
        let launched: LaunchedWindow
    }

    private func restoreWindow(
        _ spec: WindowSpec,
        index: Int,
        displayManager: DisplayManager,
        logger: ((String) -> Void)?
    ) async throws -> LaunchedWindow {
        guard let rawDirectory = spec.directoryPath, !rawDirectory.isEmpty else {
            throw LauncherError.directoryNotFound(path: "No directory specified")
        }

        let directoryPath = (rawDirectory as NSString).expandingTildeInPath

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directoryPath, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw LauncherError.directoryNotFound(path: directoryPath)
        }

        let position = spec.position
        let screenIndex = spec.screenIndex ?? 0
        let appName = spec.launcher.appName
        let bundleID = spec.launcher.bundleIdentifier

        logger?(
            "dw.restore spec=\(index) status=begin app=\"\(appName)\" bundle=\"\(bundleID)\" directory=\"\(directoryPath)\" position=\"\(position?.rawValue ?? "none")\" screen=\(screenIndex)"
        )
        DeskJigLog.info(.workspace, 
            "RESTORE-DEBUG: [DirectoryWorkspace] restoreWindow spec=\(index) app=\(appName) " +
            "bundle=\(bundleID) dir='\(directoryPath)'"
        )
        logCallStack("DirectoryWorkspace.restoreWindow spec=\(index) app=\(appName)")

        if bundleID == OpenByPathBundleIdentifiers.ghostty {
            return try await restoreGhosttyWindow(
                spec,
                index: index,
                directoryPath: directoryPath,
                position: position,
                displayManager: displayManager,
                logger: logger
            )
        }

        return try await restoreDirectoryMatchedWindow(
            spec,
            index: index,
            directoryPath: directoryPath,
            position: position,
            displayManager: displayManager,
            logger: logger
        )
    }

    private func restoreGhosttyWindow(
        _ spec: WindowSpec,
        index: Int,
        directoryPath: String,
        position: WindowPosition?,
        displayManager: DisplayManager,
        logger: ((String) -> Void)?
    ) async throws -> LaunchedWindow {
        // Use directory basename + window index for matching with the legacy terminal title token
        // The spec index maps directly to the window index for consistent identification
        let directoryBasename = URL(fileURLWithPath: directoryPath).lastPathComponent
        let windowIndex = spec.windowIndex ?? index  // Use spec's index if set, otherwise use enumerate index
        let expectedTitle = spec.windowTitle ?? "\(BundleIdentity.terminalTitleTokenPrefix):\(directoryBasename):\(windowIndex)"

        logger?("dw.restore spec=\(index) match.strategy=directoryTitle title=\"\(expectedTitle)\"")

        // Find existing Ghostty window by indexed title
        let matchResult = findGhosttyMatches(
            directoryPath: directoryPath,
            expectedTitle: expectedTitle
        )

        if matchResult.isAmbiguous {
            throw LauncherError.ambiguousMatch(matches: matchResult.matches.map(WindowMatchInfo.init(from:)))
        }

        if let existing = matchResult.bestMatch?.window {
            logger?(
                "dw.restore spec=\(index) match.result=found matchedBy=title confidence=high pid=\(existing.processID ?? 0) title=\"\(existing.title ?? "nil")\" doc=\"\(existing.documentPath ?? "nil")\""
            )

            _ = existing.restore()

            var targetFrame: CGRect?
            if let position {
                let frame = try applyPosition(
                    position,
                    to: existing,
                    screenIndex: spec.screenIndex,
                    displayManager: displayManager
                )
                targetFrame = frame
                logger?("dw.restore spec=\(index) position.result=applied frame=\"\(frame.debugDescription)\"")
            } else {
                targetFrame = existing.frame
                logger?("dw.restore spec=\(index) position.result=skipped")
            }

            // Activate the correct process by PID, then raise window
            // IMPORTANT: Ghostty uses separate processes per window, so we must activate
            // the specific process that owns this window, not just any Ghostty process
            if let windowPID = existing.processID,
               let app = NSRunningApplication(processIdentifier: pid_t(windowPID)) {
                if #available(macOS 14.0, *) {
                    _ = app.activate()
                } else {
                    _ = app.activate(options: [.activateIgnoringOtherApps])
                }
                logger?("dw.restore spec=\(index) activate.pid=\(windowPID)")
            } else {
                logger?("dw.restore spec=\(index) activate.pid=failed (no PID)")
            }
            // Raise window using AXWindowService directly (FluentServices not configured in app)
            if let axWindow = existing.window {
                let raiseSuccess = AXWindowService.shared.raise(axWindow)
                logger?("dw.restore spec=\(index) raise.success=\(raiseSuccess)")
            }
            await ensureGhosttyWindowTopmost(
                windowHandle: existing,
                expectedTitle: expectedTitle,
                expectedDocumentPath: directoryPath,
                targetFrame: targetFrame,
                logger: logger,
                specIndex: index
            )
            logger?("dw.restore spec=\(index) action=reused raiseActivate=done status=ok")

            return LaunchedWindow(
                windowHandle: existing,
                processID: existing.processID ?? 0,
                directoryPath: directoryPath
            )
        }

        logger?("dw.restore spec=\(index) match.result=none")

        // Launch new Ghostty window with indexed title
        let launchSpec: WindowSpec = {
            var updated = spec
                .inDirectory(directoryPath)
                .withWindowTitle(expectedTitle)
                .withIndex(windowIndex)

            if let position {
                updated = updated.atPosition(position, screen: spec.screenIndex)
            }

            return updated
        }()

        let launched = try await launchSpec.launch()
        logger?("dw.restore spec=\(index) action=created pid=\(launched.processID)")

        var targetFrame: CGRect?
        if let position {
            let frame = try applyPosition(
                position,
                to: launched.windowHandle,
                screenIndex: spec.screenIndex,
                displayManager: displayManager
            )
            targetFrame = frame
            logger?("dw.restore spec=\(index) position.result=applied frame=\"\(frame.debugDescription)\"")
        }

        // Activate the correct process by PID, then raise window
        if let windowPID = launched.windowHandle.processID,
           let app = NSRunningApplication(processIdentifier: pid_t(windowPID)) {
            if #available(macOS 14.0, *) {
                _ = app.activate()
            } else {
                _ = app.activate(options: [.activateIgnoringOtherApps])
            }
            logger?("dw.restore spec=\(index) activate.pid=\(windowPID)")
        } else {
            logger?("dw.restore spec=\(index) activate.pid=failed (no PID)")
        }
        // Raise window using AXWindowService directly (FluentServices not configured in app)
        if let axWindow = launched.windowHandle.window {
            let raiseSuccess = AXWindowService.shared.raise(axWindow)
            logger?("dw.restore spec=\(index) raise.success=\(raiseSuccess)")
        }
        await ensureGhosttyWindowTopmost(
            windowHandle: launched.windowHandle,
            expectedTitle: expectedTitle,
            expectedDocumentPath: directoryPath,
            targetFrame: targetFrame ?? launched.windowHandle.frame,
            logger: logger,
            specIndex: index
        )
        logger?("dw.restore spec=\(index) raiseActivate=done status=ok")

        return launched
    }

    private func findGhosttyMatches(
        directoryPath: String,
        expectedTitle: String
    ) -> WindowMatchResult {
        let normalizedPath = normalizePath(directoryPath) ?? directoryPath
        let windows = Window.allAcrossProcesses(
            forBundleID: OpenByPathBundleIdentifiers.ghostty,
            filter: .all
        )

        var matches: [WindowMatch] = []

        for window in windows {
            if let docPath = normalizePath(window.documentPath),
               docPath == normalizedPath,
               window.title == expectedTitle {
                matches.append(WindowMatch(
                    window: window,
                    confidence: .high,
                    matchedBy: .documentPath,
                    details: "documentPath + title match: \(expectedTitle)"
                ))
            }
        }

        if matches.isEmpty {
            let titleMatches = windows.filter { $0.title == expectedTitle }
            matches.append(contentsOf: titleMatches.map {
                WindowMatch(
                    window: $0,
                    confidence: .high,
                    matchedBy: .titleExact,
                    details: "title match: \(expectedTitle)"
                )
            })
        }

        return WindowMatchResult(matches: matches)
    }

    private func restoreDirectoryMatchedWindow(
        _ spec: WindowSpec,
        index: Int,
        directoryPath: String,
        position: WindowPosition?,
        displayManager: DisplayManager,
        logger: ((String) -> Void)?
    ) async throws -> LaunchedWindow {
        logCallStack("DirectoryWorkspace.restoreDirectoryMatchedWindow spec=\(index)")
        let matchResult = await spec.launcher.findWindowsMatching(directory: directoryPath)
        logger?("dw.restore spec=\(index) match.strategy=directory matches=\(matchResult.count)")

        if matchResult.count > 0 {
            if matchResult.isAmbiguous {
                let matchInfos = matchResult.matches.map { WindowMatchInfo(from: $0) }
                throw LauncherError.ambiguousMatch(matches: matchInfos)
            }

            if let best = matchResult.bestMatch {
                logger?(
                    "dw.restore spec=\(index) match.result=found matchedBy=\(best.matchedBy.rawValue) confidence=\(best.confidence.rawValue) pid=\(best.window.processID ?? 0) title=\"\(best.window.title ?? "nil")\""
                )

                _ = best.window.restore()

                if let position {
                    let frame = try applyPosition(
                        position,
                        to: best.window,
                        screenIndex: spec.screenIndex,
                        displayManager: displayManager
                    )
                    logger?("dw.restore spec=\(index) position.result=applied frame=\"\(frame.debugDescription)\"")
                } else {
                    logger?("dw.restore spec=\(index) position.result=skipped")
                }

                // Activate the correct process by PID, then raise window
                // IMPORTANT: Ghostty uses separate processes per window, so we must activate
                // the specific process that owns this window, not just any Ghostty process
                if let windowPID = best.window.processID,
                   let app = NSRunningApplication(processIdentifier: pid_t(windowPID)) {
                    if #available(macOS 14.0, *) {
                        _ = app.activate()
                    } else {
                        _ = app.activate(options: [.activateIgnoringOtherApps])
                    }
                    logger?("dw.restore spec=\(index) activate.pid=\(windowPID)")
                } else {
                    logger?("dw.restore spec=\(index) activate.pid=failed (no PID)")
                }
                // Raise window using AXWindowService directly (FluentServices not configured in app)
                if let axWindow = best.window.window {
                    let raiseSuccess = AXWindowService.shared.raise(axWindow)
                    logger?("dw.restore spec=\(index) raise.success=\(raiseSuccess)")
                }
                logger?("dw.restore spec=\(index) action=reused raiseActivate=done status=ok")

                return LaunchedWindow(
                    windowHandle: best.window,
                    processID: best.window.processID ?? 0,
                    directoryPath: directoryPath
                )
            }
        }

        logger?("dw.restore spec=\(index) match.result=none")

        let launchSpec: WindowSpec = {
            var updated = spec.inDirectory(directoryPath)
            if let position {
                updated = updated.atPosition(position, screen: spec.screenIndex)
            }
            return updated
        }()

        let launched = try await launchSpec.launch()
        logger?("dw.restore spec=\(index) action=created pid=\(launched.processID)")

        if let position {
            let frame = try applyPosition(
                position,
                to: launched.windowHandle,
                screenIndex: spec.screenIndex,
                displayManager: displayManager
            )
            logger?("dw.restore spec=\(index) position.result=applied frame=\"\(frame.debugDescription)\"")
        }

        // Activate the correct process by PID, then raise window
        if let windowPID = launched.windowHandle.processID,
           let app = NSRunningApplication(processIdentifier: pid_t(windowPID)) {
            if #available(macOS 14.0, *) {
                _ = app.activate()
            } else {
                _ = app.activate(options: [.activateIgnoringOtherApps])
            }
            logger?("dw.restore spec=\(index) activate.pid=\(windowPID)")
        } else {
            logger?("dw.restore spec=\(index) activate.pid=failed (no PID)")
        }
        // Raise window using AXWindowService directly (FluentServices not configured in app)
        if let axWindow = launched.windowHandle.window {
            let raiseSuccess = AXWindowService.shared.raise(axWindow)
            logger?("dw.restore spec=\(index) raise.success=\(raiseSuccess)")
        }
        logger?("dw.restore spec=\(index) raiseActivate=done status=ok")

        return launched
    }

    private func applyPosition(
        _ position: WindowPosition,
        to windowHandle: WindowHandle,
        screenIndex: Int?,
        displayManager: DisplayManager
    ) throws -> CGRect {
        displayManager.refreshScreens()
        let screens = WorkspaceDisplayTopology.effectiveScreens(from: displayManager)

        let targetScreenIndex = screenIndex ?? 0
        guard targetScreenIndex < screens.count else {
            throw LauncherError.positioningFailed(
                reason: "Screen index \(targetScreenIndex) out of range (0-\(max(0, screens.count - 1)))"
            )
        }

        let screen = screens[targetScreenIndex]
        let visibleFrame = screen.visibleFrameInWindowCoordinates(globalMaxY: displayManager.windowCoordinateAnchorY)
        let absoluteFrame = WindowFrameConverter.toAbsolute(
            relativeFrame: position.toRelativeFrame(),
            screenFrame: visibleFrame
        )

        if windowHandle.setFrame(absoluteFrame) == nil {
            if let axWindow = windowHandle.window {
                let success = AXWindowService.shared.move(axWindow, to: absoluteFrame)
                guard success else {
                    throw LauncherError.positioningFailed(reason: "Failed to set frame via AXWindowService")
                }
            } else {
                throw LauncherError.positioningFailed(reason: "No AX window available for positioning")
            }
        }

        return absoluteFrame
    }

    private func raiseConfiguredWindows(
        _ entries: [RestoredWindowEntry],
        logger: ((String) -> Void)?
    ) async {
        guard !entries.isEmpty else { return }
        logCallStack("DirectoryWorkspace.raiseConfiguredWindows entries=\(entries.count)")

        logger?("dw.restore raise.final start count=\(entries.count)")

        for entry in entries {
            let handle = entry.launched.windowHandle
            _ = handle.refresh()

            guard handle.exists else {
                logger?("dw.restore raise.final spec=\(entry.index) skipped reason=missing")
                continue
            }

            let appName = entry.spec.launcher.appName
            let title = handle.title ?? "nil"

            _ = handle.unminimize()

            if let windowPID = handle.processID,
               let app = NSRunningApplication(processIdentifier: pid_t(windowPID)) {
                if #available(macOS 14.0, *) {
                    _ = app.activate()
                } else {
                    _ = app.activate(options: [.activateIgnoringOtherApps])
                }
            }

            if let axWindow = handle.window {
                let raiseSuccess = AXWindowService.shared.raise(axWindow)
                logger?(
                    "dw.restore raise.final spec=\(entry.index) app=\"\(appName)\" title=\"\(title)\" raise.success=\(raiseSuccess)"
                )
            } else {
                logger?(
                    "dw.restore raise.final spec=\(entry.index) app=\"\(appName)\" title=\"\(title)\" raise.success=false"
                )
            }

            _ = handle.tap()

            if entry.spec.launcher.bundleIdentifier == OpenByPathBundleIdentifiers.ghostty {
                let expectedTitle = ghosttyExpectedTitle(
                    for: entry.spec,
                    index: entry.index,
                    directoryPath: entry.launched.directoryPath
                )
                let targetFrame = handle.window?.frame
                await ensureGhosttyWindowTopmost(
                    windowHandle: handle,
                    expectedTitle: expectedTitle,
                    expectedDocumentPath: entry.launched.directoryPath,
                    targetFrame: targetFrame,
                    logger: logger,
                    specIndex: entry.index
                )
            }

            guard await Task.sleepUnlessCancelled(nanoseconds: 150_000_000) else { break }
        }

        logger?("dw.restore raise.final complete")
    }

}

// MARK: - LaunchResult

/// Result of launching a directory workspace
public struct LaunchResult: Sendable {
    public let successCount: Int
    public let failedCount: Int
    public let launchedWindows: [LaunchedWindow]
    public let failures: [(spec: WindowSpec, error: Error)]
    
    public init(
        successCount: Int,
        failedCount: Int,
        launchedWindows: [LaunchedWindow],
        failures: [(spec: WindowSpec, error: Error)]
    ) {
        self.successCount = successCount
        self.failedCount = failedCount
        self.launchedWindows = launchedWindows
        self.failures = failures
    }
}

// MARK: - DirectoryWorkspaceBuilder

/// Builder for constructing directory workspaces with fluent API
public final class DirectoryWorkspaceBuilder {
    private let name: String
    private var icon: String?
    private var windowConfigs: [DirectoryWorkspace.WindowConfig] = []
    
    internal init(name: String) {
        self.name = name
    }
    
    /// Add a window specification to the workspace
    /// - Parameter spec: The window specification to add
    /// - Returns: Self for chaining
    public func add(_ spec: WindowSpec) -> DirectoryWorkspaceBuilder {
        windowConfigs.append(DirectoryWorkspace.makeWindowConfig(from: spec))
        return self
    }
    
    /// Set the workspace icon
    /// - Parameter icon: The emoji icon to use
    /// - Returns: Self for chaining
    public func withIcon(_ icon: String) -> DirectoryWorkspaceBuilder {
        self.icon = icon
        return self
    }
    
    /// Build and save the workspace
    /// - Returns: The created workspace
    public func save() throws -> DirectoryWorkspace {
        let workspace = DirectoryWorkspace(
            name: name,
            icon: icon,
            windowConfigs: windowConfigs
        )
        
        try workspace.save()
        return workspace
    }
    
    /// Build the workspace without saving
    /// - Returns: The created workspace
    public func build() -> DirectoryWorkspace {
        return DirectoryWorkspace(
            name: name,
            icon: icon,
            windowConfigs: windowConfigs
        )
    }
    
    /// Build and immediately launch the workspace
    /// - Returns: The launch result
    public func launch() async throws -> LaunchResult {
        let workspace = build()
        return try await workspace.launch()
    }
}

// MARK: - DirectoryWorkspaceManager

/// Manager for persisting and loading directory workspaces
/// Note: Reads/writes directly from DeskJig app's plist file to ensure
/// both the main app and DeskJigCLI access the same data.
public final class DirectoryWorkspaceManager: ObservableObject, @unchecked Sendable {
    public static let shared = DirectoryWorkspaceManager()

    private let workspacesKey = "DirectoryWorkspaces"
    @Published public var savedWorkspaces: [DirectoryWorkspace] = []

    /// Path to the DeskJig app's preferences plist file
    private var deskJigPrefsPath: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Preferences/\(BundleIdentity.bundleID).plist")
    }

    private init() {
        loadWorkspaces()
    }

    private func loadWorkspaces() {
        // Read directly from DeskJig app's preference file to ensure
        // both main app and DeskJigCLI access the same data
        guard FileManager.default.fileExists(atPath: deskJigPrefsPath.path) else {
            savedWorkspaces = []
            DeskJigLog.info(.workspace, "DirectoryWorkspaceManager: DeskJig prefs file not found at \(deskJigPrefsPath.path)")
            return
        }

        guard let prefsDict = NSDictionary(contentsOf: deskJigPrefsPath) as? [String: Any] else {
            savedWorkspaces = []
            DeskJigLog.info(.workspace, "DirectoryWorkspaceManager: Could not read DeskJig prefs")
            return
        }

        guard let data = prefsDict[workspacesKey] as? Data else {
            savedWorkspaces = []
            DeskJigLog.info(.workspace, "DirectoryWorkspaceManager: No saved workspaces found")
            return
        }

        do {
            savedWorkspaces = try JSONDecoder().decode([DirectoryWorkspace].self, from: data)
            DeskJigLog.info(.workspace, "DirectoryWorkspaceManager: Loaded \(savedWorkspaces.count) workspaces from \(deskJigPrefsPath.path)")
        } catch {
            DeskJigLog.error(.workspace, "DirectoryWorkspaceManager: Failed to load workspaces: \(error)")
            savedWorkspaces = []
        }
    }

    private func saveWorkspaces() {
        do {
            // Load existing preferences
            var prefsDict = (NSDictionary(contentsOf: deskJigPrefsPath) as? [String: Any]) ?? [:]

            // Encode and update workspaces data
            let data = try JSONEncoder().encode(savedWorkspaces)
            prefsDict[workspacesKey] = data

            // Write back to file
            let nsDictionary = NSDictionary(dictionary: prefsDict)
            nsDictionary.write(to: deskJigPrefsPath, atomically: true)

            // Notify defaults system to reload
            CFPreferencesAppSynchronize(BundleIdentity.bundleID as CFString)

            DeskJigLog.info(.workspace, "DirectoryWorkspaceManager: Saved \(savedWorkspaces.count) workspaces to \(deskJigPrefsPath.path)")
        } catch {
            DeskJigLog.error(.workspace, "DirectoryWorkspaceManager: Failed to save workspaces: \(error)")
        }
    }
    
    public func saveWorkspace(_ workspace: DirectoryWorkspace) {
        if let index = savedWorkspaces.firstIndex(where: { $0.id == workspace.id }) {
            savedWorkspaces[index] = workspace
        } else {
            savedWorkspaces.append(workspace)
        }
        saveWorkspaces()
    }
    
    public func updateWorkspace(_ workspace: DirectoryWorkspace) {
        saveWorkspace(workspace)
    }
    
    public func deleteWorkspace(_ workspace: DirectoryWorkspace) {
        savedWorkspaces.removeAll { $0.id == workspace.id }
        saveWorkspaces()
    }
    
    public func getWorkspace(named name: String) -> DirectoryWorkspace? {
        return savedWorkspaces.first { $0.name == name }
    }
    
    public func getWorkspace(withID id: UUID) -> DirectoryWorkspace? {
        return savedWorkspaces.first { $0.id == id }
    }
    
    public func reloadWorkspaces() {
        loadWorkspaces()
    }
}
