//  FluentXcodeLauncherMatcherTests.swift
//  DeskJigSharedTests

import Testing
import Foundation
import CoreGraphics
@testable import DeskJigShared

// CLI lane (old BentoTests-CLI.xctestplan): isolation-sensitive, run serially.
@Suite(.serialized)
struct FluentXcodeLauncherMatcherTests {
    private let launcher = FluentXcodeLauncher()
    private let bundleId = OpenByPathBundleIdentifiers.xcode

    @Test("Xcode matcher rejects title fallback when document path points outside target directory")
    func rejectsCrossDirectoryTitleFallback() {
        let targetDirectory = "/Users/andrewarmenante/.codex/worktrees/52c3/deskjig"
        let rootDocPath = "/Users/andrewarmenante/code/deskjig/DeskJig/UI/DesignSystem/DSWindowDragControl.swift"
        let snapshot = makeSnapshot(
            windows: [
                makeXcodeWindow(
                    id: 26616,
                    title: "DeskJig — DSWindowDragControl.swift",
                    documentPath: rootDocPath
                )
            ]
        )

        let match = launcher.matchWindow(
            in: snapshot,
            directory: targetDirectory,
            title: nil,
            task: makeTaskContext(taskId: "reject-cross-directory"),
            trustDeskJigTitle: false
        )

        #expect(match == nil)
    }

    @Test("Xcode matcher treats files inside target directory as documentPath matches")
    func matchesDocumentPathForNestedFiles() {
        let targetDirectory = "/Users/andrewarmenante/.codex/worktrees/52c3/deskjig"
        let nestedFilePath = "/Users/andrewarmenante/.codex/worktrees/52c3/deskjig/DeskJig/UI/DesignSystem/DSWindowDragControl.swift"
        let snapshot = makeSnapshot(
            windows: [
                makeXcodeWindow(
                    id: 26616,
                    title: "DeskJig — DSWindowDragControl.swift",
                    documentPath: nestedFilePath
                )
            ]
        )

        let match = launcher.matchWindow(
            in: snapshot,
            directory: targetDirectory,
            title: nil,
            task: makeTaskContext(taskId: "nested-file-match"),
            trustDeskJigTitle: false
        )

        #expect(match?.window.windowId == 26616)
        #expect(match?.method == .documentPath)
        #expect(match?.confidence == .exact)
    }

    @Test("Xcode matcher may use title fallback when document path is unavailable")
    func allowsTitleFallbackWithoutDocPath() {
        let targetDirectory = "/Users/andrewarmenante/.codex/worktrees/52c3/deskjig"
        let snapshot = makeSnapshot(
            windows: [
                makeXcodeWindow(
                    id: 26616,
                    title: "DeskJig — DSWindowDragControl.swift",
                    documentPath: nil
                )
            ]
        )

        let match = launcher.matchWindow(
            in: snapshot,
            directory: targetDirectory,
            title: nil,
            task: makeTaskContext(taskId: "nil-doc-title-fallback"),
            trustDeskJigTitle: false
        )

        #expect(match?.window.windowId == 26616)
        #expect(match?.method == .titlePattern)
        #expect(match?.confidence == .high)
    }

    @Test("Multiple same-title Xcode windows with unknown docs does not title-match")
    func rejectsAmbiguousSameTitleWithoutDocumentPath() {
        let targetDirectory = "/Users/andrewarmenante/.codex/worktrees/52c3/deskjig"
        let snapshot = makeSnapshot(
            windows: [
                makeXcodeWindow(
                    id: 26616,
                    title: "DeskJig — DSWindowDragControl.swift",
                    documentPath: nil
                ),
                makeXcodeWindow(
                    id: 26617,
                    title: "DeskJig — DSWindowDragControl.swift",
                    documentPath: nil
                )
            ]
        )

        let match = launcher.matchWindow(
            in: snapshot,
            directory: targetDirectory,
            title: nil,
            task: makeTaskContext(taskId: "ambiguous-same-title"),
            trustDeskJigTitle: false
        )

        #expect(match == nil)
    }

    @Test("Xcode matcher returns nil on path-strict loose-title ambiguity")
    func rejectsAmbiguousLooseTitleFallback() {
        let targetDirectory = "/Users/andrewarmenante/.codex/worktrees/52c3/deskjig"
        let snapshot = makeSnapshot(
            windows: [
                makeXcodeWindow(
                    id: 26616,
                    title: "Feature: deskjig refactor",
                    documentPath: nil
                ),
                makeXcodeWindow(
                    id: 26617,
                    title: "Bugfix in deskjig helper",
                    documentPath: nil
                )
            ]
        )

        let match = launcher.matchWindow(
            in: snapshot,
            directory: targetDirectory,
            title: nil,
            task: makeTaskContext(taskId: "ambiguous-loose-title"),
            trustDeskJigTitle: false
        )

        #expect(match == nil)
    }

    @Test("Path-strict still prefers exact document path when titles are ambiguous")
    func prefersExactDocumentPathOverAmbiguousTitles() {
        let targetDirectory = "/Users/andrewarmenante/.codex/worktrees/52c3/deskjig"
        let exactPath = "/Users/andrewarmenante/.codex/worktrees/52c3/deskjig/DeskJig.xcodeproj"
        let snapshot = makeSnapshot(
            windows: [
                makeXcodeWindow(
                    id: 26616,
                    title: "deskjig helper notes",
                    documentPath: nil
                ),
                makeXcodeWindow(
                    id: 26617,
                    title: "deskjig quick switch",
                    documentPath: exactPath
                )
            ]
        )

        let match = launcher.matchWindow(
            in: snapshot,
            directory: targetDirectory,
            title: nil,
            task: makeTaskContext(taskId: "exact-path-preferred"),
            trustDeskJigTitle: false
        )

        #expect(match?.window.windowId == 26617)
        #expect(match?.method == .documentPath)
        #expect(match?.confidence == .exact)
    }

    private func makeTaskContext(taskId: String) -> RestorationTaskContext {
        RestorationTaskContext(
            taskId: taskId,
            taskType: .ide,
            runId: "test-run"
        )
    }

    private func makeSnapshot(windows: [SnapshotWindow]) -> SystemSnapshot {
        SystemSnapshot(
            captureTime: Date(),
            captureDurationMs: 0,
            runId: "test-run",
            displays: [],
            windows: windows
        )
    }

    private func makeXcodeWindow(
        id: CGWindowID,
        title: String,
        documentPath: String?
    ) -> SnapshotWindow {
        SnapshotWindow(
            windowId: id,
            pid: 6916,
            bundleId: bundleId,
            appName: "Xcode",
            title: title,
            frame: CGRect(x: 980, y: 30, width: 940, height: 1050),
            layer: 0,
            isOnScreen: true,
            documentPath: documentPath
        )
    }
}
