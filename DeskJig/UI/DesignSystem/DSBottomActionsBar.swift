//
//  DSBottomActionsBar.swift
//  DeskJig
//
//  Created by Codex on 02/04/26.
//

import SwiftUI
import DeskJigShared

struct DSBottomActionsBar<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        content
            .padding(.vertical, 10)
            .padding(.horizontal, 16)
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

#Preview {
    DSBottomActionsBar {
        HStack(spacing: 12) {
            Text("Preview")
                .foregroundStyle(DesignTokens.Text.primary)
            Spacer()
            Text("Path")
                .foregroundStyle(DesignTokens.Text.tertiary)
        }
    }
    .padding(24)
    .background(DesignTokens.Surface.elevated)
}
