//
//  SettingsToggle.swift
//  DeskJig
//
//  Created by Claude Code on 02/02/26.
//

import SwiftUI
import DeskJigShared

/// A toggle component with title and optional subtitle.
/// Matches the design system pattern for settings toggles.
///
/// Uses HStack layout with center alignment for proper vertical centering
/// of the toggle with the text content, matching the reference web UI pattern:
/// `flex items-center justify-between`
struct SettingsToggle: View {
    let title: String
    var subtitle: String?
    @Binding var isOn: Bool

    var body: some View {
        HStack(alignment: .center, spacing: DesignTokens.Spacing.gapMedium) {
            // Text content on left
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(brand: .body3)
                    .foregroundStyle(DesignTokens.Text.primary)

                if let subtitle {
                    Text(subtitle)
                        .font(brand: .body4)
                        .foregroundStyle(DesignTokens.Text.tertiary)
                }
            }

            Spacer()

            // Toggle on right, vertically centered
            Toggle("", isOn: $isOn)
                .toggleStyle(.switch)
                .labelsHidden()
                .tint(DesignTokens.Brand.accent)
        }
    }
}

/// A horizontal settings toggle for use in SettingsRow.
/// Shows just the toggle without any label (label comes from SettingsRow).
struct SettingsToggleControl: View {
    @Binding var isOn: Bool

    var body: some View {
        Toggle("", isOn: $isOn)
            .toggleStyle(.switch)
            .labelsHidden()
    }
}

#Preview {
    VStack(alignment: .leading, spacing: 24) {
        SettingsToggle(
            title: "Auto-Close Menu",
            subtitle: "Automatically close the menu after a period of inactivity",
            isOn: .constant(true)
        )

        SettingsToggle(
            title: "Hide all apps before restore",
            subtitle: "Temporarily hide all apps to reduce window overlap during restore",
            isOn: .constant(false)
        )

        Divider().background(.white.opacity(0.2))

        HStack {
            Text("Check for updates automatically")
                .foregroundStyle(DesignTokens.Text.primary)
            Spacer()
            SettingsToggleControl(isOn: .constant(true))
        }
    }
    .padding(24)
    .background(Color.black.opacity(0.9))
}
