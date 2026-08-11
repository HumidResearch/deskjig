//  UpdateBadge.swift
//  DeskJig

import SwiftUI
import DeskJigShared

/// A pulsating badge that surfaces an available update and runs the update
/// action when tapped.
///
/// Used by the settings sidebar and the main content top bar to advertise a
/// Sparkle app update, and by the settings screen to advertise a stale
/// `deskjig` CLI install.
struct UpdateBadge: View {
    var text: String = "New Update"
    var color: Color = DesignTokens.Status.success
    var isActive: Bool = true
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            Text(text)
                .font(brand: Font.brandBody(size: 11))
                .foregroundStyle(DesignTokens.Text.primary)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background {
                    Capsule()
                        .fill(color)
                }
        }
        .buttonStyle(.plain)
        .repeatingAnimation(
            isActive: isActive,
            duration: 1.5,
            animation: .easeInOut(duration: 0.75)
        ) { content, didAnimate, _ in
            content
                .shadow(
                    color: color.opacity(didAnimate ? 0.8 : 0.3),
                    radius: didAnimate ? 12 : 4,
                    x: 0,
                    y: 0
                )
        }
    }
}

#Preview {
    ZStack {
        Color.black
        UpdateBadge { }
    }
}
