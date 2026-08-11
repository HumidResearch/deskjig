//  Keycap.swift
//  DeskJig
//
//  Created by Marco Freedom on 05.09.2025.
//

import SwiftUI
import DeskJigShared

/// Small rounded “keycap” used in tiles and bottom bar.
struct Keycap: View {
    let text: String
    
    init(_ text: String) { self.text = text }
    
    var body: some View {
        Text(text)
            .font(brand: .body4)
            .foregroundStyle(DesignTokens.Text.primary)
            .padding(.vertical, 4)
            .padding(.horizontal, 8)
            .background(
                RoundedRectangle(cornerRadius: DesignTokens.CornerRadius.medium)
                    .fill(DesignTokens.Surface.card)
                    .overlay(
                        RoundedRectangle(cornerRadius: DesignTokens.CornerRadius.medium)
                            .stroke(DesignTokens.Border.subtle, lineWidth: 1)
                    )
            )
    }
}

#Preview {
    Keycap("1")
        .padding(20)
}
