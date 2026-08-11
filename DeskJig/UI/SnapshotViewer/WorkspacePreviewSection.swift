//
//  WorkspacePreviewSection.swift
//  DeskJig
//
//  Visual layout preview for workspace windows in the SnapshotViewer.
//  Uses muted neutral colors with a single primary accent for clarity.
//

import SwiftUI
import AppKit
import DeskJigShared

// MARK: - Debug Preview Colors

private enum DebugPreviewColors {
    /// Default window color (muted gray)
    static let defaultFill = DesignTokens.Surface.cardHover
    static let defaultStroke = DesignTokens.Border.regular

    /// Chrome windows (accent tint)
    static let chromeFill = DesignTokens.Brand.accent.opacity(0.12)
    static let chromeStroke = DesignTokens.Brand.accent.opacity(0.5)

    /// Terminal/IDE windows with openPath (neutral)
    static let openPathFill = DesignTokens.Surface.elevated
    static let openPathStroke = DesignTokens.Border.prominent

    /// Selected window
    static let selectedStroke = DesignTokens.Brand.accent

    /// Display background
    static let displayFill = DesignTokens.Surface.card
    static let displayStroke = DesignTokens.Border.subtle
    static let primaryDisplayStroke = DesignTokens.Border.prominent
}

// MARK: - Workspace Preview Section

struct WorkspacePreviewSection: View {
    let windows: [WorkspaceWindow]
    let screens: [WorkspaceScreen]?
    let iconProvider: (WorkspaceWindow) -> NSImage?
    var selectedWindowId: UUID? = nil
    var onWindowTapped: ((WorkspaceWindow) -> Void)? = nil

    // Screen mapping support
    var currentSystemScreens: [ScreenOption] = []
    var screenMappings: [Int: Int] = [:]
    var onScreenMappingChanged: ((Int, Int?) -> Void)? = nil

    private let previewHeight: CGFloat = 110  // Increased to accommodate picker
    private let maxWindowsPerScreen = 8

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Header
            HStack {
                Text("Layout Preview")
                    .font(.subheadline)
                    .fontWeight(.semibold)
                    .foregroundStyle(.secondary)

                Spacer()

                // Legend
                legendView
            }

            // Preview content
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(resolvedScreens) { screen in
                        DebugScreenPreview(
                            screen: screen,
                            windows: windowsByScreen[screen.index] ?? [],
                            selectedWindowId: selectedWindowId,
                            iconProvider: iconProvider,
                            height: previewHeight,
                            maxWindows: maxWindowsPerScreen,
                            onWindowTapped: onWindowTapped,
                            currentSystemScreens: currentSystemScreens,
                            screenMapping: screenMappings[screen.index],
                            onScreenMappingChanged: onScreenMappingChanged != nil ? { targetIndex in
                                onScreenMappingChanged?(screen.index, targetIndex)
                            } : nil
                        )
                    }

                    if !unassignedWindows.isEmpty {
                        DebugScreenPreview(
                            screen: PreviewScreenInfo(index: -1, title: "Unassigned", aspectRatio: 1.6, isPrimary: false),
                            windows: unassignedWindows,
                            selectedWindowId: selectedWindowId,
                            iconProvider: iconProvider,
                            height: previewHeight,
                            maxWindows: maxWindowsPerScreen,
                            onWindowTapped: onWindowTapped,
                            currentSystemScreens: [],  // No mapping for unassigned
                            screenMapping: nil,
                            onScreenMappingChanged: nil
                        )
                    }
                }
                .padding(.vertical, 4)
            }
            .frame(height: previewHeight + 34)  // Extra space for picker
            .padding(8)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.black.opacity(0.2))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(Color.white.opacity(0.08), lineWidth: 1)
                    )
            )
        }
    }

    // MARK: - Legend

    private var legendView: some View {
        HStack(spacing: 12) {
            legendItem(color: DebugPreviewColors.defaultStroke, label: "Default")
            legendItem(color: DebugPreviewColors.chromeStroke, label: "Chrome")
            legendItem(color: DebugPreviewColors.openPathStroke, label: "With Path")
        }
    }

    private func legendItem(color: Color, label: String) -> some View {
        HStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 2)
                .fill(color.opacity(0.3))
                .overlay(RoundedRectangle(cornerRadius: 2).stroke(color, lineWidth: 1))
                .frame(width: 10, height: 10)
            Text(label)
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    // MARK: - Screen Resolution

    struct PreviewScreenInfo: Identifiable {
        let index: Int
        let title: String
        let aspectRatio: CGFloat
        let isPrimary: Bool
        var id: Int { index }
    }

    private var resolvedScreens: [PreviewScreenInfo] {
        guard let screens = screens, !screens.isEmpty else {
            return [PreviewScreenInfo(index: 0, title: "Display 1", aspectRatio: 16.0 / 9.0, isPrimary: true)]
        }

        return screens.enumerated().map { index, screen in
            PreviewScreenInfo(
                index: index,
                title: screenTitle(for: screen, index: index),
                aspectRatio: aspectRatio(for: screen),
                isPrimary: screen.isPrimary
            )
        }
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

    private func screenTitle(for screen: WorkspaceScreen, index: Int) -> String {
        var components: [String] = []
        if screen.name.isEmpty {
            components.append("Display \(index)")
        } else {
            components.append(screen.name)
        }
        if screen.isPrimary {
            components.append("Primary")
        }
        return components.joined(separator: " \u{2022} ")
    }

    private func aspectRatio(for screen: WorkspaceScreen) -> CGFloat {
        let width = max(screen.frame.width, 1)
        let height = max(screen.frame.height, 1)
        let ratio = width / height
        return ratio.isFinite ? ratio : 1.6
    }
}

// MARK: - Debug Screen Preview

private struct DebugScreenPreview: View {
    let screen: WorkspacePreviewSection.PreviewScreenInfo
    let windows: [WorkspaceWindow]
    let selectedWindowId: UUID?
    let iconProvider: (WorkspaceWindow) -> NSImage?
    let height: CGFloat
    let maxWindows: Int
    var onWindowTapped: ((WorkspaceWindow) -> Void)?

    // Screen mapping support
    var currentSystemScreens: [ScreenOption] = []
    var screenMapping: Int? = nil
    var onScreenMappingChanged: ((Int?) -> Void)? = nil

    private let layoutInset: CGFloat = 4
    private let minimumWindowPreviewSize: CGFloat = 10
    private let windowScale: CGFloat = 0.88

    private var contentHeight: CGFloat { height - 36 }  // Reduced to make room for picker
    private var width: CGFloat { contentHeight * 1.6 }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            GeometryReader { geometry in
                let shadowPadding: CGFloat = 6
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
                    // Display background
                    RoundedRectangle(cornerRadius: 10)
                        .fill(DebugPreviewColors.displayFill)
                        .overlay(
                            RoundedRectangle(cornerRadius: 10)
                                .stroke(
                                    screen.isPrimary ? DebugPreviewColors.primaryDisplayStroke : DebugPreviewColors.displayStroke,
                                    lineWidth: screen.isPrimary ? 1.5 : 1
                                )
                        )

                    // Windows (back-to-front)
                    ForEach(limitedWindows.reversed()) { window in
                        if let rect = layoutLookup[window.id] {
                            DebugWindowRect(
                                window: window,
                                rect: rect,
                                isSelected: selectedWindowId == window.id,
                                onTap: { onWindowTapped?(window) }
                            )
                        }

                        // App icon
                        if let entry = entries.first(where: { $0.id == window.id }) {
                            DebugWindowIcon(
                                icon: entry.icon,
                                fallback: entry.fallback,
                                size: iconSize,
                                position: entry.position,
                                window: window,
                                isSelected: selectedWindowId == window.id,
                                onTap: { onWindowTapped?(window) }
                            )
                        }
                    }

                    // Overflow indicator
                    if windows.count > maxWindows {
                        let overflow = windows.count - maxWindows
                        Text("+\(overflow)")
                            .font(.system(size: iconSize * 0.4, weight: .semibold))
                            .foregroundStyle(DesignTokens.Text.primary)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(Color.black.opacity(0.5)))
                            .position(x: adjustedSize.width - iconSize * 0.6, y: adjustedSize.height - iconSize * 0.5)
                    }
                }
                .frame(width: adjustedSize.width, height: adjustedSize.height)
                .offset(x: shadowPadding, y: shadowPadding)
            }
            .frame(width: width, height: contentHeight)

            // Screen label
            Text(screen.title)
                .font(brand: Font.brandBody(size: 10))
                .foregroundStyle(DesignTokens.Text.primary.opacity(0.6))

            // Screen mapping picker
            if let onMappingChanged = onScreenMappingChanged, !currentSystemScreens.isEmpty {
                screenMappingPicker(onMappingChanged: onMappingChanged)
            }
        }
        .frame(width: width)
    }

    // MARK: - Screen Mapping Picker

    @ViewBuilder
    private func screenMappingPicker(onMappingChanged: @escaping (Int?) -> Void) -> some View {
        HStack(spacing: 4) {
            Image(systemName: screenMapping != nil ? "arrow.right.circle.fill" : "arrow.right.circle")
                .font(brand: Font.brandBody(size: 9))
                .foregroundStyle(screenMapping != nil ? DesignTokens.Brand.accent : .secondary)

            Picker("", selection: Binding(
                get: { screenMapping },
                set: { onMappingChanged($0) }
            )) {
                Text("Original").tag(nil as Int?)
                ForEach(currentSystemScreens) { screen in
                    Text(screen.label).tag(screen.index as Int?)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .scaleEffect(0.85, anchor: .leading)
        }
        .frame(height: 16)
    }

    // MARK: - Layout Helpers

    private func iconSize(for size: CGSize) -> CGFloat {
        let base = min(size.width, size.height) * 0.2
        return max(14, min(26, base))
    }

    private struct PreviewEntry: Identifiable {
        let id: UUID
        let icon: NSImage?
        let fallback: String
        let position: CGPoint
    }

    private func previewEntries(
        for windowsSubset: [WorkspaceWindow],
        size: CGSize,
        iconSize: CGFloat,
        layoutLookup: [UUID: CGRect]
    ) -> [PreviewEntry] {
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

            return PreviewEntry(id: window.id, icon: image, fallback: fallback, position: position)
        }
    }

    private struct LayoutRectEntry: Identifiable {
        let id: UUID
        let rect: CGRect
    }

    private func layoutRectangles(for windowsSubset: [WorkspaceWindow], in size: CGSize) -> [LayoutRectEntry] {
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
            return LayoutRectEntry(id: window.id, rect: rect)
        }
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
        let spacing: CGFloat = 2
        return CGRect(
            x: x + spacing,
            y: y + spacing,
            width: max(minimumWindowPreviewSize, width - spacing * 2),
            height: max(minimumWindowPreviewSize, height - spacing * 2)
        )
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

    // MARK: - Window Layout Normalizer

    private struct WindowLayoutNormalizer {
        private let padding: CGFloat

        init(frames: [RelativeWindowFrame]) {
            padding = frames.count > 1 ? 0.08 : 0.05
        }

        func normalizedRect(for frame: RelativeWindowFrame) -> CGRect? {
            let availableWidth = max(0, 1 - padding * 2)
            let availableHeight = max(0, 1 - padding * 2)

            var normalizedWidth = CGFloat(frame.widthPercent) * availableWidth
            var normalizedHeight = CGFloat(frame.heightPercent) * availableHeight
            var normalizedX = padding + CGFloat(frame.xPercent) * availableWidth
            var normalizedY = padding + CGFloat(frame.yPercent) * availableHeight

            let minSize: CGFloat = 0.04
            normalizedWidth = max(minSize, normalizedWidth)
            normalizedHeight = max(minSize, normalizedHeight)

            let maxX = 1 - padding - normalizedWidth
            let maxY = 1 - padding - normalizedHeight
            normalizedX = min(max(normalizedX, padding), maxX)
            normalizedY = min(max(normalizedY, padding), maxY)

            return CGRect(x: normalizedX, y: normalizedY, width: normalizedWidth, height: normalizedHeight)
        }
    }
}

// MARK: - Debug Window Rect

private struct DebugWindowRect: View {
    let window: WorkspaceWindow
    let rect: CGRect
    let isSelected: Bool
    let onTap: () -> Void

    private var isChrome: Bool {
        chromeBundleIdentifiers.contains(window.bundleIdentifier)
    }

    private var hasOpenPath: Bool {
        window.openPath != nil || OpenByPathBundleIdentifiers.supported.contains(window.bundleIdentifier)
    }

    private var fillColor: Color {
        if isChrome {
            return DebugPreviewColors.chromeFill
        } else if hasOpenPath {
            return DebugPreviewColors.openPathFill
        }
        return DebugPreviewColors.defaultFill
    }

    private var strokeColor: Color {
        if isSelected {
            return DebugPreviewColors.selectedStroke
        }
        if isChrome {
            return DebugPreviewColors.chromeStroke
        } else if hasOpenPath {
            return DebugPreviewColors.openPathStroke
        }
        return DebugPreviewColors.defaultStroke
    }

    var body: some View {
        RoundedRectangle(cornerRadius: 3)
            .fill(fillColor)
            .overlay(
                RoundedRectangle(cornerRadius: 3)
                    .stroke(strokeColor, lineWidth: isSelected ? 2 : 1)
            )
            .frame(width: rect.width, height: rect.height)
            .position(x: rect.midX, y: rect.midY)
            .contentShape(Rectangle())
            .onTapGesture(perform: onTap)
    }
}

// MARK: - Debug Window Icon

private struct DebugWindowIcon: View {
    let icon: NSImage?
    let fallback: String
    let size: CGFloat
    let position: CGPoint
    let window: WorkspaceWindow
    let isSelected: Bool
    let onTap: () -> Void

    private var isChrome: Bool {
        chromeBundleIdentifiers.contains(window.bundleIdentifier)
    }

    private var hasOpenPath: Bool {
        window.openPath != nil || OpenByPathBundleIdentifiers.supported.contains(window.bundleIdentifier)
    }

    private var accentColor: Color {
        if isSelected {
            return DebugPreviewColors.selectedStroke
        }
        if isChrome {
            return DebugPreviewColors.chromeStroke
        } else if hasOpenPath {
            return DebugPreviewColors.openPathStroke
        }
        return DebugPreviewColors.defaultStroke
    }

    var body: some View {
        Group {
            if let icon {
                Image(nsImage: icon)
                    .resizable()
                    .scaledToFit()
            } else {
                Text(String(fallback.prefix(1)).uppercased())
                    .font(.system(size: size * 0.4, weight: .bold))
                    .foregroundStyle(DesignTokens.Text.primary)
            }
        }
        .frame(width: size, height: size)
        .background(
            RoundedRectangle(cornerRadius: size * 0.25)
                .fill(accentColor.opacity(0.2))
                .overlay(
                    RoundedRectangle(cornerRadius: size * 0.25)
                        .stroke(accentColor.opacity(0.6), lineWidth: isSelected ? 1.5 : 0.8)
                )
        )
        .clipShape(RoundedRectangle(cornerRadius: size * 0.25))
        .position(position)
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
    }
}
