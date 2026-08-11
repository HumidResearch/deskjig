// InlineScreenSelectionStateTests.swift
// DeskJigTests

import Testing
import CoreGraphics
@testable import DeskJig
@testable import DeskJigShared

struct InlineScreenSelectionStateTests {

    @Test("Initial selection keeps all suggested assignments and leaves extra monitors unassigned")
    @MainActor
    func initialSelectionPreservesSuggestedAssignments() {
        let analysis = makeAnalysis(
            savedCount: 2,
            currentCount: 3,
            mappings: [
                ScreenMappingInfo(savedIndex: 0, currentIndex: 2, matchKind: .displayID),
                ScreenMappingInfo(savedIndex: 1, currentIndex: 1, matchKind: .displayID)
            ]
        )

        let state = InlineScreenSelectionState(analysis: analysis)
        let expectedMappings = [
            ScreenMappingInfo(savedIndex: 0, currentIndex: 2, matchKind: .displayID),
            ScreenMappingInfo(savedIndex: 1, currentIndex: 1, matchKind: .displayID)
        ]

        #expect(state.selectedMappings == expectedMappings)
        #expect(state.assignedLayoutIndex(forMonitor: 0) == nil)
        #expect(state.assignedLayoutIndex(forMonitor: 1) == 1)
        #expect(state.assignedLayoutIndex(forMonitor: 2) == 0)
    }

    @Test("Assigning a layout to a new monitor clears the previous monitor assignment")
    @MainActor
    func assigningLayoutMovesItOffThePreviousMonitor() {
        let analysis = makeAnalysis(
            savedCount: 2,
            currentCount: 3,
            mappings: [
                ScreenMappingInfo(savedIndex: 0, currentIndex: 2, matchKind: .displayID),
                ScreenMappingInfo(savedIndex: 1, currentIndex: 1, matchKind: .displayID)
            ]
        )

        let state = InlineScreenSelectionState(analysis: analysis)
        state.assignSavedScreen(0, toCurrentScreen: 0, savedScreenCount: 2, currentScreenCount: 3)

        #expect(state.assignedLayoutIndex(forMonitor: 0) == 0)
        #expect(state.assignedLayoutIndex(forMonitor: 1) == 1)
        #expect(state.assignedLayoutIndex(forMonitor: 2) == nil)

        let assignedMonitors = state.selectedMappings.compactMap(\.currentIndex)
        #expect(Set(assignedMonitors).count == assignedMonitors.count)
    }

    @Test("Assigning an in-use layout swaps it with the current monitor's prior layout")
    @MainActor
    func assigningInUseLayoutSwapsLayoutsAcrossMonitors() {
        let analysis = makeAnalysis(
            savedCount: 2,
            currentCount: 2,
            mappings: [
                ScreenMappingInfo(savedIndex: 0, currentIndex: 0, matchKind: .displayID),
                ScreenMappingInfo(savedIndex: 1, currentIndex: 1, matchKind: .displayID)
            ]
        )

        let state = InlineScreenSelectionState(analysis: analysis)
        state.assignSavedScreen(0, toCurrentScreen: 1, savedScreenCount: 2, currentScreenCount: 2)

        #expect(state.assignedLayoutIndex(forMonitor: 0) == 1)
        #expect(state.assignedLayoutIndex(forMonitor: 1) == 0)
    }

    @Test("Cycling an unassigned monitor rehomes the displaced monitor to the next free layout")
    @MainActor
    func cycleReassignsDisplacedMonitorToAvailableLayout() {
        let analysis = makeAnalysis(
            savedCount: 3,
            currentCount: 3,
            mappings: [
                ScreenMappingInfo(savedIndex: 0, currentIndex: 0, matchKind: .displayID),
                ScreenMappingInfo(savedIndex: 1, currentIndex: 2, matchKind: .displayID),
                ScreenMappingInfo(savedIndex: 2, currentIndex: nil, matchKind: .unresolved)
            ]
        )

        let state = InlineScreenSelectionState(analysis: analysis)
        state.cycleLayout(forMonitor: 1, savedScreenCount: 3, currentScreenCount: 3)

        #expect(state.assignedLayoutIndex(forMonitor: 0) == 2)
        #expect(state.assignedLayoutIndex(forMonitor: 1) == 0)
        #expect(state.assignedLayoutIndex(forMonitor: 2) == 1)

        let assignedMonitors = state.selectedMappings.compactMap(\.currentIndex)
        #expect(Set(assignedMonitors).count == assignedMonitors.count)
    }

    private func makeAnalysis(
        savedCount: Int,
        currentCount: Int,
        mappings: [ScreenMappingInfo]
    ) -> ScreenMismatchAnalysis {
        let savedScreens = (0..<savedCount).map { index in
            let x = CGFloat(index * 1920)
            return WorkspaceScreen(
                displayID: 100 + index,
                name: "Saved \(index)",
                resolution: CGSize(width: 1920, height: 1080),
                frame: CGRect(x: x, y: 0, width: 1920, height: 1080),
                visibleFrame: CGRect(x: x, y: 0, width: 1920, height: 1050),
                isPrimary: index == 0,
                displayFingerprint: nil
            )
        }

        let currentScreens = (0..<currentCount).map { index in
            let x = CGFloat(index * 1920)
            return makeScreen(
                displayID: 200 + index,
                name: "Current \(index)",
                origin: CGPoint(x: x, y: 0),
                isPrimary: index == 0
            )
        }

        return ScreenMismatchAnalysis(
            savedScreenCount: savedCount,
            currentScreenCount: currentCount,
            savedScreens: savedScreens,
            currentScreens: currentScreens,
            suggestedMappings: mappings
        )
    }

    private func makeScreen(
        displayID: Int,
        name: String,
        origin: CGPoint,
        isPrimary: Bool
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

