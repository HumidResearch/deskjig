//  SingleProcessTerminalWindowResolverTests.swift
//  DeskJigSharedTests

import Testing
import CoreGraphics
@testable import DeskJigShared

@Suite("Single-process terminal window resolver")
struct SingleProcessTerminalWindowResolverTests {

    @Test("Decorated Terminal title exposes the managed tmux index")
    func decoratedTerminalTitleParsesManagedIndex() {
        let title = "brutus — bento:tmux:managed:terminal:1 — /Users/brutus/code/deskjig"
        #expect(ManagedTmuxWindowTitleMatcher.managedIndex(from: title) == 1)
        #expect(
            ManagedTmuxWindowTitleMatcher.matchesManagedIndex(
                title,
                bundleId: BundleRegistry.terminal,
                index: 1
            )
        )
    }

    @Test("Resolver prefers the new titled window over a pre-launch blank Terminal window")
    func resolverPrefersNewTitledWindow() {
        let attempt = SingleProcessTerminalWindowResolver.resolve(
            bundleId: BundleRegistry.terminal,
            expectedIndexedTitle: BundleRegistry.managedTmuxWindowTitle(bundleId: BundleRegistry.terminal, index: 1),
            bundleWindows: [
                makeSnapshotWindow(
                    id: 36003,
                    pid: 900,
                    title: "-zsh",
                    frame: CGRect(x: 1920, y: 30, width: 900, height: 700)
                ),
                makeSnapshotWindow(
                    id: 36020,
                    pid: 900,
                    title: nil,
                    frame: CGRect(x: 29, y: 59, width: 900, height: 700)
                )
            ],
            preLaunchBundleWindowIds: [36003],
            claimedWindowIds: [],
            targetFrame: CGRect(x: 1920, y: 30, width: 900, height: 700),
            axCandidates: [
                .init(
                    windowId: 36003,
                    frame: CGRect(x: 1920, y: 30, width: 900, height: 700),
                    title: "-zsh",
                    pid: 900
                ),
                .init(
                    windowId: 36020,
                    frame: CGRect(x: 29, y: 59, width: 900, height: 700),
                    title: "brutus — bento:tmux:managed:terminal:1 — /Users/brutus/code/deskjig",
                    pid: 900
                )
            ]
        )

        #expect(attempt.resolution?.window.windowId == 36020)
        #expect(attempt.resolution?.evidence == .axManagedTitle)
    }

    @Test("Resolver rejects title-less candidates instead of falling back to PID")
    func resolverRejectsTitleLessCandidates() {
        let attempt = SingleProcessTerminalWindowResolver.resolve(
            bundleId: BundleRegistry.terminal,
            expectedIndexedTitle: BundleRegistry.managedTmuxWindowTitle(bundleId: BundleRegistry.terminal, index: 0),
            bundleWindows: [
                makeSnapshotWindow(
                    id: 100,
                    pid: 500,
                    title: "-zsh",
                    frame: CGRect(x: 0, y: 30, width: 800, height: 600)
                ),
                makeSnapshotWindow(
                    id: 101,
                    pid: 500,
                    title: nil,
                    frame: CGRect(x: 1920, y: 30, width: 800, height: 600)
                )
            ],
            preLaunchBundleWindowIds: [100],
            claimedWindowIds: [],
            axCandidates: [
                .init(windowId: 100, frame: CGRect(x: 0, y: 30, width: 800, height: 600), title: "-zsh", pid: 500),
                .init(windowId: 101, frame: CGRect(x: 1920, y: 30, width: 800, height: 600), title: nil, pid: 500)
            ]
        )

        #expect(attempt.resolution == nil)
        #expect(attempt.rejectionReason == "no-title-match")
    }

    @Test("Resolver rejects ambiguous titled candidates")
    func resolverRejectsAmbiguousCandidates() {
        let expectedTitle = BundleRegistry.managedTmuxWindowTitle(bundleId: BundleRegistry.terminal, index: 0)
        let attempt = SingleProcessTerminalWindowResolver.resolve(
            bundleId: BundleRegistry.terminal,
            expectedIndexedTitle: expectedTitle,
            bundleWindows: [
                makeSnapshotWindow(
                    id: 201,
                    pid: 700,
                    title: nil,
                    frame: CGRect(x: 0, y: 30, width: 800, height: 600)
                ),
                makeSnapshotWindow(
                    id: 202,
                    pid: 700,
                    title: nil,
                    frame: CGRect(x: 1920, y: 30, width: 800, height: 600)
                )
            ],
            preLaunchBundleWindowIds: [],
            claimedWindowIds: [],
            axCandidates: [
                .init(windowId: 201, frame: CGRect(x: 0, y: 30, width: 800, height: 600), title: expectedTitle, pid: 700),
                .init(windowId: 202, frame: CGRect(x: 1920, y: 30, width: 800, height: 600), title: "brutus — \(expectedTitle) — /tmp", pid: 700)
            ]
        )

        #expect(attempt.resolution == nil)
        #expect(attempt.rejectionReason == "ambiguous-new-window-match" || attempt.rejectionReason == "ambiguous-window-match")
    }

    @Test("Resolver falls back to frame correlation when AX window number is unavailable")
    func resolverFallsBackToFrameCorrelation() {
        let attempt = SingleProcessTerminalWindowResolver.resolve(
            bundleId: BundleRegistry.terminal,
            expectedIndexedTitle: BundleRegistry.managedTmuxWindowTitle(bundleId: BundleRegistry.terminal, index: 2),
            bundleWindows: [
                makeSnapshotWindow(
                    id: 301,
                    pid: 800,
                    title: nil,
                    frame: CGRect(x: 1920, y: 30, width: 1100, height: 700)
                )
            ],
            preLaunchBundleWindowIds: [],
            claimedWindowIds: [],
            axCandidates: [
                .init(
                    windowId: nil,
                    frame: CGRect(x: 1921, y: 31, width: 1100, height: 700),
                    title: "brutus — bento:tmux:managed:terminal:2 — /tmp",
                    pid: 800
                )
            ]
        )

        #expect(attempt.resolution?.window.windowId == 301)
        #expect(attempt.resolution?.evidence == .prePostLaunchBundleDiff)
    }

    private func makeSnapshotWindow(
        id: CGWindowID,
        pid: pid_t,
        title: String?,
        frame: CGRect
    ) -> SnapshotWindow {
        SnapshotWindow(
            windowId: id,
            pid: pid,
            bundleId: BundleRegistry.terminal,
            appName: "Terminal",
            title: title,
            frame: frame,
            layer: 0,
            isOnScreen: true,
            zOrderIndex: 0
        )
    }
}
