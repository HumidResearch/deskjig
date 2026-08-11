//
//  DSEmojiPicker.swift
//  DeskJig
//
//  Created by Claude Code on 02/02/26.
//

import SwiftUI
import DeskJigShared

/// Emoji picker grid for workspace icons
struct DSEmojiPicker: View {
    @Binding var selectedEmoji: String
    @Binding var isPresented: Bool

    static let emojis: [String] = [
        "📁", "🗂️", "🧭", "🔍", "💡", "🚀", "⚡", "🎯",
        "📊", "📈", "🛠️", "⚙️", "🔧", "💻", "🖥️", "📱",
        "🎨", "🎵", "📷", "🎬", "📝", "📚", "🔬", "🧪",
        "💼", "📦", "🏠", "🏢", "🌐", "☁️", "🔒", "🔑",
        "💬", "📧", "📅", "⏰", "🎮", "🎲", "🏆", "⭐",
        "❤️", "💚", "💙", "💜", "🧡", "💛", "🤍", "🖤"
    ]

    var body: some View {
        LazyVGrid(
            columns: Array(repeating: GridItem(.fixed(32), spacing: 4), count: 8),
            spacing: 4
        ) {
            ForEach(Self.emojis, id: \.self) { emoji in
                Button {
                    selectedEmoji = emoji
                    isPresented = false
                } label: {
                    Text(emoji)
                        .font(brand: Font.brandBody(size: 18))
                        .frame(width: 28, height: 28)
                        .background {
                            RoundedRectangle(cornerRadius: DesignTokens.CornerRadius.medium)
                                .fill(selectedEmoji == emoji
                                    ? DesignTokens.Surface.cardHover
                                    : Color.clear)
                        }
                }
                .buttonStyle(.plain)
                .brightenOnHover()
            }
        }
        .padding(DesignTokens.Spacing.gapSmall)
        .background {
            RoundedRectangle(cornerRadius: DesignTokens.CornerRadius.large)
                .fill(DesignTokens.Surface.panel)
        }
        .overlay {
            RoundedRectangle(cornerRadius: DesignTokens.CornerRadius.large)
                .stroke(DesignTokens.Border.subtle, lineWidth: 1)
        }
    }
}

// MARK: - Preview

#Preview("Emoji Picker") {
    VStack(spacing: 24) {
        Text("Emoji Picker")
            .font(brand: .h3)
            .foregroundStyle(DesignTokens.Text.primary)

        DSEmojiPicker(
            selectedEmoji: .constant("🚀"),
            isPresented: .constant(true)
        )
    }
    .padding(32)
    .background(Color.black.opacity(0.9))
}
