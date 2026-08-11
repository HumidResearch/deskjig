//
//  TilingLayoutManager.swift
//  DeskJigShared
//
//  Manages automatic window tiling layouts (Amethyst-style)
//

import Foundation
import CoreGraphics
import AppKit

@MainActor
public class TilingLayoutManager: ObservableObject {

    // MARK: - Properties

    public static let shared = TilingLayoutManager()

    private var windowManager: WindowManager?
    private var displayManager: DisplayManager?

    // Configuration
    public var mainPaneRatio: CGFloat = 0.5
    public var mainPaneCount: Int = 1
    public var windowMargins: CGFloat = 0
    public var cascadeOffset: CGFloat = 25.0 // Cascade offset for stacked windows (matches legacy restore behavior)

    // Minimum window dimensions for cascaded windows
    private let minWindowWidth: CGFloat = 400.0
    private let minWindowHeight: CGFloat = 300.0

    // MARK: - Layout Types

    public enum TilingLayout {
        case sideBySide
        case topBottom
        case quarters
    }

    // MARK: - Initialization

    private init() {}

    // MARK: - Dependency Injection

    /// Configure the dependencies for the TilingLayoutManager
    public func configure(
        windowManager: WindowManager,
        displayManager: DisplayManager
    ) {
        self.windowManager = windowManager
        self.displayManager = displayManager
    }

    // MARK: - Public Methods

    /// Apply a tiling layout to all windows on the current screen
    public func applyLayout(_ layout: TilingLayout, screen: NSScreen? = nil) {
        DeskJigLog.info(.window, "Applying tiling layout: \(String(describing: layout))")

        guard let windowManager = windowManager,
              let displayManager = displayManager else {
            DeskJigLog.error(.window, "TilingLayoutManager not configured. Call configure() first.")
            return
        }

        // Get the target screen - use provided screen or screen at mouse location
        let targetScreen: NSScreen?
        if let providedScreen = screen {
            targetScreen = providedScreen
        } else {
            // Get screen at current mouse location
            let mouseLocation = NSEvent.mouseLocation
            targetScreen = findScreenContaining(point: mouseLocation)
        }

        guard let targetScreen = targetScreen else {
            DeskJigLog.error(.window, "No screen available for tiling")
            return
        }

        // Get visible windows from WindowManager (snapshot capture handles visibility)
        let allVisibleWindows = windowManager.getVisibleWindows(
            minVisibility: 0.0,  // Include all visible windows
            includeMinimized: false,
            includeHidden: false,
            currentWindows: windowManager.windows
        )

        // Filter to windows on the target screen using DisplayManager
        let targetScreenInfo = FullScreenInfo(screen: targetScreen)
        let visibleWindowsOnScreen = allVisibleWindows.filter { windowInfo in
            // Use DisplayManager to find which screen this window belongs to
            guard let screenInfo = displayManager.getBestScreen(for: windowInfo.frame) else {
                return false
            }
            return screenInfo.displayID == targetScreenInfo.displayID
        }

        guard !visibleWindowsOnScreen.isEmpty else {
            DeskJigLog.info(.window, "No visible windows to tile on screen \(targetScreenInfo.displayID)")
            return
        }

        DeskJigLog.info(.window, "Tiling \(visibleWindowsOnScreen.count) visible windows on screen \(targetScreenInfo.displayID)")
        DeskJigLog.debug(.window, "Screen frame: \(NSStringFromRect(targetScreen.frame)), visible frame: \(NSStringFromRect(targetScreen.visibleFrame))")

        // Sort windows by bundle identifier to group same apps together
        let sortedWindows = visibleWindowsOnScreen.sorted { window1, window2 in
            // First sort by bundle identifier
            let bundle1 = window1.bundleIdentifier ?? ""
            let bundle2 = window2.bundleIdentifier ?? ""
            if bundle1 != bundle2 {
                return bundle1 < bundle2
            }
            // Within same app, maintain existing order
            return false
        }

        // CRITICAL: Convert visibleFrame to window coordinates for proper window positioning
        // WindowManager.moveWindowToFrame() expects window coordinates (top-left origin)
        // NSScreen.visibleFrame is in screen coordinates (bottom-left origin)
        // We must convert before using for window positioning
        let globalMaxY = WorkspaceDisplayTopology.windowCoordinateAnchorY(
            from: NSScreen.screens.map(FullScreenInfo.init(screen:))
        )
        let positioningFrame = targetScreenInfo.visibleFrameInWindowCoordinates(globalMaxY: globalMaxY)

        DeskJigLog.info(.window, "Screen frame: \(NSStringFromRect(targetScreen.frame))")
        DeskJigLog.info(.window, "Visible frame (screen coords): \(NSStringFromRect(targetScreen.visibleFrame))")
        DeskJigLog.info(.window, "Positioning frame (window coords): \(NSStringFromRect(positioningFrame))")

        // Apply the selected layout
        switch layout {
        case .sideBySide:
            tileSideBySide(windows: sortedWindows, screenFrame: positioningFrame)
        case .topBottom:
            tileTopBottom(windows: sortedWindows, screenFrame: positioningFrame)
        case .quarters:
            tileQuarters(windows: sortedWindows, screenFrame: positioningFrame)
        }
    }

    // MARK: - Helper Methods

    /// Find the screen containing the given point
    private func findScreenContaining(point: CGPoint) -> NSScreen? {
        // Find the screen that contains the point
        for screen in NSScreen.screens {
            if screen.frame.contains(point) {
                return screen
            }
        }

        // If point is not in any screen, find the closest screen
        var closestScreen: NSScreen?
        var minDistance = Double.infinity

        for screen in NSScreen.screens {
            let distance = distanceFromPointToRect(point: point, rect: screen.frame)
            if distance < minDistance {
                minDistance = distance
                closestScreen = screen
            }
        }

        return closestScreen ?? NSScreen.main
    }

    /// Calculate distance from point to rectangle
    private func distanceFromPointToRect(point: CGPoint, rect: CGRect) -> Double {
        let dx = max(rect.minX - point.x, 0, point.x - rect.maxX)
        let dy = max(rect.minY - point.y, 0, point.y - rect.maxY)
        return sqrt(dx * dx + dy * dy)
    }

    // MARK: - Layout Implementations

    /// Arrange windows in side-by-side columns
    /// - Parameters:
    ///   - windows: Array of windows to tile
    ///   - screenFrame: The positioning frame in WINDOW COORDINATES (top-left origin)
    private func tileSideBySide(windows: [WindowInfo], screenFrame: CGRect) {
        guard let windowManager = windowManager else { return }

        // Always use exactly 2 columns
        let columnCount = 2
        let columnWidth = screenFrame.width / CGFloat(columnCount)

        // Group windows by app
        var appGroups: [[WindowInfo]] = []
        var processedBundles = Set<String>()

        for window in windows {
            let bundleId = window.bundleIdentifier ?? "unknown"
            if !processedBundles.contains(bundleId) {
                // Find all windows with this bundle identifier
                let appWindows = windows.filter { ($0.bundleIdentifier ?? "unknown") == bundleId }
                appGroups.append(appWindows)
                processedBundles.insert(bundleId)
            }
        }

        // Build a list of windows with their target columns and cascade levels
        // This allows us to position them in the correct Z-order (highest cascade level first)
        struct WindowPlacement {
            var windowInfo: WindowInfo  // var instead of let so we can update the frame
            let column: Int
            let cascadeLevel: Int
            let appIndex: Int  // Index within app group for logging
            let appWindowCount: Int  // Total windows in app for logging
        }

        var placements: [WindowPlacement] = []
        var currentColumn = 0
        var cascadeLevelsPerColumn = [Int](repeating: 0, count: columnCount)

        // First pass: assign columns and cascade levels to all windows
        for appGroup in appGroups {
            let column = currentColumn
            let startingCascadeLevel = cascadeLevelsPerColumn[column]

            for (index, windowInfo) in appGroup.enumerated() {
                let cascadeLevel = startingCascadeLevel + index
                placements.append(WindowPlacement(
                    windowInfo: windowInfo,
                    column: column,
                    cascadeLevel: cascadeLevel,
                    appIndex: index,
                    appWindowCount: appGroup.count
                ))
            }

            cascadeLevelsPerColumn[column] += appGroup.count
            currentColumn = (currentColumn + 1) % columnCount
        }

        // Second pass: position all windows and update their frames
        for index in placements.indices {
            var placement = placements[index]
            let windowInfo = placement.windowInfo
            let column = placement.column
            let cascadeLevel = placement.cascadeLevel

            // Base position and size for this column
            let columnX = screenFrame.origin.x + (columnWidth * CGFloat(column))
            let baseX = columnX + windowMargins
            // CRITICAL: Y position in window coordinates (top-left origin)
            // screenFrame.origin.y is the top of the visible area (below menu bar)
            // This is our base Y position for non-cascaded windows
            let baseY = screenFrame.origin.y + windowMargins
            let baseWidth = columnWidth - (windowMargins * 2)
            let baseHeight = screenFrame.height - (windowMargins * 2)

            // Calculate cascade offset for THIS window
            let totalOffset = CGFloat(cascadeLevel) * cascadeOffset

            DeskJigLog.info(.window, "📐 Window \(placement.appIndex + 1)/\(placement.appWindowCount) for \(windowInfo.appName):")
            DeskJigLog.info(.window, "  - Column: \(column), Cascade level: \(cascadeLevel), Z-index: \(cascadeLevel)")
            DeskJigLog.info(.window, "  - Base position: (\(baseX), \(baseY)) with size \(baseWidth)×\(baseHeight)")
            DeskJigLog.info(.window, "  - Cascade offset: \(totalOffset) (level \(cascadeLevel) × \(self.cascadeOffset)px)")
            DeskJigLog.info(.window, "  - Target position before offset: X=\(baseX), Y=\(baseY)")

            // CRITICAL: Reduce width and height by the offset amount
            // This matches legacy restore behavior for stacked windows
            // Combined with position offset, creates proper cascade effect
            let calculatedWidth = baseWidth - totalOffset
            let calculatedHeight = baseHeight - totalOffset
            DeskJigLog.info(.window, "  - Calculated size after offset reduction: \(calculatedWidth)×\(calculatedHeight)")

            // Apply minimum size constraints
            let constrainedWidth = max(calculatedWidth, minWindowWidth)
            let constrainedHeight = max(calculatedHeight, minWindowHeight)
            DeskJigLog.info(.window, "  - Size after min constraints: \(constrainedWidth)×\(constrainedHeight)")

            // Calculate position with cascade offset - matches legacy restore behavior
            // Just ADD the offset to both X and Y
            let frameX = baseX + totalOffset
            let frameY = baseY + totalOffset
            DeskJigLog.info(.window, "  - Position after cascade offset: X=\(frameX), Y=\(frameY)")

            // Final boundary checks (additional safety)
            var finalWidth = constrainedWidth
            var finalHeight = constrainedHeight

            let columnRight = columnX + columnWidth
            let screenBottom = screenFrame.origin.y + screenFrame.height

            if (frameX + finalWidth) > columnRight {
                finalWidth = max(columnRight - frameX - windowMargins, minWindowWidth)
                DeskJigLog.info(.window, "  - Width adjusted for right boundary: \(constrainedWidth) → \(finalWidth)")
            }

            if (frameY + finalHeight) > screenBottom {
                finalHeight = max(screenBottom - frameY - windowMargins, minWindowHeight)
                DeskJigLog.info(.window, "  - Height adjusted for bottom boundary: \(constrainedHeight) → \(finalHeight)")
            }

            // Create the frame
            let frame = CGRect(
                x: frameX,
                y: frameY,
                width: finalWidth,
                height: finalHeight
            )

            DeskJigLog.info(.window, "  📍 FINAL FRAME: origin=(\(frame.origin.x), \(frame.origin.y)) size=\(frame.width)×\(frame.height)")
            DeskJigLog.info(.window, "  - Bottom-left (origin): (\(frame.origin.x), \(frame.origin.y))")
            DeskJigLog.info(.window, "  - Bottom-right: (\(frame.maxX), \(frame.origin.y))")
            DeskJigLog.info(.window, "  - Top-left: (\(frame.origin.x), \(frame.maxY))")
            DeskJigLog.info(.window, "  - Top-right: (\(frame.maxX), \(frame.maxY))")
            DeskJigLog.info(.window, "  - Window top Y: \(frame.maxY), Window bottom Y: \(frame.origin.y)")
            DeskJigLog.info(.window, "  - Visual cascade: Window extends from Y=\(frame.origin.y) to Y=\(frame.maxY)")

            let moveSuccess = windowManager.moveWindowToFrame(windowInfo: windowInfo, targetFrame: frame)
            DeskJigLog.info(.window, "  - Move result: \(moveSuccess ? "✅ SUCCESS" : "❌ FAILED")")

            // CRITICAL: Update the placement's windowInfo frame so raiseWindow can find it
            placement.windowInfo.frame = frame
            placements[index] = placement
        }

        // Third pass: Set Z-order by raising windows PER COLUMN
        // We must process each column independently to avoid cross-column Z-order interference
        DeskJigLog.info(.window, "🔄 Setting Z-order...")

        // Group placements by column
        var placementsByColumn = [Int: [WindowPlacement]]()
        for placement in placements {
            if placementsByColumn[placement.column] == nil {
                placementsByColumn[placement.column] = []
            }
            placementsByColumn[placement.column]?.append(placement)
        }

        // Process each column independently
        for column in placementsByColumn.keys.sorted() {
            guard let columnPlacements = placementsByColumn[column] else { continue }

            DeskJigLog.info(.window, "  Column \(column):")
            // Within each column, raise from lowest to highest cascade level
            for placement in columnPlacements.sorted(by: { $0.cascadeLevel < $1.cascadeLevel }) {
                let success = Window.find(windowId: CGWindowID(placement.windowInfo.id))?.raise() != nil
                let status = success ? "✅" : "❌"
                DeskJigLog.info(.window, "    \(status) Raised \(placement.windowInfo.appName) (cascade level \(placement.cascadeLevel))")
            }
        }
    }

    /// Arrange windows in top-bottom rows
    /// - Parameters:
    ///   - windows: Array of windows to tile
    ///   - screenFrame: The positioning frame in WINDOW COORDINATES (top-left origin)
    private func tileTopBottom(windows: [WindowInfo], screenFrame: CGRect) {
        guard let windowManager = windowManager else { return }

        // Always use exactly 2 rows
        let rowCount = 2
        let rowHeight = screenFrame.height / CGFloat(rowCount)

        // Group windows by app
        var appGroups: [[WindowInfo]] = []
        var processedBundles = Set<String>()

        for window in windows {
            let bundleId = window.bundleIdentifier ?? "unknown"
            if !processedBundles.contains(bundleId) {
                // Find all windows with this bundle identifier
                let appWindows = windows.filter { ($0.bundleIdentifier ?? "unknown") == bundleId }
                appGroups.append(appWindows)
                processedBundles.insert(bundleId)
            }
        }

        // Build a list of windows with their target rows and cascade levels
        // This allows us to position them in the correct Z-order (highest cascade level first)
        struct WindowPlacement {
            var windowInfo: WindowInfo  // var instead of let so we can update the frame
            let row: Int
            let cascadeLevel: Int
            let appIndex: Int  // Index within app group for logging
            let appWindowCount: Int  // Total windows in app for logging
        }

        var placements: [WindowPlacement] = []
        var currentRow = 0
        var cascadeLevelsPerRow = [Int](repeating: 0, count: rowCount)

        // First pass: assign rows and cascade levels to all windows
        for appGroup in appGroups {
            let row = currentRow
            let startingCascadeLevel = cascadeLevelsPerRow[row]

            for (index, windowInfo) in appGroup.enumerated() {
                let cascadeLevel = startingCascadeLevel + index
                placements.append(WindowPlacement(
                    windowInfo: windowInfo,
                    row: row,
                    cascadeLevel: cascadeLevel,
                    appIndex: index,
                    appWindowCount: appGroup.count
                ))
            }

            cascadeLevelsPerRow[row] += appGroup.count
            currentRow = (currentRow + 1) % rowCount
        }

        // Second pass: position all windows and update their frames
        for index in placements.indices {
            var placement = placements[index]
            let windowInfo = placement.windowInfo
            let row = placement.row
            let cascadeLevel = placement.cascadeLevel

            // Base position and size for this row
            let rowY = screenFrame.origin.y + (rowHeight * CGFloat(row))
            let baseX = screenFrame.origin.x + windowMargins
            // CRITICAL: Y position in window coordinates (top-left origin)
            // rowY already accounts for menu bar height from screenFrame.origin.y
            let baseY = rowY + windowMargins
            let baseWidth = screenFrame.width - (windowMargins * 2)
            let baseHeight = rowHeight - (windowMargins * 2)

            // Calculate cascade offset for THIS window
            let totalOffset = CGFloat(cascadeLevel) * cascadeOffset

            DeskJigLog.info(.window, "📐 Window \(placement.appIndex + 1)/\(placement.appWindowCount) for \(windowInfo.appName):")
            DeskJigLog.info(.window, "  - Row: \(row), Cascade level: \(cascadeLevel), Z-index: \(cascadeLevel)")
            DeskJigLog.info(.window, "  - Base position: (\(baseX), \(baseY)) with size \(baseWidth)×\(baseHeight)")
            DeskJigLog.info(.window, "  - Cascade offset: \(totalOffset) (level \(cascadeLevel) × \(self.cascadeOffset)px)")
            DeskJigLog.info(.window, "  - Target position before offset: X=\(baseX), Y=\(baseY)")

            // CRITICAL: Reduce width and height by the offset amount
            // This matches legacy restore behavior for stacked windows
            // Combined with position offset, creates proper cascade effect
            let calculatedWidth = baseWidth - totalOffset
            let calculatedHeight = baseHeight - totalOffset
            DeskJigLog.info(.window, "  - Calculated size after offset reduction: \(calculatedWidth)×\(calculatedHeight)")

            // Apply minimum size constraints
            let constrainedWidth = max(calculatedWidth, minWindowWidth)
            let constrainedHeight = max(calculatedHeight, minWindowHeight)
            DeskJigLog.info(.window, "  - Size after min constraints: \(constrainedWidth)×\(constrainedHeight)")

            // Calculate position with cascade offset - matches legacy restore behavior
            // Just ADD the offset to both X and Y
            let frameX = baseX + totalOffset
            let frameY = baseY + totalOffset
            DeskJigLog.info(.window, "  - Position after cascade offset: X=\(frameX), Y=\(frameY)")

            // Final boundary checks (additional safety)
            var finalWidth = constrainedWidth
            var finalHeight = constrainedHeight

            let screenRight = screenFrame.origin.x + screenFrame.width
            let rowBottom = rowY + rowHeight

            if (frameX + finalWidth) > screenRight {
                finalWidth = max(screenRight - frameX - windowMargins, minWindowWidth)
                DeskJigLog.info(.window, "  - Width adjusted for right boundary: \(constrainedWidth) → \(finalWidth)")
            }

            if (frameY + finalHeight) > rowBottom {
                finalHeight = max(rowBottom - frameY - windowMargins, minWindowHeight)
                DeskJigLog.info(.window, "  - Height adjusted for bottom boundary: \(constrainedHeight) → \(finalHeight)")
            }

            // Create the frame
            let frame = CGRect(
                x: frameX,
                y: frameY,
                width: finalWidth,
                height: finalHeight
            )

            DeskJigLog.info(.window, "  📍 FINAL FRAME: origin=(\(frame.origin.x), \(frame.origin.y)) size=\(frame.width)×\(frame.height)")
            DeskJigLog.info(.window, "  - Bottom-left (origin): (\(frame.origin.x), \(frame.origin.y))")
            DeskJigLog.info(.window, "  - Bottom-right: (\(frame.maxX), \(frame.origin.y))")
            DeskJigLog.info(.window, "  - Top-left: (\(frame.origin.x), \(frame.maxY))")
            DeskJigLog.info(.window, "  - Top-right: (\(frame.maxX), \(frame.maxY))")
            DeskJigLog.info(.window, "  - Window top Y: \(frame.maxY), Window bottom Y: \(frame.origin.y)")
            DeskJigLog.info(.window, "  - Visual cascade: Window extends from Y=\(frame.origin.y) to Y=\(frame.maxY)")

            let moveSuccess = windowManager.moveWindowToFrame(windowInfo: windowInfo, targetFrame: frame)
            DeskJigLog.info(.window, "  - Move result: \(moveSuccess ? "✅ SUCCESS" : "❌ FAILED")")

            // CRITICAL: Update the placement's windowInfo frame so raiseWindow can find it
            placement.windowInfo.frame = frame
            placements[index] = placement
        }

        // Third pass: Set Z-order by raising windows PER ROW
        // We must process each row independently to avoid cross-row Z-order interference
        DeskJigLog.info(.window, "🔄 Setting Z-order...")

        // Group placements by row
        var placementsByRow = [Int: [WindowPlacement]]()
        for placement in placements {
            if placementsByRow[placement.row] == nil {
                placementsByRow[placement.row] = []
            }
            placementsByRow[placement.row]?.append(placement)
        }

        // Process each row independently
        for row in placementsByRow.keys.sorted() {
            guard let rowPlacements = placementsByRow[row] else { continue }

            DeskJigLog.info(.window, "  Row \(row):")
            // Within each row, raise from lowest to highest cascade level
            for placement in rowPlacements.sorted(by: { $0.cascadeLevel < $1.cascadeLevel }) {
                let success = Window.find(windowId: CGWindowID(placement.windowInfo.id))?.raise() != nil
                let status = success ? "✅" : "❌"
                DeskJigLog.info(.window, "    \(status) Raised \(placement.windowInfo.appName) (cascade level \(placement.cascadeLevel))")
            }
        }
    }

    /// Arrange windows in four quarters (2x2 grid)
    /// - Parameters:
    ///   - windows: Array of windows to tile
    ///   - screenFrame: The positioning frame in WINDOW COORDINATES (top-left origin)
    private func tileQuarters(windows: [WindowInfo], screenFrame: CGRect) {
        guard let windowManager = windowManager else { return }

        // Always use 2x2 grid (4 quadrants)
        let columns = 2
        let rows = 2
        let quadrantWidth = screenFrame.width / CGFloat(columns)
        let quadrantHeight = screenFrame.height / CGFloat(rows)

        // Group windows by app
        var appGroups: [[WindowInfo]] = []
        var processedBundles = Set<String>()

        for window in windows {
            let bundleId = window.bundleIdentifier ?? "unknown"
            if !processedBundles.contains(bundleId) {
                // Find all windows with this bundle identifier
                let appWindows = windows.filter { ($0.bundleIdentifier ?? "unknown") == bundleId }
                appGroups.append(appWindows)
                processedBundles.insert(bundleId)
            }
        }

        // Build a list of windows with their target quadrants and cascade levels
        struct WindowPlacement {
            var windowInfo: WindowInfo  // var instead of let so we can update the frame
            let quadrant: Int  // 0=top-left, 1=top-right, 2=bottom-left, 3=bottom-right
            let cascadeLevel: Int
            let appIndex: Int  // Index within app group for logging
            let appWindowCount: Int  // Total windows in app for logging
        }

        var placements: [WindowPlacement] = []
        var currentQuadrant = 0
        var cascadeLevelsPerQuadrant = [Int](repeating: 0, count: 4)

        // First pass: assign quadrants and cascade levels to all windows
        for appGroup in appGroups {
            let quadrant = currentQuadrant
            let startingCascadeLevel = cascadeLevelsPerQuadrant[quadrant]

            for (index, windowInfo) in appGroup.enumerated() {
                let cascadeLevel = startingCascadeLevel + index
                placements.append(WindowPlacement(
                    windowInfo: windowInfo,
                    quadrant: quadrant,
                    cascadeLevel: cascadeLevel,
                    appIndex: index,
                    appWindowCount: appGroup.count
                ))
            }

            cascadeLevelsPerQuadrant[quadrant] += appGroup.count
            currentQuadrant = (currentQuadrant + 1) % 4
        }

        // Second pass: position all windows and update their frames
        for index in placements.indices {
            var placement = placements[index]
            let windowInfo = placement.windowInfo
            let quadrant = placement.quadrant
            let cascadeLevel = placement.cascadeLevel

            // Calculate quadrant position (0=top-left, 1=top-right, 2=bottom-left, 3=bottom-right)
            let col = quadrant % 2  // 0 or 1
            let row = quadrant / 2  // 0 or 1

            // Base position and size for this quadrant
            let quadrantX = screenFrame.origin.x + (quadrantWidth * CGFloat(col))
            let quadrantY = screenFrame.origin.y + (quadrantHeight * CGFloat(row))
            let baseX = quadrantX + windowMargins
            let baseY = quadrantY + windowMargins
            let baseWidth = quadrantWidth - (windowMargins * 2)
            let baseHeight = quadrantHeight - (windowMargins * 2)

            // Calculate cascade offset for THIS window
            let totalOffset = CGFloat(cascadeLevel) * cascadeOffset

            DeskJigLog.info(.window, "📐 Window \(placement.appIndex + 1)/\(placement.appWindowCount) for \(windowInfo.appName):")
            DeskJigLog.info(.window, "  - Quadrant: \(quadrant) (row: \(row), col: \(col)), Cascade level: \(cascadeLevel)")
            DeskJigLog.info(.window, "  - Base position: (\(baseX), \(baseY)) with size \(baseWidth)×\(baseHeight)")
            DeskJigLog.info(.window, "  - Cascade offset: \(totalOffset) (level \(cascadeLevel) × \(self.cascadeOffset)px)")

            // Reduce width and height by the offset amount
            let calculatedWidth = baseWidth - totalOffset
            let calculatedHeight = baseHeight - totalOffset
            DeskJigLog.info(.window, "  - Calculated size after offset reduction: \(calculatedWidth)×\(calculatedHeight)")

            // Apply minimum size constraints
            let constrainedWidth = max(calculatedWidth, minWindowWidth)
            let constrainedHeight = max(calculatedHeight, minWindowHeight)
            DeskJigLog.info(.window, "  - Size after min constraints: \(constrainedWidth)×\(constrainedHeight)")

            // Calculate position with cascade offset
            let frameX = baseX + totalOffset
            let frameY = baseY + totalOffset
            DeskJigLog.info(.window, "  - Position after cascade offset: X=\(frameX), Y=\(frameY)")

            // Final boundary checks
            var finalWidth = constrainedWidth
            var finalHeight = constrainedHeight

            let quadrantRight = quadrantX + quadrantWidth
            let quadrantBottom = quadrantY + quadrantHeight

            if (frameX + finalWidth) > quadrantRight {
                finalWidth = max(quadrantRight - frameX - windowMargins, minWindowWidth)
                DeskJigLog.info(.window, "  - Width adjusted for right boundary: \(constrainedWidth) → \(finalWidth)")
            }

            if (frameY + finalHeight) > quadrantBottom {
                finalHeight = max(quadrantBottom - frameY - windowMargins, minWindowHeight)
                DeskJigLog.info(.window, "  - Height adjusted for bottom boundary: \(constrainedHeight) → \(finalHeight)")
            }

            // Create the frame
            let frame = CGRect(
                x: frameX,
                y: frameY,
                width: finalWidth,
                height: finalHeight
            )

            DeskJigLog.info(.window, "  📍 FINAL FRAME: origin=(\(frame.origin.x), \(frame.origin.y)) size=\(frame.width)×\(frame.height)")

            let moveSuccess = windowManager.moveWindowToFrame(windowInfo: windowInfo, targetFrame: frame)
            DeskJigLog.info(.window, "  - Move result: \(moveSuccess ? "✅ SUCCESS" : "❌ FAILED")")

            // Update the placement's windowInfo frame so raiseWindow can find it
            placement.windowInfo.frame = frame
            placements[index] = placement
        }

        // Third pass: Set Z-order by raising windows PER QUADRANT
        DeskJigLog.info(.window, "🔄 Setting Z-order...")

        // Group placements by quadrant
        var placementsByQuadrant = [Int: [WindowPlacement]]()
        for placement in placements {
            if placementsByQuadrant[placement.quadrant] == nil {
                placementsByQuadrant[placement.quadrant] = []
            }
            placementsByQuadrant[placement.quadrant]?.append(placement)
        }

        // Process each quadrant independently
        for quadrant in placementsByQuadrant.keys.sorted() {
            guard let quadrantPlacements = placementsByQuadrant[quadrant] else { continue }

            DeskJigLog.info(.window, "  Quadrant \(quadrant):")
            // Within each quadrant, raise from lowest to highest cascade level
            for placement in quadrantPlacements.sorted(by: { $0.cascadeLevel < $1.cascadeLevel }) {
                let success = Window.find(windowId: CGWindowID(placement.windowInfo.id))?.raise() != nil
                let status = success ? "✅" : "❌"
                DeskJigLog.info(.window, "    \(status) Raised \(placement.windowInfo.appName) (cascade level \(placement.cascadeLevel))")
            }
        }
    }

    // MARK: - Configuration Methods

    /// Update the main pane ratio (0.0 - 1.0)
    public func setMainPaneRatio(_ ratio: CGFloat) {
        mainPaneRatio = max(0.1, min(0.9, ratio))
    }

    /// Update the number of windows in the main pane
    public func setMainPaneCount(_ count: Int) {
        mainPaneCount = max(1, count)
    }

    /// Update window margins
    public func setWindowMargins(_ margins: CGFloat) {
        windowMargins = max(0, margins)
    }
}
