//
//  VariableFont.swift
//  DeskJigShared
//
//  Created by Jake Sax on 9/10/25.
//

import SwiftUI

#if canImport(UIKit)
public typealias PlatformFont = UIFont
public typealias PlatformFontDescriptor = UIFontDescriptor
#else
public typealias PlatformFont = NSFont
public typealias PlatformFontDescriptor = NSFontDescriptor
#endif

/// A type that represents a variable font with customizable axes for style, weight, and slant.
///
/// Variable fonts allow dynamic adjustment of font characteristics along defined axes
/// such as weight (light to bold), slant (roman to italic), or other stylistic dimensions.
/// This struct provides a convenient way to create and manipulate variable fonts.
///
/// Example:
/// ```
/// let fontAxes = myUIFont.availableVariationAxes()
/// let weightAxis = fontAxes.first(where: { $0.axis == .weight })
/// let variableFont = VariableFont(uiFont: myUIFont, weightAxis: weightAxis)
/// ```
struct VariableFont {
    
    // MARK: Properties
    
    /// The SwiftUI font representation, ready for use in SwiftUI views.
    let font: Font
    
    /// The Platform font representation, ready for use in UIKit/AppKit components.
    let platformFont: PlatformFont
    
    /// The style variation axis of the font, if available.
    ///
    /// Style axes typically control design aspects like serif/sans-serif variants
    /// or other stylistic alternates.
    let styleAxis: Axis?
    
    /// The weight variation axis of the font, if available.
    ///
    /// The weight axis typically controls font boldness from light to heavy.
    let weightAxis: Axis?
    
    /// The slant variation axis of the font, if available.
    ///
    /// The slant axis typically controls the italic angle of the font.
    let slantAxis: Axis?
    
    // MARK: Initialization
    
    /// Creates a variable font with the specified axes and stylistic alternative.
    ///
    /// - Parameters:
    ///   - platformFont: The base PlatformFont to create variations from.
    ///   - styleAxis: The style axis to apply, if any.
    ///   - weightAxis: The weight axis to apply, if any.
    ///   - slantAxis: The slant axis to apply, if any.
    ///
    /// - Returns: A new `VariableFont` instance with the specified variations applied.
    init?(
        platformFont: PlatformFont,
        styleAxis: Axis? = nil,
        weightAxis: Axis? = nil,
        slantAxis: Axis? = nil
    ) {
        guard let variablePlatformFont = platformFont.varying(
            axes: styleAxis?.input, weightAxis?.input, slantAxis?.input
        ) else {
            return nil
        }
        self.styleAxis = styleAxis
        self.weightAxis = weightAxis
        self.slantAxis = slantAxis
        self.platformFont = variablePlatformFont
        self.font = Font(variablePlatformFont)
    }
    
    // MARK: Data Structures
    
    /// Represents the type of variation axis in a variable font.
    ///
    /// Variable fonts can have multiple types of axes that control different
    /// aspects of the font's appearance.
    enum AxisType: Sendable {
        /// Controls the font weight from light to bold.
        case weight
        
        /// Controls the font slant or italic angle.
        case slant
        
        /// Controls other stylistic aspects of the font.
        case style
    }
    
    /// A variation axis of a variable font.
    ///
    /// This represents a single dimension along which a variable font can be adjusted,
    /// such as weight, slant, or other stylistic features. Each axis has a defined range
    /// and a current value within that range.
    struct Axis: Sendable {
        /// The unique identifier for this axis in the font.
        let id: AxisIdentifier
        
        /// The human-readable name of the axis.
        let name: String
        
        /// The valid range of values for this axis.
        let axisRange: ClosedRange<Double>
        
        /// The type of this axis (weight, slant, or style).
        let axis: VariableFont.AxisType
        
        /// The current value of this axis.
        var axisValue: Double
        
        /// Converts this axis to an input format suitable for the font variation system.
        var input: Input {
            Input(id: id, value: axisValue)
        }
        
        /// A structure representing the minimum required information to define a font variation axis input.
        struct Input {
            /// The identifier for the axis.
            let id: AxisIdentifier
            
            /// The value to set for this axis.
            let value: Double
        }
    }
    
    /// The number that identifies a variation axis for a font.
    ///
    /// This is an inconsistent number that may be different for different fonts
    /// but will remain constant for a given font.
    typealias AxisIdentifier = NSNumber
}

extension PlatformFont {
    
    /// Creates a variable font with the specified axes.
    ///
    /// - Parameters:
    ///   - font: The name of the font.
    ///   - size: The point size of the font.
    ///   - variationAxes: The variation axes to apply to the font.
    ///
    /// - Returns: A UIFont with the specified variations applied.
    static func makeVariableFont(
        _ font: String,
        size: CGFloat,
        withAxes variationAxes: [VariableFont.Axis.Input?]
    ) -> Self? {
        let attributes: [NSNumber: Any] = variationAxes
            .compactMap { $0 }
            .reduce(into: [NSNumber: Any]()) { result, axis in
                // print("Axis ID: \(axis.id), Axis value: \(axis.value)")
                result[axis.id] = axis.value
            }
        
        let fontDescriptor = PlatformFontDescriptor(
            fontAttributes: [
                // Font Name
                PlatformFontDescriptor.AttributeName.name : font,
                // Font Attribute
                kCTFontVariationAttribute as PlatformFontDescriptor.AttributeName : attributes
            ]
        )
        return Self(descriptor: fontDescriptor, size: size)
    }
    
    /// Creates a new UIFont by varying a single axis to a specified value.
    ///
    /// - Parameters:
    ///   - axisAttributeID: The identifier of the axis to modify.
    ///   - value: The value to set for the specified axis.
    ///
    /// - Returns: A new UIFont with the specified axis variation applied.
    func varying(
        axisIdentifiedBy axisAttributeID: NSNumber,
        to value: CGFloat
    ) -> Self? {
        Self.makeVariableFont(
            self.fontName,
            size: self.pointSize,
            withAxes: [.init(id: axisAttributeID, value: value)]
        )
    }
    
    /// Creates a new UIFont by varying multiple axes.
    ///
    /// - Parameter axes: The axis inputs to apply. Pass nil for any axes you don't want to modify.
    ///
    /// - Returns: A new UIFont with the specified axis variations applied.
    func varying(axes: VariableFont.Axis.Input?...) -> Self? {
        Self.makeVariableFont(self.fontName, size: self.pointSize, withAxes: axes)
    }
    
    /// Returns an array of available variation axes for the font.
    ///
    /// This method inspects the font's descriptor to discover what variable font axes
    /// are available and their valid ranges.
    ///
    /// - Returns: An array of axes representing the font's variable parameters.
    func availableVariationAxes() -> [VariableFont.Axis] {
        let ctFont = self as CTFont
        guard let variationAxesRef = CTFontCopyVariationAxes(ctFont) else {
            return []
        }
        
        let variationAxes = variationAxesRef as NSArray as? [[String: Any]] ?? []
        
        return variationAxes.compactMap { axisDict in
            guard
                let id = axisDict["NSCTVariationAxisIdentifier"] as? NSNumber,
                let name = axisDict["NSCTVariationAxisName"] as? String,
                let minValue = axisDict["NSCTVariationAxisMinimumValue"] as? Double,
                let maxValue = axisDict["NSCTVariationAxisMaximumValue"] as? Double,
                let defaultValue = axisDict["NSCTVariationAxisDefaultValue"] as? Double
            else {
                return nil
            }
            
            let axisType: VariableFont.AxisType
            switch name.lowercased() {
            case "weight": axisType = .weight
            case "italic", "slant": axisType = .slant
            default: axisType = .style
            }
            
            return VariableFont.Axis(
                id: id,
                name: name,
                axisRange: minValue...maxValue,
                axis: axisType,
                axisValue: defaultValue
            )
        }
    }
    
}
