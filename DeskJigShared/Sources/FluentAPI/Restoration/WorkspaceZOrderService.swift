//  WorkspaceZOrderService.swift
//  DeskJigShared

import Foundation
import AppKit
import CoreGraphics

public final class WorkspaceZOrderService {
    private let displayManager: DisplayManager
    private let chromeProfileManager = ChromeProfileManager()

    /// Per-bundle handle cache for the lifetime of this service instance (zorder-01/02).
    /// A fresh WorkspaceZOrderService is created per post-restore pass, so this cache is
    /// fresh per restore. The five z-order phases only raise/minimize/activate windows —
    /// they never create or destroy them — so the cached handle LIST stays valid across
    /// phases. Handle STATE is not live, though (#500): `WindowHandle.frame` /
    /// `.isMinimized` / `.isHidden` / `.title` are AX snapshots captured at enumeration
    /// and updated only by `refresh()` or by that same handle's own successful mutating
    /// operations (`minimize()`, `restore()`, `setFrame(_:)`, …). `activate()`/`raise()`
    /// do not refresh, and changes made through OTHER handles (e.g. Phase 2's
    /// `Window.find(windowId:)` lookups) or by the apps themselves leave these snapshots
    /// stale across phases. Any frame- or minimized-state-based decision must therefore
    /// pass its candidates through a `HandleTieBreakRefresher` first. (`windowId`,
    /// `documentPath`, and `axElementHash` are live AX reads and are unaffected.)
    /// This collapses the ~22 repeated full per-bundle AX enumerations (one per phase) into
    /// one enumeration per bundle. All callers use `filter: .all`, so the cache is keyed by
    /// bundle id alone.
    private var zorderHandleCacheByBundle: [String: [WindowHandle]] = [:]

    private func cachedWindowsAcrossProcesses(
        forBundleID bundleID: String,
        filter: WindowFilterOptions = .default
    ) -> [WindowHandle] {
        if let cached = zorderHandleCacheByBundle[bundleID] {
            return cached
        }
        let windows = Window.allAcrossProcesses(forBundleID: bundleID, filter: filter)
        zorderHandleCacheByBundle[bundleID] = windows
        return windows
    }

    /// #500: scopes "refresh handles before frame/minimized-state tie-breaks" to a single
    /// post-restore phase. Each phase (or its per-phase `WindowHandleResolver`) creates its
    /// own refresher; passing candidates through `refreshedForTieBreak` re-reads their AX
    /// snapshots (frame, minimized, hidden, title) at most once per refresher lifetime and
    /// drops handles whose windows no longer exist. Targeted refresh at the tie-break call
    /// sites — instead of blanket per-phase cache invalidation — keeps the zorder-01
    /// single-enumeration win (an attribute refresh per candidate is far cheaper than a
    /// full per-bundle re-enumeration) while ensuring frame-tolerance comparisons and
    /// minimized-state checks operate on current AX state rather than snapshots that an
    /// earlier phase's minimize/move made stale.
    ///
    /// Within one phase the once-per-handle guard is sound: the phases only
    /// raise/activate (no snapshot impact) and minimize/restore, and minimize/restore
    /// self-refresh the acting handle, so a handle's snapshot cannot silently go stale
    /// again inside the same phase after this refresher touched it.
    final class HandleTieBreakRefresher {
        private var refreshedHandleIds = Set<ObjectIdentifier>()

        /// Returns the given handles with current AX snapshots, dropping any whose
        /// window no longer exists. Each handle is refreshed at most once per
        /// refresher (i.e. per phase); later calls just re-check liveness.
        func refreshedForTieBreak(_ handles: [WindowHandle]) -> [WindowHandle] {
            handles.filter { handle in
                let id = ObjectIdentifier(handle)
                if refreshedHandleIds.contains(id) {
                    return handle.exists
                }
                refreshedHandleIds.insert(id)
                return handle.refresh() != nil
            }
        }

        /// Single-handle variant: returns the handle (same instance, refreshed
        /// in place) or `nil` when its window no longer exists.
        func refreshedForTieBreak(_ handle: WindowHandle) -> WindowHandle? {
            refreshedForTieBreak([handle]).first
        }
    }

    private final class WindowHandleResolver {
        private unowned let service: WorkspaceZOrderService
        private let terminalBundleIds: Set<String>
        private let resolveTerminalTitles: Bool
        private let frameMatchFallback: Bool
        private var handleCache: [String: [WindowHandle]] = [:]
        /// #500: a resolver is created per phase, so this refresher gives the phase
        /// once-per-handle refresh semantics for all frame-based tie-breaks below.
        private let tieBreakRefresher = HandleTieBreakRefresher()

        init(
            service: WorkspaceZOrderService,
            terminalBundleIds: Set<String>,
            resolveTerminalTitles: Bool,
            frameMatchFallback: Bool
        ) {
            self.service = service
            self.terminalBundleIds = terminalBundleIds
            self.resolveTerminalTitles = resolveTerminalTitles
            self.frameMatchFallback = frameMatchFallback
        }

        func bundleHandles(_ bundleId: String) -> [WindowHandle] {
            if let cached = handleCache[bundleId] { return cached }
            let handles = service.cachedWindowsAcrossProcesses(forBundleID: bundleId, filter: .all)
            handleCache[bundleId] = handles
            return handles
        }

        func handleForTitle(bundleId: String, title: String) -> WindowHandle? {
            bundleHandles(bundleId).first(where: { $0.title == title })
        }

        /// Exposes the per-phase refresher so the owning phase can refresh handles it
        /// obtained from this resolver before its own frame/minimized-state checks,
        /// sharing the once-per-handle guard with the resolver's internal tie-breaks.
        func refreshedForTieBreak(_ handles: [WindowHandle]) -> [WindowHandle] {
            tieBreakRefresher.refreshedForTieBreak(handles)
        }

        func refreshedForTieBreak(_ handle: WindowHandle) -> WindowHandle? {
            tieBreakRefresher.refreshedForTieBreak(handle)
        }

        func handleForTitleAndFrame(bundleId: String, title: String, targetFrame: CGRect, tolerance: CGFloat = 20.0) -> WindowHandle? {
            // #500: frame tolerance decides between same-title duplicates — compare
            // current AX frames, not enumeration-time snapshots that an earlier
            // phase's minimize/move may have invalidated. Titles are re-checked
            // after the refresh for the same reason.
            let titleMatches = bundleHandles(bundleId).filter { $0.title == title }
            return tieBreakRefresher.refreshedForTieBreak(titleMatches).first(where: { handle in
                guard handle.title == title,
                      let handleFrame = handle.frame else { return false }
                return abs(handleFrame.origin.x - targetFrame.origin.x) <= tolerance &&
                       abs(handleFrame.origin.y - targetFrame.origin.y) <= tolerance
            })
        }

        func handleForSnapshotWindow(bundleId: String, snapshotWindow: SnapshotWindow, allSnapshotWindows: [SnapshotWindow]) -> WindowHandle? {
            let handles = bundleHandles(bundleId)
            if let exactIdHandle = handles.first(where: {
                WorkspaceZOrderService.cgWindowId(fromAXWindowNumber: $0.windowId) == snapshotWindow.windowId
            }) {
                return exactIdHandle
            }

            if resolveTerminalTitles,
               terminalBundleIds.contains(bundleId),
               let resolved = TerminalWindowIdentityResolver.resolveHandle(
                bundleId: bundleId,
                snapshotWindow: snapshotWindow,
                handles: handles
               ) {
                return resolved.handle
            }

            if bundleId == OpenByPathBundleIdentifiers.xcode,
               let snapshotPath = service.observedOpenPath(
                for: snapshotWindow.ideDocumentPath ?? snapshotWindow.documentPath,
                bundleId: bundleId
               ) {
                let pathMatches = handles.filter { handle in
                    guard let handlePath = service.observedOpenPath(for: handle.documentPath, bundleId: bundleId) else { return false }
                    return service.pathMatchesExpectedDirectory(
                        observedPath: handlePath,
                        expectedDirectory: snapshotPath,
                        bundleId: bundleId
                    )
                }

                if pathMatches.count == 1, let match = pathMatches.first {
                    return match
                }

                if pathMatches.count > 1 {
                    var candidatePool = pathMatches
                    if let snapshotTitle = snapshotWindow.title {
                        let titleMatches = candidatePool.filter { $0.title == snapshotTitle }
                        if !titleMatches.isEmpty {
                            candidatePool = titleMatches
                        }
                    }

                    if candidatePool.count == 1, let match = candidatePool.first {
                        return match
                    }

                    // #500: refresh before the frame-tolerance disambiguation so stale
                    // enumeration-time frames can't select the wrong same-path window.
                    let frameMatchesPool = tieBreakRefresher.refreshedForTieBreak(candidatePool).filter { handle in
                        guard let handleFrame = handle.frame else { return false }
                        return service.frameMatches(handleFrame, snapshotWindow.frame, tolerance: 20.0)
                    }
                    if frameMatchesPool.count == 1, let match = frameMatchesPool.first {
                        return match
                    }
                }

                // Snapshot path is known but no unique live handle could be resolved.
                // Fail closed for Xcode to avoid root/worktree title collisions.
                return nil
            }

            if frameMatchFallback,
               // #500: frame-only matching is the most stale-sensitive path — refresh
               // the candidates (once per phase) before comparing frames.
               let frameOnlyMatch = tieBreakRefresher.refreshedForTieBreak(handles).first(where: { handle in
                guard let handleFrame = handle.frame else { return false }
                return service.frameMatches(handleFrame, snapshotWindow.frame, tolerance: 20.0)
            }) {
                return frameOnlyMatch
            }

            guard let snapshotTitle = snapshotWindow.title else { return nil }
            let sameTitleWindows = allSnapshotWindows.filter { $0.title == snapshotTitle }
            if sameTitleWindows.count > 1 {
                return handleForTitleAndFrame(
                    bundleId: bundleId,
                    title: snapshotTitle,
                    targetFrame: snapshotWindow.frame,
                    tolerance: 20.0
                )
            }
            return handleForTitle(bundleId: bundleId, title: snapshotTitle)
        }
    }

    public init(displayManager: DisplayManager) {
        self.displayManager = displayManager
    }
    
    private func normalizeOpenPath(_ path: String?) -> String? {
        guard let path else { return nil }
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let expanded = (trimmed as NSString).expandingTildeInPath
        return URL(fileURLWithPath: expanded).standardizedFileURL.path
    }

    /// Checks if a window title contains the folder name using word boundary matching.
    /// This prevents false positives like "deskjig" matching "deskjig-web".
    /// Pattern from OpenByPathAppLauncher.titleContainsFolder().
    private func titleContainsFolder(_ title: String, folderName: String) -> Bool {
        let escaped = NSRegularExpression.escapedPattern(for: folderName)
        let pattern = "(?:^|[^a-zA-Z0-9_-])\(escaped)(?:$|[^a-zA-Z0-9_-])"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else {
            return title.localizedCaseInsensitiveContains(folderName)
        }

        let range = NSRange(title.startIndex..., in: title)
        return regex.firstMatch(in: title, options: [], range: range) != nil
    }

    public func validateOpenPathWindows(
        workspace: Workspace?,
        workspaceWindows: [WorkspaceWindow],
        bundlesWithAuthoritativeRestore: Set<String> = [],
        protectedWindowIds: Set<CGWindowID> = []
    ) {
        DeskJigLog.debug(.restorationTrace, "validateOpenPathWindows enter", fields: [
            "workspaceWindowsCount": workspaceWindows.count,
            "protectedWindowCount": protectedWindowIds.count
        ])
        guard let workspace else { return }

        let titledWindows = OpenByPathTitleAssigner.apply(to: workspaceWindows)
        let openPathWindows = titledWindows.filter { window in
            guard OpenByPathBundleIdentifiers.supported.contains(window.bundleIdentifier) else { return false }
            return normalizeOpenPath(window.openPath) != nil
        }
        guard !openPathWindows.isEmpty else { return }

        let needsGhosttyWindows = openPathWindows.contains { $0.bundleIdentifier == OpenByPathBundleIdentifiers.ghostty }
        let needsCursorWindows = openPathWindows.contains { $0.bundleIdentifier == OpenByPathBundleIdentifiers.cursor }
        let needsCodexWindows = openPathWindows.contains { $0.bundleIdentifier == OpenByPathBundleIdentifiers.codex }
        let needsXcodeWindows = openPathWindows.contains { $0.bundleIdentifier == OpenByPathBundleIdentifiers.xcode }
        let ghosttyWindows = needsGhosttyWindows
            ? cachedWindowsAcrossProcesses(forBundleID: OpenByPathBundleIdentifiers.ghostty, filter: .all)
            : []
        let cursorWindows = needsCursorWindows
            ? cachedWindowsAcrossProcesses(forBundleID: OpenByPathBundleIdentifiers.cursor, filter: .all)
            : []
        let codexWindows = needsCodexWindows
            ? cachedWindowsAcrossProcesses(forBundleID: OpenByPathBundleIdentifiers.codex, filter: .all)
            : []
        let xcodeWindows = needsXcodeWindows
            ? cachedWindowsAcrossProcesses(forBundleID: OpenByPathBundleIdentifiers.xcode, filter: .all)
            : []
        let ghosttyIndexMap = buildGhosttyIndexMap(
            windows: openPathWindows.filter { $0.bundleIdentifier == OpenByPathBundleIdentifiers.ghostty }
        )
        var claimedGhosttyHashes = Set<Int>()

        // Pre-capture CG window list once to avoid repeated CGWindowListCopyWindowInfo calls
        // inside the per-window loop. Each Window.topmost(in:) call previously did its own
        // CG round trip (~30-50ms each); with N open-path windows this saves ~100-150ms.
        let cgWindowListOptions: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        let preCapturedCGWindowList = CGWindowListCopyWindowInfo(cgWindowListOptions, kCGNullWindowID) as? [[String: Any]] ?? []

        // Build PID→bundleId map from running apps once
        let runningApps = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }
        let pidToBundleId = RunningApplicationIndex.bundleIDsByProcessID(
            from: runningApps,
            logSubsystem: .restorationTrace,
            logContext: "WorkspaceZOrderService.validateOpenPathWindows"
        )

        // Local topmost lookup using pre-captured CG list. Returns the document path and
        // CG window number of the topmost window at the target frame for the given bundle,
        // or nil when no on-screen window of that bundle occupies the target point. The
        // window number identifies WHICH window passed the frame check, so the zorder-11
        // skip below can verify the selected window itself is the on-screen one (#501).
        func topmostWindowAtTarget(
            in frame: CGRect,
            forBundle targetBundleId: String
        ) -> (documentPath: String?, windowNumber: Int?)? {
            let targetPoint = CGPoint(x: frame.midX, y: frame.midY)
            for cgWindow in preCapturedCGWindowList {
                let layer = cgWindow[kCGWindowLayer as String] as? Int ?? 0
                guard layer == 0 else { continue }
                guard let ownerPID = cgWindow[kCGWindowOwnerPID as String] as? pid_t else { continue }
                guard pidToBundleId[ownerPID] == targetBundleId else { continue }
                guard let boundsDict = cgWindow[kCGWindowBounds as String] as? [String: CGFloat],
                      let cgX = boundsDict["X"], let cgY = boundsDict["Y"],
                      let cgWidth = boundsDict["Width"], let cgHeight = boundsDict["Height"],
                      cgWidth >= 64, cgHeight >= 64 else { continue }
                let cgFrame = CGRect(x: cgX, y: cgY, width: cgWidth, height: cgHeight)
                guard cgFrame.contains(targetPoint) else { continue }
                let windowNumber = (cgWindow[kCGWindowNumber as String] as? NSNumber)?.intValue
                // Found the topmost CG window for this bundle at target — resolve its AX handle
                // to get the document path.
                if let axService = FluentServices.shared.axWindowService {
                    let axWindows = axService.getWindows(forProcessID: ownerPID, bundleIdentifier: targetBundleId)
                    if let matched = axWindows.first(where: { $0.frameMatches(cgFrame, tolerance: 5) }) {
                        return (WindowHandle(axWindow: matched).documentPath, windowNumber)
                    }
                }
                return (nil, windowNumber)
            }
            return nil
        }

        for window in openPathWindows {
            guard let expectedPath = normalizeOpenPath(window.openPath) else { continue }
            let targetFrame = targetFrameForRaise(window: window, workspaceScreens: workspace.screens)
            let bundleId = window.bundleIdentifier
            if bundleId != OpenByPathBundleIdentifiers.ghostty,
               bundleId != OpenByPathBundleIdentifiers.cursor,
               bundleId != OpenByPathBundleIdentifiers.codex,
               bundleId != OpenByPathBundleIdentifiers.xcode {
                continue
            }

            // Skip bundles that already had an authoritative restore decision
            // (new launch or tmux session switch). Re-validating here can otherwise
            // reactivate stale windows (e.g. bento:deskjig:0) over the intended target.
            if bundlesWithAuthoritativeRestore.contains(bundleId) {
                continue
            }

            let candidates: [WindowHandle]
            switch bundleId {
            case OpenByPathBundleIdentifiers.ghostty:
                candidates = ghosttyWindows
            case OpenByPathBundleIdentifiers.cursor:
                candidates = cursorWindows
            case OpenByPathBundleIdentifiers.codex:
                candidates = codexWindows
            case OpenByPathBundleIdentifiers.xcode:
                candidates = xcodeWindows
            default:
                candidates = []
            }
            var slotMismatch = false
            var slotAlreadyCorrect = false
            var topmostWindowNumber: Int?
            if let targetFrame {
                if let topmost = topmostWindowAtTarget(in: targetFrame, forBundle: bundleId) {
                    topmostWindowNumber = topmost.windowNumber
                    if let topmostDoc = topmost.documentPath {
                        let normalizedTopmostDoc = observedOpenPath(for: topmostDoc, bundleId: bundleId)
                        if normalizedTopmostDoc != expectedPath {
                            slotMismatch = true
                        } else {
                            slotAlreadyCorrect = true
                        }
                    }
                }
            }

            let selected: WindowHandle?
            if bundleId == OpenByPathBundleIdentifiers.ghostty {
                let expectedTitle = ghosttyExpectedTitle(
                    window: window,
                    normalizedPath: expectedPath,
                    indexMap: ghosttyIndexMap
                )
                let matches = ghosttyWindows.filter { $0.title == expectedTitle }
                if let match = selectPreferredWindow(from: matches, excluding: claimedGhosttyHashes) {
                    if let hash = match.axElementHash { claimedGhosttyHashes.insert(hash) }
                    selected = match
                } else {
                    selected = nil
                }
            } else if bundleId == OpenByPathBundleIdentifiers.xcode {
                let pathMatches = candidates.filter { candidate in
                    guard let observed = observedOpenPath(for: candidate.documentPath, bundleId: bundleId) else { return false }
                    return pathMatchesExpectedDirectory(
                        observedPath: observed,
                        expectedDirectory: expectedPath,
                        bundleId: bundleId
                    )
                }

                let protectedPathMatches = pathMatches.filter { candidate in
                    guard let windowId = candidate.windowId else { return false }
                    return protectedWindowIds.contains(CGWindowID(windowId))
                }

                if let protectedMatch = selectPreferredWindow(from: protectedPathMatches) {
                    selected = protectedMatch
                } else if pathMatches.count == 1, let uniquePathMatch = pathMatches.first {
                    selected = uniquePathMatch
                } else if pathMatches.count > 1 {
                    // Fail closed when path-compatible Xcode candidates exist but none map
                    // to a protected/restored window ID. This avoids re-activating a stale
                    // same-title window after the main positioning phase.
                    DeskJigLog.debug(.restorationTrace, "validateOpenPathWindows: ambiguous Xcode path matches (fail closed)", fields: [
                        "expectedPath": expectedPath,
                        "candidateCounts": "path=\(pathMatches.count),protectedPath=\(protectedPathMatches.count)",
                        "protectedWindowCount": "\(protectedWindowIds.count)"
                    ])
                    selected = nil
                } else if let match = matchCursorWindowForRaise(directoryPath: expectedPath, windows: candidates, bundleId: bundleId) {
                    selected = match
                } else {
                    selected = nil
                }
            } else {
                if let match = matchCursorWindowForRaise(directoryPath: expectedPath, windows: candidates, bundleId: bundleId) {
                    selected = match
                } else {
                    selected = nil
                }
            }

            guard let selected else { continue }

            if bundleId == OpenByPathBundleIdentifiers.xcode {
                guard let observed = observedOpenPath(for: selected.documentPath, bundleId: bundleId),
                      pathMatchesExpectedDirectory(
                        observedPath: observed,
                        expectedDirectory: expectedPath,
                        bundleId: bundleId
                      )
                else {
                    DeskJigLog.debug(.restorationTrace, "validateOpenPathWindows: skip incompatible Xcode candidate", fields: [
                        "expectedPath": expectedPath,
                        "selectedTitle": selected.title ?? "nil",
                        "selectedDocumentPath": selected.documentPath ?? "nil"
                    ])
                    continue
                }
            }

            // zorder-11: if the expected document is already the topmost window at the target
            // frame AND that topmost window is `selected` itself, the slot is already correct —
            // skip the redundant restore()/activate() (mirrors the cachedTopmostMatches
            // optimization in enforceTopmostForWorkspaceWindows). The identity match matters:
            // `selected` is chosen by title/path ordering, decoupled from the frame-anchored
            // topmost check, so with two same-bundle windows sharing a normalized open path
            // (one on-screen at the target frame, one minimized) the frame check can pass on
            // the on-screen duplicate while `selected` resolved to the minimized one — skipping
            // then would leave the workspace window minimized (#501).
            if slotAlreadyCorrect {
                // #500: `selected.isMinimized` is an enumeration-time snapshot; refresh
                // before the zorder-11 skip decision so a window an earlier phase
                // minimized or restored is judged on current AX state. A handle whose
                // window vanished has nothing left to restore — skip it entirely.
                guard selected.refresh() != nil else { continue }
                if Self.selectedWindowIsVerifiedTopmost(
                    selectedWindowNumber: selected.windowId,
                    selectedIsMinimized: selected.isMinimized,
                    topmostWindowNumber: topmostWindowNumber
                ) {
                    continue
                }
                DeskJigLog.debug(.restorationTrace, "validateOpenPathWindows: topmost doc correct but selected window is not the on-screen topmost — restoring selected (zorder-11)", fields: [
                    "expectedPath": expectedPath,
                    "selectedWindowNumber": selected.windowId.map(String.init) ?? "nil",
                    "selectedIsMinimized": "\(selected.isMinimized)",
                    "topmostWindowNumber": topmostWindowNumber.map(String.init) ?? "nil"
                ])
            }

            // Skip frame repositioning during post-restore. The main restoration phase already
            // positioned windows correctly. When screen mappings are applied, targetFrame is
            // computed incorrectly (relativeFrame is relative to the original saved screen but
            // screenIndex points to the remapped screen), which causes windows to flip-flop
            // between screens.
            _ = selected.restore()?.activate()

            if slotMismatch, targetFrame != nil {
                _ = selected.raise()
                _ = selected.tap()
            }
        }
    }

    /// zorder-11 (#501): decides whether the "slot already correct" skip in
    /// `validateOpenPathWindows` may fire. The skip is only safe when the window we would
    /// otherwise `restore()?.activate()` is provably the on-screen topmost window at the
    /// target frame — a positive CG window-number identity match. Fails closed (returns
    /// `false`, taking the restore path) when either window number is unavailable, and a
    /// minimized selected window can never be the on-screen topmost window regardless of
    /// what the window numbers claim.
    static func selectedWindowIsVerifiedTopmost(
        selectedWindowNumber: Int?,
        selectedIsMinimized: Bool,
        topmostWindowNumber: Int?
    ) -> Bool {
        guard !selectedIsMinimized else { return false }
        guard let selectedWindowNumber, let topmostWindowNumber else { return false }
        return selectedWindowNumber == topmostWindowNumber
    }

    public func enforceTopmostForWorkspaceWindows(
        workspaceWindows: [WorkspaceWindow],
        workspaceScreens: [WorkspaceScreen]?,
        alreadyRaisedWindowIds: Set<CGWindowID> = []
    ) {
        DeskJigLog.debug(.restorationTrace, "enforceTopmostForWorkspaceWindows enter", fields: [
            "workspaceWindowsCount": workspaceWindows.count,
            "alreadyRaisedCount": alreadyRaisedWindowIds.count
        ])
        guard !workspaceWindows.isEmpty else { return }

        let titledWindows = OpenByPathTitleAssigner.apply(to: workspaceWindows)

        let workspaceBundleIds = Set(workspaceWindows.map { $0.bundleIdentifier })
        var windowCache: [String: [WindowHandle]] = [:]
        // #500: phase-scoped refresher for the frame/hidden-state decisions below.
        let tieBreakRefresher = HandleTieBreakRefresher()

        func bundleWindows(_ bundleId: String) -> [WindowHandle] {
            if let cached = windowCache[bundleId] { return cached }
            let windows = cachedWindowsAcrossProcesses(forBundleID: bundleId, filter: .all)
            windowCache[bundleId] = windows
            return windows
        }

        let ghosttyWindows = workspaceBundleIds.contains(OpenByPathBundleIdentifiers.ghostty)
            ? bundleWindows(OpenByPathBundleIdentifiers.ghostty)
            : []
        let cursorWindows = workspaceBundleIds.contains(OpenByPathBundleIdentifiers.cursor)
            ? bundleWindows(OpenByPathBundleIdentifiers.cursor)
            : []
        let codexWindows = workspaceBundleIds.contains(OpenByPathBundleIdentifiers.codex)
            ? bundleWindows(OpenByPathBundleIdentifiers.codex)
            : []
        let terminalWindows = workspaceBundleIds.contains(OpenByPathBundleIdentifiers.terminal)
            ? bundleWindows(OpenByPathBundleIdentifiers.terminal)
            : []
        let itermWindows = workspaceBundleIds.contains(OpenByPathBundleIdentifiers.iterm2)
            ? bundleWindows(OpenByPathBundleIdentifiers.iterm2)
            : []
        let kittyWindows = workspaceBundleIds.contains(OpenByPathBundleIdentifiers.kitty)
            ? bundleWindows(OpenByPathBundleIdentifiers.kitty)
            : []
        let alacrittyWindows = workspaceBundleIds.contains(OpenByPathBundleIdentifiers.alacritty)
            ? bundleWindows(OpenByPathBundleIdentifiers.alacritty)
            : []
        let vscodeWindows = workspaceBundleIds.contains(OpenByPathBundleIdentifiers.vscode)
            ? bundleWindows(OpenByPathBundleIdentifiers.vscode)
            : []
        let xcodeWindows = workspaceBundleIds.contains(OpenByPathBundleIdentifiers.xcode)
            ? bundleWindows(OpenByPathBundleIdentifiers.xcode)
            : []

        let ghosttyIndexMap = buildGhosttyIndexMap(
            windows: titledWindows.filter { $0.bundleIdentifier == OpenByPathBundleIdentifiers.ghostty && normalizeOpenPath($0.openPath) != nil }
        )
        let terminalIndexMap = buildTerminalIndexMap(windows: titledWindows.filter { $0.bundleIdentifier == OpenByPathBundleIdentifiers.terminal && normalizeOpenPath($0.openPath) != nil })
        let itermIndexMap = buildTerminalIndexMap(windows: titledWindows.filter { $0.bundleIdentifier == OpenByPathBundleIdentifiers.iterm2 && normalizeOpenPath($0.openPath) != nil })
        let kittyIndexMap = buildTerminalIndexMap(windows: titledWindows.filter { $0.bundleIdentifier == OpenByPathBundleIdentifiers.kitty && normalizeOpenPath($0.openPath) != nil })
        let alacrittyIndexMap = buildTerminalIndexMap(windows: titledWindows.filter { $0.bundleIdentifier == OpenByPathBundleIdentifiers.alacritty && normalizeOpenPath($0.openPath) != nil })
        var claimedGhosttyHashes = Set<Int>()

        func fallbackWindow(for window: WorkspaceWindow, targetFrame: CGRect) -> WindowHandle? {
            let bundleHandles = bundleWindows(window.bundleIdentifier)
            // #500: both selections below are frame-based (closest-to-target ordering and
            // frame-tolerance filtering) — refresh candidates (once per phase) first.
            let matches = tieBreakRefresher.refreshedForTieBreak(
                bundleHandles.filter { ($0.title ?? "").localizedCaseInsensitiveCompare(window.windowTitle) == .orderedSame }
            )
            if let selected = selectClosestWindow(from: matches, targetFrame: targetFrame) { return selected }
            let frameCandidates = tieBreakRefresher.refreshedForTieBreak(bundleHandles).filter { candidate in
                guard let frame = candidate.frame else { return false }
                return frameMatches(frame, targetFrame, tolerance: 12.0)
            }
            return selectClosestWindow(from: frameCandidates, targetFrame: targetFrame)
        }

        func selectExpectedWindow(for window: WorkspaceWindow, targetFrame: CGRect) -> WindowHandle? {
            switch window.bundleIdentifier {
            case OpenByPathBundleIdentifiers.ghostty:
                if let normalizedOpenPath = normalizeOpenPath(window.openPath) {
                    let expectedTitle = ghosttyExpectedTitle(window: window, normalizedPath: normalizedOpenPath, indexMap: ghosttyIndexMap)
                    let matches = ghosttyWindows.filter { $0.title == expectedTitle }
                    if let selected = selectPreferredWindow(from: matches, excluding: claimedGhosttyHashes) {
                        if let hash = selected.axElementHash { claimedGhosttyHashes.insert(hash) }
                        return selected
                    }
                }
                return fallbackWindow(for: window, targetFrame: targetFrame)

            case OpenByPathBundleIdentifiers.cursor:
                if let openPath = normalizeOpenPath(window.openPath) {
                    return matchCursorWindowForRaise(directoryPath: openPath, windows: cursorWindows)
                }
                return fallbackWindow(for: window, targetFrame: targetFrame)

            case OpenByPathBundleIdentifiers.codex:
                if let openPath = normalizeOpenPath(window.openPath) {
                    if let match = matchCursorWindowForRaise(
                        directoryPath: openPath,
                        windows: codexWindows,
                        bundleId: OpenByPathBundleIdentifiers.codex
                    ) {
                        return match
                    }
                }
                return fallbackWindow(for: window, targetFrame: targetFrame)

            case OpenByPathBundleIdentifiers.terminal:
                if let openPath = normalizeOpenPath(window.openPath) {
                    let expectedTitle = terminalExpectedTitle(window: window, normalizedPath: openPath, indexMap: terminalIndexMap)
                    let matches = terminalWindows.filter { $0.title == expectedTitle }
                    if let selected = selectPreferredWindow(from: matches) { return selected }
                    let docMatches = terminalWindows.filter { normalizeOpenPath($0.documentPath) == openPath }
                    if let selected = selectPreferredWindow(from: docMatches) { return selected }
                }
                return fallbackWindow(for: window, targetFrame: targetFrame)

            case OpenByPathBundleIdentifiers.iterm2:
                if let openPath = normalizeOpenPath(window.openPath) {
                    let expectedTitle = terminalExpectedTitle(window: window, normalizedPath: openPath, indexMap: itermIndexMap)
                    let matches = itermWindows.filter { $0.title == expectedTitle }
                    if let selected = selectPreferredWindow(from: matches) { return selected }
                    let docMatches = itermWindows.filter { normalizeOpenPath($0.documentPath) == openPath }
                    if let selected = selectPreferredWindow(from: docMatches) { return selected }
                }
                return fallbackWindow(for: window, targetFrame: targetFrame)

            case OpenByPathBundleIdentifiers.kitty:
                if let openPath = normalizeOpenPath(window.openPath) {
                    let expectedTitle = terminalExpectedTitle(window: window, normalizedPath: openPath, indexMap: kittyIndexMap)
                    let matches = kittyWindows.filter { $0.title == expectedTitle }
                    if let selected = selectPreferredWindow(from: matches) { return selected }
                    let docMatches = kittyWindows.filter { normalizeOpenPath($0.documentPath) == openPath }
                    if let selected = selectPreferredWindow(from: docMatches) { return selected }
                }
                return fallbackWindow(for: window, targetFrame: targetFrame)

            case OpenByPathBundleIdentifiers.alacritty:
                if let openPath = normalizeOpenPath(window.openPath) {
                    let expectedTitle = terminalExpectedTitle(window: window, normalizedPath: openPath, indexMap: alacrittyIndexMap)
                    let matches = alacrittyWindows.filter { $0.title == expectedTitle }
                    if let selected = selectPreferredWindow(from: matches) { return selected }
                    let docMatches = alacrittyWindows.filter { normalizeOpenPath($0.documentPath) == openPath }
                    if let selected = selectPreferredWindow(from: docMatches) { return selected }
                }
                return fallbackWindow(for: window, targetFrame: targetFrame)

            case OpenByPathBundleIdentifiers.vscode:
                if let openPath = normalizeOpenPath(window.openPath) {
                    if let match = matchCursorWindowForRaise(directoryPath: openPath, windows: vscodeWindows) {
                        return match
                    }
                }
                return fallbackWindow(for: window, targetFrame: targetFrame)

            case OpenByPathBundleIdentifiers.xcode:
                if let openPath = normalizeOpenPath(window.openPath) {
                    if let match = matchCursorWindowForRaise(
                        directoryPath: openPath,
                        windows: xcodeWindows,
                        bundleId: OpenByPathBundleIdentifiers.xcode
                    ) {
                        return match
                    }
                }
                return fallbackWindow(for: window, targetFrame: targetFrame)

            case "com.google.Chrome", "com.google.Chrome.beta", "com.google.Chrome.dev", "com.google.Chrome.canary":
                // #500: every Chrome selection below tie-breaks by frame proximity —
                // refresh the candidate list (once per phase) up front.
                let chromeWindows = tieBreakRefresher.refreshedForTieBreak(bundleWindows(window.bundleIdentifier))
                let isAnyWindowSelection = window.chromeState?.profileMatchMode == .anyWindow

                if isAnyWindowSelection {
                    let chromeFrameCandidates = chromeWindows.filter { candidate in
                        guard let frame = candidate.frame else { return false }
                        return frameMatches(frame, targetFrame, tolerance: 50.0)
                    }
                    if let selected = selectClosestWindow(from: chromeFrameCandidates, targetFrame: targetFrame) {
                        return selected
                    }
                    return selectClosestWindow(from: chromeWindows, targetFrame: targetFrame)
                }

                // First: if we have chromeState.profileDirectory, use it for reliable matching
                if let savedDirectory = window.chromeState?.profileDirectory, !savedDirectory.isEmpty,
                   let savedProfile = chromeProfileManager.profile(forDirectory: savedDirectory) {
                    let savedAppleScriptName = savedProfile.appleScriptName
                    let profileMatches = chromeWindows.filter { candidate in
                        guard let title = candidate.title else { return false }
                        let candidateProfile = extractChromeProfileName(from: title)
                        return candidateProfile == savedAppleScriptName
                    }
                    if let selected = selectClosestWindow(from: profileMatches, targetFrame: targetFrame) { return selected }
                }

                // Second: try chromeState.appleScriptProfileName directly
                if let savedAppleScriptName = window.chromeState?.appleScriptProfileName, !savedAppleScriptName.isEmpty {
                    let profileMatches = chromeWindows.filter { candidate in
                        guard let title = candidate.title else { return false }
                        let candidateProfile = extractChromeProfileName(from: title)
                        return candidateProfile == savedAppleScriptName
                    }
                    if let selected = selectClosestWindow(from: profileMatches, targetFrame: targetFrame) { return selected }
                }

                // Third: Extract profile from saved title (backward compatibility)
                let savedProfile = extractChromeProfileName(from: window.windowTitle)
                if let savedProfile {
                    let profileMatches = chromeWindows.filter { candidate in
                        guard let title = candidate.title else { return false }
                        let candidateProfile = extractChromeProfileName(from: title)
                        return candidateProfile == savedProfile
                    }
                    if let selected = selectClosestWindow(from: profileMatches, targetFrame: targetFrame) { return selected }
                }

                // Fallback: match by frame with larger tolerance (50pt for Chrome)
                let chromeFrameCandidates = chromeWindows.filter { candidate in
                    guard let frame = candidate.frame else { return false }
                    return frameMatches(frame, targetFrame, tolerance: 50.0)
                }
                return selectClosestWindow(from: chromeFrameCandidates, targetFrame: targetFrame)

            default:
                return fallbackWindow(for: window, targetFrame: targetFrame)
            }
        }

        func priority(for window: WorkspaceWindow) -> Int {
            switch window.bundleIdentifier {
            case OpenByPathBundleIdentifiers.ghostty: return 2
            case OpenByPathBundleIdentifiers.cursor, OpenByPathBundleIdentifiers.codex, OpenByPathBundleIdentifiers.terminal, OpenByPathBundleIdentifiers.iterm2, OpenByPathBundleIdentifiers.kitty, OpenByPathBundleIdentifiers.alacritty, OpenByPathBundleIdentifiers.vscode, OpenByPathBundleIdentifiers.xcode: return 1
            default: return 0
            }
        }

        let orderedWindows = titledWindows.sorted {
            let lhs = priority(for: $0)
            let rhs = priority(for: $1)
            return lhs == rhs ? $0.id.uuidString < $1.id.uuidString : lhs < rhs
        }

        // Pre-capture CGWindowList once to avoid repeated CGWindowListCopyWindowInfo calls
        // inside the per-window loop (~30ms per call × N windows = significant savings).
        let cgOptions: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        let cgWindowList = CGWindowListCopyWindowInfo(cgOptions, kCGNullWindowID) as? [[String: Any]] ?? []

        // Build a lookup from the CG list: for each target frame center point, find the
        // topmost CG window (first match in z-ordered list) and cache its owner PID + frame.
        // This replaces per-window Window.topmost(in:) calls.
        func cachedTopmostMatches(expected: WindowHandle, in frame: CGRect) -> Bool {
            let targetPoint = CGPoint(x: frame.midX, y: frame.midY)
            for cgWindow in cgWindowList {
                let layer = cgWindow[kCGWindowLayer as String] as? Int ?? 0
                guard layer == 0 else { continue }
                guard let boundsDict = cgWindow[kCGWindowBounds as String] as? [String: CGFloat],
                      let cgX = boundsDict["X"], let cgY = boundsDict["Y"],
                      let cgW = boundsDict["Width"], let cgH = boundsDict["Height"],
                      cgW >= 64, cgH >= 64 else { continue }
                let cgFrame = CGRect(x: cgX, y: cgY, width: cgW, height: cgH)
                guard cgFrame.contains(targetPoint) else { continue }
                // First layer-0 CG window containing the target point is the topmost.
                // Check if it matches the expected window by PID + frame proximity.
                guard let ownerPID = cgWindow[kCGWindowOwnerPID as String] as? pid_t,
                      let expectedPID = expected.processID else { return false }
                if ownerPID == expectedPID {
                    if let expectedFrame = expected.frame,
                       abs(cgFrame.origin.x - expectedFrame.origin.x) <= 5 &&
                       abs(cgFrame.origin.y - expectedFrame.origin.y) <= 5 &&
                       abs(cgFrame.width - expectedFrame.width) <= 5 &&
                       abs(cgFrame.height - expectedFrame.height) <= 5 {
                        return true
                    }
                }
                return false
            }
            return false
        }

        for window in orderedWindows {
            guard let targetFrame = targetFrameForRaise(window: window, workspaceScreens: workspaceScreens) else { continue }
            guard let expected = selectExpectedWindow(for: window, targetFrame: targetFrame) else { continue }

            // Skip windows already raised by Phase 2 (ensureWorkspaceWindowsOnTop) to avoid
            // redundant AX calls (~45ms per window for topmost check + raise + activate + tap).
            if let windowId = expected.windowId, alreadyRaisedWindowIds.contains(CGWindowID(windowId)) {
                continue
            }

            // #500: `cachedTopmostMatches` compares expected.frame against the CG list and
            // the `isHidden` read below is snapshot state — refresh before both decisions.
            // A handle whose window vanished has nothing left to raise.
            guard tieBreakRefresher.refreshedForTieBreak(expected) != nil else { continue }

            // Skip frame repositioning during post-restore. The main restoration phase already
            // positioned windows correctly. When screen mappings are applied, targetFrame is
            // computed incorrectly (relativeFrame is relative to the original saved screen but
            // screenIndex points to the remapped screen), which causes windows to flip-flop
            // between screens.

            // Use pre-captured CG window list for topmost check instead of per-window
            // CGWindowListCopyWindowInfo calls (~30ms savings per window).
            if cachedTopmostMatches(expected: expected, in: targetFrame) { continue }

            if expected.isHidden { _ = expected.unhide() }
            // activate() already performs kAXRaiseAction internally, so separate raise() is redundant.
            _ = expected.restore()?.activate()
            _ = expected.tap()
        }
    }

    /// Aggressively minimizes ALL windows from open-by-path apps (IDEs, terminals) that don't match
    /// workspace directory paths. This runs early in post-restore to clean up windows that apps
    /// restore from their previous sessions.
    ///
    /// Unlike `minimizeNonWorkspaceWindows`, this function:
    /// - Processes ALL open-by-path apps (not just those in the workspace)
    /// - Minimizes ALL non-matching windows (regardless of z-order position)
    /// - Uses the snapshot which contains supplementation data (document paths, working dirs)
    ///
    /// - Parameter protectedWindowIds: Window IDs that were just restored and should NOT be minimized.
    ///   This prevents the flicker where a workspace window is minimized by cleanup, then restored
    ///   by z-order enforcement, then minimized again.
    public func minimizeNonMatchingOpenByPathWindows(
        workspaceWindows: [WorkspaceWindow],
        snapshot: SystemSnapshot,
        runId: String,
        protectedWindowIds: Set<CGWindowID> = [],
        bundlesWithAuthoritativeRestore: Set<String> = []
    ) {
        DeskJigLog.debug(.restorationTrace, "minimizeNonMatchingOpenByPathWindows: starting", fields: [
            "snapshotWindowCount": "\(snapshot.windows.count)",
            "protectedWindowCount": "\(protectedWindowIds.count)",
            "bundlesWithAuthoritativeRestore": bundlesWithAuthoritativeRestore.sorted().joined(separator: ",")
        ], runId: runId)

        let openByPathBundleIds: Set<String> = [
            OpenByPathBundleIdentifiers.cursor,
            OpenByPathBundleIdentifiers.codex,
            OpenByPathBundleIdentifiers.vscode,
            OpenByPathBundleIdentifiers.xcode,
            OpenByPathBundleIdentifiers.ghostty,
            OpenByPathBundleIdentifiers.terminal,
            OpenByPathBundleIdentifiers.iterm2,
            OpenByPathBundleIdentifiers.kitty,
            OpenByPathBundleIdentifiers.alacritty
        ]

        let terminalBundleIds: Set<String> = [
            OpenByPathBundleIdentifiers.ghostty,
            OpenByPathBundleIdentifiers.terminal,
            OpenByPathBundleIdentifiers.iterm2,
            OpenByPathBundleIdentifiers.kitty,
            OpenByPathBundleIdentifiers.alacritty
        ]

        let ideBundleIds: Set<String> = [
            OpenByPathBundleIdentifiers.cursor,
            OpenByPathBundleIdentifiers.codex,
            OpenByPathBundleIdentifiers.vscode,
            OpenByPathBundleIdentifiers.xcode
        ]

        // Build workspace paths by bundle ID
        let workspacePathsByBundle = Dictionary(grouping: workspaceWindows, by: { $0.bundleIdentifier })
            .mapValues { windows in
                Set(windows.compactMap { normalizeOpenPath($0.openPath) })
            }
        let workspacePathSlotsByBundle = Dictionary(grouping: workspaceWindows, by: { $0.bundleIdentifier })
            .mapValues { windows in
                windows.compactMap { normalizeOpenPath($0.openPath) }
            }
        let tmuxManagedTerminalBundles = Set(
            workspaceWindows
                .filter { BundleRegistry.isTerminal($0.bundleIdentifier) && $0.tmuxState != nil }
                .map(\.bundleIdentifier)
        )

        // Build workspace title tokens for fallback matching (e.g., "bento:deskjig:0")
        let workspaceTitleTokensByBundle = Dictionary(grouping: workspaceWindows, by: { $0.bundleIdentifier })
            .mapValues { windows -> Set<String> in
                var tokens = Set<String>()
                for window in windows {
                    // Add directory basename
                    if let path = normalizeOpenPath(window.openPath) {
                        let basename = URL(fileURLWithPath: path).lastPathComponent
                        if !basename.isEmpty {
                            tokens.insert(basename)
                        }
                    }
                    // Add window title tokens (e.g., "bento:deskjig:0" for terminals)
                    let titleTokens = window.windowTitle.components(separatedBy: CharacterSet.whitespaces.union(CharacterSet(charactersIn: "—-")))
                        .filter { !$0.isEmpty && $0.count > 3 }
                    tokens.formUnion(titleTokens)
                }
                return tokens
            }

        // Group snapshot windows by bundle ID (these have supplementation data)
        let snapshotWindowsByBundle = Dictionary(grouping: snapshot.windows.filter { $0.bundleId != nil }) { $0.bundleId! }

        var totalMinimized = 0
        var totalSkipped = 0

        let handleResolver = WindowHandleResolver(
            service: self,
            terminalBundleIds: terminalBundleIds,
            resolveTerminalTitles: true,
            frameMatchFallback: true
        )

        let xcodeHashesByWindowId = xcodeHandleHashesByWindowId()

        for bundleId in openByPathBundleIds {
            let isAuthoritativeBundle = bundlesWithAuthoritativeRestore.contains(bundleId)
            // Most authoritative bundles are skipped here to avoid minimizing newly restored
            // windows during window-ID churn. Xcode is the exception: it often has multiple
            // project windows, and we still want to demote non-workspace extras while keeping
            // protected restored IDs intact.
            if isAuthoritativeBundle,
               bundleId != OpenByPathBundleIdentifiers.xcode,
               !tmuxManagedTerminalBundles.contains(bundleId) {
                DeskJigLog.trace(.restorationTrace, "minimizeNonMatchingOpenByPathWindows: skip authoritative bundle", fields: [
                    "bundleId": bundleId
                ], runId: runId)
                continue
            }
            guard let snapshotWindows = snapshotWindowsByBundle[bundleId], !snapshotWindows.isEmpty else { continue }

            let workspacePaths = workspacePathsByBundle[bundleId] ?? []
            let workspacePathSlots = workspacePathSlotsByBundle[bundleId] ?? []
            let workspaceTitleTokens = workspaceTitleTokensByBundle[bundleId] ?? []

            // If this bundle has no workspace windows, minimize ALL its windows
            let hasWorkspaceWindows = !workspacePaths.isEmpty || !workspaceTitleTokens.isEmpty
            let protectedBundleWindowIds = Set(snapshotWindows
                .filter { protectedWindowIds.contains($0.windowId) }
                .map { $0.windowId })
            let orderedSnapshotWindows = snapshotWindows.sorted { lhs, rhs in
                let lhsZ = lhs.zOrderIndex ?? Int.max
                let rhsZ = rhs.zOrderIndex ?? Int.max
                if lhsZ != rhsZ {
                    return lhsZ < rhsZ
                }
                if lhs.windowId != rhs.windowId {
                    return lhs.windowId < rhs.windowId
                }
                let lhsHash = xcodeHashesByWindowId[lhs.windowId] ?? 0
                let rhsHash = xcodeHashesByWindowId[rhs.windowId] ?? 0
                return lhsHash < rhsHash
            }
            let xcodeCoverageSelection = bundleId == OpenByPathBundleIdentifiers.xcode
                ? selectXcodeCoverageWindowIds(
                    expectedPathSlots: workspacePathSlots,
                    snapshotWindows: orderedSnapshotWindows,
                    protectedWindowIds: protectedBundleWindowIds,
                    xcodeHashesByWindowId: xcodeHashesByWindowId
                )
                : nil
            let xcodeCoverageWindowIds = xcodeCoverageSelection?.coverageWindowIds ?? Set<CGWindowID>()
            let authoritativeTmuxWindowIds = tmuxManagedTerminalBundles.contains(bundleId)
                ? protectedBundleWindowIds
                : Set<CGWindowID>()

            if bundleId == OpenByPathBundleIdentifiers.xcode, isAuthoritativeBundle {
                DeskJigLog.debug(.restorationTrace, "minimizeNonMatchingOpenByPathWindows: Xcode authoritative pass enabled", fields: [
                    "bundleId": bundleId,
                    "protectedCount": "\(protectedBundleWindowIds.count)"
                ], runId: runId)
            }
            if bundleId == OpenByPathBundleIdentifiers.xcode,
               let xcodeCoverageSelection {
                DeskJigLog.trace(.restorationTrace, "minimizeNonMatchingOpenByPathWindows: Xcode coverage topology", fields: [
                    "bundleId": bundleId,
                    "reason": XcodeIdentityTraceReason.pathConfirmedSelection.rawValue,
                    "expectedPathSlots": xcodeCoverageSelection.topology.expectedPathSlots.joined(separator: " | "),
                    "observedPathSlots": xcodeCoverageSelection.topology.observedPathSlots.joined(separator: " | "),
                    "missingPathSlots": xcodeCoverageSelection.topology.missingPathSlots.joined(separator: " | "),
                    "duplicatePathSlots": xcodeCoverageSelection.topology.duplicatePathSlots.joined(separator: " | "),
                    "coverageWindowIds": xcodeCoverageWindowIds.map { "\($0)" }.joined(separator: ",")
                ], runId: runId)
            }

            var minimizedCount = 0
            var skippedCount = 0

            for snapshotWindow in orderedSnapshotWindows {
                // Skip protected windows (just restored during this restoration)
                if protectedWindowIds.contains(snapshotWindow.windowId) {
                    if bundleId == OpenByPathBundleIdentifiers.xcode,
                       !xcodeCoverageWindowIds.contains(snapshotWindow.windowId) {
                        DeskJigLog.debug(.restorationTrace, "minimizeNonMatchingOpenByPathWindows: demoting stale protected Xcode window", fields: [
                            "bundleId": bundleId,
                            "windowId": "\(snapshotWindow.windowId)",
                            "title": snapshotWindow.title ?? "nil",
                            "coverageWindowIds": xcodeCoverageWindowIds.map { "\($0)" }.joined(separator: ",")
                        ], runId: runId)
                    } else {
                        DeskJigLog.trace(.restorationTrace, "minimizeNonMatchingOpenByPathWindows: skipping protected window", fields: [
                            "bundleId": bundleId,
                            "windowId": "\(snapshotWindow.windowId)",
                            "title": snapshotWindow.title ?? "nil"
                        ], runId: runId)
                        skippedCount += 1
                        continue
                    }
                }
                // Skip already minimized windows
                if snapshotWindow.isMinimized == true { continue }
                // Skip off-screen windows
                if snapshotWindow.isOnScreen == false { continue }

                // Check if this window matches a workspace path
                var isWorkspaceWindow = false
                var windowPath: String?

                if hasWorkspaceWindows {
                    if bundleId == OpenByPathBundleIdentifiers.xcode {
                        windowPath = observedOpenPath(
                            for: snapshotWindow.ideDocumentPath ?? snapshotWindow.documentPath,
                            bundleId: bundleId
                        )
                        isWorkspaceWindow = xcodeCoverageWindowIds.contains(snapshotWindow.windowId)
                    } else if tmuxManagedTerminalBundles.contains(bundleId), isAuthoritativeBundle {
                        isWorkspaceWindow = authoritativeTmuxWindowIds.contains(snapshotWindow.windowId)
                    } else if terminalBundleIds.contains(bundleId) {
                        // For terminals, use freshWorkingDirectory or documentPath
                        windowPath = normalizeOpenPath(snapshotWindow.freshWorkingDirectory)
                            ?? normalizeOpenPath(snapshotWindow.documentPath)
                    } else if ideBundleIds.contains(bundleId) {
                        // For IDEs, use ideDocumentPath or documentPath
                        windowPath = observedOpenPath(
                            for: snapshotWindow.ideDocumentPath ?? snapshotWindow.documentPath,
                            bundleId: bundleId
                        )
                    }

                    if bundleId != OpenByPathBundleIdentifiers.xcode,
                       let path = windowPath, workspacePaths.contains(where: { expected in
                        pathMatchesExpectedDirectory(observedPath: path, expectedDirectory: expected, bundleId: bundleId)
                    }) {
                        isWorkspaceWindow = true
                    }

                    // Fallback to title matching (using word boundary matching to avoid false positives)
                    if bundleId != OpenByPathBundleIdentifiers.xcode,
                       !isWorkspaceWindow,
                       let title = snapshotWindow.title,
                       !workspaceTitleTokens.isEmpty {
                        // For Xcode, if we already have a resolved document path and it is outside
                        // workspace paths, do not trust title token fallback.
                        isWorkspaceWindow = workspaceTitleTokens.contains(where: { token in
                            titleContainsFolder(title, folderName: token)
                        })
                    }
                }

                if isWorkspaceWindow {
                    skippedCount += 1
                    continue
                }

                guard let windowHandle = handleResolver.handleForSnapshotWindow(
                    bundleId: bundleId,
                    snapshotWindow: snapshotWindow,
                    allSnapshotWindows: orderedSnapshotWindows
                ) else {
                    DeskJigLog.debug(.restorationTrace, "minimizeNonMatchingOpenByPathWindows: no handle found by id/title", fields: [
                        "bundleId": bundleId,
                        "windowId": "\(snapshotWindow.windowId)",
                        "title": snapshotWindow.title ?? "nil",
                        "authoritativeTmuxBundle": "\(tmuxManagedTerminalBundles.contains(bundleId))"
                    ], runId: runId)
                    continue
                }

                if bundleId == OpenByPathBundleIdentifiers.xcode,
                   Self.cgWindowId(fromAXWindowNumber: windowHandle.windowId) == nil {
                    let snapshotResolvedPath = windowPath
                    let handleResolvedPath = observedOpenPath(
                        for: windowHandle.documentPath,
                        bundleId: bundleId
                    )
                    let snapshotIsWorkspacePath = snapshotResolvedPath.map { path in
                        workspacePaths.contains(where: { expected in
                            pathMatchesExpectedDirectory(
                                observedPath: path,
                                expectedDirectory: expected,
                                bundleId: bundleId
                            )
                        })
                    } ?? false
                    let handleIsWorkspacePath = handleResolvedPath.map { path in
                        workspacePaths.contains(where: { expected in
                            pathMatchesExpectedDirectory(
                                observedPath: path,
                                expectedDirectory: expected,
                                bundleId: bundleId
                            )
                        })
                    } ?? false
                    // #500: the title+frame identity proof below reads snapshot state —
                    // refresh (once per phase) so it reflects current AX values. A handle
                    // whose window vanished has nothing left to minimize.
                    guard handleResolver.refreshedForTieBreak(windowHandle) != nil else {
                        DeskJigLog.debug(.restorationTrace, "minimizeNonMatchingOpenByPathWindows: Xcode handle vanished before identity check (skip)", fields: [
                            "bundleId": bundleId,
                            "snapshotWindowId": "\(snapshotWindow.windowId)",
                            "title": snapshotWindow.title ?? "nil"
                        ], runId: runId)
                        continue
                    }
                    let titleMatchesSnapshot = windowHandle.title == snapshotWindow.title
                    let frameMatchesSnapshot = windowHandle.frame.map { frame in
                        frameMatches(frame, snapshotWindow.frame, tolerance: 20.0)
                    } ?? false

                    // Xcode AX window numbers can transiently fail to resolve to CG window IDs.
                    // Allow minimizing only when we can still safely prove this is a non-workspace
                    // window via path mismatch and/or title+frame identity.
                    //
                    // Important: if the handle path resolves to a workspace path, fail closed
                    // even when snapshot path suggests otherwise. Duplicate Xcode titles/frames
                    // can cause handle/snapshot crossover, and minimizing in that state can
                    // demote the just-restored workspace window.
                    let canSafelyMinimizeWithoutResolvedId =
                        (handleResolvedPath != nil && !handleIsWorkspacePath) ||
                        (handleResolvedPath == nil &&
                         snapshotResolvedPath != nil &&
                         !snapshotIsWorkspacePath &&
                         titleMatchesSnapshot &&
                         frameMatchesSnapshot)

                    if !canSafelyMinimizeWithoutResolvedId {
                        DeskJigLog.debug(.restorationTrace, "minimizeNonMatchingOpenByPathWindows: unresolved handle ID for Xcode (fail closed)", fields: [
                            "bundleId": bundleId,
                            "snapshotWindowId": "\(snapshotWindow.windowId)",
                            "title": snapshotWindow.title ?? "nil"
                        ], runId: runId)
                        continue
                    }

                    DeskJigLog.debug(.restorationTrace, "minimizeNonMatchingOpenByPathWindows: unresolved handle ID for Xcode (safe fallback minimize)", fields: [
                        "bundleId": bundleId,
                        "snapshotWindowId": "\(snapshotWindow.windowId)",
                        "title": snapshotWindow.title ?? "nil",
                        "snapshotPath": snapshotResolvedPath ?? "nil",
                        "handlePath": handleResolvedPath ?? "nil"
                    ], runId: runId)
                }

                if let resolvedHandleId = Self.cgWindowId(fromAXWindowNumber: windowHandle.windowId),
                   resolvedHandleId != snapshotWindow.windowId {
                    DeskJigLog.debug(.restorationTrace, "minimizeNonMatchingOpenByPathWindows: resolved mismatched handle (fail closed)", fields: [
                        "bundleId": bundleId,
                        "snapshotWindowId": "\(snapshotWindow.windowId)",
                        "resolvedWindowId": "\(resolvedHandleId)",
                        "title": snapshotWindow.title ?? "nil"
                    ], runId: runId)
                    continue
                }

                // Minimize this non-workspace window
                DeskJigLog.debug(.restorationTrace, "minimizeNonMatchingOpenByPathWindows: minimizing", fields: [
                    "bundleId": bundleId,
                    "reason": bundleId == OpenByPathBundleIdentifiers.xcode
                        ? XcodeIdentityTraceReason.xcodeWindowLevelDemotion.rawValue
                        : (tmuxManagedTerminalBundles.contains(bundleId) ? "authoritative-tmux-stale-window" : "nonWorkspaceWindow"),
                    "windowId": "\(snapshotWindow.windowId)",
                    "title": snapshotWindow.title ?? "nil",
                    "documentPath": snapshotWindow.documentPath ?? "nil",
                    "ideDocumentPath": snapshotWindow.ideDocumentPath ?? "nil",
                    "freshWorkingDir": snapshotWindow.freshWorkingDirectory ?? "nil",
                    "authoritativeTmuxWindowIds": authoritativeTmuxWindowIds.map { "\($0)" }.joined(separator: ",")
                ], runId: runId)
                _ = windowHandle.minimize()
                minimizedCount += 1
            }

            if minimizedCount > 0 || skippedCount > 0 {
                DeskJigLog.debug(.restorationTrace, "minimizeNonMatchingOpenByPathWindows: bundle summary", fields: [
                    "bundleId": bundleId,
                    "windowCount": "\(snapshotWindows.count)",
                    "minimized": "\(minimizedCount)",
                    "skippedWorkspace": "\(skippedCount)"
                ], runId: runId)
            }

            totalMinimized += minimizedCount
            totalSkipped += skippedCount
        }

        DeskJigLog.debug(.restorationTrace, "minimizeNonMatchingOpenByPathWindows: complete", fields: [
            "totalMinimized": "\(totalMinimized)",
            "totalSkippedWorkspace": "\(totalSkipped)"
        ], runId: runId)
    }

    /// Minimizes windows from multi-window apps (IDEs, terminals) that are NOT part of the workspace.
    /// This handles the case where the same app (e.g., Cursor) has multiple project windows open,
    /// but only some are part of the current workspace.
    public func minimizeNonWorkspaceWindows(
        workspaceWindows: [WorkspaceWindow],
        snapshot: SystemSnapshot,
        runId: String,
        workspaceScreens: [WorkspaceScreen]?,
        protectedWindowIds: Set<CGWindowID> = [],
        bundlesWithAuthoritativeRestore: Set<String> = []
    ) {
        let multiWindowBundleIds: Set<String> = [
            OpenByPathBundleIdentifiers.cursor,
            OpenByPathBundleIdentifiers.codex,
            OpenByPathBundleIdentifiers.vscode,
            OpenByPathBundleIdentifiers.xcode,
            OpenByPathBundleIdentifiers.ghostty,
            OpenByPathBundleIdentifiers.terminal,
            OpenByPathBundleIdentifiers.iterm2,
            OpenByPathBundleIdentifiers.kitty,
            OpenByPathBundleIdentifiers.alacritty
        ]

        let chromeBundleIds: Set<String> = [
            "com.google.Chrome",
            "com.google.Chrome.beta",
            "com.google.Chrome.dev",
            "com.google.Chrome.canary"
        ]

        let terminalBundleIds: Set<String> = [
            OpenByPathBundleIdentifiers.ghostty,
            OpenByPathBundleIdentifiers.terminal,
            OpenByPathBundleIdentifiers.iterm2,
            OpenByPathBundleIdentifiers.kitty,
            OpenByPathBundleIdentifiers.alacritty
        ]

        let ideBundleIds: Set<String> = [
            OpenByPathBundleIdentifiers.cursor,
            OpenByPathBundleIdentifiers.codex,
            OpenByPathBundleIdentifiers.vscode,
            OpenByPathBundleIdentifiers.xcode
        ]

        let workspaceBundleIds = Set(workspaceWindows.map { $0.bundleIdentifier })
        let relevantBundleIds = workspaceBundleIds.intersection(multiWindowBundleIds.union(chromeBundleIds))
        let genericWorkspaceApps = workspaceBundleIds.subtracting(multiWindowBundleIds.union(chromeBundleIds))

        guard !relevantBundleIds.isEmpty || !genericWorkspaceApps.isEmpty else {
            DeskJigLog.debug(.restorationTrace, "minimizeNonWorkspaceWindows: no workspace app bundles to process", runId: runId)
            return
        }

        let handleResolver = WindowHandleResolver(
            service: self,
            terminalBundleIds: terminalBundleIds,
            resolveTerminalTitles: false,
            frameMatchFallback: false
        )

        let allWorkspacePaths = Set(workspaceWindows.compactMap { normalizeOpenPath($0.openPath) })
        let workspacePathsByBundle = Dictionary(grouping: workspaceWindows, by: { $0.bundleIdentifier })
            .mapValues { windows in
                Set(windows.compactMap { normalizeOpenPath($0.openPath) })
            }
        let workspacePathSlotsByBundle = Dictionary(grouping: workspaceWindows, by: { $0.bundleIdentifier })
            .mapValues { windows in
                windows.compactMap { normalizeOpenPath($0.openPath) }
            }
        let workspaceTokensByBundle = workspacePathsByBundle.mapValues { paths in
            paths.map { URL(fileURLWithPath: $0).lastPathComponent }.filter { !$0.isEmpty }
        }
        let xcodeHashesByWindowId = xcodeHandleHashesByWindowId()

        DeskJigLog.debug(.restorationTrace, "minimizeNonWorkspaceWindows: starting", fields: [
            "relevantBundleIds": relevantBundleIds.joined(separator: ", "),
            "workspacePathCount": "\(allWorkspacePaths.count)"
        ], runId: runId)

        // Hide apps that have NO workspace windows (Command+H style - instant, users can easily unhide)
        // Never hide DeskJig itself
        let currentBundleId = Bundle.main.bundleIdentifier
        var hiddenAppCount = 0
        for app in NSWorkspace.shared.runningApplications {
            guard app.activationPolicy == .regular,
                  let bundleId = app.bundleIdentifier,
                  !workspaceBundleIds.contains(bundleId),
                  bundleId != currentBundleId,
                  !app.isHidden else { continue }
            _ = app.hide()
            hiddenAppCount += 1
        }

        if hiddenAppCount > 0 {
            DeskJigLog.debug(.restorationTrace, "minimizeNonWorkspaceWindows: hidden apps with no workspace windows", fields: [
                "hiddenAppCount": "\(hiddenAppCount)"
            ], runId: runId)
        }

        var snapshotWindowsByBundle: [String: [SnapshotWindow]] = [:]
        for window in snapshot.windows {
            guard let bundleId = window.bundleId else { continue }
            snapshotWindowsByBundle[bundleId, default: []].append(window)
        }

        for bundleId in relevantBundleIds {
            guard let snapshotWindows = snapshotWindowsByBundle[bundleId] else { continue }
            let appWorkspaceWindows = workspaceWindows.filter { $0.bundleIdentifier == bundleId }

            if chromeBundleIds.contains(bundleId) {
                let chromeWorkspaceWindows = workspaceWindows.filter { $0.bundleIdentifier == bundleId }

                // Early exit: skip Chrome entirely if not in workspace (avoid expensive AppleScript call)
                guard !chromeWorkspaceWindows.isEmpty else {
                    DeskJigLog.debug(.restorationTrace, "minimizeNonWorkspaceWindows: skip Chrome (not in workspace)", fields: [
                        "bundleId": bundleId
                    ], runId: runId)
                    continue
                }

                // Skip if workspace uses "anyWindow" mode
                if chromeWorkspaceWindows.contains(where: { $0.chromeState?.profileMatchMode == .anyWindow }) {
                    DeskJigLog.debug(.restorationTrace, "minimizeNonWorkspaceWindows: skip Chrome (anyWindow)", fields: [
                        "bundleId": bundleId
                    ], runId: runId)
                    continue
                }

                // Get workspace profiles to preserve - use directory-based matching for accuracy
                var workspaceProfileDirectories = Set<String>()
                var workspaceAppleScriptNames = Set<String>()
                for window in chromeWorkspaceWindows {
                    // Primary: Use profile directory (most reliable)
                    if let dir = window.chromeState?.profileDirectory, !dir.isEmpty {
                        workspaceProfileDirectories.insert(dir)
                        // Also resolve to AppleScript name for matching
                        if let profile = chromeProfileManager.profile(forDirectory: dir) {
                            workspaceAppleScriptNames.insert(profile.appleScriptName)
                        }
                    }
                    // Fallback: Use AppleScript name directly
                    if let profile = window.chromeState?.appleScriptProfileName, !profile.isEmpty {
                        workspaceAppleScriptNames.insert(profile)
                    }
                }

                guard !workspaceProfileDirectories.isEmpty || !workspaceAppleScriptNames.isEmpty else {
                    DeskJigLog.debug(.restorationTrace, "minimizeNonWorkspaceWindows: skip Chrome (no workspace profiles)", fields: [
                        "bundleId": bundleId
                    ], runId: runId)
                    continue
                }

                // Use AX window titles to infer profiles (avoid expensive AppleScript capture).
                let currentChromeWindows = handleResolver.bundleHandles(bundleId)

                DeskJigLog.debug(.restorationTrace, "minimizeNonWorkspaceWindows: Chrome captured current state", fields: [
                    "bundleId": bundleId,
                    "workspaceProfileDirs": workspaceProfileDirectories.joined(separator: ","),
                    "workspaceAppleScriptNames": workspaceAppleScriptNames.joined(separator: ","),
                    "currentWindowCount": "\(currentChromeWindows.count)",
                    "currentProfiles": currentChromeWindows.compactMap { handle in
                        guard let title = handle.title else { return nil }
                        return ChromeAutomationService.parseProfileName(from: title)
                    }.joined(separator: ",")
                ], runId: runId)

                let expectedWorkspaceWindowCount = chromeWorkspaceWindows.count
                var workspaceChromeWindowIds = Set(
                    snapshotWindows
                        .filter { protectedWindowIds.contains($0.windowId) }
                        .map(\.windowId)
                )

                if workspaceChromeWindowIds.isEmpty {
                    let matchingWorkspaceSnapshots = snapshotWindows.filter { snapshotWindow in
                        guard let title = snapshotWindow.title else { return false }
                        let parsedProfile = ChromeAutomationService.parseProfileName(from: title)
                        let resolvedProfile: String?
                        if let parsedProfile {
                            resolvedProfile = parsedProfile
                        } else if workspaceAppleScriptNames.count == 1 {
                            resolvedProfile = workspaceAppleScriptNames.first
                        } else {
                            resolvedProfile = nil
                        }
                        guard let profileName = resolvedProfile else { return false }

                        let chromeProfile = chromeProfileManager.profile(forAppleScriptName: profileName)
                        let profileDirectory = chromeProfile?.directory ?? ""

                        if !profileDirectory.isEmpty && workspaceProfileDirectories.contains(profileDirectory) {
                            return true
                        }

                        return workspaceAppleScriptNames.contains(profileName)
                    }

                    let keptWindows = matchingWorkspaceSnapshots.sorted { lhs, rhs in
                        let lhsZ = lhs.zOrderIndex ?? Int.max
                        let rhsZ = rhs.zOrderIndex ?? Int.max
                        if lhsZ != rhsZ {
                            return lhsZ < rhsZ
                        }
                        return lhs.windowId < rhs.windowId
                    }
                    workspaceChromeWindowIds = Set(keptWindows.prefix(expectedWorkspaceWindowCount).map(\.windowId))
                }

                DeskJigLog.debug(.restorationTrace, "minimizeNonWorkspaceWindows: Chrome workspace windows", fields: [
                    "bundleId": bundleId,
                    "expectedWorkspaceCount": "\(expectedWorkspaceWindowCount)",
                    "workspaceWindowIds": workspaceChromeWindowIds.map { "\($0)" }.joined(separator: ",")
                ], runId: runId)

                // Minimize Chrome windows that are not one of the restored workspace windows,
                // even when they share the same profile.
                var minimizedCount = 0
                for chromeWindow in currentChromeWindows {
                    guard let resolvedWindowId = Self.cgWindowId(fromAXWindowNumber: chromeWindow.windowId) else {
                        continue
                    }
                    if workspaceChromeWindowIds.contains(resolvedWindowId) {
                        continue // This is a workspace window, don't minimize
                    }

                    DeskJigLog.debug(.restorationTrace, "Minimizing non-workspace Chrome window", fields: [
                        "bundleId": bundleId,
                        "windowId": "\(resolvedWindowId)",
                        "title": chromeWindow.title ?? "nil"
                    ], runId: runId)
                    _ = chromeWindow.minimize()
                    minimizedCount += 1
                }

                if minimizedCount > 0 {
                    DeskJigLog.debug(.restorationTrace, "minimizeNonWorkspaceWindows: Chrome summary", fields: [
                        "bundleId": bundleId,
                        "workspaceWindowIds": workspaceChromeWindowIds.map { "\($0)" }.joined(separator: ","),
                        "minimized": "\(minimizedCount)"
                    ], runId: runId)
                }
                continue
            }
            let workspaceOpenPaths = workspacePathsByBundle[bundleId] ?? []
            let workspacePathSlots = workspacePathSlotsByBundle[bundleId] ?? []
            let workspaceTokens = workspaceTokensByBundle[bundleId] ?? []
            let orderedSnapshotWindows = snapshotWindows.sorted { lhs, rhs in
                let lhsZ = lhs.zOrderIndex ?? Int.max
                let rhsZ = rhs.zOrderIndex ?? Int.max
                if lhsZ != rhsZ {
                    return lhsZ < rhsZ
                }
                if lhs.windowId != rhs.windowId {
                    return lhs.windowId < rhs.windowId
                }
                let lhsHash = xcodeHashesByWindowId[lhs.windowId] ?? 0
                let rhsHash = xcodeHashesByWindowId[rhs.windowId] ?? 0
                return lhsHash < rhsHash
            }

            guard !workspaceOpenPaths.isEmpty else {
                DeskJigLog.debug(.restorationTrace, "minimizeNonWorkspaceWindows: skip bundle (no workspace paths)", fields: [
                    "bundleId": bundleId
                ], runId: runId)
                continue
            }

            func resolveWindowPath(_ window: SnapshotWindow) -> String? {
                if terminalBundleIds.contains(bundleId) {
                    return normalizeOpenPath(window.freshWorkingDirectory)
                        ?? normalizeOpenPath(window.documentPath)
                }
                if ideBundleIds.contains(bundleId) {
                    return observedOpenPath(
                        for: window.ideDocumentPath ?? window.documentPath,
                        bundleId: bundleId
                    )
                }
                return normalizeOpenPath(window.documentPath)
            }

            func isWorkspaceWindow(_ window: SnapshotWindow) -> Bool {
                let resolvedPath = resolveWindowPath(window)
                if let path = resolvedPath, workspaceOpenPaths.contains(where: { expected in
                    pathMatchesExpectedDirectory(observedPath: path, expectedDirectory: expected, bundleId: bundleId)
                }) {
                    return true
                }
                if bundleId != OpenByPathBundleIdentifiers.xcode,
                   let title = window.title,
                   !workspaceTokens.isEmpty {
                    // For Xcode, if we know the path and it isn't a workspace path,
                    // don't let basename/title fallback keep the wrong window.
                    return workspaceTokens.contains(where: { titleContainsFolder(title, folderName: $0) })
                }
                return false
            }

            var workspaceWindowIds = Set<CGWindowID>()
            if bundleId == OpenByPathBundleIdentifiers.xcode {
                let xcodeCoverageSelection = selectXcodeCoverageWindowIds(
                    expectedPathSlots: workspacePathSlots,
                    snapshotWindows: orderedSnapshotWindows,
                    protectedWindowIds: Set(snapshotWindows.filter { protectedWindowIds.contains($0.windowId) }.map(\.windowId)),
                    xcodeHashesByWindowId: xcodeHashesByWindowId
                )
                workspaceWindowIds = xcodeCoverageSelection.coverageWindowIds
                DeskJigLog.trace(.restorationTrace, "minimizeNonWorkspaceWindows: Xcode coverage topology", fields: [
                    "bundleId": bundleId,
                    "reason": XcodeIdentityTraceReason.pathConfirmedSelection.rawValue,
                    "expectedPathSlots": xcodeCoverageSelection.topology.expectedPathSlots.joined(separator: " | "),
                    "observedPathSlots": xcodeCoverageSelection.topology.observedPathSlots.joined(separator: " | "),
                    "missingPathSlots": xcodeCoverageSelection.topology.missingPathSlots.joined(separator: " | "),
                    "duplicatePathSlots": xcodeCoverageSelection.topology.duplicatePathSlots.joined(separator: " | "),
                    "coverageWindowIds": workspaceWindowIds.map { "\($0)" }.joined(separator: ",")
                ], runId: runId)
            } else {
                for snapshotWindow in orderedSnapshotWindows {
                    guard isWorkspaceWindow(snapshotWindow) else { continue }
                    workspaceWindowIds.insert(snapshotWindow.windowId)
                }
            }

            // Also protect windows from protectedWindowIds (same pattern as generic apps)
            let protectedAppIds = Set(snapshotWindows
                .filter { protectedWindowIds.contains($0.windowId) }
                .map { $0.windowId })
            if !protectedAppIds.isEmpty {
                let effectiveProtectedIds: Set<CGWindowID>
                if bundleId == OpenByPathBundleIdentifiers.xcode {
                    // Xcode window IDs can churn after restoration. Keep only protected IDs
                    // that still participate in path-confirmed workspace coverage.
                    effectiveProtectedIds = protectedAppIds.intersection(workspaceWindowIds)
                    let staleProtectedIds = protectedAppIds.subtracting(effectiveProtectedIds)
                    if !staleProtectedIds.isEmpty {
                        DeskJigLog.debug(.restorationTrace, "minimizeNonWorkspaceWindows: ignoring stale protected Xcode windows", fields: [
                            "bundleId": bundleId,
                            "staleProtectedIds": staleProtectedIds.map { "\($0)" }.joined(separator: ","),
                            "coverageWindowIds": workspaceWindowIds.map { "\($0)" }.joined(separator: ",")
                        ], runId: runId)
                    }
                } else {
                    effectiveProtectedIds = protectedAppIds
                }
                workspaceWindowIds.formUnion(effectiveProtectedIds)
                DeskJigLog.trace(.restorationTrace, "minimizeNonWorkspaceWindows: protected terminal/IDE windows", fields: [
                    "bundleId": bundleId,
                    "protectedCount": "\(effectiveProtectedIds.count)",
                    "protectedIds": effectiveProtectedIds.map { "\($0)" }.joined(separator: ",")
                ], runId: runId)

                // For authoritative relaunches and for Xcode path restoration, prefer restored
                // window IDs over broad path/title matches so stale duplicates are minimized.
                let shouldDemoteToProtectedOnly = bundlesWithAuthoritativeRestore.contains(bundleId)
                    || bundleId == OpenByPathBundleIdentifiers.xcode
                if shouldDemoteToProtectedOnly, bundleId != OpenByPathBundleIdentifiers.xcode {
                    let removedIds = workspaceWindowIds.subtracting(protectedAppIds)
                    if !removedIds.isEmpty {
                        workspaceWindowIds = workspaceWindowIds.intersection(protectedAppIds)
                        DeskJigLog.debug(.restorationTrace, "minimizeNonWorkspaceWindows: demoted old windows for protected restore", fields: [
                            "bundleId": bundleId,
                            "demotedCount": "\(removedIds.count)",
                            "demotedIds": removedIds.map { "\($0)" }.joined(separator: ",")
                        ], runId: runId)
                    }
                }
            }

            // Keep terminal workspace coverage cardinality-aware so duplicate windows
            // (especially tmux extras) are minimized at window level rather than
            // treated as full workspace coverage.
            let expectedWorkspaceWindowCount = appWorkspaceWindows.count
            if terminalBundleIds.contains(bundleId),
               expectedWorkspaceWindowCount > 0,
               workspaceWindowIds.count > expectedWorkspaceWindowCount {
                let preferredWindowIds = Set(orderedSnapshotWindows
                    .filter { workspaceWindowIds.contains($0.windowId) }
                    .sorted { lhs, rhs in
                        let lhsProtected = protectedAppIds.contains(lhs.windowId)
                        let rhsProtected = protectedAppIds.contains(rhs.windowId)
                        if lhsProtected != rhsProtected {
                            return lhsProtected
                        }

                        let lhsWorkspaceMatch = isWorkspaceWindow(lhs)
                        let rhsWorkspaceMatch = isWorkspaceWindow(rhs)
                        if lhsWorkspaceMatch != rhsWorkspaceMatch {
                            return lhsWorkspaceMatch
                        }

                        let lhsZ = lhs.zOrderIndex ?? Int.max
                        let rhsZ = rhs.zOrderIndex ?? Int.max
                        if lhsZ != rhsZ {
                            return lhsZ < rhsZ
                        }
                        return lhs.windowId < rhs.windowId
                    }
                    .prefix(expectedWorkspaceWindowCount)
                    .map(\.windowId))
                let trimmedIds = workspaceWindowIds.subtracting(preferredWindowIds)
                workspaceWindowIds = Set(preferredWindowIds)

                DeskJigLog.debug(.restorationTrace, "minimizeNonWorkspaceWindows: trimmed terminal workspace coverage", fields: [
                    "bundleId": bundleId,
                    "expectedWorkspaceCount": "\(expectedWorkspaceWindowCount)",
                    "candidateCount": "\(snapshotWindows.count)",
                    "keptCount": "\(workspaceWindowIds.count)",
                    "trimmedCount": "\(trimmedIds.count)",
                    "trimmedWindowIds": trimmedIds.map { "\($0)" }.joined(separator: ",")
                ], runId: runId)
            }

            if workspaceWindowIds.isEmpty,
               bundlesWithAuthoritativeRestore.contains(bundleId),
               bundleId != OpenByPathBundleIdentifiers.xcode {
                let fallbackCandidates = snapshotWindows.filter { window in
                    window.isOnScreen && window.isMinimized != true
                }
                let fallbackWorkspaceWindow = fallbackCandidates.sorted { lhs, rhs in
                    let lhsZ = lhs.zOrderIndex ?? Int.max
                    let rhsZ = rhs.zOrderIndex ?? Int.max
                    if lhsZ != rhsZ {
                        return lhsZ < rhsZ
                    }
                    return lhs.windowId < rhs.windowId
                }.first

                if let fallbackWorkspaceWindow {
                    workspaceWindowIds.insert(fallbackWorkspaceWindow.windowId)
                    DeskJigLog.debug(.restorationTrace, "minimizeNonWorkspaceWindows: authoritative fallback workspace window selected", fields: [
                        "bundleId": bundleId,
                        "windowId": "\(fallbackWorkspaceWindow.windowId)",
                        "title": fallbackWorkspaceWindow.title ?? "nil",
                        "reason": "no-workspace-match-windowid-churn"
                    ], runId: runId)
                }
            }

            guard !workspaceWindowIds.isEmpty else {
                DeskJigLog.debug(.restorationTrace, "minimizeNonWorkspaceWindows: skip bundle (no workspace matches)", fields: [
                    "bundleId": bundleId
                ], runId: runId)
                continue
            }

            var minimizedCount = 0
            // For PID+frame fallback: cap minimizations to the genuine excess count
            // and track used handles so each AX handle is only minimized once.
            let visibleOnScreenCount = orderedSnapshotWindows.filter {
                $0.isOnScreen && $0.isMinimized != true
            }.count
            let maxFallbackMinimizations = max(0, visibleOnScreenCount - expectedWorkspaceWindowCount)
            var fallbackMinimizedCount = 0
            var usedFallbackHandleIds = Set<Int>()

            // Minimize ALL non-workspace windows (removed z-order filtering that skipped windows behind workspace)
            for snapshotWindow in orderedSnapshotWindows {
                if workspaceWindowIds.contains(snapshotWindow.windowId) { continue }
                if snapshotWindow.isMinimized == true { continue }
                if snapshotWindow.isOnScreen == false { continue }

                var windowHandle = handleResolver.handleForSnapshotWindow(
                    bundleId: bundleId,
                    snapshotWindow: snapshotWindow,
                    allSnapshotWindows: orderedSnapshotWindows
                )

                // PID + frame fallback for terminal bundles: when normal handle resolution fails
                // (stale window IDs, nil titles), enumerate AX handles for the same PID and pick
                // the one whose frame is closest to the snapshot window's frame.
                // Guards: only activate when (1) visible windows exceed expected count,
                // (2) we haven't already minimized enough extras, (3) handle not already used.
                // Exclude Terminal.app — it has dedicated cleanup (closeExtraWindowsIfIdle)
                // and its CGWindowList titles are populated, so normal resolution works.
                // The PID+frame fallback is primarily needed for Ghostty/kitty where
                // CGWindowList returns nil titles.
                if windowHandle == nil,
                   terminalBundleIds.contains(bundleId),
                   bundleId != OpenByPathBundleIdentifiers.terminal,
                   maxFallbackMinimizations > 0,
                   fallbackMinimizedCount < maxFallbackMinimizations {
                    let allHandles = handleResolver.bundleHandles(bundleId)
                    let samePidHandles = allHandles.filter { $0.processID == snapshotWindow.pid }
                    // Exclude handles that resolve to workspace/protected windows or were already used
                    let candidateHandles = samePidHandles.filter { handle in
                        if let handleId = handle.windowId, usedFallbackHandleIds.contains(handleId) {
                            return false
                        }
                        if let resolvedId = Self.cgWindowId(fromAXWindowNumber: handle.windowId) {
                            if workspaceWindowIds.contains(resolvedId) { return false }
                            if protectedWindowIds.contains(resolvedId) { return false }
                        }
                        return true
                    }
                    // #500: refresh before the frame-distance selection so it compares
                    // current AX frames, not enumeration-time snapshots.
                    if let bestMatch = handleResolver.refreshedForTieBreak(candidateHandles).min(by: { lhs, rhs in
                        guard let lhsFrame = lhs.frame, let rhsFrame = rhs.frame else {
                            return lhs.frame != nil
                        }
                        return frameDistance(lhsFrame, snapshotWindow.frame) < frameDistance(rhsFrame, snapshotWindow.frame)
                    }), let bestFrame = bestMatch.frame, frameDistance(bestFrame, snapshotWindow.frame) < 200 {
                        windowHandle = bestMatch
                        if let handleId = bestMatch.windowId {
                            usedFallbackHandleIds.insert(handleId)
                        }
                        fallbackMinimizedCount += 1
                        DeskJigLog.debug(.restorationTrace, "minimizeNonWorkspaceWindows: PID+frame fallback resolved handle for terminal", fields: [
                            "bundleId": bundleId,
                            "snapshotWindowId": "\(snapshotWindow.windowId)",
                            "snapshotPid": "\(snapshotWindow.pid)",
                            "matchedHandleFrame": "\(bestFrame)",
                            "snapshotFrame": "\(snapshotWindow.frame)",
                            "frameDistance": "\(frameDistance(bestFrame, snapshotWindow.frame))",
                            "fallbackBudget": "\(fallbackMinimizedCount)/\(maxFallbackMinimizations)"
                        ], runId: runId)
                    }
                }

                guard let windowHandle else {
                    DeskJigLog.debug(.restorationTrace, "minimizeNonWorkspaceWindows: no handle found by id/title (IDE/terminal)", fields: [
                        "bundleId": bundleId,
                        "windowId": "\(snapshotWindow.windowId)",
                        "title": snapshotWindow.title ?? "nil"
                    ], runId: runId)
                    continue
                }

                if bundleId == OpenByPathBundleIdentifiers.xcode,
                   Self.cgWindowId(fromAXWindowNumber: windowHandle.windowId) == nil {
                    let snapshotResolvedPath = resolveWindowPath(snapshotWindow)
                    let handleResolvedPath = observedOpenPath(
                        for: windowHandle.documentPath,
                        bundleId: bundleId
                    )
                    let snapshotIsWorkspacePath = snapshotResolvedPath.map { path in
                        workspaceOpenPaths.contains(where: { expected in
                            pathMatchesExpectedDirectory(
                                observedPath: path,
                                expectedDirectory: expected,
                                bundleId: bundleId
                            )
                        })
                    } ?? false
                    let handleIsWorkspacePath = handleResolvedPath.map { path in
                        workspaceOpenPaths.contains(where: { expected in
                            pathMatchesExpectedDirectory(
                                observedPath: path,
                                expectedDirectory: expected,
                                bundleId: bundleId
                            )
                        })
                    } ?? false
                    // #500: the title+frame identity proof below reads snapshot state —
                    // refresh (once per phase) so it reflects current AX values. A handle
                    // whose window vanished has nothing left to minimize.
                    guard handleResolver.refreshedForTieBreak(windowHandle) != nil else {
                        DeskJigLog.debug(.restorationTrace, "minimizeNonWorkspaceWindows: Xcode handle vanished before identity check (skip)", fields: [
                            "bundleId": bundleId,
                            "snapshotWindowId": "\(snapshotWindow.windowId)",
                            "title": snapshotWindow.title ?? "nil"
                        ], runId: runId)
                        continue
                    }
                    let titleMatchesSnapshot = windowHandle.title == snapshotWindow.title
                    let frameMatchesSnapshot = windowHandle.frame.map { frame in
                        frameMatches(frame, snapshotWindow.frame, tolerance: 20.0)
                    } ?? false

                    // Xcode AX window numbers can transiently fail to resolve to CG window IDs.
                    // Allow minimizing only when we can still safely prove this is a non-workspace
                    // window via path mismatch and/or title+frame identity.
                    //
                    // Important: if the handle path resolves to a workspace path, fail closed
                    // even when snapshot path suggests otherwise. Duplicate Xcode titles/frames
                    // can cause handle/snapshot crossover, and minimizing in that state can
                    // demote the just-restored workspace window.
                    let canSafelyMinimizeWithoutResolvedId =
                        (handleResolvedPath != nil && !handleIsWorkspacePath) ||
                        (handleResolvedPath == nil &&
                         snapshotResolvedPath != nil &&
                         !snapshotIsWorkspacePath &&
                         titleMatchesSnapshot &&
                         frameMatchesSnapshot)

                    if !canSafelyMinimizeWithoutResolvedId {
                        DeskJigLog.debug(.restorationTrace, "minimizeNonWorkspaceWindows: unresolved handle ID for Xcode (fail closed)", fields: [
                            "bundleId": bundleId,
                            "snapshotWindowId": "\(snapshotWindow.windowId)",
                            "title": snapshotWindow.title ?? "nil"
                        ], runId: runId)
                        continue
                    }

                    DeskJigLog.debug(.restorationTrace, "minimizeNonWorkspaceWindows: unresolved handle ID for Xcode (safe fallback minimize)", fields: [
                        "bundleId": bundleId,
                        "snapshotWindowId": "\(snapshotWindow.windowId)",
                        "title": snapshotWindow.title ?? "nil",
                        "snapshotPath": snapshotResolvedPath ?? "nil",
                        "handlePath": handleResolvedPath ?? "nil"
                    ], runId: runId)
                }

                if let resolvedHandleId = Self.cgWindowId(fromAXWindowNumber: windowHandle.windowId),
                   resolvedHandleId != snapshotWindow.windowId {
                    DeskJigLog.debug(.restorationTrace, "minimizeNonWorkspaceWindows: resolved mismatched handle (fail closed)", fields: [
                        "bundleId": bundleId,
                        "snapshotWindowId": "\(snapshotWindow.windowId)",
                        "resolvedWindowId": "\(resolvedHandleId)",
                        "title": snapshotWindow.title ?? "nil"
                    ], runId: runId)
                    continue
                }

                DeskJigLog.debug(.restorationTrace, "Minimizing non-workspace window", fields: [
                    "bundleId": bundleId,
                    "reason": bundleId == OpenByPathBundleIdentifiers.xcode
                        ? XcodeIdentityTraceReason.xcodeWindowLevelDemotion.rawValue
                        : "nonWorkspaceWindow",
                    "windowId": "\(snapshotWindow.windowId)",
                    "title": snapshotWindow.title ?? "nil",
                    "docPath": snapshotWindow.documentPath ?? "nil",
                    "idePath": snapshotWindow.ideDocumentPath ?? "nil",
                    "freshWorkingDir": snapshotWindow.freshWorkingDirectory ?? "nil"
                ], runId: runId)
                _ = windowHandle.minimize()
                minimizedCount += 1
            }

            if minimizedCount > 0 {
                DeskJigLog.debug(.restorationTrace, "minimizeNonWorkspaceWindows: bundle summary", fields: [
                    "bundleId": bundleId,
                    "workspaceMatches": "\(workspaceWindowIds.count)",
                    "minimized": "\(minimizedCount)"
                ], runId: runId)
            }
        }

        // Handle generic workspace apps that are not in the special-cased bundle lists.
        // These apps don't have openPath, so we match workspace windows by frame proximity + title.
        for bundleId in genericWorkspaceApps {
            let appWorkspaceWindows = workspaceWindows.filter { $0.bundleIdentifier == bundleId }
            guard !appWorkspaceWindows.isEmpty else { continue }

            guard let snapshotWindows = snapshotWindowsByBundle[bundleId], !snapshotWindows.isEmpty else { continue }

            // Match workspace windows to snapshot windows by frame proximity + title
            var workspaceWindowIds = Set<CGWindowID>()
            for wsWindow in appWorkspaceWindows {
                if let match = findBestSnapshotMatch(
                    workspaceWindow: wsWindow,
                    candidates: snapshotWindows,
                    workspaceScreens: workspaceScreens
                ) {
                    workspaceWindowIds.insert(match.windowId)
                }
            }

            // Also protect windows from protectedWindowIds
            if !protectedWindowIds.isEmpty {
                let protectedAppIds = snapshotWindows
                    .filter { protectedWindowIds.contains($0.windowId) }
                    .map { $0.windowId }
                if !protectedAppIds.isEmpty {
                    workspaceWindowIds.formUnion(protectedAppIds)
                    DeskJigLog.debug(.restorationTrace, "minimizeNonWorkspaceWindows: protected generic app windows", fields: [
                        "bundleId": bundleId,
                        "protectedCount": "\(protectedAppIds.count)",
                        "protectedIds": protectedAppIds.map { "\($0)" }.joined(separator: ",")
                    ], runId: runId)
                }
            }

            guard !workspaceWindowIds.isEmpty else {
                DeskJigLog.debug(.restorationTrace, "minimizeNonWorkspaceWindows: skip generic app (no workspace matches)", fields: [
                    "bundleId": bundleId
                ], runId: runId)
                continue
            }

            var minimizedCount = 0

            // Minimize all non-workspace windows from this app
            for snapshotWindow in snapshotWindows {
                if workspaceWindowIds.contains(snapshotWindow.windowId) { continue }
                if snapshotWindow.isMinimized == true { continue }
                if snapshotWindow.isOnScreen == false { continue }

                guard let snapshotTitle = snapshotWindow.title else { continue }

                guard let windowHandle = handleResolver.handleForSnapshotWindow(
                    bundleId: bundleId,
                    snapshotWindow: snapshotWindow,
                    allSnapshotWindows: snapshotWindows
                ) else {
                    DeskJigLog.debug(.restorationTrace, "minimizeNonWorkspaceWindows: no handle found by title (generic)", fields: [
                        "bundleId": bundleId,
                        "windowId": "\(snapshotWindow.windowId)",
                        "title": snapshotTitle
                    ], runId: runId)
                    continue
                }

                if let resolvedHandleId = Self.cgWindowId(fromAXWindowNumber: windowHandle.windowId),
                   resolvedHandleId != snapshotWindow.windowId {
                    DeskJigLog.debug(.restorationTrace, "minimizeNonWorkspaceWindows: resolved mismatched handle (generic, fail closed)", fields: [
                        "bundleId": bundleId,
                        "snapshotWindowId": "\(snapshotWindow.windowId)",
                        "resolvedWindowId": "\(resolvedHandleId)",
                        "title": snapshotTitle
                    ], runId: runId)
                    continue
                }

                DeskJigLog.debug(.restorationTrace, "Minimizing non-workspace window (generic app)", fields: [
                    "bundleId": bundleId,
                    "windowId": "\(snapshotWindow.windowId)",
                    "title": snapshotWindow.title ?? "nil"
                ], runId: runId)
                _ = windowHandle.minimize()
                minimizedCount += 1
            }

            if minimizedCount > 0 {
                DeskJigLog.debug(.restorationTrace, "minimizeNonWorkspaceWindows: generic app summary", fields: [
                    "bundleId": bundleId,
                    "workspaceMatches": "\(workspaceWindowIds.count)",
                    "minimized": "\(minimizedCount)"
                ], runId: runId)
            }
        }
    }

    func xcodeCoverageTopology(
        workspaceWindows: [WorkspaceWindow],
        snapshot: SystemSnapshot
    ) -> XcodeWindowCoverageTopology? {
        let expectedPathSlots = workspaceWindows
            .filter { $0.bundleIdentifier == OpenByPathBundleIdentifiers.xcode }
            .compactMap { normalizeOpenPath($0.openPath) }
        guard !expectedPathSlots.isEmpty else { return nil }

        let expectedPathSet = Set(expectedPathSlots)
        let observedPathSlots = snapshot.windows
            .filter { $0.bundleId == OpenByPathBundleIdentifiers.xcode }
            .compactMap { window -> String? in
                guard let observedPath = observedOpenPath(
                    for: window.ideDocumentPath ?? window.documentPath,
                    bundleId: OpenByPathBundleIdentifiers.xcode
                ) else {
                    return nil
                }
                return bestMatchingExpectedPath(
                    observedPath: observedPath,
                    expectedPaths: expectedPathSet,
                    bundleId: OpenByPathBundleIdentifiers.xcode
                )
            }

        return XcodeWindowCoverageTopology(
            expectedPathSlots: expectedPathSlots,
            observedPathSlots: observedPathSlots
        )
    }

    public func ensureWorkspaceWindowsOnTop(
        runId: String,
        workspaceWindows: [WorkspaceWindow],
        workspaceScreens: [WorkspaceScreen]?,
        shouldMinimizeWindowsInFront: Bool = true,
        forceRaiseWorkspaceWindows: Bool = false,
        preCapturedSnapshot: SystemSnapshot? = nil,
        completion: @escaping (Bool, Set<CGWindowID>) -> Void
    ) {
        var didAdjust = forceRaiseWorkspaceWindows
        var handledWindowIds = Set<CGWindowID>()
        DeskJigLog.debug(.restorationTrace, "ensureWorkspaceWindowsOnTop enter", fields: [
            "workspaceWindowsCount": workspaceWindows.count,
            "forceRaiseWorkspaceWindows": forceRaiseWorkspaceWindows
        ])

        Task { [weak self] in
            guard let self else {
                completion(didAdjust, handledWindowIds)
                return
            }

            let titledWindows = OpenByPathTitleAssigner.apply(to: workspaceWindows)
            let currentSnapshot: SystemSnapshot
            if let preCapturedSnapshot {
                currentSnapshot = preCapturedSnapshot
            } else {
                currentSnapshot = await SystemSnapshotCapture.captureQuickOnScreenOnly(runId: runId)
            }
            let currentWindows = self.windowInfosForZOrderChecks(from: currentSnapshot)
            let workspaceWindowIds = self.workspaceWindowIdsForZOrderChecks(
                workspaceWindows: titledWindows,
                snapshot: currentSnapshot
            )

            let finalize: () -> Void = { [weak self] in
                guard let self else {
                    completion(didAdjust, handledWindowIds)
                    return
                }

                if forceRaiseWorkspaceWindows {
                    self.forceRaiseWorkspaceWindows(workspaceWindows: titledWindows, workspaceScreens: workspaceScreens)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                        completion(didAdjust, handledWindowIds)
                    }
                } else {
                    completion(didAdjust, handledWindowIds)
                }
            }

            if shouldMinimizeWindowsInFront {
                let nonWorkspaceWindowsToMinimize = self.findNonWorkspaceWindowsInFront(
                    workspaceWindowIds: workspaceWindowIds,
                    currentWindows: currentWindows
                )

                if !nonWorkspaceWindowsToMinimize.isEmpty {
                    didAdjust = true
                    for windowInfo in nonWorkspaceWindowsToMinimize {
                        _ = self.minimize(windowInfo: windowInfo)
                        if windowInfo.id >= 0, windowInfo.id <= Int(UInt32.max) {
                            handledWindowIds.insert(CGWindowID(windowInfo.id))
                        }
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { finalize() }
                } else {
                    finalize()
                }
            } else {
                let workspaceWindowsToActivate = self.findWorkspaceWindowsBehindOthers(
                    workspaceWindowIds: workspaceWindowIds,
                    currentWindows: currentWindows
                )

                if !workspaceWindowsToActivate.isEmpty {
                    didAdjust = true
                    for windowInfo in workspaceWindowsToActivate {
                        _ = self.activate(windowInfo: windowInfo)
                        if windowInfo.id >= 0, windowInfo.id <= Int(UInt32.max) {
                            handledWindowIds.insert(CGWindowID(windowInfo.id))
                        }
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { finalize() }
                } else {
                    finalize()
                }
            }
        }
    }

    public func needsZOrderAdjustments(
        snapshot: SystemSnapshot,
        workspaceWindows: [WorkspaceWindow],
        workspaceScreens: [WorkspaceScreen]?
    ) -> Bool {
        let titledWindows = OpenByPathTitleAssigner.apply(to: workspaceWindows)
        let currentWindows = windowInfosForZOrderChecks(from: snapshot)
        let workspaceWindowIds = workspaceWindowIdsForZOrderChecks(
            workspaceWindows: titledWindows,
            snapshot: snapshot
        )

        let nonWorkspaceInFront = findNonWorkspaceWindowsInFront(
            workspaceWindowIds: workspaceWindowIds,
            currentWindows: currentWindows
        )

        if !nonWorkspaceInFront.isEmpty {
            return true
        }

        let workspaceBehind = findWorkspaceWindowsBehindOthers(
            workspaceWindowIds: workspaceWindowIds,
            currentWindows: currentWindows
        )

        return !workspaceBehind.isEmpty
    }

    private func windowInfosForZOrderChecks(from snapshot: SystemSnapshot) -> [WindowInfo] {
        let currentBundleId = Bundle.main.bundleIdentifier
        var currentWindows: [WindowInfo] = []

        for window in snapshot.windows {
            guard let bundleId = window.bundleId else { continue }
            if let currentBundleId, bundleId == currentBundleId { continue }

            if let app = NSWorkspace.shared.runningApplications.first(where: { $0.processIdentifier == window.pid }) {
                if app.activationPolicy != .regular { continue }
                if let appBundle = app.bundleIdentifier, appBundle == currentBundleId { continue }
            }

            // For post-restore z-order checks, prefer the fast CGWindowList snapshot and avoid
            // per-window AX resolution (can be very slow with many windows).
            // We intentionally only consider on-screen windows since off-space windows cannot
            // visually occlude the restored workspace.
            let isHidden = !window.isOnScreen
            if isHidden { continue }
            let isMinimized = window.isMinimized ?? false
            let title = window.title ?? "Untitled"
            let appName = window.appName ?? "Unknown"

            currentWindows.append(WindowInfo(
                id: Int(window.windowId),
                appName: appName,
                windowTitle: title,
                frame: window.frame,
                processID: window.pid,
                bundleIdentifier: bundleId,
                isMinimized: isMinimized,
                isHidden: isHidden,
                windowLevel: window.zOrderIndex ?? Int.max
            ))
        }

        return currentWindows.sorted { $0.windowLevel < $1.windowLevel }
    }

    private func minimize(windowInfo: WindowInfo) -> Bool {
        handleWindowInfo(windowInfo) { handle in
            handle.minimize()
        }
    }

    private func activate(windowInfo: WindowInfo) -> Bool {
        handleWindowInfo(windowInfo) { handle in
            handle.activate()
        }
    }

    private func handleWindowInfo(
        _ windowInfo: WindowInfo,
        action: (WindowHandle) -> WindowHandle?
    ) -> Bool {
        guard windowInfo.id >= 0, windowInfo.id <= Int(UInt32.max) else {
            DeskJigLog.debug(.restorationPostRestore, "WorkspaceZOrderService: Invalid window ID \(windowInfo.id) for '\(windowInfo.windowTitle)'")
            return false
        }

        guard let handle = Window.find(windowId: CGWindowID(windowInfo.id)) else {
            DeskJigLog.debug(.restorationPostRestore, "WorkspaceZOrderService: Unable to resolve window handle for ID \(windowInfo.id) '\(windowInfo.windowTitle)'")
            return false
        }

        return action(handle) != nil
    }

    private func forceRaiseWorkspaceWindows(
        workspaceWindows: [WorkspaceWindow],
        workspaceScreens: [WorkspaceScreen]?
    ) {
        let titledWindows = OpenByPathTitleAssigner.apply(to: workspaceWindows)

        let ghosttyWindows = cachedWindowsAcrossProcesses(forBundleID: OpenByPathBundleIdentifiers.ghostty, filter: .all)
        let cursorWindows = cachedWindowsAcrossProcesses(forBundleID: OpenByPathBundleIdentifiers.cursor, filter: .all)
        let codexWindows = cachedWindowsAcrossProcesses(forBundleID: OpenByPathBundleIdentifiers.codex, filter: .all)
        let terminalWindows = cachedWindowsAcrossProcesses(forBundleID: OpenByPathBundleIdentifiers.terminal, filter: .all)
        let itermWindows = cachedWindowsAcrossProcesses(forBundleID: OpenByPathBundleIdentifiers.iterm2, filter: .all)
        let kittyWindows = cachedWindowsAcrossProcesses(forBundleID: OpenByPathBundleIdentifiers.kitty, filter: .all)
        let alacrittyWindows = cachedWindowsAcrossProcesses(forBundleID: OpenByPathBundleIdentifiers.alacritty, filter: .all)
        let vscodeWindows = cachedWindowsAcrossProcesses(forBundleID: OpenByPathBundleIdentifiers.vscode, filter: .all)
        let xcodeWindows = cachedWindowsAcrossProcesses(forBundleID: OpenByPathBundleIdentifiers.xcode, filter: .all)

        let ghosttyIndexMap = buildGhosttyIndexMap(
            windows: titledWindows.filter { $0.bundleIdentifier == OpenByPathBundleIdentifiers.ghostty && normalizeOpenPath($0.openPath) != nil }
        )
        let terminalIndexMap = buildTerminalIndexMap(windows: titledWindows.filter { $0.bundleIdentifier == OpenByPathBundleIdentifiers.terminal && normalizeOpenPath($0.openPath) != nil })
        let itermIndexMap = buildTerminalIndexMap(windows: titledWindows.filter { $0.bundleIdentifier == OpenByPathBundleIdentifiers.iterm2 && normalizeOpenPath($0.openPath) != nil })
        let kittyIndexMap = buildTerminalIndexMap(windows: titledWindows.filter { $0.bundleIdentifier == OpenByPathBundleIdentifiers.kitty && normalizeOpenPath($0.openPath) != nil })
        let alacrittyIndexMap = buildTerminalIndexMap(windows: titledWindows.filter { $0.bundleIdentifier == OpenByPathBundleIdentifiers.alacritty && normalizeOpenPath($0.openPath) != nil })
        var claimedGhosttyHashes = Set<Int>()

        for window in titledWindows {
            switch window.bundleIdentifier {
            case OpenByPathBundleIdentifiers.ghostty:
                let normalizedOpenPath = normalizeOpenPath(window.openPath)
                let expectedTitle = normalizedOpenPath.map { ghosttyExpectedTitle(window: window, normalizedPath: $0, indexMap: ghosttyIndexMap) }
                
                if let expectedTitle {
                    let titleMatches = ghosttyWindows.filter { $0.title == expectedTitle }
                    if let selected = selectPreferredWindow(from: titleMatches, excluding: claimedGhosttyHashes) {
                        if let hash = selected.axElementHash { claimedGhosttyHashes.insert(hash) }
                        _ = selected.restore()?.activate()
                        _ = selected.raise()
                    }
                }
            case OpenByPathBundleIdentifiers.cursor:
                if let openPath = normalizeOpenPath(window.openPath) {
                    if let match = matchCursorWindowForRaise(directoryPath: openPath, windows: cursorWindows) {
                        _ = match.restore()?.activate()
                        _ = match.raise()
                    }
                }
            case OpenByPathBundleIdentifiers.codex:
                if let openPath = normalizeOpenPath(window.openPath) {
                    if let match = matchCursorWindowForRaise(
                        directoryPath: openPath,
                        windows: codexWindows,
                        bundleId: OpenByPathBundleIdentifiers.codex
                    ) {
                        _ = match.restore()?.activate()
                        _ = match.raise()
                    }
                }
            case OpenByPathBundleIdentifiers.terminal:
                if let openPath = normalizeOpenPath(window.openPath) {
                    let expectedTitle = terminalExpectedTitle(window: window, normalizedPath: openPath, indexMap: terminalIndexMap)
                    let matches = terminalWindows.filter { $0.title == expectedTitle }
                    if let selected = selectPreferredWindow(from: matches) {
                        _ = selected.restore()?.activate()
                        _ = selected.raise()
                    } else {
                        let docMatches = terminalWindows.filter { normalizeOpenPath($0.documentPath) == openPath }
                        if let selected = selectPreferredWindow(from: docMatches) {
                            _ = selected.restore()?.activate()
                            _ = selected.raise()
                        }
                    }
                }
            case OpenByPathBundleIdentifiers.iterm2:
                if let openPath = normalizeOpenPath(window.openPath) {
                    let expectedTitle = terminalExpectedTitle(window: window, normalizedPath: openPath, indexMap: itermIndexMap)
                    let matches = itermWindows.filter { $0.title == expectedTitle }
                    if let selected = selectPreferredWindow(from: matches) {
                        _ = selected.restore()?.activate()
                        _ = selected.raise()
                    } else {
                        let docMatches = itermWindows.filter { normalizeOpenPath($0.documentPath) == openPath }
                        if let selected = selectPreferredWindow(from: docMatches) {
                            _ = selected.restore()?.activate()
                            _ = selected.raise()
                        }
                    }
                }
            case OpenByPathBundleIdentifiers.kitty:
                if let openPath = normalizeOpenPath(window.openPath) {
                    let expectedTitle = terminalExpectedTitle(window: window, normalizedPath: openPath, indexMap: kittyIndexMap)
                    let matches = kittyWindows.filter { $0.title == expectedTitle }
                    if let selected = selectPreferredWindow(from: matches) {
                        _ = selected.restore()?.activate()
                        _ = selected.raise()
                    } else {
                        let docMatches = kittyWindows.filter { normalizeOpenPath($0.documentPath) == openPath }
                        if let selected = selectPreferredWindow(from: docMatches) {
                            _ = selected.restore()?.activate()
                            _ = selected.raise()
                        }
                    }
                }
            case OpenByPathBundleIdentifiers.alacritty:
                if let openPath = normalizeOpenPath(window.openPath) {
                    let expectedTitle = terminalExpectedTitle(window: window, normalizedPath: openPath, indexMap: alacrittyIndexMap)
                    let matches = alacrittyWindows.filter { $0.title == expectedTitle }
                    if let selected = selectPreferredWindow(from: matches) {
                        _ = selected.restore()?.activate()
                        _ = selected.raise()
                    } else {
                        let docMatches = alacrittyWindows.filter { normalizeOpenPath($0.documentPath) == openPath }
                        if let selected = selectPreferredWindow(from: docMatches) {
                            _ = selected.restore()?.activate()
                            _ = selected.raise()
                        }
                    }
                }
            case OpenByPathBundleIdentifiers.vscode:
                if let openPath = normalizeOpenPath(window.openPath) {
                    if let match = matchCursorWindowForRaise(directoryPath: openPath, windows: vscodeWindows) {
                        _ = match.restore()?.activate()
                        _ = match.raise()
                    }
                }
            case OpenByPathBundleIdentifiers.xcode:
                if let openPath = normalizeOpenPath(window.openPath) {
                    if let match = matchCursorWindowForRaise(
                        directoryPath: openPath,
                        windows: xcodeWindows,
                        bundleId: OpenByPathBundleIdentifiers.xcode
                    ) {
                        _ = match.restore()?.activate()
                        _ = match.raise()
                    }
                }
            default: break
            }
        }
    }

    private func frameMatches(_ frame: CGRect, _ target: CGRect, tolerance: CGFloat = 8.0) -> Bool {
        frame.approximatelyEquals(target, tolerance: tolerance)
    }

    private func frameDistance(_ lhs: CGRect, _ rhs: CGRect) -> CGFloat {
        lhs.manhattanDistance(to: rhs)
    }

    private func extractChromeProfileName(from title: String) -> String? {
        let delimiters = [" - Google Chrome - ", " - Google Chrome – ", " - Google Chrome — "]
        for delimiter in delimiters {
            if let range = title.range(of: delimiter, options: .backwards) {
                let profileName = title[range.upperBound...]
                return profileName.isEmpty ? nil : String(profileName)
            }
        }
        return nil
    }

    private func parseGhosttyIndex(from title: String, basename: String) -> Int? {
        let prefix = "\(BundleIdentity.terminalTitleTokenPrefix):\(basename):"
        guard title.hasPrefix(prefix) else { return nil }
        return Int(title.dropFirst(prefix.count))
    }

    private func buildGhosttyIndexMap(windows: [WorkspaceWindow], ignoreSavedTitles: Bool = false) -> [UUID: Int] {
        let grouped = Dictionary(grouping: windows) { normalizeOpenPath($0.openPath) ?? "" }
        var indexMap: [UUID: Int] = [:]
        for (path, group) in grouped where !path.isEmpty {
            let basename = URL(fileURLWithPath: path).lastPathComponent
            var usedIndices = Set<Int>()
            var pending: [WorkspaceWindow] = []
            if ignoreSavedTitles {
                pending = group
            } else {
                for window in group {
                    if let index = parseGhosttyIndex(from: window.windowTitle, basename: basename) {
                        indexMap[window.id] = index
                        usedIndices.insert(index)
                    } else { pending.append(window) }
                }
            }
            let sortedPending = pending
            var nextIndex = 0
            for window in sortedPending {
                while usedIndices.contains(nextIndex) { nextIndex += 1 }
                indexMap[window.id] = nextIndex
                usedIndices.insert(nextIndex)
                nextIndex += 1
            }
        }
        return indexMap
    }

    private func buildTerminalIndexMap(windows: [WorkspaceWindow]) -> [UUID: Int] {
        buildGhosttyIndexMap(windows: windows, ignoreSavedTitles: false)
    }

    private func ghosttyExpectedTitle(window: WorkspaceWindow, normalizedPath: String, indexMap: [UUID: Int]) -> String {
        let basename = URL(fileURLWithPath: normalizedPath).lastPathComponent
        return "\(BundleIdentity.terminalTitleTokenPrefix):\(basename):\(indexMap[window.id] ?? 0)"
    }

    private func terminalExpectedTitle(window: WorkspaceWindow, normalizedPath: String, indexMap: [UUID: Int]) -> String {
        let basename = URL(fileURLWithPath: normalizedPath).lastPathComponent
        return "\(BundleIdentity.terminalTitleTokenPrefix):\(basename):\(indexMap[window.id] ?? 0)"
    }

    private func matchCursorWindowForRaise(
        directoryPath: String,
        windows: [WindowHandle],
        bundleId: String = OpenByPathBundleIdentifiers.cursor
    ) -> WindowHandle? {
        let expectedPath = normalizeOpenPath(directoryPath) ?? directoryPath
        let token = URL(fileURLWithPath: expectedPath).lastPathComponent

        if bundleId == OpenByPathBundleIdentifiers.xcode {
            // Prefer path-compatible matches first for Xcode. Title-only fallback can collide between
            // root and worktree repos that share the same basename (e.g. both "deskjig").
            let docMatches = windows.filter {
                guard let observed = observedOpenPath(for: $0.documentPath, bundleId: bundleId) else { return false }
                return pathMatchesExpectedDirectory(observedPath: observed, expectedDirectory: expectedPath, bundleId: bundleId)
            }
            if docMatches.count == 1, let match = docMatches.first { return match }
            if docMatches.count > 1 { return nil }

            let titleMatches = windows.filter { titleContainsFolder($0.title ?? "", folderName: token) }
            let compatibleTitleMatches = titleMatches.filter { window in
                guard let observed = observedOpenPath(for: window.documentPath, bundleId: bundleId) else { return false }
                return pathMatchesExpectedDirectory(observedPath: observed, expectedDirectory: expectedPath, bundleId: bundleId)
            }
            if compatibleTitleMatches.count == 1, let match = compatibleTitleMatches.first { return match }
            if compatibleTitleMatches.count > 1 { return nil }

            // Avoid unresolved-path title fallback for Xcode; it is too ambiguous with
            // root/worktree windows that share the same project basename.
            return nil
        }

        let titleMatches = windows.filter { titleContainsFolder($0.title ?? "", folderName: token) }
        if let match = selectPreferredWindow(from: titleMatches) { return match }
        let docMatches = windows.filter { observedOpenPath(for: $0.documentPath, bundleId: bundleId) == expectedPath }
        return selectPreferredWindow(from: docMatches)
    }

    private func observedOpenPath(for documentPath: String?, bundleId: String) -> String? {
        guard let normalizedPath = normalizeOpenPath(documentPath) else { return nil }
        if bundleId == OpenByPathBundleIdentifiers.xcode {
            if normalizedPath.hasSuffix(".xcworkspace") || normalizedPath.hasSuffix(".xcodeproj") {
                return URL(fileURLWithPath: normalizedPath).deletingLastPathComponent().path
            }
        }
        return normalizedPath
    }

    private func pathMatchesExpectedDirectory(observedPath: String, expectedDirectory: String, bundleId: String) -> Bool {
        if bundleId == OpenByPathBundleIdentifiers.xcode {
            return observedPath == expectedDirectory || observedPath.hasPrefix("\(expectedDirectory)/")
        }
        return observedPath == expectedDirectory
    }

    private func targetFrameForRaise(window: WorkspaceWindow, workspaceScreens: [WorkspaceScreen]?) -> CGRect? {
        guard let relativeFrame = window.relativeFrame, let screenIndex = window.screenIndex, let workspaceScreens, screenIndex < workspaceScreens.count else { return nil }
        return WindowFrameConverter.restoreToAbsolute(relativeFrame: relativeFrame, savedScreen: workspaceScreens[screenIndex], currentScreens: displayManager.screens)
    }

    private func selectClosestWindow(from windows: [WindowHandle], targetFrame: CGRect?) -> WindowHandle? {
        guard let targetFrame else { return windows.first }
        return windows.min { lhs, rhs in
            let lhsDist = lhs.frame.map { pow($0.origin.x - targetFrame.origin.x, 2) + pow($0.origin.y - targetFrame.origin.y, 2) } ?? .infinity
            let rhsDist = rhs.frame.map { pow($0.origin.x - targetFrame.origin.x, 2) + pow($0.origin.y - targetFrame.origin.y, 2) } ?? .infinity
            return lhsDist < rhsDist
        }
    }

    private func selectPreferredWindow(from windows: [WindowHandle]) -> WindowHandle? {
        return windows.sorted { lhs, rhs in
            let lhsTitle = lhs.title ?? ""
            let rhsTitle = rhs.title ?? ""
            let lhsManagedTitle = lhsTitle.lowercased().hasPrefix("\(BundleIdentity.terminalTitleTokenPrefix):")
            let rhsManagedTitle = rhsTitle.lowercased().hasPrefix("\(BundleIdentity.terminalTitleTokenPrefix):")
            if lhsManagedTitle != rhsManagedTitle {
                return lhsManagedTitle
            }
            if lhsTitle != rhsTitle {
                return lhsTitle.localizedCaseInsensitiveCompare(rhsTitle) == .orderedAscending
            }
            let lhsPid = lhs.processID ?? 0
            let rhsPid = rhs.processID ?? 0
            if lhsPid != rhsPid {
                return lhsPid < rhsPid
            }
            let lhsHash = lhs.axElementHash ?? 0
            let rhsHash = rhs.axElementHash ?? 0
            return lhsHash < rhsHash
        }.first
    }

    private func selectPreferredWindow(
        from windows: [WindowHandle],
        excluding claimedHashes: Set<Int>
    ) -> WindowHandle? {
        let filtered = windows.filter { handle in
            guard let hash = handle.axElementHash else { return true }
            return !claimedHashes.contains(hash)
        }
        return selectPreferredWindow(from: filtered)
    }

    private func workspaceWindowIdsForZOrderChecks(
        workspaceWindows: [WorkspaceWindow],
        snapshot: SystemSnapshot
    ) -> Set<Int> {
        let snapshotWindowsByBundle = Dictionary(grouping: snapshot.windows) { $0.bundleId ?? "" }
        let xcodeHashesByWindowId = xcodeHandleHashesByWindowId()
        var claimedWindowIds = Set<CGWindowID>()
        var workspaceWindowIds = Set<Int>()
        let xcodeWorkspaceWindows = workspaceWindows.filter {
            $0.bundleIdentifier == OpenByPathBundleIdentifiers.xcode
        }

        if !xcodeWorkspaceWindows.isEmpty,
           let xcodeCandidates = snapshotWindowsByBundle[OpenByPathBundleIdentifiers.xcode],
           !xcodeCandidates.isEmpty {
            let expectedPathSlots = xcodeWorkspaceWindows.compactMap { normalizeOpenPath($0.openPath) }
            let selection = selectXcodeCoverageWindowIds(
                expectedPathSlots: expectedPathSlots,
                snapshotWindows: xcodeCandidates,
                protectedWindowIds: [],
                xcodeHashesByWindowId: xcodeHashesByWindowId
            )
            for windowId in selection.coverageWindowIds {
                workspaceWindowIds.insert(Int(windowId))
                claimedWindowIds.insert(windowId)
            }
        }

        for workspaceWindow in workspaceWindows {
            let bundleId = workspaceWindow.bundleIdentifier
            guard !bundleId.isEmpty else { continue }
            guard let candidates = snapshotWindowsByBundle[bundleId], !candidates.isEmpty else { continue }

            if bundleId == OpenByPathBundleIdentifiers.xcode {
                continue
            }

            if let expectedPath = normalizeOpenPath(workspaceWindow.openPath) {
                let pathMatches = candidates.filter { snapshotWindow in
                    let observedPath: String?
                    if bundleId == OpenByPathBundleIdentifiers.ghostty ||
                        bundleId == OpenByPathBundleIdentifiers.terminal ||
                        bundleId == OpenByPathBundleIdentifiers.iterm2 ||
                        bundleId == OpenByPathBundleIdentifiers.kitty ||
                        bundleId == OpenByPathBundleIdentifiers.alacritty {
                        observedPath = normalizeOpenPath(snapshotWindow.freshWorkingDirectory)
                            ?? normalizeOpenPath(snapshotWindow.documentPath)
                    } else if BundleRegistry.isIDE(bundleId) {
                        observedPath = observedOpenPath(
                            for: snapshotWindow.ideDocumentPath ?? snapshotWindow.documentPath,
                            bundleId: bundleId
                        )
                    } else {
                        observedPath = normalizeOpenPath(snapshotWindow.documentPath)
                    }
                    guard let observedPath else { return false }
                    return pathMatchesExpectedDirectory(
                        observedPath: observedPath,
                        expectedDirectory: expectedPath,
                        bundleId: bundleId
                    )
                }
                if let selected = selectPreferredSnapshotWindow(from: pathMatches, excluding: claimedWindowIds) {
                    workspaceWindowIds.insert(Int(selected.windowId))
                    claimedWindowIds.insert(selected.windowId)
                    continue
                }
            }

            let titleMatches = candidates.filter { $0.title == workspaceWindow.windowTitle }
            if let selected = selectPreferredSnapshotWindow(from: titleMatches, excluding: claimedWindowIds) {
                workspaceWindowIds.insert(Int(selected.windowId))
                claimedWindowIds.insert(selected.windowId)
            }
        }

        return workspaceWindowIds
    }

    private func selectPreferredSnapshotWindow(
        from windows: [SnapshotWindow],
        excluding claimedWindowIds: Set<CGWindowID> = [],
        preferredWindowIds: Set<CGWindowID> = [],
        xcodeHashesByWindowId: [CGWindowID: Int] = [:]
    ) -> SnapshotWindow? {
        let filtered = windows.filter { !claimedWindowIds.contains($0.windowId) }
        guard !filtered.isEmpty else { return nil }

        return filtered.sorted { lhs, rhs in
            let lhsPreferred = preferredWindowIds.contains(lhs.windowId)
            let rhsPreferred = preferredWindowIds.contains(rhs.windowId)
            if lhsPreferred != rhsPreferred {
                return lhsPreferred
            }

            let lhsZ = lhs.zOrderIndex ?? Int.max
            let rhsZ = rhs.zOrderIndex ?? Int.max
            if lhsZ != rhsZ {
                return lhsZ < rhsZ
            }

            if lhs.windowId != rhs.windowId {
                return lhs.windowId < rhs.windowId
            }

            let lhsHash = xcodeHashesByWindowId[lhs.windowId] ?? 0
            let rhsHash = xcodeHashesByWindowId[rhs.windowId] ?? 0
            return lhsHash < rhsHash
        }.first
    }

    private func selectXcodeCoverageWindowIds(
        expectedPathSlots: [String],
        snapshotWindows: [SnapshotWindow],
        protectedWindowIds: Set<CGWindowID>,
        xcodeHashesByWindowId: [CGWindowID: Int]
    ) -> (coverageWindowIds: Set<CGWindowID>, topology: XcodeWindowCoverageTopology) {
        let normalizedExpectedPathSlots = expectedPathSlots.compactMap { normalizeOpenPath($0) }
        let expectedPathSet = Set(normalizedExpectedPathSlots)
        guard !expectedPathSet.isEmpty else {
            return ([], XcodeWindowCoverageTopology(expectedPathSlots: [], observedPathSlots: []))
        }

        let observedEntries: [(window: SnapshotWindow, expectedPath: String)] = snapshotWindows.compactMap { snapshotWindow in
            guard let observedPath = observedOpenPath(
                for: snapshotWindow.ideDocumentPath ?? snapshotWindow.documentPath,
                bundleId: OpenByPathBundleIdentifiers.xcode
            ) else {
                return nil
            }
            guard let expectedPath = bestMatchingExpectedPath(
                observedPath: observedPath,
                expectedPaths: expectedPathSet,
                bundleId: OpenByPathBundleIdentifiers.xcode
            ) else {
                return nil
            }
            return (snapshotWindow, expectedPath)
        }

        let topology = XcodeWindowCoverageTopology(
            expectedPathSlots: normalizedExpectedPathSlots,
            observedPathSlots: observedEntries.map(\.expectedPath)
        )
        guard !observedEntries.isEmpty else {
            return ([], topology)
        }

        let groupedByExpectedPath = Dictionary(grouping: observedEntries, by: { $0.expectedPath })
        let expectedPathCounts = topology.expectedCountsByPath
        var selectedWindowIds = Set<CGWindowID>()

        for (expectedPath, requiredCount) in expectedPathCounts where requiredCount > 0 {
            guard let groupedEntries = groupedByExpectedPath[expectedPath], !groupedEntries.isEmpty else { continue }
            let sortedWindows = groupedEntries.map(\.window).sorted { lhs, rhs in
                let lhsProtected = protectedWindowIds.contains(lhs.windowId)
                let rhsProtected = protectedWindowIds.contains(rhs.windowId)
                if lhsProtected != rhsProtected {
                    return lhsProtected
                }

                let lhsZ = lhs.zOrderIndex ?? Int.max
                let rhsZ = rhs.zOrderIndex ?? Int.max
                if lhsZ != rhsZ {
                    return lhsZ < rhsZ
                }

                if lhs.windowId != rhs.windowId {
                    return lhs.windowId < rhs.windowId
                }

                let lhsHash = xcodeHashesByWindowId[lhs.windowId] ?? 0
                let rhsHash = xcodeHashesByWindowId[rhs.windowId] ?? 0
                return lhsHash < rhsHash
            }

            for window in sortedWindows.prefix(requiredCount) {
                selectedWindowIds.insert(window.windowId)
            }
        }

        return (selectedWindowIds, topology)
    }

    private func bestMatchingExpectedPath(
        observedPath: String,
        expectedPaths: Set<String>,
        bundleId: String
    ) -> String? {
        let matches = expectedPaths.filter { expectedPath in
            pathMatchesExpectedDirectory(
                observedPath: observedPath,
                expectedDirectory: expectedPath,
                bundleId: bundleId
            )
        }
        guard !matches.isEmpty else { return nil }
        return matches.sorted { lhs, rhs in
            if lhs.count != rhs.count {
                return lhs.count > rhs.count
            }
            return lhs < rhs
        }.first
    }

    private func xcodeHandleHashesByWindowId() -> [CGWindowID: Int] {
        let handles = cachedWindowsAcrossProcesses(forBundleID: OpenByPathBundleIdentifiers.xcode, filter: .all)
        var hashes: [CGWindowID: Int] = [:]
        for handle in handles {
            guard let axWindowNumber = handle.windowId,
                  let windowId = Self.cgWindowId(fromAXWindowNumber: axWindowNumber),
                  let hash = handle.axElementHash else {
                continue
            }
            hashes[windowId] = hash
        }
        return hashes
    }

    private func findNonWorkspaceWindowsInFront(
        workspaceWindowIds: Set<Int>,
        currentWindows: [WindowInfo]
    ) -> [WindowInfo] {
        guard !workspaceWindowIds.isEmpty else { return [] }
        let currentWorkspaceWindows = currentWindows.filter { workspaceWindowIds.contains($0.id) }
        guard !currentWorkspaceWindows.isEmpty else { return [] }

        return currentWindows.filter { window in
            guard !workspaceWindowIds.contains(window.id) else { return false }
            return currentWorkspaceWindows.contains { $0.windowLevel > window.windowLevel }
        }
    }

    private func findWorkspaceWindowsBehindOthers(
        workspaceWindowIds: Set<Int>,
        currentWindows: [WindowInfo]
    ) -> [WindowInfo] {
        guard !workspaceWindowIds.isEmpty else { return [] }
        let workspaceCurrentWindows = currentWindows.filter { workspaceWindowIds.contains($0.id) }
        guard !workspaceCurrentWindows.isEmpty else { return [] }

        return workspaceCurrentWindows.filter { window in
            currentWindows.contains { candidate in
                candidate.windowLevel < window.windowLevel && !workspaceWindowIds.contains(candidate.id)
            }
        }
    }

    public func logPostRestoreDiagnostics(workspace: Workspace?, restoredWindows: [WorkspaceWindow]) {
        let workspaceName = workspace?.name ?? "nil"
        DeskJigLog.info(.restorationPostRestore, "workspace=\(workspaceName) expectedWindows=\(restoredWindows.count)")
        for window in restoredWindows {
            DeskJigLog.debug(.restorationPostRestore, "expected windowId=\(window.id) app=\(window.appName) bundle=\(window.bundleIdentifier) title='\(window.windowTitle)' openPath='\(window.openPath ?? "nil")' screen=\(window.screenIndex.map(String.init) ?? "nil") relativeFrame=\(window.relativeFrame?.description ?? "nil")")
        }

        let ghosttyWindows = cachedWindowsAcrossProcesses(forBundleID: OpenByPathBundleIdentifiers.ghostty, filter: .all)
        let cursorWindows = cachedWindowsAcrossProcesses(forBundleID: OpenByPathBundleIdentifiers.cursor, filter: .all)
        let codexWindows = cachedWindowsAcrossProcesses(forBundleID: OpenByPathBundleIdentifiers.codex, filter: .all)
        DeskJigLog.info(.restorationPostRestore, "workspace=\(workspaceName) ghosttyCount=\(ghosttyWindows.count) cursorCount=\(cursorWindows.count) codexCount=\(codexWindows.count)")

        for window in ghosttyWindows { DeskJigLog.debug(.restorationPostRestore, "ghostty \(describeWindow(window))") }
        for window in cursorWindows { DeskJigLog.debug(.restorationPostRestore, "cursor \(describeWindow(window))") }
        for window in codexWindows { DeskJigLog.debug(.restorationPostRestore, "codex \(describeWindow(window))") }

        if let topmost = Window.topmost(filter: .all) { DeskJigLog.debug(.restorationPostRestore, "topmost \(describeWindow(topmost))") }
    }

    private func describeWindow(_ window: WindowHandle) -> String {
        let frameStr = window.frame.map { String(format: "(%.0f, %.0f) %.0fx%.0f", $0.origin.x, $0.origin.y, $0.size.width, $0.size.height) } ?? "nil"
        return "title='\(window.title ?? "nil")' doc='\(window.documentPath ?? "nil")' frame=\(frameStr) pid=\(window.processID.map(String.init) ?? "nil") hidden=\(window.isHidden ? "1" : "0") minimized=\(window.isMinimized ? "1" : "0") ax=\(window.axElementHash.map(String.init) ?? "nil") bundle=\(window.bundleIdentifier ?? "nil")"
    }

    /// Finds the best matching snapshot window for a workspace window using frame proximity and title matching.
    /// Used for generic apps that don't have openPath.
    private func findBestSnapshotMatch(
        workspaceWindow: WorkspaceWindow,
        candidates: [SnapshotWindow],
        workspaceScreens: [WorkspaceScreen]?
    ) -> SnapshotWindow? {
        guard !candidates.isEmpty else { return nil }

        let targetFrame = targetFrameForRaise(window: workspaceWindow, workspaceScreens: workspaceScreens)
        let expectedTitle = workspaceWindow.windowTitle

        // First: Try exact title match
        let titleMatches = candidates.filter { $0.title == expectedTitle }
        if titleMatches.count == 1 {
            return titleMatches[0]
        }
        if titleMatches.count > 1 {
            // Multiple title matches - prefer the one closest to target frame
            if let targetFrame {
                return titleMatches.min { lhs, rhs in
                    frameDistance(lhs.frame, targetFrame) < frameDistance(rhs.frame, targetFrame)
                }
            }
            // No target frame - prefer frontmost by z-order
            return titleMatches.sorted { ($0.zOrderIndex ?? Int.max) < ($1.zOrderIndex ?? Int.max) }.first
        }

        // Second: Try frame matching with tolerance
        if let targetFrame {
            let frameCandidates = candidates.filter { self.frameMatches($0.frame, targetFrame, tolerance: 50.0) }
            if frameCandidates.count == 1 {
                return frameCandidates[0]
            }
            if frameCandidates.count > 1 {
                // Multiple frame matches - prefer closest
                return frameCandidates.min { lhs, rhs in
                    frameDistance(lhs.frame, targetFrame) < frameDistance(rhs.frame, targetFrame)
                }
            }
        }

        // Third: Try partial title match (case insensitive contains)
        if !expectedTitle.isEmpty {
            let partialMatches = candidates.filter {
                guard let title = $0.title else { return false }
                return title.localizedCaseInsensitiveContains(expectedTitle) ||
                       expectedTitle.localizedCaseInsensitiveContains(title)
            }
            if let targetFrame, !partialMatches.isEmpty {
                return partialMatches.min { lhs, rhs in
                    frameDistance(lhs.frame, targetFrame) < frameDistance(rhs.frame, targetFrame)
                }
            }
            if let first = partialMatches.first {
                return first
            }
        }

        // Fallback: If we have a target frame, return the closest window
        if let targetFrame {
            return candidates.min { lhs, rhs in
                frameDistance(lhs.frame, targetFrame) < frameDistance(rhs.frame, targetFrame)
            }
        }

        return nil
    }

    private static func cgWindowId(fromAXWindowNumber value: Int?) -> CGWindowID? {
        guard let value, value >= 0, value <= Int(UInt32.max) else { return nil }
        return CGWindowID(value)
    }
}

