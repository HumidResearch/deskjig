//
//  TmuxIndexCoveragePlannerTests.swift
//  DeskJigSharedTests
//
//  Verifies tmux managed-index coverage planning in `RestorationPlanBuilder`.
//
//  These cases assert the planner's *current* contract, which evolved after the
//  suite was originally written:
//    - Geometry is injected via `withResolvedWindowTargets` (PR #457 / 7f75252);
//      without it every task short-circuits to `.failed` before the tmux planner
//      runs, so `tmuxManagedIndex` is never assigned. `resolvedTargets(for:)`
//      supplies it.
//    - Reuse requires *evidence* that a candidate window is a live tmux window:
//      an exact managed indexed title (authoritative identity written by
//      Bento's own launchers — trusted even without client-backing since #627),
//      or enough client-backed windows to cover the expected slot count. This
//      hardening (7cdcc12 "Fix duplicate terminal windows and cross-bundle
//      contamination", 4fb2f74 "Fix single-process terminal window detection")
//      prevents reusing stale/foreign windows and spawning duplicates.
//    - When a managed index is missing but the terminal-window count still
//      covers the slots, an unclaimed window is reused for the missing slot
//      instead of launching a new one (4a7eff8 "relax partial topology reuse",
//      which avoids launch storms when shell prompts overwrite managed titles).
//      Since #627 that fallback is title-aware: it will not consume the sole
//      remaining window carrying a higher, still-unassigned index's managed
//      title (surplus duplicates remain fair game).
//    - Without sufficient client-backing evidence, ambiguous (non-managed-title)
//      windows are NOT reused — the planner bootstraps to stay safe.
//

import Testing
import Foundation
import CoreGraphics
@testable import DeskJigShared

@Suite("Tmux Index Coverage Planner")
struct TmuxIndexCoveragePlannerTests {
    @Test("Duplicate managed index is reused for the missing slot instead of bootstrapping")
    @MainActor
    func duplicateManagedIndexReusedForMissingSlot() async {
        // Two iTerm windows both carry managed index 1 (a duplicate); index 0 is
        // missing. Because the window count (2) covers the expected slots (2) and
        // both are client-backed, the relaxed partial-topology policy reuses both
        // windows — one for its indexed slot, the extra duplicate for the missing
        // slot — rather than launching a new window.
        let workspace = Workspace(
            name: "tmux-plan",
            workspaceWindows: [
                makeTmuxWorkspaceWindow(bundleId: BundleRegistry.iterm2, path: "/tmp/a", session: "session_0"),
                makeTmuxWorkspaceWindow(bundleId: BundleRegistry.iterm2, path: "/tmp/b", session: "session_1")
            ]
        )

        let snapshot = makeEnhancedSnapshot(
            windows: [
                makeTerminalSnapshotWindow(
                    id: 201,
                    bundleId: BundleRegistry.iterm2,
                    title: BundleRegistry.managedTmuxWindowTitle(index: 1),
                    zOrder: 2
                ),
                makeTerminalSnapshotWindow(
                    id: 202,
                    bundleId: BundleRegistry.iterm2,
                    title: BundleRegistry.managedTmuxWindowTitle(index: 1),
                    zOrder: 5
                )
            ]
        )

        let plan = await plan(
            workspace: workspace,
            snapshot: snapshot,
            tmuxClientWindowMap: [9901: 201, 9902: 202]
        )
        let tasksByIndex = tasksByManagedIndex(plan)

        let index0 = tasksByIndex[0]?.decision
        let index1 = tasksByIndex[1]?.decision

        // Both slots reuse an existing window — no bootstrap, no orphan.
        #expect(switchedWindowId(from: index0) != nil)
        #expect(switchedWindowId(from: index1) != nil)
        #expect(!isOpenNewWithPath(index0))
        #expect(!isOpenNewWithPath(index1))
        // Both duplicate windows are consumed exactly once between the two slots.
        let reusedIds = Set([switchedWindowId(from: index0), switchedWindowId(from: index1)].compactMap { $0 })
        #expect(reusedIds == [201, 202])
    }

    @Test("Present managed index is reused and a genuinely missing index bootstraps")
    @MainActor
    func presentIndexReusedMissingIndexBootstraps() async {
        // Ghostty slot 0 exists as a client-backed managed:0 window and is reused;
        // slot 1 has no window at all, so it bootstraps a new one.
        let workspace = Workspace(
            name: "tmux-plan-missing",
            workspaceWindows: [
                makeTmuxWorkspaceWindow(bundleId: BundleRegistry.ghostty, path: "/tmp/a", session: "session_0"),
                makeTmuxWorkspaceWindow(bundleId: BundleRegistry.ghostty, path: "/tmp/b", session: "session_1")
            ]
        )

        let snapshot = makeEnhancedSnapshot(
            windows: [
                makeTerminalSnapshotWindow(
                    id: 301,
                    bundleId: BundleRegistry.ghostty,
                    title: BundleRegistry.managedTmuxWindowTitle(index: 0),
                    zOrder: 1
                )
            ]
        )

        let plan = await plan(
            workspace: workspace,
            snapshot: snapshot,
            tmuxClientWindowMap: [9901: 301]
        )
        let tasksByIndex = tasksByManagedIndex(plan)

        #expect(switchedWindowId(from: tasksByIndex[0]?.decision) == 301)
        #expect(isOpenNewWithPath(tasksByIndex[1]?.decision))
    }

    @Test("Non-managed titles with full client-backing reuse windows deterministically")
    @MainActor
    func nonManagedTitlesWithFullBackingReuseWindows() async {
        // No managed titles (shell prompt/hostname titles), but both windows are
        // client-backed so coverage is satisfied. The topology-unavailable reuse
        // path assigns windows deterministically by z-order (lowest first).
        let workspace = Workspace(
            name: "tmux-plan-unindexed",
            workspaceWindows: [
                makeTmuxWorkspaceWindow(bundleId: BundleRegistry.iterm2, path: "/tmp/a", session: "session_0"),
                makeTmuxWorkspaceWindow(bundleId: BundleRegistry.iterm2, path: "/tmp/b", session: "session_1")
            ]
        )

        let snapshot = makeEnhancedSnapshot(
            windows: [
                makeTerminalSnapshotWindow(
                    id: 601,
                    bundleId: BundleRegistry.iterm2,
                    title: "syn-172-100-002-067.res.spectrum.com",
                    zOrder: 4
                ),
                makeTerminalSnapshotWindow(
                    id: 602,
                    bundleId: BundleRegistry.iterm2,
                    title: "syn-172-100-002-067.res.spectrum.com",
                    zOrder: 2
                )
            ]
        )

        let plan = await plan(
            workspace: workspace,
            snapshot: snapshot,
            tmuxClientWindowMap: [42: 602, 43: 601]
        )
        let tasksByIndex = tasksByManagedIndex(plan)

        // Lowest z-order (602) claims slot 0, the next (601) claims slot 1.
        #expect(switchedWindowId(from: tasksByIndex[0]?.decision) == 602)
        #expect(switchedWindowId(from: tasksByIndex[1]?.decision) == 601)
        #expect(!isOpenNewWithPath(tasksByIndex[0]?.decision))
        #expect(!isOpenNewWithPath(tasksByIndex[1]?.decision))
    }

    @Test("AX-inaccessible windows with full client-backing are still reused")
    @MainActor
    func axInaccessibleWindowsWithFullBackingReuse() async {
        // Both windows report AX-inaccessible but are client-backed. Client
        // backing is sufficient evidence, so both are reused rather than
        // bootstrapped even though AX inspection is unavailable.
        let workspace = Workspace(
            name: "tmux-plan-unindexed-non-ax",
            workspaceWindows: [
                makeTmuxWorkspaceWindow(bundleId: BundleRegistry.iterm2, path: "/tmp/a", session: "session_0"),
                makeTmuxWorkspaceWindow(bundleId: BundleRegistry.iterm2, path: "/tmp/b", session: "session_1")
            ]
        )

        let snapshot = makeEnhancedSnapshot(
            windows: [
                makeTerminalSnapshotWindow(
                    id: 701,
                    bundleId: BundleRegistry.iterm2,
                    title: "host-a.local",
                    zOrder: 3,
                    isAXAccessible: false
                ),
                makeTerminalSnapshotWindow(
                    id: 702,
                    bundleId: BundleRegistry.iterm2,
                    title: "host-a.local",
                    zOrder: 5,
                    isAXAccessible: false
                )
            ]
        )

        let plan = await plan(
            workspace: workspace,
            snapshot: snapshot,
            tmuxClientWindowMap: [55: 702, 56: 701]
        )
        let tasksByIndex = tasksByManagedIndex(plan)

        // Both windows are reused (no bootstrap); each slot gets a distinct window.
        let index0Id = switchedWindowId(from: tasksByIndex[0]?.decision)
        let index1Id = switchedWindowId(from: tasksByIndex[1]?.decision)
        #expect(index0Id != nil)
        #expect(index1Id != nil)
        #expect(index0Id != index1Id)
        #expect(Set([index0Id, index1Id].compactMap { $0 }) == [701, 702])
        #expect(!isOpenNewWithPath(tasksByIndex[0]?.decision))
        #expect(!isOpenNewWithPath(tasksByIndex[1]?.decision))
    }

    @Test("Non-managed titles without client-backing bootstrap rather than reuse")
    @MainActor
    func nonManagedTitlesWithoutBackingBootstrap() async {
        // Ambiguous hostname-titled windows with NO client-backing evidence: the
        // planner cannot confirm these are the right tmux windows, so it
        // bootstraps both slots instead of risking reuse of stale/foreign windows.
        let workspace = Workspace(
            name: "tmux-plan-unindexed-unbacked",
            workspaceWindows: [
                makeTmuxWorkspaceWindow(bundleId: BundleRegistry.iterm2, path: "/tmp/a", session: "session_0"),
                makeTmuxWorkspaceWindow(bundleId: BundleRegistry.iterm2, path: "/tmp/b", session: "session_1")
            ]
        )

        let snapshot = makeEnhancedSnapshot(
            windows: [
                makeTerminalSnapshotWindow(
                    id: 801,
                    bundleId: BundleRegistry.iterm2,
                    title: "host-b.local",
                    zOrder: 4,
                    isAXAccessible: false
                ),
                makeTerminalSnapshotWindow(
                    id: 802,
                    bundleId: BundleRegistry.iterm2,
                    title: "host-b.local",
                    zOrder: 2,
                    isAXAccessible: true
                )
            ]
        )

        let plan = await plan(
            workspace: workspace,
            snapshot: snapshot,
            tmuxClientWindowMap: [:]
        )
        let tasksByIndex = tasksByManagedIndex(plan)

        #expect(isOpenNewWithPath(tasksByIndex[0]?.decision))
        #expect(isOpenNewWithPath(tasksByIndex[1]?.decision))
    }

    @Test("Partial client-backing insufficient for coverage bootstraps missing slots")
    @MainActor
    func partialClientBackingBootstrapsMissingSlots() async {
        // Only one of two expected windows is client-backed and there are no
        // managed titles, so coverage is not satisfied. Neither slot has enough
        // evidence to reuse, so both bootstrap.
        let workspace = Workspace(
            name: "tmux-plan-underprovisioned",
            workspaceWindows: [
                makeTmuxWorkspaceWindow(bundleId: BundleRegistry.kitty, path: "/tmp/a", session: "session_0"),
                makeTmuxWorkspaceWindow(bundleId: BundleRegistry.kitty, path: "/tmp/b", session: "session_1")
            ]
        )

        let snapshot = makeEnhancedSnapshot(
            windows: [
                makeTerminalSnapshotWindow(
                    id: 901,
                    bundleId: BundleRegistry.kitty,
                    title: "host-c.local",
                    zOrder: 3
                ),
                makeTerminalSnapshotWindow(
                    id: 902,
                    bundleId: BundleRegistry.kitty,
                    title: "host-c.local",
                    zOrder: 1
                )
            ]
        )

        let plan = await plan(
            workspace: workspace,
            snapshot: snapshot,
            tmuxClientWindowMap: [77: 902]
        )
        let tasksByIndex = tasksByManagedIndex(plan)

        #expect(isOpenNewWithPath(tasksByIndex[0]?.decision))
        #expect(isOpenNewWithPath(tasksByIndex[1]?.decision))
    }

    @Test("Managed indexed titles without client-backing are reused; only the truly missing index bootstraps")
    @MainActor
    func managedTitlesWithoutBackingReusedOnlyMissingIndexBootstraps() async {
        // The exact repro from #627: Ghostty expects indices {0,1,2}, the
        // snapshot has managed:0 and managed:2 windows, and there is NO live
        // tmux client backing (the old clients died / the windows are from a
        // previous workspace). Managed titles are authoritative, so managed:0
        // is reused for slot 0 and managed:2 for slot 2; only slot 1 (no
        // window at all) bootstraps. Before #627 the planner bootstrapped
        // slot 0 (indexed match untrusted without backing on non-Terminal.app
        // bundles) and the title-blind partial fallback let slot 1 steal the
        // managed:2 window — orphaning it and launching a duplicate.
        let workspace = Workspace(
            name: "tmux-plan-unbacked-managed",
            workspaceWindows: [
                makeTmuxWorkspaceWindow(bundleId: BundleRegistry.ghostty, path: "/tmp/a", session: "session_0"),
                makeTmuxWorkspaceWindow(bundleId: BundleRegistry.ghostty, path: "/tmp/b", session: "session_1"),
                makeTmuxWorkspaceWindow(bundleId: BundleRegistry.ghostty, path: "/tmp/c", session: "session_2")
            ]
        )

        let snapshot = makeEnhancedSnapshot(
            windows: [
                makeTerminalSnapshotWindow(
                    id: 1001,
                    bundleId: BundleRegistry.ghostty,
                    title: BundleRegistry.managedTmuxWindowTitle(index: 0),
                    zOrder: 1
                ),
                makeTerminalSnapshotWindow(
                    id: 1003,
                    bundleId: BundleRegistry.ghostty,
                    title: BundleRegistry.managedTmuxWindowTitle(index: 2),
                    zOrder: 3
                )
            ]
        )

        let plan = await plan(
            workspace: workspace,
            snapshot: snapshot,
            tmuxClientWindowMap: [:]
        )
        let tasksByIndex = tasksByManagedIndex(plan)

        // Each managed window is reused for its own indexed slot.
        #expect(switchedWindowId(from: tasksByIndex[0]?.decision) == 1001)
        #expect(switchedWindowId(from: tasksByIndex[2]?.decision) == 1003)
        // Only the genuinely absent index bootstraps.
        #expect(isOpenNewWithPath(tasksByIndex[1]?.decision))
        #expect(!isOpenNewWithPath(tasksByIndex[0]?.decision))
        #expect(!isOpenNewWithPath(tasksByIndex[2]?.decision))
    }

    @Test("Partial fallback reuses an un-titled window instead of stealing a foreign managed index")
    @MainActor
    func partialFallbackDoesNotStealForeignManagedWindow() async {
        // iTerm expects {0,1}. The snapshot has a managed:1 window (frontmost,
        // so a title-blind fallback would pick it first) and a hostname-titled
        // window whose shell prompt overwrote the managed title. Slot 0's
        // partial fallback must reuse the un-titled window and leave managed:1
        // for slot 1's exact-match path. Before #627 slot 0 stole the
        // managed:1 window, forcing slot 1 to bootstrap a duplicate.
        let workspace = Workspace(
            name: "tmux-plan-foreign-steal",
            workspaceWindows: [
                makeTmuxWorkspaceWindow(bundleId: BundleRegistry.iterm2, path: "/tmp/a", session: "session_0"),
                makeTmuxWorkspaceWindow(bundleId: BundleRegistry.iterm2, path: "/tmp/b", session: "session_1")
            ]
        )

        let snapshot = makeEnhancedSnapshot(
            windows: [
                makeTerminalSnapshotWindow(
                    id: 1102,
                    bundleId: BundleRegistry.iterm2,
                    title: BundleRegistry.managedTmuxWindowTitle(index: 1),
                    zOrder: 1
                ),
                makeTerminalSnapshotWindow(
                    id: 1101,
                    bundleId: BundleRegistry.iterm2,
                    title: "host-d.local",
                    zOrder: 4
                )
            ]
        )

        let plan = await plan(
            workspace: workspace,
            snapshot: snapshot,
            tmuxClientWindowMap: [:]
        )
        let tasksByIndex = tasksByManagedIndex(plan)

        // Slot 0 falls back to the genuinely un-titled window; slot 1 keeps
        // its own managed window. No bootstrap, no orphan.
        #expect(switchedWindowId(from: tasksByIndex[0]?.decision) == 1101)
        #expect(switchedWindowId(from: tasksByIndex[1]?.decision) == 1102)
        #expect(!isOpenNewWithPath(tasksByIndex[0]?.decision))
        #expect(!isOpenNewWithPath(tasksByIndex[1]?.decision))
    }

    @Test("Index topology is enforced independently per terminal bundle")
    @MainActor
    func enforcesPerBundleIndependently() async {
        // iTerm has a duplicate managed:1 with index 0 missing (reused via the
        // relaxed fallback), while Ghostty has clean managed:0 and managed:1
        // windows (each reused for its own indexed slot). The two bundles are
        // planned independently.
        let workspace = Workspace(
            name: "tmux-plan-cross-bundle",
            workspaceWindows: [
                makeTmuxWorkspaceWindow(bundleId: BundleRegistry.iterm2, path: "/tmp/a", session: "iterm_0"),
                makeTmuxWorkspaceWindow(bundleId: BundleRegistry.iterm2, path: "/tmp/b", session: "iterm_1"),
                makeTmuxWorkspaceWindow(bundleId: BundleRegistry.ghostty, path: "/tmp/c", session: "ghostty_0"),
                makeTmuxWorkspaceWindow(bundleId: BundleRegistry.ghostty, path: "/tmp/d", session: "ghostty_1")
            ]
        )

        let snapshot = makeEnhancedSnapshot(
            windows: [
                makeTerminalSnapshotWindow(
                    id: 401,
                    bundleId: BundleRegistry.iterm2,
                    title: BundleRegistry.managedTmuxWindowTitle(index: 1),
                    zOrder: 2
                ),
                makeTerminalSnapshotWindow(
                    id: 402,
                    bundleId: BundleRegistry.iterm2,
                    title: BundleRegistry.managedTmuxWindowTitle(index: 1),
                    zOrder: 3
                ),
                makeTerminalSnapshotWindow(
                    id: 501,
                    bundleId: BundleRegistry.ghostty,
                    title: BundleRegistry.managedTmuxWindowTitle(index: 0),
                    zOrder: 1
                ),
                makeTerminalSnapshotWindow(
                    id: 502,
                    bundleId: BundleRegistry.ghostty,
                    title: BundleRegistry.managedTmuxWindowTitle(index: 1),
                    zOrder: 2
                )
            ]
        )

        let plan = await plan(
            workspace: workspace,
            snapshot: snapshot,
            tmuxClientWindowMap: [9901: 401, 9902: 402, 9903: 501, 9904: 502]
        )

        let itermTasks = plan.tasks.filter { $0.workspaceWindow.bundleIdentifier == BundleRegistry.iterm2 }
        let ghosttyTasks = plan.tasks.filter { $0.workspaceWindow.bundleIdentifier == BundleRegistry.ghostty }

        let itermByIndex = Dictionary(uniqueKeysWithValues: itermTasks.compactMap { task in
            task.tmuxManagedIndex.map { ($0, task) }
        })
        let ghosttyByIndex = Dictionary(uniqueKeysWithValues: ghosttyTasks.compactMap { task in
            task.tmuxManagedIndex.map { ($0, task) }
        })

        // iTerm: both duplicate windows reused across the two slots (no bootstrap).
        let itermReused = Set([
            switchedWindowId(from: itermByIndex[0]?.decision),
            switchedWindowId(from: itermByIndex[1]?.decision)
        ].compactMap { $0 })
        #expect(itermReused == [401, 402])
        #expect(!isOpenNewWithPath(itermByIndex[0]?.decision))
        #expect(!isOpenNewWithPath(itermByIndex[1]?.decision))

        // Ghostty: each managed index is reused by its own titled, client-backed window.
        #expect(switchedWindowId(from: ghosttyByIndex[0]?.decision) == 501)
        #expect(switchedWindowId(from: ghosttyByIndex[1]?.decision) == 502)

        // Ensures test fails loudly if expected per-bundle index assignment disappeared.
        #expect(itermByIndex.keys.sorted() == [0, 1])
        #expect(ghosttyByIndex.keys.sorted() == [0, 1])
    }

    // MARK: - Helpers

    /// Runs the tmux index-coverage planner for a workspace/snapshot pair.
    private func plan(
        workspace: Workspace,
        snapshot: EnhancedSnapshot,
        tmuxClientWindowMap: [pid_t: CGWindowID]
    ) async -> RestorationPlan {
        await RestorationPlanBuilder(runId: "tmux_test")
            .forWorkspace(workspace)
            .withSnapshot(snapshot)
            .withCurrentScreens([])
            .withResolvedWindowTargets(resolvedTargets(for: workspace))
            .withTmuxSessionManager(TmuxSessionManager())
            .withTmuxClientWindowMap(tmuxClientWindowMap)
            .analyze()
            .build()
    }

    private func tasksByManagedIndex(_ plan: RestorationPlan) -> [Int: RestorationTask] {
        Dictionary(
            uniqueKeysWithValues: plan.tasks.compactMap { task in
                task.tmuxManagedIndex.map { ($0, task) }
            }
        )
    }

    /// Builds resolved target geometry for every window in the workspace.
    ///
    /// Since PR #457 ("Redesign workspace layout editor", 7f75252),
    /// `RestorationPlanBuilder` no longer computes target frames internally from
    /// `withCurrentScreens`; callers must inject resolved geometry via
    /// `withResolvedWindowTargets`. Without it every task short-circuits to
    /// `.failed("Missing resolved target geometry")` before the tmux planner
    /// runs, so `tmuxManagedIndex` is never assigned. These planner tests only
    /// care about the tmux index-coverage decisions, so a uniform frame is enough.
    private func resolvedTargets(for workspace: Workspace) -> [UUID: ResolvedWorkspaceWindowTarget] {
        Dictionary(uniqueKeysWithValues: workspace.windows.map { window in
            (window.id, ResolvedWorkspaceWindowTarget(
                windowID: window.id,
                slotID: window.id,
                displayID: 0,
                targetScreenIndex: 0,
                targetFrame: CGRect(x: 100, y: 100, width: 900, height: 600)
            ))
        })
    }

    private func makeEnhancedSnapshot(windows: [SnapshotWindow]) -> EnhancedSnapshot {
        let snapshot = SystemSnapshot(
            captureTime: Date(),
            captureDurationMs: 0,
            runId: "tmux_test",
            displays: [],
            windows: windows
        )
        return EnhancedSnapshot.from(snapshot)
    }

    private func makeTmuxWorkspaceWindow(bundleId: String, path: String, session: String) -> WorkspaceWindow {
        WorkspaceWindow(
            bundleIdentifier: bundleId,
            appName: "Terminal",
            windowTitle: "tmux",
            openPath: path,
            tmuxState: TmuxSessionState(
                sessionName: session,
                initialWorkingDirectory: path
            )
        )
    }

    private func makeTerminalSnapshotWindow(
        id: CGWindowID,
        bundleId: String,
        title: String,
        zOrder: Int,
        isAXAccessible: Bool? = true
    ) -> SnapshotWindow {
        SnapshotWindow(
            windowId: id,
            pid: pid_t(1000 + Int32(truncatingIfNeeded: id)),
            bundleId: bundleId,
            appName: "Terminal",
            title: title,
            frame: CGRect(x: 100, y: 100, width: 900, height: 600),
            layer: 0,
            isOnScreen: true,
            zOrderIndex: zOrder,
            isAXAccessible: isAXAccessible
        )
    }

    private func isOpenNewWithPath(_ decision: RestorationDecision?) -> Bool {
        guard let decision else { return false }
        if case .openNewWithPath = decision {
            return true
        }
        return false
    }

    private func switchedWindowId(from decision: RestorationDecision?) -> CGWindowID? {
        guard let decision else { return nil }
        if case .switchTmuxSession(let windowId, _, _) = decision {
            return windowId
        }
        return nil
    }
}
