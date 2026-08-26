//
//  DSCard.swift
//  DeskJig
//
//  Created by Claude Code on 02/02/26.
//

import SwiftUI
import DeskJigShared

/// Card style variants
enum DSCardStyle {
    /// Default style - subtle glass background
    case `default`
    /// Config panel style - gradient background for app configuration cards
    case config
    /// Workspace cards - solid surface for list items
    case workspace
}

/// Design System Card - a reusable surface card with consistent styling.
struct DSCard<Content: View>: View {
    var style: DSCardStyle = .default
    var isHighlighted: Bool = false
    var cornerRadius: CGFloat = DesignTokens.Card.cornerRadius
    @ViewBuilder let content: () -> Content

    init(
        style: DSCardStyle = .default,
        isHighlighted: Bool = false,
        cornerRadius: CGFloat = DesignTokens.Card.cornerRadius,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.style = style
        self.isHighlighted = isHighlighted
        self.cornerRadius = cornerRadius
        self.content = content
    }

    var body: some View {
        content()
            .background {
                switch style {
                case .default:
                    RoundedRectangle(cornerRadius: cornerRadius)
                        .fill(isHighlighted ? DesignTokens.Surface.cardHover : DesignTokens.Surface.card)
                case .config:
                    // Config cards use the same solid surface for consistency
                    RoundedRectangle(cornerRadius: cornerRadius)
                        .fill(isHighlighted ? DesignTokens.Surface.cardHover : DesignTokens.Surface.card)
                case .workspace:
                    RoundedRectangle(cornerRadius: cornerRadius)
                        .fill(isHighlighted ? DesignTokens.Surface.cardHover : DesignTokens.Surface.card)
                }
            }
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius)
                    .stroke(borderColor, lineWidth: 1)
            }
    }

    private var borderColor: Color {
        switch style {
        case .default:
            return isHighlighted ? DesignTokens.Border.regular : DesignTokens.Border.subtle
        case .config:
            return DesignTokens.Border.subtle
        case .workspace:
            return isHighlighted ? DesignTokens.Border.regular : DesignTokens.Border.subtle
        }
    }
}

/// Convenience modifier for applying card styling
extension View {
    /// `isSelected` is keyboard/click selection — deliberately louder than the
    /// `isHighlighted` hover state so the selected row is unmistakable (#51).
    @ViewBuilder
    func dsCard(
        style: DSCardStyle = .default,
        isHighlighted: Bool = false,
        isSelected: Bool = false,
        cornerRadius: CGFloat = DesignTokens.Card.cornerRadius
    ) -> some View {
        let fillColor: Color = {
            if isSelected { return DesignTokens.LayoutPreview.tileSelectedFill }
            return isHighlighted ? DesignTokens.Surface.cardHover : DesignTokens.Surface.card
        }()
        let borderColor: Color = {
            if isSelected { return DesignTokens.Brand.accent }
            switch style {
            case .default, .workspace:
                return isHighlighted ? DesignTokens.Border.regular : DesignTokens.Border.subtle
            case .config:
                return DesignTokens.Border.subtle
            }
        }()

        self.background {
            RoundedRectangle(cornerRadius: cornerRadius)
                .fill(fillColor)
        }
        .overlay {
            RoundedRectangle(cornerRadius: cornerRadius)
                .stroke(borderColor, lineWidth: isSelected ? 2 : 1)
        }
    }
}

#Preview {
    VStack(spacing: 24) {
        Text("Card Styles")
            .font(brand: .h4)
            .foregroundStyle(DesignTokens.Text.primary)

        DSCard {
            VStack(alignment: .leading, spacing: 8) {
                Text("Default Card")
                    .font(brand: .label2)
                    .foregroundStyle(DesignTokens.Text.primary)
                Text("Standard glass-style background")
                    .font(brand: .body3)
                    .foregroundStyle(DesignTokens.Text.secondary)
            }
            .padding(DesignTokens.Card.padding)
            .frame(width: 300, alignment: .leading)
        }

        DSCard(isHighlighted: true) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Highlighted Card")
                    .font(brand: .label2)
                    .foregroundStyle(DesignTokens.Text.primary)
                Text("Brighter background for hover/selected state")
                    .font(brand: .body3)
                    .foregroundStyle(DesignTokens.Text.secondary)
            }
            .padding(DesignTokens.Card.padding)
            .frame(width: 300, alignment: .leading)
        }

        DSCard(style: .config) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Config Card")
                    .font(brand: .label2)
                    .foregroundStyle(DesignTokens.Text.primary)
                Text("Elevated surface for app config panels")
                    .font(brand: .body3)
                    .foregroundStyle(DesignTokens.Text.secondary)
            }
            .padding(DesignTokens.Card.padding)
            .frame(width: 300, alignment: .leading)
        }

        // Using the modifier
        Text("Using dsCard modifier")
            .font(brand: .body3)
            .foregroundStyle(DesignTokens.Text.secondary)
            .padding(DesignTokens.Card.padding)
            .frame(width: 300, alignment: .leading)
            .dsCard()
    }
    .padding(32)
    .background(Color.black.opacity(0.9))
}
