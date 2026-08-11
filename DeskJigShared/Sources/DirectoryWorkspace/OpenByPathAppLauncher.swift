//  OpenByPathAppLauncher.swift
//  DeskJigShared

import Foundation
import AppKit
import CoreGraphics

public final class OpenByPathAppLauncher: AppLauncher, @unchecked Sendable {

    public enum AppKind {
        case ghostty
        case terminal
        case ide
    }

    public let bundleIdentifier: String
    public let appName: String

    private let kind: AppKind
    private let displayManager: DisplayManager
    private let axService: AXWindowServiceProtocol
    private let orchestrator = LaunchOrchestrator()
    private let cursorStateReader: CursorStateReader?

    public init(
        bundleIdentifier: String,
        appName: String,
        kind: AppKind? = nil,
        displayManager: DisplayManager = DisplayManager(),
        axService: AXWindowServiceProtocol = AXWindowService.shared,
        cursorStateReader: CursorStateReader = CursorStateReader()
    ) {
        self.bundleIdentifier = bundleIdentifier
        self.appName = appName
        if let kind {
            self.kind = kind
        } else if bundleIdentifier == OpenByPathBundleIdentifiers.ghostty {
            self.kind = .ghostty
        } else if BundleRegistry.isIDE(bundleIdentifier) {
            self.kind = .ide
        } else {
            self.kind = .terminal
        }
        self.displayManager = displayManager
        self.axService = axService
        self.cursorStateReader = bundleIdentifier == OpenByPathBundleIdentifiers.cursor ? cursorStateReader : nil
    }

    // MARK: - Factory

    public static func ghostty() -> OpenByPathAppLauncher {
        OpenByPathAppLauncher(
            bundleIdentifier: OpenByPathBundleIdentifiers.ghostty,
            appName: "Ghostty",
            kind: .ghostty
        )
    }

    public static func cursor() -> OpenByPathAppLauncher {
        OpenByPathAppLauncher(
            bundleIdentifier: OpenByPathBundleIdentifiers.cursor,
            appName: "Cursor",
            kind: .ide
        )
    }

    public static func codex() -> OpenByPathAppLauncher {
        OpenByPathAppLauncher(
            bundleIdentifier: OpenByPathBundleIdentifiers.codex,
            appName: "Codex",
            kind: .ide
        )
    }

    public static func vscode() -> OpenByPathAppLauncher {
        OpenByPathAppLauncher(
            bundleIdentifier: OpenByPathBundleIdentifiers.vscode,
            appName: "VS Code",
            kind: .ide
        )
    }

    public static func terminal() -> OpenByPathAppLauncher {
        OpenByPathAppLauncher(
            bundleIdentifier: OpenByPathBundleIdentifiers.terminal,
            appName: "Terminal",
            kind: .terminal
        )
    }

    public static func iterm() -> OpenByPathAppLauncher {
        OpenByPathAppLauncher(
            bundleIdentifier: OpenByPathBundleIdentifiers.iterm2,
            appName: "iTerm",
            kind: .terminal
        )
    }

    public static func kitty() -> OpenByPathAppLauncher {
        OpenByPathAppLauncher(
            bundleIdentifier: OpenByPathBundleIdentifiers.kitty,
            appName: "kitty",
            kind: .terminal
        )
    }

    public static func alacritty() -> OpenByPathAppLauncher {
        OpenByPathAppLauncher(
            bundleIdentifier: OpenByPathBundleIdentifiers.alacritty,
            appName: "Alacritty",
            kind: .terminal
        )
    }

    public static func xcode() -> OpenByPathAppLauncher {
        OpenByPathAppLauncher(
            bundleIdentifier: OpenByPathBundleIdentifiers.xcode,
            appName: "Xcode",
            kind: .ide
        )
    }

    // MARK: - AppLauncher

    public func launch(spec: WindowSpec) async throws -> LaunchedWindow {
        guard let directoryPath = spec.directoryPath else {
            throw LauncherError.directoryNotFound(path: "No directory specified")
        }

        let expandedPath = (directoryPath as NSString).expandingTildeInPath

        guard let launcher = FluentLauncherFactory.launcher(for: bundleIdentifier) else {
            throw LauncherError.appNotFound(bundleID: bundleIdentifier)
        }

        let title = effectiveTitle(
            for: expandedPath,
            providedTitle: spec.windowTitle,
            windowIndex: spec.windowIndex
        )

        let runId = makeRunId(prefix: "directory")
        let taskContext = RestorationTaskContext(
            taskId: "\(bundleIdentifier)-\(spec.windowIndex ?? 0)",
            taskType: taskType,
            runId: runId
        )

        let snapshot = await SystemSnapshotCapture.captureQuick(runId: runId)
        func fetchAXHandles() -> [WindowHandle] {
            let byBundle = Window.all(forBundleID: bundleIdentifier, filter: .all)
            if !byBundle.isEmpty { return byBundle }
            return Window.all(for: appName, filter: .all)
        }
        let preLaunchAXHashes: Set<Int> = {
            guard kind == .ide else { return [] }
            return Set(fetchAXHandles().compactMap { $0.axElementHash })
        }()
        let result = await orchestrator.findOrLaunch(
            launcher: launcher,
            directory: expandedPath,
            title: title,
            existingSnapshot: snapshot,
            task: taskContext,
            runId: runId,
            supplementationMethod: .axWithLsofFallback,
            enableSupplementation: true,
            ideSupplementationMethod: .cursorStateWithAXFallback,
            enableIDESupplementation: spec.allowReuseExisting,
            allowReuseExisting: spec.allowReuseExisting,
            windowWaitMs: spec.allowReuseExisting ? 800 : 200
        )

        var resolvedMatch = result.match

        if resolvedMatch == nil, kind == .ide {
            let normalizedPath = normalizePath(expandedPath) ?? expandedPath
            let basename = URL(fileURLWithPath: normalizedPath).lastPathComponent
            func matchesApp(_ window: SnapshotWindow) -> Bool {
                if let bundleId = window.bundleId, bundleId == bundleIdentifier {
                    return true
                }
                if let appName = window.appName, appName.caseInsensitiveCompare(self.appName) == .orderedSame {
                    return true
                }
                return false
            }

            let preLaunchWindowIds = Set(snapshot.windows.filter { matchesApp($0) }.map { $0.id })
            let maxAttempts = spec.allowReuseExisting ? 18 : 6

            if !spec.allowReuseExisting {
                func matchNewHandle() async -> WindowHandle? {
                    for _ in 0..<maxAttempts {
                        let postLaunchHandles = fetchAXHandles()
                        let newHandles = postLaunchHandles.filter { handle in
                            guard let hash = handle.axElementHash else { return true }
                            return !preLaunchAXHashes.contains(hash)
                        }

                        if let handle = newHandles.first(where: {
                            guard let doc = $0.documentPath else { return false }
                            return normalizePath(doc) == normalizedPath
                        }) {
                            return handle
                        }

                        if newHandles.count == 1, let handle = newHandles.first {
                            return handle
                        }

                        if let topmost = Window.topmost(filter: .all),
                           (topmost.bundleIdentifier == bundleIdentifier ||
                            topmost.appName?.caseInsensitiveCompare(appName) == .orderedSame) {
                            if let hash = topmost.axElementHash {
                                if newHandles.contains(where: { $0.axElementHash == hash }) {
                                    return topmost
                                }
                            } else if !newHandles.isEmpty {
                                return topmost
                            }
                        }

                        guard await Task.sleepUnlessCancelled(for: .milliseconds(150)) else { break }
                    }
                    return nil
                }

                if let handle = await matchNewHandle() {
                    if let position = spec.position {
                        _ = try applyPosition(position, to: handle, screenIndex: spec.screenIndex)
                    }
                    return LaunchedWindow(
                        windowHandle: handle,
                        processID: handle.processID ?? 0,
                        directoryPath: expandedPath
                    )
                }
            }

            for _ in 0..<maxAttempts {
                let postSnapshot = await SystemSnapshotCapture.captureQuick(runId: runId)
                let appWindows = postSnapshot.windows.filter { matchesApp($0) }
                let newWindows = appWindows.filter { !preLaunchWindowIds.contains($0.id) }

                let titleMatches = newWindows.filter { window in
                    guard let title = window.title, !title.isEmpty else { return false }
                    return matchesProjectTitle(title, folderName: basename) ||
                        titleContainsFolder(title, folderName: basename)
                }

                let candidate: SnapshotWindow?
                let allowMultiMatch = !spec.allowReuseExisting
                func pickFrontmost(_ windows: [SnapshotWindow]) -> SnapshotWindow? {
                    windows.sorted { ($0.zOrderIndex ?? Int.max) < ($1.zOrderIndex ?? Int.max) }.first
                }

                if !titleMatches.isEmpty {
                    if titleMatches.count == 1 || allowMultiMatch {
                        candidate = pickFrontmost(titleMatches)
                    } else {
                        candidate = nil
                    }
                } else if !newWindows.isEmpty {
                    if newWindows.count == 1 || allowMultiMatch {
                        candidate = pickFrontmost(newWindows)
                    } else {
                        candidate = nil
                    }
                } else {
                    candidate = nil
                }

                if let candidate {
                    resolvedMatch = ExpWindowMatch(
                        window: candidate,
                        confidence: .medium,
                        method: .titlePattern,
                        matchedValue: candidate.title
                    )
                    break
                }

                // Cancelled: abort instead of falling into the topmost-window
                // fallback below, which would position and claim a window.
                guard await Task.sleepUnlessCancelled(for: .milliseconds(150)) else { throw CancellationError() }
            }

            if let topmost = Window.topmost(filter: .all),
               (topmost.appName?.caseInsensitiveCompare(appName) == .orderedSame ||
                topmost.bundleIdentifier == bundleIdentifier) {
                if let position = spec.position {
                    _ = try applyPosition(position, to: topmost, screenIndex: spec.screenIndex)
                }
                return LaunchedWindow(
                    windowHandle: topmost,
                    processID: topmost.processID ?? 0,
                    directoryPath: expandedPath
                )
            }
        }

        

        guard let match = resolvedMatch else {
            throw LauncherError.windowNotFound(reason: "No matching window detected after launch")
        }

        let preferredStrategy = WindowHandleResolver.preferredStrategy(for: match)
        guard let handle = WindowHandleResolver.resolve(
            windowId: match.window.windowId,
            preferredStrategy: preferredStrategy,
            filter: .all
        ) else {
            throw LauncherError.windowNotFound(
                reason: "Failed to resolve AX window for CGWindowID \(match.window.windowId)"
            )
        }

        if let position = spec.position, result.matchSource != .existingWindow {
            _ = try applyPosition(position, to: handle, screenIndex: spec.screenIndex)
        }

        return LaunchedWindow(
            windowHandle: handle,
            processID: match.window.pid,
            directoryPath: expandedPath
        )
    }

    public func findByDirectory(_ path: String) async -> WindowHandle? {
        let result = await findWindowsMatching(directory: path)
        guard let best = result.bestMatch else {
            DeskJigLog.debug(.restorationExecutor, "findByDirectory: No window found for '\(path)'")
            return nil
        }

        if result.isAmbiguous {
            DeskJigLog.warn(
                .restorationExecutor,
                "findByDirectory: Ambiguous match for '\(path)' - \(result.count) windows at same confidence"
            )
            return nil
        }

        DeskJigLog.debug(
            .restorationExecutor,
            "findByDirectory: Found window via \(best.matchedBy) (\(best.confidence) confidence)"
        )
        return best.window
    }

    public func findWindowsMatching(directory path: String) async -> WindowMatchResult {
        let normalizedPath = normalizePath(path) ?? (path as NSString).expandingTildeInPath
        let basename = URL(fileURLWithPath: normalizedPath).lastPathComponent

        let windows = Window.allAcrossProcesses(forBundleID: bundleIdentifier, filter: .all)
        let matches = windows.compactMap { matchWindow($0, normalizedPath: normalizedPath, basename: basename) }

        DeskJigLog.debug(.restorationExecutor, "findWindowsMatching: Found \(matches.count) matches for '\(path)'")
        return WindowMatchResult(matches: matches)
    }

    // MARK: - Matching Helpers

    private var taskType: RestorationTaskType {
        switch kind {
        case .ide:
            return .ide
        case .ghostty, .terminal:
            return .terminal
        }
    }

    private func matchWindow(
        _ window: WindowHandle,
        normalizedPath: String,
        basename: String
    ) -> WindowMatch? {
        if let docPath = normalizePath(window.documentPath) {
            if docPath == normalizedPath {
                return WindowMatch(
                    window: window,
                    confidence: .high,
                    matchedBy: .documentPath,
                    details: "documentPath match: \(docPath)"
                )
            }

            if docPath.hasPrefix(normalizedPath + "/") {
                return WindowMatch(
                    window: window,
                    confidence: .medium,
                    matchedBy: .documentPathPrefix,
                    details: "documentPath prefix match: \(docPath)"
                )
            }
        }

        guard let title = window.title, !title.isEmpty else {
            return nil
        }

        switch kind {
        case .ghostty:
            let titlePrefix = "\(BundleIdentity.terminalTitleTokenPrefix):\(basename):"
            if title.hasPrefix(titlePrefix) {
                return WindowMatch(
                    window: window,
                    confidence: .medium,
                    matchedBy: .titleExact,
                    details: "legacy terminal title prefix: \(title)"
                )
            }
        case .terminal:
            let titlePrefix = "\(BundleIdentity.terminalTitleTokenPrefix):\(basename):"
            if title.hasPrefix(titlePrefix) {
                return WindowMatch(
                    window: window,
                    confidence: .medium,
                    matchedBy: .titleExact,
                    details: "legacy terminal title prefix: \(title)"
                )
            }

            if title.localizedCaseInsensitiveContains(basename) {
                return WindowMatch(
                    window: window,
                    confidence: .medium,
                    matchedBy: .titleContains,
                    details: "title contains '\(basename)'"
                )
            }
        case .ide:
            if matchesProjectTitle(title, folderName: basename) {
                let confidence: MatchConfidence
                if let reader = cursorStateReader, reader.findWindowState(forDirectory: normalizedPath) != nil {
                    confidence = .high
                } else {
                    confidence = .medium
                }
                return WindowMatch(
                    window: window,
                    confidence: confidence,
                    matchedBy: .titleExact,
                    details: "title pattern match: \(basename)"
                )
            }

            if titleContainsFolder(title, folderName: basename) {
                return WindowMatch(
                    window: window,
                    confidence: .low,
                    matchedBy: .titleContains,
                    details: "title contains '\(basename)'"
                )
            }
        }

        return nil
    }

    private func matchesProjectTitle(_ title: String, folderName: String) -> Bool {
        let lowered = title.lowercased()
        let token = folderName.lowercased()

        return lowered.hasSuffix(" — \(token)") ||
            lowered.hasSuffix(" - \(token)") ||
            lowered.hasPrefix("\(token) — ") ||
            lowered.hasPrefix("\(token) - ") ||
            lowered.contains(" — \(token) — ") ||
            lowered.contains(" - \(token) - ")
    }

    private func titleContainsFolder(_ title: String, folderName: String) -> Bool {
        let escaped = NSRegularExpression.escapedPattern(for: folderName)
        let pattern = "(?:^|[^a-zA-Z0-9_-])\(escaped)(?:$|[^a-zA-Z0-9_-])"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else {
            return title.localizedCaseInsensitiveContains(folderName)
        }

        let range = NSRange(title.startIndex..., in: title)
        return regex.firstMatch(in: title, options: [], range: range) != nil
    }

    // MARK: - Positioning

    private func applyPosition(
        _ position: WindowPosition,
        to windowHandle: WindowHandle,
        screenIndex: Int?
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
                let success = axService.move(axWindow, to: absoluteFrame)
                guard success else {
                    throw LauncherError.positioningFailed(reason: "Both setFrame and AX positioning failed")
                }
            } else {
                throw LauncherError.positioningFailed(reason: "No AX window available for positioning")
            }
        }

        return absoluteFrame
    }

    // MARK: - Utilities

    private func effectiveTitle(for directoryPath: String, providedTitle: String?, windowIndex: Int?) -> String? {
        guard kind != .ide else { return providedTitle }

        if let providedTitle, !providedTitle.isEmpty {
            return providedTitle
        }

        let basename = URL(fileURLWithPath: directoryPath).lastPathComponent
        let index = windowIndex ?? 0
        return "\(BundleIdentity.terminalTitleTokenPrefix):\(basename):\(index)"
    }

    private func normalizePath(_ path: String?) -> String? {
        guard let path, !path.isEmpty else { return nil }
        let expanded = (path as NSString).expandingTildeInPath
        return URL(fileURLWithPath: expanded).resolvingSymlinksInPath().path
    }

    private func makeRunId(prefix: String) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HHmmss"
        let timestamp = formatter.string(from: Date())
        let chars = "abcdefghijklmnopqrstuvwxyz0123456789"
        let suffix = String((0..<6).compactMap { _ in chars.randomElement() })
        return "\(prefix)_\(timestamp)_\(suffix)"
    }
}
