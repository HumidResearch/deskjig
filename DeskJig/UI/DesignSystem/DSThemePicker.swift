//
//  DSThemePicker.swift
//  DeskJig
//
//  Created by Codex on 02/04/26.
//

import SwiftUI
import DeskJigShared

struct DSThemePicker: View {
    @Binding var selection: AppTheme

    var body: some View {
        ZStack(alignment: .trailing) {
            RoundedRectangle(cornerRadius: DesignTokens.CornerRadius.full)
                .fill(DesignTokens.Surface.input)
                .overlay(
                    RoundedRectangle(cornerRadius: DesignTokens.CornerRadius.full)
                        .stroke(DesignTokens.Border.subtle, lineWidth: 1)
                )

            HStack(spacing: 0) {
                segment(title: "System", systemImage: "laptopcomputer", value: .system)
                segment(title: "Light", systemImage: "sun.max.fill", value: .light)
                segment(title: "Dark", systemImage: "moon.fill", value: .dark)
            }
            .padding(4)
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
    }

    private func segment(title: String, systemImage: String, value: AppTheme) -> some View {
        Button {
            withAnimation(.easeInOut(duration: 0.15)) {
                selection = value
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: systemImage)
                    .font(brand: Font.brandBody(size: 12))
                Text(title)
                    .font(brand: .body4)
            }
            .foregroundStyle(selection == value ? DesignTokens.Text.primary : DesignTokens.Text.tertiary)
            .padding(.vertical, 6)
            .padding(.horizontal, 12)
            .background(
                RoundedRectangle(cornerRadius: DesignTokens.CornerRadius.full)
                    .fill(selection == value ? DesignTokens.Surface.card : Color.clear)
            )
        }
        .buttonStyle(.plain)
    }
}

#Preview {
    DSThemePicker(selection: .constant(.dark))
        .padding(24)
        .background(DesignTokens.Surface.elevated)
}
