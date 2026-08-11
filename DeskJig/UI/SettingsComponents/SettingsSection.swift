//
//  SettingsSection.swift
//  DeskJig
//
//  Created by Claude Code on 02/02/26.
//

import SwiftUI
import DeskJigShared

/// A glass card wrapper component with title for settings sections.
/// Uses design tokens for consistent styling.
struct SettingsSection<Content: View>: View {
    let title: String
    let badgeText: String?
    let subtitle: String?
    let content: Content

    init(_ title: String, badgeText: String? = nil, subtitle: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.badgeText = badgeText
        self.subtitle = subtitle
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(title)
                        .font(brand: .label2)
                        .foregroundStyle(DesignTokens.Text.secondary)

                    if let badgeText {
                        DSTag(
                            label: badgeText,
                            color: DesignTokens.Status.success,
                            size: .small
                        )
                    }
                }

                if let subtitle {
                    Text(subtitle)
                        .font(brand: .body4)
                        .foregroundStyle(DesignTokens.Text.tertiary)
                        .frame(maxWidth: 720, alignment: .leading)
                }
            }

            VStack(alignment: .leading, spacing: 12) {
                content
            }
            .padding(DesignTokens.Card.padding)
            .frame(maxWidth: 720, alignment: .leading)
            .dsCard()
        }
        .frame(maxWidth: .infinity, alignment: .center)
    }
}

#Preview {
    VStack(spacing: 24) {
        SettingsSection("UI Scale") {
            Text("Content goes here")
                .foregroundStyle(DesignTokens.Text.primary)
        }

        SettingsSection("Keyboard Shortcuts") {
            VStack(alignment: .leading, spacing: 8) {
                Text("Primary")
                    .foregroundStyle(DesignTokens.Text.primary)
                Text("More content...")
                    .foregroundStyle(DesignTokens.Text.secondary)
            }
        }
    }
    .padding(32)
    .background(Color.black.opacity(0.9))
}
