//
//  DSMonitorSelectorBar.swift
//  DeskJig
//
//  Created by Codex on 02/03/26.
//

import SwiftUI
import DeskJigShared

struct DSMonitorItem: Identifiable {
    let id: UUID
    let title: String
    let subtitle: String?
    let isPrimary: Bool
    let isVirtual: Bool
    let isRemovable: Bool
}

struct DSMonitorSelectorBar: View {
    let monitors: [DSMonitorItem]
    let selectedId: UUID?
    let onSelect: (UUID) -> Void
    let onRemove: (UUID) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.gapSmall) {
            HStack(spacing: DesignTokens.Spacing.gapSmall) {
                Text("Monitors")
                    .font(brand: .label3)
                    .foregroundStyle(DesignTokens.Text.tertiary)
            }

            VStack(spacing: 8) {
                ForEach(monitors) { monitor in
                    DSMonitorRow(
                        monitor: monitor,
                        isSelected: monitor.id == selectedId,
                        onSelect: { onSelect(monitor.id) },
                        onRemove: { onRemove(monitor.id) }
                    )
                }
            }
        }
        .padding(DesignTokens.Card.paddingCompact)
        .background {
            RoundedRectangle(cornerRadius: DesignTokens.CornerRadius.large)
                .fill(DesignTokens.Surface.elevated)
                .overlay(
                    RoundedRectangle(cornerRadius: DesignTokens.CornerRadius.large)
                        .stroke(DesignTokens.Border.subtle, lineWidth: 1)
                )
        }
    }
}

private struct DSMonitorRow: View {
    let monitor: DSMonitorItem
    let isSelected: Bool
    let onSelect: () -> Void
    let onRemove: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: DesignTokens.Spacing.gapSmall) {
                Image(systemName: "display")
                    .font(brand: Font.brandBody(size: 14))
                    .foregroundStyle(isSelected ? DesignTokens.Brand.accent : DesignTokens.Text.tertiary)

                VStack(alignment: .leading, spacing: 2) {
                    Text(monitor.title)
                        .font(brand: .label2)
                        .foregroundStyle(DesignTokens.Text.primary)
                        .lineLimit(1)

                    if let subtitle = monitor.subtitle {
                        Text(subtitle)
                            .font(brand: .body4)
                            .foregroundStyle(DesignTokens.Text.tertiary)
                            .lineLimit(1)
                    }
                }

                if monitor.isPrimary {
                    DSTag(label: "Primary", color: DesignTokens.Status.info, size: .small)
                }

                if monitor.isVirtual {
                    DSTag(label: "Virtual", color: DesignTokens.Status.warning, size: .small)
                }

                Spacer()

                if monitor.isRemovable {
                    Button(action: onRemove) {
                        Image(systemName: "trash")
                            .font(brand: Font.brandBody(size: 12))
                            .foregroundStyle(DesignTokens.Text.muted)
                    }
                    .buttonStyle(.plain)
                    .opacity(isHovering ? 1 : 0)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background {
                RoundedRectangle(cornerRadius: DesignTokens.CornerRadius.medium)
                    .fill(isSelected ? DesignTokens.Surface.cardHover : DesignTokens.Surface.card)
            }
            .overlay {
                RoundedRectangle(cornerRadius: DesignTokens.CornerRadius.medium)
                    .stroke(isSelected ? DesignTokens.Border.prominent : DesignTokens.Border.subtle, lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }
}

#Preview {
    DSMonitorSelectorBar(
        monitors: [
            DSMonitorItem(id: UUID(), title: "Monitor 1", subtitle: "2560 x 1440", isPrimary: true, isVirtual: false, isRemovable: false),
            DSMonitorItem(id: UUID(), title: "Monitor 2", subtitle: "Virtual", isPrimary: false, isVirtual: true, isRemovable: true)
        ],
        selectedId: nil,
        onSelect: { _ in },
        onRemove: { _ in }
    )
    .padding(24)
    .background(Color.black.opacity(0.9))
}

struct DSDisplayArrangementAssignmentOption: Identifiable, Hashable {
    let id: String
    let title: String
    let subtitle: String?
}

struct DSDisplayArrangementItem: Identifiable, Hashable {
    let id: String
    let frame: CGRect
    let title: String
    let subtitle: String?
    let detail: String?
    let assignmentTitle: String?
    let assignmentSubtitle: String?
    let isPrimary: Bool
    let isGhost: Bool
    let isSelected: Bool
    let isLinkedHighlight: Bool
    let assignmentOptions: [DSDisplayArrangementAssignmentOption]
    let selectedAssignmentID: String?

    init(
        id: String,
        frame: CGRect,
        title: String,
        subtitle: String? = nil,
        detail: String? = nil,
        assignmentTitle: String? = nil,
        assignmentSubtitle: String? = nil,
        isPrimary: Bool = false,
        isGhost: Bool = false,
        isSelected: Bool = false,
        isLinkedHighlight: Bool = false,
        assignmentOptions: [DSDisplayArrangementAssignmentOption] = [],
        selectedAssignmentID: String? = nil
    ) {
        self.id = id
        self.frame = frame
        self.title = title
        self.subtitle = subtitle
        self.detail = detail
        self.assignmentTitle = assignmentTitle
        self.assignmentSubtitle = assignmentSubtitle
        self.isPrimary = isPrimary
        self.isGhost = isGhost
        self.isSelected = isSelected
        self.isLinkedHighlight = isLinkedHighlight
        self.assignmentOptions = assignmentOptions
        self.selectedAssignmentID = selectedAssignmentID
    }
}

struct DSDisplayArrangementCanvas: View {
    let items: [DSDisplayArrangementItem]
    var preferredHeight: CGFloat = 260
    var onTap: ((String) -> Void)? = nil

    private let containerPadding: CGFloat = 36
    private let tileVisualInset: CGFloat = 22

    var body: some View {
        GeometryReader { geometry in
            let metrics = ArrangementMetrics(
                items: items,
                containerSize: geometry.size,
                containerPadding: containerPadding
            )

            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: DesignTokens.CornerRadius.large)
                    .fill(DesignTokens.Surface.card)
                    .overlay(
                        RoundedRectangle(cornerRadius: DesignTokens.CornerRadius.large)
                            .stroke(DesignTokens.Border.subtle, lineWidth: 1)
                    )

                if items.isEmpty {
                    Text("No displays detected")
                        .font(brand: .body4)
                        .foregroundStyle(DesignTokens.Text.tertiary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ForEach(metrics.sortedItems) { item in
                        DSDisplayArrangementTile(
                            item: item,
                            size: metrics.tileSize(for: item),
                            visualInset: tileVisualInset,
                            onTap: onTap
                        )
                        .offset(metrics.offset(for: item, visualInset: tileVisualInset))
                        .zIndex(item.isGhost ? 0 : 1)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: preferredHeight)
    }
}

private struct DSDisplayArrangementTile: View {
    let item: DSDisplayArrangementItem
    let size: CGSize
    let visualInset: CGFloat
    let onTap: ((String) -> Void)?

    var body: some View {
        let strokeColor = (item.isLinkedHighlight || item.isSelected)
            ? DesignTokens.Brand.accent
            : (item.isPrimary ? DesignTokens.Preview.monitorStrokePrimary : DesignTokens.Preview.monitorStrokeSecondary)
        let fillColor = item.isGhost
            ? DesignTokens.Surface.elevated.opacity(0.55)
            : DesignTokens.Preview.monitorFill
        let isCompact = size.height < 94 || size.width < 150
        let layoutSpacing: CGFloat = isCompact ? 4 : 8

        VStack(alignment: .leading, spacing: layoutSpacing) {
            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(item.title)
                        .font(brand: isCompact ? .body4 : .label3)
                        .foregroundStyle(DesignTokens.Text.primary)
                        .lineLimit(isCompact ? 1 : 2)
                        .truncationMode(.middle)

                    if let subtitle = item.subtitle {
                        Text(subtitle)
                            .font(brand: .body4)
                            .foregroundStyle(DesignTokens.Text.tertiary)
                            .lineLimit(isCompact ? 1 : 2)
                    }
                }

                Spacer(minLength: 0)

                VStack(alignment: .trailing, spacing: 4) {
                    if item.isPrimary {
                        DSTag(label: "Primary", color: DesignTokens.Status.info, size: .small)
                    }

                    if item.isGhost {
                        DSTag(label: "Saved only", color: DesignTokens.Status.warning, size: .small)
                    }
                }
            }

            Spacer(minLength: 0)

            if let assignmentTitle = item.assignmentTitle {
                Text(assignmentTitle)
                    .font(brand: isCompact ? .body4 : .label3)
                    .foregroundStyle(DesignTokens.Text.primary)
                    .lineLimit(1)
            } else if item.assignmentOptions.isEmpty == false {
                Text("Tap to assign")
                    .font(brand: .body4)
                    .foregroundStyle(DesignTokens.Text.muted)
            }
        }
        .padding(isCompact ? 10 : 12)
        .frame(
            width: max(size.width - visualInset, 72),
            height: max(size.height - visualInset, 48),
            alignment: .topLeading
        )
        .background(
            RoundedRectangle(cornerRadius: DesignTokens.CornerRadius.large)
                .fill(fillColor)
        )
        .overlay(
            RoundedRectangle(cornerRadius: DesignTokens.CornerRadius.large)
                .stroke(
                    strokeColor.opacity(item.isGhost ? 0.75 : 1),
                    style: StrokeStyle(
                        lineWidth: (item.isLinkedHighlight || item.isSelected) ? 3 : 1,
                        dash: item.isGhost ? [8, 5] : []
                    )
                )
        )
        .opacity(item.isGhost ? 0.85 : 1)
        .contentShape(RoundedRectangle(cornerRadius: DesignTokens.CornerRadius.large))
        .onTapGesture {
            onTap?(item.id)
        }
    }
}

private struct ArrangementMetrics {
    let sortedItems: [DSDisplayArrangementItem]
    private let minX: CGFloat
    private let maxY: CGFloat
    private let scale: CGFloat
    private let containerPadding: CGFloat

    init(items: [DSDisplayArrangementItem], containerSize: CGSize, containerPadding: CGFloat) {
        self.sortedItems = items.sorted { lhs, rhs in
            if lhs.isGhost != rhs.isGhost {
                return lhs.isGhost && !rhs.isGhost
            }
            if lhs.frame.minX != rhs.frame.minX {
                return lhs.frame.minX < rhs.frame.minX
            }
            return lhs.frame.minY > rhs.frame.minY
        }
        self.containerPadding = containerPadding

        let minX = items.map { $0.frame.minX }.min() ?? 0
        let minY = items.map { $0.frame.minY }.min() ?? 0
        let maxX = items.map { $0.frame.maxX }.max() ?? 1
        let maxY = items.map { $0.frame.maxY }.max() ?? 1

        self.minX = minX
        self.maxY = maxY

        let totalWidth = max(maxX - minX, 1)
        let totalHeight = max(maxY - minY, 1)
        let usableWidth = max(containerSize.width - containerPadding * 2, 1)
        let usableHeight = max(containerSize.height - containerPadding * 2, 1)
        self.scale = min(usableWidth / totalWidth, usableHeight / totalHeight)
    }

    func offset(for item: DSDisplayArrangementItem, visualInset: CGFloat) -> CGSize {
        CGSize(
            width: containerPadding + (item.frame.minX - minX) * scale + visualInset / 2,
            height: containerPadding + (maxY - item.frame.maxY) * scale + visualInset / 2
        )
    }

    func tileSize(for item: DSDisplayArrangementItem) -> CGSize {
        CGSize(
            width: max(item.frame.width * scale, 88),
            height: max(item.frame.height * scale, 56)
        )
    }
}

#Preview("Display Arrangement Canvas") {
    DSDisplayArrangementCanvas(
        items: [
            DSDisplayArrangementItem(
                id: "live-0",
                frame: CGRect(x: 0, y: 0, width: 1920, height: 1080),
                title: "Studio Display",
                subtitle: "3840 x 2160",
                detail: "Current display",
                assignmentTitle: "Monitor 1",
                assignmentSubtitle: "Saved layout",
                isPrimary: true,
                assignmentOptions: [
                    DSDisplayArrangementAssignmentOption(id: "saved-0", title: "Monitor 1", subtitle: "Studio Display"),
                    DSDisplayArrangementAssignmentOption(id: "saved-1", title: "Monitor 2", subtitle: "Portrait")
                ],
                selectedAssignmentID: "saved-0"
            ),
            DSDisplayArrangementItem(
                id: "live-1",
                frame: CGRect(x: 1920, y: -420, width: 2560, height: 1440),
                title: "LG UltraFine",
                subtitle: "2560 x 1440",
                detail: "Current display",
                assignmentTitle: "Monitor 2",
                assignmentSubtitle: "Saved layout",
                assignmentOptions: [
                    DSDisplayArrangementAssignmentOption(id: "saved-0", title: "Monitor 1", subtitle: "Studio Display"),
                    DSDisplayArrangementAssignmentOption(id: "saved-1", title: "Monitor 2", subtitle: "Portrait")
                ],
                selectedAssignmentID: "saved-1"
            ),
            DSDisplayArrangementItem(
                id: "ghost-2",
                frame: CGRect(x: 420, y: 1080, width: 1920, height: 1080),
                title: "Dell U2720Q",
                subtitle: "3840 x 2160",
                detail: "Saved workspace display",
                isGhost: true
            )
        ],
        onTap: { _ in }
    )
    .padding(24)
    .background(Color.black.opacity(0.9))
}
