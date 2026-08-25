//
//  XcodeCoverageTopologyTests.swift
//  DeskJigSharedTests
//
//  Verifies deterministic Xcode path-slot coverage calculations.
//

import Testing
import Foundation
import CoreGraphics
@testable import DeskJigShared

@Suite("Xcode Coverage Topology")
struct XcodeCoverageTopologyTests {
    @Test("Missing root slot with duplicate worktree slot is detected")
    func detectsMissingAndDuplicatePathSlots() {
        let rootPath = "/Users/testuser/code/acme"
        let worktreePath = "/Users/testuser/.codex/worktrees/ab12/acme"
        let topology = XcodeWindowCoverageTopology(
            expectedPathSlots: [rootPath, worktreePath],
            observedPathSlots: [worktreePath, worktreePath]
        )

        #expect(topology.isComplete == false)
        #expect(topology.missingPathSlots == [rootPath])
        #expect(topology.duplicatePathSlots == [worktreePath])
    }

    @Test("Topology ignores unresolved Xcode document paths for coverage")
    func unresolvedPathsDoNotCountAsCoverage() {
        let rootPath = "/Users/testuser/code/acme"
        let worktreePath = "/Users/testuser/.codex/worktrees/ab12/acme"
        let workspaceWindows = [
            makeWorkspaceWindow(path: rootPath),
            makeWorkspaceWindow(path: worktreePath)
        ]
        let snapshot = SystemSnapshot(
            captureTime: Date(),
            captureDurationMs: 0,
            runId: "xcode-topology-test",
            displays: [],
            windows: [
                makeSnapshotWindow(id: 1001, docPath: "\(rootPath)/Nexus.xcworkspace"),
                makeSnapshotWindow(id: 1002, docPath: nil)
            ]
        )

        let service = WorkspaceZOrderService(displayManager: DisplayManager())
        let topology = service.xcodeCoverageTopology(
            workspaceWindows: workspaceWindows,
            snapshot: snapshot
        )

        #expect(topology != nil)
        #expect(topology?.isComplete == false)
        #expect(topology?.missingPathSlots == [worktreePath])
        #expect(topology?.duplicatePathSlots.isEmpty == true)
    }

    private func makeWorkspaceWindow(path: String) -> WorkspaceWindow {
        WorkspaceWindow(
            bundleIdentifier: OpenByPathBundleIdentifiers.xcode,
            appName: "Xcode",
            windowTitle: "Nexus",
            openPath: path
        )
    }

    private func makeSnapshotWindow(id: CGWindowID, docPath: String?) -> SnapshotWindow {
        SnapshotWindow(
            windowId: id,
            pid: pid_t(9000 + Int32(id)),
            bundleId: OpenByPathBundleIdentifiers.xcode,
            appName: "Xcode",
            title: "Nexus — Nexus.xcworkspace",
            frame: CGRect(x: 980, y: 25, width: 940, height: 1055),
            layer: 0,
            isOnScreen: true,
            documentPath: docPath,
            ideDocumentPath: docPath,
            isAXAccessible: true
        )
    }
}
