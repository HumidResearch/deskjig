//  TmuxSessionManager.swift
//  DeskJigShared

import Foundation
import CoreGraphics

// MARK: - Tmux Session Manager

/// Coordinates tmux sessions at the workspace level.
///
/// Maps workspace windows to tmux sessions using a deterministic naming scheme,
/// and provides the fast-switch operation that swaps which session a terminal
/// window displays.
///
/// ## Session Naming
///
/// Session names retain the legacy `bento_` namespace so existing live sessions
/// remain attachable after the product rename.
///
/// Non-quick-switch sessions are named `bento_{workspaceIdPrefix}_{terminalKeyPrefix}`:
/// - `workspaceIdPrefix`: first 8 characters of the workspace UUID
/// - `terminalKeyPrefix`: first 8 normalized characters of `WorkspaceWindow.terminalKey`
///
/// Quick-switch sessions are directory-slot scoped:
/// - `bento_qs_{directoryToken}_s{slotIndex}`
/// - `directoryToken`: deterministic token derived from normalized directory path
public actor TmuxSessionManager {

    public enum SessionNamingMode: String, Sendable, Equatable {
        case workspace = "workspace"
        case directorySlot = "directory-slot"
    }

    // MARK: - Properties

    private static let quickSwitchLaunchSource = "quick-switch"
    private static let quickSwitchTerminalKeyPrefix = "qs_"
    private static let quickSwitchSessionPrefixRoot = "bento_qs_"

    private let commandService: TmuxCommandService

    // MARK: - Initialization

    public init(commandService: TmuxCommandService = TmuxCommandService()) {
        self.commandService = commandService
    }

    // MARK: - Availability

    /// Whether tmux is available on this system.
    public var isAvailable: Bool {
        get async {
            await commandService.isAvailable
        }
    }

    // MARK: - Session Naming

    /// Generates a deterministic tmux session name for a workspace terminal key.
    ///
    /// Format: `bento_{workspaceIdPrefix}_{terminalKeyPrefix}`
    public static func sessionName(forWorkspaceId workspaceId: String, terminalKey: String) -> String {
        let workspacePrefix = String(workspaceId.prefix(8)).lowercased()
        let terminalPrefix = normalizedSessionToken(terminalKey)
        return "bento_\(workspacePrefix)_\(terminalPrefix)"
    }

    /// Generates a deterministic terminal key for Quick Switch directory-slot mapping.
    ///
    /// Format: `qs_{directoryToken}_s{slotIndex}`
    public static func quickSwitchTerminalKey(forDirectoryPath directoryPath: String, slotIndex: Int) -> String {
        let token = quickSwitchDirectoryToken(forDirectoryPath: directoryPath)
        let safeSlotIndex = max(0, slotIndex)
        return "\(quickSwitchTerminalKeyPrefix)\(token)_s\(safeSlotIndex)"
    }

    /// Generates a deterministic tmux session name for Quick Switch directory-slot mapping.
    ///
    /// Format: `bento_qs_{directoryToken}_s{slotIndex}`
    public static func quickSwitchSessionName(forDirectoryPath directoryPath: String, slotIndex: Int) -> String {
        let token = quickSwitchDirectoryToken(forDirectoryPath: directoryPath)
        return quickSwitchSessionName(forDirectoryToken: token, slotIndex: slotIndex)
    }

    static func sessionNamingMode(for launchSource: String) -> SessionNamingMode {
        launchSource == quickSwitchLaunchSource ? .directorySlot : .workspace
    }

    /// Legacy fallback when a workspace window has no terminal key.
    public static func legacyTerminalKey(windowIndex: Int) -> String {
        "legacy\(windowIndex)"
    }

    public static func workspaceSessionPrefix(for workspaceId: String) -> String {
        "bento_\(String(workspaceId.prefix(8)).lowercased())_"
    }

    public static func quickSwitchDirectoryToken(forDirectoryPath directoryPath: String) -> String {
        let normalizedPath = normalizedDirectoryPath(directoryPath)
        let basename = URL(fileURLWithPath: normalizedPath).lastPathComponent
        let basenameSanitized = basename.lowercased().filter { $0.isLetter || $0.isNumber }
        let basenamePrefix = String((basenameSanitized.isEmpty ? "dir" : basenameSanitized).prefix(6))
        let hashSuffix = stableToken(from: normalizedPath, length: 6)
        return "\(basenamePrefix)\(hashSuffix)"
    }

    private static func normalizedSessionToken(_ raw: String) -> String {
        let sanitized = raw.lowercased().filter { $0.isLetter || $0.isNumber }
        let token = sanitized.isEmpty ? "terminal0" : sanitized
        return String(token.prefix(8))
    }

    private static func normalizedTerminalKey(_ key: String?) -> String? {
        guard let key else { return nil }
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return trimmed
    }

    private static func normalizedDirectoryPath(_ path: String) -> String {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "~" }
        let expanded = (trimmed as NSString).expandingTildeInPath
        return URL(fileURLWithPath: expanded).standardizedFileURL.path
    }

    private static func quickSwitchSessionName(forDirectoryToken directoryToken: String, slotIndex: Int) -> String {
        let safeSlotIndex = max(0, slotIndex)
        return "\(quickSwitchSessionPrefixRoot)\(directoryToken)_s\(safeSlotIndex)"
    }

    private static func quickSwitchSessionPrefix(forDirectoryToken directoryToken: String) -> String {
        "\(quickSwitchSessionPrefixRoot)\(directoryToken)_"
    }

    private static func quickSwitchSlotIndex(fromSessionName sessionName: String) -> Int? {
        guard sessionName.hasPrefix(quickSwitchSessionPrefixRoot),
              let slotRange = sessionName.range(of: "_s", options: .backwards) else {
            return nil
        }
        return Int(sessionName[slotRange.upperBound...])
    }

    private static func quickSwitchDirectoryToken(fromQuickSwitchTerminalKey terminalKey: String) -> String? {
        guard terminalKey.hasPrefix(quickSwitchTerminalKeyPrefix) else { return nil }
        let tokenStartIndex = terminalKey.index(terminalKey.startIndex, offsetBy: quickSwitchTerminalKeyPrefix.count)
        guard let slotRange = terminalKey.range(of: "_s", options: .backwards),
              slotRange.lowerBound > tokenStartIndex else {
            return nil
        }
        let token = String(terminalKey[tokenStartIndex..<slotRange.lowerBound])
        return token.isEmpty ? nil : token
    }

    private static func quickSwitchSlotIndex(fromQuickSwitchTerminalKey terminalKey: String) -> Int? {
        guard terminalKey.hasPrefix(quickSwitchTerminalKeyPrefix),
              let slotRange = terminalKey.range(of: "_s", options: .backwards) else {
            return nil
        }
        let slotText = String(terminalKey[slotRange.upperBound...])
        return Int(slotText)
    }

    private static func stableToken(from input: String, length: Int) -> String {
        let clampedLength = max(1, length)
        var hash: UInt64 = 1469598103934665603
        for byte in input.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1099511628211
        }

        let alphabet = Array("0123456789abcdefghijklmnopqrstuvwxyz")
        var value = hash
        var encoded: [Character] = []
        repeat {
            encoded.append(alphabet[Int(value % 36)])
            value /= 36
        } while value > 0

        let token = String(encoded.reversed())
        if token.count >= clampedLength {
            return String(token.prefix(clampedLength))
        }
        return String(repeating: "0", count: clampedLength - token.count) + token
    }

    // MARK: - Client / Session Queries

    public func listClients() async -> [TmuxClientInfo] {
        do {
            return try await commandService.listClients()
        } catch {
            // Callers treat [] as "no clients attached"; make a tmux command
            // failure distinguishable from that in the logs.
            DeskJigLog.debug(.tmux, "list-clients failed — returning empty client list", fields: [
                "error": error.localizedDescription
            ])
            return []
        }
    }

    // MARK: - Session Lifecycle

    /// Ensures tmux sessions exist for all terminal windows in a workspace.
    ///
    /// Creates sessions that don't already exist (idempotent). Returns updated
    /// workspace windows with `tmuxState` populated.
    public func ensureSessionsForWorkspace(
        _ workspace: Workspace,
        launchSource: String = "unknown",
        runId: String
    ) async -> [WorkspaceWindow] {
        let startTime = Date()
        var updatedWindows: [WorkspaceWindow] = []
        var terminalIndex = 0
        let namingMode = Self.sessionNamingMode(for: launchSource)

        let primaryTerminalPath = workspace.windows
            .first(where: { BundleRegistry.isTerminal($0.bundleIdentifier) })?
            .openPath
            .map(Self.normalizedDirectoryPath)
        let primaryDirectoryToken = primaryTerminalPath.map(Self.quickSwitchDirectoryToken(forDirectoryPath:))

        DeskJigLog.trace(
            .tmux,
            "RC10_DIAG tmux-session-naming mode=\(namingMode.rawValue) launchSource=\(launchSource) primaryDirectoryToken=\(primaryDirectoryToken ?? "n/a")",
            runId: runId
        )

        // Enable tmux mouse support so wheel scrolling uses tmux pane history
        // (copy-mode) instead of cycling shell command history at the prompt.
        // The DeskJig socket is a dedicated tmux server, so the global option is safe.
        do {
            try await commandService.setGlobalOption("mouse", value: "on")
        } catch {
            DeskJigLog.debug(.tmux, "Failed to set tmux global option", fields: [
                "option": "mouse",
                "value": "on",
                "error": error.localizedDescription
            ], runId: runId)
        }

        for window in workspace.windows {
            guard BundleRegistry.isTerminal(window.bundleIdentifier) else {
                // Non-terminal windows pass through unchanged
                updatedWindows.append(window)
                continue
            }

            let resolvedTerminalKey: String
            let needsLegacyFallback: Bool
            if let key = Self.normalizedTerminalKey(window.terminalKey) {
                resolvedTerminalKey = key
                needsLegacyFallback = false
            } else {
                resolvedTerminalKey = Self.legacyTerminalKey(windowIndex: terminalIndex)
                needsLegacyFallback = true
            }

            let workingDir = window.openPath ?? "~"
            let normalizedWorkingDir = Self.normalizedDirectoryPath(workingDir)
            let name: String
            let quickSwitchDirectoryToken: String?
            let quickSwitchSlotIndex: Int?
            switch namingMode {
            case .workspace:
                name = Self.sessionName(
                    forWorkspaceId: workspace.id.uuidString,
                    terminalKey: resolvedTerminalKey
                )
                quickSwitchDirectoryToken = nil
                quickSwitchSlotIndex = nil
            case .directorySlot:
                let directoryToken = window.openPath.map(Self.quickSwitchDirectoryToken(forDirectoryPath:))
                    ?? Self.quickSwitchDirectoryToken(fromQuickSwitchTerminalKey: resolvedTerminalKey)
                    ?? Self.quickSwitchDirectoryToken(forDirectoryPath: "~")
                let slotIndex = Self.quickSwitchSlotIndex(fromQuickSwitchTerminalKey: resolvedTerminalKey)
                    ?? terminalIndex
                name = Self.quickSwitchSessionName(
                    forDirectoryToken: directoryToken,
                    slotIndex: slotIndex
                )
                quickSwitchDirectoryToken = directoryToken
                quickSwitchSlotIndex = slotIndex
            }
            let keyedWindow = needsLegacyFallback
                ? window.withTerminalKey(resolvedTerminalKey)
                : window

            if needsLegacyFallback {
                DeskJigLog.debug(.tmux, "Legacy terminal key fallback used", fields: [
                    "workspaceId": workspace.id.uuidString,
                    "windowId": window.id.uuidString,
                    "legacyTerminalKey": resolvedTerminalKey,
                    "windowIndex": "\(terminalIndex)",
                    "namingMode": namingMode.rawValue
                ], runId: runId)
            }

            if namingMode == .directorySlot,
               let quickSwitchDirectoryToken,
               let quickSwitchSlotIndex {
                DeskJigLog.trace(
                    .tmux,
                    "RC10_DIAG tmux-directory-slot-assignment windowId=\(window.id.uuidString) bundle=\(window.bundleIdentifier) directoryToken=\(quickSwitchDirectoryToken) slot=\(quickSwitchSlotIndex) session=\(name)",
                    runId: runId
                )
            }

            do {
                try await commandService.ensureSession(name: name, workingDirectory: workingDir)
                let state = TmuxSessionState(
                    sessionName: name,
                    initialWorkingDirectory: normalizedWorkingDir
                )
                updatedWindows.append(keyedWindow.withTmuxState(state))

                DeskJigLog.trace(.tmux, "Session ensured", fields: [
                    "sessionName": name,
                    "workingDir": normalizedWorkingDir,
                    "terminalKey": resolvedTerminalKey,
                    "windowIndex": "\(terminalIndex)",
                    "namingMode": namingMode.rawValue,
                    "directoryToken": quickSwitchDirectoryToken ?? "",
                    "slotIndex": quickSwitchSlotIndex.map(String.init) ?? ""
                ], runId: runId)
            } catch {
                DeskJigLog.debug(.tmux, "Failed to ensure session", fields: [
                    "sessionName": name,
                    "namingMode": namingMode.rawValue,
                    "error": error.localizedDescription
                ], runId: runId)
                // Explicitly clear tmux state so restoration falls back to
                // legacy-title/open-by-path behavior when session prep fails.
                updatedWindows.append(keyedWindow.withTmuxState(nil))
            }

            terminalIndex += 1
        }

        // Detect stale sessions in the active namespace for diagnostics only.
        // Existing sessions are intentionally left untouched to preserve pane
        // history and cwd state across quick-switch restores.
        let ensuredNames = Set(updatedWindows.compactMap { $0.tmuxState?.sessionName })
        let terminalOpenPaths = workspace.windows
            .filter { BundleRegistry.isTerminal($0.bundleIdentifier) }
            .compactMap(\.openPath)

        if let primaryPath = terminalOpenPaths.first {
            do {
                let allSessions = try await commandService.listSessions()
                let normalizedPrimaryPath = Self.normalizedDirectoryPath(primaryPath)
                let sessionPrefix: String = {
                    switch namingMode {
                    case .workspace:
                        return Self.workspaceSessionPrefix(for: workspace.id.uuidString)
                    case .directorySlot:
                        let directoryToken = Self.quickSwitchDirectoryToken(forDirectoryPath: normalizedPrimaryPath)
                        return Self.quickSwitchSessionPrefix(forDirectoryToken: directoryToken)
                    }
                }()
                let staleSessions = allSessions.filter {
                    $0.sessionName.hasPrefix(sessionPrefix) &&
                    !ensuredNames.contains($0.sessionName)
                }
                if !staleSessions.isEmpty {
                    DeskJigLog.debug(.tmux, "Stale sessions detected (preserving existing session state)", fields: [
                        "staleCount": "\(staleSessions.count)",
                        "ensuredCount": "\(ensuredNames.count)",
                        "primaryPath": normalizedPrimaryPath,
                        "namingMode": namingMode.rawValue,
                        "sessionPrefix": sessionPrefix,
                        "staleSessions": staleSessions.map(\.sessionName).joined(separator: ",")
                    ], runId: runId)
                }
            } catch {
                DeskJigLog.debug(.tmux, "list-sessions failed — skipping stale-session diagnostics", fields: [
                    "error": error.localizedDescription
                ], runId: runId)
            }
        }

        let durationMs = Int(Date().timeIntervalSince(startTime) * 1000)
        DeskJigLog.debug(.tmux, "ensureSessionsForWorkspace complete", fields: [
            "terminalCount": "\(terminalIndex)",
            "namingMode": namingMode.rawValue,
            "durationMs": "\(durationMs)"
        ], runId: runId)

        return updatedWindows
    }

    /// Maps tmux client PIDs to CGWindowList window IDs.
    ///
    /// For each tmux client, walks the process tree to find the terminal
    /// window that owns it, then matches to a CGWindowID.
    public func mapClientsToWindows(
        snapshot: SystemSnapshot
    ) async -> [pid_t: CGWindowID] {
        let clients = await listClients()

        // Build a PID -> CGWindowID mapping from the snapshot
        var pidToWindowId: [pid_t: CGWindowID] = [:]
        for window in snapshot.windows {
            guard let bundleId = window.bundleId,
                  BundleRegistry.isTerminal(bundleId) else { continue }
            pidToWindowId[window.pid] = window.windowId
        }

        // For each tmux client, find the terminal window it belongs to.
        var clientPidToWindowId: [pid_t: CGWindowID] = [:]
        for client in clients {
            // Direct PID match
            if let windowId = pidToWindowId[client.clientPID] {
                clientPidToWindowId[client.clientPID] = windowId
                continue
            }

            // Walk up the process tree to find the terminal PID
            var currentPid = Self.parentPID(of: client.clientPID)
            var depth = 0
            while currentPid > 1 && depth < 10 {
                if let windowId = pidToWindowId[currentPid] {
                    clientPidToWindowId[client.clientPID] = windowId
                    break
                }
                currentPid = Self.parentPID(of: currentPid)
                depth += 1
            }
        }

        return clientPidToWindowId
    }

    /// After a quick-switch terminal phase completes, rebind any still-attached
    /// quick-switch clients from an old directory token onto the target slot sessions.
    public func reconcileAttachedQuickSwitchClients(
        targetWindows: [WorkspaceWindow],
        clientBundleByPID: [pid_t: String] = [:],
        runId: String
    ) async {
        var tmuxIndexByBundle: [String: Int] = [:]
        var targetSessionEntries: [(Int, (sessionName: String, title: String?, bundleId: String))] = []
        for window in targetWindows {
            guard let sessionName = window.tmuxState?.sessionName,
                  let slotIndex = Self.quickSwitchSlotIndex(fromSessionName: sessionName) else {
                continue
            }

            let tmuxIndex = tmuxIndexByBundle[window.bundleIdentifier, default: 0]
            tmuxIndexByBundle[window.bundleIdentifier] = tmuxIndex + 1
            let title = BundleRegistry.managedTmuxWindowTitle(
                bundleId: window.bundleIdentifier,
                index: tmuxIndex
            )
            targetSessionEntries.append((slotIndex, (sessionName, title, window.bundleIdentifier)))
        }

        let targetSessionsBySlot = Dictionary(uniqueKeysWithValues: targetSessionEntries)

        guard !targetSessionsBySlot.isEmpty else { return }

        var clients = await listClients()
        guard !clients.isEmpty else { return }

        var switchedCount = 0
        for client in clients {
            guard let slotIndex = Self.quickSwitchSlotIndex(fromSessionName: client.sessionName),
                  let target = targetSessionsBySlot[slotIndex],
                  client.sessionName != target.sessionName else {
                continue
            }

            // Only rebind if the client's window bundle matches the target bundle.
            // This prevents Terminal.app clients from being switched to Ghostty sessions
            // (or vice versa) when crossing workspaces with different terminal compositions.
            if let clientBundle = clientBundleByPID[client.clientPID],
               clientBundle != target.bundleId {
                continue
            }

            DeskJigLog.debug(.tmux, "Rebinding attached quick-switch client after terminal phase", fields: [
                "clientTTY": client.clientTTY,
                "fromSession": client.sessionName,
                "toSession": target.sessionName,
                "slotIndex": "\(slotIndex)"
            ], runId: runId)

            do {
                try await commandService.switchClient(clientTTY: client.clientTTY, toSession: target.sessionName)
                if let title = target.title {
                    try await commandService.ensureTitlePropagation()
                    try await commandService.setPaneTitle(session: target.sessionName, title: title)
                }
                switchedCount += 1
            } catch {
                DeskJigLog.debug(.tmux, "Failed to rebind attached quick-switch client", fields: [
                    "clientTTY": client.clientTTY,
                    "fromSession": client.sessionName,
                    "toSession": target.sessionName,
                    "slotIndex": "\(slotIndex)",
                    "error": error.localizedDescription
                ], runId: runId)
            }
        }

        clients = await listClients()
        let targetSessionNames = Set(targetSessionsBySlot.values.map { $0.sessionName })
        var clientsBySession = Dictionary(grouping: clients.filter { targetSessionNames.contains($0.sessionName) }, by: \.sessionName)
        let attachedTargetSessionNames = Set(clientsBySession.keys)
        let missingSlots = targetSessionsBySlot.keys.sorted().filter { slotIndex in
            guard let target = targetSessionsBySlot[slotIndex] else { return false }
            return !attachedTargetSessionNames.contains(target.sessionName)
        }

        if !missingSlots.isEmpty {
            for missingSlot in missingSlots {
                guard let missingTarget = targetSessionsBySlot[missingSlot] else { continue }
                let preferredDonorSessionName = clientsBySession.keys.sorted().first { sessionName in
                    guard clientsBySession[sessionName]?.count ?? 0 > 1,
                          let donorSlotIndex = Self.quickSwitchSlotIndex(fromSessionName: sessionName),
                          let donorTarget = targetSessionsBySlot[donorSlotIndex] else {
                        return false
                    }
                    return donorTarget.bundleId == missingTarget.bundleId
                }
                // Only use same-bundle donors to prevent cross-bundle title contamination.
                let donorSessionName = preferredDonorSessionName

                guard let donorSessionName,
                      var donorClients = clientsBySession[donorSessionName],
                      let donorClient = donorClients.popLast() else {
                    break
                }

                DeskJigLog.debug(.tmux, "Rebinding duplicate attached quick-switch client to missing slot", fields: [
                    "clientTTY": donorClient.clientTTY,
                    "fromSession": donorSessionName,
                    "toSession": missingTarget.sessionName,
                    "missingSlotIndex": "\(missingSlot)",
                    "bundleId": missingTarget.bundleId
                ], runId: runId)

                do {
                    try await commandService.switchClient(
                        clientTTY: donorClient.clientTTY,
                        toSession: missingTarget.sessionName
                    )
                    if let title = missingTarget.title {
                        try await commandService.ensureTitlePropagation()
                        try await commandService.setPaneTitle(session: missingTarget.sessionName, title: title)
                    }
                    switchedCount += 1

                    clientsBySession[donorSessionName] = donorClients
                    clientsBySession[missingTarget.sessionName, default: []].append(
                        TmuxClientInfo(
                            clientTTY: donorClient.clientTTY,
                            sessionName: missingTarget.sessionName,
                            clientPID: donorClient.clientPID
                        )
                    )
                } catch {
                    DeskJigLog.debug(.tmux, "Failed to rebind duplicate client to missing quick-switch slot", fields: [
                        "clientTTY": donorClient.clientTTY,
                        "fromSession": donorSessionName,
                        "toSession": missingTarget.sessionName,
                        "missingSlotIndex": "\(missingSlot)",
                        "bundleId": missingTarget.bundleId,
                        "error": error.localizedDescription
                    ], runId: runId)
                }
            }
        }

        if switchedCount > 0 {
            DeskJigLog.debug(.tmux, "Post-terminal quick-switch client reconciliation complete", fields: [
                "switchedCount": "\(switchedCount)",
                "targetSlotCount": "\(targetSessionsBySlot.count)"
            ], runId: runId)
        }
    }

    /// Cleans up DeskJig tmux sessions for a deleted workspace.
    public func cleanupWorkspaceSessions(
        workspaceId: String,
        runId: String
    ) async {
        let prefix = Self.workspaceSessionPrefix(for: workspaceId)
        let sessions: [TmuxSessionInfo]
        do {
            sessions = try await commandService.listSessions()
        } catch {
            // A list failure here silently skips cleanup and leaks sessions.
            DeskJigLog.debug(.tmux, "list-sessions failed — skipping workspace session cleanup", fields: [
                "workspaceId": workspaceId,
                "error": error.localizedDescription
            ], runId: runId)
            return
        }

        for session in sessions where session.sessionName.hasPrefix(prefix) {
            do {
                try await commandService.killSession(name: session.sessionName)
                DeskJigLog.debug(.tmux, "Session killed", fields: [
                    "sessionName": session.sessionName
                ], runId: runId)
            } catch {
                // Session may not exist by the time we try to kill it.
            }
        }
    }

    // MARK: - Private Helpers

    /// Gets the parent PID of a process.
    public static func parentPID(of pid: pid_t) -> pid_t {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        let result = sysctl(&mib, UInt32(mib.count), &info, &size, nil, 0)
        guard result == 0 else { return 0 }
        return info.kp_eproc.e_ppid
    }
}
