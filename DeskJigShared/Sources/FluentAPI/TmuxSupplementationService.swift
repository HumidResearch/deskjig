//  TmuxSupplementationService.swift
//  DeskJigShared

import Foundation

// MARK: - Tmux Supplementation Service

/// Detects tmux sessions in terminal windows during workspace save.
///
/// During workspace capture, this service checks if Ghostty terminal windows
/// have tmux clients attached. If so, it stores the session name and working
/// directory on `WorkspaceWindow.tmuxState` to enable fast session switching
/// on workspace restore.
///
/// ## Usage
///
/// ```swift
/// let service = TmuxSupplementationService()
/// let enrichedWindows = await service.supplementWindows(
///     workspace.windows,
///     runId: "capture_123"
/// )
/// ```
public actor TmuxSupplementationService {

    // MARK: - Properties

    private let commandService: TmuxCommandService

    // MARK: - Initialization

    public init(commandService: TmuxCommandService = TmuxCommandService()) {
        self.commandService = commandService
    }

    // MARK: - Supplementation

    /// Enriches workspace windows with tmux session state.
    ///
    /// For each Ghostty terminal window, checks if it has a tmux client attached.
    /// If so, sets `tmuxState` with the session name and working directory.
    ///
    /// - Parameters:
    ///   - windows: The workspace windows to enrich
    ///   - windowPIDs: Map of workspace window index to PID (from CGWindowList)
    ///   - runId: Run ID for logging
    /// - Returns: Updated windows with tmuxState populated where applicable
    public func supplementWindows(
        _ windows: [WorkspaceWindow],
        windowPIDs: [Int: pid_t],
        runId: String
    ) async -> [WorkspaceWindow] {
        guard await commandService.isAvailable else {
            return windows
        }

        let startTime = Date()

        // Get all tmux clients
        let clients: [TmuxClientInfo]
        do {
            clients = try await commandService.listClients()
        } catch {
            DeskJigLog.debug(.tmux, "Failed to list tmux clients for supplementation", fields: [
                "error": error.localizedDescription
            ], runId: runId)
            return windows
        }

        guard !clients.isEmpty else {
            return windows
        }

        // Get all sessions for working directory info
        let sessions: [TmuxSessionInfo]
        do {
            sessions = try await commandService.listSessions()
        } catch {
            sessions = []
        }
        let sessionsByName = Dictionary(uniqueKeysWithValues: sessions.map { ($0.sessionName, $0) })

        var enrichedWindows: [WorkspaceWindow] = []
        var enrichedCount = 0

        for (index, window) in windows.enumerated() {
            guard window.bundleIdentifier == BundleRegistry.ghostty,
                  let windowPID = windowPIDs[index] else {
                enrichedWindows.append(window)
                continue
            }

            // Check if any tmux client is a child of this terminal window's process
            let matchedClient = findClientForTerminalPID(windowPID, clients: clients)

            if let client = matchedClient {
                let sessionPath = sessionsByName[client.sessionName]?.sessionPath ?? window.openPath ?? "~"
                let state = TmuxSessionState(
                    sessionName: client.sessionName,
                    initialWorkingDirectory: sessionPath
                )
                enrichedWindows.append(window.withTmuxState(state))
                enrichedCount += 1

                DeskJigLog.debug(.tmux, "Window supplemented with tmux state", fields: [
                    "windowIndex": "\(index)",
                    "sessionName": client.sessionName,
                    "sessionPath": sessionPath,
                    "terminalPID": "\(windowPID)"
                ], runId: runId)
            } else {
                enrichedWindows.append(window)
            }
        }

        let durationMs = Int(Date().timeIntervalSince(startTime) * 1000)
        DeskJigLog.debug(.tmux, "Supplementation complete", fields: [
            "enrichedCount": "\(enrichedCount)",
            "totalGhostty": "\(windows.filter { $0.bundleIdentifier == BundleRegistry.ghostty }.count)",
            "durationMs": "\(durationMs)"
        ], runId: runId)

        return enrichedWindows
    }

    // MARK: - Private Helpers

    /// Finds the tmux client that belongs to a terminal window's process tree.
    private func findClientForTerminalPID(
        _ terminalPID: pid_t,
        clients: [TmuxClientInfo]
    ) -> TmuxClientInfo? {
        for client in clients {
            // Direct match
            if client.clientPID == terminalPID {
                return client
            }

            // Walk up from client PID to find terminal PID
            var currentPid = TmuxSessionManager.parentPID(of: client.clientPID)
            var depth = 0
            while currentPid > 1 && depth < 10 {
                if currentPid == terminalPID {
                    return client
                }
                currentPid = TmuxSessionManager.parentPID(of: currentPid)
                depth += 1
            }
        }
        return nil
    }
}
