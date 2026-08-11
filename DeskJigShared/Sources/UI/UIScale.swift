//
//  UIScale.swift
//  DeskJigShared
//
//  Created by Jake Sax on 11/10/25.
//

import CoreGraphics

/// The scale to be applied to UI elements, currently only applied
/// to ``ActionPanelContent``.
public enum UIScale: String, Identifiable, Codable, Hashable, Sendable, CaseIterable, CustomStringConvertible {
    case tiny, small, regular, large, extraLarge
    
    public var id: Self { self }
    
    public var description: String {
        switch self {
        case .extraLarge: "Extra Large"
        default: rawValue.capitalized
        }
    }
    
    /// The associated scale factor, a value between 0.76-1.24.
    public var scale: CGFloat {
        switch self {
        case .tiny: 0.76
        case .small: 0.88
        case .regular: 1.0
        case .large: 1.12
        case .extraLarge: 1.24
        }
    }
    
    /// Scales the provided value by the associated scale factor.
    public func scaling(_ value: CGFloat) -> CGFloat {
        value * scale
    }
}
