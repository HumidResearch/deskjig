//
//  BlurTransition.swift
//  DeskJig
//
//  Created by Jake Sax on 10/27/25.
//

import SwiftUI
import DeskJigShared

@MainActor
public extension AnyTransition {
    /// A reusable blur-based transition that applies scaling, blurring, opacity, and offset.
    ///
    /// This transition is suitable for a variety of UI elements where a soft visual replacement is desired.
    ///
    /// - Parameters:
    ///   - blurRadius: The amount of blur to apply during transition.
    ///   - xOffset: The horizontal offset applied to the entering/exiting view.
    ///   - yOffset: The vertical offset applied to the entering/exiting view.
    ///   - scale: The minimum scale applied to the view.
    ///   - anchor: The anchor point used for scaling.
    ///   - reversesOnExit: When `true`, the view reverses direction when exiting, creating a symmetric
    ///     transition (e.g., enters from below, exits to below). When `false`, the view continues in
    ///     the same direction (e.g., enters from below, exits toward above). Defaults to `true`.
    /// - Returns: A configured `AnyTransition` instance.
    static func blurTransition(
        blurRadius: Double,
        xOffset: Double = .zero,
        yOffset: Double = .zero,
        scale: Double = 0.94,
        anchor: UnitPoint = .center,
        reversesOnExit: Bool = true
    ) -> AnyTransition {
        AnyTransition(
            BlurTransition(
                xOffset: xOffset,
                yOffset: yOffset,
                scale: scale,
                anchor: anchor,
                blurRadius: blurRadius,
                minOpacity: 0,
                reversesOnExit: reversesOnExit
            )
        )
    }
}