//
//  DSWindowPreview.swift
//  DeskJig
//
//  Created by Claude Code on 02/02/26.
//

import SwiftUI
import AppKit
import DeskJigShared

// MARK: - Window Preview Rectangle

/// A tappable window rectangle in the monitor preview.
/// Uses design tokens for consistent styling.
struct DSWindowPreviewRect: View {
    let rect: CGRect
    var isSelected: Bool = false
    var onTap: (() -> Void)? = nil

    @State private var isHovering = false

    private let cornerRadius: CGFloat = 4

    var body: some View {
        Button {
            onTap?()
        } label: {
            RoundedRectangle(cornerRadius: cornerRadius)
                .fill(fillColor)
                .overlay(
                    RoundedRectangle(cornerRadius: cornerRadius)
                        .stroke(strokeColor, lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .frame(width: rect.width, height: rect.height)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                isHovering = hovering
            }
        }
        // Use offset instead of position to keep hit-testing area constrained to actual size
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .offset(x: rect.minX, y: rect.minY)
    }

    private var fillColor: Color {
        if isSelected {
            return DesignTokens.Preview.windowFillHover
        }
        return isHovering ? DesignTokens.Preview.windowFillHover : DesignTokens.Preview.windowFill
    }

    private var strokeColor: Color {
        if isSelected {
            return DesignTokens.Preview.windowStrokeHover
        }
        return isHovering ? DesignTokens.Preview.windowStrokeHover : DesignTokens.Preview.windowStroke
    }
}

// MARK: - Window Preview Icon

/// A tappable app icon positioned in the preview with optional special app indicator.
struct DSWindowPreviewIcon: View {
    let icon: NSImage?
    let fallback: String
    let size: CGFloat
    let position: CGPoint
    var onTap: (() -> Void)? = nil
    var specialAppType: DSSpecialAppType? = nil
    var isInEditMode: Bool = false
    var isSelected: Bool = false

    @State private var isHovering = false

    private var frameSize: CGFloat { size + 8 }

    var body: some View {
        Button {
            onTap?()
        } label: {
            DSAppIcon(icon: icon, fallback: fallback, size: size)
                .scaleEffect(isHovering ? 1.1 : 1.0)
                .dsSpecialAppIndicator(
                    appType: specialAppType,
                    isActive: isInEditMode,
                    isSelected: isSelected
                )
        }
        .buttonStyle(.plain)
        .frame(width: frameSize, height: frameSize)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                isHovering = hovering
            }
        }
        // Use offset instead of position to keep hit-testing area constrained to actual size
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .offset(x: position.x - frameSize / 2, y: position.y - frameSize / 2)
    }
}

// MARK: - App Icon

/// A simple app icon view with fallback text display.
struct DSAppIcon: View {
    let icon: NSImage?
    let fallback: String
    let size: CGFloat

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

// MARK: - Preview

#Preview("Window Preview Components") {
    VStack(spacing: 24) {
        Text("Window Preview Components")
            .font(brand: .h3)
            .foregroundStyle(DesignTokens.Text.primary)

        // Window rectangles
        VStack(alignment: .leading, spacing: 12) {
            Text("Window Rectangles")
                .font(brand: .label2)
                .foregroundStyle(DesignTokens.Text.secondary)

            ZStack {
                RoundedRectangle(cornerRadius: 6)
                    .fill(DesignTokens.Preview.monitorFill)
                    .frame(width: 200, height: 120)

                DSWindowPreviewRect(rect: CGRect(x: 10, y: 10, width: 80, height: 60))
                DSWindowPreviewRect(rect: CGRect(x: 100, y: 40, width: 90, height: 70), isSelected: true)
            }
            .frame(width: 200, height: 120)
        }

        // App icons
        VStack(alignment: .leading, spacing: 12) {
            Text("App Icons")
                .font(brand: .label2)
                .foregroundStyle(DesignTokens.Text.secondary)

            HStack(spacing: 16) {
                DSAppIcon(icon: nil, fallback: "Chrome", size: 32)
                DSAppIcon(icon: nil, fallback: "VS Code", size: 32)
                DSAppIcon(icon: nil, fallback: "Finder", size: 32)
            }
        }

        // Icons with special app indicators
        VStack(alignment: .leading, spacing: 12) {
            Text("With Special App Indicators")
                .font(brand: .label2)
                .foregroundStyle(DesignTokens.Text.secondary)

            HStack(spacing: 24) {
                DSAppIcon(icon: nil, fallback: "C", size: 32)
                    .dsSpecialAppIndicator(appType: .chrome, isActive: true)

                DSAppIcon(icon: nil, fallback: "V", size: 32)
                    .dsSpecialAppIndicator(appType: .ide, isActive: true)

                DSAppIcon(icon: nil, fallback: "C", size: 32)
                    .dsSpecialAppIndicator(appType: .chrome, isActive: true, isSelected: true)
            }
        }
    }
    .padding(32)
    .background(Color.black.opacity(0.9))
}
