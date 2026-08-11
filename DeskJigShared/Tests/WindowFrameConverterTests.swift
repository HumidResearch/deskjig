//  WindowFrameConverterTests.swift
//  DeskJigSharedTests

import Testing
import Foundation
import CoreGraphics
@testable import DeskJigShared

struct WindowFrameConverterTests {

    // MARK: - Helpers

    /// Build a FullScreenInfo via the public MockScreenProvider path (per ticket #537
    /// verifier correction: do not add a redundant memberwise init to FullScreenInfo).
    private func makeScreen(
        displayID: Int,
        frame: CGRect,
        isPrimary: Bool = false,
        backingScaleFactor: CGFloat = 1.0,
        vendorID: Int = 0,
        modelNumber: Int = 0,
        serialNumber: Int? = nil,
        displayUUID: String? = nil,
        name: String = "Mock"
    ) -> FullScreenInfo {
        let provider = MockScreenProvider(
            frame: frame,
            visibleFrame: frame,
            backingScaleFactor: backingScaleFactor,
            isPrimary: isPrimary,
            displayID: displayID,
            displayName: name,
            vendorID: vendorID,
            modelNumber: modelNumber,
            serialNumber: serialNumber,
            displayUUID: displayUUID
        )
        return FullScreenInfo(screenProvider: provider)
    }

    private func makeSavedScreen(
        displayID: Int,
        frame: CGRect,
        resolution: CGSize? = nil,
        isPrimary: Bool = false,
        fingerprint: DisplayFingerprint? = nil,
        name: String = "Saved"
    ) -> WorkspaceScreen {
        WorkspaceScreen(
            displayID: displayID,
            name: name,
            resolution: resolution ?? frame.size,
            frame: frame,
            visibleFrame: frame,
            isPrimary: isPrimary,
            displayFingerprint: fingerprint
        )
    }

    // MARK: - (a) RelativeWindowFrame.init rounding + clamping

    @Test("init rounds each percent to 4 decimal places")
    func initRoundsToFourDecimals() {
        // 0.123456 -> 1234.56 -> round -> 1235 -> 0.1235
        let frame = RelativeWindowFrame(
            xPercent: 0.123456,
            yPercent: 0.33333,   // 3333.3 -> 3333 -> 0.3333
            widthPercent: 0.5,
            heightPercent: 0.99999 // 9999.9 -> 10000 -> 1.0000
        )

        #expect(abs(frame.xPercent - 0.1235) < 1e-9)
        #expect(abs(frame.yPercent - 0.3333) < 1e-9)
        #expect(abs(frame.widthPercent - 0.5) < 1e-9)
        #expect(abs(frame.heightPercent - 1.0) < 1e-9)
    }

    @Test("init clamps out-of-range percents into [0, 1]")
    func initClampsOutOfRange() {
        let high = RelativeWindowFrame(xPercent: 1.2, yPercent: 5.0, widthPercent: 2.0, heightPercent: 1.0)
        #expect(high.xPercent == 1.0)
        #expect(high.yPercent == 1.0)
        #expect(high.widthPercent == 1.0)
        #expect(high.heightPercent == 1.0)

        let low = RelativeWindowFrame(xPercent: -0.1, yPercent: -3.0, widthPercent: -0.0001, heightPercent: 0.25)
        #expect(low.xPercent == 0.0)
        #expect(low.yPercent == 0.0)
        #expect(low.widthPercent == 0.0)
        #expect(low.heightPercent == 0.25)
    }

    // MARK: - (b) toRelative -> toAbsolute round-trip

    @Test("round-trip on a non-square screen returns the original frame within 1px")
    func roundTripWithinOnePixel() {
        // Non-square screen; thirds-based window exercises the 4dp rounding path.
        let screenFrame = CGRect(x: 0, y: 0, width: 1920, height: 1200)
        let original = CGRect(x: 640, y: 400, width: 640, height: 600) // x=1/3, w=1/3, y=1/3, h=1/2

        let relative = WindowFrameConverter.toRelative(windowFrame: original, screenFrame: screenFrame)
        let restored = WindowFrameConverter.toAbsolute(relativeFrame: relative, screenFrame: screenFrame)

        let tolerance: CGFloat = 1.0
        #expect(abs(restored.origin.x - original.origin.x) <= tolerance)
        #expect(abs(restored.origin.y - original.origin.y) <= tolerance)
        #expect(abs(restored.width - original.width) <= tolerance)
        #expect(abs(restored.height - original.height) <= tolerance)
    }

    @Test("round-trip preserves a non-zero screen origin offset within 1px")
    func roundTripWithScreenOriginOffset() {
        // Secondary display to the right: screen origin is non-zero.
        let screenFrame = CGRect(x: 1920, y: 0, width: 2560, height: 1440)
        let original = CGRect(x: 1920 + 256, y: 144, width: 1280, height: 720)

        let relative = WindowFrameConverter.toRelative(windowFrame: original, screenFrame: screenFrame)
        let restored = WindowFrameConverter.toAbsolute(relativeFrame: relative, screenFrame: screenFrame)

        let tolerance: CGFloat = 1.0
        #expect(abs(restored.origin.x - original.origin.x) <= tolerance)
        #expect(abs(restored.origin.y - original.origin.y) <= tolerance)
        #expect(abs(restored.width - original.width) <= tolerance)
        #expect(abs(restored.height - original.height) <= tolerance)
    }

    // MARK: - (c) Divide-by-zero guard

    @Test("zero-size screen yields an all-zero relative frame with no NaN")
    func zeroSizeScreenProducesZeroRelativeFrame() {
        let window = CGRect(x: 100, y: 100, width: 800, height: 600)
        let zeroScreen = CGRect(x: 0, y: 0, width: 0, height: 0)

        let relative = WindowFrameConverter.toRelative(windowFrame: window, screenFrame: zeroScreen)

        #expect(relative.xPercent == 0.0)
        #expect(relative.yPercent == 0.0)
        #expect(relative.widthPercent == 0.0)
        #expect(relative.heightPercent == 0.0)
        #expect(!relative.xPercent.isNaN)
        #expect(!relative.yPercent.isNaN)
        #expect(!relative.widthPercent.isNaN)
        #expect(!relative.heightPercent.isNaN)
    }

    @Test("zero-width-only screen zeroes horizontal percents but keeps vertical")
    func zeroWidthScreenGuardsHorizontalOnly() {
        let window = CGRect(x: 0, y: 300, width: 400, height: 600)
        let zeroWidthScreen = CGRect(x: 0, y: 0, width: 0, height: 1200)

        let relative = WindowFrameConverter.toRelative(windowFrame: window, screenFrame: zeroWidthScreen)

        #expect(relative.xPercent == 0.0)
        #expect(relative.widthPercent == 0.0)
        #expect(!relative.xPercent.isNaN)
        #expect(!relative.widthPercent.isNaN)
        // Vertical axis is well-defined: y = 300/1200 = 0.25, h = 600/1200 = 0.5
        #expect(abs(relative.yPercent - 0.25) < 1e-9)
        #expect(abs(relative.heightPercent - 0.5) < 1e-9)
    }

    // MARK: - (d) toAbsolute clamping

    @Test("toAbsolute clamps an oversized frame to the 400x300 usability floor")
    func toAbsoluteClampsToMinimumFloor() {
        let screenFrame = CGRect(x: 0, y: 0, width: 1000, height: 1000)
        // Position near the far edge so remaining space (100px) is below the floor.
        let relative = RelativeWindowFrame(xPercent: 0.9, yPercent: 0.9, widthPercent: 1.0, heightPercent: 1.0)

        let absolute = WindowFrameConverter.toAbsolute(relativeFrame: relative, screenFrame: screenFrame)

        #expect(absolute.origin.x == 900)
        #expect(absolute.origin.y == 900)
        // remaining width = 100 < 400 floor -> clamped to 400; remaining height = 100 < 300 -> 300
        #expect(absolute.width == 400)
        #expect(absolute.height == 300)
    }

    @Test("toAbsolute clamps width/height to remaining space when above the floor")
    func toAbsoluteClampsToRemainingSpace() {
        let screenFrame = CGRect(x: 0, y: 0, width: 1000, height: 1000)
        // Position at the midpoint: remaining space (500px) exceeds the floor, so
        // width/height clamp to remaining space rather than to 400x300.
        let relative = RelativeWindowFrame(xPercent: 0.5, yPercent: 0.5, widthPercent: 1.0, heightPercent: 1.0)

        let absolute = WindowFrameConverter.toAbsolute(relativeFrame: relative, screenFrame: screenFrame)

        #expect(absolute.origin.x == 500)
        #expect(absolute.origin.y == 500)
        #expect(absolute.width == 500)  // min(1000, max(500, 400)) = 500
        #expect(absolute.height == 500) // min(1000, max(500, 300)) = 500
    }

    @Test("toAbsolute leaves a well-fitting frame unclamped")
    func toAbsoluteLeavesFittingFrameUnchanged() {
        let screenFrame = CGRect(x: 0, y: 0, width: 1600, height: 1000)
        let relative = RelativeWindowFrame(xPercent: 0.25, yPercent: 0.2, widthPercent: 0.5, heightPercent: 0.5)

        let absolute = WindowFrameConverter.toAbsolute(relativeFrame: relative, screenFrame: screenFrame)

        #expect(absolute.origin.x == 400)
        #expect(absolute.origin.y == 200)
        #expect(absolute.width == 800)  // remaining = 1200, well above width; unclamped
        #expect(absolute.height == 500) // remaining = 800, well above height; unclamped
    }

    // MARK: - (e) findMatchingScreen strategy ladder

    // Strategy 1: display ID match wins even when another screen is a closer
    // positional match (so this fails if the displayID branch is removed).
    @Test("findMatchingScreen prefers an exact displayID match (strategy 1)")
    func findMatchingScreenMatchesByDisplayID() {
        let saved = makeSavedScreen(displayID: 42, frame: CGRect(x: 0, y: 0, width: 1000, height: 1000))
        let screens = [
            makeScreen(displayID: 42, frame: CGRect(x: 9000, y: 9000, width: 1000, height: 1000)),
            makeScreen(displayID: 7, frame: CGRect(x: 0, y: 0, width: 1000, height: 1000))
        ]

        let match = WindowFrameConverter.findMatchingScreen(savedScreen: saved, currentScreens: screens)
        #expect(match?.displayID == 42)
    }

    // Strategy 2: hardware fingerprint match when displayID has churned. The
    // fingerprint-matched screen is positionally farther, so this fails if the
    // fingerprint branch is removed (strategy 4 would pick the closer screen).
    @Test("findMatchingScreen falls back to the hardware fingerprint (strategy 2)")
    func findMatchingScreenMatchesByFingerprint() {
        let fingerprint = DisplayFingerprint(
            vendorID: 100,
            modelNumber: 200,
            serialNumber: 300,
            displayUUID: nil,
            name: "Studio Display",
            resolution: CGSize(width: 5120, height: 2880)
        )
        let saved = makeSavedScreen(
            displayID: 999, // no current screen has this id
            frame: CGRect(x: 5000, y: 5000, width: 1000, height: 1000),
            fingerprint: fingerprint
        )
        let screens = [
            // Fingerprint match (same vendor/model/serial), positionally far.
            makeScreen(
                displayID: 10,
                frame: CGRect(x: 0, y: 0, width: 1000, height: 1000),
                vendorID: 100, modelNumber: 200, serialNumber: 300
            ),
            // Same vendor/model but different serial -> not a fingerprint match;
            // positionally closest to the saved origin.
            makeScreen(
                displayID: 20,
                frame: CGRect(x: 5000, y: 5000, width: 1000, height: 1000),
                vendorID: 100, modelNumber: 200, serialNumber: 999
            )
        ]

        let match = WindowFrameConverter.findMatchingScreen(savedScreen: saved, currentScreens: screens)
        #expect(match?.displayID == 10)
    }

    // Strategy 3: primary-flag fallback. The primary screen is positionally far,
    // so this fails if the primary branch is removed (strategy 4 picks the closer).
    @Test("findMatchingScreen falls back to the primary screen (strategy 3)")
    func findMatchingScreenMatchesByPrimaryFlag() {
        let saved = makeSavedScreen(
            displayID: 555, // no id match
            frame: CGRect(x: 0, y: 0, width: 1000, height: 1000),
            isPrimary: true
        )
        let screens = [
            makeScreen(displayID: 1, frame: CGRect(x: 9000, y: 9000, width: 1000, height: 1000), isPrimary: true),
            makeScreen(displayID: 2, frame: CGRect(x: 0, y: 0, width: 1000, height: 1000), isPrimary: false)
        ]

        let match = WindowFrameConverter.findMatchingScreen(savedScreen: saved, currentScreens: screens)
        #expect(match?.displayID == 1)
    }

    // Strategy 4: origin/size score. The nearest-origin screen wins even though a
    // farther screen is the exact resolution match, pinning that strategy 4 is
    // terminal for non-empty input and no resolution-only fallback runs.
    @Test("findMatchingScreen scores by origin proximity (strategy 4)")
    func findMatchingScreenMatchesByOriginScore() {
        let saved = makeSavedScreen(
            displayID: 888, // no id match
            frame: CGRect(x: 0, y: 0, width: 2000, height: 2000),
            resolution: CGSize(width: 2000, height: 2000),
            isPrimary: false
        )
        let screens = [
            // Nearest origin, but resolution far from saved.
            makeScreen(displayID: 1, frame: CGRect(x: 10, y: 10, width: 500, height: 500)),
            // Far origin, but exact resolution match (would win if strategy 4 removed).
            makeScreen(displayID: 2, frame: CGRect(x: 5000, y: 5000, width: 2000, height: 2000))
        ]

        let match = WindowFrameConverter.findMatchingScreen(savedScreen: saved, currentScreens: screens)
        #expect(match?.displayID == 1)
    }

    // Strategy 4, size sub-term: with identical origins, the frame-size (resolution)
    // difference term breaks the tie. Ordered so the size-correct screen is second;
    // this fails if the `widthDiff*0.1 + heightDiff*0.1` weighting is removed (the
    // tie would then resolve to the first element).
    //
    // The dead standalone resolution-similarity strategy was deleted; resolution
    // influence is exercised only through strategy 4's score term, which this test pins.
    @Test("findMatchingScreen breaks an origin tie by frame-size similarity")
    func findMatchingScreenBreaksTieBySize() {
        let saved = makeSavedScreen(
            displayID: 888,
            frame: CGRect(x: 0, y: 0, width: 1000, height: 1000),
            isPrimary: false
        )
        let screens = [
            // Same origin, wrong size (listed first).
            makeScreen(displayID: 1, frame: CGRect(x: 0, y: 0, width: 4000, height: 4000)),
            // Same origin, exact size match (listed second).
            makeScreen(displayID: 2, frame: CGRect(x: 0, y: 0, width: 1000, height: 1000))
        ]

        let match = WindowFrameConverter.findMatchingScreen(savedScreen: saved, currentScreens: screens)
        #expect(match?.displayID == 2)
    }

    @Test("findMatchingScreen returns nil when there are no current screens")
    func findMatchingScreenReturnsNilForEmptyScreens() {
        let saved = makeSavedScreen(
            displayID: 1,
            frame: CGRect(x: 0, y: 0, width: 1000, height: 1000),
            isPrimary: true
        )

        // Empty input is the only path to the function's trailing return nil.
        let match = WindowFrameConverter.findMatchingScreen(savedScreen: saved, currentScreens: [])
        #expect(match == nil)
    }
}
