// WorkspaceListNavigatorTests.swift
// DeskJigTests

import Testing
import Foundation
@testable import DeskJig

struct WorkspaceListNavigatorTests {

    private let idA = UUID()
    private let idB = UUID()
    private let idC = UUID()

    private var withCreator: [WorkspaceListItemID] {
        WorkspaceListNavigator.items(showCreator: true, workspaceIds: [idA, idB, idC])
    }

    private var withoutCreator: [WorkspaceListItemID] {
        WorkspaceListNavigator.items(showCreator: false, workspaceIds: [idA, idB, idC])
    }

    @Test("Items place the creator row first, then cards in display order")
    func itemsOrder() {
        #expect(withCreator == [.creator, .workspace(idA), .workspace(idB), .workspace(idC)])
        #expect(withoutCreator == [.workspace(idA), .workspace(idB), .workspace(idC)])
        #expect(WorkspaceListNavigator.items(showCreator: false, workspaceIds: []).isEmpty)
    }

    @Test("Down from the search field enters at the first visible row")
    func downEntersAtFirstRow() {
        #expect(WorkspaceListNavigator.next(after: nil, in: withCreator) == .creator)
        #expect(WorkspaceListNavigator.next(after: nil, in: withoutCreator) == .workspace(idA))
        #expect(WorkspaceListNavigator.next(after: nil, in: []) == nil)
    }

    @Test("Down walks rows in visual order and stops at the last row")
    func downWalksAndStopsAtEnd() {
        #expect(WorkspaceListNavigator.next(after: .creator, in: withCreator) == .workspace(idA))
        #expect(WorkspaceListNavigator.next(after: .workspace(idA), in: withCreator) == .workspace(idB))
        #expect(WorkspaceListNavigator.next(after: .workspace(idC), in: withCreator) == .workspace(idC))
    }

    @Test("Up walks back and clears to the search field from the first row")
    func upWalksAndClearsAtTop() {
        #expect(WorkspaceListNavigator.previous(before: .workspace(idB), in: withCreator) == .workspace(idA))
        #expect(WorkspaceListNavigator.previous(before: .workspace(idA), in: withCreator) == .creator)
        #expect(WorkspaceListNavigator.previous(before: .creator, in: withCreator) == nil)
        #expect(WorkspaceListNavigator.previous(before: .workspace(idA), in: withoutCreator) == nil)
        #expect(WorkspaceListNavigator.previous(before: nil, in: withCreator) == nil)
    }

    @Test("A stale selection restarts down-navigation at the first row and clears up-navigation")
    func staleSelectionRecovers() {
        let gone = UUID()
        #expect(WorkspaceListNavigator.next(after: .workspace(gone), in: withCreator) == .creator)
        #expect(WorkspaceListNavigator.previous(before: .workspace(gone), in: withCreator) == nil)
        // Creator hidden while searching: stale .creator restarts at the first card.
        #expect(WorkspaceListNavigator.next(after: .creator, in: withoutCreator) == .workspace(idA))
    }

    @Test("Scroll anchor ids are stable per identity, not per position")
    func scrollAnchorIDs() {
        #expect(WorkspaceListItemID.creator.scrollAnchorID == "workspace-item-creator")
        #expect(WorkspaceListItemID.workspace(idA).scrollAnchorID == "workspace-item-\(idA.uuidString)")
        #expect(WorkspaceListItemID.workspace(idA).scrollAnchorID != WorkspaceListItemID.workspace(idB).scrollAnchorID)
    }
}
