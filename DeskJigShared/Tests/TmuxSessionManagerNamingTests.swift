//  TmuxSessionManagerNamingTests.swift
//  DeskJigSharedTests

import Testing
@testable import DeskJigShared

struct TmuxSessionManagerNamingTests {

    @Test("Quick Switch launch source uses directory-slot naming mode")
    func quickSwitchUsesDirectorySlotMode() {
        #expect(TmuxSessionManager.sessionNamingMode(for: "quick-switch") == .directorySlot)
    }

    @Test("Non-Quick Switch launch source keeps workspace naming mode")
    func nonQuickSwitchUsesWorkspaceMode() {
        #expect(TmuxSessionManager.sessionNamingMode(for: "actionPanel") == .workspace)
        #expect(TmuxSessionManager.sessionNamingMode(for: "unknown") == .workspace)
    }

    @Test("Quick Switch directory-slot session names are stable for same directory+slot")
    func quickSwitchSessionNamesStableByDirectorySlot() {
        let directory = "/Users/testuser/code/deskjig"
        let nameA = TmuxSessionManager.quickSwitchSessionName(forDirectoryPath: directory, slotIndex: 0)
        let nameB = TmuxSessionManager.quickSwitchSessionName(forDirectoryPath: directory, slotIndex: 0)
        let slotOneName = TmuxSessionManager.quickSwitchSessionName(forDirectoryPath: directory, slotIndex: 1)

        #expect(nameA == nameB)
        #expect(nameA != slotOneName)
        #expect(nameA.hasPrefix("bento_qs_"))
    }

    @Test("Quick Switch session namespace is independent of workspace-scoped legacy names")
    func quickSwitchDoesNotUseWorkspaceScopedNamespace() {
        let directory = "/Users/testuser/code/deskjig"
        let workspaceId = "85f37006-1111-2222-3333-444444444444"
        let terminalKey = TmuxSessionManager.quickSwitchTerminalKey(forDirectoryPath: directory, slotIndex: 0)

        let quickSwitchName = TmuxSessionManager.quickSwitchSessionName(forDirectoryPath: directory, slotIndex: 0)
        let workspaceScopedName = TmuxSessionManager.sessionName(forWorkspaceId: workspaceId, terminalKey: terminalKey)

        #expect(quickSwitchName != workspaceScopedName)
        #expect(!quickSwitchName.contains(String(workspaceId.prefix(8)).lowercased()))
    }

    @Test("Existing tmux sessions preserve pane history and cwd state")
    func existingSessionsPreserveHistoryAndCWD() {
        #expect(!TmuxCommandService.shouldMutateExistingSessionWorkingDirectory())
    }
}
