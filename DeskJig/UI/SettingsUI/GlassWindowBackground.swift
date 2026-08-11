//
//  GlassWindowBackground.swift
//  DeskJig
//
//  Created by Claude Code on 01/30/26.
//

import SwiftUI
import DeskJigShared

/// Clean window background using the design system surface hierarchy.
struct GlassWindowBackground: View {
    var cornerRadius: CGFloat = 16
    var borderOpacity: CGFloat = 0.15

    var body: some View {
        ZStack {
            DesignTokens.Surface.window

            // Border
            RoundedRectangle(cornerRadius: cornerRadius)
                .stroke(DesignTokens.Border.subtle.opacity(min(borderOpacity / 0.15, 1)), lineWidth: 1)
        }
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
        .ignoresSafeArea()
    }
}

/// Alternative: Pure SwiftUI material-based glass card for content areas
/// Use this for cards/panels within the window (not the window itself)
struct GlassMaterialCard: View {
    var material: Material = .ultraThinMaterial
    var cornerRadius: CGFloat = 12

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius)
            .fill(material)
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius)
                    .stroke(DesignTokens.Border.subtle, lineWidth: 1)
            }
    }
}

#Preview {
    ZStack {
        // Simulate desktop background
        LinearGradient(
            colors: [DesignTokens.Surface.window, DesignTokens.Surface.cardHover],
            startPoint: .top,
            endPoint: .bottom
        )
        .ignoresSafeArea()

        VStack {
            Text("Glass Window Background")
                .font(brand: .h4)
                .foregroundStyle(DesignTokens.Text.primary)
        }
        .frame(width: 600, height: 400)
        .background(GlassWindowBackground())
    }
}
