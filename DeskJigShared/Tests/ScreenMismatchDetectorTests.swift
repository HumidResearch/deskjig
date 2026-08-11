//
//  ScreenMismatchDetectorTests.swift
//  DeskJigSharedTests
//

import Testing
import CoreGraphics
@testable import DeskJigShared

struct ScreenMismatchDetectorTests {

    @Test("Suggested mappings prefer exact display matches over positional middle screen")
    func suggestedMappingsPreferExactDisplayMatches() {
        let savedScreens = [
            WorkspaceScreen(from: makeScreen(
                displayID: 4,
                name: "DELL U2720Q (1)",
                origin: CGPoint(x: 0, y: 0),
                vendorID: 4268,
                modelNumber: 16821,
                serialNumber: 1110790732,
                displayUUID: "17BEF206-07DD-473A-9165-D1285CBF5FD4",
                isPrimary: true
            )),
            WorkspaceScreen(from: makeScreen(
                displayID: 5,
                name: "DELL U2720Q (2)",
                origin: CGPoint(x: 1920, y: 0),
                vendorID: 4268,
                modelNumber: 16819,
                serialNumber: 1163084364,
                displayUUID: "F964B74A-D519-44E1-8C0F-584F79FFEC3E"
            ))
        ]

        let currentScreens = [
            makeScreen(
                displayID: 4,
                name: "DELL U2720Q (1)",
                origin: CGPoint(x: 0, y: 0),
                vendorID: 4268,
                modelNumber: 16821,
                serialNumber: 1110790732,
                displayUUID: "17BEF206-07DD-473A-9165-D1285CBF5FD4",
                isPrimary: true
            ),
            makeScreen(
                displayID: 8,
                name: "VX1655-OLED",
                origin: CGPoint(x: 986, y: -1080),
                vendorID: 23139,
                modelNumber: 26175,
                serialNumber: 16843009,
                displayUUID: "9BE6B52C-E833-4AAE-B4F0-84D9C51C3D03"
            ),
            makeScreen(
                displayID: 5,
                name: "DELL U2720Q (2)",
                origin: CGPoint(x: 1920, y: 0),
                vendorID: 4268,
                modelNumber: 16819,
                serialNumber: 1163084364,
                displayUUID: "F964B74A-D519-44E1-8C0F-584F79FFEC3E"
            )
        ]

        let mappings = ScreenMismatchDetector.suggestMappings(
            savedScreens: savedScreens,
            currentScreens: currentScreens
        )

        #expect(mappings == [
            ScreenMappingInfo(savedIndex: 0, currentIndex: 0, matchKind: .displayID),
            ScreenMappingInfo(savedIndex: 1, currentIndex: 2, matchKind: .displayID)
        ])
    }

    @Test("Same-count low-confidence topology prompts for review")
    func sameCountLowConfidenceRequiresSelection() {
        let workspace = Workspace(
            name: "Mismatch",
            workspaceWindows: [],
            screens: [
                WorkspaceScreen(
                    displayID: 10,
                    name: "Saved Left",
                    resolution: CGSize(width: 1920, height: 1080),
                    frame: CGRect(x: 0, y: 0, width: 1920, height: 1080),
                    visibleFrame: CGRect(x: 0, y: 0, width: 1920, height: 1080),
                    isPrimary: true,
                    displayFingerprint: nil
                ),
                WorkspaceScreen(
                    displayID: 11,
                    name: "Saved Top",
                    resolution: CGSize(width: 1920, height: 1080),
                    frame: CGRect(x: 0, y: 1080, width: 1920, height: 1080),
                    visibleFrame: CGRect(x: 0, y: 1080, width: 1920, height: 1080),
                    isPrimary: false,
                    displayFingerprint: nil
                )
            ]
        )

        let currentScreens = [
            makeScreen(
                displayID: 20,
                name: "Current Primary",
                origin: CGPoint(x: 0, y: 0),
                vendorID: 0,
                modelNumber: 0,
                serialNumber: nil,
                displayUUID: nil,
                isPrimary: true
            ),
            makeScreen(
                displayID: 21,
                name: "Current Right",
                origin: CGPoint(x: 1920, y: 0),
                vendorID: 0,
                modelNumber: 0,
                serialNumber: nil,
                displayUUID: nil,
                isPrimary: false
            )
        ]

        let analysis = ScreenMismatchDetector.analyze(workspace: workspace, currentScreens: currentScreens)

        #expect(analysis.hasTopologyChange)
        #expect(analysis.hasLowConfidenceMappings)
        #expect(analysis.requiresUserSelection)
    }

    @Test("Stacked saved screens remap to current topology by exact display identity")
    func stackedSavedScreensRemapByExactDisplayIdentity() {
        let savedScreens = [
            WorkspaceScreen(from: makeScreen(
                displayID: 7,
                name: "DELL U2720Q (1)",
                origin: CGPoint(x: -1920, y: 0),
                vendorID: 4268,
                modelNumber: 16821,
                serialNumber: 1110790732,
                displayUUID: "17BEF206-07DD-473A-9165-D1285CBF5FD4"
            )),
            WorkspaceScreen(from: makeScreen(
                displayID: 5,
                name: "DELL U2723QE",
                origin: CGPoint(x: -1920, y: 1080),
                vendorID: 4268,
                modelNumber: 17016,
                serialNumber: 1162891852,
                displayUUID: "2955E849-4C6D-4BD2-B37B-4C8FEC738AAB"
            )),
            WorkspaceScreen(from: makeScreen(
                displayID: 3,
                name: "DELL U2720Q (2)",
                origin: CGPoint(x: 0, y: 0),
                vendorID: 4268,
                modelNumber: 16821,
                serialNumber: 1163084364,
                displayUUID: "21FB5EBF-E01B-4A5B-8171-9915A40BE682",
                isPrimary: true
            ))
        ]

        let currentScreens = [
            makeScreen(
                displayID: 5,
                name: "DELL U2723QE",
                origin: CGPoint(x: -1920, y: 1080),
                vendorID: 4268,
                modelNumber: 17016,
                serialNumber: 1162891852,
                displayUUID: "2955E849-4C6D-4BD2-B37B-4C8FEC738AAB"
            ),
            makeScreen(
                displayID: 7,
                name: "DELL U2720Q (1)",
                origin: CGPoint(x: -1920, y: 0),
                vendorID: 4268,
                modelNumber: 16821,
                serialNumber: 1110790732,
                displayUUID: "17BEF206-07DD-473A-9165-D1285CBF5FD4"
            ),
            makeScreen(
                displayID: 3,
                name: "DELL U2720Q (2)",
                origin: CGPoint(x: 0, y: 0),
                vendorID: 4268,
                modelNumber: 16821,
                serialNumber: 1163084364,
                displayUUID: "21FB5EBF-E01B-4A5B-8171-9915A40BE682",
                isPrimary: true
            )
        ]

        let mappings = ScreenMismatchDetector.suggestMappings(
            savedScreens: savedScreens,
            currentScreens: currentScreens
        )

        #expect(mappings == [
            ScreenMappingInfo(savedIndex: 0, currentIndex: 1, matchKind: .displayID),
            ScreenMappingInfo(savedIndex: 1, currentIndex: 0, matchKind: .displayID),
            ScreenMappingInfo(savedIndex: 2, currentIndex: 2, matchKind: .displayID)
        ])
    }

    @Test("Exact fingerprint matches can skip review even when topology changes")
    func exactFingerprintMatchStaysAutomatic() {
        let savedScreens = [
            WorkspaceScreen(from: makeScreen(
                displayID: 4,
                name: "Studio Display",
                origin: CGPoint(x: 0, y: 1080),
                vendorID: 4268,
                modelNumber: 16821,
                serialNumber: 1110790732,
                displayUUID: "AAAA",
                isPrimary: true
            ))
        ]

        let workspace = Workspace(name: "Trusted", workspaceWindows: [], screens: savedScreens)
        let currentScreens = [
            makeScreen(
                displayID: 99,
                name: "Studio Display",
                origin: CGPoint(x: 0, y: 0),
                vendorID: 4268,
                modelNumber: 16821,
                serialNumber: 1110790732,
                displayUUID: "BBBB",
                isPrimary: true
            )
        ]

        let analysis = ScreenMismatchDetector.analyze(workspace: workspace, currentScreens: currentScreens)

        #expect(analysis.hasTopologyChange)
        #expect(!analysis.hasLowConfidenceMappings)
        #expect(!analysis.requiresUserSelection)
    }

    private func makeScreen(
        displayID: Int,
        name: String,
        origin: CGPoint,
        vendorID: Int,
        modelNumber: Int,
        serialNumber: Int?,
        displayUUID: String?,
        isPrimary: Bool = false
    ) -> FullScreenInfo {
        let frame = CGRect(x: origin.x, y: origin.y, width: 1920, height: 1080)
        let provider = MockScreenProvider(
            frame: frame,
            visibleFrame: frame,
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
