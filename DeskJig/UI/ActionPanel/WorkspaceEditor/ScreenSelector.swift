//  ScreenSelector.swift
//  DeskJig
//
//  Screen selector components for workspace editor
//

import SwiftUI
import DeskJigShared

/// Compact screen selector showing displays in proper arrangement
struct CompactScreenSelector: View {
    @Binding var selectedScreenIndices: Set<Int>
    let screens: [FullScreenInfo]

    private var allScreensBounds: CGRect {
        guard !screens.isEmpty else { return .zero }

        var minX = CGFloat.greatestFiniteMagnitude
        var minY = CGFloat.greatestFiniteMagnitude
        var maxX = -CGFloat.greatestFiniteMagnitude
        var maxY = -CGFloat.greatestFiniteMagnitude

        for screen in screens {
            minX = min(minX, screen.frame.minX)
            minY = min(minY, screen.frame.minY)
            maxX = max(maxX, screen.frame.maxX)
            maxY = max(maxY, screen.frame.maxY)
        }

        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    private func calculateScale(for viewSize: CGSize, padding: CGFloat = 40) -> CGFloat {
        let bounds = allScreensBounds
        guard bounds.width > 0 && bounds.height > 0 else { return 0.25 }

        let availableWidth = viewSize.width - padding
        let availableHeight = viewSize.height - padding

        let scaleX = availableWidth / bounds.width
        let scaleY = availableHeight / bounds.height

        return min(scaleX, scaleY, 0.35)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Select displays to save:")
                .font(brand: .label3)
                .foregroundStyle(DesignTokens.Text.primary.opacity(0.8))

            // Display arrangement preview with polished container
            ZStack(alignment: .bottom) {
                GeometryReader { geometry in
                    let bounds = allScreensBounds
                    let scale = calculateScale(for: geometry.size, padding: 60)

                    ZStack {
                        ForEach(Array(screens.enumerated()), id: \.offset) { index, screen in
                            ScreenMiniature(
                                screen: screen,
                                index: index,
                                isSelected: selectedScreenIndices.contains(index),
                                scale: scale,
                                onToggle: {
                                    withAnimation(.spring(duration: 0.2)) {
                                        if selectedScreenIndices.contains(index) {
                                            // Don't allow deselecting all screens
                                            if selectedScreenIndices.count > 1 {
                                                selectedScreenIndices.remove(index)
                                            }
                                        } else {
                                            selectedScreenIndices.insert(index)
                                        }
                                    }
                                }
                            )
                            .position(
                                x: (screen.frame.midX - bounds.minX) * scale + geometry.size.width / 2 - (bounds.width * scale / 2),
                                y: (bounds.maxY - screen.frame.midY) * scale + geometry.size.height / 2 - (bounds.height * scale / 2)
                            )
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                
                // Selection counter at bottom of container
                Text("\(selectedScreenIndices.count) of \(screens.count) displays selected")
                    .font(brand: Font.brandBody(size: 11))
                    .foregroundStyle(DesignTokens.Text.tertiary)
                    .padding(.bottom, 6)
            }
            .frame(height: 120)
            .background(
                RoundedRectangle(cornerRadius: DesignTokens.Card.cornerRadius)
                    .fill(DesignTokens.Surface.elevated)
                    .overlay(
                        RoundedRectangle(cornerRadius: DesignTokens.Card.cornerRadius)
                            .strokeBorder(DesignTokens.Border.subtle, lineWidth: 1)
                    )
            )
            .padding(.vertical, 4)
        }
    }
}

/// Miniature representation of a screen with proper proportions
struct ScreenMiniature: View {
    let screen: FullScreenInfo
    let index: Int
    let isSelected: Bool
    let scale: CGFloat
    let onToggle: () -> Void
    
    @State private var isHovering = false

    private var scaledSize: CGSize {
        CGSize(
            width: screen.frame.width * scale,
            height: screen.frame.height * scale
        )
    }
    
    private var fillColor: Color {
        if isSelected {
            return DesignTokens.Status.info.opacity(0.2)
        } else if isHovering {
            return DesignTokens.Surface.cardHover
        } else {
            return DesignTokens.Surface.card
        }
    }
    
    private var strokeColor: Color {
        if isSelected {
            return DesignTokens.Status.info.opacity(0.6)
        } else if isHovering {
            return DesignTokens.Border.prominent
        } else {
            return DesignTokens.Border.subtle
        }
    }
    
    private var strokeWidth: CGFloat {
        isSelected ? 2.5 : (isHovering ? 2 : 1.5)
    }
    
    private var shadowRadius: CGFloat {
        isSelected ? 4 : (isHovering ? 3 : 2)
    }

    var body: some View {
        ZStack {
            // Screen background with improved styling
            RoundedRectangle(cornerRadius: 8)
                .fill(fillColor)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(strokeColor, lineWidth: strokeWidth)
                )
                .shadow(
                    color: isSelected
                        ? DesignTokens.Status.info.opacity(0.15)
                        : Color.black.opacity(DesignTokens.Shadow.small.opacity),
                    radius: shadowRadius,
                    x: 0,
                    y: isSelected ? 2 : 1
                )

            // Center content - checkmark when selected, number when not selected
            if isSelected {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(DesignTokens.Status.info)
                    .font(.system(size: min(scaledSize.width, scaledSize.height) * 0.35))
                    .shadow(color: DesignTokens.Text.primary.opacity(0.15), radius: 1, x: 0, y: 0)
            } else {
                Text("\(index + 1)")
                    .font(.system(size: min(scaledSize.width, scaledSize.height) * 0.2, weight: .semibold))
                    .foregroundColor(DesignTokens.Text.secondary)
            }
        }
        .frame(width: scaledSize.width, height: scaledSize.height)
        .onTapGesture {
            onToggle()
        }
        .contentShape(Rectangle())
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                isHovering = hovering
            }
        }
        .help(screen.isPrimary ? "Display \(index + 1) (Main)" : "Display \(index + 1)")
    }
}
