//
//  WindowPositioningServiceTests.swift
//  DeskJigSharedTests
//

import Testing
import CoreGraphics
@testable import DeskJigShared

struct WindowPositioningServiceTests {

    @Test("Layout matcher treats lower-row titlebar spillover as the same placement")
    func layoutMatcherAcceptsLowerRowChromeSpillover() {
        let screens = [
            makeScreen(displayID: 5, frame: CGRect(x: -1920, y: 1080, width: 1920, height: 1080), visibleFrame: CGRect(x: -1920, y: 1080, width: 1920, height: 1080), isPrimary: false),
            makeScreen(displayID: 7, frame: CGRect(x: -1920, y: 0, width: 1920, height: 1080), visibleFrame: CGRect(x: -1920, y: 0, width: 1920, height: 1080), isPrimary: false),
            makeScreen(displayID: 3, frame: CGRect(x: 0, y: 0, width: 1920, height: 1080), visibleFrame: CGRect(x: 0, y: 0, width: 1920, height: 1050), isPrimary: true)
        ]

        // Window coordinates are anchored at the primary display's top edge
        // (WorkspaceDisplayTopology.windowCoordinateAnchorY), so the top of the
        // primary's visible frame is y = 30 (below the 30pt menu bar). Desired is
        // the left half of the lower-row primary; observed is Chrome's outer frame
        // spilling 62pt above the visible area.
        let desired = CGRect(x: 0, y: 30, width: 960, height: 1050)
        let observed = CGRect(x: 0, y: -32, width: 960, height: 1050)

        #expect(
            WindowLayoutFrameMatcher.matchesLayout(
                actualFrame: observed,
                targetFrame: desired,
                screens: screens
            )
        )
    }

    @Test("Layout matcher still rejects meaningful in-display drift")
    func layoutMatcherRejectsMeaningfulInDisplayDrift() {
        let screens = [
            makeScreen(displayID: 5, frame: CGRect(x: -1920, y: 1080, width: 1920, height: 1080), visibleFrame: CGRect(x: -1920, y: 1080, width: 1920, height: 1080), isPrimary: false),
            makeScreen(displayID: 7, frame: CGRect(x: -1920, y: 0, width: 1920, height: 1080), visibleFrame: CGRect(x: -1920, y: 0, width: 1920, height: 1080), isPrimary: false),
            makeScreen(displayID: 3, frame: CGRect(x: 0, y: 0, width: 1920, height: 1080), visibleFrame: CGRect(x: 0, y: 0, width: 1920, height: 1050), isPrimary: true)
        ]

        // Same spillover scenario as above, but with a 140pt horizontal drift
        // that must still be rejected as a different placement.
        let desired = CGRect(x: 0, y: 30, width: 960, height: 1050)
        let observed = CGRect(x: 140, y: -32, width: 960, height: 1050)

        #expect(
            !WindowLayoutFrameMatcher.matchesLayout(
                actualFrame: observed,
                targetFrame: desired,
                screens: screens
            )
        )
    }

    @Test("Observed lower-row position drift produces a corrective retry target")
    func correctiveRetryTargetAccountsForObservedPositionDrift() {
        let desired = CGRect(x: 0, y: 1110, width: 960, height: 1050)
        let observed = CGRect(x: 0, y: 1048, width: 960, height: 1050)

        let corrected = WindowPositioningService.correctedTargetFrameForObservedPositionDrift(
            desiredTarget: desired,
            observedFrame: observed,
            finalScreenIndex: 2,
            targetScreenIndex: 2
        )

        #expect(corrected == CGRect(x: 0, y: 1172, width: 960, height: 1050))
    }

    @Test("Corrective retry target skips size clamps and cross-screen mismatches")
    func correctiveRetryTargetSkipsUnrelatedMismatches() {
        let desired = CGRect(x: -960, y: 30, width: 960, height: 525)
        let sizeClamped = CGRect(x: -960, y: 30, width: 960, height: 600)
        let crossScreen = CGRect(x: -960, y: 555, width: 960, height: 525)

        let skippedForSize = WindowPositioningService.correctedTargetFrameForObservedPositionDrift(
            desiredTarget: desired,
            observedFrame: sizeClamped,
            finalScreenIndex: 0,
            targetScreenIndex: 0
        )
        let skippedForScreen = WindowPositioningService.correctedTargetFrameForObservedPositionDrift(
            desiredTarget: desired,
            observedFrame: crossScreen,
            finalScreenIndex: 1,
            targetScreenIndex: 0
        )

        #expect(skippedForSize == nil)
        #expect(skippedForScreen == nil)
    }

    @Test("Size-clamp retry keeps an upper-left target on the upper-left monitor")
    func sizeClampRetryPreservesContainingDisplayGeometry() {
        let screens = [
            makeScreen(displayID: 5, frame: CGRect(x: -1920, y: 1080, width: 1920, height: 1080), visibleFrame: CGRect(x: -1920, y: 1080, width: 1920, height: 1050), isPrimary: false),
            makeScreen(displayID: 7, frame: CGRect(x: -1920, y: 0, width: 1920, height: 1080), visibleFrame: CGRect(x: -1920, y: 0, width: 1920, height: 1050), isPrimary: false),
            makeScreen(displayID: 3, frame: CGRect(x: 0, y: 0, width: 1920, height: 1080), visibleFrame: CGRect(x: 0, y: 0, width: 1920, height: 1050), isPrimary: true)
        ]

        let desired = CGRect(x: -960, y: -1050, width: 960, height: 525)
        let observed = CGRect(x: -960, y: -1050, width: 960, height: 600)

        let adjusted = WindowPositioningService.adjustedFrameForObservedSizeClamp(
            desiredTarget: desired,
            observedFrame: observed,
            currentScreens: screens
        )

        #expect(adjusted == CGRect(x: -960, y: -1050, width: 960, height: 600))
    }

    @Test("Best matching screen index follows geometry instead of assuming primary order")
    func bestMatchingScreenIndexUsesGeometry() {
        let screens = [
            makeScreen(displayID: 5, frame: CGRect(x: -1920, y: 1080, width: 1920, height: 1080), visibleFrame: CGRect(x: -1920, y: 1080, width: 1920, height: 1050), isPrimary: false),
            makeScreen(displayID: 7, frame: CGRect(x: -1920, y: 0, width: 1920, height: 1080), visibleFrame: CGRect(x: -1920, y: 0, width: 1920, height: 1050), isPrimary: false),
            makeScreen(displayID: 3, frame: CGRect(x: 0, y: 0, width: 1920, height: 1080), visibleFrame: CGRect(x: 0, y: 0, width: 1920, height: 1050), isPrimary: true)
        ]

        let upperLeft = WindowPositioningService.bestMatchingScreenIndex(
            for: CGRect(x: -960, y: -1050, width: 960, height: 600),
            among: screens
        )
        let lowerLeft = WindowPositioningService.bestMatchingScreenIndex(
            for: CGRect(x: -1920, y: 30, width: 576, height: 1050),
            among: screens
        )
        let right = WindowPositioningService.bestMatchingScreenIndex(
            for: CGRect(x: 0, y: 30, width: 960, height: 1050),
            among: screens
        )

        #expect(upperLeft == 0)
        #expect(lowerLeft == 1)
        #expect(right == 2)
    }

    private func makeScreen(
        displayID: Int,
        frame: CGRect,
        visibleFrame: CGRect,
        isPrimary: Bool
    ) -> FullScreenInfo {
        FullScreenInfo(
            screenProvider: MockScreenProvider(
                frame: frame,
                visibleFrame: visibleFrame,
                isPrimary: isPrimary,
                displayID: displayID,
                displayName: "Display \(displayID)"
            )
        )
    }
}
