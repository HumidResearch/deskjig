//
//  WorkspaceDisplayResolutionTests.swift
//  DeskJigSharedTests
//

import Testing
import CoreGraphics
@testable import DeskJigShared

struct WorkspaceDisplayResolutionTests {

    @Test("Legacy workspace normalizes into sorted display slots and slot-bound windows")
    func normalizeWorkspaceMigratesLegacyGeometryIntoDisplaySlots() throws {
        let lower = WorkspaceScreen(
            displayID: 7,
            name: "Lower",
            resolution: CGSize(width: 3840, height: 2160),
            frame: CGRect(x: -1920, y: 0, width: 1920, height: 1080),
            visibleFrame: CGRect(x: -1920, y: 0, width: 1920, height: 1050),
            isPrimary: false
        )
        let upper = WorkspaceScreen(
            displayID: 5,
            name: "Upper",
            resolution: CGSize(width: 3840, height: 2160),
            frame: CGRect(x: -1920, y: 1080, width: 1920, height: 1080),
            visibleFrame: CGRect(x: -1920, y: 1080, width: 1920, height: 1050),
            isPrimary: false
        )
        let right = WorkspaceScreen(
            displayID: 3,
            name: "Right",
            resolution: CGSize(width: 3840, height: 2160),
            frame: CGRect(x: 0, y: 0, width: 1920, height: 1080),
            visibleFrame: CGRect(x: 0, y: 0, width: 1920, height: 1050),
            isPrimary: true
        )

        let workspace = Workspace(
            name: "macDev",
            workspaceWindows: [
                WorkspaceWindow(
                    id: UUID(),
                    bundleIdentifier: "com.example.lower",
                    appName: "Lower App",
                    windowTitle: "Lower",
                    screenIndex: 0,
                    relativeFrame: RelativeWindowFrame(xPercent: 0, yPercent: 0, widthPercent: 0.3, heightPercent: 1)
                ),
                WorkspaceWindow(
                    id: UUID(),
                    bundleIdentifier: "com.example.upper",
                    appName: "Upper App",
                    windowTitle: "Upper",
                    screenIndex: 1,
                    relativeFrame: RelativeWindowFrame(xPercent: 0, yPercent: 0, widthPercent: 0.5, heightPercent: 1)
                ),
                WorkspaceWindow(
                    id: UUID(),
                    bundleIdentifier: "com.example.right",
                    appName: "Right App",
                    windowTitle: "Right",
                    screenIndex: 2,
                    relativeFrame: RelativeWindowFrame(xPercent: 0, yPercent: 0, widthPercent: 0.5, heightPercent: 1)
                )
            ],
            screens: [lower, upper, right]
        )

        let normalized = try WorkspaceDisplayResolutionService.normalizeWorkspace(workspace)

        #expect(normalized.displaySlots?.map(\.displayID) == [5, 7, 3])
        #expect(normalized.screens?.map(\.displayID) == [5, 7, 3])
        #expect(normalized.windows.map(\.screenIndex) == [1, 0, 2])
        #expect(normalized.windows.allSatisfy { $0.displaySlotID != nil })
    }

    @Test("Prepare restore rejects invalid legacy screen index")
    func prepareRestoreRejectsInvalidLegacyScreenIndex() {
        let workspace = Workspace(
            name: "Broken",
            workspaceWindows: [
                WorkspaceWindow(
                    bundleIdentifier: "com.example.app",
                    appName: "App",
                    windowTitle: "App",
                    screenIndex: 4,
                    relativeFrame: RelativeWindowFrame(xPercent: 0, yPercent: 0, widthPercent: 1, heightPercent: 1)
                )
            ],
            screens: [
                WorkspaceScreen(
                    displayID: 1,
                    name: "Only",
                    resolution: CGSize(width: 1920, height: 1080),
                    frame: CGRect(x: 0, y: 0, width: 1920, height: 1080),
                    visibleFrame: CGRect(x: 0, y: 0, width: 1920, height: 1050),
                    isPrimary: true
                )
            ]
        )

        do {
            _ = try WorkspaceDisplayResolutionService.prepare(
                workspace: workspace,
                currentScreens: [makeScreen(displayID: 1, origin: CGPoint(x: 0, y: 0), isPrimary: true)],
                mode: .nonInteractive
            )
            Issue.record("Expected invalid workspace error")
        } catch let error as RestorationError {
            switch error {
            case .invalidWorkspace(let message):
                #expect(message.contains("invalid legacy screenIndex"))
            default:
                Issue.record("Unexpected error: \(error.localizedDescription)")
            }
        } catch {
            Issue.record("Unexpected error: \(error.localizedDescription)")
        }
    }

    @Test("Prepare restore is ready when geometry matches even if current screen list arrives in different order")
    func prepareRestoreUsesGeometryRatherThanIncomingScreenOrdering() throws {
        let workspace = try WorkspaceDisplayResolutionService.normalizeWorkspace(
            Workspace(
                name: "macDev",
                workspaceWindows: [
                    WorkspaceWindow(
                        bundleIdentifier: "com.example.lower",
                        appName: "Lower App",
                        windowTitle: "Lower",
                        screenIndex: 0,
                        relativeFrame: RelativeWindowFrame(xPercent: 0, yPercent: 0, widthPercent: 0.5, heightPercent: 1)
                    ),
                    WorkspaceWindow(
                        bundleIdentifier: "com.example.upper",
                        appName: "Upper App",
                        windowTitle: "Upper",
                        screenIndex: 1,
                        relativeFrame: RelativeWindowFrame(xPercent: 0, yPercent: 0, widthPercent: 0.5, heightPercent: 1)
                    ),
                    WorkspaceWindow(
                        bundleIdentifier: "com.example.right",
                        appName: "Right App",
                        windowTitle: "Right",
                        screenIndex: 2,
                        relativeFrame: RelativeWindowFrame(xPercent: 0, yPercent: 0, widthPercent: 0.5, heightPercent: 1)
                    )
                ],
                screens: [
                    WorkspaceScreen(from: makeScreen(displayID: 7, origin: CGPoint(x: -1920, y: 0))),
                    WorkspaceScreen(from: makeScreen(displayID: 5, origin: CGPoint(x: -1920, y: 1080))),
                    WorkspaceScreen(from: makeScreen(displayID: 3, origin: CGPoint(x: 0, y: 0), isPrimary: true))
                ]
            )
        )

        let result = try WorkspaceDisplayResolutionService.prepare(
            workspace: workspace,
            currentScreens: [
                makeScreen(displayID: 7, origin: CGPoint(x: -1920, y: 0)),
                makeScreen(displayID: 3, origin: CGPoint(x: 0, y: 0), isPrimary: true),
                makeScreen(displayID: 5, origin: CGPoint(x: -1920, y: 1080))
            ],
            mode: .nonInteractive
        )

        guard case .ready(let context) = result else {
            Issue.record("Expected ready restore context")
            return
        }

        let orderedDisplayIDs = context.currentScreens.map(\.displayID)
        #expect(orderedDisplayIDs == [5, 7, 3])
        #expect(context.assignments.map(\.displayID) == [5, 7, 3])
        #expect(context.resolvedWorkspace.windows.map(\.screenIndex) == [1, 0, 2])
    }

    @Test("Prepare restore requires assignment in interactive mode when topology changed")
    func prepareRestoreRequiresAssignmentForTopologyChange() throws {
        let workspace = try WorkspaceDisplayResolutionService.normalizeWorkspace(
            Workspace(
                name: "Topology",
                workspaceWindows: [
                    WorkspaceWindow(
                        bundleIdentifier: "com.example.left",
                        appName: "Left",
                        windowTitle: "Left",
                        screenIndex: 0,
                        relativeFrame: RelativeWindowFrame(xPercent: 0, yPercent: 0, widthPercent: 1, heightPercent: 1)
                    ),
                    WorkspaceWindow(
                        bundleIdentifier: "com.example.right",
                        appName: "Right",
                        windowTitle: "Right",
                        screenIndex: 1,
                        relativeFrame: RelativeWindowFrame(xPercent: 0, yPercent: 0, widthPercent: 1, heightPercent: 1)
                    )
                ],
                screens: [
                    WorkspaceScreen(from: makeScreen(displayID: 1, origin: CGPoint(x: 0, y: 0), isPrimary: true)),
                    WorkspaceScreen(from: makeScreen(displayID: 2, origin: CGPoint(x: 1920, y: 0)))
                ]
            )
        )

        // The current displays are unrecognized hardware (different display IDs
        // and non-matching fingerprints): confident identity matches (displayID
        // or fingerprint) intentionally bypass the prompt even when the
        // arrangement changed, so the prompt path requires unconfident identity.
        let result = try WorkspaceDisplayResolutionService.prepare(
            workspace: workspace,
            currentScreens: [
                makeScreen(displayID: 10, origin: CGPoint(x: 0, y: 1080), isPrimary: true),
                makeScreen(displayID: 20, origin: CGPoint(x: 0, y: 0))
            ],
            mode: .interactive
        )

        guard case .requiresAssignment(let prompt) = result else {
            Issue.record("Expected assignment prompt")
            return
        }

        #expect(prompt.analysis.hasTopologyChange)
        #expect(prompt.currentScreens.count == 2)
        #expect(prompt.suggestedAssignments.count == 2)
    }

    @Test("Prepare restore proceeds without prompting when display IDs match despite topology change")
    func prepareRestoreProceedsWithoutPromptWhenDisplayIDsMatchDespiteTopologyChange() throws {
        let workspace = try WorkspaceDisplayResolutionService.normalizeWorkspace(
            Workspace(
                name: "Topology",
                workspaceWindows: [
                    WorkspaceWindow(
                        bundleIdentifier: "com.example.left",
                        appName: "Left",
                        windowTitle: "Left",
                        screenIndex: 0,
                        relativeFrame: RelativeWindowFrame(xPercent: 0, yPercent: 0, widthPercent: 1, heightPercent: 1)
                    ),
                    WorkspaceWindow(
                        bundleIdentifier: "com.example.right",
                        appName: "Right",
                        windowTitle: "Right",
                        screenIndex: 1,
                        relativeFrame: RelativeWindowFrame(xPercent: 0, yPercent: 0, widthPercent: 1, heightPercent: 1)
                    )
                ],
                screens: [
                    WorkspaceScreen(from: makeScreen(displayID: 1, origin: CGPoint(x: 0, y: 0), isPrimary: true)),
                    WorkspaceScreen(from: makeScreen(displayID: 2, origin: CGPoint(x: 1920, y: 0)))
                ]
            )
        )

        // Same physical monitors (identical display IDs), rearranged from
        // side-by-side to stacked. Confidently identified monitors restore
        // without an assignment prompt even though the topology changed.
        let result = try WorkspaceDisplayResolutionService.prepare(
            workspace: workspace,
            currentScreens: [
                makeScreen(displayID: 1, origin: CGPoint(x: 0, y: 1080), isPrimary: true),
                makeScreen(displayID: 2, origin: CGPoint(x: 0, y: 0))
            ],
            mode: .nonInteractive
        )

        guard case .ready(let context) = result else {
            Issue.record("Expected ready restore context")
            return
        }

        #expect(context.assignments.map(\.displayID) == [1, 2])
    }

    @Test("Assignment prompt converts selected mappings into slot-based display assignments")
    func assignmentPromptConvertsMappingsToDisplayAssignments() throws {
        let workspace = try WorkspaceDisplayResolutionService.normalizeWorkspace(
            Workspace(
                name: "Topology",
                workspaceWindows: [
                    WorkspaceWindow(
                        bundleIdentifier: "com.example.left",
                        appName: "Left",
                        windowTitle: "Left",
                        screenIndex: 0,
                        relativeFrame: RelativeWindowFrame(xPercent: 0, yPercent: 0, widthPercent: 1, heightPercent: 1)
                    ),
                    WorkspaceWindow(
                        bundleIdentifier: "com.example.right",
                        appName: "Right",
                        windowTitle: "Right",
                        screenIndex: 1,
                        relativeFrame: RelativeWindowFrame(xPercent: 0, yPercent: 0, widthPercent: 1, heightPercent: 1)
                    )
                ],
                screens: [
                    WorkspaceScreen(from: makeScreen(displayID: 1, origin: CGPoint(x: 0, y: 0), isPrimary: true)),
                    WorkspaceScreen(from: makeScreen(displayID: 2, origin: CGPoint(x: 1920, y: 0)))
                ]
            )
        )

        let result = try WorkspaceDisplayResolutionService.prepare(
            workspace: workspace,
            currentScreens: [
                makeScreen(displayID: 10, origin: CGPoint(x: 0, y: 1080), isPrimary: true),
                makeScreen(displayID: 20, origin: CGPoint(x: 0, y: 0))
            ],
            mode: .interactive
        )

        guard case .requiresAssignment(let prompt) = result else {
            Issue.record("Expected assignment prompt")
            return
        }

        let assignments = prompt.displayAssignments(from: [
            ScreenMappingInfo(savedIndex: 0, currentIndex: 1, matchKind: .geometry),
            ScreenMappingInfo(savedIndex: 1, currentIndex: 0, matchKind: .geometry)
        ])

        #expect(assignments == [
            WorkspaceDisplayAssignment(slotID: prompt.orderedSlotIDs[0], displayID: 20),
            WorkspaceDisplayAssignment(slotID: prompt.orderedSlotIDs[1], displayID: 10)
        ])
    }

    @Test("Prepare restore fails fast in non-interactive mode when topology changed")
    func prepareRestoreFailsFastInNonInteractiveModeForTopologyChange() throws {
        let workspace = try WorkspaceDisplayResolutionService.normalizeWorkspace(
            Workspace(
                name: "Topology",
                workspaceWindows: [
                    WorkspaceWindow(
                        bundleIdentifier: "com.example.left",
                        appName: "Left",
                        windowTitle: "Left",
                        screenIndex: 0,
                        relativeFrame: RelativeWindowFrame(xPercent: 0, yPercent: 0, widthPercent: 1, heightPercent: 1)
                    )
                ],
                screens: [
                    WorkspaceScreen(from: makeScreen(displayID: 1, origin: CGPoint(x: 0, y: 0), isPrimary: true))
                ]
            )
        )

        do {
            // Unrecognized display hardware (different display ID and
            // non-matching fingerprint) at a shifted position: without a
            // confident identity match, a topology change must fail fast in
            // non-interactive mode instead of guessing an assignment.
            _ = try WorkspaceDisplayResolutionService.prepare(
                workspace: workspace,
                currentScreens: [
                    makeScreen(displayID: 99, origin: CGPoint(x: 0, y: 1080), isPrimary: true)
                ],
                mode: .nonInteractive
            )
            Issue.record("Expected assignment required error")
        } catch let error as RestorationError {
            switch error {
            case .assignmentRequired(let message):
                #expect(message.contains("requires explicit slot assignment"))
            default:
                Issue.record("Unexpected error: \(error.localizedDescription)")
            }
        } catch {
            Issue.record("Unexpected error: \(error.localizedDescription)")
        }
    }

    @Test("Prepare restore backfills fingerprints for legacy same-count monitor ID churn")
    func prepareRestoreBackfillsFingerprintsForLegacyFourDisplayWorkspace() throws {
        let savedScreens = [
            WorkspaceScreen(
                displayID: 2,
                name: "DELL U2723QE",
                resolution: CGSize(width: 3840, height: 2160),
                frame: CGRect(x: -1920, y: 1080, width: 1920, height: 1080),
                visibleFrame: CGRect(x: -1920, y: 1080, width: 1920, height: 1050),
                isPrimary: false,
                displayFingerprint: nil
            ),
            WorkspaceScreen(
                displayID: 4,
                name: "DELL U2720Q (1)",
                resolution: CGSize(width: 3840, height: 2160),
                frame: CGRect(x: -1920, y: 0, width: 1920, height: 1080),
                visibleFrame: CGRect(x: -1920, y: 0, width: 1920, height: 1050),
                isPrimary: false,
                displayFingerprint: nil
            ),
            WorkspaceScreen(
                displayID: 5,
                name: "DELL U2725QE",
                resolution: CGSize(width: 3840, height: 2160),
                frame: CGRect(x: 0, y: 1080, width: 1920, height: 1080),
                visibleFrame: CGRect(x: 0, y: 1080, width: 1920, height: 1050),
                isPrimary: false,
                displayFingerprint: nil
            ),
            WorkspaceScreen(
                displayID: 6,
                name: "DELL U2720Q (2)",
                resolution: CGSize(width: 3840, height: 2160),
                frame: CGRect(x: 0, y: 0, width: 1920, height: 1080),
                visibleFrame: CGRect(x: 0, y: 0, width: 1920, height: 1050),
                isPrimary: true,
                displayFingerprint: nil
            )
        ]

        let workspace = try WorkspaceDisplayResolutionService.normalizeWorkspace(
            Workspace(
                name: "Writing",
                workspaceWindows: [
                    WorkspaceWindow(
                        bundleIdentifier: "com.example.chrome",
                        appName: "Chrome",
                        windowTitle: "Chrome",
                        screenIndex: 0,
                        relativeFrame: RelativeWindowFrame(xPercent: 0, yPercent: 0, widthPercent: 1, heightPercent: 1)
                    )
                ],
                screens: savedScreens
            )
        )

        let currentScreens = [
            makeScreen(
                displayID: 7,
                name: "DELL U2723QE",
                origin: CGPoint(x: -1920, y: 1080),
                vendorID: 4268,
                modelNumber: 17016,
                serialNumber: 1162891852,
                displayUUID: "2955E849-4C6D-4BD2-B37B-4C8FEC738AAB"
            ),
            makeScreen(
                displayID: 4,
                name: "DELL U2720Q (1)",
                origin: CGPoint(x: -1920, y: 0),
                vendorID: 4268,
                modelNumber: 16821,
                serialNumber: 1110790732,
                displayUUID: "17BEF206-07DD-473A-9165-D1285CBF5FD4"
            ),
            makeScreen(
                displayID: 3,
                name: "DELL U2725QE",
                origin: CGPoint(x: 0, y: 1080),
                vendorID: 4268,
                modelNumber: 17157,
                serialNumber: 1163084365,
                displayUUID: "A1FB5EBF-E01B-4A5B-8171-9915A40BE683"
            ),
            makeScreen(
                displayID: 6,
                name: "DELL U2720Q (2)",
                origin: CGPoint(x: 0, y: 0),
                vendorID: 4268,
                modelNumber: 16821,
                serialNumber: 1163084364,
                displayUUID: "21FB5EBF-E01B-4A5B-8171-9915A40BE682",
                isPrimary: true
            )
        ]

        let result = try WorkspaceDisplayResolutionService.prepare(
            workspace: workspace,
            currentScreens: currentScreens,
            mode: .interactive
        )

        guard case .ready(let context) = result else {
            Issue.record("Expected ready restore context")
            return
        }

        #expect(context.assignments.map(\.displayID) == [7, 4, 3, 6])
        #expect(context.normalizedWorkspace.screens?.allSatisfy { $0.displayFingerprint != nil } == true)
    }

    @Test("Prepare restore still requires assignment for ambiguous duplicate legacy monitors")
    func prepareRestoreRequiresAssignmentForAmbiguousLegacyDuplicateDisplays() throws {
        let savedScreens = [
            WorkspaceScreen(
                displayID: 10,
                name: "Studio Display",
                resolution: CGSize(width: 3840, height: 2160),
                frame: CGRect(x: 0, y: 0, width: 1920, height: 1080),
                visibleFrame: CGRect(x: 0, y: 0, width: 1920, height: 1050),
                isPrimary: true,
                displayFingerprint: nil
            ),
            WorkspaceScreen(
                displayID: 11,
                name: "Studio Display",
                resolution: CGSize(width: 3840, height: 2160),
                frame: CGRect(x: 0, y: 0, width: 1920, height: 1080),
                visibleFrame: CGRect(x: 0, y: 0, width: 1920, height: 1050),
                isPrimary: false,
                displayFingerprint: nil
            )
        ]

        let workspace = try WorkspaceDisplayResolutionService.normalizeWorkspace(
            Workspace(
                name: "Ambiguous",
                workspaceWindows: [
                    WorkspaceWindow(
                        bundleIdentifier: "com.example.left",
                        appName: "Left",
                        windowTitle: "Left",
                        screenIndex: 0,
                        relativeFrame: RelativeWindowFrame(xPercent: 0, yPercent: 0, widthPercent: 1, heightPercent: 1)
                    ),
                    WorkspaceWindow(
                        bundleIdentifier: "com.example.right",
                        appName: "Right",
                        windowTitle: "Right",
                        screenIndex: 1,
                        relativeFrame: RelativeWindowFrame(xPercent: 0, yPercent: 0, widthPercent: 1, heightPercent: 1)
                    )
                ],
                screens: savedScreens
            )
        )

        let currentScreens = [
            makeScreen(
                displayID: 20,
                name: "Studio Display",
                origin: CGPoint(x: 0, y: 0),
                vendorID: 4268,
                modelNumber: 16821,
                serialNumber: nil,
                displayUUID: nil,
                isPrimary: true
            ),
            makeScreen(
                displayID: 21,
                name: "Studio Display",
                origin: CGPoint(x: 0, y: 0),
                vendorID: 4268,
                modelNumber: 16821,
                serialNumber: nil,
                displayUUID: nil
            )
        ]

        let result = try WorkspaceDisplayResolutionService.prepare(
            workspace: workspace,
            currentScreens: currentScreens,
            mode: .interactive
        )

        guard case .requiresAssignment(let prompt) = result else {
            Issue.record("Expected assignment prompt")
            return
        }

        #expect(prompt.analysis.hasLowConfidenceMappings)
        #expect(prompt.analysis.requiresUserSelection)
    }

    @Test("Prepare restore is ready when saved fingerprints match despite changed display IDs")
    func prepareRestoreSkipsAssignmentForFingerprintMatchedDisplayIDChurn() throws {
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

        let workspace = try WorkspaceDisplayResolutionService.normalizeWorkspace(
            Workspace(
                name: "Trusted",
                workspaceWindows: [
                    WorkspaceWindow(
                        bundleIdentifier: "com.example.app",
                        appName: "App",
                        windowTitle: "App",
                        screenIndex: 0,
                        relativeFrame: RelativeWindowFrame(xPercent: 0, yPercent: 0, widthPercent: 1, heightPercent: 1)
                    )
                ],
                screens: savedScreens
            )
        )

        let result = try WorkspaceDisplayResolutionService.prepare(
            workspace: workspace,
            currentScreens: [
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
            ],
            mode: .interactive
        )

        guard case .ready(let context) = result else {
            Issue.record("Expected ready restore context")
            return
        }

        #expect(context.assignments.map(\.displayID) == [99])
        #expect(context.normalizedWorkspace.screens?.first?.displayFingerprint != nil)
    }

    @Test("Prepare restore produces persistable display identity after explicit assignments")
    func prepareRestorePersistsResolvedIdentityForExplicitAssignments() throws {
        let workspace = try WorkspaceDisplayResolutionService.normalizeWorkspace(
            Workspace(
                name: "Topology",
                workspaceWindows: [
                    WorkspaceWindow(
                        bundleIdentifier: "com.example.left",
                        appName: "Left",
                        windowTitle: "Left",
                        screenIndex: 0,
                        relativeFrame: RelativeWindowFrame(xPercent: 0, yPercent: 0, widthPercent: 1, heightPercent: 1)
                    ),
                    WorkspaceWindow(
                        bundleIdentifier: "com.example.right",
                        appName: "Right",
                        windowTitle: "Right",
                        screenIndex: 1,
                        relativeFrame: RelativeWindowFrame(xPercent: 0, yPercent: 0, widthPercent: 1, heightPercent: 1)
                    )
                ],
                screens: [
                    WorkspaceScreen(from: makeScreen(displayID: 1, name: "Display 1", origin: CGPoint(x: 0, y: 0), isPrimary: true)),
                    WorkspaceScreen(from: makeScreen(displayID: 2, name: "Display 2", origin: CGPoint(x: 1920, y: 0)))
                ]
            )
        )

        let currentScreens = [
            makeScreen(displayID: 10, name: "Display 1", origin: CGPoint(x: 0, y: 1080), isPrimary: true),
            makeScreen(displayID: 20, name: "Display 2", origin: CGPoint(x: 0, y: 0))
        ]

        let displayAssignments = [
            WorkspaceDisplayAssignment(slotID: workspace.displaySlots![0].id, displayID: 10),
            WorkspaceDisplayAssignment(slotID: workspace.displaySlots![1].id, displayID: 20)
        ]

        let result = try WorkspaceDisplayResolutionService.prepare(
            workspace: workspace,
            currentScreens: currentScreens,
            mode: .nonInteractive,
            explicitAssignments: displayAssignments
        )

        guard case .ready(let context) = result else {
            Issue.record("Expected ready restore context")
            return
        }

        #expect(context.resolvedDisplayIdentity.trustedAssignments == displayAssignments)
        #expect(context.resolvedDisplayIdentity.shouldPersistUpdatedIdentity)
        #expect(context.resolvedDisplayIdentity.displaySlots.map { $0.displayID } == [10, 20])
    }

    private func makeScreen(
        displayID: Int,
        name: String? = nil,
        origin: CGPoint,
        resolution: CGSize = CGSize(width: 3840, height: 2160),
        vendorID: Int = 4268,
        modelNumber: Int = 16821,
        serialNumber: Int? = nil,
        displayUUID: String? = nil,
        isPrimary: Bool = false
    ) -> FullScreenInfo {
        let frame = CGRect(x: origin.x, y: origin.y, width: 1920, height: 1080)
        let provider = MockScreenProvider(
            frame: frame,
            visibleFrame: CGRect(x: origin.x, y: origin.y, width: 1920, height: 1050),
            backingScaleFactor: resolution.width / frame.width,
            isPrimary: isPrimary,
            displayID: displayID,
            displayName: name ?? "Display \(displayID)",
            vendorID: vendorID,
            modelNumber: modelNumber,
            serialNumber: serialNumber ?? displayID * 111,
            displayUUID: displayUUID ?? "DISPLAY-\(displayID)"
        )
        return FullScreenInfo(screenProvider: provider)
    }
}
