//
//  DSStatusLabel.swift
//  DeskJig
//
//  Created by Codex on 02/02/26.
//

import SwiftUI
import DeskJigShared

/// A compact status label with icon and text using design tokens.
struct DSStatusLabel: View {
    let text: String
    let systemIcon: String
    let color: Color
    var font: Font.BrandFont = .body3
    var iconSize: CGFloat = DesignTokens.IconSize.small

    var body: some View {
        HStack(spacing: DesignTokens.Spacing.gapTiny) {
            Image(systemName: systemIcon)
                .font(.system(size: iconSize, weight: .medium))
            Text(text)
                .font(brand: font)
        }
        .foregroundStyle(color)
    }
}

#Preview {
    VStack(alignment: .leading, spacing: 12) {
        DSStatusLabel(
            text: "Granted",
            systemIcon: "checkmark.circle.fill",
            color: DesignTokens.Status.success
        )

        DSStatusLabel(
            text: "Not Granted",
            systemIcon: "exclamationmark.triangle.fill",
            color: DesignTokens.Status.error
        )
    }
    .padding(24)
    .background(Color.black.opacity(0.9))
}
