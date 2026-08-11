//
//  SettingsSubSection.swift
//  DeskJig
//
//  Created by Claude Code on 05/03/26.
//

import SwiftUI
import DeskJigShared

/// A lightweight inner grouping card with a sub-header, used inside a SettingsSection
/// to create visual hierarchy (e.g., grouping integrations by agent).
struct SettingsSubSection<Content: View>: View {
    let title: String
    let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.gapSmall) {
            Text(title)
                .font(brand: .label3)
                .foregroundStyle(DesignTokens.Text.secondary)

            VStack(alignment: .leading, spacing: 0) {
                content
            }
            .padding(DesignTokens.Card.paddingCompact)
            .dsCard(cornerRadius: DesignTokens.CornerRadius.medium)
        }
    }
}

#Preview {
    VStack(spacing: 24) {
        SettingsSubSection("Claude Code") {
            Text("Row 1")
                .foregroundStyle(DesignTokens.Text.primary)
            Divider().background(DesignTokens.Border.subtle)
            Text("Row 2")
                .foregroundStyle(DesignTokens.Text.primary)
        }
    }
    .padding(32)
    .background(Color.black.opacity(0.9))
}
