//  AppBackground.swift
//  DeskJig
//
//  Created by Codex on 02/04/26.
//

import SwiftUI
import DeskJigShared

struct AppBackground: View {
    var body: some View {
        DesignTokens.Surface.window
        .ignoresSafeArea()
    }
}

#Preview {
    AppBackground()
        .frame(width: 900, height: 600)
}
