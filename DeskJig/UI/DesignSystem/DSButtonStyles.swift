//
//  DSButtonStyles.swift
//  DeskJig
//
//  Created by Claude Code on 02/02/26.
//

import SwiftUI
import DeskJigShared

/// Button variants aligned with the Warm Obsidian design system.
enum DSButtonVariant {
    case primary
    case secondary
    case tertiary
    case success
    case green
    case warning
    case danger
}

/// Unified button style that supports design system variants.
struct DSButtonStyle: ButtonStyle {
    var size: DSButtonSize = .medium
    var variant: DSButtonVariant = .primary
    var isIconOnly: Bool = false
    var foregroundOverride: Color? = nil
    /// When true, skips internal vertical padding so button can be sized by an external frame.
    /// Use this when placing buttons alongside form inputs that need matching heights.
    var formHeight: Bool = false

    func makeBody(configuration: Configuration) -> some View {
        let background = backgroundColor(isPressed: configuration.isPressed)
        let foreground = foregroundOverride ?? foregroundColor
        let border = borderColor
        let horizontalPadding = isIconOnly ? size.iconPadding : size.horizontalPadding
        // When formHeight is true, skip vertical padding - the parent frame controls height
        let verticalPadding = formHeight ? 0 : (isIconOnly ? size.iconPadding : size.verticalPadding)

        configuration.label
            .font(brand: size.font)
            .foregroundStyle(foreground)
            .padding(.horizontal, horizontalPadding)
            .padding(.vertical, verticalPadding)
            .frame(maxHeight: formHeight ? .infinity : nil)
            .background {
                RoundedRectangle(cornerRadius: DesignTokens.CornerRadius.medium)
                    .fill(background)
            }
            .overlay {
                if let border {
                    RoundedRectangle(cornerRadius: DesignTokens.CornerRadius.medium)
                        .stroke(border, lineWidth: 1)
                }
            }
            .opacity(configuration.isPressed && usesOpacityPress ? DesignTokens.Opacity.pressed : 1.0)
    }

    private var usesOpacityPress: Bool {
        switch variant {
        case .primary, .secondary, .success, .green, .warning, .danger:
            return true
        case .tertiary:
            return false
        }
    }

    private var foregroundColor: Color {
        switch variant {
        case .primary:
            return DesignTokens.Text.primary
        case .secondary:
            return DesignTokens.Text.primary
        case .tertiary:
            return DesignTokens.Text.primary
        case .green:
            return .white
        case .success, .warning:
            return DesignTokens.Text.primary
        case .danger:
            return DesignTokens.Status.error
        }
    }

    private var borderColor: Color? {
        switch variant {
        case .primary:
            return DesignTokens.Brand.accent.opacity(0.35)
        case .secondary:
            return DesignTokens.Border.subtle
        case .tertiary:
            return nil
        case .green:
            return DesignTokens.Brand.communityGreen.opacity(0.8)
        case .success, .warning:
            return DesignTokens.Border.subtle
        case .danger:
            return DesignTokens.Status.error.opacity(0.6)
        }
    }

    private func backgroundColor(isPressed: Bool) -> Color {
        switch variant {
        case .primary:
            return DesignTokens.Brand.primaryButton
        case .secondary:
            return DesignTokens.Surface.card
        case .tertiary:
            return isPressed ? DesignTokens.Surface.cardHover : Color.clear
        case .green:
            return isPressed ? DesignTokens.Brand.communityGreenPressed : DesignTokens.Brand.communityGreen
        case .success:
            return DesignTokens.Surface.card
        case .warning:
            return DesignTokens.Surface.card
        case .danger:
            return DesignTokens.Surface.card
        }
    }
}

/// Primary button style - accent filled background
struct DSPrimaryButtonStyle: ButtonStyle {
    var size: DSButtonSize = .medium
    var background: Color = DesignTokens.Brand.primaryButton
    var foreground: Color = DesignTokens.Text.primary

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(brand: size.font)
            .foregroundStyle(foreground)
            .padding(.horizontal, size.horizontalPadding)
            .padding(.vertical, size.verticalPadding)
            .background {
                RoundedRectangle(cornerRadius: DesignTokens.CornerRadius.medium)
                    .fill(background)
            }
            .overlay {
                RoundedRectangle(cornerRadius: DesignTokens.CornerRadius.medium)
                    .stroke(DesignTokens.Brand.accent.opacity(0.35), lineWidth: 1)
            }
            .opacity(configuration.isPressed ? DesignTokens.Opacity.pressed : 1.0)
    }
}

/// Secondary button style - outlined/ghost style
struct DSSecondaryButtonStyle: ButtonStyle {
    var size: DSButtonSize = .medium
    var foreground: Color = DesignTokens.Text.primary
    var background: Color = DesignTokens.Surface.card
    var border: Color = DesignTokens.Border.subtle

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(brand: size.font)
            .foregroundStyle(foreground)
            .padding(.horizontal, size.horizontalPadding)
            .padding(.vertical, size.verticalPadding)
            .background {
                RoundedRectangle(cornerRadius: DesignTokens.CornerRadius.medium)
                    .fill(background)
            }
            .overlay {
                RoundedRectangle(cornerRadius: DesignTokens.CornerRadius.medium)
                    .stroke(border, lineWidth: 1)
            }
            .opacity(configuration.isPressed ? DesignTokens.Opacity.pressed : 1.0)
    }
}

/// Button size variants
enum DSButtonSize {
    case small, medium, large

    @MainActor var font: Font.BrandFont {
        switch self {
        case .small: return .body4
        case .medium: return .label3
        case .large: return .label2
        }
    }

    var horizontalPadding: CGFloat {
        switch self {
        case .small: return 8
        case .medium: return 12
        case .large: return 16
        }
    }

    var verticalPadding: CGFloat {
        switch self {
        case .small: return 4
        case .medium: return 6
        case .large: return 8
        }
    }

    var iconPadding: CGFloat {
        switch self {
        case .small: return 6
        case .medium: return 8
        case .large: return 10
        }
    }

    var iconSize: CGFloat {
        switch self {
        case .small: return DesignTokens.IconSize.small
        case .medium: return DesignTokens.IconSize.medium
        case .large: return DesignTokens.IconSize.large
        }
    }
}

// MARK: - Toggle Button Style

/// Toggle button style for icon-only state toggles (favorite star, pin, etc.)
struct DSToggleButtonStyle: ButtonStyle {
    var size: DSButtonSize = .medium
    var isSelected: Bool = false
    var selectedColor: Color = DesignTokens.Brand.accent
    var unselectedColor: Color = DesignTokens.Text.muted

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: size.iconSize))
            .foregroundStyle(isSelected ? selectedColor : unselectedColor)
            .frame(width: 28, height: 28)
            .background {
                RoundedRectangle(cornerRadius: DesignTokens.CornerRadius.medium)
                    .fill(isSelected
                        ? selectedColor.opacity(0.2)
                        : DesignTokens.Surface.card)
            }
            .opacity(configuration.isPressed ? DesignTokens.Opacity.pressed : 1.0)
    }
}

/// Convenience extensions for easy usage
extension ButtonStyle where Self == DSPrimaryButtonStyle {
    static var dsPrimary: DSPrimaryButtonStyle { DSPrimaryButtonStyle() }
    static func dsPrimary(size: DSButtonSize) -> DSPrimaryButtonStyle {
        DSPrimaryButtonStyle(size: size)
    }
    static var dsAccent: DSPrimaryButtonStyle {
        DSPrimaryButtonStyle(background: DesignTokens.Brand.accent)
    }
    static func dsAccent(size: DSButtonSize) -> DSPrimaryButtonStyle {
        DSPrimaryButtonStyle(size: size, background: DesignTokens.Brand.accent)
    }
}

extension ButtonStyle where Self == DSSecondaryButtonStyle {
    static var dsSecondary: DSSecondaryButtonStyle { DSSecondaryButtonStyle() }
    static func dsSecondary(size: DSButtonSize) -> DSSecondaryButtonStyle {
        DSSecondaryButtonStyle(size: size)
    }
    static func dsSecondary(
        size: DSButtonSize,
        foreground: Color
    ) -> DSSecondaryButtonStyle {
        DSSecondaryButtonStyle(size: size, foreground: foreground)
    }
}

extension ButtonStyle where Self == DSButtonStyle {
    static func dsButton(
        variant: DSButtonVariant,
        size: DSButtonSize = .medium,
        isIconOnly: Bool = false,
        foreground: Color? = nil,
        formHeight: Bool = false
    ) -> DSButtonStyle {
        DSButtonStyle(
            size: size,
            variant: variant,
            isIconOnly: isIconOnly,
            foregroundOverride: foreground,
            formHeight: formHeight
        )
    }
}

extension ButtonStyle where Self == DSToggleButtonStyle {
    static func dsToggle(isSelected: Bool, size: DSButtonSize = .medium) -> DSToggleButtonStyle {
        DSToggleButtonStyle(size: size, isSelected: isSelected)
    }

    static func dsFavorite(isSelected: Bool) -> DSToggleButtonStyle {
        DSToggleButtonStyle(isSelected: isSelected, selectedColor: DesignTokens.Brand.accent)
    }
}

#Preview {
    VStack(spacing: 24) {
        VStack(spacing: 12) {
            Text("Primary Buttons")
                .font(brand: .h5)
                .foregroundStyle(DesignTokens.Text.primary)

            HStack(spacing: 12) {
                Button("Small") {}
                    .buttonStyle(.dsPrimary(size: .small))

                Button("Medium") {}
                    .buttonStyle(.dsPrimary)

                Button("Large") {}
                    .buttonStyle(.dsPrimary(size: .large))
            }
        }

        Divider()
            .background(DesignTokens.Border.subtle)

        VStack(spacing: 12) {
            Text("Secondary Buttons")
                .font(brand: .h5)
                .foregroundStyle(DesignTokens.Text.primary)

            HStack(spacing: 12) {
                Button("Small") {}
                    .buttonStyle(.dsSecondary(size: .small))

                Button("Medium") {}
                    .buttonStyle(.dsSecondary)

                Button("Large") {}
                    .buttonStyle(.dsSecondary(size: .large))
            }
        }

        Divider()
            .background(DesignTokens.Border.subtle)

        VStack(spacing: 12) {
            Text("With Icons")
                .font(brand: .h5)
                .foregroundStyle(DesignTokens.Text.primary)

            HStack(spacing: 12) {
                Button {
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "plus")
                        Text("Add")
                    }
                }
                .buttonStyle(.dsPrimary)

                Button {
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "folder")
                        Text("Open")
                    }
                }
                .buttonStyle(.dsSecondary)
            }
        }

        Divider()
            .background(DesignTokens.Border.subtle)

        VStack(spacing: 12) {
            Text("Green Accent")
                .font(brand: .h5)
                .foregroundStyle(DesignTokens.Text.primary)

            Button {
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "person.3.fill")
                    Text("Confirm")
                }
            }
            .buttonStyle(.dsButton(variant: .green, size: .large))
        }

        Divider()
            .background(DesignTokens.Border.subtle)

        VStack(spacing: 12) {
            Text("Toggle Buttons")
                .font(brand: .h5)
                .foregroundStyle(DesignTokens.Text.primary)

            HStack(spacing: 12) {
                Button {} label: {
                    Image(systemName: "star.fill")
                }
                .buttonStyle(.dsFavorite(isSelected: true))

                Button {} label: {
                    Image(systemName: "star")
                }
                .buttonStyle(.dsFavorite(isSelected: false))

                Button {} label: {
                    Image(systemName: "pin.fill")
                }
                .buttonStyle(.dsToggle(isSelected: true))

                Button {} label: {
                    Image(systemName: "pin")
                }
                .buttonStyle(.dsToggle(isSelected: false))
            }
        }
    }
    .padding(32)
    .background(Color.black.opacity(0.9))
}
