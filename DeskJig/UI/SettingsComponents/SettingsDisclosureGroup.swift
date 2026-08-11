//
//  SettingsDisclosureGroup.swift
//  DeskJig
//
//  Created by Claude Code on 02/02/26.
//

import SwiftUI
import DeskJigShared

/// A styled collapsible section for grouping related settings.
/// Matches the design system pattern from SettingsPanel.tsx DisclosureGroup component.
struct SettingsDisclosureGroup<Content: View>: View {
    let title: String
    @Binding var isExpanded: Bool
    let content: Content

    init(
        _ title: String,
        isExpanded: Binding<Bool>,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self._isExpanded = isExpanded
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Top border divider
            Rectangle()
                .fill(DesignTokens.Border.subtle)
                .frame(height: 1)
                .padding(.bottom, 12)

            // Clickable header
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(spacing: DesignTokens.Spacing.gapSmall) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: DesignTokens.IconSize.small, weight: .medium))
                        .foregroundStyle(DesignTokens.Text.secondary)
                        .frame(width: DesignTokens.IconSize.large)

                    Text(title)
                        .font(brand: .body3)
                        .foregroundStyle(DesignTokens.Text.secondary)

                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hovering in
                // Could add hover state here if desired
            }

            // Collapsible content
            if isExpanded {
                VStack(alignment: .leading, spacing: 12) {
                    content
                }
                .padding(.top, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(.top, 12)
    }
}

#Preview {
    VStack(alignment: .leading, spacing: 16) {
        SettingsDisclosureGroup("Thirds", isExpanded: .constant(true)) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Left third")
                    .foregroundStyle(DesignTokens.Text.secondary)
                Text("Center third")
                    .foregroundStyle(DesignTokens.Text.secondary)
                Text("Right third")
                    .foregroundStyle(DesignTokens.Text.secondary)
            }
        }

        SettingsDisclosureGroup("Quarters", isExpanded: .constant(false)) {
            Text("Content hidden")
        }
    }
    .padding(24)
    .frame(width: 400)
    .background(Color.black.opacity(0.9))
}
