//
//  FluentWorkspaceRestorerAuthoritativeBundlesTests.swift
//  DeskJigSharedTests
//
//  Verifies tmux authoritative bundle resolution for post-restore cleanup.
//

import Testing
import CoreGraphics
import Foundation
@testable import DeskJigShared

struct FluentWorkspaceRestorerAuthoritativeBundlesTests {

    @Test("tmux-prepared terminal bundles remain authoritative when snapshot mapping is incomplete")
    func tmuxPreparedBundlesRemainAuthoritativeWithoutSnapshotMapping() {
        let kittyWindow = WorkspaceWindow(
            id: UUID(),
            bundleIdentifier: OpenByPathBundleIdentifiers.kitty,
            appName: "kitty",
            windowTitle: "bento:tmux:managed:0",
            openPath: "/Users/andrew/code/nexus",
            tmuxState: TmuxSessionState(
                sessionName: "bento_qs_nexusabc123_s0",
                initialWorkingDirectory: "/Users/andrew/code/nexus"
            )
        )

        let taskResults = [
            TaskResult(
                taskId: "tmux-switch",
                success: true,
                windowId: 999, // Not present in bundle map to emulate capture gap.
                decision: .switchTmuxSession(
                    windowId: 999,
                    sessionName: "bento_qs_nexusabc123_s0",
                    targetFrame: .zero
                ),
                durationMs: 7,
                plannedWindowId: 888 // Also missing from bundle map.
            )
        ]

        let resolved = FluentWorkspaceRestorer.resolvePostRestoreAuthoritativeBundles(
            taskResults: taskResults,
            bundleByWindowId: [:],
            tmuxPreparedTerminalWindowsById: [kittyWindow.id: kittyWindow]
        )

        #expect(resolved.hasSuccessfulTmuxSwitch)
        #expect(resolved.tmuxPreparedTerminalBundles == Set([OpenByPathBundleIdentifiers.kitty]))
        #expect(resolved.bundlesWithTmuxSwitch == Set([OpenByPathBundleIdentifiers.kitty]))
        #expect(resolved.bundlesWithAuthoritativeRestore == Set([OpenByPathBundleIdentifiers.kitty]))
    }
}
