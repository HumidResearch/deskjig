//
//  TileSection.swift
//  DeskJig
//

import Foundation

struct TileSection: Identifiable {
    let id: UUID
    let title: String
    let tiles: [Tile]

    init(title: String, tiles: [Tile]) {
        self.id = UUID()
        self.title = title
        self.tiles = tiles
    }

    init(id: UUID, title: String, tiles: [Tile]) {
        self.id = id
        self.title = title
        self.tiles = tiles
    }
}
