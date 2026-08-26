//
//  WorkspaceListSelection.swift
//  DeskJig
//

import Foundation

/// Identity of a selectable row in the workspaces list. Selection is tracked
/// by stable identity (not positional index) so keyboard selection can never
/// drift from the visual order while search filtering or the inline creator
/// row change what is on screen (#51).
enum WorkspaceListItemID: Hashable {
    case creator
    case workspace(UUID)

    /// ScrollViewReader anchor id for this row.
    var scrollAnchorID: String {
        switch self {
        case .creator:
            return "workspace-item-creator"
        case .workspace(let id):
            return "workspace-item-\(id.uuidString)"
        }
    }
}

/// Pure keyboard-navigation rules for the workspaces list.
enum WorkspaceListNavigator {
    /// Visible rows in display order: creator row first when shown, then cards.
    static func items(showCreator: Bool, workspaceIds: [UUID]) -> [WorkspaceListItemID] {
        (showCreator ? [.creator] : []) + workspaceIds.map { .workspace($0) }
    }

    /// Selection after ↓. No selection (search focused) enters at the first
    /// row; a stale selection (row no longer visible) restarts at the first
    /// row; the last row stays put.
    static func next(after current: WorkspaceListItemID?, in items: [WorkspaceListItemID]) -> WorkspaceListItemID? {
        guard let first = items.first else { return nil }
        guard let current, let index = items.firstIndex(of: current) else { return first }
        return items.index(after: index) < items.endIndex ? items[items.index(after: index)] : current
    }

    /// Selection after ↑. The first row — or a stale selection — clears back
    /// to the search field.
    static func previous(before current: WorkspaceListItemID?, in items: [WorkspaceListItemID]) -> WorkspaceListItemID? {
        guard let current, let index = items.firstIndex(of: current), index > items.startIndex else { return nil }
        return items[items.index(before: index)]
    }
}
