//
//  WorkspaceLayoutHealthTests.swift
//  DeskJigSharedTests
//

import Testing
import CoreGraphics
@testable import DeskJigShared

struct WorkspaceLayoutHealthTests {

    @Test("Healthy workspaces with saved display metadata remain healthy")
    func slotBackedWorkspaceRemainsHealthy() {
        let slot = WorkspaceDisplaySlot(
            id: UUID(),
            title: "Monitor 1",
            displayID: 1,
            displayName: "Studio Display",
            resolution: CGSize(width: 5120, height: 2880),
            arrangementFrame: CGRect(x: 0, y: 0, width: 2560, height: 1440),
            visibleFrame: CGRect(x: 0, y: 0, width: 2560, height: 1400),
            isPrimary: true
        )
        let workspace = Workspace(
            name: "Healthy",
            workspaceWindows: [
                makeWindow(
                    app: "Editor",
                    bundle: BundleRegistry.vscode,
                    frame: RelativeWindowFrame(xPercent: 0, yPercent: 0, widthPercent: 1, heightPercent: 1),
                    displaySlotID: slot.id,
                    screenIndex: 0
                )
            ],
            displaySlots: [slot]
        )

        #expect(workspace.layoutHealth == .healthy)
        #expect(!workspace.needsLayoutRepair)
        guard case .unavailable = workspace.monitorRepairResult(using: []) else {
            Issue.record("Healthy workspace should bypass repair inference")
            return
        }
    }

    @Test("Zoom uses shared open path to choose project monitor against meeting monitor")
    func zoomLayoutResolvesProjectMonitorAgainstMeetingMonitor() {
        let path = "/Users/example/code/acme-web"
        let workspace = Workspace(
            name: "Zoom",
            workspaceWindows: [
                makeWindow(app: "Terminal", bundle: BundleRegistry.terminal, openPath: path, frame: .init(xPercent: 0.5, yPercent: 0.5, widthPercent: 0.5005, heightPercent: 0.5)),
                makeWindow(app: "zoom.us", bundle: BundleRegistry.zoom, frame: .init(xPercent: 0.5, yPercent: 0, widthPercent: 0.5, heightPercent: 1)),
                makeWindow(app: "Alacritty", bundle: BundleRegistry.alacritty, openPath: path, frame: .init(xPercent: 0.5, yPercent: 0, widthPercent: 0.5, heightPercent: 0.5)),
                makeWindow(app: "Cursor", bundle: BundleRegistry.cursor, openPath: path, frame: .init(xPercent: 0, yPercent: 0, widthPercent: 0.5, heightPercent: 1)),
                makeWindow(app: "Google Chrome", bundle: BundleRegistry.chrome, frame: .init(xPercent: 0, yPercent: 0, widthPercent: 0.5, heightPercent: 1))
            ]
        )

        guard case .resolved(let candidate) = workspace.monitorRepairResult(using: []) else {
            Issue.record("Expected Zoom to resolve automatically")
            return
        }

        let groupedApps = groupedAppSets(in: candidate.repairedWorkspace)
        #expect(groupedApps.contains(Set(["Cursor", "Alacritty", "Terminal"])))
        #expect(groupedApps.contains(Set(["Google Chrome", "zoom.us"])))
    }

    @Test("xcode keeps same-path Ghostty and Xcode together")
    func xcodeLayoutResolvesPathBackedProjectMonitor() {
        let path = "/Users/example/code/acme"
        let workspace = Workspace(
            name: "xcode",
            workspaceWindows: [
                makeWindow(app: "Codex", bundle: BundleRegistry.codex, frame: .init(xPercent: 0, yPercent: 0, widthPercent: 0.5, heightPercent: 1)),
                makeWindow(app: "Google Chrome", bundle: BundleRegistry.chrome, frame: .init(xPercent: 0.5, yPercent: 0, widthPercent: 0.5, heightPercent: 1)),
                makeWindow(app: "Ghostty", bundle: BundleRegistry.ghostty, openPath: path, frame: .init(xPercent: 0, yPercent: 0, widthPercent: 0.7, heightPercent: 1)),
                makeWindow(app: "Xcode", bundle: BundleRegistry.xcode, openPath: path, frame: .init(xPercent: 0.7, yPercent: 0, widthPercent: 0.3, heightPercent: 1))
            ]
        )

        guard case .resolved(let candidate) = workspace.monitorRepairResult(using: []) else {
            Issue.record("Expected xcode to resolve automatically")
            return
        }

        let groupedApps = groupedAppSets(in: candidate.repairedWorkspace)
        #expect(groupedApps.contains(Set(["Ghostty", "Xcode"])))
        #expect(groupedApps.contains(Set(["Codex", "Google Chrome"])))
    }

    @Test("Web Code keeps same-path terminals and IDE together")
    func webCodeLayoutResolvesSharedProjectCluster() {
        let path = "/Users/example/code/shows-cli"
        let workspace = Workspace(
            name: "Web Code",
            workspaceWindows: [
                makeWindow(app: "Google Chrome", bundle: BundleRegistry.chrome, frame: .init(xPercent: 0, yPercent: 0, widthPercent: 0.5, heightPercent: 1)),
                makeWindow(app: "Tower", bundle: "com.fournova.Tower3", frame: .init(xPercent: 0.5, yPercent: 0, widthPercent: 0.5, heightPercent: 1)),
                makeWindow(app: "Ghostty A", bundle: BundleRegistry.ghostty, openPath: path, frame: .init(xPercent: 0, yPercent: 0, widthPercent: 0.5, heightPercent: 0.5)),
                makeWindow(app: "Ghostty B", bundle: BundleRegistry.ghostty, openPath: path, frame: .init(xPercent: 0, yPercent: 0.5, widthPercent: 0.5, heightPercent: 0.5)),
                makeWindow(app: "Cursor", bundle: BundleRegistry.cursor, openPath: path, frame: .init(xPercent: 0.5, yPercent: 0, widthPercent: 0.5, heightPercent: 1))
            ]
        )

        guard case .resolved(let candidate) = workspace.monitorRepairResult(using: []) else {
            Issue.record("Expected Web Code to resolve automatically")
            return
        }

        let groupedApps = groupedAppSets(in: candidate.repairedWorkspace)
        #expect(groupedApps.contains(Set(["Ghostty A", "Ghostty B", "Cursor"])))
        #expect(groupedApps.contains(Set(["Google Chrome", "Tower"])))
    }

    @Test("messaging prefers messaging pair against browser companion monitor")
    func messagingLayoutResolvesByRoleCompatibility() {
        let workspace = Workspace(
            name: "messaging",
            workspaceWindows: [
                makeWindow(app: "Discord", bundle: BundleRegistry.discord, frame: .init(xPercent: 0, yPercent: 0, widthPercent: 0.5, heightPercent: 1)),
                makeWindow(app: "Messages", bundle: BundleRegistry.messages, frame: .init(xPercent: 0.5, yPercent: 0, widthPercent: 0.5, heightPercent: 1)),
                makeWindow(app: "Spotify", bundle: "com.spotify.client", frame: .init(xPercent: 0, yPercent: 0, widthPercent: 0.3, heightPercent: 1)),
                makeWindow(app: "Google Chrome", bundle: BundleRegistry.chrome, frame: .init(xPercent: 0.3, yPercent: 0, widthPercent: 0.7, heightPercent: 1))
            ]
        )

        guard case .resolved(let candidate) = workspace.monitorRepairResult(using: []) else {
            Issue.record("Expected messaging layout to resolve automatically")
            return
        }

        let groupedApps = groupedAppSets(in: candidate.repairedWorkspace)
        #expect(groupedApps.contains(Set(["Discord", "Messages"])))
        #expect(groupedApps.contains(Set(["Spotify", "Google Chrome"])))
    }

    @Test("Marketing stays unresolved without stronger priors")
    func marketingLayoutNeedsChoiceOrStaysUnavailable() {
        let workspace = Workspace(
            name: "Marketing",
            workspaceWindows: [
                makeWindow(app: "Discord", bundle: BundleRegistry.discord, frame: .init(xPercent: 0, yPercent: 0, widthPercent: 0.5, heightPercent: 1)),
                makeWindow(app: "Notes", bundle: "com.apple.Notes", frame: .init(xPercent: 0.5, yPercent: 0, widthPercent: 0.5, heightPercent: 0.5)),
                makeWindow(app: "Ghostty", bundle: BundleRegistry.ghostty, frame: .init(xPercent: 0.5, yPercent: 0.5, widthPercent: 0.5, heightPercent: 0.5)),
                makeWindow(app: "Typefully", bundle: "com.todesktop.2304250k2av6yux", frame: .init(xPercent: 0, yPercent: 0, widthPercent: 0.5, heightPercent: 1)),
                makeWindow(app: "Google Chrome", bundle: BundleRegistry.chrome, frame: .init(xPercent: 0.5, yPercent: 0, widthPercent: 0.5, heightPercent: 1))
            ]
        )

        switch workspace.monitorRepairResult(using: []) {
        case .needsChoice, .unavailable:
            #expect(true)
        case .resolved:
            Issue.record("Marketing should not auto-resolve without stronger priors")
        }
    }

    @Test("Bento stays unresolved without stronger priors")
    func bentoLayoutNeedsChoiceOrStaysUnavailable() {
        let workspace = Workspace(
            name: "Bento",
            workspaceWindows: [
                makeWindow(app: "Ghostty A", bundle: BundleRegistry.ghostty, frame: .init(xPercent: 0, yPercent: 0, widthPercent: 0.5, heightPercent: 0.5)),
                makeWindow(app: "iTerm2 A", bundle: BundleRegistry.iterm2, frame: .init(xPercent: 0.5, yPercent: 0, widthPercent: 0.5, heightPercent: 0.5)),
                makeWindow(app: "Ghostty B", bundle: BundleRegistry.ghostty, frame: .init(xPercent: 0, yPercent: 0.5, widthPercent: 0.5, heightPercent: 0.5)),
                makeWindow(app: "iTerm2 B", bundle: BundleRegistry.iterm2, frame: .init(xPercent: 0.5, yPercent: 0.5, widthPercent: 0.5, heightPercent: 0.5)),
                makeWindow(app: "Ghostty C", bundle: BundleRegistry.ghostty, frame: .init(xPercent: 0, yPercent: 0, widthPercent: 0.5, heightPercent: 0.5)),
                makeWindow(app: "Ghostty D", bundle: BundleRegistry.ghostty, frame: .init(xPercent: 0, yPercent: 0.5, widthPercent: 0.5, heightPercent: 0.5)),
                makeWindow(app: "Activity Monitor", bundle: "com.apple.ActivityMonitor", frame: .init(xPercent: 0.5, yPercent: 0, widthPercent: 0.5, heightPercent: 1))
            ]
        )

        switch workspace.monitorRepairResult(using: []) {
        case .needsChoice, .unavailable:
            #expect(true)
        case .resolved:
            Issue.record("Bento should not auto-resolve without stronger priors")
        }
    }

    @Test("Inferred repairs preserve original workspace metadata")
    func inferredRepairProducesValidDisplayAssignments() {
        let workspace = Workspace(
            name: "xcode",
            icon: "🎲",
            workspaceWindows: [
                makeWindow(app: "Codex", bundle: BundleRegistry.codex, frame: .init(xPercent: 0, yPercent: 0, widthPercent: 0.5, heightPercent: 1)),
                makeWindow(app: "Google Chrome", bundle: BundleRegistry.chrome, frame: .init(xPercent: 0.5, yPercent: 0, widthPercent: 0.5, heightPercent: 1)),
                makeWindow(app: "Ghostty", bundle: BundleRegistry.ghostty, openPath: "/Users/example/code/acme", frame: .init(xPercent: 0, yPercent: 0, widthPercent: 0.7, heightPercent: 1)),
                makeWindow(app: "Xcode", bundle: BundleRegistry.xcode, openPath: "/Users/example/code/acme", frame: .init(xPercent: 0.7, yPercent: 0, widthPercent: 0.3, heightPercent: 1))
            ]
        )

        guard case .resolved(let candidate) = workspace.monitorRepairResult(using: []) else {
            Issue.record("Expected xcode-style layout to infer a repair")
            return
        }

        let repaired = candidate.repairedWorkspace
        let slots = repaired.displaySlots ?? []
        let screens = repaired.screens ?? []
        let slotIDs = Set(slots.map(\.id))

        #expect(repaired.name == workspace.name)
        #expect(repaired.icon == workspace.icon)
        #expect(repaired.windows.map(\.windowTitle) == workspace.windows.map(\.windowTitle))
        #expect(slots.count == 2)
        #expect(screens.count == 2)
        #expect(slots[0].arrangementFrame.minX < slots[1].arrangementFrame.minX)
        #expect(repaired.windows.allSatisfy { window in
            guard let screenIndex = window.screenIndex,
                  let displaySlotID = window.displaySlotID else {
                return false
            }
            return screens.indices.contains(screenIndex) && slotIDs.contains(displaySlotID)
        })
    }

    private func groupedAppSets(in workspace: Workspace) -> [Set<String>] {
        let grouped = Dictionary(grouping: workspace.windows) { $0.screenIndex ?? -1 }
        return grouped.values.map { Set($0.map(\.appName)) }
    }

    private func makeWindow(
        app: String,
        bundle: String,
        openPath: String? = nil,
        frame: RelativeWindowFrame,
        displaySlotID: UUID? = nil,
        screenIndex: Int? = nil
    ) -> WorkspaceWindow {
        WorkspaceWindow(
            bundleIdentifier: bundle,
            appName: app,
            windowTitle: app,
            openPath: openPath,
            displaySlotID: displaySlotID,
            screenIndex: screenIndex,
            relativeFrame: frame
        )
    }
}
