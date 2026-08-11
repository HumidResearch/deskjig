//
//  DSLayoutNormalizer.swift
//  DeskJig
//
//  Created by Claude Code on 02/02/26.
//

import SwiftUI

// MARK: - Layout Normalizer

/// A utility for normalizing window positions within a preview container.
/// Takes relative window frames (percentages) and calculates normalized positions
/// within the available preview bounds.
struct DSLayoutNormalizer {
    private let padding: CGFloat
    private let minNormalizedSize: CGFloat = 0.04

    /// Initialize with a set of relative frames to determine appropriate padding
    init(frameCount: Int) {
        // Padding is fixed so windows retain their real relative placement
        padding = frameCount > 1 ? 0.04 : 0.02
    }

    /// Calculate the normalized rect for a relative frame
    /// - Parameters:
    ///   - xPercent: X position as percentage (0-1)
    ///   - yPercent: Y position as percentage (0-1)
    ///   - widthPercent: Width as percentage (0-1)
    ///   - heightPercent: Height as percentage (0-1)
    /// - Returns: A normalized CGRect within the 0-1 coordinate space
    func normalizedRect(
        xPercent: Double,
        yPercent: Double,
        widthPercent: Double,
        heightPercent: Double
    ) -> CGRect {
        let availableWidth = max(0, 1 - padding * 2)
        let availableHeight = max(0, 1 - padding * 2)

        var normalizedWidth = CGFloat(widthPercent) * availableWidth
        var normalizedHeight = CGFloat(heightPercent) * availableHeight
        var normalizedX = padding + CGFloat(xPercent) * availableWidth
        var normalizedY = padding + CGFloat(yPercent) * availableHeight

        normalizedWidth = max(minNormalizedSize, normalizedWidth)
        normalizedHeight = max(minNormalizedSize, normalizedHeight)

        let maxX = 1 - padding - normalizedWidth
        let maxY = 1 - padding - normalizedHeight
        normalizedX = clamp(normalizedX, min: padding, max: maxX)
        normalizedY = clamp(normalizedY, min: padding, max: maxY)

        return CGRect(x: normalizedX, y: normalizedY, width: normalizedWidth, height: normalizedHeight)
    }

    private func clamp(_ value: CGFloat, min: CGFloat, max: CGFloat) -> CGFloat {
        guard min < max else { return min }
        return Swift.min(Swift.max(value, min), max)
    }
}

// MARK: - Layout Bounds Calculator

/// Calculates the bounds for window layout within a preview container
struct DSLayoutBoundsCalculator {
    let layoutInset: CGFloat
    let windowScale: CGFloat
    let minimumWindowPreviewSize: CGFloat

    init(
        layoutInset: CGFloat = 4,
        windowScale: CGFloat = 0.95,
        minimumWindowPreviewSize: CGFloat = 12
    ) {
        self.layoutInset = layoutInset
        self.windowScale = windowScale
        self.minimumWindowPreviewSize = minimumWindowPreviewSize
    }

    /// Calculate the layout bounds for a given container size
    func layoutBounds(for size: CGSize) -> CGRect {
        let availableWidth = max(0, size.width - layoutInset * 2)
        let availableHeight = max(0, size.height - layoutInset * 2)
        let scaledWidth = availableWidth * windowScale
        let scaledHeight = availableHeight * windowScale
        let originX = layoutInset + (availableWidth - scaledWidth) / 2
        let originY = layoutInset + (availableHeight - scaledHeight) / 2
        return CGRect(x: originX, y: originY, width: scaledWidth, height: scaledHeight)
    }

    /// Calculate adjusted bounds for fallback icon grid positioning
    func adjustedFallbackBounds(for bounds: CGRect, iconSize: CGFloat) -> CGRect {
        let inset = iconSize / 2 + 2
        let width = bounds.width - inset * 2
        let height = bounds.height - inset * 2
        guard width > 0, height > 0 else { return bounds }
        return CGRect(x: bounds.minX + inset, y: bounds.minY + inset, width: width, height: height)
    }

    /// Convert a normalized rect to a layout rect within bounds
    func layoutRect(fromNormalized normalized: CGRect, within bounds: CGRect) -> CGRect {
        let width = max(minimumWindowPreviewSize, normalized.width * bounds.width)
        let height = max(minimumWindowPreviewSize, normalized.height * bounds.height)
        let x = bounds.minX + normalized.origin.x * bounds.width
        let y = bounds.minY + normalized.origin.y * bounds.height

        // Add spacing between boxes by insetting each rectangle
        let spacing: CGFloat = 2
        return CGRect(
            x: x + spacing,
            y: y + spacing,
            width: max(minimumWindowPreviewSize, width - spacing * 2),
            height: max(minimumWindowPreviewSize, height - spacing * 2)
        )
    }

    /// Calculate grid positions for icons without layout frames
    func gridPositions(count: Int, in bounds: CGRect) -> [CGPoint] {
        guard count > 0, bounds.width > 0, bounds.height > 0 else { return [] }
        let columns = Int(ceil(sqrt(Double(count))))
        let rows = Int(ceil(Double(count) / Double(columns)))
        let cellWidth = bounds.width / CGFloat(columns)
        let cellHeight = bounds.height / CGFloat(rows)

        var positions: [CGPoint] = []
        var remaining = count

        for row in 0..<rows {
            let itemsInRow = min(columns, remaining)
            remaining -= itemsInRow

            // Center each row's subset by offsetting the unused column space equally on both sides.
            let rowWidth = CGFloat(itemsInRow) * cellWidth
            let rowStartX = bounds.minX + (bounds.width - rowWidth) / 2
            let y = bounds.minY + cellHeight * (CGFloat(row) + 0.5)

            for column in 0..<itemsInRow {
                let x = rowStartX + cellWidth * (CGFloat(column) + 0.5)
                positions.append(CGPoint(x: x, y: y))
            }
        }

        return positions
    }

    /// Calculate icon size based on container size
    func iconSize(for size: CGSize) -> CGFloat {
        let base = min(size.width, size.height) * 0.30
        return max(20, min(42, base))
    }
}
