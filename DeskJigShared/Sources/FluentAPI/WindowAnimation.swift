//  WindowAnimation.swift
//  DeskJigShared

import Foundation
import QuartzCore

// MARK: - Animation Options

/// Options for window animations
public struct WindowAnimationOptions: Sendable {
    /// Duration of the animation in seconds
    public var duration: TimeInterval

    /// Easing function to apply
    public var easing: AnimationEasing

    /// Delay between sequential animations (for staggered effects)
    public var staggerDelay: TimeInterval

    public init(
        duration: TimeInterval = 0.25,
        easing: AnimationEasing = .easeOutCubic,
        staggerDelay: TimeInterval = 0
    ) {
        self.duration = duration
        self.easing = easing
        self.staggerDelay = staggerDelay
    }

    // MARK: - Presets

    /// Default animation (0.25s, easeOutCubic)
    public static let `default` = WindowAnimationOptions()

    /// Fast animation (0.15s)
    public static let fast = WindowAnimationOptions(duration: 0.15)

    /// Slow animation (0.4s)
    public static let slow = WindowAnimationOptions(duration: 0.4)

    /// Slide-in animation (0.3s, easeOutCubic — decelerates into position)
    public static let slideIn = WindowAnimationOptions(duration: 0.3, easing: .easeOutCubic)

    /// Slide-out animation (0.2s, easeInCubic — accelerates away)
    public static let slideOut = WindowAnimationOptions(duration: 0.2, easing: .easeInCubic)

    /// Staggered animation with 50ms delay between windows
    public static let staggered = WindowAnimationOptions(staggerDelay: 0.05)
}

// MARK: - Easing Functions

/// Easing functions for animations
public enum AnimationEasing: String, CaseIterable, Sendable, Identifiable {
    case linear
    case easeIn
    case easeOut
    case easeInOut
    case easeInQuad
    case easeOutQuad
    case easeInOutQuad
    case easeInCubic
    case easeOutCubic
    case easeInOutCubic
    case easeInCirc
    case easeOutCirc
    case easeInOutCirc

    public var id: String { rawValue }

    /// Human-readable display name
    public var displayName: String {
        switch self {
        case .linear: return "Linear"
        case .easeIn: return "Ease In"
        case .easeOut: return "Ease Out"
        case .easeInOut: return "Ease In-Out"
        case .easeInQuad: return "Ease In (Quad)"
        case .easeOutQuad: return "Ease Out (Quad)"
        case .easeInOutQuad: return "Ease In-Out (Quad)"
        case .easeInCubic: return "Ease In (Cubic)"
        case .easeOutCubic: return "Ease Out (Cubic)"
        case .easeInOutCubic: return "Ease In-Out (Cubic)"
        case .easeInCirc: return "Ease In (Circ)"
        case .easeOutCirc: return "Ease Out (Circ)"
        case .easeInOutCirc: return "Ease In-Out (Circ)"
        }
    }

    /// Apply easing to normalized time (0.0 - 1.0)
    /// - Parameter t: Normalized time from 0 to 1
    /// - Returns: Eased value from 0 to 1
    public func apply(_ t: Double) -> Double {
        switch self {
        case .linear:
            return t
        case .easeIn:
            return t * t
        case .easeOut:
            return 1 - (1 - t) * (1 - t)
        case .easeInOut:
            return t < 0.5 ? 2 * t * t : 1 - pow(-2 * t + 2, 2) / 2
        case .easeInQuad:
            return t * t
        case .easeOutQuad:
            return 1 - (1 - t) * (1 - t)
        case .easeInOutQuad:
            return t < 0.5 ? 2 * t * t : 1 - pow(-2 * t + 2, 2) / 2
        case .easeInCubic:
            return t * t * t
        case .easeOutCubic:
            return 1 - pow(1 - t, 3)
        case .easeInOutCubic:
            return t < 0.5 ? 4 * t * t * t : 1 - pow(-2 * t + 2, 3) / 2
        case .easeInCirc:
            return 1 - sqrt(1 - pow(t, 2))
        case .easeOutCirc:
            return sqrt(1 - pow(t - 1, 2))
        case .easeInOutCirc:
            return t < 0.5
                ? (1 - sqrt(1 - pow(2 * t, 2))) / 2
                : (sqrt(1 - pow(-2 * t + 2, 2)) + 1) / 2
        }
    }

    /// Convert to CAMediaTimingFunction for Core Animation
    public var caTimingFunction: CAMediaTimingFunction {
        switch self {
        case .linear:
            return CAMediaTimingFunction(name: .linear)
        case .easeIn, .easeInQuad, .easeInCubic, .easeInCirc:
            return CAMediaTimingFunction(name: .easeIn)
        case .easeOut, .easeOutQuad, .easeOutCubic, .easeOutCirc:
            return CAMediaTimingFunction(name: .easeOut)
        case .easeInOut, .easeInOutQuad, .easeInOutCubic, .easeInOutCirc:
            return CAMediaTimingFunction(name: .easeInEaseOut)
        }
    }
}

// MARK: - Animation Result

/// Result of a window animation operation
public struct WindowAnimationResult: Sendable {
    /// The window identity key (frame + title based)
    public let windowIdentityKey: String

    /// Whether the animation completed successfully
    public let success: Bool

    /// The final frame after animation
    public let finalFrame: CGRect

    /// Actual duration of the animation
    public let duration: TimeInterval

    /// Whether the animation was interrupted (e.g., by another animation)
    public let wasInterrupted: Bool

    public init(
        windowIdentityKey: String,
        success: Bool,
        finalFrame: CGRect,
        duration: TimeInterval,
        wasInterrupted: Bool = false
    ) {
        self.windowIdentityKey = windowIdentityKey
        self.success = success
        self.finalFrame = finalFrame
        self.duration = duration
        self.wasInterrupted = wasInterrupted
    }
}

// MARK: - Animation Error

/// Errors that can occur during window animation
public enum WindowAnimationError: Error, Sendable {
    case windowNotFound
    case animationCancelled
    case screenshotCaptureFailed
    case axOperationFailed
    case invalidFrame
}
