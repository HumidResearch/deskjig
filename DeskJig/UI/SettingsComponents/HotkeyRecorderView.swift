//
//  HotkeyRecorderView.swift
//  DeskJig
//
//  Created by Claude Code on 02/02/26.
//

import SwiftUI
import KeyboardShortcuts
import DeskJigShared

/// A styled keyboard shortcut recorder badge.
/// Wraps KeyboardShortcuts.Recorder with design system styling.
///
/// Style matches the React design system:
/// - Neutral capsule background (Surface.card)
/// - Narrower width, taller height
/// - Design token fonts
struct HotkeyRecorderView: View {
    let title: String
    let name: KeyboardShortcuts.Name
    var labelWidth: CGFloat = SettingsRowLayout.labelWidth
    var controlWidth: CGFloat = SettingsRowLayout.controlWidth

    var body: some View {
        HStack {
            if !title.isEmpty {
                Text(title)
                    .font(brand: .body3)
                    .foregroundStyle(DesignTokens.Text.secondary)
                    .frame(width: labelWidth, alignment: .leading)
            }

            Spacer(minLength: 12)

            // Styled recorder with capsule background
            KeyboardShortcuts.Recorder(for: name)
                .font(brand: .body3)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(
                    Capsule()
                        .fill(DesignTokens.Surface.card)
                )
                .overlay(
                    Capsule()
                        .stroke(DesignTokens.Border.subtle, lineWidth: 1)
                )
                .frame(width: controlWidth, alignment: .trailing)
        }
    }
}

/// A section header for grouping keyboard shortcuts.
struct ShortcutSectionHeader: View {
    let title: String
    var topPadding: CGFloat = 0

    var body: some View {
        Text(title)
            .font(brand: .body2)
            .foregroundStyle(DesignTokens.Text.primary)
            .padding(.top, topPadding)
    }
}

#Preview {
    VStack(alignment: .leading, spacing: 12) {
        ShortcutSectionHeader(title: "Primary")

        HotkeyRecorderView(
            title: "Open DeskJig:",
            name: .showWorkspaceView
        )

        ShortcutSectionHeader(title: "Layout Helpers", topPadding: 8)

        HotkeyRecorderView(
            title: "Move left:",
            name: .moveWindowLeft
        )
    }
    .padding(24)
    .background(Color.black.opacity(0.9))
}
