import Testing
import CoreGraphics
@testable import DeskJigShared

struct FolderTabCoordinatorTests {

    @Test("Activating a selection moves and raises the active member while hiding siblings")
    func liveStackCommandsHideInactiveMembersOnActivation() {
        let firstID = UUID()
        let secondID = UUID()
        let thirdID = UUID()
        let targetFrame = CGRect(x: 120, y: 200, width: 900, height: 600)

        let commands = FolderTabPlanner.makeLiveStackCommands(
            members: [
                .init(workspaceWindowID: firstID, liveWindowID: 10, folderOrder: 0),
                .init(workspaceWindowID: secondID, liveWindowID: 11, folderOrder: 1),
                .init(workspaceWindowID: thirdID, liveWindowID: 12, folderOrder: 2),
            ],
            activeWorkspaceWindowID: secondID,
            targetFrame: targetFrame,
            moveActiveWindow: true,
            activateActiveWindow: true
        )

        #expect(commands.count == 3)
        #expect(commands.map(\.workspaceWindowID) == [firstID, thirdID, secondID])
        #expect(commands.allSatisfy { $0.targetFrame == targetFrame })
        #expect(commands.dropLast().allSatisfy { !$0.shouldActivateWindow })
        #expect(commands.dropLast().allSatisfy { $0.shouldHideWindow })
        #expect(commands.last?.workspaceWindowID == secondID)
        #expect(commands.last?.shouldActivateWindow == true)
        #expect(commands.last?.shouldHideWindow == false)
    }

    @Test("Direct member drag keeps siblings realized and does not hide them")
    func directMemberDragKeepsSiblingsRealized() {
        let firstID = UUID()
        let secondID = UUID()
        let targetFrame = CGRect(x: 80, y: 160, width: 800, height: 500)

        let commands = FolderTabPlanner.makeLiveStackCommands(
            members: [
                .init(workspaceWindowID: firstID, liveWindowID: 20, folderOrder: 0),
                .init(workspaceWindowID: secondID, liveWindowID: 21, folderOrder: 1),
            ],
            activeWorkspaceWindowID: secondID,
            targetFrame: targetFrame,
            moveActiveWindow: false,
            activateActiveWindow: false
        )

        #expect(commands.count == 2)
        #expect(commands.first?.workspaceWindowID == firstID)
        #expect(commands.first?.shouldMoveWindow == true)
        #expect(commands.last?.workspaceWindowID == secondID)
        #expect(commands.last?.shouldMoveWindow == false)
        #expect(commands.allSatisfy { !$0.shouldActivateWindow })
        #expect(commands.allSatisfy { !$0.shouldHideWindow })
    }

    @Test("Strip drag in cocoa coordinates moves the slot in the same direction")
    func stripTranslationUsesCapturedOriginOnce() {
        let stripHeight: CGFloat = 52
        let stripSpacing: CGFloat = 8
        let anchorY: CGFloat = 1200
        let contentFrame = CGRect(x: 300, y: 240, width: 900, height: 600)
        let preservedSlotFrame = FolderTabPlanner.slotFrame(
            for: contentFrame,
            stripHeight: stripHeight,
            stripSpacing: stripSpacing
        )

        let originStripCocoaY = anchorY - preservedSlotFrame.origin.y - stripHeight
        let originStripFrame = CGRect(
            x: preservedSlotFrame.origin.x,
            y: originStripCocoaY,
            width: preservedSlotFrame.width,
            height: stripHeight
        )

        let translatedStripFrame = originStripFrame.offsetBy(dx: 120, dy: 90)

        let nextSlotFrame = FolderTabPlanner.slotFrame(
            fromStripFrame: translatedStripFrame,
            preserving: preservedSlotFrame,
            anchorY: anchorY,
            stripHeight: stripHeight,
            stripSpacing: stripSpacing
        )

        #expect(nextSlotFrame.origin.x == 420)
        #expect(nextSlotFrame.origin.y == preservedSlotFrame.origin.y - 90)
        #expect(nextSlotFrame.width == preservedSlotFrame.width)
        #expect(nextSlotFrame.height == preservedSlotFrame.height)
    }

    @Test("Slot frame reserves room above the content frame for the strip")
    func slotFrameReservesStripInset() {
        let contentFrame = CGRect(x: 160, y: 240, width: 960, height: 540)
        let slotFrame = FolderTabPlanner.slotFrame(for: contentFrame, stripHeight: 52, stripSpacing: 8)

        #expect(slotFrame.origin.x == contentFrame.origin.x)
        #expect(slotFrame.origin.y == contentFrame.origin.y - 60)
        #expect(slotFrame.width == contentFrame.width)
        #expect(slotFrame.height == contentFrame.height + 60)
    }

    @Test("Canonical content frame normalizes slot-sized observations back into the inset content area")
    func canonicalContentFrameNormalizesInsetReservation() {
        let contentFrame = CGRect(x: 160, y: 240, width: 960, height: 540)
        let slotFrame = FolderTabPlanner.slotFrame(for: contentFrame, stripHeight: 52, stripSpacing: 8)

        let canonicalFrame = FolderTabPlanner.canonicalContentFrame(
            observedFrame: slotFrame,
            slotFrame: slotFrame,
            stripHeight: 52,
            stripSpacing: 8,
            minimumContentHeight: 80,
            frameTolerance: 2
        )

        #expect(canonicalFrame == contentFrame)
    }

    @Test("Canonical content frame accepts already-inset observations unchanged")
    func canonicalContentFrameAcceptsInsetObservation() {
        let contentFrame = CGRect(x: 160, y: 240, width: 960, height: 540)
        let slotFrame = FolderTabPlanner.slotFrame(for: contentFrame, stripHeight: 52, stripSpacing: 8)

        let canonicalFrame = FolderTabPlanner.canonicalContentFrame(
            observedFrame: contentFrame,
            slotFrame: slotFrame,
            stripHeight: 52,
            stripSpacing: 8,
            minimumContentHeight: 80,
            frameTolerance: 2
        )

        #expect(canonicalFrame == contentFrame)
    }
}
