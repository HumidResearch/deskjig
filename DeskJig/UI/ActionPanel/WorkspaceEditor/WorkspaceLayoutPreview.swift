//  WorkspaceLayoutPreview.swift
//  DeskJig
//
//  Workspace layout preview showing windows on screens
//

import SwiftUI
import AppKit
import DeskJigShared

let workspacePreviewAccentColor = Color(red: 0.31, green: 0.58, blue: 0.98)

struct WorkspaceLayoutPreview: View {
    let windows: [WorkspaceWindow]
    let screens: [WorkspaceScreen]
    var screenFilter: Set<Int> = []
    var height: CGFloat = 110
    var showLabels: Bool = true
    var showBackground: Bool = true
    var isInEditMode: Bool = false
    var selectedWindowId: UUID? = nil
    let iconProvider: (WorkspaceWindow) -> NSImage?
    var onWindowTapped: ((WorkspaceWindow) -> Void)? = nil
    var onRefresh: (() -> Void)? = nil

    private let maxWindowsPerScreen = 8

    private var resolvedScreens: [ScreenRepresentation] {
        let filtered: [ScreenRepresentation]
        if screens.isEmpty {
            filtered = [ScreenRepresentation(index: 0, title: "Monitor 1", aspectRatio: 16.0 / 9.0, isPrimary: true)]
        } else {
            filtered = screens.enumerated().compactMap { index, screen in
                if !screenFilter.isEmpty && !screenFilter.contains(index) {
                    return nil
                }
                return ScreenRepresentation(index: index, title: title(for: screen, index: index), aspectRatio: aspectRatio(for: screen), isPrimary: screen.isPrimary)
            }
        }

        return filtered.isEmpty ? [ScreenRepresentation(index: 0, title: "Monitor", aspectRatio: 16.0 / 9.0, isPrimary: false)] : filtered
    }

    private var filteredScreenIndices: Set<Int> {
        Set(resolvedScreens.map(\.index))
    }

    private var windowsByScreen: [Int: [WorkspaceWindow]] {
        windows.reduce(into: [:]) { result, window in
            guard let index = window.screenIndex, filteredScreenIndices.contains(index) else { return }
            result[index, default: []].append(window)
        }
    }

    private var unassignedWindows: [WorkspaceWindow] {
        windows.filter { window in
            guard let index = window.screenIndex else { return true }
            return !filteredScreenIndices.contains(index)
        }
    }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
                ForEach(resolvedScreens) { screen in
                    ScreenPreview(
                        screen: screen,
                        windows: windowsByScreen[screen.index] ?? [],
                        iconProvider: iconProvider,
                        showLabel: showLabels,
                        height: height,
                        maxWindows: maxWindowsPerScreen,
                        isInEditMode: isInEditMode,
                        selectedWindowId: selectedWindowId,
                        onWindowTapped: onWindowTapped
                    )
                }

                if !unassignedWindows.isEmpty {
                    ScreenPreview(
                        screen: ScreenRepresentation(index: -1, title: "Unassigned", aspectRatio: 1.6, isPrimary: false),
                        windows: unassignedWindows,
                        iconProvider: iconProvider,
                        showLabel: showLabels,
                        height: height,
                        maxWindows: maxWindowsPerScreen,
                        isInEditMode: isInEditMode,
                        selectedWindowId: selectedWindowId,
                        onWindowTapped: onWindowTapped
                    )
                }
            }
            .padding(.vertical, 4)
            .frame(height: height)
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 8)
        .background(
            Group {
                if showBackground {
                    RoundedRectangle(cornerRadius: 18)
                        .fill(DesignTokens.Preview.containerFill)
                        .overlay(
                            RoundedRectangle(cornerRadius: 18)
                                .stroke(DesignTokens.Preview.containerStroke, lineWidth: 1)
                        )
                }
            }
        )
        .frame(height: height + 40)
        .overlay(alignment: .topTrailing) {
            if let onRefresh {
                Button(action: onRefresh) {
                    Image(systemName: "arrow.clockwise")
                        .font(brand: Font.brandBody(size: 10))
                        .foregroundStyle(DesignTokens.Text.tertiary)
                        .frame(width: 18, height: 18)
                        .background(
                            Circle()
                                .fill(DesignTokens.Surface.elevated)
                        )
                        .brightenOnHover()
                }
                .buttonStyle(.plain)
                .padding(.top, 22)
                .padding(.trailing, 14)
                .help("Refresh visible apps")
            }
        }
    }

    private func title(for screen: WorkspaceScreen, index: Int) -> String {
        // Simple position-based naming: Monitor 1 is leftmost, Monitor 2 is next, etc.
        // This matches the physical left-to-right ordering from DisplayManager
        return "Monitor \(index + 1)"
    }

    private func aspectRatio(for screen: WorkspaceScreen) -> CGFloat {
        let width = max(screen.frame.width, 1)
        let height = max(screen.frame.height, 1)
        let ratio = width / height
        return ratio.isFinite ? ratio : 1.6
    }

    private struct ScreenRepresentation: Identifiable {
        let index: Int
        let title: String
        let aspectRatio: CGFloat
        let isPrimary: Bool

        var id: Int { index }
    }

    private struct ScreenPreview: View {
        let screen: ScreenRepresentation
        let windows: [WorkspaceWindow]
        let iconProvider: (WorkspaceWindow) -> NSImage?
        let showLabel: Bool
        let height: CGFloat
        let maxWindows: Int
        var isInEditMode: Bool = false
        var selectedWindowId: UUID? = nil
        var onWindowTapped: ((WorkspaceWindow) -> Void)? = nil
        private let layoutInset: CGFloat = 4
        private let minimumWindowPreviewSize: CGFloat = 12
        private let windowScale: CGFloat = 0.95
        private var displayFillColor: Color { DesignTokens.Preview.monitorFill }
        private var displayStrokeColor: Color { screen.isPrimary ? DesignTokens.Preview.monitorStrokePrimary : DesignTokens.Preview.monitorStrokeSecondary }

        private var contentHeight: CGFloat {
            showLabel ? height - 18 : height
        }

        private var width: CGFloat {
            let fixedRatio: CGFloat = 1.6
            return contentHeight * fixedRatio
        }

        var body: some View {
            VStack(alignment: .leading, spacing: 6) {
                GeometryReader { geometry in
                    let shadowPadding: CGFloat = 8
                    let adjustedSize = CGSize(
                        width: geometry.size.width - shadowPadding * 2,
                        height: geometry.size.height - shadowPadding * 2
                    )
                    let iconSize = iconSize(for: adjustedSize)
                    let limitedWindows = Array(windows.prefix(maxWindows))
                    let layoutRects = layoutRectangles(for: limitedWindows, in: adjustedSize)
                    let layoutLookup = Dictionary(uniqueKeysWithValues: layoutRects.map { ($0.id, $0.rect) })
                    let entries = previewEntries(
                        for: limitedWindows,
                        size: adjustedSize,
                        iconSize: iconSize,
                        layoutLookup: layoutLookup
                    )
                    ZStack(alignment: .topLeading) {
                        // Monitor frame - keep consistent with card radius
                        RoundedRectangle(cornerRadius: DesignTokens.Card.cornerRadius)
                            .fill(displayFillColor)
                            .overlay(
                                RoundedRectangle(cornerRadius: DesignTokens.Card.cornerRadius)
                                    .stroke(displayStrokeColor, lineWidth: screen.isPrimary ? 1.6 : 1)
                            )
                            .shadow(
                                color: Color.black.opacity(DesignTokens.Shadow.small.opacity),
                                radius: DesignTokens.Shadow.small.radius,
                                x: 0,
                                y: DesignTokens.Shadow.small.y
                            )

                        // Render each window's rect and icon together to maintain proper Z-order
                        // Windows are sorted topmost-first (lower windowLevel = front), but SwiftUI renders
                        // later views on top, so we reverse to render back-to-front (topmost last)
                        ForEach(limitedWindows.reversed()) { window in
                            // Window rectangle (if it has a relative frame)
                            if let rect = layoutLookup[window.id] {
                                WindowPreviewRect(
                                    rect: rect,
                                    onTap: {
                                        onWindowTapped?(window)
                                    }
                                )
                            }

                            // App icon for this window
                            if let entry = entries.first(where: { $0.id == window.id }) {
                                WindowPreviewIcon(
                                    icon: entry.icon,
                                    fallback: entry.fallback,
                                    size: iconSize,
                                    position: entry.position,
                                    onTap: {
                                        onWindowTapped?(window)
                                    },
                                    appType: SpecialAppType.from(bundleIdentifier: window.bundleIdentifier),
                                    isInEditMode: isInEditMode,
                                    isSelected: selectedWindowId == window.id
                                )
                            }
                        }

                        if windows.count > maxWindows {
                            let overflow = windows.count - maxWindows
                            Text("+\(overflow)")
                                .font(.system(size: iconSize * 0.45, weight: .semibold))
                                .foregroundStyle(DesignTokens.Text.primary)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(
                                    Capsule().fill(DesignTokens.Surface.cardHover)
                                )
                                .position(x: adjustedSize.width - iconSize * 0.7, y: adjustedSize.height - iconSize * 0.6)
                        }
                    }
                    .frame(width: adjustedSize.width, height: adjustedSize.height)
                    .offset(x: shadowPadding, y: shadowPadding)
                }
                .frame(width: width, height: contentHeight)

                if showLabel {
                    Text(screen.title)
                        .font(brand: .label4)
                        .foregroundStyle(DesignTokens.Text.secondary)
                }
            }
            .frame(width: width)
        }

        private func iconSize(for size: CGSize) -> CGFloat {
            let base = min(size.width, size.height) * 0.30
            return max(20, min(42, base))
        }

        private func previewEntries(
            for windowsSubset: [WorkspaceWindow],
            size: CGSize,
            iconSize: CGFloat,
            layoutLookup: [UUID: CGRect]
        ) -> [WindowPreviewEntry] {
            let bounds = layoutBounds(for: size)
            let fallbackCount = windowsSubset.filter { layoutLookup[$0.id] == nil }.count
            let insetBounds = adjustedFallbackBounds(for: bounds, iconSize: iconSize)
            let fallbackPositions = gridPositions(count: fallbackCount, in: insetBounds)
            var fallbackIndex = 0

            return windowsSubset.map { window in
                let image = iconProvider(window)
                let fallback = window.appName
                let position: CGPoint

                if let rect = layoutLookup[window.id] {
                    position = CGPoint(x: rect.midX, y: rect.midY)
                } else if fallbackIndex < fallbackPositions.count {
                    position = fallbackPositions[fallbackIndex]
                    fallbackIndex += 1
                } else {
                    position = CGPoint(x: bounds.midX, y: bounds.midY)
                }

                return WindowPreviewEntry(id: window.id, window: window, icon: image, fallback: fallback, position: position)
            }
        }

        private func layoutRectangles(for windowsSubset: [WorkspaceWindow], in size: CGSize) -> [WindowLayoutRectEntry] {
            let bounds = layoutBounds(for: size)
            guard bounds.width > 0, bounds.height > 0 else { return [] }
            let relativeFrames = windowsSubset.compactMap { $0.relativeFrame }
            let normalizer = WindowLayoutNormalizer(frames: relativeFrames)

            return windowsSubset.compactMap { window in
                guard
                    let relative = window.relativeFrame,
                    let normalized = normalizer.normalizedRect(for: relative)
                else { return nil }
                let rect = layoutRect(fromNormalized: normalized, within: bounds)
                return WindowLayoutRectEntry(id: window.id, window: window, rect: rect)
            }
        }

        private func gridPositions(count: Int, in bounds: CGRect) -> [CGPoint] {
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

        private func layoutBounds(for size: CGSize) -> CGRect {
            let availableWidth = max(0, size.width - layoutInset * 2)
            let availableHeight = max(0, size.height - layoutInset * 2)
            let scaledWidth = availableWidth * windowScale
            let scaledHeight = availableHeight * windowScale
            let originX = layoutInset + (availableWidth - scaledWidth) / 2
            let originY = layoutInset + (availableHeight - scaledHeight) / 2
            return CGRect(x: originX, y: originY, width: scaledWidth, height: scaledHeight)
        }

        private func adjustedFallbackBounds(for bounds: CGRect, iconSize: CGFloat) -> CGRect {
            let inset = iconSize / 2 + 2
            let width = bounds.width - inset * 2
            let height = bounds.height - inset * 2
            guard width > 0, height > 0 else { return bounds }
            return CGRect(x: bounds.minX + inset, y: bounds.minY + inset, width: width, height: height)
        }

        private func layoutRect(fromNormalized normalized: CGRect, within bounds: CGRect) -> CGRect {
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

        private struct WindowPreviewEntry: Identifiable {
            let id: UUID
            let window: WorkspaceWindow
            let icon: NSImage?
            let fallback: String
            let position: CGPoint
        }

        private struct WindowLayoutRectEntry: Identifiable {
            let id: UUID
            let window: WorkspaceWindow
            let rect: CGRect
        }

        private struct WindowLayoutNormalizer {
            private let padding: CGFloat
            private let minNormalizedSize: CGFloat = 0.04

            init(frames: [RelativeWindowFrame]) {
                // Padding is fixed so windows retain their real relative placement
                padding = frames.count > 1 ? 0.04 : 0.02
            }

            func normalizedRect(for frame: RelativeWindowFrame) -> CGRect? {
                let availableWidth = max(0, 1 - padding * 2)
                let availableHeight = max(0, 1 - padding * 2)

                var normalizedWidth = CGFloat(frame.widthPercent) * availableWidth
                var normalizedHeight = CGFloat(frame.heightPercent) * availableHeight
                var normalizedX = padding + CGFloat(frame.xPercent) * availableWidth
                var normalizedY = padding + CGFloat(frame.yPercent) * availableHeight

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
    }
}

struct WorkspaceLayoutAppIcon: View {
    let icon: NSImage?
    let fallback: String
    let size: CGFloat

    // Mockup uses small corner radius (~4px), more square appearance
    private var cornerRadius: CGFloat { min(4, size * 0.15) }

    var body: some View {
        Group {
            if let icon {
                Image(nsImage: icon)
                    .resizable()
                    .scaledToFit()
            } else {
                // Fallback: show first letter
                Text(String(fallback.prefix(1)).uppercased())
                    .font(.system(size: size * 0.45, weight: .bold))
                    .foregroundStyle(DesignTokens.Text.primary.opacity(0.8))
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
    }
}
