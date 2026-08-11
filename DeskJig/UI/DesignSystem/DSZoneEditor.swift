//
//  DSZoneEditor.swift
//  DeskJig
//
//  Created by Codex on 02/03/26.
//

import SwiftUI
import AppKit
import DeskJigShared

struct DSZoneApp: Identifiable {
    let id: UUID
    let name: String
    let icon: NSImage?
    let specialAppType: DSSpecialAppType?
}

struct DSZone: Identifiable {
    let id: UUID
    let frame: RelativeWindowFrame
    let app: DSZoneApp?
    let stackCount: Int
    let isSelected: Bool
    let isFocused: Bool
    let canSplitVertical: Bool
    let canSplitHorizontal: Bool
}

private enum DSZoneResizeHandleAxis {
    case vertical
    case horizontal
}

private struct DSZoneResizeHandleDescriptor: Identifiable, Hashable {
    let key: String
    let axis: DSZoneResizeHandleAxis
    let position: Double
    let rangeStart: Double
    let rangeEnd: Double

    var id: String {
        key
    }
}

struct DSZoneEditor: View {
    let zones: [DSZone]
    let onDrop: (String, UUID) -> Bool
    let onSelectApp: (UUID) -> Void
    let onSplitVertical: (UUID) -> Void
    let onSplitHorizontal: (UUID) -> Void
    let onCloseZone: (UUID) -> Void
    let onSelectZone: (UUID) -> Void
    var onResizeBoundary: ((WorkspaceDraftViewModel.ZoneResizeAxis, Double, ClosedRange<Double>, Double) -> Void)? = nil
    var onSelectMonitor: (() -> Void)? = nil
    var isPrimary: Bool = true
    var isSelectedMonitor: Bool = false
    var inset: CGFloat = 10

    var body: some View {
        GeometryReader { geometry in
            let clampedInset = max(0, inset)
            let contentWidth = max(0, geometry.size.width - clampedInset * 2)
            let contentHeight = max(0, geometry.size.height - clampedInset * 2)
            let baseStroke = isPrimary ? DesignTokens.Preview.monitorStrokePrimary : DesignTokens.Preview.monitorStrokeSecondary
            let strokeColor = isSelectedMonitor
            ? DesignTokens.Preview.monitorStrokePrimary.opacity(0.9)
            : baseStroke.opacity(isPrimary ? 0.65 : 0.5)
            let strokeWidth: CGFloat = isSelectedMonitor ? 2 : 1
            let resizeHandles = resizeHandleDescriptors(for: zones)

            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 10)
                    .fill(DesignTokens.Preview.monitorFill)
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(strokeColor, lineWidth: strokeWidth)
                    )

                ForEach(zones) { zone in
                    DSZoneView(
                        zone: zone,
                        onDrop: onDrop,
                        onSelectApp: onSelectApp,
                        onSplitVertical: onSplitVertical,
                        onSplitHorizontal: onSplitHorizontal,
                        onCloseZone: onCloseZone,
                        onSelectZone: onSelectZone
                    )
                    .frame(
                        width: CGFloat(zone.frame.widthPercent) * contentWidth - 4,
                        height: CGFloat(zone.frame.heightPercent) * contentHeight - 4
                    )
                    .position(
                        x: clampedInset + CGFloat(zone.frame.xPercent) * contentWidth + CGFloat(zone.frame.widthPercent) * contentWidth / 2,
                        y: clampedInset + CGFloat(zone.frame.yPercent) * contentHeight + CGFloat(zone.frame.heightPercent) * contentHeight / 2
                    )
                }

                ForEach(resizeHandles) { handle in
                    DSZoneResizeHandle(
                        handle: handle,
                        inset: clampedInset,
                        contentWidth: contentWidth,
                        contentHeight: contentHeight
                    ) { delta in
                        onResizeBoundary?(
                            handle.axis == .vertical ? .vertical : .horizontal,
                            handle.position,
                            handle.rangeStart...handle.rangeEnd,
                            delta
                        )
                    }
                    .zIndex(3)
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: 10))
            .onTapGesture {
                onSelectMonitor?()
            }
        }
    }

    private func resizeHandleDescriptors(for zones: [DSZone]) -> [DSZoneResizeHandleDescriptor] {
        verticalResizeHandles(for: zones) + horizontalResizeHandles(for: zones)
    }

    private func verticalResizeHandles(for zones: [DSZone]) -> [DSZoneResizeHandleDescriptor] {
        let boundaries = Set(
            zones
                .map { $0.frame.xPercent + $0.frame.widthPercent }
                .filter { $0 > 0.0001 && $0 < 0.9999 }
        )

        return boundaries.sorted().enumerated().flatMap { boundaryIndex, boundary in
            let leftRanges = zones
                .filter { nearlyEqual($0.frame.xPercent + $0.frame.widthPercent, boundary) }
                .map { $0.frame.yPercent...($0.frame.yPercent + $0.frame.heightPercent) }
            let rightRanges = zones
                .filter { nearlyEqual($0.frame.xPercent, boundary) }
                .map { $0.frame.yPercent...($0.frame.yPercent + $0.frame.heightPercent) }

            return mergedOverlaps(between: leftRanges, and: rightRanges).enumerated().map { overlapIndex, overlap in
                DSZoneResizeHandleDescriptor(
                    key: "vertical-\(boundaryIndex)-\(overlapIndex)",
                    axis: .vertical,
                    position: boundary,
                    rangeStart: overlap.lowerBound,
                    rangeEnd: overlap.upperBound
                )
            }
        }
    }

    private func horizontalResizeHandles(for zones: [DSZone]) -> [DSZoneResizeHandleDescriptor] {
        let boundaries = Set(
            zones
                .map { $0.frame.yPercent + $0.frame.heightPercent }
                .filter { $0 > 0.0001 && $0 < 0.9999 }
        )

        return boundaries.sorted().enumerated().flatMap { boundaryIndex, boundary in
            let topRanges = zones
                .filter { nearlyEqual($0.frame.yPercent + $0.frame.heightPercent, boundary) }
                .map { $0.frame.xPercent...($0.frame.xPercent + $0.frame.widthPercent) }
            let bottomRanges = zones
                .filter { nearlyEqual($0.frame.yPercent, boundary) }
                .map { $0.frame.xPercent...($0.frame.xPercent + $0.frame.widthPercent) }

            return mergedOverlaps(between: topRanges, and: bottomRanges).enumerated().map { overlapIndex, overlap in
                DSZoneResizeHandleDescriptor(
                    key: "horizontal-\(boundaryIndex)-\(overlapIndex)",
                    axis: .horizontal,
                    position: boundary,
                    rangeStart: overlap.lowerBound,
                    rangeEnd: overlap.upperBound
                )
            }
        }
    }

    private func mergedOverlaps(
        between firstRanges: [ClosedRange<Double>],
        and secondRanges: [ClosedRange<Double>]
    ) -> [ClosedRange<Double>] {
        let epsilon = 0.0001
        let overlaps = firstRanges.flatMap { first in
            secondRanges.compactMap { second -> ClosedRange<Double>? in
                let lower = max(first.lowerBound, second.lowerBound)
                let upper = min(first.upperBound, second.upperBound)
                return upper - lower > epsilon ? lower...upper : nil
            }
        }
        .sorted { lhs, rhs in
            if nearlyEqual(lhs.lowerBound, rhs.lowerBound) {
                return lhs.upperBound < rhs.upperBound
            }
            return lhs.lowerBound < rhs.lowerBound
        }

        var merged: [ClosedRange<Double>] = []
        for range in overlaps {
            guard let last = merged.last else {
                merged.append(range)
                continue
            }

            if range.lowerBound <= last.upperBound + epsilon {
                merged[merged.count - 1] = last.lowerBound...max(last.upperBound, range.upperBound)
            } else {
                merged.append(range)
            }
        }

        return merged
    }

    private func nearlyEqual(_ lhs: Double, _ rhs: Double, epsilon: Double = 0.0001) -> Bool {
        abs(lhs - rhs) < epsilon
    }
}

private struct DSZoneResizeHandle: View {
    let handle: DSZoneResizeHandleDescriptor
    let inset: CGFloat
    let contentWidth: CGFloat
    let contentHeight: CGFloat
    let onResizeDelta: (Double) -> Void

    @State private var isHovering = false
    @State private var isDragging = false
    @State private var lastTranslation: CGFloat = 0

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6)
                .fill(handleFill)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(handleStroke, lineWidth: isDragging ? 2 : 1)
                )
                .overlay(handleGrip)
                .frame(width: handleVisualSize.width, height: handleVisualSize.height)
        }
            .frame(width: handleHitSize.width, height: handleHitSize.height)
            .background(Color.clear)
            .contentShape(Rectangle())
            .allowsHitTesting(true)
            .position(handleCenter)
            .onHover { isHovering = $0 }
            .highPriorityGesture(resizeGesture)
            .animation(.smooth(duration: 0.12), value: isHovering)
            .animation(.smooth(duration: 0.12), value: isDragging)
    }

    private var resizeGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                isDragging = true
                let translation = handle.axis == .vertical ? value.translation.width : value.translation.height
                let deltaPixels = translation - lastTranslation
                lastTranslation = translation

                let denominator = handle.axis == .vertical ? max(contentWidth, 1) : max(contentHeight, 1)
                onResizeDelta(Double(deltaPixels / denominator))
            }
            .onEnded { _ in
                isDragging = false
                lastTranslation = 0
            }
    }

    private var handleVisualSize: CGSize {
        CGSize(width: handleSize.width, height: handleSize.height)
    }

    private var handleHitSize: CGSize {
        switch handle.axis {
        case .vertical:
            return CGSize(width: 24, height: max(handleSize.height, 44))
        case .horizontal:
            return CGSize(width: max(handleSize.width, 44), height: 24)
        }
    }

    private var handleFill: Color {
        if isDragging {
            return DesignTokens.WorkspaceBuilder.splitControlHover
        }
        if isHovering {
            return DesignTokens.WorkspaceBuilder.splitControlHover.opacity(0.85)
        }
        return DesignTokens.WorkspaceBuilder.splitControlFill.opacity(0.9)
    }

    private var handleStroke: Color {
        isDragging || isHovering ? DesignTokens.Brand.accent : DesignTokens.WorkspaceBuilder.splitControlStroke
    }

    @ViewBuilder
    private var handleGrip: some View {
        if handle.axis == .vertical {
            VStack(spacing: 4) {
                gripDot
                gripDot
                gripDot
            }
        } else {
            HStack(spacing: 4) {
                gripDot
                gripDot
                gripDot
            }
        }
    }

    private var gripDot: some View {
        Circle()
            .fill(DesignTokens.Text.muted.opacity(isDragging ? 0.9 : 0.75))
            .frame(width: 3.5, height: 3.5)
    }

    private var handleCenter: CGPoint {
        switch handle.axis {
        case .vertical:
            return CGPoint(
                x: inset + CGFloat(handle.position) * contentWidth,
                y: inset + CGFloat((handle.rangeStart + handle.rangeEnd) / 2) * contentHeight
            )
        case .horizontal:
            return CGPoint(
                x: inset + CGFloat((handle.rangeStart + handle.rangeEnd) / 2) * contentWidth,
                y: inset + CGFloat(handle.position) * contentHeight
            )
        }
    }

    private var handleSize: CGSize {
        switch handle.axis {
        case .vertical:
            return CGSize(
                width: 12,
                height: max(CGFloat(handle.rangeEnd - handle.rangeStart) * contentHeight - 10, 44)
            )
        case .horizontal:
            return CGSize(
                width: max(CGFloat(handle.rangeEnd - handle.rangeStart) * contentWidth - 10, 44),
                height: 12
            )
        }
    }
}

private struct DSZoneView: View {
    let zone: DSZone
    let onDrop: (String, UUID) -> Bool
    let onSelectApp: (UUID) -> Void
    let onSplitVertical: (UUID) -> Void
    let onSplitHorizontal: (UUID) -> Void
    let onCloseZone: (UUID) -> Void
    let onSelectZone: (UUID) -> Void

    @State private var isTargeted = false
    @State private var isHovering = false

    var body: some View {
        let showsZoneControls = isHovering || zone.isFocused

        ZStack(alignment: .topTrailing) {
            RoundedRectangle(cornerRadius: 6)
                .fill(isTargeted ? DesignTokens.WorkspaceBuilder.zoneTargetFill : (isHovering ? DesignTokens.Preview.windowFillHover : DesignTokens.Preview.windowFill))

            if let app = zone.app {
                VStack(spacing: 6) {
                    ZStack(alignment: .topTrailing) {
                        if let icon = app.icon {
                            Image(nsImage: icon)
                                .resizable()
                                .frame(width: 28, height: 28)
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                        } else {
                            Image(systemName: "app.fill")
                                .font(brand: Font.brandBody(size: 24))
                                .foregroundStyle(DesignTokens.Text.muted)
                        }

                        if let appType = app.specialAppType {
                            DSPulsatingIndicator(color: appType.color, isActive: true)
                                .offset(x: 5, y: -5)
                        }
                    }

                    Text(app.name)
                        .font(brand: .body4)
                        .foregroundStyle(DesignTokens.Text.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)

                    if zone.stackCount > 1 {
                        Text("\(zone.stackCount) apps")
                            .font(brand: .body4)
                            .foregroundStyle(DesignTokens.Text.tertiary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }
                .padding(.horizontal, 6)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
                .draggable("window:\(app.id)")
                .onTapGesture {
                    onSelectZone(zone.id)
                    onSelectApp(app.id)
                }
            } else {
                VStack(spacing: 4) {
                    Image(systemName: "plus.circle.dashed")
                        .font(brand: Font.brandBody(size: 18))
                        .foregroundStyle(DesignTokens.Text.muted)
                    Text("Drop app")
                        .font(brand: .body4)
                        .foregroundStyle(DesignTokens.Text.tertiary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .padding(.horizontal, 6)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
                .onTapGesture {
                    onSelectZone(zone.id)
                }
            }

            if zone.stackCount > 1 {
                // Anchored top-leading: the tool cluster owns the top-right
                // corner, so the stack badge yields it to avoid collisions in
                // narrow zones (#596).
                Text("\(zone.stackCount)")
                    .font(brand: .label4)
                    .foregroundStyle(Color.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        Capsule()
                            .fill(DesignTokens.Brand.accent)
                    )
                    .padding(8)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }

            if showsZoneControls {
                HStack(spacing: 4) {
                    if zone.canSplitVertical {
                        zoneToolButton(systemName: "rectangle.split.2x1") {
                            onSplitVertical(zone.id)
                        }
                    }

                    if zone.canSplitHorizontal {
                        zoneToolButton(systemName: "rectangle.split.1x2") {
                            onSplitHorizontal(zone.id)
                        }
                    }

                    zoneToolButton(systemName: "xmark.circle.fill") {
                        onCloseZone(zone.id)
                    }
                }
                // Solid pill so the cluster reads cleanly over any zone
                // content it covers in narrow zones (#596).
                .padding(3)
                .background {
                    RoundedRectangle(cornerRadius: 7)
                        .fill(DesignTokens.Surface.elevated)
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 7)
                        .stroke(DesignTokens.WorkspaceBuilder.splitControlStroke, lineWidth: 1)
                }
                .padding(6)
                .zIndex(2)
            }
        }
        // Zones clip their content — nothing may render outside the zone
        // bounds (#596). The selection stroke is applied after the clip so it
        // keeps its full line width.
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(
                    zone.isSelected
                    ? DesignTokens.WorkspaceBuilder.zoneStrokeSelected
                    : (zone.isFocused ? DesignTokens.Border.prominent : Color.clear),
                    lineWidth: zone.isSelected ? 2 : (zone.isFocused ? 1 : 0)
                )
        )
        .onHover { isHovering = $0 }
        .dropDestination(for: String.self) { items, _ in
            guard let payload = items.first else { return false }
            return onDrop(payload, zone.id)
        } isTargeted: { targeted in
            isTargeted = targeted
        }
        .animation(.smooth(duration: 0.15), value: isTargeted)
        .animation(.smooth(duration: 0.15), value: isHovering)
    }

    private func zoneToolButton(systemName: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(brand: Font.brandBody(size: 10))
                .foregroundStyle(DesignTokens.Text.secondary)
                .frame(width: 20, height: 20)
                .background {
                    RoundedRectangle(cornerRadius: 5)
                        .fill(DesignTokens.WorkspaceBuilder.splitControlFill)
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 5)
                        .stroke(DesignTokens.WorkspaceBuilder.splitControlStroke, lineWidth: 1)
                }
        }
        .buttonStyle(.plain)
        .brightenOnHover()
    }
}

#Preview {
        DSZoneEditor(
            zones: [
                DSZone(
                    id: UUID(),
                    frame: RelativeWindowFrame(xPercent: 0, yPercent: 0, widthPercent: 0.5, heightPercent: 1),
                    app: nil,
                    stackCount: 0,
                    isSelected: false,
                    isFocused: false,
                    canSplitVertical: true,
                    canSplitHorizontal: true
                ),
                DSZone(
                    id: UUID(),
                    frame: RelativeWindowFrame(xPercent: 0.5, yPercent: 0, widthPercent: 0.5, heightPercent: 1),
                    app: nil,
                    stackCount: 0,
                    isSelected: false,
                    isFocused: false,
                    canSplitVertical: true,
                    canSplitHorizontal: true
                )
            ],
            onDrop: { _, _ in true },
            onSelectApp: { _ in },
            onSplitVertical: { _ in },
            onSplitHorizontal: { _ in },
            onCloseZone: { _ in },
            onSelectZone: { _ in },
            onSelectMonitor: { }
        )
    .frame(width: 320, height: 160)
    .padding(24)
    .background(Color.black.opacity(0.9))
}
