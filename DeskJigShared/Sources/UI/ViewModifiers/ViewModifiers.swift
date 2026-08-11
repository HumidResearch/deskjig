//
//  ViewModifiers.swift
//  MonitorAppWindows
//
//  Created by Jake Sax on 9/11/25.
//

import SwiftUI

extension View {
    
    /// Applies an overlay to the View to easily debug and visualize the frame of the View.
    func showViewFrame(color: Color = DesignTokens.Status.error) -> some View {
        self.overlay {
            color
                .opacity(0.2)
                .allowsHitTesting(false)
        }
    }
    
}
