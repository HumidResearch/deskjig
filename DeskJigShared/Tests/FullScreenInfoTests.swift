//
//  FullScreenInfoTests.swift
//  DeskJigSharedTests
//

import Testing
import CoreGraphics
@testable import DeskJigShared

struct FullScreenInfoTests {

    @Test("Non-primary screens preserve the provider visible frame when it matches the full frame")
    func nonPrimaryScreensPreserveReportedVisibleFrame() {
        let frame = CGRect(x: -1920, y: 0, width: 1920, height: 1080)
        let provider = MockScreenProvider(
            frame: frame,
            visibleFrame: frame,
            isPrimary: false,
            displayID: 7,
            displayName: "Secondary"
        )

        let screen = FullScreenInfo(screenProvider: provider)

        #expect(screen.visibleFrame == frame)
    }
}
