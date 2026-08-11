//
//  WorkspacePortabilityAnalyzerTests.swift
//  DeskJigSharedTests
//
//  GH #579: pre-restore workspace portability validation. Pins the report
//  findings (missing apps, missing directories, display-count mismatch) and
//  the deterministic degradation rules:
//
//  * Missing-app windows are skipped (with per-app counts), the rest restores.
//  * Missing directories are warn-only; windows are kept.
//  * Display mismatch: geometry-sorted slot i maps to geometry-sorted current
//    display i; windows on slots beyond the available displays are remapped to
//    the highest available slot. The produced explicit assignments make a
//    non-interactive restore preparation succeed (`.ready`) instead of failing
//    with `assignmentRequired` — a 2-display workspace on 1 display restores
//    deterministically.
//

import CoreGraphics
import Foundation
import Testing
@testable import DeskJigShared

struct WorkspacePortabilityAnalyzerTests {

    // MARK: - Mock checkers

    private struct MockAppChecker: PortabilityAppAvailabilityChecking {
        let installedBundleIDs: Set<String>

        func isAppAvailable(bundleIdentifier: String, applicationPath: String?) -> Bool {
            installedBundleIDs.contains(bundleIdentifier)
        }
    }

    private struct MockPathChecker: PortabilityPathChecking {
        let existingPaths: Set<String>

        func pathExists(_ path: String) -> Bool {
            existingPaths.contains(path)
        }
    }

    // MARK: - Helpers

    private func makeAnalyzer(
        installedBundleIDs: Set<String>,
        existingPaths: Set<String> = []
    ) -> WorkspacePortabilityAnalyzer {
        WorkspacePortabilityAnalyzer(
            appChecker: MockAppChecker(installedBundleIDs: installedBundleIDs),
            pathChecker: MockPathChecker(existingPaths: existingPaths)
        )
    }

    private func makeWindow(
        bundleIdentifier: String = "com.example.app",
        appName: String = "App",
        windowTitle: String = "Window",
        openPath: String? = nil,
        screenIndex: Int? = nil
    ) -> WorkspaceWindow {
        WorkspaceWindow(
            bundleIdentifier: bundleIdentifier,
            appName: appName,
            windowTitle: windowTitle,
            openPath: openPath,
            screenIndex: screenIndex,
            relativeFrame: RelativeWindowFrame(xPercent: 0, yPercent: 0, widthPercent: 0.5, heightPercent: 1)
        )
    }

    private func makeScreen(
        displayID: Int,
        originX: CGFloat = 0,
        isPrimary: Bool = false
    ) -> FullScreenInfo {
        let frame = CGRect(x: originX, y: 0, width: 1920, height: 1080)
        let provider = MockScreenProvider(
            frame: frame,
            visibleFrame: CGRect(x: originX, y: 0, width: 1920, height: 1050),
            backingScaleFactor: 2,
            isPrimary: isPrimary,
            displayID: displayID,
            displayName: "Display \(displayID)",
            vendorID: 4268,
            modelNumber: 16821,
            serialNumber: displayID * 111,
            displayUUID: "DISPLAY-\(displayID)"
        )
        return FullScreenInfo(screenProvider: provider)
    }

    /// A workspace saved on two side-by-side displays with one window on each.
    private func makeTwoDisplayWorkspace(
        leftBundle: String = "com.example.editor",
        rightBundle: String = "com.example.terminal",
        leftOpenPath: String? = nil
    ) -> Workspace {
        Workspace(
            name: "Two Display",
            workspaceWindows: [
                makeWindow(
                    bundleIdentifier: leftBundle,
                    appName: "Editor",
                    windowTitle: "Editor",
                    openPath: leftOpenPath,
                    screenIndex: 0
                ),
                makeWindow(
                    bundleIdentifier: rightBundle,
                    appName: "Terminal",
                    windowTitle: "Terminal",
                    screenIndex: 1
                )
            ],
            screens: [
                WorkspaceScreen(from: makeScreen(displayID: 7, originX: 0, isPrimary: true)),
                WorkspaceScreen(from: makeScreen(displayID: 9, originX: 1920))
            ]
        )
    }

    // MARK: - No findings

    @Test("A fully portable workspace reports no findings and is not degraded")
    func portableWorkspaceHasNoFindings() {
        let workspace = makeTwoDisplayWorkspace(leftOpenPath: "/tmp/project")
        let analyzer = makeAnalyzer(
            installedBundleIDs: ["com.example.editor", "com.example.terminal"],
            existingPaths: ["/tmp/project"]
        )
        let currentScreens = [
            makeScreen(displayID: 7, originX: 0, isPrimary: true),
            makeScreen(displayID: 9, originX: 1920)
        ]

        let report = analyzer.analyze(workspace: workspace, currentDisplayCount: currentScreens.count)

        #expect(!report.hasFindings)
        #expect(report.warnings.isEmpty)
        #expect(report.savedDisplayCount == 2)
        #expect(report.currentDisplayCount == 2)

        let degradation = analyzer.applyDegradations(
            to: workspace,
            currentScreens: currentScreens,
            report: report
        )
        #expect(degradation.workspace.windows.count == workspace.windows.count)
        #expect(degradation.skippedWindows.isEmpty)
        #expect(degradation.displayAssignments.isEmpty)
        #expect(degradation.remappedWindowCount == 0)
    }

    // MARK: - Missing apps

    @Test("Missing-app windows are reported per app and skipped by degradation")
    func missingAppWindowsAreReportedAndSkipped() {
        let workspace = Workspace(
            name: "Apps",
            workspaceWindows: [
                makeWindow(bundleIdentifier: "com.example.gone", appName: "Gone", screenIndex: 0),
                makeWindow(bundleIdentifier: "com.example.gone", appName: "Gone", windowTitle: "Second", screenIndex: 0),
                makeWindow(bundleIdentifier: "com.example.present", appName: "Present", screenIndex: 0)
            ],
            screens: [WorkspaceScreen(from: makeScreen(displayID: 7, isPrimary: true))]
        )
        let analyzer = makeAnalyzer(installedBundleIDs: ["com.example.present"])
        let currentScreens = [makeScreen(displayID: 7, isPrimary: true)]

        let report = analyzer.analyze(workspace: workspace, currentDisplayCount: 1)

        #expect(report.missingApps == [
            WorkspacePortabilityReport.MissingApp(
                bundleIdentifier: "com.example.gone",
                appName: "Gone",
                windowCount: 2
            )
        ])
        #expect(report.skippedWindowCount == 2)
        #expect(report.displayRemap == nil)
        #expect(report.warnings.contains { $0.contains("Gone") && $0.contains("will be skipped") })

        let degradation = analyzer.applyDegradations(
            to: workspace,
            currentScreens: currentScreens,
            report: report
        )
        #expect(degradation.skippedWindows.count == 2)
        #expect(degradation.workspace.windows.map(\.bundleIdentifier) == ["com.example.present"])
    }

    // MARK: - Missing directories

    @Test("Missing directories are warn-only: reported but windows are kept")
    func missingDirectoriesAreWarnOnly() {
        let workspace = Workspace(
            name: "Paths",
            workspaceWindows: [
                makeWindow(
                    bundleIdentifier: "com.example.editor",
                    appName: "Editor",
                    openPath: "/Users/gone/project",
                    screenIndex: 0
                )
            ],
            screens: [WorkspaceScreen(from: makeScreen(displayID: 7, isPrimary: true))]
        )
        let analyzer = makeAnalyzer(installedBundleIDs: ["com.example.editor"], existingPaths: [])
        let currentScreens = [makeScreen(displayID: 7, isPrimary: true)]

        let report = analyzer.analyze(workspace: workspace, currentDisplayCount: 1)

        #expect(report.missingPaths == [
            WorkspacePortabilityReport.MissingPath(
                path: "/Users/gone/project",
                appNames: ["Editor"],
                windowCount: 1
            )
        ])
        #expect(report.hasFindings)
        #expect(report.warnings.contains { $0.contains("/Users/gone/project") })

        let degradation = analyzer.applyDegradations(
            to: workspace,
            currentScreens: currentScreens,
            report: report
        )
        #expect(degradation.workspace.windows.count == 1)
        #expect(degradation.skippedWindows.isEmpty)
    }

    // MARK: - Display remap: 2 displays saved, 1 connected (GH #579 AC)

    @Test("Two-display workspace on one display remaps deterministically and prepares non-interactively")
    func twoDisplayWorkspaceOnOneDisplayDegradesDeterministically() throws {
        let workspace = makeTwoDisplayWorkspace()
        let analyzer = makeAnalyzer(installedBundleIDs: ["com.example.editor", "com.example.terminal"])
        let currentScreens = [makeScreen(displayID: 42, originX: 0, isPrimary: true)]

        let report = analyzer.analyze(workspace: workspace, currentDisplayCount: 1)

        #expect(report.displayRemap == WorkspacePortabilityReport.DisplayRemap(
            savedDisplayCount: 2,
            currentDisplayCount: 1,
            remappedWindowCount: 1
        ))
        #expect(report.warnings.contains { $0.contains("only 1 connected") })

        let degradation = analyzer.applyDegradations(
            to: workspace,
            currentScreens: currentScreens,
            report: report
        )

        // Every window lands on the single remaining display slot.
        #expect(degradation.remappedWindowCount == 1)
        #expect(degradation.workspace.windows.map(\.screenIndex) == [0, 0])
        let slots = try #require(degradation.workspace.displaySlots)
        // Slots are preserved in full so the saved 2-display layout is never
        // flattened on disk by a degraded restore.
        #expect(slots.count == 2)
        #expect(degradation.workspace.windows.allSatisfy { $0.displaySlotID == slots[0].id })

        // Deterministic slot→display assignment: sorted slot 0 → sorted display 0.
        #expect(degradation.displayAssignments == [
            WorkspaceDisplayAssignment(slotID: slots[0].id, displayID: 42)
        ])

        // Degradation is a pure function of its inputs: a second run produces
        // the identical window mapping and assignments. (`updatedAt` is
        // refreshed on copy, so compare the restore-relevant projections.)
        let secondRun = analyzer.applyDegradations(
            to: workspace,
            currentScreens: currentScreens,
            report: report
        )
        #expect(
            secondRun.workspace.windows.map { [$0.id.uuidString, "\($0.screenIndex ?? -1)", $0.displaySlotID?.uuidString ?? ""] } ==
            degradation.workspace.windows.map { [$0.id.uuidString, "\($0.screenIndex ?? -1)", $0.displaySlotID?.uuidString ?? ""] }
        )
        #expect(secondRun.displayAssignments == degradation.displayAssignments)

        // End-to-end: the degraded payload passes non-interactive restore
        // preparation (.ready) instead of throwing assignmentRequired, and
        // every window resolves to the single available display.
        let preparation = try WorkspaceDisplayResolutionService.prepare(
            workspace: degradation.workspace,
            currentScreens: currentScreens,
            mode: .nonInteractive,
            explicitAssignments: degradation.displayAssignments
        )
        guard case .ready(let context) = preparation else {
            Issue.record("Expected ready restore context for degraded workspace")
            return
        }
        #expect(context.windowTargetsByWindowID.count == 2)
        #expect(context.windowTargetsByWindowID.values.allSatisfy { $0.targetScreenIndex == 0 })
        #expect(context.windowTargetsByWindowID.values.allSatisfy { $0.displayID == 42 })
    }

    @Test("Single-display workspace on two displays assigns the first display deterministically")
    func singleDisplayWorkspaceOnTwoDisplaysAssignsFirstDisplay() throws {
        let workspace = Workspace(
            name: "One Display",
            workspaceWindows: [
                makeWindow(bundleIdentifier: "com.example.editor", appName: "Editor", screenIndex: 0)
            ],
            screens: [WorkspaceScreen(from: makeScreen(displayID: 7, isPrimary: true))]
        )
        let analyzer = makeAnalyzer(installedBundleIDs: ["com.example.editor"])
        let currentScreens = [
            makeScreen(displayID: 10, originX: 0, isPrimary: true),
            makeScreen(displayID: 20, originX: 1920)
        ]

        let report = analyzer.analyze(workspace: workspace, currentDisplayCount: 2)

        #expect(report.displayRemap == WorkspacePortabilityReport.DisplayRemap(
            savedDisplayCount: 1,
            currentDisplayCount: 2,
            remappedWindowCount: 0
        ))

        let degradation = analyzer.applyDegradations(
            to: workspace,
            currentScreens: currentScreens,
            report: report
        )
        let slots = try #require(degradation.workspace.displaySlots)
        #expect(degradation.remappedWindowCount == 0)
        #expect(degradation.displayAssignments == [
            WorkspaceDisplayAssignment(slotID: slots[0].id, displayID: 10)
        ])

        let preparation = try WorkspaceDisplayResolutionService.prepare(
            workspace: degradation.workspace,
            currentScreens: currentScreens,
            mode: .nonInteractive,
            explicitAssignments: degradation.displayAssignments
        )
        guard case .ready(let context) = preparation else {
            Issue.record("Expected ready restore context")
            return
        }
        #expect(context.windowTargetsByWindowID.values.allSatisfy { $0.displayID == 10 })
    }

    @Test("Slots that identify a connected display keep it; sorted-order fill only covers the rest")
    func identityMatchedSlotsKeepTheirDisplays() throws {
        // Saved on displays 20 and 30 (secondary/tertiary). Restored on a
        // machine that also has display 10 as primary: the slots must claim
        // displays 20/30 by identity, not be forced onto 10/20 by sort order.
        let workspace = Workspace(
            name: "Identity",
            workspaceWindows: [
                makeWindow(bundleIdentifier: "com.example.editor", appName: "Editor", screenIndex: 0),
                makeWindow(bundleIdentifier: "com.example.terminal", appName: "Terminal", screenIndex: 1)
            ],
            screens: [
                WorkspaceScreen(from: makeScreen(displayID: 20, originX: 1920)),
                WorkspaceScreen(from: makeScreen(displayID: 30, originX: 3840))
            ]
        )
        let analyzer = makeAnalyzer(installedBundleIDs: ["com.example.editor", "com.example.terminal"])
        let currentScreens = [
            makeScreen(displayID: 10, originX: 0, isPrimary: true),
            makeScreen(displayID: 20, originX: 1920),
            makeScreen(displayID: 30, originX: 3840)
        ]

        let report = analyzer.analyze(workspace: workspace, currentDisplayCount: 3)
        #expect(report.displayRemap == WorkspacePortabilityReport.DisplayRemap(
            savedDisplayCount: 2,
            currentDisplayCount: 3,
            remappedWindowCount: 0
        ))

        let degradation = analyzer.applyDegradations(
            to: workspace,
            currentScreens: currentScreens,
            report: report
        )
        let slots = try #require(degradation.workspace.displaySlots)
        #expect(degradation.displayAssignments == [
            WorkspaceDisplayAssignment(slotID: slots[0].id, displayID: 20),
            WorkspaceDisplayAssignment(slotID: slots[1].id, displayID: 30)
        ])

        let preparation = try WorkspaceDisplayResolutionService.prepare(
            workspace: degradation.workspace,
            currentScreens: currentScreens,
            mode: .nonInteractive,
            explicitAssignments: degradation.displayAssignments
        )
        guard case .ready(let context) = preparation else {
            Issue.record("Expected ready restore context")
            return
        }
        let assignedDisplayIDs = Set(context.windowTargetsByWindowID.values.map(\.displayID))
        #expect(assignedDisplayIDs == [20, 30])
    }

    // MARK: - Flattened workspaces (no persisted geometry)

    @Test("Flattened workspace still analyzes and degrades via synthesized slots")
    func flattenedWorkspaceDegradesViaSynthesizedSlots() throws {
        let workspace = Workspace(
            name: "Flattened",
            workspaceWindows: [
                makeWindow(bundleIdentifier: "com.example.editor", appName: "Editor", screenIndex: 0),
                makeWindow(bundleIdentifier: "com.example.terminal", appName: "Terminal", screenIndex: 1)
            ],
            displaySlots: nil,
            screens: nil
        )
        let analyzer = makeAnalyzer(installedBundleIDs: ["com.example.editor", "com.example.terminal"])
        let currentScreens = [makeScreen(displayID: 42, isPrimary: true)]

        let report = analyzer.analyze(workspace: workspace, currentDisplayCount: 1)
        #expect(report.savedDisplayCount == 2)
        #expect(report.displayRemap?.remappedWindowCount == 1)

        let degradation = analyzer.applyDegradations(
            to: workspace,
            currentScreens: currentScreens,
            report: report
        )
        #expect(degradation.workspace.windows.map(\.screenIndex) == [0, 0])
        #expect(degradation.displayAssignments.count == 1)

        let preparation = try WorkspaceDisplayResolutionService.prepare(
            workspace: degradation.workspace,
            currentScreens: currentScreens,
            mode: .nonInteractive,
            explicitAssignments: degradation.displayAssignments
        )
        guard case .ready = preparation else {
            Issue.record("Expected ready restore context for flattened workspace")
            return
        }
    }

    // MARK: - Warning determinism

    @Test("Warnings are deterministically ordered: displays, then apps, then paths")
    func warningsAreDeterministicallyOrdered() {
        let workspace = Workspace(
            name: "Everything",
            workspaceWindows: [
                makeWindow(bundleIdentifier: "com.example.zeta", appName: "Zeta", screenIndex: 0),
                makeWindow(bundleIdentifier: "com.example.alpha", appName: "Alpha", screenIndex: 1),
                makeWindow(
                    bundleIdentifier: "com.example.editor",
                    appName: "Editor",
                    openPath: "/Users/gone/project",
                    screenIndex: 0
                )
            ],
            screens: [
                WorkspaceScreen(from: makeScreen(displayID: 7, originX: 0, isPrimary: true)),
                WorkspaceScreen(from: makeScreen(displayID: 9, originX: 1920))
            ]
        )
        let analyzer = makeAnalyzer(installedBundleIDs: ["com.example.editor"], existingPaths: [])

        let report = analyzer.analyze(workspace: workspace, currentDisplayCount: 1)

        #expect(report.warnings.count == 4)
        #expect(report.warnings[0].contains("displays"))
        #expect(report.warnings[1].contains("Alpha"))
        #expect(report.warnings[2].contains("Zeta"))
        #expect(report.warnings[3].contains("/Users/gone/project"))
    }
}
