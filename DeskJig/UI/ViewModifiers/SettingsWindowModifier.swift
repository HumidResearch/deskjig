//
//  SettingsWindowModifier.swift
//  DeskJig
//
//  Created by Marco Freedom on 10.10.2025.
//

import SwiftUI

struct SettingsWindowModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .onAppear {
                bringSettingsToFront()
            }
    }
    
    private func bringSettingsToFront() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            if let settingsWindow = NSApp.windows.first(where: {
                $0.identifier?.rawValue.contains("Settings") ?? false ||
                $0.title.contains("Settings")
            }) {
                settingsWindow.makeKeyAndOrderFront(nil)
                NSApp.activate(ignoringOtherApps: true)
            }
        }
    }
}

extension View {
    func bringSettingsWindowToFront() -> some View {
        modifier(SettingsWindowModifier())
    }
}