// WorkspaceLaunchSourcePolicyTests.swift
// DeskJigTests

import Testing
@testable import DeskJig
@testable import DeskJigShared

struct WorkspaceLaunchSourcePolicyTests {

    @Test("Quick Switch source closes settings window immediately")
    func quickSwitchClosesImmediately() {
        #expect(
            WorkspaceViewModel.shouldCloseMainWindowImmediately(
                source: WorkspaceViewModel.quickSwitchLaunchSource
            )
        )
    }

    @Test("Settings-enter source closes settings window immediately")
    func settingsEnterClosesImmediately() {
        #expect(
            WorkspaceViewModel.shouldCloseMainWindowImmediately(
                source: WorkspaceViewModel.settingsEnterLaunchSource
            )
        )
    }

    @Test("Unknown source does not close settings window immediately")
    func unknownSourceDoesNotCloseImmediately() {
        #expect(!WorkspaceViewModel.shouldCloseMainWindowImmediately(source: "unknown"))
        #expect(!WorkspaceViewModel.shouldCloseMainWindowImmediately(source: "menu"))
    }

    @Test("Quick Switch launch resolution preserves transformed workspace payload")
    func quickSwitchLaunchResolutionPreservesTransformedWorkspace() {
        let workspaceID = UUID()
        let windowID = UUID()
        let persistedWorkspace = Workspace(
            id: workspaceID,
            name: "Main Dev",
            workspaceWindows: [
                WorkspaceWindow(
                    id: windowID,
                    bundleIdentifier: OpenByPathBundleIdentifiers.ghostty,
                    appName: "Ghostty",
                    windowTitle: "Ghostty",
                    terminalKey: "persisted-key",
                    openPath: "/Users/brutus",
                    tmuxState: TmuxSessionState(
                        sessionName: "persisted-session",
                        initialWorkingDirectory: "/Users/brutus"
                    )
                )
            ]
        )
        let transformedWorkspace = persistedWorkspace.withNewWindows([
            WorkspaceWindow(
                id: windowID,
                bundleIdentifier: OpenByPathBundleIdentifiers.ghostty,
                appName: "Ghostty",
                windowTitle: "Ghostty",
                terminalKey: "qs_guidebook_s0",
                openPath: "/Users/brutus/code/guidebook",
                tmuxState: TmuxSessionState(
                    sessionName: "persisted-session",
                    initialWorkingDirectory: "/Users/brutus/code/guidebook"
                )
            )
        ])

        let resolution = WorkspaceViewModel.resolveWorkspaceForLaunch(
            transformedWorkspace,
            source: WorkspaceViewModel.quickSwitchLaunchSource,
            savedWorkspaces: [persistedWorkspace]
        )

        #expect(resolution.workspace == transformedWorkspace)
        #expect(!resolution.usedLatestPersistedCopy)
        #expect(resolution.persistedWorkspace == persistedWorkspace)
    }

    @Test("Non quick-switch launch resolution still prefers persisted workspace")
    func nonQuickSwitchLaunchResolutionUsesPersistedWorkspace() {
        let workspaceID = UUID()
        let persistedWorkspace = Workspace(
            id: workspaceID,
            name: "Main Dev",
            workspaceWindows: []
        )
        let transientWorkspace = persistedWorkspace.withNewName("Transient")

        let resolution = WorkspaceViewModel.resolveWorkspaceForLaunch(
            transientWorkspace,
            source: "menu",
            savedWorkspaces: [persistedWorkspace]
        )

        #expect(resolution.workspace == persistedWorkspace)
        #expect(resolution.usedLatestPersistedCopy)
    }
}

