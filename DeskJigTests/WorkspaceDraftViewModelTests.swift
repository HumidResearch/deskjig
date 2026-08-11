// WorkspaceDraftViewModelTests.swift
// DeskJigTests

import Testing
import CoreGraphics
@testable import DeskJig
@testable import DeskJigShared

struct WorkspaceDraftViewModelTests {

    @Test("Workspace draft save order follows assigned monitor arrangement rather than draft slot order")
    @MainActor
    func normalizedSaveOrderFollowsAssignedArrangement() {
        let screens = [
            WorkspaceDraftViewModel.DraftScreen(
                id: UUID(),
                title: "Monitor 1",
                displayName: "Lower Left",
                isPrimary: false,
                isVirtual: false,
                displayID: 7,
                resolution: CGSize(width: 3840, height: 2160),
                frame: CGRect(x: -1920, y: 0, width: 1920, height: 1080),
                visibleFrame: CGRect(x: -1920, y: 0, width: 1920, height: 1050),
                displayFingerprint: nil,
                screenInfo: nil
            ),
            WorkspaceDraftViewModel.DraftScreen(
                id: UUID(),
                title: "Monitor 2",
                displayName: "Upper Left",
                isPrimary: false,
                isVirtual: false,
                displayID: 5,
                resolution: CGSize(width: 3840, height: 2160),
                frame: CGRect(x: -1920, y: 1080, width: 1920, height: 1080),
                visibleFrame: CGRect(x: -1920, y: 1080, width: 1920, height: 1050),
                displayFingerprint: nil,
                screenInfo: nil
            ),
            WorkspaceDraftViewModel.DraftScreen(
                id: UUID(),
                title: "Monitor 3",
                displayName: "Right",
                isPrimary: true,
                isVirtual: false,
                displayID: 3,
                resolution: CGSize(width: 3840, height: 2160),
                frame: CGRect(x: 0, y: 0, width: 1920, height: 1080),
                visibleFrame: CGRect(x: 0, y: 0, width: 1920, height: 1050),
                displayFingerprint: nil,
                screenInfo: nil
            )
        ]

        let currentDisplays = [
            makeScreen(displayID: 5, name: "Upper Left", origin: CGPoint(x: -1920, y: 1080)),
            makeScreen(displayID: 7, name: "Lower Left", origin: CGPoint(x: -1920, y: 0)),
            makeScreen(displayID: 3, name: "Right", origin: CGPoint(x: 0, y: 0), isPrimary: true)
        ]

        let saveOrder = WorkspaceDraftViewModel.normalizedSaveOrder(
            screens: screens,
            currentDisplays: currentDisplays,
            screenAssignments: [0: 1, 1: 0, 2: 2]
        )
        let saveIndexMap = WorkspaceDraftViewModel.normalizedSaveIndexMap(
            screens: screens,
            currentDisplays: currentDisplays,
            screenAssignments: [0: 1, 1: 0, 2: 2]
        )

        #expect(saveOrder == [1, 0, 2])
        #expect(saveIndexMap == [1: 0, 0: 1, 2: 2])
    }

    private func makeScreen(
        displayID: Int,
        name: String,
        origin: CGPoint,
        isPrimary: Bool = false
    ) -> FullScreenInfo {
        let frame = CGRect(x: origin.x, y: origin.y, width: 1920, height: 1080)
        let provider = MockScreenProvider(
            frame: frame,
            visibleFrame: CGRect(x: origin.x, y: origin.y, width: 1920, height: 1050),
            isPrimary: isPrimary,
            displayID: displayID,
            displayName: name
        )
        return FullScreenInfo(screenProvider: provider)
    }
}

