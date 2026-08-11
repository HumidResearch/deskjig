//  LayoutPreset.swift
//  DeskJigShared

import Foundation

// MARK: - Layout Presets

/// Predefined layout presets for window arrangement
public enum LayoutPreset: String, CaseIterable, Identifiable, Codable, Sendable {
    case fiftyFifty = "50/50 Split"
    case seventyThirty = "70/30 Split"
    case thirtySeventy = "30/70 Split"
    case threeColumn = "Three Column"
    case quadrant = "Quadrant"
    case fullscreen = "Fullscreen"
    case leftFullRightStacked = "Left + Right Stack"
    case rightFullLeftStacked = "Right Stack + Left"

    public var id: String { rawValue }

    /// SF Symbol name for the layout
    public var icon: String {
        switch self {
        case .fiftyFifty: return "rectangle.split.2x1"
        case .seventyThirty: return "rectangle.leadinghalf.filled"
        case .thirtySeventy: return "rectangle.trailinghalf.filled"
        case .threeColumn: return "rectangle.split.3x1"
        case .quadrant: return "rectangle.split.2x2"
        case .fullscreen: return "rectangle.fill"
        case .leftFullRightStacked: return "rectangle.leadinghalf.inset.filled.arrow.leading"
        case .rightFullLeftStacked: return "rectangle.trailinghalf.inset.filled.arrow.trailing"
        }
    }

    /// Description of the layout
    public var description: String {
        switch self {
        case .fiftyFifty: return "Two equal windows side by side"
        case .seventyThirty: return "Large window on left, smaller on right"
        case .thirtySeventy: return "Smaller window on left, larger on right"
        case .threeColumn: return "Three equal columns"
        case .quadrant: return "Four windows in corners"
        case .fullscreen: return "Single fullscreen window"
        case .leftFullRightStacked: return "Full left, stacked right"
        case .rightFullLeftStacked: return "Stacked left, full right"
        }
    }

    /// Number of windows this layout supports
    public var windowCount: Int {
        switch self {
        case .fiftyFifty: return 2
        case .seventyThirty: return 2
        case .thirtySeventy: return 2
        case .threeColumn: return 3
        case .quadrant: return 4
        case .fullscreen: return 1
        case .leftFullRightStacked: return 3
        case .rightFullLeftStacked: return 3
        }
    }

    /// Get the relative frame for a window at a given index in this layout
    public func relativeFrame(for index: Int) -> RelativeWindowFrame {
        switch self {
        case .fiftyFifty:
            return index == 0
                ? RelativeWindowFrame(xPercent: 0.0, yPercent: 0.0, widthPercent: 0.5, heightPercent: 1.0)
                : RelativeWindowFrame(xPercent: 0.5, yPercent: 0.0, widthPercent: 0.5, heightPercent: 1.0)

        case .seventyThirty:
            return index == 0
                ? RelativeWindowFrame(xPercent: 0.0, yPercent: 0.0, widthPercent: 0.7, heightPercent: 1.0)
                : RelativeWindowFrame(xPercent: 0.7, yPercent: 0.0, widthPercent: 0.3, heightPercent: 1.0)

        case .thirtySeventy:
            return index == 0
                ? RelativeWindowFrame(xPercent: 0.0, yPercent: 0.0, widthPercent: 0.3, heightPercent: 1.0)
                : RelativeWindowFrame(xPercent: 0.3, yPercent: 0.0, widthPercent: 0.7, heightPercent: 1.0)

        case .threeColumn:
            switch index {
            case 0: return RelativeWindowFrame(xPercent: 0.0, yPercent: 0.0, widthPercent: 0.3333, heightPercent: 1.0)
            case 1: return RelativeWindowFrame(xPercent: 0.3333, yPercent: 0.0, widthPercent: 0.3334, heightPercent: 1.0)
            default: return RelativeWindowFrame(xPercent: 0.6667, yPercent: 0.0, widthPercent: 0.3333, heightPercent: 1.0)
            }

        case .quadrant:
            switch index {
            case 0: return RelativeWindowFrame(xPercent: 0.0, yPercent: 0.0, widthPercent: 0.5, heightPercent: 0.5)
            case 1: return RelativeWindowFrame(xPercent: 0.5, yPercent: 0.0, widthPercent: 0.5, heightPercent: 0.5)
            case 2: return RelativeWindowFrame(xPercent: 0.0, yPercent: 0.5, widthPercent: 0.5, heightPercent: 0.5)
            default: return RelativeWindowFrame(xPercent: 0.5, yPercent: 0.5, widthPercent: 0.5, heightPercent: 0.5)
            }

        case .fullscreen:
            return RelativeWindowFrame(xPercent: 0.0, yPercent: 0.0, widthPercent: 1.0, heightPercent: 1.0)

        case .leftFullRightStacked:
            switch index {
            case 0: return RelativeWindowFrame(xPercent: 0.0, yPercent: 0.0, widthPercent: 0.5, heightPercent: 1.0)      // Left full
            case 1: return RelativeWindowFrame(xPercent: 0.5, yPercent: 0.0, widthPercent: 0.5, heightPercent: 0.5)     // Right top
            default: return RelativeWindowFrame(xPercent: 0.5, yPercent: 0.5, widthPercent: 0.5, heightPercent: 0.5)    // Right bottom
            }

        case .rightFullLeftStacked:
            switch index {
            case 0: return RelativeWindowFrame(xPercent: 0.0, yPercent: 0.0, widthPercent: 0.5, heightPercent: 0.5)     // Left top
            case 1: return RelativeWindowFrame(xPercent: 0.0, yPercent: 0.5, widthPercent: 0.5, heightPercent: 0.5)     // Left bottom
            default: return RelativeWindowFrame(xPercent: 0.5, yPercent: 0.0, widthPercent: 0.5, heightPercent: 1.0)    // Right full
            }
        }
    }
}
