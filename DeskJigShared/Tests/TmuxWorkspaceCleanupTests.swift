//  TmuxWorkspaceCleanupTests.swift
//  DeskJigSharedTests

import Testing
import Foundation
@testable import DeskJigShared

// Gated: needs a real tmux binary and drives the DeskJig tmux socket.
@Suite(
    "Tmux workspace-deletion cleanup (REAL TMUX)",
    .serialized,
    .enabled(if: TestEnvironment.envTestsEnabled, TestEnvironment.gateReason)
)
struct TmuxWorkspaceCleanupTests {

    @Test("cleanupWorkspaceSessions kills only the deleted workspace's sessions")
    func cleanupKillsOnlyMatchingSessions() async throws {
        let service = TmuxCommandService()
        guard await service.isAvailable else {
            Issue.record("tmux is not installed; DESKJIG_ENV_TESTS runs require it")
            return
        }

        let deletedWorkspaceId = UUID().uuidString
        let survivingWorkspaceId = UUID().uuidString
        let deletedPrefix = TmuxSessionManager.workspaceSessionPrefix(for: deletedWorkspaceId)
        let survivingPrefix = TmuxSessionManager.workspaceSessionPrefix(for: survivingWorkspaceId)
        let deletedSession = "\(deletedPrefix)cleanuptest"
        let survivingSession = "\(survivingPrefix)cleanuptest"
        let workingDirectory = FileManager.default.temporaryDirectory.path

        try await service.ensureSession(name: deletedSession, workingDirectory: workingDirectory)
        try await service.ensureSession(name: survivingSession, workingDirectory: workingDirectory)
        defer {
            Task {
                try? await service.killSession(name: deletedSession)
                try? await service.killSession(name: survivingSession)
            }
        }

        await TmuxSessionManager(commandService: service)
            .cleanupWorkspaceSessions(workspaceId: deletedWorkspaceId, runId: "test-cleanup")

        #expect(await service.sessionExists(name: deletedSession) == false)
        #expect(await service.sessionExists(name: survivingSession) == true)
    }
}
