//
//  PlaceholderSectionView.swift
//  DeskJig
//
//  Created by Claude Code on 01/30/26.
//

import SwiftUI
import DeskJigShared

/// Generic placeholder view for unimplemented sections in the new settings UI.
struct PlaceholderSectionView: View {
    let section: SettingsSidebarSection

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            // Section header
            VStack(alignment: .leading, spacing: 8) {
                Text(section.title)
                    .font(brand: .h2)
                    .foregroundStyle(DesignTokens.Text.primary)

                Text(descriptionForSection)
                    .font(brand: .body2)
                    .foregroundStyle(DesignTokens.Text.secondary)
            }

            // Placeholder content card
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.gapMedium) {
                HStack(spacing: DesignTokens.Spacing.gapMedium) {
                    Image(systemName: section.icon)
                        .font(.system(size: DesignTokens.IconSize.xxxLarge))
                        .foregroundStyle(DesignTokens.Text.muted)

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Coming Soon")
                            .font(brand: .h4)
                            .foregroundStyle(DesignTokens.Text.primary)

                        Text(comingSoonMessage)
                            .font(brand: .body3)
                            .foregroundStyle(DesignTokens.Text.tertiary)
                    }
                }

                if !previewItems.isEmpty {
                    Divider()
                        .background(DesignTokens.Border.subtle)

                    // Preview of what's coming
                    VStack(alignment: .leading, spacing: DesignTokens.Spacing.gapRegular) {
                        ForEach(Array(previewItems.enumerated()), id: \.offset) { index, item in
                            HStack(spacing: DesignTokens.Spacing.gapRegular) {
                                Image(systemName: item.icon)
                                    .font(.system(size: DesignTokens.IconSize.medium))
                                    .foregroundStyle(DesignTokens.Text.muted)
                                    .frame(width: DesignTokens.IconSize.xLarge)

                                Text(item.label)
                                    .font(brand: .body3)
                                    .foregroundStyle(DesignTokens.Text.tertiary)
                            }
                        }
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: 600, alignment: .leading)
            .dsCard()
            .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Card.cornerRadius))

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var descriptionForSection: String {
        switch section {
        case .allWorkspaces:
            return "View and manage all your saved workspaces"
        case .favorites:
            return "Quick access to your favorite workspaces"
        case .tutorials:
            return "Learn how to get the most out of DeskJig"
        case .settings:
            return "Customize your DeskJig experience"
        case .helpFeedback:
            return "Get help and share your feedback"
        case .quickSwitch:
            return "Quickly switch project directories"
#if DEBUG
        case .designSystem:
            return "Preview design system components and tokens"
#endif
        }
    }

    private var comingSoonMessage: String {
        switch section {
        case .allWorkspaces:
            return "Your workspaces will appear here"
        case .favorites:
            return "Favorite workspaces will appear here"
        case .quickSwitch:
            return "Quick Switch will appear here"
        case .tutorials:
            return "Interactive tutorials coming soon"
        case .settings:
            return "Settings controls will be available here"
        case .helpFeedback:
            return "Help resources coming soon"
#if DEBUG
        case .designSystem:
            return "Design system preview available"
#endif
        }
    }

    private var previewItems: [(icon: String, label: String)] {
        switch section {
        case .settings:
            return [
                ("display", "Display"),
                ("keyboard", "Shortcuts"),
                ("bell", "Notifications"),
                ("paintbrush", "Appearance")
            ]
        case .tutorials:
            return [
                ("star.circle.fill", "Intro to DeskJig"),
                ("play.circle.fill", "Using Hotkeys"),
                ("rectangle.stack", "Workspace Management")
            ]
        case .helpFeedback:
            return [
                ("book", "Documentation"),
                ("envelope", "Contact Support"),
                ("bubble.left.and.bubble.right", "Community")
            ]
        default:
            return []
        }
    }
}

#Preview {
    PlaceholderSectionView(section: .settings)
        .padding(32)
        .background(Color.black.opacity(0.8))
}
