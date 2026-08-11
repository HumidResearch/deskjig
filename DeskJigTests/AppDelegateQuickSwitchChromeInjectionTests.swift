// AppDelegateQuickSwitchChromeInjectionTests.swift
// DeskJigTests

import Foundation
import Testing
@testable import DeskJig
@testable import DeskJigShared

struct AppDelegateQuickSwitchChromeInjectionTests {
    @Test("Inject URL reuses existing Chrome window and focuses equivalent existing tab")
    func reuseExistingChromeWithEquivalentURL() {
        let chromeWindow = WorkspaceWindow(
            id: UUID(),
            bundleIdentifier: BundleRegistry.chrome,
            appName: "Google Chrome",
            windowTitle: "Chrome",
            chromeState: ChromeWindowState(
                profileDirectory: "Default",
                profileDisplayName: "Default",
                profileMatchMode: .anyWindow,
                shouldRestoreTabs: true,
                savedTabURLs: ["https://example.com"],
                focusedTabIndex: nil,
                chromeWindowId: 42
            )
        )
        let workspace = Workspace(name: "WS", workspaceWindows: [chromeWindow])

        let result = AppURLHelper.injectChromeURL("https://www.example.com/", into: workspace, forceChrome: true)
        #expect(result.mode == .reusedExistingChrome)
        #expect(result.workspace.windows.count == 1)

        let injected = result.workspace.windows[0]
        #expect(injected.chromeState?.savedTabURLs.count == 1)
        #expect(injected.chromeState?.focusedTabIndex == 1)
    }

    @Test("Inject URL appends missing tab and sets focused index to appended tab (1-based)")
    func appendMissingTabUsesOneBasedIndex() {
        let chromeWindow = WorkspaceWindow(
            id: UUID(),
            bundleIdentifier: BundleRegistry.chrome,
            appName: "Google Chrome",
            windowTitle: "Chrome",
            chromeState: ChromeWindowState(
                profileDirectory: "Default",
                profileDisplayName: "Default",
                profileMatchMode: .anyWindow,
                shouldRestoreTabs: true,
                savedTabURLs: ["https://example.com/docs"],
                focusedTabIndex: nil
            )
        )
        let workspace = Workspace(name: "WS", workspaceWindows: [chromeWindow])

        let result = AppURLHelper.injectChromeURL("https://example.com/new", into: workspace, forceChrome: true)
        #expect(result.mode == .reusedExistingChrome)

        let injected = result.workspace.windows[0]
        #expect(injected.chromeState?.savedTabURLs.count == 2)
        #expect(injected.chromeState?.focusedTabIndex == 2)
    }

    @Test("Inject URL with force_chrome adds temporary centered Chrome window when missing")
    func forceChromeAddsCenteredWindow() {
        let terminal = WorkspaceWindow(
            id: UUID(),
            bundleIdentifier: BundleRegistry.terminal,
            appName: "Terminal",
            windowTitle: "Terminal",
            screenIndex: 2
        )
        let workspace = Workspace(name: "WS", workspaceWindows: [terminal])

        let result = AppURLHelper.injectChromeURL("https://docs.example.com", into: workspace, forceChrome: true)
        #expect(result.mode == .addedForcedChrome)
        #expect(result.workspace.windows.count == 2)

        let chrome = result.workspace.windows.first { BundleRegistry.isChrome($0.bundleIdentifier) }
        #expect(chrome != nil)
        #expect(chrome?.screenIndex == 2)
        #expect(chrome?.relativeFrame?.xPercent == 0.15)
        #expect(chrome?.relativeFrame?.yPercent == 0.10)
        #expect(chrome?.relativeFrame?.widthPercent == 0.70)
        #expect(chrome?.relativeFrame?.heightPercent == 0.80)
        #expect(chrome?.chromeState?.focusedTabIndex == 1)
    }

    @Test("Inject URL without force_chrome leaves no-Chrome workspace unchanged")
    func noForceChromeSkipsInjection() {
        let terminal = WorkspaceWindow(
            id: UUID(),
            bundleIdentifier: BundleRegistry.terminal,
            appName: "Terminal",
            windowTitle: "Terminal"
        )
        let workspace = Workspace(name: "WS", workspaceWindows: [terminal])

        let result = AppURLHelper.injectChromeURL("https://example.com", into: workspace, forceChrome: false)
        #expect(result.mode == .skippedNoChrome)
        #expect(result.workspace.windows.count == 1)
        #expect(!result.workspace.windows.contains(where: { BundleRegistry.isChrome($0.bundleIdentifier) }))
    }

    @Test("Quick-switch previous workspace resolves to most recently active non-target workspace")
    func resolvePreviousWorkspaceUsesMostRecentNonTarget() {
        let older = makeWorkspace(name: "Older", createdAt: Date(timeIntervalSince1970: 100), lastActivatedAt: Date(timeIntervalSince1970: 120))
        let target = makeWorkspace(name: "Target", createdAt: Date(timeIntervalSince1970: 200), lastActivatedAt: Date(timeIntervalSince1970: 220))
        let current = makeWorkspace(name: "Current", createdAt: Date(timeIntervalSince1970: 300), lastActivatedAt: Date(timeIntervalSince1970: 340))

        let resolved = AppDelegate.resolveQuickSwitchPreviousWorkspace(
            switchingToWorkspaceID: target.id,
            savedWorkspaces: [older, target, current]
        )

        #expect(resolved?.id == current.id)
    }

    @Test("Quick-switch previous workspace falls back to next-most-recent workspace when target is most recent")
    func resolvePreviousWorkspaceUsesNextMostRecentWhenTargetIsMostRecent() {
        let target = makeWorkspace(name: "Target", createdAt: Date(timeIntervalSince1970: 200), lastActivatedAt: Date(timeIntervalSince1970: 500))
        let other = makeWorkspace(name: "Other", createdAt: Date(timeIntervalSince1970: 300), lastActivatedAt: Date(timeIntervalSince1970: 340))

        let resolved = AppDelegate.resolveQuickSwitchPreviousWorkspace(
            switchingToWorkspaceID: target.id,
            savedWorkspaces: [target, other]
        )

        #expect(resolved?.id == other.id)
    }

    @Test("Quick-switch previous workspace falls back to created date when activation dates are missing")
    func resolvePreviousWorkspaceFallsBackToCreatedDate() {
        let target = makeWorkspace(name: "Target", createdAt: Date(timeIntervalSince1970: 200), lastActivatedAt: nil)
        let current = makeWorkspace(name: "Current", createdAt: Date(timeIntervalSince1970: 400), lastActivatedAt: nil)

        let resolved = AppDelegate.resolveQuickSwitchPreviousWorkspace(
            switchingToWorkspaceID: target.id,
            savedWorkspaces: [target, current]
        )

        #expect(resolved?.id == current.id)
    }

    @Test("Quick-switch previous workspace prefers runtime current workspace when it is not the target")
    func resolvePreviousWorkspacePrefersRuntimeCurrentWorkspace() {
        let target = makeWorkspace(name: "Target", createdAt: Date(timeIntervalSince1970: 200), lastActivatedAt: Date(timeIntervalSince1970: 500))
        let runtimeCurrent = makeWorkspace(name: "Runtime", createdAt: Date(timeIntervalSince1970: 100), lastActivatedAt: Date(timeIntervalSince1970: 110))

        let resolved = AppDelegate.resolveQuickSwitchPreviousWorkspace(
            switchingToWorkspaceID: target.id,
            runtimeCurrentWorkspace: runtimeCurrent,
            runtimePreviousWorkspace: nil
        )

        #expect(resolved?.id == runtimeCurrent.id)
    }

    @Test("Quick-switch previous workspace uses runtime previous when current runtime matches target")
    func resolvePreviousWorkspaceUsesRuntimePreviousWhenCurrentMatchesTarget() {
        let target = makeWorkspace(name: "Target", createdAt: Date(timeIntervalSince1970: 200), lastActivatedAt: Date(timeIntervalSince1970: 500))
        let runtimePrevious = makeWorkspace(name: "Previous", createdAt: Date(timeIntervalSince1970: 300), lastActivatedAt: Date(timeIntervalSince1970: 340))

        let resolved = AppDelegate.resolveQuickSwitchPreviousWorkspace(
            switchingToWorkspaceID: target.id,
            runtimeCurrentWorkspace: target,
            runtimePreviousWorkspace: runtimePrevious
        )

        #expect(resolved?.id == runtimePrevious.id)
    }

    @Test("Quick-switch previous workspace does not fall back to saved workspaces when runtime snapshots are unavailable")
    func resolvePreviousWorkspaceDoesNotFallBackToSavedWorkspaces() {
        let target = makeWorkspace(name: "Target", createdAt: Date(timeIntervalSince1970: 200), lastActivatedAt: Date(timeIntervalSince1970: 500))

        let resolved = AppDelegate.resolveQuickSwitchPreviousWorkspace(
            switchingToWorkspaceID: target.id,
            runtimeCurrentWorkspace: nil,
            runtimePreviousWorkspace: nil
        )

        #expect(resolved == nil)
    }

    @Test("Quick-switch workspace lookup resolves explicit workspace ID override")
    func lookupQuickSwitchWorkspaceResolvesExplicitWorkspaceID() async {
        let workspace = makeWorkspace(name: "Shared Layout", createdAt: Date(timeIntervalSince1970: 100), lastActivatedAt: nil)
        let quickSwitchViewModel = await MainActor.run { QuickSwitchViewModel() }

        let result = await MainActor.run {
            AppDelegate.lookupQuickSwitchWorkspace(
                cwd: "/Users/brutus/code/deskjig",
                workspaceNameOverride: nil,
                workspaceIDOverrideRaw: workspace.id.uuidString,
                savedWorkspaces: [workspace],
                quickSwitchViewModel: quickSwitchViewModel
            )
        }

        #expect(result.workspace?.id == workspace.id)
        #expect(result.resolutionSource == "workspace-id-override")
        #expect(result.diagnosticMessage == nil)
    }

    @Test("Quick-switch workspace lookup succeeds after refreshed saved workspaces include new layout")
    func lookupQuickSwitchWorkspaceCanRecoverAfterReloadSnapshot() async {
        let workspace = makeWorkspace(name: "Agent Switch Matrix B Half User", createdAt: Date(timeIntervalSince1970: 100), lastActivatedAt: nil)
        let quickSwitchViewModel = await MainActor.run { QuickSwitchViewModel() }

        let initial = await MainActor.run {
            AppDelegate.lookupQuickSwitchWorkspace(
                cwd: "/Users/brutus/code/deskjig-wt/test_2",
                workspaceNameOverride: workspace.name,
                workspaceIDOverrideRaw: nil,
                savedWorkspaces: [],
                quickSwitchViewModel: quickSwitchViewModel
            )
        }
        #expect(initial.workspace == nil)
        #expect(initial.diagnosticMessage == "Quick-switch: workspace override not found")

        let reloaded = await MainActor.run {
            AppDelegate.lookupQuickSwitchWorkspace(
                cwd: "/Users/brutus/code/deskjig-wt/test_2",
                workspaceNameOverride: workspace.name,
                workspaceIDOverrideRaw: nil,
                savedWorkspaces: [workspace],
                quickSwitchViewModel: quickSwitchViewModel
            )
        }
        #expect(reloaded.workspace?.id == workspace.id)
        #expect(reloaded.resolutionSource == "workspace-name-override")
        #expect(reloaded.diagnosticMessage == nil)
    }

    @Test("Quick-switch go-back label prefers directory basename from openPath")
    func goBackLabelUsesDirectoryBasename() {
        let window = WorkspaceWindow(
            id: UUID(),
            bundleIdentifier: BundleRegistry.vscode,
            appName: "Cursor",
            windowTitle: "Dotfiles",
            openPath: "/Users/brutus/.dotfiles"
        )
        let workspace = Workspace(name: "Backend", workspaceWindows: [window])

        let label = AppDelegate.quickSwitchGoBackDestinationLabel(for: workspace)
        #expect(label == "Dotfiles")
    }

    @Test("Quick-switch go-back label falls back to workspace name without openPath")
    func goBackLabelFallsBackToWorkspaceName() {
        let window = WorkspaceWindow(
            id: UUID(),
            bundleIdentifier: BundleRegistry.chrome,
            appName: "Google Chrome",
            windowTitle: "Chrome"
        )
        let workspace = Workspace(name: "Market", workspaceWindows: [window])

        let label = AppDelegate.quickSwitchGoBackDestinationLabel(for: workspace)
        #expect(label == "Market")
    }

    @Test("Quick-switch go-back directory path uses compact home-relative path")
    func goBackDirectoryPathUsesCompactPath() {
        // Derive the fixture from the real home directory: tilde compaction only
        // applies to paths under the current user's home (e.g. /Users/runner on CI).
        let window = WorkspaceWindow(
            id: UUID(),
            bundleIdentifier: BundleRegistry.vscode,
            appName: "Cursor",
            windowTitle: "Dotfiles",
            openPath: NSHomeDirectory() + "/.dotfiles"
        )
        let workspace = Workspace(name: "Backend", workspaceWindows: [window])

        let path = AppDelegate.quickSwitchGoBackDirectoryPath(for: workspace)
        #expect(path == "~/.dotfiles")
    }

    @Test("Quick-switch go-back directory path is nil without openPath")
    func goBackDirectoryPathNilWithoutOpenPath() {
        let window = WorkspaceWindow(
            id: UUID(),
            bundleIdentifier: BundleRegistry.chrome,
            appName: "Google Chrome",
            windowTitle: "Chrome"
        )
        let workspace = Workspace(name: "Market", workspaceWindows: [window])

        let path = AppDelegate.quickSwitchGoBackDirectoryPath(for: workspace)
        #expect(path == nil)
    }

    @Test("Quick-switch Xcode skip notice is produced for non-project targets")
    func quickSwitchSkippedXcodeNotificationContentProduced() {
        let result = QuickSwitchWorkspaceTransformResult(
            workspace: Workspace(name: "WS", workspaceWindows: []),
            rewrittenWindowCount: 2,
            skippedXcodeWindowCount: 1,
            skippedXcodeForNonProjectTarget: true
        )

        let notification = AppDelegate.quickSwitchSkippedXcodeNotificationContent(
            for: result,
            targetDirectoryPath: "/Users/brutus/code/guidebook"
        )

        #expect(notification?.title == "No Xcode project detected in guidebook. Skipping Xcode.")
        #expect(notification?.icon == "hammer.circle.fill")
        #expect(notification?.iconColor == .yellow)
    }

    @Test("Quick-switch Xcode skip notice is omitted when no Xcode windows were skipped")
    func quickSwitchSkippedXcodeNotificationContentOmitted() {
        let result = QuickSwitchWorkspaceTransformResult(
            workspace: Workspace(name: "WS", workspaceWindows: []),
            rewrittenWindowCount: 2,
            skippedXcodeWindowCount: 0,
            skippedXcodeForNonProjectTarget: false
        )

        let notification = AppDelegate.quickSwitchSkippedXcodeNotificationContent(
            for: result,
            targetDirectoryPath: "/Users/brutus/code/deskjig"
        )

        #expect(notification == nil)
    }

    private func makeWorkspace(
        name: String,
        createdAt: Date,
        lastActivatedAt: Date?
    ) -> Workspace {
        Workspace.migrated(
            id: UUID(),
            name: name,
            icon: nil,
            createdAt: createdAt,
            lastActivatedAt: lastActivatedAt,
            windows: [],
            screens: nil
        )
    }
}

