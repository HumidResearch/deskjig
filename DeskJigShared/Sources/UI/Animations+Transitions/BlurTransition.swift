//
//  BlurTransition.swift
//  DeskJig
//
//  Created by Jake Sax on 10/27/25.
//

import SwiftUI

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
    
    /// A composite transition that applies offset, scale, blur, and opacity effects.
    ///
    /// This transition is intended for use in `AnyTransition` extensions and provides
    /// directional movement, size shrinking/growing, a light blur, and a fade effect.
    struct BlurTransition: Transition {
        
        private let xOffset: Double
        private let yOffset: Double
        private let scale: Double
        private let anchor: UnitPoint
        private let blurRadius: Double
        private let minOpacity: Double
        private let reversesOnExit: Bool
        
        public func body(content: Content, phase: TransitionPhase) -> some View {
            content
                .opacity(phase.isIdentity ? 1 : minOpacity)
                .scaleEffect(phase.isIdentity ? 1 : scale, anchor: anchor)
                .blur(radius: phase.isIdentity ? 0 : blurRadius)
                .offset(
                    x: offset(xOffset, for: phase, reverses: reversesOnExit),
                    y: offset(yOffset, for: phase, reverses: reversesOnExit)
                )
        }
        
        /// Creates a new instance of `BlurTransition`.
        ///
        /// - Parameters:
        ///   - xOffset: Horizontal movement during transition.
        ///   - yOffset: Vertical movement during transition.
        ///   - scale: Minimum scale during transition.
        ///   - anchor: Anchor point for scaling.
        ///   - blurRadius: Radius of the blur effect.
        ///   - minOpacity: Minimum opacity at the start or end of the transition.
        ///   - reversesOnExit: When `true`, the view reverses direction when exiting, creating a symmetric
        ///     transition. When `false`, the view continues in the same direction throughout the transition.
        ///     Defaults to `true`.
        public init(
            xOffset: Double = .zero,
            yOffset: Double = .zero,
            scale: Double = 0.94,
            anchor: UnitPoint = .center,
            blurRadius: Double = 1,
            minOpacity: Double = 0,
            reversesOnExit: Bool = true
        ) {
            self.xOffset = xOffset
            self.yOffset = yOffset
            self.scale = scale
            self.anchor = anchor
            self.blurRadius = blurRadius
            self.minOpacity = minOpacity
            self.reversesOnExit = reversesOnExit
        }
        
        /// Calculates the offset based on the transition phase and direction behavior.
        ///
        /// - Parameters:
        ///   - offset: The base offset value to apply.
        ///   - phase: The current transition phase.
        ///   - reverses: When `true`, applies the opposite offset during exit; when `false`,
        ///     continues in the same direction.
        /// - Returns: The calculated offset for the current phase.
        private func offset(
            _ offset: Double,
            for phase: TransitionPhase,
            reverses: Bool
        ) -> Double {
            switch phase {
            case .willAppear: offset
            case .identity: 0
            case .didDisappear: reverses ? offset : -offset
            }
        }
    }
}
