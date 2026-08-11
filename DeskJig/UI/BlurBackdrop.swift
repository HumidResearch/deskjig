//  BlurBackdrop.swift
//  DeskJig
//
//  Created by Marco Freedom on 05.09.2025.
//

import SwiftUI
import DeskJigShared

/// Solid neutral window background (no translucency).
struct BlurBackdrop: View {
    var background: Color = DesignTokens.Surface.window

    var body: some View {
        background
            .ignoresSafeArea()
    }
}
