//
//  SidebarItem.swift
//  DeskJig
//
//  Created by Claude Code on 01/30/26.
//

import SwiftUI
import DeskJigShared

/// Reusable sidebar row component with icon, label, optional count badge, and hover/selected states.
struct SidebarItem: View {
    let icon: String
    let label: String
    var count: Int? = nil
    var showsPulseIndicator: Bool = false
    let isSelected: Bool
    let action: () -> Void

    @State private var isHovering: Bool = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: DesignTokens.Spacing.gapRegular) {
                Image(systemName: icon)
                    .font(.system(size: DesignTokens.IconSize.medium, weight: .medium))
                    .foregroundStyle(isSelected ? DesignTokens.Text.primary : DesignTokens.Text.secondary)
                    .frame(width: DesignTokens.IconSize.xLarge)

                Text(label)
                    .font(brand: .body3)
                    .foregroundStyle(isSelected ? DesignTokens.Text.primary : DesignTokens.Text.secondary)

                Spacer()

                if showsPulseIndicator {
                    PulsingDot()
                }

                if let count {
                    Text("\(count)")
                        .font(brand: .label4)
                        .foregroundStyle(isSelected ? DesignTokens.Text.primary : DesignTokens.Text.tertiary)
                        .padding(.horizontal, DesignTokens.Spacing.gapSmall)
                        .padding(.vertical, DesignTokens.Spacing.gapTiny)
                        .background {
                            Capsule()
                                .fill(isSelected ? DesignTokens.Surface.elevated : DesignTokens.Surface.card)
                        }
                }
            }
            .padding(.horizontal, DesignTokens.Spacing.itemPaddingHorizontal)
            .padding(.vertical, DesignTokens.Spacing.itemPaddingVertical)
            .contentShape(Rectangle())
            .background {
                RoundedRectangle(cornerRadius: 8)
                    .fill(backgroundColor)
            }
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .animation(.smooth(duration: 0.15), value: isHovering)
        .animation(.smooth(duration: 0.15), value: isSelected)
    }

    private var backgroundColor: Color {
        if isSelected {
            return DesignTokens.Surface.cardHover
        } else if isHovering {
            return DesignTokens.Surface.card
        } else {
            return .clear
        }
    }
}

private struct PulsingDot: View {
    @State private var isAnimating = false

    var body: some View {
        ZStack {
            Circle()
                .fill(DesignTokens.Status.warning.opacity(0.32))
                .frame(width: 12, height: 12)
                .scaleEffect(isAnimating ? 1.25 : 0.9)
                .opacity(isAnimating ? 0.15 : 0.7)

            Circle()
                .fill(DesignTokens.Status.warning)
                .frame(width: 7, height: 7)
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 0.95).repeatForever(autoreverses: true)) {
                isAnimating = true
            }
        }
    }
}

#Preview {
    VStack(spacing: 8) {
        SidebarItem(icon: "square.grid.2x2", label: "All", count: 12, isSelected: true) {}
        SidebarItem(icon: "star", label: "Favorites", count: 3, isSelected: false) {}
        SidebarItem(icon: "gearshape", label: "Settings", isSelected: false) {}
    }
    .padding()
    .frame(width: 220)
    .background(Color.black.opacity(0.8))
}
