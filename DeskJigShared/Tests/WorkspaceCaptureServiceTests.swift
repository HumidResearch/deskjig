//
//  WorkspaceCaptureServiceTests.swift
//  DeskJigSharedTests
//

import Testing
import CoreGraphics
@testable import DeskJigShared

struct WorkspaceCaptureServiceTests {

    @Test("Ignored-screen windows are omitted and remaining screens keep compact indices")
    func ignoredScreenWindowsAreOmittedAndIndicesAreCompacted() {
        let left = makeScreen(displayID: 4, name: "DELL U2720Q (1)", origin: CGPoint(x: 0, y: 0))
        let reference = makeScreen(displayID: 8, name: "VX1655-OLED", origin: CGPoint(x: 986, y: -1080))
        let right = makeScreen(displayID: 5, name: "DELL U2720Q (2)", origin: CGPoint(x: 1920, y: 0))

        let captureService = WorkspaceCaptureService(
            displayManager: DisplayManager(),
            bestScreenResolver: { frame in
                switch Int(frame.origin.x) {
                case 0: return left
                case 986: return reference
                case 1920: return right
                default: return nil
                }
            }
        )

        let effectiveScreens = [WorkspaceScreen(from: left), WorkspaceScreen(from: right)]

        let leftMatch = captureService.findScreenInfo(
            for: CGRect(x: 0, y: 0, width: 800, height: 600),
            in: effectiveScreens
        )
        let ignoredMatch = captureService.findScreenInfo(
            for: CGRect(x: 986, y: -1080, width: 800, height: 600),
            in: effectiveScreens
        )
        let rightMatch = captureService.findScreenInfo(
            for: CGRect(x: 1920, y: 0, width: 800, height: 600),
            in: effectiveScreens
        )

        #expect(leftMatch?.index == 0)
        #expect(ignoredMatch == nil)
        #expect(rightMatch?.index == 1)
    }

    private func makeScreen(displayID: Int, name: String, origin: CGPoint) -> FullScreenInfo {
        let frame = CGRect(x: origin.x, y: origin.y, width: 1920, height: 1080)
        let provider = MockScreenProvider(
            frame: frame,
            visibleFrame: frame,
            isPrimary: displayID == 4,
            displayID: displayID,
            displayName: name
        )
        return FullScreenInfo(screenProvider: provider)
    }
}
