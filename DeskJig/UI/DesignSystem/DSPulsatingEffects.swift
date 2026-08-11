//
//  DSPulsatingEffects.swift
//  DeskJig
//
//  Created by Claude Code on 02/02/26.
//

import SwiftUI
import DeskJigShared

// MARK: - Pulsating Border Modifier

/// A reusable modifier that applies a pulsating border effect to any view.
/// Uses design tokens for consistent animation timing and colors.
struct DSPulsatingBorderModifier: ViewModifier {
    let color: Color
    let isActive: Bool
    let isSelected: Bool
    let cornerRadius: CGFloat

    @State private var isPulsing = false

    func body(content: Content) -> some View {
        content
            .overlay {
                if isActive {
                    RoundedRectangle(cornerRadius: cornerRadius)
                        .stroke(
                            color.opacity(borderOpacity),
                            lineWidth: borderWidth
                        )
                        .animation(pulseAnimation, value: isPulsing)
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

    private var pulseAnimation: Animation? {
        isSelected ? nil : .easeInOut(duration: DesignTokens.Animation.pulseDuration).repeatForever(autoreverses: true)
    }
}

// MARK: - Pulsating Indicator Dot

/// A small pulsating dot indicator, useful for showing active/special states.
struct DSPulsatingIndicator: View {
    let color: Color
    let isActive: Bool
    var size: CGFloat = DesignTokens.Animation.indicatorDotSize

    @State private var isPulsing = false

    var body: some View {
        if isActive {
            Circle()
                .fill(color)
                .frame(width: size, height: size)
                .opacity(isPulsing ? 1.0 : 0.4)
                .scaleEffect(isPulsing ? 1.0 : 0.85)
                .animation(
                    .easeInOut(duration: DesignTokens.Animation.pulseDuration)
                        .repeatForever(autoreverses: true),
                    value: isPulsing
                )
                .onAppear {
                    // Delay to ensure animation triggers after initial render
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                        isPulsing = true
                    }
                }
        }
    }
}

// MARK: - Special App Type (for Design System)

/// Represents special app types that receive visual indicators.
enum DSSpecialAppType {
    case chrome
    case terminal
    case ide

    var color: Color {
        switch self {
        case .chrome:
            return DesignTokens.SpecialApp.chrome
        case .terminal:
            return DesignTokens.SpecialApp.terminal
        case .ide:
            return DesignTokens.SpecialApp.ide
        }
    }

    var displayName: String {
        switch self {
        case .chrome: return "Chrome"
        case .ide: return "IDE"
        case .terminal: return "Terminal"
        }
    }

    static func from(bundleIdentifier: String) -> DSSpecialAppType? {
        if chromeBundleIdentifiers.contains(bundleIdentifier) {
            return .chrome
        }
        if OpenByPathBundleIdentifiers.supported.contains(bundleIdentifier) {
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

// MARK: - Type Badge

/// A badge that displays the special app type (Chrome, IDE, Terminal).
/// Uses DSTag for consistent styling with subtle rounded corners (not pill shape).
struct DSTypeBadge: View {
    let type: DSSpecialAppType

    var body: some View {
        DSTag(
            label: type.displayName,
            color: type.color,
            size: .small
        )
    }
}

// MARK: - Special App Indicator Modifier

/// A combined modifier that adds both a badge indicator and a pulsating border
/// for special apps (Chrome, IDEs, terminals).
struct DSSpecialAppIndicatorModifier: ViewModifier {
    let appType: DSSpecialAppType?
    let isActive: Bool
    let isSelected: Bool
    var cornerRadius: CGFloat = 4
    var badgeOffset: CGPoint = CGPoint(x: 2, y: -2)

    @State private var isPulsing = false

    func body(content: Content) -> some View {
        content
            // Badge indicator at top-right
            .overlay(alignment: .topTrailing) {
                if let appType, isActive {
                    Circle()
                        .fill(appType.color)
                        .frame(
                            width: DesignTokens.Animation.indicatorDotSize,
                            height: DesignTokens.Animation.indicatorDotSize
                        )
                        .offset(x: badgeOffset.x, y: badgeOffset.y)
                }
            }
            // Pulsating border
            .overlay {
                if let appType, isActive {
                    RoundedRectangle(cornerRadius: cornerRadius)
                        .stroke(
                            appType.color.opacity(borderOpacity),
                            lineWidth: borderWidth
                        )
                        .animation(pulseAnimation, value: isPulsing)
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

    private var pulseAnimation: Animation? {
        isSelected ? nil : .easeInOut(duration: DesignTokens.Animation.pulseDuration).repeatForever(autoreverses: true)
    }
}

// MARK: - View Extensions

extension View {
    /// Applies a pulsating border effect to the view.
    /// - Parameters:
    ///   - color: The color of the border
    ///   - isActive: Whether the pulsating effect is active
    ///   - isSelected: When true, shows a solid border instead of pulsating
    ///   - cornerRadius: Corner radius of the border
    func dsPulsatingBorder(
        color: Color,
        isActive: Bool = true,
        isSelected: Bool = false,
        cornerRadius: CGFloat = 4
    ) -> some View {
        modifier(DSPulsatingBorderModifier(
            color: color,
            isActive: isActive,
            isSelected: isSelected,
            cornerRadius: cornerRadius
        ))
    }

    /// Applies a special app indicator (badge + pulsating border) to the view.
    /// - Parameters:
    ///   - appType: The type of special app (chrome, terminal, ide)
    ///   - isActive: Whether the indicator is shown
    ///   - isSelected: When true, shows a solid border instead of pulsating
    ///   - cornerRadius: Corner radius of the border
    ///   - badgeOffset: Offset for the badge indicator
    func dsSpecialAppIndicator(
        appType: DSSpecialAppType?,
        isActive: Bool,
        isSelected: Bool = false,
        cornerRadius: CGFloat = 4,
        badgeOffset: CGPoint = CGPoint(x: 2, y: -2)
    ) -> some View {
        modifier(DSSpecialAppIndicatorModifier(
            appType: appType,
            isActive: isActive,
            isSelected: isSelected,
            cornerRadius: cornerRadius,
            badgeOffset: badgeOffset
        ))
    }
}

// MARK: - Preview

#Preview("Pulsating Effects") {
    VStack(spacing: 24) {
        Text("Pulsating Effects")
            .font(brand: .h3)
            .foregroundStyle(DesignTokens.Text.primary)

        // Type badges
        VStack(alignment: .leading, spacing: 12) {
            Text("Type Badges")
                .font(brand: .label2)
                .foregroundStyle(DesignTokens.Text.secondary)

            HStack(spacing: 12) {
                DSTypeBadge(type: .chrome)
                DSTypeBadge(type: .ide)
                DSTypeBadge(type: .terminal)
            }
        }

        // Pulsating borders
        VStack(alignment: .leading, spacing: 12) {
            Text("Pulsating Borders")
                .font(brand: .label2)
                .foregroundStyle(DesignTokens.Text.secondary)

            HStack(spacing: 16) {
                RoundedRectangle(cornerRadius: 8)
                    .fill(DesignTokens.Surface.card)
                    .frame(width: 60, height: 40)
                    .dsPulsatingBorder(color: DesignTokens.SpecialApp.chrome, cornerRadius: 8)

                RoundedRectangle(cornerRadius: 8)
                    .fill(DesignTokens.Surface.card)
                    .frame(width: 60, height: 40)
                    .dsPulsatingBorder(color: DesignTokens.SpecialApp.ide, cornerRadius: 8)

                RoundedRectangle(cornerRadius: 8)
                    .fill(DesignTokens.Surface.card)
                    .frame(width: 60, height: 40)
                    .dsPulsatingBorder(color: DesignTokens.SpecialApp.chrome, isSelected: true, cornerRadius: 8)

                Text("Selected")
                    .font(brand: .body4)
                    .foregroundStyle(DesignTokens.Text.muted)
            }
        }

        // Pulsating indicator dots
        VStack(alignment: .leading, spacing: 12) {
            Text("Indicator Dots")
                .font(brand: .label2)
                .foregroundStyle(DesignTokens.Text.secondary)

            HStack(spacing: 16) {
                DSPulsatingIndicator(color: DesignTokens.SpecialApp.chrome, isActive: true)
                DSPulsatingIndicator(color: DesignTokens.SpecialApp.ide, isActive: true)
                DSPulsatingIndicator(color: DesignTokens.Status.success, isActive: true)
                DSPulsatingIndicator(color: DesignTokens.Status.warning, isActive: true)
            }
        }

        // Special app indicators
        VStack(alignment: .leading, spacing: 12) {
            Text("Special App Indicators")
                .font(brand: .label2)
                .foregroundStyle(DesignTokens.Text.secondary)

            HStack(spacing: 16) {
                RoundedRectangle(cornerRadius: 4)
                    .fill(DesignTokens.Surface.elevated)
                    .frame(width: 48, height: 32)
                    .dsSpecialAppIndicator(appType: .chrome, isActive: true)

                RoundedRectangle(cornerRadius: 4)
                    .fill(DesignTokens.Surface.elevated)
                    .frame(width: 48, height: 32)
                    .dsSpecialAppIndicator(appType: .ide, isActive: true)

                RoundedRectangle(cornerRadius: 4)
                    .fill(DesignTokens.Surface.elevated)
                    .frame(width: 48, height: 32)
                    .dsSpecialAppIndicator(appType: .chrome, isActive: true, isSelected: true)

                Text("Selected")
                    .font(brand: .body4)
                    .foregroundStyle(DesignTokens.Text.muted)
            }
        }
    }
    .padding(32)
    .background(Color.black.opacity(0.9))
}
