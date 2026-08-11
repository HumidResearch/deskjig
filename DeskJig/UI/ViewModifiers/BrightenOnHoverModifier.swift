//
//  BrightenOnHoverModifier.swift
//  DeskJig
//
//  Created by Jake Sax on 10/21/25.
//

import SwiftUI

/// A view modifier that brightens the view when hovered. You can also darken
/// the view by providing a negative brightness value.
private struct BrightenOnHoverViewModifier: ViewModifier {
    let brightnessOnHover: Double
    @State private var isHovering: Bool = false
    
    func body(content: Content) -> some View {
        content
            .brightness(isHovering ? brightnessOnHover : 0)
            .onHover { isHovering = $0 }
    }
}

public extension View {
    /// Applies a brightness effect to a view when it's hovered over.
    ///
    /// Use this modifier to create an interactive visual feedback when the user hovers
    /// their cursor over the view. By default, it brightens the view, but you can also
    /// darken it by providing a negative brightness value.
    ///
    /// - Parameter brightness: The amount of brightness to apply when hovered.
    ///   Positive values brighten the view, while negative values darken it.
    ///   Defaults to 0.2 (slight brightening).
    func brightenOnHover(_ brightness: Double = 0.2) -> some View {
        self.modifier(BrightenOnHoverViewModifier(brightnessOnHover: brightness))
    }
}