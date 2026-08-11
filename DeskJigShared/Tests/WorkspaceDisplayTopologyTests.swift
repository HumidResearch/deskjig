//
//  WorkspaceDisplayTopologyTests.swift
//  DeskJigSharedTests
//

import Testing
import CoreGraphics
@testable import DeskJigShared

struct WorkspaceDisplayTopologyTests {

    @Test("Display fingerprint matches by serial when available")
    func displayFingerprintMatchesBySerial() {
        let lhs = DisplayFingerprint(
            vendorID: 4268,
            modelNumber: 16821,
            serialNumber: 1110790732,
            displayUUID: "AAAA",
            name: "DELL U2720Q (1)",
            resolution: CGSize(width: 3840, height: 2160)
        )
        let rhs = DisplayFingerprint(
            vendorID: 4268,
            modelNumber: 16821,
            serialNumber: 1110790732,
            displayUUID: "BBBB",
            name: "Renamed DELL",
            resolution: CGSize(width: 3008, height: 1692)
        )

        #expect(lhs.matches(rhs))
    }

    @Test("Display fingerprint falls back to UUID when serial is unavailable")
    func displayFingerprintFallsBackToUUID() {
        let lhs = DisplayFingerprint(
            vendorID: 0,
            modelNumber: 0,
            serialNumber: nil,
            displayUUID: "9BE6B52C-E833-4AAE-B4F0-84D9C51C3D03",
            name: "VX1655-OLED",
            resolution: CGSize(width: 3840, height: 2160)
        )
        let rhs = DisplayFingerprint(
            vendorID: 0,
            modelNumber: 0,
            serialNumber: nil,
            displayUUID: "9be6b52c-e833-4aae-b4f0-84d9c51c3d03",
            name: "Reference Display",
            resolution: CGSize(width: 1920, height: 1080)
        )

        #expect(lhs.matches(rhs))
    }

    @Test("Display fingerprint falls back to vendor model name and resolution")
    func displayFingerprintFallsBackToNameAndResolution() {
        let lhs = DisplayFingerprint(
            vendorID: 4268,
            modelNumber: 16819,
            serialNumber: nil,
            displayUUID: nil,
            name: "DELL U2720Q (2)",
            resolution: CGSize(width: 3840, height: 2160)
        )
        let rhs = DisplayFingerprint(
            vendorID: 4268,
            modelNumber: 16819,
            serialNumber: nil,
            displayUUID: nil,
            name: "dell u2720q (2)",
            resolution: CGSize(width: 3840, height: 2160)
        )

        #expect(lhs.matches(rhs))
    }

    @Test("Effective screens exclude ignored display and preserve remaining order")
    func effectiveScreensExcludeIgnoredDisplay() {
        let left = makeScreen(
            displayID: 4,
            name: "DELL U2720Q (1)",
            origin: CGPoint(x: 0, y: 0),
            vendorID: 4268,
            modelNumber: 16821,
            serialNumber: 1110790732,
            displayUUID: "17BEF206-07DD-473A-9165-D1285CBF5FD4",
            isPrimary: true
        )
        let reference = makeScreen(
            displayID: 8,
            name: "VX1655-OLED",
            origin: CGPoint(x: 986, y: -1080),
            vendorID: 23139,
            modelNumber: 26175,
            serialNumber: 16843009,
            displayUUID: "9BE6B52C-E833-4AAE-B4F0-84D9C51C3D03"
        )
        let right = makeScreen(
            displayID: 5,
            name: "DELL U2720Q (2)",
            origin: CGPoint(x: 1920, y: 0),
            vendorID: 4268,
            modelNumber: 16819,
            serialNumber: 1163084364,
            displayUUID: "F964B74A-D519-44E1-8C0F-584F79FFEC3E"
        )

        let filtered = WorkspaceDisplayTopology.effectiveScreens(
            from: [left, reference, right],
            ignoredDisplays: [IgnoredDisplayPreference(screen: reference)]
        )

        #expect(filtered.map(\.displayID) == [4, 5])
    }

    @Test("Ignoring every screen falls back to raw topology")
    func ignoringEveryScreenFallsBackToRawTopology() {
        let left = makeScreen(displayID: 4, name: "DELL U2720Q (1)", origin: .zero)
        let right = makeScreen(displayID: 5, name: "DELL U2720Q (2)", origin: CGPoint(x: 1920, y: 0))

        let filtered = WorkspaceDisplayTopology.effectiveScreens(
            from: [left, right],
            ignoredDisplays: [
                IgnoredDisplayPreference(screen: left),
                IgnoredDisplayPreference(screen: right)
            ]
        )

        #expect(filtered.map(\.displayID) == [4, 5])
    }

    @Test("Sorted screens use Y tie-breakers for stacked displays")
    func sortScreensResolvesVerticalTies() {
        let lower = makeScreen(displayID: 4, name: "Lower", origin: CGPoint(x: 0, y: 0))
        let upper = makeScreen(displayID: 5, name: "Upper", origin: CGPoint(x: 0, y: 1080))
        let right = makeScreen(displayID: 6, name: "Right", origin: CGPoint(x: 1920, y: 0))

        let sorted = WorkspaceDisplayTopology.sortScreens([right, lower, upper])

        #expect(sorted.map(\.displayID) == [5, 4, 6])
    }

    @Test("Global max Y uses the highest display in the topology")
    func globalMaxYUsesHighestDisplay() {
        let lower = makeScreen(displayID: 4, name: "Lower", origin: CGPoint(x: 0, y: 0))
        let upper = makeScreen(displayID: 5, name: "Upper", origin: CGPoint(x: 0, y: 1080))

        let screens = [WorkspaceScreen(from: lower), WorkspaceScreen(from: upper)]

        #expect(WorkspaceScreen.calculateGlobalMaxY(from: screens) == 2160)
    }

    @Test("Screen frame conversion uses the primary display anchor for stacked displays")
    func screenFrameInWindowCoordinatesUsesPrimaryDisplayAnchor() {
        let primary = makeScreen(displayID: 4, name: "Primary", origin: CGPoint(x: 0, y: 0), isPrimary: true)
        let upper = makeScreen(displayID: 5, name: "Upper", origin: CGPoint(x: 0, y: 1080))
        let lower = makeScreen(displayID: 6, name: "Lower", origin: CGPoint(x: 0, y: -1080))

        let screens = [upper, primary, lower]

        let primaryWindowFrame = WorkspaceDisplayTopology.screenFrameInWindowCoordinates(
            primary.visibleFrame,
            from: screens
        )
        let upperWindowFrame = WorkspaceDisplayTopology.screenFrameInWindowCoordinates(
            upper.visibleFrame,
            from: screens
        )
        let lowerWindowFrame = WorkspaceDisplayTopology.screenFrameInWindowCoordinates(
            lower.visibleFrame,
            from: screens
        )

        #expect(primaryWindowFrame == CGRect(x: 0, y: 0, width: 1920, height: 1080))
        #expect(upperWindowFrame == CGRect(x: 0, y: -1080, width: 1920, height: 1080))
        #expect(lowerWindowFrame == CGRect(x: 0, y: 1080, width: 1920, height: 1080))
    }

    @Test("Top snap zone conversion keeps an upper monitor quarter on the upper monitor")
    func topSnapZoneConversionPreservesUpperMonitorPlacement() {
        let primary = makeScreen(
            displayID: 4,
            name: "Primary",
            origin: CGPoint(x: 0, y: 0),
            visibleHeight: 1050,
            isPrimary: true
        )
        let upper = makeScreen(
            displayID: 5,
            name: "Upper",
            origin: CGPoint(x: 0, y: 1080),
            visibleHeight: 1050
        )

        let topLeftZone = LayoutTemplate.fourParts
            .generateZones(in: upper.visibleFrame, screenIndex: 0)
            .first(where: { $0.type == .topLeft })

        guard let topLeftZone else {
            Issue.record("Expected a top-left zone for the upper display")
            return
        }

        let converted = WorkspaceDisplayTopology.screenFrameInWindowCoordinates(
            topLeftZone.frame,
            from: [upper, primary]
        )

        #expect(converted == CGRect(x: 0, y: -1050, width: 960, height: 525))
        #expect(converted.minY < 0)
    }

    private func makeScreen(
        displayID: Int,
        name: String,
        origin: CGPoint,
        visibleHeight: CGFloat = 1080,
        vendorID: Int = 0,
        modelNumber: Int = 0,
        serialNumber: Int? = nil,
        displayUUID: String? = nil,
        isPrimary: Bool = false
    ) -> FullScreenInfo {
        let frame = CGRect(x: origin.x, y: origin.y, width: 1920, height: 1080)
        let provider = MockScreenProvider(
            frame: frame,
            visibleFrame: CGRect(
                x: origin.x,
                y: origin.y,
                width: 1920,
                height: visibleHeight
            ),
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
}
