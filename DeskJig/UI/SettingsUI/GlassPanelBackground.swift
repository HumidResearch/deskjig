//
//  GlassPanelBackground.swift
//  DeskJig
//
//  Created by Codex on 02/04/26.
//

import SwiftUI
import AppKit
import DeskJigShared

/// Reusable glass panel background for sidebar and main content surfaces.
struct GlassPanelBackground: View {
    var material: NSVisualEffectView.Material = .sidebar
    var blending: NSVisualEffectView.BlendingMode = .withinWindow
    var tint: Color = .clear
    var showBorder: Bool = false
    var borderColor: Color = DesignTokens.Border.subtle
    var borderWidth: CGFloat = 1

    var body: some View {
        ZStack {
            VisualEffect(material: material, blending: blending)
            tint
            if showBorder {
                Rectangle()
                    .stroke(borderColor, lineWidth: borderWidth)
            }
        }
    }
}

#Preview {
    ZStack {
        LinearGradient(
            colors: [DesignTokens.Surface.window, DesignTokens.Surface.cardHover],
            startPoint: .top,
            endPoint: .bottom
        )
        .ignoresSafeArea()

        HStack(spacing: 0) {
            GlassPanelBackground(material: .sidebar)
                .frame(width: 220)
            GlassPanelBackground(material: .contentBackground)
        }
        .frame(width: 600, height: 400)
    }
}
