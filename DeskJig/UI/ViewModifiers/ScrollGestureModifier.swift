//
//  ScrollGestureModifier.swift
//  DeskJig
//
//  Created by Jake Sax on 11/17/25.
//

import SwiftUI
import DeskJigShared

// MARK: - Gesture Value
/// The value of a scroll gesture on macOS trackpads.
public struct ScrollGestureValue: Sendable, Equatable {
    /// The current translation of the scroll gesture.
    public let translation: CGSize
    
    /// The predicted final translation if the current velocity continues with natural deceleration.
    ///
    /// This value estimates where the scroll gesture will end based on the current
    /// momentum and typical trackpad deceleration curves.
    public let predictedEndTranslation: CGSize
    
    /// The velocity of the scroll gesture in points per second.
    public let velocity: CGSize
    
    /// Whether the gesture is in its momentum phase.
    public let isMomentum: Bool
    
    /// The current phase of the gesture.
    public let phase: NSEvent.Phase
}

// MARK: - View Extension

public extension View {
    /// Adds a scroll gesture recognizer to the view.
    ///
    /// - Parameter gesture: The scroll gesture to attach.
    /// - Returns: A view with the gesture recognizer attached.
    func onScrollGesture(
        onChanged: @escaping (ScrollGestureValue) -> Void,
        onEnded: @escaping (ScrollGestureValue) -> Void
    ) -> some View {
        modifier(
            ScrollGestureModifier(
                onChanged: onChanged,
                onEnded: onEnded
            )
        )
    }
}

// MARK: - View Modifier

/// A view modifier that detects trackpad scroll gestures on macOS.
private struct ScrollGestureModifier: ViewModifier {
    let onChanged: (ScrollGestureValue) -> Void
    let onEnded: (ScrollGestureValue) -> Void
    
    func body(content: Content) -> some View {
        content
            .background(
                ScrollGestureRepresentable(onChanged: onChanged, onEnded: onEnded)
            )
    }
}

// MARK: - NSView Representable
/// Wraps an NSView to capture scroll events from the trackpad.
private struct ScrollGestureRepresentable: NSViewRepresentable {
    let onChanged: (ScrollGestureValue) -> Void
    let onEnded: (ScrollGestureValue) -> Void
    
    
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel]) { event in
            context.coordinator.handleEvent(event)
            return event
        }
        return view
    }
    
    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.onChanged = onChanged
        context.coordinator.onEnded = onEnded
    }
    
    func makeCoordinator() -> Coordinator {
        Coordinator(onChanged: onChanged, onEnded: onEnded)
    }
    
    final class Coordinator: NSObject {
        var onChanged: (ScrollGestureValue) -> Void
        var onEnded: (ScrollGestureValue) -> Void
        
        private var accumulatedTranslation: CGSize = .zero
        private var lastEventTime: TimeInterval = 0
        private var lastDelta: CGSize = .zero
        
        /// The decay time constant for momentum prediction (in seconds).
        ///
        /// This approximates the typical macOS trackpad momentum deceleration curve.
        private let momentumDecayConstant: CGFloat = 0.35
        
        init(
            onChanged: @escaping (ScrollGestureValue) -> Void,
            onEnded: @escaping (ScrollGestureValue) -> Void
        ) {
            self.onChanged = onChanged
            self.onEnded = onEnded
        }
        
        func handleEvent(_ event: NSEvent) {
            guard event.type == .scrollWheel,
                  event.hasPreciseScrollingDeltas
            else {
                return
            }
            
            let delta = CGSize(
                width: event.scrollingDeltaX,
                height: event.scrollingDeltaY
            )
            
            // Calculate velocity
            let currentTime = event.timestamp
            let timeDelta = currentTime - lastEventTime
            let velocity: CGSize
            
            if timeDelta > 0 {
                velocity = CGSize(
                    width: delta.width / timeDelta,
                    height: delta.height / timeDelta
                )
            } else {
                velocity = .zero
            }
            
            lastEventTime = currentTime
            lastDelta = delta
            
            let isMomentumPhase = event.phase == []
            let currentPhase = isMomentumPhase ? event.momentumPhase : event.phase
            
            // Accumulate translation during active phases
            if currentPhase == .began || currentPhase == .changed {
                accumulatedTranslation.width += delta.width
                accumulatedTranslation.height += delta.height
            }
            
            // Calculate predicted end translation based on velocity and momentum decay
            let predictedEndTranslation = calculatePredictedEndTranslation(
                currentTranslation: accumulatedTranslation,
                velocity: velocity,
                isMomentum: isMomentumPhase
            )
            
            let value = ScrollGestureValue(
                translation: accumulatedTranslation,
                predictedEndTranslation: predictedEndTranslation,
                velocity: velocity,
                isMomentum: isMomentumPhase,
                phase: currentPhase
            )
            
            switch currentPhase {
            case .began, .changed:
                DeskJigLog.debug(.app, "ScrollGestureModifier: on changed", fields: ["phase": currentPhase.rawValue])
                onChanged(value)

            case .ended, .cancelled:
                DeskJigLog.debug(.app, "ScrollGestureModifier: on ended")
                onEnded(value)
                // Reset accumulated translation
                accumulatedTranslation = .zero
                
            default:
                break
            }
        }
        
        /// Calculates the predicted end translation based on current velocity and momentum.
        ///
        /// Uses an exponential decay model to approximate macOS trackpad momentum behavior:
        /// `predictedDistance ≈ velocity × timeConstant`
        ///
        /// - Parameters:
        ///   - currentTranslation: The current accumulated translation.
        ///   - velocity: The current velocity in points per second.
        ///   - isMomentum: Whether the gesture is in its momentum phase.
        /// - Returns: The predicted final translation.
        private func calculatePredictedEndTranslation(
            currentTranslation: CGSize,
            velocity: CGSize,
            isMomentum: Bool
        ) -> CGSize {
            // If already in momentum phase, use a shorter prediction window
            let decayFactor = isMomentum ? 0.5 : 1.0
            let effectiveDecayConstant = momentumDecayConstant * decayFactor
            
            // Calculate predicted additional distance based on velocity with exponential decay
            // Using approximation: distance ≈ velocity * timeConstant for exponential decay
            let predictedAdditionalDistance = CGSize(
                width: velocity.width * effectiveDecayConstant,
                height: velocity.height * effectiveDecayConstant
            )
            
            return CGSize(
                width: currentTranslation.width + predictedAdditionalDistance.width,
                height: currentTranslation.height + predictedAdditionalDistance.height
            )
        }
    }
}

// MARK: - Usage Example

private struct ScrollTestView: View {
    @State private var offset: CGFloat = 0
    @State private var isDismissed = false
    
    var body: some View {
        VStack {
            if !isDismissed {
                notificationView
                    .offset(x: offset)
                    .animation(.spring(response: 0.3, dampingFraction: 0.7), value: offset)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    
    private var notificationView: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Notification")
                .font(.headline)
            Text("Swipe left or right to dismiss")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .shadow(radius: 5)
        .padding()
        .onScrollGesture(
            onChanged: { value in
                offset = value.translation.width
            },
            onEnded: { value in
                //                    handleDismissal(value)
                offset = .zero
            }
        )
    }
    
    /// Handles the end of the scroll gesture and determines if dismissal should occur.
    ///
    /// - Parameter value: The final value of the scroll gesture.
    private func handleDismissal(
        _ value: ScrollGestureValue
    ) {
        let dismissThreshold: CGFloat = 100
        
        if abs(value.translation.width) > dismissThreshold {
            // Animate off screen in the direction of the swipe
            offset = value.translation.width > 0 ? 400 : -400
            
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                isDismissed = true
            }
        } else {
            // Spring back to center
            offset = 0
        }
    }
}

#Preview {
    ScrollTestView()
}