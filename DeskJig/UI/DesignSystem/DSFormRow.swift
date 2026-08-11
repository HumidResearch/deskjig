//
//  DSFormRow.swift
//  DeskJig
//
//  Created by Claude Code on 02/02/26.
//

import SwiftUI
import DeskJigShared

/// A wrapper that ensures all elements in a horizontal row have consistent heights.
///
/// Use this to align inputs, buttons, and other form elements at the same height.
///
/// Usage:
/// ```swift
/// DSFormRow {
///     DSTextField(placeholder: "Path...", text: $path)
///     Button("Browse") { ... }
///     Button("Verify") { ... }
/// }
/// ```
struct DSFormRow<Content: View>: View {
    /// The fixed height for all row elements
    var height: CGFloat = DesignTokens.Form.inputHeight // 40px

    @ViewBuilder let content: () -> Content

    var body: some View {
        HStack(spacing: DesignTokens.Spacing.gapSmall) {
            content()
        }
        .frame(height: height)
    }
}

// MARK: - Preview

#Preview("DSFormRow") {
    VStack(spacing: 24) {
        Text("Form Rows")
            .font(brand: .h3)
            .foregroundStyle(DesignTokens.Text.primary)

        VStack(alignment: .leading, spacing: 16) {
            Text("Consistent Height Elements")
                .font(brand: .label2)
                .foregroundStyle(DesignTokens.Text.secondary)

            DSFormRow {
                // Input field
                HStack {
                    Image(systemName: "folder")
                        .foregroundStyle(DesignTokens.Text.tertiary)
                    Text("/Users/dev/project")
                        .foregroundStyle(DesignTokens.Text.primary)
                    Spacer()
                }
                .padding(.horizontal, 12)
                .frame(maxWidth: .infinity)
                .background(DesignTokens.Surface.input)
                .clipShape(RoundedRectangle(cornerRadius: DesignTokens.CornerRadius.large))

                Button("Browse") { }
                    .buttonStyle(.dsButton(variant: .secondary, size: .medium))

                Button("Verify") { }
                    .buttonStyle(.dsButton(variant: .tertiary, size: .medium))
            }
        }
    }
    .padding(32)
    .frame(width: 500)
    .background(Color.black.opacity(0.9))
}
