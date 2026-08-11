//
//  BlurBackdrop.swift
//  DeskJig
//
//  Created by Marco Freedom on 05.09.2025.
//

import SwiftUI

/// Tintable transparent backdrop using NSVisualEffectView.
struct BlurBackdrop: View {
    let tint: Color
    var body: some View {
        ZStack {
            VisualEffect(material: .hudWindow, blending: .behindWindow)
                .ignoresSafeArea()
            tint.ignoresSafeArea()
        }
    }
}
