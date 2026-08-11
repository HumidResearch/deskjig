//  WindowPreviewComponents.swift
//  DeskJig
//
//  Tappable window preview components for workspace layout
//

import SwiftUI
import AppKit
import DeskJigShared

// MARK: - Special App Type

enum SpecialAppType {
    case chrome
    case terminal
    case ide

    var color: Color {
        switch self {
        case .chrome: return DesignTokens.SpecialApp.chrome
        case .terminal: return DesignTokens.SpecialApp.terminal
        case .ide: return DesignTokens.SpecialApp.ide
        }
    }

    static func from(bundleIdentifier: String) -> SpecialAppType? {
        if chromeBundleIdentifiers.contains(bundleIdentifier) {
            return .chrome
        } else if OpenByPathBundleIdentifiers.supported.contains(bundleIdentifier) {
            // Categorize terminals vs IDEs
            switch bundleIdentifier {
            case OpenByPathBundleIdentifiers.ghostty,
                 OpenByPathBundleIdentifiers.terminal,
                 OpenByPathBundleIdentifiers.iterm2,
                 OpenByPathBundleIdentifiers.kitty,
                 OpenByPathBundleIdentifiers.alacritty:
                return .terminal
            case OpenByPathBundleIdentifiers.cursor,
                 OpenByPathBundleIdentifiers.codex,
                 OpenByPathBundleIdentifiers.vscode,
                 OpenByPathBundleIdentifiers.xcode:
                return .ide
            default:
                return .ide
            }
        }
        return nil
    }
}

// MARK: - Special App Indicator Modifier

struct SpecialAppIndicatorModifier: ViewModifier {
    let appType: SpecialAppType?
    let isInEditMode: Bool
    let isSelected: Bool

    @State private var isPulsing = false

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .topTrailing) {
                if let appType, isInEditMode {
                    // Badge indicator
                    Circle()
                        .fill(appType.color)
                        .frame(
                            width: DesignTokens.Animation.indicatorDotSize,
                            height: DesignTokens.Animation.indicatorDotSize
                        )
                        .offset(x: 2, y: -2)
                }
            }
            .overlay {
                if let appType, isInEditMode {
                    // Pulsing border (more prominent when selected)
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(
                            appType.color.opacity(borderOpacity),
                            lineWidth: borderWidth
                        )
                        .animation(
                            isSelected ? nil : .easeInOut(duration: DesignTokens.Animation.pulseDuration).repeatForever(autoreverses: true),
                            value: isPulsing
                        )
                        .onAppear {
                            if !isSelected {
                                isPulsing = true
                            }
                        }
                        .onChange(of: isSelected) { _, newValue in
                            isPulsing = !newValue
                        }
                }
            }
    }

    private var borderOpacity: Double {
        if isSelected {
            return DesignTokens.Animation.selectedOpacity
        } else {
            return isPulsing ? DesignTokens.Animation.pulseOpacityMax : DesignTokens.Animation.pulseOpacityMin
        }
    }

    private var borderWidth: CGFloat {
        isSelected ? DesignTokens.Animation.pulseBorderWidthSelected : DesignTokens.Animation.pulseBorderWidthDefault
    }
}

extension View {
    func specialAppIndicator(
        appType: SpecialAppType?,
        isInEditMode: Bool,
        isSelected: Bool = false
    ) -> some View {
        modifier(SpecialAppIndicatorModifier(
            appType: appType,
            isInEditMode: isInEditMode,
            isSelected: isSelected
        ))
    }
}

// MARK: - Window Preview Rect

/// A tappable window rectangle in the preview - uses design system Preview tokens
struct WindowPreviewRect: View {
    let rect: CGRect
    let onTap: () -> Void

    @State private var isHovering = false

    private let cornerRadius: CGFloat = 4

    var body: some View {
        Button(action: onTap) {
            RoundedRectangle(cornerRadius: cornerRadius)
                .fill(isHovering ? DesignTokens.Preview.windowFillHover : DesignTokens.Preview.windowFill)
                .overlay(
                    RoundedRectangle(cornerRadius: cornerRadius)
                        .stroke(isHovering ? DesignTokens.Preview.windowStrokeHover : DesignTokens.Preview.windowStroke, lineWidth: 1)
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
        // position() expands hit area to fill parent, breaking taps on overlapping windows
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .offset(x: rect.minX, y: rect.minY)
    }
}

// MARK: - Window Preview Icon

/// A tappable app icon positioned in the preview - simple centered icon
struct WindowPreviewIcon: View {
    let icon: NSImage?
    let fallback: String
    let size: CGFloat
    let position: CGPoint
    let onTap: () -> Void
    var appType: SpecialAppType? = nil
    var isInEditMode: Bool = false
    var isSelected: Bool = false

    @State private var isHovering = false

    private var frameSize: CGFloat { size + 8 }

    var body: some View {
        Button(action: onTap) {
            WorkspaceLayoutAppIcon(icon: icon, fallback: fallback, size: size)
                .scaleEffect(isHovering ? 1.1 : 1.0)
                .specialAppIndicator(
                    appType: appType,
                    isInEditMode: isInEditMode,
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
        // position() expands hit area to fill parent, breaking taps on overlapping windows
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .offset(x: position.x - frameSize / 2, y: position.y - frameSize / 2)
    }
}
