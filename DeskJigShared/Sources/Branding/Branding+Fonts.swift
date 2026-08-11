//
//  Branding+Fonts.swift
//  DeskJigShared
//
//  Created by Jake Sax on 9/10/25.
//

import SwiftUI

public extension View {
    /// Applies brand font styling to a view, including sizing, line spacing, and tracking.
    /// Prefer this over other methods to style text with a font, as this encapsulates the
    /// additional style information.
    /// - Parameters:
    ///   - font: The brand font to apply
    func font(
        brand font: Font.BrandFont
    ) -> some View {
        modifier(BrandFontModifier(brandFont: font))
    }
}

private struct BrandFontModifier: ViewModifier {
    let brandFont: Font.BrandFont

    @AppStorage("appearance.fontFamily") private var fontFamily: AppFontFamily = .system
    @AppStorage("appearance.baseFontSize") private var baseFontSize: Double = 12.0

    func body(content: Content) -> some View {
        let resolved = brandFont.resolvedFont(family: fontFamily, baseSize: CGFloat(baseFontSize))
        return content
            .font(resolved.font)
            .lineSpacing(resolved.lineSpacing)
            .tracking(resolved.tracking)
    }
}

public extension Font.BrandFont {
    /// Bold, size 32
    static let h1: Font.BrandFont = Font.brandHeading(size: 32)
    /// Bold, size 27
    static let h2: Font.BrandFont = Font.brandHeading(size: 27)
    /// Bold, size 20
    static let h3: Font.BrandFont = Font.brandHeading(size: 20)
    /// Bold, size 16
    static let h4: Font.BrandFont = Font.brandHeading(size: 16)
    /// Bold, size 14
    static let h5: Font.BrandFont = Font.brandHeading(size: 14)
    /// Bold, size 12
    static let h6: Font.BrandFont = Font.brandHeading(size: 12)
    /// Regular, size 20
    static let body1: Font.BrandFont = Font.brandBody(size: 20)
    /// Regular, size 16
    static let body2: Font.BrandFont = Font.brandBody(size: 16)
    /// Regular, size 14
    static let body3: Font.BrandFont = Font.brandBody(size: 14)
    /// Regular, size 12
    static let body4: Font.BrandFont = Font.brandBody(size: 12)
    /// Narrow Light, size 20
    static let label1: Font.BrandFont = Font.brandLabel(size: 20)
    /// Narrow Light, size 16
    static let label2: Font.BrandFont = Font.brandLabel(size: 16)
    /// Regular, size 14
    static let label3: Font.BrandFont = Font.brandBody(size: 14, lineHeight: 100)
    /// Regular, size 12
    static let label4: Font.BrandFont = Font.brandBody(size: 12, lineHeight: 100, tracking: 1)

    // MARK: - Monospace Styles

    /// Monospace Bold, size 32
    @MainActor static let monoH1: Font.BrandFont = Font.brandMonoHeading(size: 32)
    /// Monospace Bold, size 27
    @MainActor static let monoH2: Font.BrandFont = Font.brandMonoHeading(size: 27)
    /// Monospace Bold, size 20
    @MainActor static let monoH3: Font.BrandFont = Font.brandMonoHeading(size: 20)
    /// Monospace Bold, size 16
    @MainActor static let monoH4: Font.BrandFont = Font.brandMonoHeading(size: 16)
    /// Monospace Bold, size 14
    @MainActor static let monoH5: Font.BrandFont = Font.brandMonoHeading(size: 14)
    /// Monospace Bold, size 12
    @MainActor static let monoH6: Font.BrandFont = Font.brandMonoHeading(size: 12)
    /// Monospace Regular, size 16
    @MainActor static let monoBody2: Font.BrandFont = Font.brandMonoBody(size: 16)
    /// Monospace Regular, size 14
    @MainActor static let monoBody3: Font.BrandFont = Font.brandMonoBody(size: 14)
    /// Monospace Regular, size 12
    @MainActor static let monoBody4: Font.BrandFont = Font.brandMonoBody(size: 12)
    /// Monospace Medium, size 16
    @MainActor static let monoLabel2: Font.BrandFont = Font.brandMonoLabel(size: 16)
    /// Monospace Regular, size 14 with 100% line height
    @MainActor static let monoLabel3: Font.BrandFont = Font.brandMonoBody(size: 14, lineHeight: 100)
    /// Monospace Medium, size 11 with letter spacing for section headers
    @MainActor static let monoLabel4: Font.BrandFont = Font.brandMonoLabel(size: 11, tracking: 5)
}

public extension Font {
    /// Encapsulates font properties and styling attributes in a unified structure
    @MainActor struct BrandFont: Sendable {
        enum Kind: Sendable {
            case heading
            case body
            case label
            case monoHeading
            case monoBody
            case monoLabel
        }

        struct Resolved: Sendable {
            let font: Font
            let lineSpacing: Double
            let tracking: Double
        }

        let kind: Kind
        /// Font size in points
        let size: Double
        /// Line height as percentage of font size (100% = default)
        let lineHeightPercentage: Double
        /// Letter spacing as percentage of font size (0% = default)
        let trackingPercentage: Double

        fileprivate init(
            kind: Kind,
            size: Double,
            lineHeightPercentage: Double = 100,
            trackingPercentage: Double = 0
        ) {
            self.kind = kind
            self.size = size
            self.lineHeightPercentage = lineHeightPercentage
            self.trackingPercentage = trackingPercentage
        }

        func resolvedFont(family: AppFontFamily, baseSize: CGFloat) -> Resolved {
            let scale = Double(baseSize / 12.0)
            let actualSize = size * scale
            let lineSpacing = ((lineHeightPercentage - 100) / 100) * actualSize
            let tracking = (trackingPercentage / 100) * actualSize

            let platformFont: NSFont
            switch family {
            case .system:
                platformFont = Self.systemFont(for: kind, size: CGFloat(actualSize))
            }

            return Resolved(
                font: Font(platformFont),
                lineSpacing: lineSpacing,
                tracking: tracking
            )
        }

        private static func systemFont(for kind: Kind, size: CGFloat) -> NSFont {
            switch kind {
            case .heading:
                return sfProTextFont(weight: .medium, size: size)
            case .body:
                return sfProTextFont(weight: .regular, size: size)
            case .label:
                return sfCompactTextFont(weight: .regular, size: size)
            case .monoHeading:
                return NSFont.monospacedSystemFont(ofSize: size, weight: .medium)
            case .monoBody:
                return NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
            case .monoLabel:
                return NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
            }
        }

        private enum SFWeight {
            case regular
            case medium
            case semibold
            case bold
        }

        private static func sfProTextFont(weight: SFWeight, size: CGFloat) -> NSFont {
            let name: String
            switch weight {
            case .regular:
                name = "SF Pro Text Regular"
            case .medium:
                name = "SF Pro Text Medium"
            case .semibold:
                name = "SF Pro Text Semibold"
            case .bold:
                name = "SF Pro Text Bold"
            }
            return NSFont(name: name, size: size) ?? NSFont.systemFont(ofSize: size, weight: .regular)
        }

        private static func sfCompactTextFont(weight: SFWeight, size: CGFloat) -> NSFont {
            let name: String
            switch weight {
            case .regular:
                name = "SF Compact Text Regular"
            case .medium:
                name = "SF Compact Text Medium"
            case .semibold:
                name = "SF Compact Text Semibold"
            case .bold:
                name = "SF Compact Text Bold"
            }
            return NSFont(name: name, size: size) ?? NSFont.systemFont(ofSize: size, weight: .regular)
        }
    }
    
    @MainActor static func brandHeading(size: Double) -> Font.BrandFont {
        Font.BrandFont(kind: .heading, size: size, trackingPercentage: 0)
    }
    
    @MainActor static func brandBody(
        size: Double,
        lineHeight: CGFloat = 120,
        tracking: Double = 0
    ) -> Font.BrandFont {
        Font.BrandFont(
            kind: .body,
            size: size,
            lineHeightPercentage: lineHeight,
            trackingPercentage: tracking
        )
    }
    
    @MainActor static func brandLabel(size: Double) -> Font.BrandFont {
        Font.BrandFont(kind: .label, size: size)
    }

    // MARK: - Monospace Helpers

    @MainActor static func brandMonoHeading(size: Double) -> Font.BrandFont {
        Font.BrandFont(kind: .monoHeading, size: size, trackingPercentage: 2)
    }

    @MainActor static func brandMonoBody(
        size: Double,
        lineHeight: CGFloat = 120
    ) -> Font.BrandFont {
        Font.BrandFont(
            kind: .monoBody,
            size: size,
            lineHeightPercentage: lineHeight
        )
    }

    @MainActor static func brandMonoLabel(size: Double, tracking: Double = 0) -> Font.BrandFont {
        Font.BrandFont(
            kind: .monoLabel,
            size: size,
            trackingPercentage: tracking
        )
    }
}

@MainActor public extension Font {
    private static let defaultFamily: AppFontFamily = .system
    private static let defaultBaseSize: CGFloat = 12.0

    static let brandH1: Font = BrandFont.h1.resolvedFont(family: defaultFamily, baseSize: defaultBaseSize).font
    static let brandH2: Font = BrandFont.h2.resolvedFont(family: defaultFamily, baseSize: defaultBaseSize).font
    static let brandH3: Font = BrandFont.h3.resolvedFont(family: defaultFamily, baseSize: defaultBaseSize).font
    static let brandH4: Font = BrandFont.h4.resolvedFont(family: defaultFamily, baseSize: defaultBaseSize).font
    static let brandH5: Font = BrandFont.h5.resolvedFont(family: defaultFamily, baseSize: defaultBaseSize).font
    static let brandH6: Font = BrandFont.h6.resolvedFont(family: defaultFamily, baseSize: defaultBaseSize).font
    static let brandBody1: Font = BrandFont.body1.resolvedFont(family: defaultFamily, baseSize: defaultBaseSize).font
    static let brandBody2: Font = BrandFont.body2.resolvedFont(family: defaultFamily, baseSize: defaultBaseSize).font
    static let brandBody3: Font = BrandFont.body3.resolvedFont(family: defaultFamily, baseSize: defaultBaseSize).font
    static let brandBody4: Font = BrandFont.body4.resolvedFont(family: defaultFamily, baseSize: defaultBaseSize).font
    static let brandLabel1: Font = BrandFont.label1.resolvedFont(family: defaultFamily, baseSize: defaultBaseSize).font
    static let brandLabel2: Font = BrandFont.label2.resolvedFont(family: defaultFamily, baseSize: defaultBaseSize).font
    static let brandLabel3: Font = BrandFont.label3.resolvedFont(family: defaultFamily, baseSize: defaultBaseSize).font
    static let brandLabel4: Font = BrandFont.label4.resolvedFont(family: defaultFamily, baseSize: defaultBaseSize).font

    // Monospace static fonts
    static let brandMonoH1: Font = BrandFont.monoH1.resolvedFont(family: defaultFamily, baseSize: defaultBaseSize).font
    static let brandMonoH2: Font = BrandFont.monoH2.resolvedFont(family: defaultFamily, baseSize: defaultBaseSize).font
    static let brandMonoH3: Font = BrandFont.monoH3.resolvedFont(family: defaultFamily, baseSize: defaultBaseSize).font
    static let brandMonoH4: Font = BrandFont.monoH4.resolvedFont(family: defaultFamily, baseSize: defaultBaseSize).font
    static let brandMonoH5: Font = BrandFont.monoH5.resolvedFont(family: defaultFamily, baseSize: defaultBaseSize).font
    static let brandMonoH6: Font = BrandFont.monoH6.resolvedFont(family: defaultFamily, baseSize: defaultBaseSize).font
    static let brandMonoBody2: Font = BrandFont.monoBody2.resolvedFont(family: defaultFamily, baseSize: defaultBaseSize).font
    static let brandMonoBody3: Font = BrandFont.monoBody3.resolvedFont(family: defaultFamily, baseSize: defaultBaseSize).font
    static let brandMonoBody4: Font = BrandFont.monoBody4.resolvedFont(family: defaultFamily, baseSize: defaultBaseSize).font
    static let brandMonoLabel2: Font = BrandFont.monoLabel2.resolvedFont(family: defaultFamily, baseSize: defaultBaseSize).font
    static let brandMonoLabel3: Font = BrandFont.monoLabel3.resolvedFont(family: defaultFamily, baseSize: defaultBaseSize).font
    static let brandMonoLabel4: Font = BrandFont.monoLabel4.resolvedFont(family: defaultFamily, baseSize: defaultBaseSize).font
}

extension Font.Weight {
    /// The associated value of the weight variation axis for a variable font.
    var variationValue: CGFloat {
        switch self {
        case .ultraLight: 100
        case .thin: 200
        case .light: 300
        case .regular: 400
        case .medium: 500
        case .semibold: 600
        case .bold: 700
        case .heavy, .black: 800
        default: 400
        }
    }
}
