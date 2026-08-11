import Foundation
import Testing
@testable import DeskJigShared

struct WorkspaceWindowFolderMetadataTests {

    @Test("WorkspaceWindow codable round-trip preserves folder metadata")
    func codableRoundTripPreservesFolderMetadata() throws {
        let folderGroupID = UUID()
        let window = WorkspaceWindow(
            id: UUID(),
            bundleIdentifier: "com.example.app",
            appName: "Example",
            windowTitle: "Example Window",
            folderGroupID: folderGroupID,
            folderOrder: 1,
            screenIndex: 0,
            relativeFrame: RelativeWindowFrame(
                xPercent: 0.1,
                yPercent: 0.2,
                widthPercent: 0.3,
                heightPercent: 0.4
            )
        )

        let data = try JSONEncoder().encode(window)
        let decoded = try JSONDecoder().decode(WorkspaceWindow.self, from: data)

        #expect(decoded.folderGroupID == folderGroupID)
        #expect(decoded.folderOrder == 1)
        #expect(decoded.relativeFrame == window.relativeFrame)
    }

    @Test("WorkspaceWindow folder metadata helper only changes folder fields")
    func withFolderMetadataOnlyChangesFolderFields() {
        let original = WorkspaceWindow(
            id: UUID(),
            bundleIdentifier: "com.example.app",
            appName: "Example",
            windowTitle: "Example Window",
            openPath: "/tmp/example"
        )

        let folderGroupID = UUID()
        let updated = original.withFolderMetadata(groupID: folderGroupID, order: 0)

        #expect(updated.id == original.id)
        #expect(updated.bundleIdentifier == original.bundleIdentifier)
        #expect(updated.openPath == original.openPath)
        #expect(updated.folderGroupID == folderGroupID)
        #expect(updated.folderOrder == 0)
    }
}
