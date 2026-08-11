//
//  OverlayView.swift
//  DeskJig
//
//  Created by Marco Freedom on 02.09.2025.
//

import SwiftUI

public struct OverlayView: View {
    let windowInfo: WindowInfo
    let opacity: Double
    let color: Color
    let showBorders: Bool
    let showLabels: Bool

    public var body: some View {
        ZStack(alignment: .topLeading) {
            if showBorders {
                Rectangle()
                    .stroke(color.opacity(max(opacity, 0.25)), lineWidth: 20)
                    .background(Color.clear)
                    .allowsHitTesting(false)
            }

            if showLabels {
                overlayLabel
                    .padding(10)
                    .allowsHitTesting(false)
            }
        }
    }

    private var overlayLabel: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(windowInfo.appName)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.white)
                .shadow(color: .black.opacity(0.6), radius: 2, x: 0, y: 1)

            if !windowInfo.windowTitle.isEmpty && windowInfo.windowTitle != "Untitled" {
                Text(windowInfo.windowTitle)
                    .font(.system(size: 10))
                    .foregroundColor(.white.opacity(0.9))
                    .shadow(color: .black.opacity(0.6), radius: 2, x: 0, y: 1)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color.black.opacity(max(opacity * 1.5, 0.25)))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}
