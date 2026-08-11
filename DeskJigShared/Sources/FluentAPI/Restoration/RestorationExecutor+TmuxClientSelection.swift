//  RestorationExecutor+TmuxClientSelection.swift
//  DeskJigShared

import Foundation
import CoreGraphics
import AppKit

extension RestorationExecutor {

    // MARK: - Tmux Client Selection

    struct TmuxClientSelection {
        let client: TmuxClientInfo
        let reason: String
    }

    struct ITermWindowTTYBinding: Sendable {
        let windowId: CGWindowID
        let tty: String
        let sessionName: String
    }

    private struct ITermTTYSelectionOutcome {
        let client: TmuxClientInfo?
        let failureReason: String
        let mappingCount: Int
        let attempts: Int
    }

    private func clientBelongsToTerminal(client: TmuxClientInfo, terminalPid: pid_t) -> Bool {
        if client.clientPID == terminalPid {
            return true
        }
        var currentPid = TmuxSessionManager.parentPID(of: client.clientPID)
        var depth = 0
        while currentPid > 1 && depth < 10 {
            if currentPid == terminalPid {
                return true
            }
            currentPid = TmuxSessionManager.parentPID(of: currentPid)
            depth += 1
        }
        return false
    }

    func logRC10Diag(
        _ message: String,
        runId: String,
        data: [String: any Sendable] = [:]
    ) {
        let orderedFields = data
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: " ")
        let suffix = orderedFields.isEmpty ? "" : " \(orderedFields)"
        DeskJigLog.trace(.restorationExecutor, "RC10_DIAG \(message)\(suffix)", runId: runId)
    }

    private func claimedTmuxSelectionsDescription(bundleId: String) -> (ttys: String, sessions: String) {
        let claimedTTYs = (tmuxClaimedClientTTYsByBundle[bundleId] ?? []).sorted()
        let claimedSessions = (tmuxClaimedSessionsByBundle[bundleId] ?? []).sorted()
        let ttyString = claimedTTYs.isEmpty ? "none" : claimedTTYs.joined(separator: ",")
        let sessionString = claimedSessions.isEmpty ? "none" : claimedSessions.joined(separator: ",")
        return (ttys: ttyString, sessions: sessionString)
    }

    private func tryClaimTmuxClientSelection(
        bundleId: String,
        candidate: TmuxClientInfo,
        reason: String,
        taskContext: RestorationTaskContext,
        requestedSession: String?,
        enforceSessionMatch: Bool
    ) -> TmuxClientSelection? {
        if enforceSessionMatch,
           let requestedSession,
           candidate.sessionName != requestedSession {
            logRC10Diag(
                "tmux-client-rejected-session-mismatch",
                runId: taskContext.runId,
                data: [
                    "bundleId": bundleId,
                    "reason": reason,
                    "requestedSession": requestedSession,
                    "candidateSession": candidate.sessionName,
                    "candidateTTY": candidate.clientTTY
                ]
            )
            return nil
        }

        let claimedTTYs = tmuxClaimedClientTTYsByBundle[bundleId, default: []]
        if claimedTTYs.contains(candidate.clientTTY) {
            let claimed = claimedTmuxSelectionsDescription(bundleId: bundleId)
            logRC10Diag(
                "tmux-client-rejected-claimed-tty",
                runId: taskContext.runId,
                data: [
                    "bundleId": bundleId,
                    "reason": reason,
                    "candidateTTY": candidate.clientTTY,
                    "candidateSession": candidate.sessionName,
                    "claimedTTYs": claimed.ttys,
                    "claimedSessions": claimed.sessions
                ]
            )
            return nil
        }

        let claimedSessions = tmuxClaimedSessionsByBundle[bundleId, default: []]
        if claimedSessions.contains(candidate.sessionName) {
            let claimed = claimedTmuxSelectionsDescription(bundleId: bundleId)
            logRC10Diag(
                "tmux-client-rejected-claimed-session",
                runId: taskContext.runId,
                data: [
                    "bundleId": bundleId,
                    "reason": reason,
                    "candidateTTY": candidate.clientTTY,
                    "candidateSession": candidate.sessionName,
                    "claimedTTYs": claimed.ttys,
                    "claimedSessions": claimed.sessions
                ]
            )
            return nil
        }

        tmuxClaimedClientTTYsByBundle[bundleId, default: []].insert(candidate.clientTTY)
        tmuxClaimedSessionsByBundle[bundleId, default: []].insert(candidate.sessionName)

        let claimed = claimedTmuxSelectionsDescription(bundleId: bundleId)
        logRC10Diag(
            "tmux-client-claimed",
            runId: taskContext.runId,
            data: [
                "bundleId": bundleId,
                "reason": reason,
                "candidateTTY": candidate.clientTTY,
                "candidateSession": candidate.sessionName,
                "requestedSession": requestedSession ?? "nil",
                "claimedTTYs": claimed.ttys,
                "claimedSessions": claimed.sessions
            ]
        )

        return TmuxClientSelection(client: candidate, reason: reason)
    }

    func hasStrongManagedTmuxEvidenceFromTTYMapping(
        bundleId: String,
        plannedWindowId: CGWindowID,
        expectedSessionName: String,
        snapshotWindowTitle: String?,
        taskContext: RestorationTaskContext
    ) async -> Bool {
        guard bundleId == BundleRegistry.iterm2,
              let tmux = tmuxCommandService else {
            return false
        }

        let expectedWindowCount = max(expectedTmuxWindowCount(for: bundleId), 1)
        let clients: [TmuxClientInfo]
        do {
            clients = try await tmux.listClients()
        } catch {
            DeskJigLog.debug(.restorationTrace, "list-clients failed during TTY-mapping evidence check", fields: [
                "taskId": taskContext.taskId,
                "bundleId": bundleId,
                "windowId": plannedWindowId,
                "expectedSession": expectedSessionName,
                "error": error.localizedDescription
            ], runId: taskContext.runId)
            return false
        }
        guard !clients.isEmpty else { return false }

        let ttyOutcome = await selectITermClientByTTY(
            windowId: plannedWindowId,
            clients: clients,
            taskContext: taskContext,
            expectedWindowCount: expectedWindowCount
        )
        let mappedSessionName = ttyOutcome.client?.sessionName
        let hasEvidence = Self.shouldTreatTTYMappedSessionAsManagedEvidence(
            bundleId: bundleId,
            windowTitle: snapshotWindowTitle,
            mappedSessionName: mappedSessionName,
            expectedSessionName: expectedSessionName
        )
        guard hasEvidence else { return false }

        logRC10Diag(
            "quick-switch-tty-session-evidence",
            runId: taskContext.runId,
            data: [
                "bundleId": bundleId,
                "windowId": plannedWindowId,
                "expectedSession": expectedSessionName,
                "mappedSession": mappedSessionName ?? "nil",
                "windowTitle": snapshotWindowTitle ?? "nil",
                "attempts": ttyOutcome.attempts,
                "mappingCount": ttyOutcome.mappingCount
            ]
        )
        return true
    }

    func selectTmuxClientForWindow(
        bundleId: String,
        plannedWindowId: CGWindowID?,
        requestedSnapshotWindow: SnapshotWindow?,
        clients: [TmuxClientInfo],
        snapshot: SystemSnapshot,
        taskContext: RestorationTaskContext,
        sessionName: String?,
        launchSource: String,
        bindingEvidence: TmuxTerminalBindingEvidence? = nil
    ) async -> TmuxClientSelection? {
        guard !clients.isEmpty else { return nil }

        let expectedWindowCount = max(expectedTmuxWindowCount(for: bundleId), 1)
        let shouldUseITermTTYMapping = bundleId == BundleRegistry.iterm2 &&
            expectedWindowCount > 1

        if shouldUseITermTTYMapping {
            guard let plannedWindowId else {
                logRC10Diag(
                    "iterm-multi-window-missing-planned-window",
                    runId: taskContext.runId,
                    data: [
                        "bundleId": bundleId,
                        "expectedWindowCount": expectedWindowCount,
                        "clientCount": clients.count
                    ]
                )
                return nil
            }

            let ttyOutcome = await selectITermClientByTTY(
                windowId: plannedWindowId,
                clients: clients,
                taskContext: taskContext,
                expectedWindowCount: expectedWindowCount
            )

            logRC10Diag(
                "iterm-tty-mapping-outcome",
                runId: taskContext.runId,
                data: [
                    "bundleId": bundleId,
                    "windowId": plannedWindowId,
                    "clientCount": clients.count,
                    "expectedWindowCount": expectedWindowCount,
                    "mappingCount": ttyOutcome.mappingCount,
                    "attempts": ttyOutcome.attempts,
                    "failureReason": ttyOutcome.failureReason,
                    "mappedClientTTY": ttyOutcome.client?.clientTTY ?? "none",
                    "mappedClientSession": ttyOutcome.client?.sessionName ?? "none"
                ]
            )

            let enforceSessionMatchForTTYMappedClient = Self.shouldEnforceSessionMatchForITermTTYMappedSelection(
                bundleId: bundleId,
                launchSource: launchSource,
                expectedWindowCount: expectedWindowCount
            )
            logRC10Diag(
                "iterm-tty-mapped-claim-policy",
                runId: taskContext.runId,
                data: [
                    "bundleId": bundleId,
                    "launchSource": launchSource,
                    "windowId": plannedWindowId,
                    "expectedWindowCount": expectedWindowCount,
                    "enforceSessionMatch": enforceSessionMatchForTTYMappedClient,
                    "mappedTTY": ttyOutcome.client?.clientTTY ?? "none",
                    "mappedSession": ttyOutcome.client?.sessionName ?? "none",
                    "requestedSession": sessionName ?? "nil"
                ]
            )

            if let mappedClient = ttyOutcome.client,
               let claimedSelection = tryClaimTmuxClientSelection(
                bundleId: bundleId,
                candidate: mappedClient,
                reason: TmuxIndexTraceReason.itermWindowTTYMappedSelection.rawValue,
                taskContext: taskContext,
                requestedSession: sessionName,
                enforceSessionMatch: enforceSessionMatchForTTYMappedClient
               ) {
                return claimedSelection
            }

            if ttyOutcome.client != nil {
                // If a TTY mapping exists for this specific iTerm window but we
                // still cannot claim it (already-claimed or strict mismatch),
                // do not fall back to a different session client.
                logRC10Diag(
                    "iterm-tty-mapped-client-not-claimable",
                    runId: taskContext.runId,
                    data: [
                        "bundleId": bundleId,
                        "windowId": plannedWindowId,
                        "mappedTTY": ttyOutcome.client?.clientTTY ?? "none",
                        "mappedSession": ttyOutcome.client?.sessionName ?? "none",
                        "requestedSession": sessionName ?? "nil",
                        "enforceSessionMatch": enforceSessionMatchForTTYMappedClient
                    ]
                )
                return nil
            }

            // Reliability-first policy for iTerm multi-window restores:
            // when TTY mapping is unavailable, only allow exact session matches.
            if let sessionName {
                let exactSessionClients = clients
                    .filter { $0.sessionName == sessionName }
                    .sorted { lhs, rhs in
                        let lhsRank = (lhs.clientTTY, lhs.clientPID)
                        let rhsRank = (rhs.clientTTY, rhs.clientPID)
                        return lhsRank < rhsRank
                    }

                for candidate in exactSessionClients {
                    if let claimedSelection = tryClaimTmuxClientSelection(
                        bundleId: bundleId,
                        candidate: candidate,
                        reason: "fallback-session-match-iterm-multi",
                        taskContext: taskContext,
                        requestedSession: sessionName,
                        enforceSessionMatch: true
                    ) {
                        return claimedSelection
                    }
                }
            }

            logRC10Diag(
                "iterm-multi-window-no-claimable-exact-session-client",
                runId: taskContext.runId,
                data: [
                    "bundleId": bundleId,
                    "windowId": plannedWindowId,
                    "expectedSession": sessionName ?? "nil",
                    "clientCount": clients.count
                ]
            )
            return nil
        }

        if let requestedSnapshotWindow {
            let pidMatches = clients
                .filter { self.clientBelongsToTerminal(client: $0, terminalPid: requestedSnapshotWindow.pid) }
                .sorted { lhs, rhs in
                    let lhsRank = (lhs.sessionName, lhs.clientTTY, lhs.clientPID)
                    let rhsRank = (rhs.sessionName, rhs.clientTTY, rhs.clientPID)
                    return lhsRank < rhsRank
                }
            for matched in pidMatches {
                if let claimedSelection = tryClaimTmuxClientSelection(
                    bundleId: bundleId,
                    candidate: matched,
                    reason: "pid-tree-match",
                    taskContext: taskContext,
                    requestedSession: sessionName,
                    enforceSessionMatch: false
                ) {
                    return claimedSelection
                }
            }
        }

        if let plannedWindowId,
           let plannedWindow = snapshot.windows.first(where: { $0.windowId == plannedWindowId }) {
            let pidMatches = clients
                .filter { self.clientBelongsToTerminal(client: $0, terminalPid: plannedWindow.pid) }
                .sorted { lhs, rhs in
                    let lhsRank = (lhs.sessionName, lhs.clientTTY, lhs.clientPID)
                    let rhsRank = (rhs.sessionName, rhs.clientTTY, rhs.clientPID)
                    return lhsRank < rhsRank
                }
            for matched in pidMatches {
                if let claimedSelection = tryClaimTmuxClientSelection(
                    bundleId: bundleId,
                    candidate: matched,
                    reason: "pid-tree-match",
                    taskContext: taskContext,
                    requestedSession: sessionName,
                    enforceSessionMatch: false
                ) {
                    return claimedSelection
                }
            }
        }

        // Session-match fallback remains useful for terminals where process-tree
        // walking can fail after daemonization/re-parenting.
        if let sessionName {
            let sessionMatches = clients
                .filter { $0.sessionName == sessionName }
                .sorted { lhs, rhs in
                    let lhsRank = (lhs.clientTTY, lhs.clientPID)
                    let rhsRank = (rhs.clientTTY, rhs.clientPID)
                    return lhsRank < rhsRank
                }
            for matched in sessionMatches {
                if let claimedSelection = tryClaimTmuxClientSelection(
                    bundleId: bundleId,
                    candidate: matched,
                    reason: "fallback-session-match",
                    taskContext: taskContext,
                    requestedSession: sessionName,
                    enforceSessionMatch: true
                ) {
                    return claimedSelection
                }
            }
        }

        // Last-resort deterministic selection constrained to same bundle.
        let rankedClients = clients.sorted { lhs, rhs in
            let lhsRank = (lhs.sessionName.hasPrefix("bento_") ? 0 : 1, lhs.clientTTY, lhs.clientPID)
            let rhsRank = (rhs.sessionName.hasPrefix("bento_") ? 0 : 1, rhs.clientTTY, rhs.clientPID)
            return lhsRank < rhsRank
        }

        for candidate in rankedClients {
            if let sessionName, candidate.sessionName != sessionName {
                logRC10Diag(
                    "tmux-ranked-fallback-skipped-session-mismatch",
                    runId: taskContext.runId,
                    data: [
                        "bundleId": bundleId,
                        "requestedSession": sessionName,
                        "candidateSession": candidate.sessionName,
                        "candidateTTY": candidate.clientTTY
                    ]
                )
                continue
            }
            if let candidateWindow = self.snapshotWindowForClient(candidate, in: snapshot),
               candidateWindow.bundleId == bundleId,
               let claimedSelection = tryClaimTmuxClientSelection(
                bundleId: bundleId,
                candidate: candidate,
                reason: "fallback-same-bundle",
                taskContext: taskContext,
                requestedSession: sessionName,
                enforceSessionMatch: true
               ) {
                return claimedSelection
            }
        }

        for first in rankedClients {
            if let sessionName, first.sessionName != sessionName {
                continue
            }
            if let claimedSelection = tryClaimTmuxClientSelection(
                bundleId: bundleId,
                candidate: first,
                reason: "fallback-ranked-client",
                taskContext: taskContext,
                requestedSession: sessionName,
                enforceSessionMatch: true
            ) {
                return claimedSelection
            }
        }

        // Final fallback for partialTopologyReuse / topologyUnavailableReuse evidence:
        // The intent of switchTmuxSession is to *change* the session, so requiring the
        // client to already be on the target session defeats the purpose. Relax session
        // matching and accept any unclaimed client belonging to this bundle.
        if let bindingEvidence,
           (bindingEvidence == .partialTopologyReuse || bindingEvidence == .topologyUnavailableReuse),
           let sessionName {
            for candidate in rankedClients {
                if let claimedSelection = tryClaimTmuxClientSelection(
                    bundleId: bundleId,
                    candidate: candidate,
                    reason: "fallback-reuse-relaxed-session",
                    taskContext: taskContext,
                    requestedSession: sessionName,
                    enforceSessionMatch: false
                ) {
                    logRC10Diag(
                        "tmux-relaxed-session-fallback-claimed",
                        runId: taskContext.runId,
                        data: [
                            "bundleId": bundleId,
                            "candidateTTY": candidate.clientTTY,
                            "candidateSession": candidate.sessionName,
                            "requestedSession": sessionName,
                            "bindingEvidence": bindingEvidence.rawValue
                        ]
                    )
                    return claimedSelection
                }
            }
        }

        return nil
    }

    private func selectITermClientByTTY(
        windowId: CGWindowID,
        clients: [TmuxClientInfo],
        taskContext: RestorationTaskContext,
        expectedWindowCount: Int
    ) async -> ITermTTYSelectionOutcome {
        let attemptTimeouts: [TimeInterval] = [1.0, 1.8]
        var lastFailureReason = "unknown"
        var lastMappingCount = 0
        let cacheMaxAgeMs = 1_400

        if let cachedBindings = cachedITermWindowTTYBindings(
            runId: taskContext.runId,
            maxAgeMs: cacheMaxAgeMs
        ) {
            lastMappingCount = cachedBindings.count
            let cachedSelection = evaluateITermTTYMappingSelection(
                windowId: windowId,
                clients: clients,
                bindings: cachedBindings
            )
            if let selected = cachedSelection.selectedClient {
                DeskJigLog.trace(.restorationTrace, "Selected iTerm client via tty mapping", fields: [
                    "taskId": taskContext.taskId,
                    "reason": TmuxIndexTraceReason.itermWindowTTYMappedSelection.rawValue,
                    "windowId": Int(windowId),
                    "mappedTTY": cachedSelection.mappedTTY ?? "nil",
                    "mappedSessionName": cachedSelection.mappedSessionName ?? "nil",
                    "selectedClientTTY": selected.clientTTY,
                    "selectedClientSession": selected.sessionName,
                    "mappingCount": cachedBindings.count,
                    "expectedWindowCount": expectedWindowCount,
                    "attempt": 0,
                    "source": "cache"
                ], runId: taskContext.runId)
                return ITermTTYSelectionOutcome(
                    client: selected,
                    failureReason: "none",
                    mappingCount: cachedBindings.count,
                    attempts: 0
                )
            }

            lastFailureReason = cachedSelection.failureReason
            DeskJigLog.trace(.restorationTrace, "iTerm tty cache candidate unusable", fields: [
                "taskId": taskContext.taskId,
                "windowId": Int(windowId),
                "clientCount": clients.count,
                "mappingCount": cachedBindings.count,
                "expectedWindowCount": expectedWindowCount,
                "failureReason": lastFailureReason,
                "source": "cache"
            ], runId: taskContext.runId)
        }

        attemptLoop: for (attemptIndex, timeout) in attemptTimeouts.enumerated() {
            let attemptNumber = attemptIndex + 1
            let isFinalAttempt = attemptIndex == attemptTimeouts.count - 1
            let bindings = await fetchITermWindowTTYBindingsDeduped(
                runId: taskContext.runId,
                timeout: timeout
            )
            if !bindings.isEmpty {
                cacheITermWindowTTYBindings(bindings, runId: taskContext.runId)
            }
            lastMappingCount = bindings.count
            let mappingIncomplete = bindings.count < expectedWindowCount

            let selection = evaluateITermTTYMappingSelection(
                windowId: windowId,
                clients: clients,
                bindings: bindings
            )
            guard let selected = selection.selectedClient else {
                lastFailureReason = selection.failureReason
                switch lastFailureReason {
                case "empty-bindings":
                    DeskJigLog.debug(.restorationTrace, "iTerm tty mapping unavailable", fields: [
                        "taskId": taskContext.taskId,
                        "reason": TmuxIndexTraceReason.itermWindowTTYMappingUnavailable.rawValue,
                        "windowId": Int(windowId),
                        "clientCount": clients.count,
                        "mappingCount": 0,
                        "expectedWindowCount": expectedWindowCount,
                        "attempt": attemptNumber,
                        "willRetry": isFinalAttempt == false,
                        "failureReason": lastFailureReason
                    ], runId: taskContext.runId)
                    if !isFinalAttempt {
                        guard await Task.sleepUnlessCancelled(nanoseconds: 220_000_000) else { break attemptLoop }
                    }
                case "planned-window-not-mapped":
                    DeskJigLog.debug(.restorationTrace, "iTerm tty mapping missing planned window", fields: [
                        "taskId": taskContext.taskId,
                        "reason": TmuxIndexTraceReason.itermWindowTTYMappingUnavailable.rawValue,
                        "windowId": Int(windowId),
                        "clientCount": clients.count,
                        "mappingCount": bindings.count,
                        "expectedWindowCount": expectedWindowCount,
                        "attempt": attemptNumber,
                        "willRetry": isFinalAttempt == false,
                        "mappingIncomplete": mappingIncomplete,
                        "failureReason": lastFailureReason
                    ], runId: taskContext.runId)
                    if !isFinalAttempt {
                        guard await Task.sleepUnlessCancelled(nanoseconds: 180_000_000) else { break attemptLoop }
                    }
                default:
                    DeskJigLog.debug(.restorationTrace, "iTerm tty mapping missing tmux client for tty", fields: [
                        "taskId": taskContext.taskId,
                        "reason": TmuxIndexTraceReason.itermWindowTTYMappingUnavailable.rawValue,
                        "windowId": Int(windowId),
                        "mappedTTY": selection.mappedTTY ?? "nil",
                        "mappedSessionName": selection.mappedSessionName ?? "nil",
                        "clientCount": clients.count,
                        "mappingCount": bindings.count,
                        "expectedWindowCount": expectedWindowCount,
                        "attempt": attemptNumber,
                        "willRetry": isFinalAttempt == false,
                        "failureReason": lastFailureReason
                    ], runId: taskContext.runId)
                    if !isFinalAttempt {
                        guard await Task.sleepUnlessCancelled(nanoseconds: 180_000_000) else { break attemptLoop }
                    }
                }
                continue
            }

            DeskJigLog.trace(.restorationTrace, "Selected iTerm client via tty mapping", fields: [
                "taskId": taskContext.taskId,
                "reason": TmuxIndexTraceReason.itermWindowTTYMappedSelection.rawValue,
                "windowId": Int(windowId),
                "mappedTTY": selection.mappedTTY ?? "nil",
                "mappedSessionName": selection.mappedSessionName ?? "nil",
                "selectedClientTTY": selected.clientTTY,
                "selectedClientSession": selected.sessionName,
                "mappingCount": bindings.count,
                "expectedWindowCount": expectedWindowCount,
                "attempt": attemptNumber,
                "source": "osascript"
            ], runId: taskContext.runId)
            return ITermTTYSelectionOutcome(
                client: selected,
                failureReason: "none",
                mappingCount: bindings.count,
                attempts: attemptNumber
            )
        }

        DeskJigLog.debug(.restorationTrace, "iTerm tty mapping unavailable after retries", fields: [
            "taskId": taskContext.taskId,
            "reason": TmuxIndexTraceReason.itermWindowTTYMappingUnavailable.rawValue,
            "windowId": Int(windowId),
            "clientCount": clients.count,
            "mappingCount": lastMappingCount,
            "expectedWindowCount": expectedWindowCount,
            "failureReason": lastFailureReason
        ], runId: taskContext.runId)
        return ITermTTYSelectionOutcome(
            client: nil,
            failureReason: lastFailureReason,
            mappingCount: lastMappingCount,
            attempts: attemptTimeouts.count
        )
    }

    private func evaluateITermTTYMappingSelection(
        windowId: CGWindowID,
        clients: [TmuxClientInfo],
        bindings: [ITermWindowTTYBinding]
    ) -> (selectedClient: TmuxClientInfo?, failureReason: String, mappedTTY: String?, mappedSessionName: String?) {
        guard !bindings.isEmpty else {
            return (nil, "empty-bindings", nil, nil)
        }
        guard let binding = bindings.first(where: { $0.windowId == windowId }) else {
            return (nil, "planned-window-not-mapped", nil, nil)
        }

        let normalizedTTY = normalizeTTY(binding.tty)
        let mappedClients = clients.filter { normalizeTTY($0.clientTTY) == normalizedTTY }
            .sorted { lhs, rhs in
                let lhsRank = (lhs.sessionName, lhs.clientPID)
                let rhsRank = (rhs.sessionName, rhs.clientPID)
                return lhsRank < rhsRank
            }
        guard let selected = mappedClients.first else {
            return (nil, "no-client-for-mapped-tty", binding.tty, binding.sessionName)
        }

        return (selected, "none", binding.tty, binding.sessionName)
    }

    private func cachedITermWindowTTYBindings(
        runId: String,
        maxAgeMs: Int
    ) -> [ITermWindowTTYBinding]? {
        guard let cached = iTermTTYBindingCacheByRun[runId] else {
            return nil
        }
        let ageMs = Int(Date().timeIntervalSince(cached.timestamp) * 1000)
        guard ageMs <= maxAgeMs else {
            iTermTTYBindingCacheByRun.removeValue(forKey: runId)
            return nil
        }

        let bindings = cached.rows.compactMap(parseITermWindowTTYBindingRow)
        return bindings.isEmpty ? nil : bindings
    }

    private func cacheITermWindowTTYBindings(
        _ bindings: [ITermWindowTTYBinding],
        runId: String
    ) {
        let rows = bindings.map { binding in
            "\(Int(binding.windowId))|\(binding.tty)|\(binding.sessionName)"
        }
        iTermTTYBindingCacheByRun[runId] = (rows: rows, timestamp: Date())
    }

    /// Fetches iTerm TTY bindings off the actor so siblings proceed during the ~1-1.8s
    /// osascript, coalescing concurrent same-run callers onto one in-flight Task to avoid a
    /// thundering herd of osascript invocations (exec-01). Reentrancy-safe: the in-flight
    /// map is actor-isolated; concurrent callers that arrive during the suspended
    /// `await task.value` observe the stored Task and await the same result.
    private func fetchITermWindowTTYBindingsDeduped(
        runId: String,
        timeout: TimeInterval
    ) async -> [ITermWindowTTYBinding] {
        if let existing = iTermFetchInFlightByRun[runId] {
            return await existing.value
        }
        let task = Task.detached(priority: .userInitiated) { [runId, timeout] in
            self.fetchITermWindowTTYBindings(runId: runId, timeout: timeout)
        }
        iTermFetchInFlightByRun[runId] = task
        let result = await task.value
        iTermFetchInFlightByRun[runId] = nil
        return result
    }

    private nonisolated func fetchITermWindowTTYBindings(
        runId: String,
        timeout: TimeInterval = 1.8
    ) -> [ITermWindowTTYBinding] {
        let scriptTemplate = """
        tell application "__APP_NAME__"
            set outputText to ""
            repeat with w in windows
                try
                    set sessionRef to current session of current tab of w
                    set outputText to outputText & (id of w as text) & "|" & (tty of sessionRef) & "|" & (name of sessionRef) & "\\n"
                end try
            end repeat
            return outputText
        end tell
        """

        let appNames = ["iTerm", "iTerm2"]
        for appName in appNames {
            let script = scriptTemplate.replacingOccurrences(of: "__APP_NAME__", with: appName)
            let result = AppleScriptRunner.runOsascript(script, timeout: timeout)
            guard result.exitCode == 0, !result.trimmedOutput.isEmpty else { continue }

            let lines = result.trimmedOutput.split(separator: "\n", omittingEmptySubsequences: true)
            let bindings: [ITermWindowTTYBinding] = lines.compactMap { line in
                parseITermWindowTTYBindingRow(String(line))
            }

            if !bindings.isEmpty {
                DeskJigLog.trace(.restorationTrace, "Fetched iTerm tty bindings", fields: [
                    "appName": appName,
                    "bindingCount": bindings.count,
                    "timeoutSec": String(format: "%.1f", timeout)
                ], runId: runId)
                return bindings
            }
        }

        DeskJigLog.debug(.restorationTrace, "Failed to fetch iTerm tty bindings", fields: [
            "reason": TmuxIndexTraceReason.itermWindowTTYMappingUnavailable.rawValue,
            "timeoutSec": String(format: "%.1f", timeout)
        ], runId: runId)
        return []
    }

    private nonisolated func parseITermWindowTTYBindingRow(_ row: String) -> ITermWindowTTYBinding? {
        let parts = row.split(separator: "|", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count >= 2 else { return nil }
        let windowIdRaw = String(parts[0]).trimmingCharacters(in: .whitespacesAndNewlines)
        let tty = String(parts[1]).trimmingCharacters(in: .whitespacesAndNewlines)
        let sessionName = parts.count > 2
            ? String(parts[2]).trimmingCharacters(in: .whitespacesAndNewlines)
            : ""
        guard let windowIdInt = UInt32(windowIdRaw),
              !tty.isEmpty else {
            return nil
        }

        return ITermWindowTTYBinding(
            windowId: CGWindowID(windowIdInt),
            tty: tty,
            sessionName: sessionName
        )
    }

    private func normalizeTTY(_ tty: String) -> String {
        tty.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func snapshotWindowForClient(
        _ client: TmuxClientInfo,
        in snapshot: SystemSnapshot,
        managedOnly: Bool = false,
        excludingWindowIds: Set<CGWindowID> = []
    ) -> SnapshotWindow? {
        for snapshotWindow in snapshot.windows where BundleRegistry.isTerminal(snapshotWindow.bundleId ?? "") {
            if managedOnly && !isManagedTmuxWindow(snapshotWindow) {
                continue
            }
            if excludingWindowIds.contains(snapshotWindow.windowId) {
                continue
            }
            if clientBelongsToTerminal(client: client, terminalPid: snapshotWindow.pid) {
                return snapshotWindow
            }
        }
        return nil
    }

    func managedTmuxWindows(in snapshot: SystemSnapshot, forBundleId bundleId: String? = nil) -> [SnapshotWindow] {
        snapshot.windows.filter { window in
            isManagedTmuxWindow(window) &&
            (bundleId == nil || window.bundleId == bundleId)
        }
    }

    static func shouldSuppressTmuxLaunchForBundleSurplus(
        expectedCount: Int,
        freshBundleWindowCount: Int,
        freshBundleAXWindowCount: Int?,
        managedWindowCount: Int
    ) -> Bool {
        guard managedWindowCount > 0 else {
            return false
        }

        let observedCount = freshBundleAXWindowCount ?? freshBundleWindowCount
        return observedCount >= expectedCount * 2
    }

    private func isManagedTmuxWindow(_ window: SnapshotWindow) -> Bool {
        BundleRegistry.isTerminal(window.bundleId ?? "") &&
        window.title?.contains(BundleRegistry.managedTmuxWindowTitle) == true
    }

    func observeTerminalBootstrapState(
        taskContext: RestorationTaskContext,
        resetReason: String
    ) async -> ManagedTmuxResetStats {
        let preResetSnapshot = await SystemSnapshotCapture.captureQuick(runId: taskContext.runId)
        let managedVisibleWindows = managedTmuxWindows(in: preResetSnapshot)
            .filter(\.isOnScreen)
        let preResetTerminalWindowCount = preResetSnapshot.windows.filter { BundleRegistry.isTerminal($0.bundleId ?? "") }.count

        let stats = ManagedTmuxResetStats(
            targetCount: managedVisibleWindows.count,
            preResetTerminalWindowCount: preResetTerminalWindowCount,
            managedWindowCount: managedVisibleWindows.count,
            destructiveActions: 0,
            resetMode: "none",
            resetReason: resetReason
        )

        DeskJigLog.debug(.restorationTrace, "Terminal bootstrap reset complete", fields: [
            "taskId": taskContext.taskId,
            "resetMode": stats.resetMode,
            "resetReason": stats.resetReason,
            "targetCount": stats.targetCount,
            "preResetTerminalWindowCount": stats.preResetTerminalWindowCount,
            "managedWindowCount": stats.managedWindowCount,
            "destructiveActions": stats.destructiveActions
        ], runId: taskContext.runId)

        return stats
    }
}
