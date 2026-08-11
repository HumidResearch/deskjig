//
//  DragDropManager.swift
//  DeskJigShared
//
//  Created by Marco Freedom on 24.09.2025.
//

import Foundation

// MARK: - Drag Drop Manager
public class DragDropManager: ObservableObject {
    public static let shared = DragDropManager()

    @Published public var draggedSnapshot: WindowSnapshot?

    private init() {}
}
