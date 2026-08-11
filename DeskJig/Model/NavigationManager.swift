//
//  NavigationManager.swift
//  DeskJig
//

import SwiftUI
import AppKit
import Combine

enum NavigationDirection {
    case left, right, up, down
}

@MainActor
class NavigationManager: ObservableObject {
    // MARK: - Published Properties
    @Published var selectedIndex: Int = 0
    @Published var navigationStack: [Tile] = []
    @Published var search: String = ""
    @Published var searchIsFocused = false
    /// `focus` and `searchIsFocused` are distinct because we always want the
    /// search bar to receive key events (be "focused"), but those events will be ignored
    /// by the search bar if they are in reference to tile navigation.
    @Published var focus: Focus = .tiles

    // MARK: - Navigation Methods
    func refocus() {
        self.searchIsFocused = false
        DispatchQueue.main.async {
            self.searchIsFocused = true
        }
    }

    func moveSelection(
        direction: NavigationDirection,
        columns: Int,
        allTiles: [Tile],
        filteredSections: [TileSection]
    ) {
        guard !allTiles.isEmpty else { return }

        var next = selectedIndex
        switch direction {
        case .left:
            next = findHorizontalSectionTarget(
                currentIndex: selectedIndex,
                direction: .left,
                allTiles: allTiles,
                filteredSections: filteredSections
            )
        case .right:
            next = findHorizontalSectionTarget(
                currentIndex: selectedIndex,
                direction: .right,
                allTiles: allTiles,
                filteredSections: filteredSections
            )
        case .up:
            let verticalTarget =  findVerticalSectionTarget(
                currentIndex: selectedIndex,
                direction: .up,
                allTiles: allTiles,
                filteredSections: filteredSections
            )
            switch verticalTarget {
            case .index(let int):
                next = int
            case .search:
                searchIsFocused = true
                focus = .search
            }
        case .down:
            let verticalTarget = findVerticalSectionTarget(
                currentIndex: selectedIndex,
                direction: .down,
                allTiles: allTiles,
                filteredSections: filteredSections
            )
            switch verticalTarget {
            case .index(let int):
                next = int
            case .search:
                searchIsFocused = true
                focus = .search
            }
        }
        selectedIndex = next
    }

    private func findHorizontalTarget(
        currentIndex: Int,
        direction: NavigationDirection,
        columns: Int,
        allTiles: [Tile],
        filteredSections: [TileSection]
    ) -> Int {
        let tilePositions = calculateTilePositions(allTiles: allTiles, filteredSections: filteredSections, columns: columns)

        guard let currentPosition = tilePositions[currentIndex] else {
            // Fallback to simple navigation if position mapping fails
            if direction == .left {
                return max(0, currentIndex - 1)
            } else {
                return min(allTiles.count - 1, currentIndex + 1)
            }
        }

        let currentSection = filteredSections[currentPosition.sectionIndex]
        let currentSectionTileCount = currentSection.tiles.count
        let currentRowInSection = currentPosition.rowInSection

        // Calculate the range of tiles in the current row within the section
        let rowStartIndex = currentRowInSection * columns
        let rowEndIndex = min(currentSectionTileCount - 1, rowStartIndex + columns - 1)

        // Find the target position within the current row
        let targetIndexInSection: Int
        if direction == .left {
            if currentPosition.tileIndexInSection == rowStartIndex {
                // At the beginning of the row, wrap to the end
                targetIndexInSection = rowEndIndex
            } else {
                // Move one position to the left
                targetIndexInSection = currentPosition.tileIndexInSection - 1
            }
        } else { // direction == .right
            if currentPosition.tileIndexInSection == rowEndIndex {
                // At the end of the row, wrap to the beginning
                targetIndexInSection = rowStartIndex
            } else {
                // Move one position to the right
                targetIndexInSection = currentPosition.tileIndexInSection + 1
            }
        }

        // Convert section-relative index to global index
        var globalIndex = 0
        for (sectionIdx, section) in filteredSections.enumerated() {
            if sectionIdx == currentPosition.sectionIndex {
                return globalIndex + targetIndexInSection
            }
            globalIndex += section.tiles.count
        }

        // Fallback
        return currentIndex
    }

    private func findVerticalTarget(currentIndex: Int, direction: NavigationDirection, columns: Int, allTiles: [Tile], filteredSections: [TileSection]) -> Int {
        let tilePositions = calculateTilePositions(allTiles: allTiles, filteredSections: filteredSections, columns: columns)

        guard let currentPosition = tilePositions[currentIndex] else {
            // Fallback to simple grid navigation if position mapping fails
            let offset = direction == .up ? -columns : columns
            return max(0, min(allTiles.count - 1, currentIndex + offset))
        }

        let targetSectionIndex: Int
        let isMovingUp = direction == .up

        if isMovingUp {
            // Moving up: find previous section or previous row in same section
            if currentPosition.rowInSection > 0 {
                // Stay in same section, move to previous row
                targetSectionIndex = currentPosition.sectionIndex
            } else {
                // Move to previous section
                targetSectionIndex = max(0, currentPosition.sectionIndex - 1)
            }
        } else {
            // Moving down: find next section or next row in same section
            let currentSectionTileCount = filteredSections[currentPosition.sectionIndex].tiles.count
            let currentSectionRowCount = (currentSectionTileCount + columns - 1) / columns

            if currentPosition.rowInSection < currentSectionRowCount - 1 {
                // Stay in same section, move to next row
                targetSectionIndex = currentPosition.sectionIndex
            } else {
                // Move to next section
                targetSectionIndex = min(filteredSections.count - 1, currentPosition.sectionIndex + 1)
            }
        }

        // Find the target tile in the target section
        return findTileInTargetSection(
            targetSectionIndex: targetSectionIndex,
            currentPosition: currentPosition,
            direction: direction,
            columns: columns,
            tilePositions: tilePositions,
            allTiles: allTiles,
            filteredSections: filteredSections
        )
    }

    private func findTileInTargetSection(
        targetSectionIndex: Int,
        currentPosition: TilePosition,
        direction: NavigationDirection,
        columns: Int,
        tilePositions: [Int: TilePosition],
        allTiles: [Tile],
        filteredSections: [TileSection]
    ) -> Int {
        let targetSection = filteredSections[targetSectionIndex]
        let targetSectionTileCount = targetSection.tiles.count
        let targetSectionRowCount = (targetSectionTileCount + columns - 1) / columns

        let targetRow: Int
        if direction == .up {
            if targetSectionIndex == currentPosition.sectionIndex {
                // Same section, move to previous row
                targetRow = max(0, currentPosition.rowInSection - 1)
            } else {
                // Different section, go to last row
                targetRow = targetSectionRowCount - 1
            }
        } else {
            if targetSectionIndex == currentPosition.sectionIndex {
                // Same section, move to next row
                targetRow = min(targetSectionRowCount - 1, currentPosition.rowInSection + 1)
            } else {
                // Different section, go to first row
                targetRow = 0
            }
        }

        // Calculate the desired column position (try to maintain horizontal position)
        let targetColumn = currentPosition.columnInSection
        let targetTileIndexInSection = targetRow * columns + targetColumn

        // Find the closest available tile in the target row
        let targetRowStartIndex = targetRow * columns
        let targetRowEndIndex = min(targetSectionTileCount - 1, targetRowStartIndex + columns - 1)
        let actualTargetIndexInSection = min(targetTileIndexInSection, targetRowEndIndex)

        // Convert section-relative index to global index
        var globalIndex = 0
        for (sectionIdx, section) in filteredSections.enumerated() {
            if sectionIdx == targetSectionIndex {
                return globalIndex + actualTargetIndexInSection
            }
            globalIndex += section.tiles.count
        }

        // Fallback
        return max(0, min(allTiles.count - 1, currentPosition.globalIndex))
    }

    // MARK: - Horizontal Section Navigation Methods

    private func findHorizontalSectionTarget(
        currentIndex: Int,
        direction: NavigationDirection,
        allTiles: [Tile],
        filteredSections: [TileSection]
    ) -> Int {
        guard !filteredSections.isEmpty else { return currentIndex }

        // Find current section and position within that section
        var globalIndex = 0
        var currentSectionIndex = 0
        var currentTileIndexInSection = 0

        for (sectionIndex, section) in filteredSections.enumerated() {
            if globalIndex + section.tiles.count > currentIndex {
                currentSectionIndex = sectionIndex
                currentTileIndexInSection = currentIndex - globalIndex
                break
            }
            globalIndex += section.tiles.count
        }

        let currentSection = filteredSections[currentSectionIndex]

        if direction == .left {
            // Move to previous tile in same section, or wrap to end of section
            if currentTileIndexInSection > 0 {
                return currentIndex - 1
            } else {
                // Wrap to end of current section
                return globalIndex + currentSection.tiles.count - 1
            }
        } else { // direction == .right
            // Move to next tile in same section, or wrap to beginning of section
            if currentTileIndexInSection < currentSection.tiles.count - 1 {
                return currentIndex + 1
            } else {
                // Wrap to beginning of current section
                return globalIndex
            }
        }
    }

    private func findVerticalSectionTarget(
        currentIndex: Int,
        direction: NavigationDirection,
        allTiles: [Tile],
        filteredSections: [TileSection]
    ) -> NavigationTarget {
        guard !filteredSections.isEmpty else { return .index(currentIndex) }

        // Find current section and position within that section
        var globalIndex = 0
        var currentSectionIndex = 0
        var currentTileIndexInSection = 0

        for (sectionIndex, section) in filteredSections.enumerated() {
            if globalIndex + section.tiles.count > currentIndex {
                currentSectionIndex = sectionIndex
                currentTileIndexInSection = currentIndex - globalIndex
                break
            }
            globalIndex += section.tiles.count
        }

        if direction == .up {
            // Move to previous section
            guard currentSectionIndex > 0 else {
                // if we're at the top, move to search
                return .search
            }
            let targetSectionIndex = currentSectionIndex - 1
            let targetSection = filteredSections[targetSectionIndex]

            // Calculate global index for start of target section
            var targetGlobalIndex = 0
            for i in 0..<targetSectionIndex {
                targetGlobalIndex += filteredSections[i].tiles.count
            }

            // Try to maintain relative position, or go to last tile if target section is smaller
            let targetTileIndex = min(currentTileIndexInSection, targetSection.tiles.count - 1)
            return .index(targetGlobalIndex + targetTileIndex)
        } else { // direction == .down
            // Move to next section
            if currentSectionIndex < filteredSections.count - 1 {
                let targetSectionIndex = currentSectionIndex + 1
                let targetSection = filteredSections[targetSectionIndex]

                // Calculate global index for start of target section
                var targetGlobalIndex = 0
                for i in 0...currentSectionIndex {
                    targetGlobalIndex += filteredSections[i].tiles.count
                }

                // Try to maintain relative position, or go to last tile if target section is smaller
                let targetTileIndex = min(currentTileIndexInSection, targetSection.tiles.count - 1)
                return .index(targetGlobalIndex + targetTileIndex)
            } else {
                // Already at last section, wrap to first tile of first section
                return .index(0)
            }
        }
    }

    private func calculateTilePositions(allTiles: [Tile], filteredSections: [TileSection], columns: Int) -> [Int: TilePosition] {
        var positions: [Int: TilePosition] = [:]
        var globalIndex = 0

        for (sectionIndex, section) in filteredSections.enumerated() {
            for (tileIndexInSection, _) in section.tiles.enumerated() {
                let rowInSection = tileIndexInSection / columns
                let columnInSection = tileIndexInSection % columns

                positions[globalIndex] = TilePosition(
                    globalIndex: globalIndex,
                    sectionIndex: sectionIndex,
                    tileIndexInSection: tileIndexInSection,
                    rowInSection: rowInSection,
                    columnInSection: columnInSection
                )
                globalIndex += 1
            }
        }

        return positions
    }

    // MARK: - Navigation Stack Management
    func navigateToTile(_ tile: Tile) {
        if tile.type == .branch, let children = tile.children, !children.isEmpty {
            navigationStack.append(tile)
            selectedIndex = 0 // Reset selection when entering new level
        }
    }

    func navigateBack() -> Bool {
        if !navigationStack.isEmpty {
            navigationStack.removeLast()
            selectedIndex = 0 // Reset selection when going back
            return true
        }
        return false
    }

    // MARK: - Keyboard Input Handling
    func handleKeyPress(
        _ keyPress: KeyPress,
        allTiles: [Tile],
        onActivate: @escaping (Tile) -> Void,
        onKeyboardShortcut: @escaping (Tile) -> Void
    ) -> KeyPress.Result {
        // ⌘1…⌘9 → activate first 9 tiles with keyboard shortcut behavior
        if keyPress.modifiers.contains(.command),
           let digit = Int(keyPress.characters),
           digit >= 1, digit <= 9 {
            let idx = digit - 1
            if allTiles.indices.contains(idx) {
                DispatchQueue.main.async {
                    self.selectedIndex = idx
                    onKeyboardShortcut(allTiles[idx])
                }
            }
            return .handled
        }

        // Handle enter key
        if keyPress.characters.first?.isNewline == true {
            if allTiles.indices.contains(selectedIndex) {
                DispatchQueue.main.async {
                    self.search = ""
                    onActivate(allTiles[self.selectedIndex])
                }
            }
            return .handled
        }

        return .ignored
    }

//    func handleKey(
//        event: NSEvent,
//        columns: Int,
//        allTiles: [Tile],
//        filteredSections: [TileSection],
//        onActivate: @escaping (Tile) -> Void,
//        onKeyboardShortcut: @escaping (Tile) -> Void,
//        onEscape: @escaping () -> Void
//    ) -> Bool {
//        // Arrow keys (keyCodes 123…126) handled here too for robustness
//        switch event.keyCode {
//        case 123:
//            moveSelection(
//                direction: .left,
//                columns: columns,
//                allTiles: allTiles,
//                filteredSections: filteredSections
//            )
//            return true
//        case 124:
//            moveSelection(
//                direction: .right,
//                columns: columns,
//                allTiles: allTiles,
//                filteredSections: filteredSections
//            )
//            return true
//        case 125:
//            moveSelection(
//                direction: .down,
//                columns: columns,
//                allTiles: allTiles,
//                filteredSections: filteredSections
//            )
//            return true
//        case 126:
//            moveSelection(
//                direction: .up,
//                columns: columns,
//                allTiles: allTiles,
//                filteredSections: filteredSections
//            )
//            return true
//        case 36:  // Return / Enter
//            if allTiles.indices.contains(selectedIndex) {
//                search = ""
//                onActivate(allTiles[selectedIndex])
//            }
//            return true
//        case 53:  // ESC
//            onEscape()
//            return true
//        default: break
//        }
//
//        // ⌘1…⌘9 → activate first 9 tiles with keyboard shortcut behavior
//        if event.modifierFlags.contains(.command),
//           let chars = event.charactersIgnoringModifiers,
//           let digit = Int(chars),
//           digit >= 1, digit <= 9 {
//            let idx = digit - 1
//            if allTiles.indices.contains(idx) {
//                selectedIndex = idx
//                onKeyboardShortcut(allTiles[idx])
//            }
//            return true
//        }
//
//        return false
//    }

    // MARK: - Utility Methods
    func calculateGlobalIndex(
        for section: TileSection,
        tileIndex: Int,
        filteredSections: [TileSection]
    ) -> Int {
        var globalIndex = 0

        // Find the section index
        guard let sectionIndex = filteredSections.firstIndex(where: { $0.id == section.id }) else {
            return 0
        }

        // Add up all tiles from previous sections
        for i in 0..<sectionIndex {
            globalIndex += filteredSections[i].tiles.count
        }

        // Add the tile index within the current section
        globalIndex += tileIndex

        return globalIndex
    }

    func validateSelectedIndex(totalTiles: Int) {
        selectedIndex = min(selectedIndex, max(0, totalTiles - 1))
    }

    func resetSelection() {
        selectedIndex = 0
    }

    // MARK: - Breadcrumb Path
    var breadcrumbPath: String {
        if navigationStack.isEmpty {
            return "Home"
        } else {
            return navigationStack.map { $0.title }.joined(separator: " > ")
        }
    }

    // MARK: - Data Structures
    enum Focus: String, Hashable, Sendable, Identifiable {
        case search, tiles
        var id: Self { self }
    }

    ///
    enum NavigationTarget: Hashable, Sendable, Identifiable {
        case index(Int)
        case search
        var id: Self { self }
    }
}

extension NavigationManager.NavigationTarget: ExpressibleByIntegerLiteral {
    init(integerLiteral value: IntegerLiteralType) {
        self = .index(value)
    }
}
