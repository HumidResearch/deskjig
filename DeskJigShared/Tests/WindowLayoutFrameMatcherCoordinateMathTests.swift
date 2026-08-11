//
//  WindowLayoutFrameMatcherCoordinateMathTests.swift
//  DeskJigSharedTests
//
//  Extends restoration coordinate-math coverage for WindowLayoutFrameMatcher's
//  overshoot clamping / nearest-display fallback, and WorkspaceDisplayTopology's
//  globalMaxY + no-primary anchor fallback. See ticket #504.
//

import Testing
import CoreGraphics
@testable import DeskJigShared

/// Covers WindowLayoutFrameMatcher's normalizedCoordinate/normalizedExtent overshoot
/// clamping, the off-all-screens nearest-display fallback in screenIndex, and
/// matchesLayout's coordinate/size tolerance boundaries.
struct WindowLayoutFrameMatcherCoordinateMathTests {

    // MARK: - (a) normalizedCoordinate / normalizedExtent overshoot boundaries (overshootTolerance = 0.08)

    @Test("Relative layout clamps a negative X overshoot just inside tolerance to zero")
    func negativeXOvershootJustInsideToleranceClampsToZero() {
        let screens = [singleScreen]
        // rawX = -79 / 1000 = -0.079; abs(-0.079) <= 0.08 -> clamps to 0.
        let frame = CGRect(x: -79, y: 100, width: 500, height: 500)

        let layout = WindowLayoutFrameMatcher.relativeLayout(for: frame, in: screens)

        #expect(layout?.screenIndex == 0)
        #expect(layout?.xPercent == 0)
    }

    @Test("Relative layout leaves a negative X overshoot just outside tolerance unclamped")
    func negativeXOvershootJustOutsideToleranceStaysNegative() {
        let screens = [singleScreen]
        // rawX = -81 / 1000 = -0.081; abs(-0.081) > 0.08 -> stays negative.
        let frame = CGRect(x: -81, y: 100, width: 500, height: 500)

        let layout = WindowLayoutFrameMatcher.relativeLayout(for: frame, in: screens)

        #expect(layout?.screenIndex == 0)
        #expect((layout?.xPercent ?? 0) < 0)
    }

    @Test("Relative layout clamps a positive Y overshoot just inside tolerance to one")
    func positiveYOvershootJustInsideToleranceClampsToOne() {
        let screens = [singleScreen]
        // rawY = 1079 / 1000 = 1.079; (1.079 - 1) <= 0.08 -> clamps to 1.
        let frame = CGRect(x: 100, y: 1079, width: 300, height: 100)

        let layout = WindowLayoutFrameMatcher.relativeLayout(for: frame, in: screens)

        #expect(layout?.yPercent == 1)
    }

    @Test("Relative layout leaves a positive Y overshoot just outside tolerance unclamped")
    func positiveYOvershootJustOutsideToleranceStaysAboveOne() {
        let screens = [singleScreen]
        // rawY = 1081 / 1000 = 1.081; (1.081 - 1) > 0.08 -> stays above 1.
        let frame = CGRect(x: 100, y: 1081, width: 300, height: 100)

        let layout = WindowLayoutFrameMatcher.relativeLayout(for: frame, in: screens)

        #expect((layout?.yPercent ?? 0) > 1)
    }

    @Test("Relative layout clamps a width overshoot just inside tolerance to one")
    func widthOvershootJustInsideToleranceClampsToOne() {
        let screens = [singleScreen]
        // rawWidth = 1079 / 1000 = 1.079; (1.079 - 1) <= 0.08 -> clamps to 1.
        let frame = CGRect(x: 100, y: 100, width: 1079, height: 500)

        let layout = WindowLayoutFrameMatcher.relativeLayout(for: frame, in: screens)

        #expect(layout?.widthPercent == 1)
    }

    @Test("Relative layout leaves a width overshoot just outside tolerance unclamped")
    func widthOvershootJustOutsideToleranceStaysAboveOne() {
        let screens = [singleScreen]
        // rawWidth = 1081 / 1000 = 1.081; (1.081 - 1) > 0.08 -> stays above 1.
        let frame = CGRect(x: 100, y: 100, width: 1081, height: 500)

        let layout = WindowLayoutFrameMatcher.relativeLayout(for: frame, in: screens)

        #expect((layout?.widthPercent ?? 0) > 1)
    }

    // MARK: - (b) Off-all-screens nearest-display fallback (screenIndex)

    @Test("Screen index falls back to the nearest display when a window center is off every display, nearer to the left screen")
    func screenIndexFallsBackToNearestDisplayWhenOffScreenNearLeft() {
        let screens = [leftPrimaryScreen, rightScreen]
        // Center (150, 1350) is below both displays (which span y:[0, 1080]);
        // distance to the left display (270) is far shorter than to the right (~1790.5).
        let frame = CGRect(x: 100, y: 1300, width: 100, height: 100)

        let layout = WindowLayoutFrameMatcher.relativeLayout(for: frame, in: screens)

        #expect(layout?.screenIndex == 0)
    }

    @Test("Screen index falls back to the nearest display when a window center is off every display, nearer to the right screen")
    func screenIndexFallsBackToNearestDisplayWhenOffScreenNearRight() {
        let screens = [leftPrimaryScreen, rightScreen]
        // Center (2000, 1350) is below both displays; distance to the right display
        // (270) is shorter than to the left (~281.6), so the fallback must not just
        // default to the first screen.
        let frame = CGRect(x: 1950, y: 1300, width: 100, height: 100)

        let layout = WindowLayoutFrameMatcher.relativeLayout(for: frame, in: screens)

        #expect(layout?.screenIndex == 1)
    }

    // MARK: - (c) matchesLayout tolerance boundaries (coordinateTolerance = 0.03, sizeTolerance = 0.05)

    @Test("Matches layout accepts a coordinate drift just inside coordinateTolerance")
    func matchesLayoutAcceptsCoordinateDriftJustInsideTolerance() {
        let screens = [singleScreen]
        let target = CGRect(x: 100, y: 100, width: 500, height: 500)
        // xPercent diff = |0.129 - 0.1| = 0.029 <= 0.03.
        let actual = CGRect(x: 129, y: 100, width: 500, height: 500)

        #expect(WindowLayoutFrameMatcher.matchesLayout(actualFrame: actual, targetFrame: target, screens: screens))
    }

    @Test("Matches layout rejects a coordinate drift just outside coordinateTolerance")
    func matchesLayoutRejectsCoordinateDriftJustOutsideTolerance() {
        let screens = [singleScreen]
        let target = CGRect(x: 100, y: 100, width: 500, height: 500)
        // xPercent diff = |0.131 - 0.1| = 0.031 > 0.03.
        let actual = CGRect(x: 131, y: 100, width: 500, height: 500)

        #expect(!WindowLayoutFrameMatcher.matchesLayout(actualFrame: actual, targetFrame: target, screens: screens))
    }

    @Test("Matches layout accepts a size drift just inside sizeTolerance")
    func matchesLayoutAcceptsSizeDriftJustInsideTolerance() {
        let screens = [singleScreen]
        let target = CGRect(x: 100, y: 100, width: 500, height: 500)
        // widthPercent diff = |0.549 - 0.5| = 0.049 <= 0.05.
        let actual = CGRect(x: 100, y: 100, width: 549, height: 500)

        #expect(WindowLayoutFrameMatcher.matchesLayout(actualFrame: actual, targetFrame: target, screens: screens))
    }

    @Test("Matches layout rejects a size drift just outside sizeTolerance")
    func matchesLayoutRejectsSizeDriftJustOutsideTolerance() {
        let screens = [singleScreen]
        let target = CGRect(x: 100, y: 100, width: 500, height: 500)
        // widthPercent diff = |0.551 - 0.5| = 0.051 > 0.05.
        let actual = CGRect(x: 100, y: 100, width: 551, height: 500)

        #expect(!WindowLayoutFrameMatcher.matchesLayout(actualFrame: actual, targetFrame: target, screens: screens))
    }

    // MARK: - Fixtures

    /// A single 1000x1000 primary display whose frame equals its visible frame, so
    /// window-coordinate math reduces to simple fraction-of-1000 arithmetic.
    private var singleScreen: FullScreenInfo {
        makeScreen(
            displayID: 9,
            frame: CGRect(x: 0, y: 0, width: 1000, height: 1000),
            visibleFrame: CGRect(x: 0, y: 0, width: 1000, height: 1000),
            isPrimary: true
        )
    }

    /// Left-hand primary 1920x1080 display used for the nearest-display fallback tests.
    private var leftPrimaryScreen: FullScreenInfo {
        makeScreen(
            displayID: 1,
            frame: CGRect(x: 0, y: 0, width: 1920, height: 1080),
            visibleFrame: CGRect(x: 0, y: 0, width: 1920, height: 1080),
            isPrimary: true
        )
    }

    /// Right-hand secondary 1920x1080 display used for the nearest-display fallback tests.
    private var rightScreen: FullScreenInfo {
        makeScreen(
            displayID: 2,
            frame: CGRect(x: 1920, y: 0, width: 1920, height: 1080),
            visibleFrame: CGRect(x: 1920, y: 0, width: 1920, height: 1080),
            isPrimary: false
        )
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

/// Covers WorkspaceDisplayTopology.globalMaxY(from:) for both the FullScreenInfo and
/// WorkspaceScreen overloads, plus the windowCoordinateAnchorY no-primary fallback
/// (returns the first screen's maxY when no screen in the array is primary).
struct WorkspaceDisplayTopologyAnchorTests {

    @Test("Global max Y from FullScreenInfo screens uses the highest display")
    func globalMaxYFromFullScreenInfoUsesHighestDisplay() {
        let lower = makeScreen(displayID: 4, origin: CGPoint(x: 0, y: 0))
        let upper = makeScreen(displayID: 5, origin: CGPoint(x: 0, y: 1080))

        #expect(WorkspaceDisplayTopology.globalMaxY(from: [lower, upper]) == 2160)
    }

    @Test("Global max Y from WorkspaceScreen screens uses the highest display")
    func globalMaxYFromWorkspaceScreensUsesHighestDisplay() {
        let lower = WorkspaceScreen(from: makeScreen(displayID: 4, origin: CGPoint(x: 0, y: 0)))
        let upper = WorkspaceScreen(from: makeScreen(displayID: 5, origin: CGPoint(x: 0, y: 1080)))

        #expect(WorkspaceDisplayTopology.globalMaxY(from: [lower, upper]) == 2160)
    }

    @Test("Window coordinate anchor Y falls back to the first FullScreenInfo screen when none is primary")
    func windowCoordinateAnchorYFallsBackToFirstScreenWhenNoPrimary() {
        let first = makeScreen(displayID: 6, origin: CGPoint(x: 0, y: 0), isPrimary: false)
        let second = makeScreen(displayID: 7, origin: CGPoint(x: 0, y: 1080), isPrimary: false)

        // Neither screen is primary, so the fallback must use screens.first, not the
        // screen with the greatest maxY.
        #expect(WorkspaceDisplayTopology.windowCoordinateAnchorY(from: [first, second]) == first.frame.maxY)
        #expect(WorkspaceDisplayTopology.windowCoordinateAnchorY(from: [first, second]) == 1080)
    }

    @Test("Window coordinate anchor Y falls back to the first WorkspaceScreen when none is primary")
    func windowCoordinateAnchorYForWorkspaceScreensFallsBackToFirstScreenWhenNoPrimary() {
        let first = WorkspaceScreen(from: makeScreen(displayID: 6, origin: CGPoint(x: 0, y: 0), isPrimary: false))
        let second = WorkspaceScreen(from: makeScreen(displayID: 7, origin: CGPoint(x: 0, y: 1080), isPrimary: false))

        #expect(WorkspaceDisplayTopology.windowCoordinateAnchorY(from: [first, second]) == first.frame.maxY)
        #expect(WorkspaceDisplayTopology.windowCoordinateAnchorY(from: [first, second]) == 1080)
    }

    private func makeScreen(
        displayID: Int,
        origin: CGPoint,
        isPrimary: Bool = false
    ) -> FullScreenInfo {
        let frame = CGRect(x: origin.x, y: origin.y, width: 1920, height: 1080)
        return FullScreenInfo(
            screenProvider: MockScreenProvider(
                frame: frame,
                visibleFrame: frame,
                isPrimary: isPrimary,
                displayID: displayID,
                displayName: "Display \(displayID)"
            )
        )
    }
}
