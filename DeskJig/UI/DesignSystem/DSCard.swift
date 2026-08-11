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
    @ViewBuilder
    func dsCard(
        style: DSCardStyle = .default,
        isHighlighted: Bool = false,
        cornerRadius: CGFloat = DesignTokens.Card.cornerRadius
    ) -> some View {
        let borderColor: Color = {
            switch style {
            case .default:
                return isHighlighted ? DesignTokens.Border.regular : DesignTokens.Border.subtle
            case .config:
                return DesignTokens.Border.subtle
            case .workspace:
                return isHighlighted ? DesignTokens.Border.regular : DesignTokens.Border.subtle
            }
        }()

        switch style {
        case .default:
            self.background {
                RoundedRectangle(cornerRadius: cornerRadius)
                    .fill(isHighlighted ? DesignTokens.Surface.cardHover : DesignTokens.Surface.card)
            }
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius)
                    .stroke(borderColor, lineWidth: 1)
            }
        case .config:
            // Config cards use the same solid surface for consistency
            self.background {
                RoundedRectangle(cornerRadius: cornerRadius)
                    .fill(isHighlighted ? DesignTokens.Surface.cardHover : DesignTokens.Surface.card)
            }
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius)
                    .stroke(borderColor, lineWidth: 1)
            }
        case .workspace:
            self.background {
                RoundedRectangle(cornerRadius: cornerRadius)
                    .fill(isHighlighted ? DesignTokens.Surface.cardHover : DesignTokens.Surface.card)
            }
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius)
                    .stroke(borderColor, lineWidth: 1)
            }
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
