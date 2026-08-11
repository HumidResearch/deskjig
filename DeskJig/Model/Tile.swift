//
//  Tile.swift
//  DeskJig
//

import Foundation
import SwiftUI
import DeskJigShared

struct Tile: Identifiable, Hashable {
    let id = UUID()
    let title: String
    let subtitle: String?
    let icon: ImageResource?
    let type: TileType
    let children: [Tile]?
    let tileSectionUUID: UUID?
    /// Apps associated with the workspace.
    let apps: [AppInfo]

    enum TileType {
        case leaf    // Performs an action when activated
        case branch  // Opens another list of tiles
    }

    var isFolder: Bool {
        type == .branch
    }

    init(
        title: String,
        subtitle: String?,
        icon: ImageResource?,
        type: TileType,
        children: [Tile]? = nil,
        tileSectionUUID: UUID? = nil,
        apps: [AppInfo] = []
    ) {
        self.title = title
        self.subtitle = subtitle
        self.icon = icon
        self.type = type
        self.children = children
        self.tileSectionUUID = tileSectionUUID
        self.apps = apps
    }
}
