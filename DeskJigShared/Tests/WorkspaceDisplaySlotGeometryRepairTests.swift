//
//  WorkspaceDisplaySlotGeometryRepairTests.swift
//  DeskJigSharedTests
//
//  GH #566: workspaces persisted with neither `displaySlots` nor `screens`
//  ("flattened" documents, e.g. "mainDev" / "Copy of mainDev") used to fail
//  restore normalization with "has no display slot geometry" and no
//  user-facing signal. These tests pin the two halves of the fix:
//
//  * Loader repair: restore-path normalization synthesizes placeholder display
//    slots from the windows' saved `screenIndex` values (defaulting to a single
//    slot) instead of throwing, while the persistence path stays strict so
//    flattened documents remain eligible for richer-copy healing.
//  * Writer guard: `Workspace.encode(to:)` always persists `screens` alongside
//    `displaySlots`, so a reader that drops the `displaySlots` key can no
//    longer round-trip a workspace into a geometry-less document.
//

import CoreGraphics
import Foundation
import Testing
@testable import DeskJigShared

struct WorkspaceDisplaySlotGeometryRepairTests {

    // MARK: - Helpers

    private func makeWindow(
        bundleIdentifier: String = "com.example.app",
        appName: String = "App",
        windowTitle: String = "Window",
        screenIndex: Int? = nil,
        relativeFrame: RelativeWindowFrame = RelativeWindowFrame(xPercent: 0, yPercent: 0, widthPercent: 0.5, heightPercent: 1)
    ) -> WorkspaceWindow {
        WorkspaceWindow(
            bundleIdentifier: bundleIdentifier,
            appName: appName,
            windowTitle: windowTitle,
            screenIndex: screenIndex,
            relativeFrame: relativeFrame
        )
    }

    /// A workspace persisted with neither `displaySlots` nor `screens`.
    private func makeFlattenedWorkspace(windows: [WorkspaceWindow]) -> Workspace {
        Workspace(
            name: "mainDev",
            workspaceWindows: windows,
            displaySlots: nil,
            screens: nil
        )
    }

    private func makeCurrentScreen(displayID: Int, isPrimary: Bool = true) -> FullScreenInfo {
        let provider = MockScreenProvider(
            frame: CGRect(x: 0, y: 0, width: 1920, height: 1080),
            visibleFrame: CGRect(x: 0, y: 0, width: 1920, height: 1050),
            backingScaleFactor: 2,
            isPrimary: isPrimary,
            displayID: displayID,
            displayName: "Display \(displayID)",
            vendorID: 4268,
            modelNumber: 16821,
            serialNumber: displayID * 111,
            displayUUID: "DISPLAY-\(displayID)"
        )
        return FullScreenInfo(screenProvider: provider)
    }

    // MARK: - Loader: strict persistence normalization is unchanged

    @Test("Strict normalization still rejects a workspace without display slot geometry")
    func strictNormalizationRejectsMissingGeometry() {
        let workspace = makeFlattenedWorkspace(windows: [makeWindow(screenIndex: 0)])

        do {
            _ = try WorkspaceDisplayResolutionService.normalizeWorkspace(workspace)
            Issue.record("Expected invalid workspace error")
        } catch let error as RestorationError {
            switch error {
            case .invalidWorkspace(let message):
                #expect(message.contains("has no display slot geometry"))
            default:
                Issue.record("Unexpected error: \(error.localizedDescription)")
            }
        } catch {
            Issue.record("Unexpected error: \(error.localizedDescription)")
        }
    }

    // MARK: - Loader: restore-path repair

    @Test("Repair synthesizes one placeholder slot per saved screen index")
    func repairSynthesizesSlotsFromWindowScreenIndices() throws {
        let workspace = makeFlattenedWorkspace(windows: [
            makeWindow(appName: "Editor", windowTitle: "Editor", screenIndex: 0),
            makeWindow(appName: "Terminal", windowTitle: "Terminal", screenIndex: 1),
            makeWindow(appName: "Browser", windowTitle: "Browser", screenIndex: 1)
        ])

        let repaired = try WorkspaceDisplayResolutionService.normalizeWorkspace(
            workspace,
            repairPolicy: .synthesizeMissingGeometry
        )

        let slots = try #require(repaired.displaySlots)
        #expect(slots.count == 2)
        // Placeholder identity: negative display IDs so they can never collide
        // with (or spuriously fingerprint-match) a real display.
        #expect(slots.map(\.displayID) == [-1, -2])
        #expect(slots.first?.isPrimary == true)
        #expect(repaired.screens?.count == 2)

        // Windows are bound to the synthesized slots and keep their screen split.
        #expect(repaired.windows.map(\.screenIndex) == [0, 1, 1])
        #expect(repaired.windows.allSatisfy { $0.displaySlotID != nil })
        let slotIDs = Set(slots.map(\.id))
        #expect(repaired.windows.allSatisfy { slotIDs.contains($0.displaySlotID!) })
    }

    @Test("Repair defaults windows without any screen mapping to a single synthetic slot")
    func repairDefaultsFullyFlattenedWindowsToSingleSlot() throws {
        let workspace = makeFlattenedWorkspace(windows: [
            makeWindow(appName: "Editor", windowTitle: "Editor", screenIndex: nil),
            makeWindow(appName: "Terminal", windowTitle: "Terminal", screenIndex: nil)
        ])

        let repaired = try WorkspaceDisplayResolutionService.normalizeWorkspace(
            workspace,
            repairPolicy: .synthesizeMissingGeometry
        )

        let slots = try #require(repaired.displaySlots)
        #expect(slots.count == 1)
        #expect(repaired.windows.map(\.screenIndex) == [0, 0])
        #expect(repaired.windows.allSatisfy { $0.displaySlotID == slots.first?.id })
    }

    @Test("Restore preparation no longer fails with invalidWorkspace for a flattened workspace")
    func prepareProceedsForFlattenedWorkspace() throws {
        let workspace = makeFlattenedWorkspace(windows: [
            makeWindow(appName: "Editor", windowTitle: "Editor", screenIndex: 0)
        ])

        // Interactive preparation must either resolve or ask the user to assign
        // displays - both are graceful; the old behavior was an
        // `invalidWorkspace("... has no display slot geometry")` throw that the
        // UI swallowed silently.
        let result = try WorkspaceDisplayResolutionService.prepare(
            workspace: workspace,
            currentScreens: [makeCurrentScreen(displayID: 1)],
            mode: .interactive
        )

        switch result {
        case .ready(let context):
            #expect(context.normalizedWorkspace.displaySlots?.isEmpty == false)
        case .requiresAssignment(let prompt):
            #expect(prompt.normalizedWorkspace.displaySlots?.isEmpty == false)
            #expect(prompt.orderedSlotIDs.count == 1)
        }
    }

    // MARK: - Writer guard: screens always persisted alongside displaySlots

    @Test("Encoding persists screens alongside displaySlots")
    func encodingPersistsScreensAlongsideDisplaySlots() throws {
        let slot = WorkspaceDisplaySlot(
            id: UUID(),
            title: "Main",
            displayID: 1,
            displayName: "Built-in Display",
            resolution: CGSize(width: 2560, height: 1440),
            arrangementFrame: CGRect(x: 0, y: 0, width: 2560, height: 1440),
            visibleFrame: CGRect(x: 0, y: 0, width: 2560, height: 1400),
            isPrimary: true
        )
        let workspace = Workspace(
            name: "Slots Workspace",
            workspaceWindows: [makeWindow(screenIndex: 0)],
            displaySlots: [slot]
        )

        let data = try JSONEncoder().encode(workspace)
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])

        #expect(json["displaySlots"] != nil)
        #expect(json["screens"] != nil, "screens must be persisted alongside displaySlots so a displaySlots-dropping reader cannot lose all geometry")
    }

    @Test("A reader that drops displaySlots can no longer produce a geometry-less document")
    func displaySlotsDroppingRoundTripKeepsRestorableGeometry() throws {
        let slot = WorkspaceDisplaySlot(
            id: UUID(),
            title: "Main",
            displayID: 1,
            displayName: "Built-in Display",
            resolution: CGSize(width: 2560, height: 1440),
            arrangementFrame: CGRect(x: 0, y: 0, width: 2560, height: 1440),
            visibleFrame: CGRect(x: 0, y: 0, width: 2560, height: 1400),
            isPrimary: true
        )
        let workspace = Workspace(
            name: "Slots Workspace",
            workspaceWindows: [makeWindow(screenIndex: 0)],
            displaySlots: [slot]
        )

        // Simulate the historical field-drop vector: a consumer (e.g. an older
        // app build whose model predates `displaySlots`) re-persists the
        // document without the `displaySlots` key.
        let data = try JSONEncoder().encode(workspace)
        var json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        json.removeValue(forKey: "displaySlots")
        let strippedData = try JSONSerialization.data(withJSONObject: json)

        let decoded = try JSONDecoder().decode(Workspace.self, from: strippedData)
        #expect(decoded.displaySlots == nil)
        #expect(decoded.screens?.isEmpty == false)
        #expect(decoded.isDisplayMetadataFlattened == false)

        // The surviving `screens` keep the document restorable through the
        // strict (persistence) normalization path - no repair required.
        let normalized = try WorkspaceDisplayResolutionService.normalizeWorkspace(decoded)
        #expect(normalized.displaySlots?.isEmpty == false)
        #expect(normalized.windows.allSatisfy { $0.displaySlotID != nil })
    }
}
