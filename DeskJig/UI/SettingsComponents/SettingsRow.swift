//
//  SettingsRow.swift
//  DeskJig
//
//  Created by Claude Code on 02/02/26.
//

import SwiftUI
import DeskJigShared

/// A horizontal row component for settings with label on left and control on right.
/// Matches the design system pattern from SettingsPanel.tsx SettingsRow component.
enum SettingsRowLayout {
    static let labelWidth: CGFloat = 280
    static let controlWidth: CGFloat = 280
}

struct SettingsRow<Content: View>: View {

    let label: String
    let labelWidth: CGFloat
    let controlWidth: CGFloat
    let content: Content

    init(
        _ label: String,
        labelWidth: CGFloat = SettingsRowLayout.labelWidth,
        controlWidth: CGFloat = SettingsRowLayout.controlWidth,
        @ViewBuilder content: () -> Content
    ) {
        self.label = label
        self.labelWidth = labelWidth
        self.controlWidth = controlWidth
        self.content = content()
    }

    var body: some View {
        HStack {
            Text(label)
                .font(brand: .body3)
                .foregroundStyle(DesignTokens.Text.secondary)
                .frame(width: labelWidth, alignment: .leading)

            Spacer(minLength: 12)

            content
                .frame(width: controlWidth, alignment: .trailing)
        }
        .padding(.vertical, 4)
    }
}

/// A vertical settings row for controls that need more space below the label.
struct SettingsRowVertical<Content: View>: View {
    let label: String
    let subtitle: String?
    let content: Content

    init(
        _ label: String,
        subtitle: String? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.label = label
        self.subtitle = subtitle
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(label)
                .font(brand: .body3)
                .foregroundStyle(DesignTokens.Text.primary)

            if let subtitle {
                Text(subtitle)
                    .font(brand: .body4)
                    .foregroundStyle(DesignTokens.Text.tertiary)
            }

            content
        }
    }
}

#Preview {
    VStack(spacing: 16) {
        SettingsRow("Interface Scale") {
            Text("Regular")
                .foregroundStyle(DesignTokens.Text.primary)
        }

        SettingsRow("Open DeskJig") {
            Text("Command + K")
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background {
                    Capsule()
                        .fill(DesignTokens.Surface.card)
                }
                .foregroundStyle(DesignTokens.Text.primary)
        }

        Divider().background(.white.opacity(0.2))

        SettingsRowVertical("Auto-Close Delay", subtitle: "Seconds before the menu closes") {
            HStack {
                Slider(value: .constant(5.0), in: 1...10)
                    .frame(width: 150)
                Text("5.0s")
                    .foregroundStyle(DesignTokens.Text.secondary)
            }
        }
    }
    .padding(24)
    .background(Color.black.opacity(0.9))
}
