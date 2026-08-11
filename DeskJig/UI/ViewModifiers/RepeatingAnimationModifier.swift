//
//  RepeatingAnimationModifier.swift
//  MonitorAppWindows
//
//  Created by Jake Sax on 9/10/25.
//

import SwiftUI

private struct RepeatingAnimationModifier<T: View>: ViewModifier {
    
    let isActive: Bool
    let duration: TimeInterval
    let animation: Animation
    @ViewBuilder let effect: (_ content: Content, _ didAnimate: Bool, _ isActive: Bool) -> T
    @State private var timer: Timer? = nil
    @State private var didAnimate: Bool = false
    
    func body(content: Content) -> some View {
        effect(content, didAnimate, isActive)
            .animation(animation, value: didAnimate)
            .animation(.smooth, value: isActive)
            .onAppear {
                if timer == nil, isActive {
                    startTimer()
                }
            }
//            .onDisappear {
//                stopTimer()
//            }
            .onChange(of: isActive) {
                if isActive {
                    animate()
                    startTimer()
                } else {
                    stopTimer()
                }
            }
    }
    
    private func startTimer() {
        timer = Timer.scheduledTimer(
            withTimeInterval: duration,
            repeats: true
        ) { _ in
            DispatchQueue.main.async {
                animate()
            }
        }
    }
    
    private func stopTimer() {
        timer?.invalidate()
        timer = nil
        didAnimate = false
    }
    
    private func animate() {
        withAnimation(animation) {
            didAnimate.toggle()
        }
    }
}

extension View {
    
    /// Applies a repeating animation effect to the view.
    ///
    /// This modifier creates a timer-based repeating animation that toggles a state
    /// at the specified interval, allowing you to create custom animated effects.
    ///
    /// Example usage:
    /// ```swift
    /// Circle()
    ///     .repeatingAnimation(
    ///         isActive: isAnimating,
    ///         duration: 0.5,
    ///         animation: .easeInOut(duration: 0.5)
    ///     ) { content, didAnimate in
    ///         content
    ///             .scaleEffect(didAnimate ? 1.2 : 1.0)
    ///             .opacity(didAnimate ? 0.6 : 1.0)
    ///     }
    /// ```
    ///
    /// - Parameters:
    ///   - isActive: A Boolean value that determines whether the animation is running.
    ///   - duration: The time interval between animation toggles, in seconds.
    ///   - animation: The animation to apply when toggling the effect.
    ///   - effect: A closure that transforms the view based on the animation state.
    ///     - content: The original view content.
    ///     - didAnimate: A Boolean indicating the current animation state.
    ///     - isActive: A Boolean indicating whether the animation is currently active at all.
    /// - Returns: A view with the repeating animation effect applied.
    @ViewBuilder
    public func repeatingAnimation<T: View>(
        isActive: Bool,
        duration: TimeInterval,
        animation: Animation,
        @ViewBuilder effect: @escaping (
            _ content: Self,
            _ didAnimate: Bool,
            _ isActive: Bool
        ) -> T
    ) -> some View {
        modifier(
            RepeatingAnimationModifier<T>(
                isActive: isActive,
                duration: duration,
                animation: animation
            ) { _, didAnimate, nowActive in
                // Use the original view (`self`) so callers don't have to handle `Content`.
                effect(self, didAnimate, nowActive)
            }
        )
    }
}