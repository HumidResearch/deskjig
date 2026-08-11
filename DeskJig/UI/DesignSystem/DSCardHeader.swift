//
//  DSCardHeader.swift
//  DeskJig
//
//  Created by Claude Code on 02/02/26.
//

import SwiftUI
import DeskJigShared

/// A reusable card header component with icon, title, and optional subtitle.
///
/// Features:
/// - Icon displayed in a rounded colored background
/// - Title and optional subtitle
/// - Customizable icon colors
///
/// Usage:
/// ```swift
/// DSCardHeader(
///     icon: "globe",
///     title: "Google Chrome",
///     subtitle: "Chrome Profile"
/// )
/// ```
struct DSCardHeader: View {
    let icon: String
    let title: String
    var subtitle: String? = nil
    var iconBackground: Color = DesignTokens.Brand.accentMuted
    var iconForeground: Color = DesignTokens.Text.primary

    var body: some View {
        HStack(spacing: DesignTokens.Spacing.gapRegular) {
            // Icon in colored background
            Image(systemName: icon)
                .font(.system(size: DesignTokens.Card.headerIconSize, weight: .medium))
                .foregroundStyle(iconForeground)
                .frame(
                    width: DesignTokens.Card.headerIconSize + DesignTokens.Card.headerIconPadding * 2,
                    height: DesignTokens.Card.headerIconSize + DesignTokens.Card.headerIconPadding * 2
                )
                .background(
                    RoundedRectangle(cornerRadius: DesignTokens.Card.headerIconCornerRadius)
                        .fill(iconBackground)
                )

            // Title and subtitle
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(brand: .label2)
                    .foregroundStyle(DesignTokens.Text.primary)

                if let subtitle {
                    Text(subtitle)
                        .font(brand: .body4)
                        .foregroundStyle(DesignTokens.Text.tertiary)
                }
            }

            Spacer()
        }
    }
}

#Preview {
    VStack(alignment: .leading, spacing: 24) {
        Text("Card Headers")
            .font(brand: .h4)
            .foregroundStyle(DesignTokens.Text.primary)

        VStack(alignment: .leading, spacing: 16) {
            Text("With Subtitle")
                .font(brand: .body3)
                .foregroundStyle(DesignTokens.Text.secondary)

            DSCardHeader(
                icon: "globe",
                title: "Google Chrome",
                subtitle: "Chrome Profile"
            )
        }

        VStack(alignment: .leading, spacing: 16) {
            Text("Without Subtitle")
                .font(brand: .body3)
                .foregroundStyle(DesignTokens.Text.secondary)

            DSCardHeader(
                icon: "message",
                title: "Slack"
            )
        }

        VStack(alignment: .leading, spacing: 16) {
            Text("Custom Icon Color")
                .font(brand: .body3)
                .foregroundStyle(DesignTokens.Text.secondary)

            DSCardHeader(
                icon: "terminal",
                title: "Terminal",
                subtitle: "Open by Path",
                iconBackground: DesignTokens.Status.info
            )
        }

        VStack(alignment: .leading, spacing: 16) {
            Text("Multiple Headers")
                .font(brand: .body3)
                .foregroundStyle(DesignTokens.Text.secondary)

            VStack(alignment: .leading, spacing: 12) {
                DSCardHeader(icon: "globe", title: "Google Chrome", subtitle: "Chrome Profile")
                DSCardHeader(icon: "terminal", title: "VS Code", subtitle: "Open by Path")
                DSCardHeader(icon: "message", title: "Slack")
            }
        }
    }
    .padding(32)
    .frame(width: 400)
    .background(Color.black.opacity(0.9))
}
