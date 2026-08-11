//  UIExtensions.swift
//  DeskJig
//
//  Created by Jake Sax on 10/23/25.
//

import SwiftUI

extension ShapeStyle where Self == Color {
    /// Generates a random color. Can be placed in the background
    /// of a view to clearly indicate every time the view is recalculated.
    static var random: Color {
        Color(
            red: .random(in: 0...1),
            green: .random(in: 0...1),
            blue: .random(in: 0...1)
        )
    }
}
