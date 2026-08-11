//
//  DSTag.swift
//  DeskJig
//
//  Created by Claude Code on 02/02/26.
//

import SwiftUI
import DeskJigShared

/// Size variants for DSTag.
enum DSTagSize {
    /// Smaller tag: px-2 py-0.5, text-xs equivalent
    case small
    /// Standard tag: px-2.5 py-1, text-xs equivalent
    case medium
}

/// A reusable tag/badge component for labels and categories.
///
/// Features:
/// - Configurable color
/// - Size variants (small, medium)
/// - Optional remove button
/// - Subtle rounded corners (rounded-lg, not pill)
///
/// Usage:
/// ```swift
/// DSTag(label: "Chrome", color: DesignTokens.SpecialApp.chrome)
/// DSTag(label: "Removable", isRemovable: true, onRemove: { ... })
/// ```
struct DSTag: View {
    let label: String
    var color: Color = DesignTokens.Text.secondary
    var size: DSTagSize = .medium
    var isRemovable: Bool = false
    var onRemove: (() -> Void)? = nil

    var body: some View {
        HStack(spacing: 4) {
            Text(label)
                .font(brand: size == .small ? .body4 : .label4)
                .foregroundStyle(color)

            if isRemovable, let onRemove {
                Button { onRemove() } label: {
                    Image(systemName: "xmark")
                        .font(brand: Font.brandBody(size: 8))
                        .foregroundStyle(color.opacity(0.7))
                }
                .buttonStyle(.plain)
                .brightenOnHover()
            }
        }
        .padding(.horizontal, size == .small ? 6 : 8)
        .padding(.vertical, size == .small ? 2 : 4)
        .background {
            RoundedRectangle(cornerRadius: DesignTokens.CornerRadius.medium) // rounded-lg = 6px
                .fill(color.opacity(0.12))
        }
        .overlay {
            RoundedRectangle(cornerRadius: DesignTokens.CornerRadius.medium)
                .stroke(color.opacity(0.35), lineWidth: 1)
        }
    }
}

// MARK: - Preview

#Preview("DSTag") {
    VStack(spacing: 24) {
        Text("Tags / Badges")
            .font(brand: .h3)
            .foregroundStyle(DesignTokens.Text.primary)

        VStack(alignment: .leading, spacing: 16) {
            Text("Sizes")
                .font(brand: .label2)
                .foregroundStyle(DesignTokens.Text.secondary)

            HStack(spacing: 12) {
                DSTag(label: "Small", size: .small)
                DSTag(label: "Medium", size: .medium)
            }
        }

        VStack(alignment: .leading, spacing: 16) {
            Text("Special App Types")
                .font(brand: .label2)
                .foregroundStyle(DesignTokens.Text.secondary)

            HStack(spacing: 12) {
                DSTag(label: "Chrome", color: DesignTokens.SpecialApp.chrome, size: .small)
                DSTag(label: "IDE", color: DesignTokens.SpecialApp.ide, size: .small)
                DSTag(label: "Terminal", color: DesignTokens.SpecialApp.terminal, size: .small)
            }
        }

        VStack(alignment: .leading, spacing: 16) {
            Text("Status Colors")
                .font(brand: .label2)
                .foregroundStyle(DesignTokens.Text.secondary)

            HStack(spacing: 12) {
                DSTag(label: "Error", color: DesignTokens.Status.error)
            }
        }

        VStack(alignment: .leading, spacing: 16) {
            Text("Removable")
                .font(brand: .label2)
                .foregroundStyle(DesignTokens.Text.secondary)

            HStack(spacing: 12) {
                DSTag(label: "Removable", isRemovable: true, onRemove: { })
                DSTag(label: "Tab URL", color: DesignTokens.Status.info, isRemovable: true, onRemove: { })
            }
        }
    }
    .padding(32)
    .background(Color.black.opacity(0.9))
}
