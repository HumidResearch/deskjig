//  WorkspaceStorageServiceTests.swift
//  DeskJigSharedTests

import Foundation
import Testing
import CoreGraphics
@testable import DeskJigShared

struct WorkspaceStorageServiceTests {

    /// A `WorkspaceStorageService` bound to a throwaway `UserDefaults` suite.
    ///
    /// `WorkspaceStorageService()` defaults to the real `com.mscontrol.bento`
    /// suite, and `updateWorkspaceMetadata` / `updateWorkspaceDisplayMetadata`
    /// persist through `saveWorkspaces` — so the default init made these tests
    /// overwrite the developer's own saved workspaces with a fixture. Every case
    /// below writes into a scratch domain instead.
    private static func makeScratchService() throws -> (service: WorkspaceStorageService, teardown: () -> Void) {
        let suiteName = "com.mscontrol.bento.tests.storage-service.\(UUID().uuidString)"
        #expect(suiteName != BundleIdentity.defaultsSuiteName)
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        return (
            WorkspaceStorageService(defaults: defaults),
            { defaults.removePersistentDomain(forName: suiteName) }
        )
    }

    @Test("Workspace migration reorders stacked displays and rewrites window indices")
    func migrationReordersStackedDisplaysAndRemapsWindows() throws {
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

        let (service, teardown) = try Self.makeScratchService()
        defer { teardown() }
        let migrated = service.migrateWorkspaceScreenData(workspace)

        #expect(migrated.screens?.map(\.displayID) == [5, 7, 3])
        #expect(migrated.windows.map(\.screenIndex) == [1, 0, 2])
    }

    @Test("Display metadata update replaces screens and slots without changing windows")
    func updateWorkspaceDisplayMetadataOnlyMutatesDisplayMetadata() throws {
        let originalWindow = WorkspaceWindow(
            id: UUID(),
            bundleIdentifier: "com.example.app",
            appName: "App",
            windowTitle: "App",
            screenIndex: 0,
            relativeFrame: RelativeWindowFrame(xPercent: 0, yPercent: 0, widthPercent: 1, heightPercent: 1)
        )
        let originalWorkspace = Workspace(
            id: UUID(),
            name: "Writing",
            icon: "📝",
            workspaceWindows: [originalWindow],
            displaySlots: [
                WorkspaceDisplaySlot(
                    id: UUID(),
                    title: "Layout 1",
                    displayID: 2,
                    displayName: "DELL U2723QE",
                    resolution: CGSize(width: 3840, height: 2160),
                    arrangementFrame: CGRect(x: -1920, y: 1080, width: 1920, height: 1080),
                    visibleFrame: CGRect(x: -1920, y: 1080, width: 1920, height: 1050),
                    isPrimary: false
                )
            ],
            screens: nil
        )

        let updatedSlot = WorkspaceDisplaySlot(
            id: originalWorkspace.displaySlots![0].id,
            title: "Layout 1",
            displayID: 7,
            displayName: "DELL U2723QE",
            resolution: CGSize(width: 3840, height: 2160),
            arrangementFrame: CGRect(x: -1920, y: 1080, width: 1920, height: 1080),
            visibleFrame: CGRect(x: -1920, y: 1080, width: 1920, height: 1050),
            isPrimary: false,
            displayFingerprint: DisplayFingerprint(
                vendorID: 4268,
                modelNumber: 17016,
                serialNumber: 1162891852,
                displayUUID: "2955E849-4C6D-4BD2-B37B-4C8FEC738AAB",
                name: "DELL U2723QE",
                resolution: CGSize(width: 3840, height: 2160)
            )
        )

        let (service, teardown) = try Self.makeScratchService()
        defer { teardown() }
        let updatedWorkspaces = service.updateWorkspaceDisplayMetadata(
            workspaces: [originalWorkspace],
            workspaceID: originalWorkspace.id,
            screens: [updatedSlot.asWorkspaceScreen()],
            displaySlots: [updatedSlot]
        )

        let updatedWorkspace = updatedWorkspaces[0]
        #expect(updatedWorkspace.windows == originalWorkspace.windows)
        #expect(updatedWorkspace.name == originalWorkspace.name)
        #expect(updatedWorkspace.icon == originalWorkspace.icon)
        #expect(updatedWorkspace.displaySlots == [updatedSlot])
        #expect(updatedWorkspace.screens?.map(\.displayID) == [updatedSlot.displayID ?? -1])
        #expect(updatedWorkspace.screens?.map(\.name) == [updatedSlot.displayName])
        #expect(updatedWorkspace.screens?.first?.displayFingerprint == updatedSlot.displayFingerprint)
    }

    @Test("Display metadata update is a no-op when workspace is missing")
    func updateWorkspaceDisplayMetadataNoOpWhenWorkspaceMissing() throws {
        let workspace = Workspace(
            id: UUID(),
            name: "Writing",
            workspaceWindows: []
        )

        let (service, teardown) = try Self.makeScratchService()
        defer { teardown() }
        let updatedWorkspaces = service.updateWorkspaceDisplayMetadata(
            workspaces: [],
            workspaceID: workspace.id,
            screens: [],
            displaySlots: []
        )

        #expect(updatedWorkspaces.isEmpty)
    }

    @Test("Workspace metadata edits preserve display slots and screen assignments")
    func metadataEditsPreserveDisplayMetadata() throws {
        let slot = WorkspaceDisplaySlot(
            id: UUID(),
            title: "Monitor 1",
            displayID: 3,
            displayName: "DELL U2725QE",
            resolution: CGSize(width: 3840, height: 2160),
            arrangementFrame: CGRect(x: 0, y: 0, width: 1920, height: 1080),
            visibleFrame: CGRect(x: 0, y: 0, width: 1920, height: 1050),
            isPrimary: true
        )
        let workspace = Workspace(
            id: UUID(),
            name: "macDev",
            icon: "💻",
            workspaceWindows: [
                WorkspaceWindow(
                    id: UUID(),
                    bundleIdentifier: "com.example.xcode",
                    appName: "Xcode",
                    windowTitle: "Xcode",
                    displaySlotID: slot.id,
                    screenIndex: 0,
                    relativeFrame: RelativeWindowFrame(xPercent: 0, yPercent: 0, widthPercent: 1, heightPercent: 1)
                )
            ],
            displaySlots: [slot]
        )

        let (service, teardown) = try Self.makeScratchService()
        defer { teardown() }
        let updated = service.updateWorkspaceMetadata(
            workspaces: [workspace],
            workspace: workspace,
            newName: "macDev Updated",
            newIcon: "🛠️",
            chromeModifications: [:],
            openByPathModifications: [:],
            normalizeOpenPath: { $0 }
        )

        let updatedWorkspace = updated[0]
        #expect(updatedWorkspace.name == "macDev Updated")
        #expect(updatedWorkspace.icon == "🛠️")
        #expect(updatedWorkspace.displaySlots == workspace.displaySlots)
        #expect(updatedWorkspace.screens == workspace.screens)
        #expect(updatedWorkspace.windows.map(\.displaySlotID) == workspace.windows.map(\.displaySlotID))
        #expect(updatedWorkspace.windows.map(\.screenIndex) == workspace.windows.map(\.screenIndex))
    }
}
