//
//  DSLayoutPresetPicker.swift
//  DeskJig
//
//  Created by Codex on 02/03/26.
//

import SwiftUI
import DeskJigShared

struct DSLayoutPresetPicker: View {
    let presets: [LayoutPreset]
    let selectedPreset: LayoutPreset
    let onSelect: (LayoutPreset) -> Void
    /// Compact tiles for the re-expanded picker behind the layout pill (#598):
    /// once a preset is chosen the picker only needs to support switching, so
    /// it trades tile size for the vertical space the zone canvas wants.
    var isCompact: Bool = false

    var body: some View {
        ScrollView(.horizontal, showsIndicators: true) {
            HStack(spacing: DesignTokens.Spacing.gapSmall) {
                ForEach(presets) { preset in
                    LayoutPresetTile(
                        preset: preset,
                        isSelected: preset == selectedPreset,
                        isCompact: isCompact,
                        onSelect: { onSelect(preset) }
                    )
                }
            }
            .padding(.vertical, 2)
            .padding(.horizontal, 4)
        }
        .scrollIndicators(.visible)
    }
}

/// Collapsed layout picker (#598): once a preset is chosen the grid folds into
/// this pill (mini thumbnail + name + chevron); clicking re-expands the grid.
struct DSLayoutPresetPill: View {
    let preset: LayoutPreset
    let isExpanded: Bool
    let onTap: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 8) {
                LayoutPresetPreview(preset: preset)
                    .frame(width: 34, height: 21)
                    .padding(1)
                    .background {
                        RoundedRectangle(cornerRadius: 4)
                            .fill(DesignTokens.Surface.card)
                    }
                    .overlay {
                        RoundedRectangle(cornerRadius: 4)
                            .stroke(DesignTokens.Border.subtle, lineWidth: 1)
                    }

                Text(preset.rawValue)
                    .font(brand: .label3)
                    .foregroundStyle(DesignTokens.Brand.accent)
                    .lineLimit(1)

                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(DesignTokens.Text.muted)
                    .rotationEffect(.degrees(isExpanded ? 180 : 0))
            }
            .padding(.leading, 5)
            .padding(.trailing, 11)
            .padding(.vertical, 4)
            .background {
                RoundedRectangle(cornerRadius: DesignTokens.CornerRadius.medium)
                    .fill(DesignTokens.Surface.card)
            }
            .overlay {
                RoundedRectangle(cornerRadius: DesignTokens.CornerRadius.medium)
                    .stroke(
                        isHovering || isExpanded
                            ? DesignTokens.LayoutPreview.tileSelectedStroke
                            : DesignTokens.Border.regular,
                        lineWidth: 1
                    )
            }
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("workspace.layout-pill")
        .onHover { isHovering = $0 }
        .animation(.smooth(duration: 0.15), value: isHovering)
        .animation(.smooth(duration: 0.15), value: isExpanded)
    }
}

private struct LayoutPresetTile: View {
    let preset: LayoutPreset
    let isSelected: Bool
    var isCompact: Bool = false
    let onSelect: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: onSelect) {
            VStack(spacing: isCompact ? 4 : 6) {
                LayoutPresetPreview(preset: preset)
                    .frame(width: isCompact ? 56 : 72, height: isCompact ? 34 : 44)

                Text(preset.rawValue)
                    .font(brand: .body4)
                    .foregroundStyle(DesignTokens.Text.secondary)
                    .lineLimit(1)
            }
            .padding(isCompact ? 6 : 10)
            .background {
                RoundedRectangle(cornerRadius: DesignTokens.CornerRadius.large)
                    .fill(isSelected ? DesignTokens.LayoutPreview.tileSelectedFill : DesignTokens.LayoutPreview.tileFill)
            }
            .overlay {
                RoundedRectangle(cornerRadius: DesignTokens.CornerRadius.large)
                    .stroke(isSelected ? DesignTokens.LayoutPreview.tileSelectedStroke : DesignTokens.LayoutPreview.tileStroke, lineWidth: 1)
            }
            .brightness(isHovering ? 0.08 : 0)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(accessibilityIdentifier)
        .onHover { isHovering = $0 }
        .animation(.smooth(duration: 0.15), value: isHovering)
    }

    private var accessibilityIdentifier: String {
        let slug = preset.rawValue
            .lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .joined(separator: "-")
        return "workspace.layout-preset.\(slug)"
    }
}

private struct LayoutPresetPreview: View {
    let preset: LayoutPreset

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let height = geometry.size.height

            ZStack {
                ForEach(0..<preset.windowCount, id: \.self) { index in
                    let frame = preset.relativeFrame(for: index)
                    RoundedRectangle(cornerRadius: 3)
                        .fill(DesignTokens.Preview.windowFill)
                        .stroke(DesignTokens.Preview.windowStroke, lineWidth: 1)
                        .frame(
                            width: CGFloat(frame.widthPercent) * width - 4,
                            height: CGFloat(frame.heightPercent) * height - 4
                        )
                        .position(
                            x: CGFloat(frame.xPercent) * width + CGFloat(frame.widthPercent) * width / 2,
                            y: CGFloat(frame.yPercent) * height + CGFloat(frame.heightPercent) * height / 2
                        )
                }
            }
        }
    }
}

#Preview {
    DSLayoutPresetPicker(
        presets: LayoutPreset.allCases,
        selectedPreset: .fiftyFifty,
        onSelect: { _ in }
    )
    .padding(24)
    .background(Color.black.opacity(0.9))
}
