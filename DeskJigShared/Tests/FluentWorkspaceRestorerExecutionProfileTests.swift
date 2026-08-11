//
//  FluentWorkspaceRestorerExecutionProfileTests.swift
//  DeskJigSharedTests
//
//  Verifies execution-profile selection for deterministic and single-target fast-path restores.
//

import Testing
import CoreGraphics
@testable import DeskJigShared

struct FluentWorkspaceRestorerExecutionProfileTests {

    @Test("Deterministic + single-target + terminal+IDE enables single-monitor fast path")
    func deterministicSingleTargetEnablesFastPath() {
        let decision = FluentWorkspaceRestorer.resolveExecutionProfile(
            deterministicPositioningEnabled: true,
            requestedPhaseExecutionMode: .automatic,
            requestedMaxConcurrency: 4,
            mappedWindowCount: 4,
            mappedWindowScreenIndices: [0, 0, 0, 0],
            hasTerminalWindows: true,
            hasIDEWindows: true,
            launchSource: "unknown"
        )

        #expect(decision.singleTargetFastPathEnabled)
        #expect(decision.phaseExecutionMode == .parallel)
        #expect(decision.sharedConcurrency == 3)
        #expect(decision.targetScreenCardinality == 1)
    }

    @Test("Deterministic + multi-target uses sequential phases with per-display concurrency")
    func deterministicMultiTargetUsesSequentialPhasesWithPerDisplayConcurrency() {
        let decision = FluentWorkspaceRestorer.resolveExecutionProfile(
            deterministicPositioningEnabled: true,
            requestedPhaseExecutionMode: .automatic,
            requestedMaxConcurrency: 8,
            mappedWindowCount: 4,
            mappedWindowScreenIndices: [0, 1, 0, 1],
            hasTerminalWindows: true,
            hasIDEWindows: true,
            launchSource: "unknown"
        )

        #expect(!decision.singleTargetFastPathEnabled)
        #expect(decision.phaseExecutionMode == .sequential)
        #expect(decision.sharedConcurrency == 2)
        #expect(decision.reason == "multi-display-lane-sequential")
        #expect(decision.targetScreenCardinality == 2)
    }

    @Test("Deterministic + quick-switch multi-target runs parallel per-display lanes")
    func deterministicQuickSwitchMultiTargetRunsParallel() {
        let decision = FluentWorkspaceRestorer.resolveExecutionProfile(
            deterministicPositioningEnabled: true,
            requestedPhaseExecutionMode: .automatic,
            requestedMaxConcurrency: 8,
            mappedWindowCount: 4,
            mappedWindowScreenIndices: [0, 1, 0, 1],
            hasTerminalWindows: true,
            hasIDEWindows: true,
            launchSource: "quick-switch"
        )

        #expect(!decision.singleTargetFastPathEnabled)
        #expect(decision.phaseExecutionMode == .parallel)
        #expect(decision.sharedConcurrency == 2)
        #expect(decision.reason == "multi-display-lane-parallel")
        #expect(decision.targetScreenCardinality == 2)
    }

    @Test("Parallel phase order runs slowStart after parallel phases")
    func phaseExecutionOrderKeepsSlowStartLastInParallelMode() {
        let parallelOrder = FluentWorkspaceRestorer.phaseExecutionOrder(for: .parallel)
        #expect(parallelOrder == ["other", "terminal", "ide", "chrome", "slowStart"])
    }

    @Test("Deterministic + single-target terminal-only runs parallel without the fast path")
    func deterministicSingleTargetTerminalOnlyRunsParallel() {
        let decision = FluentWorkspaceRestorer.resolveExecutionProfile(
            deterministicPositioningEnabled: true,
            requestedPhaseExecutionMode: .automatic,
            requestedMaxConcurrency: 8,
            mappedWindowCount: 3,
            mappedWindowScreenIndices: [0, 0, 0],
            hasTerminalWindows: true,
            hasIDEWindows: false,
            launchSource: "unknown"
        )

        // Terminal-only single-display sets run parallel (capped at min(windowCount, 4))
        // because clamp compensation adjusts neighbor frames retroactively; the
        // single-target fast path still requires both terminal and IDE phases.
        #expect(!decision.singleTargetFastPathEnabled)
        #expect(decision.phaseExecutionMode == .parallel)
        #expect(decision.sharedConcurrency == 3)
        #expect(decision.reason == "terminal-only-parallel")
        #expect(decision.targetScreenCardinality == 1)
    }

    @Test("Deterministic profile requires complete screen mapping before fast path")
    func deterministicMissingTargetScreensStaysSequential() {
        let decision = FluentWorkspaceRestorer.resolveExecutionProfile(
            deterministicPositioningEnabled: true,
            requestedPhaseExecutionMode: .automatic,
            requestedMaxConcurrency: 8,
            mappedWindowCount: 3,
            mappedWindowScreenIndices: [0, 0],
            hasTerminalWindows: true,
            hasIDEWindows: true,
            launchSource: "unknown"
        )

        #expect(!decision.singleTargetFastPathEnabled)
        #expect(decision.phaseExecutionMode == .sequential)
        #expect(decision.sharedConcurrency == 1)
        #expect(decision.reason == "missing-target-screens")
    }

    @Test("Deferred row redistribution preserves baseline proportions after clamp compensation")
    func deferredRowRedistributionUsesBaselineProportions() {
        let baselineFrames = [
            CGRect(x: 1920, y: 555, width: 672, height: 525),
            CGRect(x: 2592, y: 555, width: 672, height: 525)
        ]
        let adjustedFrames = [
            CGRect(x: 1920, y: 555, width: 672, height: 525),
            CGRect(x: 2592, y: 555, width: 308, height: 525)
        ]
        let redistributed = FluentWorkspaceRestorer.redistributeDeferredTerminalRowFrames(
            baselineFrames: baselineFrames,
            adjustedFrames: adjustedFrames,
            screenIndices: [1, 1]
        )

        #expect(redistributed.count == 2)
        #expect(abs(redistributed[0].origin.x - 1920) <= 0.5)
        #expect(abs(redistributed[0].width - 490) <= 0.5)
        #expect(abs(redistributed[1].origin.x - 2410) <= 0.5)
        #expect(abs(redistributed[1].width - 490) <= 0.5)
    }

    @Test("Deferred row redistribution is scoped per display")
    func deferredRowRedistributionScopedPerDisplay() {
        let baselineFrames = [
            CGRect(x: 1920, y: 555, width: 672, height: 525),
            CGRect(x: 2592, y: 555, width: 672, height: 525),
            CGRect(x: 0, y: 555, width: 600, height: 525),
            CGRect(x: 600, y: 555, width: 600, height: 525)
        ]
        let adjustedFrames = [
            CGRect(x: 1920, y: 555, width: 672, height: 525),
            CGRect(x: 2592, y: 555, width: 308, height: 525),
            CGRect(x: 0, y: 555, width: 600, height: 525),
            CGRect(x: 600, y: 555, width: 600, height: 525)
        ]
        let redistributed = FluentWorkspaceRestorer.redistributeDeferredTerminalRowFrames(
            baselineFrames: baselineFrames,
            adjustedFrames: adjustedFrames,
            screenIndices: [1, 1, 0, 0]
        )

        #expect(abs(redistributed[0].width - 490) <= 0.5)
        #expect(abs(redistributed[1].width - 490) <= 0.5)
        #expect(abs(redistributed[2].origin.x - adjustedFrames[2].origin.x) <= 0.5)
        #expect(abs(redistributed[2].width - adjustedFrames[2].width) <= 0.5)
        #expect(abs(redistributed[3].origin.x - adjustedFrames[3].origin.x) <= 0.5)
        #expect(abs(redistributed[3].width - adjustedFrames[3].width) <= 0.5)
    }
}
