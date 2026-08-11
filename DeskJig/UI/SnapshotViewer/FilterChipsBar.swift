//
//  FilterChipsBar.swift
//  DeskJig
//
//  Horizontal bar showing active filters as removable chips
//

import SwiftUI
import DeskJigShared

struct FilterChipsBar: View {
    let chips: [FilterChip]
    let onRemove: (FilterChip) -> Void
    let onClearAll: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "line.3.horizontal.decrease.circle")
                .foregroundStyle(.secondary)
                .font(.caption)

            Text("Filters:")
                .font(.caption)
                .foregroundStyle(.secondary)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(chips) { chip in
                        FilterChipView(chip: chip) {
                            onRemove(chip)
                        }
                    }
                }
            }

            Spacer()

            Button("Clear All") {
                onClearAll()
            }
            .buttonStyle(.borderless)
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal)
        .padding(.vertical, 6)
        .background(.bar)
    }
}

struct FilterChipView: View {
    let chip: FilterChip
    let onRemove: () -> Void

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: chip.icon)
                .font(.caption2)
                .foregroundStyle(.secondary)

            Text(chip.label)
                .font(.caption)
                .lineLimit(1)

            Button(action: onRemove) {
                Image(systemName: "xmark.circle.fill")
                    .font(.caption2)
            }
            .buttonStyle(.plain)
            .foregroundStyle(isHovered ? .primary : .secondary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            Capsule()
                .fill(isHovered ? DesignTokens.Surface.elevated : DesignTokens.Surface.cardHover)
        )
        .overlay(
            Capsule()
                .strokeBorder(DesignTokens.Border.subtle, lineWidth: 0.5)
        )
        .onHover { hovering in
            isHovered = hovering
        }
    }
}

#Preview {
    VStack {
        FilterChipsBar(
            chips: [
                .display(index: 0, name: "DELL U2720Q"),
                .searchText("Chrome"),
                .onScreen(true),
                .minSize(100)
            ],
            onRemove: { _ in },
            onClearAll: { }
        )

        FilterChipsBar(
            chips: [.minimized(false)],
            onRemove: { _ in },
            onClearAll: { }
        )
    }
    .frame(width: 600)
}
