//
//  RestorationExecutorQuickSwitchPreflightTests.swift
//  DeskJigSharedTests
//
//  Verifies Quick Switch tmux preflight classification and source gating.
//

import Testing
@testable import DeskJigShared

struct RestorationExecutorQuickSwitchPreflightTests {

    @Test("Quick Switch launch source enables tmux preflight")
    func quickSwitchSourceEnablesPreflight() {
        #expect(RestorationExecutor.shouldUseQuickSwitchTmuxPreflight(launchSource: "quick-switch"))
    }

    @Test("Non-Quick Switch launch source does not enable tmux preflight")
    func nonQuickSwitchSourceDisablesPreflight() {
        #expect(!RestorationExecutor.shouldUseQuickSwitchTmuxPreflight(launchSource: "actionPanel"))
        #expect(!RestorationExecutor.shouldUseQuickSwitchTmuxPreflight(launchSource: "unknown"))
    }

    @Test("Preflight full match classifies as no-op")
    func fullMatchClassifiesNoOp() {
        let action = RestorationExecutor.classifyQuickSwitchTmuxPreflightAction(
            hasSelectedClient: true,
            hasSnapshotWindow: true,
            requiresSwitch: false,
            requiresTitleUpdate: false,
            requiresReposition: false,
            requiresPathUpdate: false
        )
        #expect(action == .noOp)
    }

    @Test("Preflight moved frame only classifies as reposition-only")
    func movedFrameClassifiesRepositionOnly() {
        let action = RestorationExecutor.classifyQuickSwitchTmuxPreflightAction(
            hasSelectedClient: true,
            hasSnapshotWindow: true,
            requiresSwitch: false,
            requiresTitleUpdate: false,
            requiresReposition: true,
            requiresPathUpdate: false
        )
        #expect(action == .repositionOnly)
    }

    @Test("Preflight session mismatch only classifies as switch-only")
    func sessionMismatchClassifiesSwitchOnly() {
        let action = RestorationExecutor.classifyQuickSwitchTmuxPreflightAction(
            hasSelectedClient: true,
            hasSnapshotWindow: true,
            requiresSwitch: true,
            requiresTitleUpdate: false,
            requiresReposition: false,
            requiresPathUpdate: false
        )
        #expect(action == .switchOnly)
    }

    @Test("Preflight indexed title mismatch only classifies as title-only")
    func titleMismatchClassifiesTitleOnly() {
        let action = RestorationExecutor.classifyQuickSwitchTmuxPreflightAction(
            hasSelectedClient: true,
            hasSnapshotWindow: true,
            requiresSwitch: false,
            requiresTitleUpdate: true,
            requiresReposition: false,
            requiresPathUpdate: false
        )
        #expect(action == .titleOnly)
    }

    @Test("Preflight enforces indexed title when session switch is required")
    func sessionSwitchForcesIndexedTitleEnforcement() {
        #expect(
            RestorationExecutor.shouldSetIndexedTitleForQuickSwitchPreflight(
                requiresSwitch: true,
                requiresTitleUpdate: false
            )
        )
        #expect(
            RestorationExecutor.shouldSetIndexedTitleForQuickSwitchPreflight(
                requiresSwitch: false,
                requiresTitleUpdate: true
            )
        )
        #expect(
            !RestorationExecutor.shouldSetIndexedTitleForQuickSwitchPreflight(
                requiresSwitch: false,
                requiresTitleUpdate: false
            )
        )
    }

    @Test("Quick Switch preflight never mutates existing tmux session paths")
    func quickSwitchPreflightDoesNotMutateExistingSessionPaths() {
        #expect(!RestorationExecutor.shouldMutateExistingTmuxSessionPathForQuickSwitch())
    }

    @Test("Surplus guard does not suppress tmux launch when bundle has no managed coverage")
    func surplusGuardAllowsBootstrapWithoutManagedCoverage() {
        #expect(
            !RestorationExecutor.shouldSuppressTmuxLaunchForBundleSurplus(
                expectedCount: 1,
                freshBundleWindowCount: 8,
                freshBundleAXWindowCount: 3,
                managedWindowCount: 0
            )
        )
    }

    @Test("Surplus guard suppresses tmux launch when managed coverage already exists")
    func surplusGuardSuppressesWhenManagedCoverageExists() {
        #expect(
            RestorationExecutor.shouldSuppressTmuxLaunchForBundleSurplus(
                expectedCount: 1,
                freshBundleWindowCount: 8,
                freshBundleAXWindowCount: 3,
                managedWindowCount: 1
            )
        )
    }

    @Test("Quick Switch iTerm multi-window TTY mapping allows session mismatch for switch")
    func quickSwitchITermMultiWindowTTYMismatchIsAllowed() {
        #expect(
            !RestorationExecutor.shouldEnforceSessionMatchForITermTTYMappedSelection(
                bundleId: BundleRegistry.iterm2,
                launchSource: "quick-switch",
                expectedWindowCount: 2
            )
        )
    }

    @Test("Non-Quick Switch iTerm multi-window TTY mapping keeps strict session match")
    func nonQuickSwitchITermMultiWindowTTYMismatchIsRejected() {
        #expect(
            RestorationExecutor.shouldEnforceSessionMatchForITermTTYMappedSelection(
                bundleId: BundleRegistry.iterm2,
                launchSource: "actionPanel",
                expectedWindowCount: 2
            )
        )
    }

    @Test("Single-window and non-iTerm TTY mapping keep strict session match")
    func nonITermOrSingleWindowKeepsStrictSessionMatch() {
        #expect(
            RestorationExecutor.shouldEnforceSessionMatchForITermTTYMappedSelection(
                bundleId: BundleRegistry.iterm2,
                launchSource: "quick-switch",
                expectedWindowCount: 1
            )
        )
        #expect(
            RestorationExecutor.shouldEnforceSessionMatchForITermTTYMappedSelection(
                bundleId: BundleRegistry.ghostty,
                launchSource: "quick-switch",
                expectedWindowCount: 2
            )
        )
    }

    @Test("Preflight missing evidence classifies as bootstrap")
    func missingEvidenceClassifiesBootstrap() {
        let missingClient = RestorationExecutor.classifyQuickSwitchTmuxPreflightAction(
            hasSelectedClient: false,
            hasSnapshotWindow: true,
            requiresSwitch: false,
            requiresTitleUpdate: false,
            requiresReposition: false,
            requiresPathUpdate: false
        )
        let missingWindow = RestorationExecutor.classifyQuickSwitchTmuxPreflightAction(
            hasSelectedClient: true,
            hasSnapshotWindow: false,
            requiresSwitch: false,
            requiresTitleUpdate: false,
            requiresReposition: false,
            requiresPathUpdate: false
        )
        #expect(missingClient == .bootstrap)
        #expect(missingWindow == .bootstrap)
    }

    @Test("Switch positioning failure with unresolved handle falls back to launch")
    func switchPositioningFailureFallsBackToLaunch() {
        #expect(
            RestorationExecutor.shouldFallbackToTmuxLaunchAfterSwitchPositionFailure(
                positioningSucceeded: false,
                finalFramePresent: false,
                hasTmuxState: true
            )
        )
    }

    @Test("Switch positioning does not fallback when frame resolved")
    func switchPositioningNoFallbackWhenFrameResolved() {
        #expect(
            !RestorationExecutor.shouldFallbackToTmuxLaunchAfterSwitchPositionFailure(
                positioningSucceeded: false,
                finalFramePresent: true,
                hasTmuxState: true
            )
        )
    }

    @Test("Switch positioning does not fallback without tmux state")
    func switchPositioningNoFallbackWithoutTmuxState() {
        #expect(
            !RestorationExecutor.shouldFallbackToTmuxLaunchAfterSwitchPositionFailure(
                positioningSucceeded: false,
                finalFramePresent: false,
                hasTmuxState: false
            )
        )
    }

    @Test("Generic iTerm title with tty-mapped expected session is treated as managed evidence")
    func genericTitleTTYSessionMappingIsManagedEvidence() {
        let genericTitleEvidence = RestorationExecutor.shouldTreatTTYMappedSessionAsManagedEvidence(
            bundleId: BundleRegistry.iterm2,
            windowTitle: "zsh",
            mappedSessionName: "bento_workspace",
            expectedSessionName: "bento_workspace"
        )
        #expect(genericTitleEvidence)

        let mismatchedSessionEvidence = RestorationExecutor.shouldTreatTTYMappedSessionAsManagedEvidence(
            bundleId: BundleRegistry.iterm2,
            windowTitle: "zsh",
            mappedSessionName: "bento_other",
            expectedSessionName: "bento_workspace"
        )
        #expect(!mismatchedSessionEvidence)

        let indexedTitleNoOverride = RestorationExecutor.shouldTreatTTYMappedSessionAsManagedEvidence(
            bundleId: BundleRegistry.iterm2,
            windowTitle: "bento:tmux:managed:3",
            mappedSessionName: "bento_workspace",
            expectedSessionName: "bento_workspace"
        )
        #expect(!indexedTitleNoOverride)
    }
}
