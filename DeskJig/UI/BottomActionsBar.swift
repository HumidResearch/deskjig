//  BottomActionsBar.swift
//  DeskJig
//
//  Created by Marco Freedom on 05.09.2025.
//

import SwiftUI
import DeskJigShared

struct BottomActionsBar: View {
    let isInFolder: Bool
    let currentPath: String

    var body: some View {
        DSBottomActionsBar {
            HStack(spacing: 12) {
                Keycap("ESC")
                Text("Back")
                    .foregroundStyle(DesignTokens.Text.secondary)
                Keycap("↩︎")
                Text(isInFolder ? "Open" : "Confirm")
                    .foregroundStyle(DesignTokens.Text.secondary)

                Spacer()

                // Breadcrumb path
                Text(currentPath)
                    .font(brand: .body4)
                    .foregroundStyle(DesignTokens.Text.tertiary)
                    .lineLimit(1)
            }
            .font(brand: .body4)
        }
    }
}
