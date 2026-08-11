//
//  Branding+Colors.swift
//  DeskJigShared
//
//  Created by Claude Code on 02/02/26.
//

import SwiftUI
#if os(macOS)
import AppKit
#endif

/// Design system color tokens for DeskJig UI with light/dark variants.
/// Use these tokens instead of inline color values for consistency.
public enum DesignTokens {
    private enum Palette {
        static func rgb(_ r: Int, _ g: Int, _ b: Int, _ alpha: Double = 1.0) -> Color {
            Color(
                red: Double(r) / 255.0,
                green: Double(g) / 255.0,
                blue: Double(b) / 255.0,
                opacity: alpha
            )
        }

        static func color(light: Color, dark: Color) -> Color {
            #if os(macOS)
            let lightColor = NSColor(light)
            let darkColor = NSColor(dark)
            let dynamic = NSColor(name: nil) { appearance in
                let match = appearance.bestMatch(from: [.darkAqua, .aqua])
                return match == .darkAqua ? darkColor : lightColor
            }
            return Color(nsColor: dynamic)
            #else
            return Color { scheme in
                scheme == .dark ? dark : light
            }
            #endif
        }
    }

    /// Text color tokens for consistent typography styling
    public enum Text {
        /// Primary text - highest contrast (white at 90% opacity)
        public static let primary = Palette.color(
            light: Palette.rgb(27, 31, 36),
            dark: Palette.rgb(230, 233, 238)
        )
        /// Secondary text - medium contrast (white at 70% opacity)
        public static let secondary = Palette.color(
            light: Palette.rgb(82, 90, 101),
            dark: Palette.rgb(168, 175, 185)
        )
        /// Tertiary text - lower contrast for hints/disabled (white at 50% opacity)
        public static let tertiary = Palette.color(
            light: Palette.rgb(106, 114, 125),
            dark: Palette.rgb(127, 135, 147)
        )
        /// Muted text - very low contrast (white at 40% opacity)
        public static let muted = Palette.color(
            light: Palette.rgb(138, 145, 155),
            dark: Palette.rgb(106, 113, 124)
        )
        /// Inverse text for colored backgrounds (pure white)
        public static let inverse = Palette.color(
            light: Palette.rgb(247, 248, 250),
            dark: Palette.rgb(15, 17, 20)
        )
    }

    /// Surface/background color tokens for cards and containers
    public enum Surface {
        /// Window background for primary app surfaces
        public static let window = Palette.color(
            light: Palette.rgb(255, 255, 255),
            dark: Palette.rgb(20, 22, 26)
        )
        /// Default card background (white at 5% opacity)
        public static let card = Palette.color(
            light: Palette.rgb(240, 242, 245),
            dark: Palette.rgb(29, 32, 37)
        )
        /// Highlighted/hover card background (white at 18% opacity)
        public static let cardHover = Palette.color(
            light: Palette.rgb(233, 237, 242),
            dark: Palette.rgb(35, 39, 45)
        )
        /// Elevated surface for nested elements (white at 8% opacity)
        public static let elevated = Palette.color(
            light: Palette.rgb(227, 232, 239),
            dark: Palette.rgb(42, 47, 55)
        )
        /// Panel background for modal surfaces
        public static let panel = Palette.color(
            light: Palette.rgb(240, 242, 245),
            dark: Palette.rgb(29, 32, 37)
        )
        /// Input field background
        public static let input = Palette.color(
            light: Palette.rgb(240, 242, 245),
            dark: Palette.rgb(35, 39, 45)
        )
        /// Muted accent surface for subtle emphasis
        public static var accentMuted: Color { Brand.accent.opacity(0.12) }
    }

    /// Glass effect tokens for semi-transparent backgrounds with blur
    public enum Glass {
        /// Ultra thin glass - very subtle (white at 3% opacity)
        public static let ultraThin = Palette.color(
            light: Color.black.opacity(0.02),
            dark: Color.white.opacity(0.03)
        )
        /// Thin glass - subtle transparency (white at 5% opacity)
        public static let thin = Palette.color(
            light: Color.black.opacity(0.03),
            dark: Color.white.opacity(0.05)
        )
        /// Regular glass - moderate transparency (white at 8% opacity)
        public static let regular = Palette.color(
            light: Color.black.opacity(0.05),
            dark: Color.white.opacity(0.08)
        )
        /// Glass tint aligned with Alexandria
        public static let tint = Palette.color(
            light: Color.black.opacity(0.07),
            dark: Color.white.opacity(0.12)
        )
    }

    /// Material tokens for glass-like backgrounds.
    public enum Material {
        public static let ultraThin: SwiftUI.Material = .ultraThinMaterial
        public static let thin: SwiftUI.Material = .thinMaterial
        public static let regular: SwiftUI.Material = .regularMaterial
    }

    /// Border color tokens
    public enum Border {
        /// Subtle border - default state (white at 10% opacity)
        public static let subtle = Palette.color(
            light: Palette.rgb(225, 229, 234),
            dark: Palette.rgb(46, 51, 58)
        )
        /// Regular border - slightly more visible (white at 15% opacity)
        public static let regular = Palette.color(
            light: Palette.rgb(211, 217, 224),
            dark: Palette.rgb(58, 64, 72)
        )
        /// Prominent border - hover/focus state (white at 25% opacity)
        public static let prominent = Palette.color(
            light: Palette.rgb(197, 203, 210),
            dark: Palette.rgb(69, 76, 85)
        )
    }

    /// Brand color tokens
    public enum Brand {
        /// Brand purple color (from asset catalog)
        public static let purple = Color("brandPurple")

        // Primary accent (orange)
        /// Primary accent color (#c07a3d)
        public static let accent = Color(red: 192/255, green: 122/255, blue: 61/255)
        /// Lighter accent for hover states (same muted tone)
        public static let accentLight = Color(red: 192/255, green: 122/255, blue: 61/255)
        /// Darker accent for pressed states (same muted tone)
        public static let accentDark = Color(red: 192/255, green: 122/255, blue: 61/255)
        /// Muted accent background tint (10% opacity)
        public static var accentMuted: Color { accent.opacity(0.1) }

        /// Purple for button backgrounds (70% opacity)
        public static var purpleButton: Color { accent.opacity(0.1) }
        /// Primary button color - uses accent
        public static var primaryButton: Color { accentMuted }
        /// Amber for favorites/stars
        public static let amber = Color(red: 0.96, green: 0.76, blue: 0.28)
        /// Green CTA color for community actions (Discord onboarding/help)
        public static let communityGreen = Color(red: 52/255, green: 168/255, blue: 83/255)
        /// Darker pressed state for community CTA
        public static let communityGreenPressed = Color(red: 44/255, green: 144/255, blue: 70/255)
        /// Dark green for Pro Tools branding
        public static let proToolsDarkGreen = Color(red: 45/255, green: 69/255, blue: 48/255)
    }

    /// Status colors for success/warning/error/info messaging
    public enum Status {
        /// Success/connected state (neutralized)
    public static let success = DesignTokens.Brand.communityGreen
        /// Warning/attention state (neutralized)
        public static let warning = DesignTokens.Text.secondary
        /// Error/destructive state (red)
        public static let error = Color(red: 239/255, green: 68/255, blue: 68/255)
        /// Informational state (neutralized)
        public static let info = DesignTokens.Text.secondary
    }

    /// Spacing tokens for consistent layout
    public enum Spacing {
        // Sidebar dimensions
        public static let sidebarWidth: CGFloat = 220

        // Content padding
        public static let contentPaddingSmall: CGFloat = 16
        public static let contentPaddingRegular: CGFloat = 24
        public static let contentPaddingLarge: CGFloat = 32

        // Item padding
        public static let itemPaddingVertical: CGFloat = 8
        public static let itemPaddingHorizontal: CGFloat = 12

        // Gaps
        public static let gapTiny: CGFloat = 4
        public static let gapSmall: CGFloat = 8
        public static let gapRegular: CGFloat = 12
        public static let gapMedium: CGFloat = 16
        public static let gapLarge: CGFloat = 24
        public static let gapXLarge: CGFloat = 32

        // Section spacing
        public static let sectionHeaderBottom: CGFloat = 8
        public static let sectionGap: CGFloat = 24

        // Card padding
        public static let cardPadding: CGFloat = 16
        public static let cardPaddingSmall: CGFloat = 12

        // Window chrome
        public static let trafficLightPadding: CGFloat = 40
    }

    /// Icon size tokens for SF Symbol sizing
    public enum IconSize {
        public static let tiny: CGFloat = 10
        public static let small: CGFloat = 12
        public static let medium: CGFloat = 14
        public static let large: CGFloat = 16
        public static let xLarge: CGFloat = 20
        public static let xxLarge: CGFloat = 24
        public static let xxxLarge: CGFloat = 32
    }

    /// Form component tokens for inputs, dropdowns, and form fields
    public enum Form {
        /// Corner radius for form inputs
        public static let cornerRadius: CGFloat = CornerRadius.medium
        /// Horizontal padding inside inputs
        public static let inputPaddingHorizontal: CGFloat = 12
        /// Vertical padding inside inputs
        public static let inputPaddingVertical: CGFloat = 10
        /// Standard input height
        public static let inputHeight: CGFloat = 40
        /// Focus ring width for accessibility
        public static let focusRingWidth: CGFloat = 2
    }

    /// Corner radius tokens for consistent rounding
    public enum CornerRadius {
        /// Small - chips, small elements (6pt)
        public static let small: CGFloat = 6
        /// Medium - buttons, inputs (8pt)
        public static let medium: CGFloat = 8
        /// Large - form fields, smaller cards (10pt)
        public static let large: CGFloat = 10
        /// XLarge - cards, panels (12pt)
        public static let xLarge: CGFloat = 12
        /// XXLarge - large modals, sheets (16pt)
        public static let xxLarge: CGFloat = 16
        /// Full - circular/pill shapes
        public static let full: CGFloat = 9999
    }

    /// Opacity tokens for consistent transparency
    public enum Opacity {
        /// Disabled state opacity
        public static let disabled: Double = 0.5
        /// Hover state opacity
        public static let hover: Double = 0.8
        /// Pressed state opacity
        public static let pressed: Double = 0.85
        /// Overlay background opacity
        public static let overlay: Double = 0.6
        /// Subtle backgrounds (muted tints)
        public static let subtle: Double = 0.1
        /// Medium transparency
        public static let medium: Double = 0.3
        /// Strong/prominent transparency
        public static let strong: Double = 0.7
    }

    /// Card-specific design tokens
    public enum Card {
        /// Standard card corner radius
        public static let cornerRadius: CGFloat = CornerRadius.xLarge
        /// Standard card padding
        public static let padding: CGFloat = 16
        /// Compact card padding
        public static let paddingCompact: CGFloat = 12
        /// Header icon size
        public static let headerIconSize: CGFloat = 20
        /// Header icon padding
        public static let headerIconPadding: CGFloat = 8
        /// Header icon corner radius
        public static let headerIconCornerRadius: CGFloat = CornerRadius.large
        /// Section divider padding
        public static let sectionDividerPadding: CGFloat = 12
    }

    /// Shadow style definition
    public struct ShadowStyle {
        public let radius: CGFloat
        public let y: CGFloat
        public let opacity: Double

        public init(radius: CGFloat, y: CGFloat, opacity: Double) {
            self.radius = radius
            self.y = y
            self.opacity = opacity
        }
    }

    /// Shadow tokens for non-glass elevated surfaces
    public enum Shadow {
        /// Small shadow for subtle elevation
        public static let small = ShadowStyle(radius: 10, y: 6, opacity: 0.08)
        /// Medium shadow for cards
        public static let medium = ShadowStyle(radius: 12, y: 8, opacity: 0.12)
        /// Large shadow for modals and overlays
        public static let large = ShadowStyle(radius: 16, y: 10, opacity: 0.16)
    }

    /// Preview tokens for monitor and window preview components
    public enum Preview {
        // Monitor colors
        /// Fill color for monitor background (white at 7% opacity)
        public static let monitorFill = Glass.thin
        /// Primary stroke for monitor borders - used for primary display (white at 55% opacity)
        public static let monitorStrokePrimary = Border.regular
        /// Secondary stroke for monitor borders - used for non-primary displays (white at 25% opacity)
        public static let monitorStrokeSecondary = Border.subtle

        // Window rectangle colors
        /// Fill color for window rectangles (white at 12% opacity)
        public static let windowFill = Glass.regular
        /// Hover fill color for window rectangles (white at 18% opacity)
        public static let windowFillHover = Palette.color(
            light: Color.black.opacity(0.10),
            dark: Color.white.opacity(0.14)
        )
        /// Stroke color for window rectangles (white at 30% opacity)
        public static let windowStroke = Border.regular
        /// Hover stroke color for window rectangles (white at 40% opacity)
        public static let windowStrokeHover = Border.prominent

        // Container
        /// Fill color for preview containers (white at 12% opacity)
        public static let containerFill = Glass.ultraThin
        /// Stroke color for preview containers (white at 15% opacity)
        public static let containerStroke = Border.subtle
    }

    /// Workspace builder tokens for inline creation UI
    public enum WorkspaceBuilder {
        /// Monitor container fill for zone layout
        public static let monitorFill = Palette.color(
            light: Color.black.opacity(0.03),
            dark: Color.white.opacity(0.05)
        )
        /// Monitor container stroke for zone layout
        public static let monitorStroke = Brand.accent.opacity(0.7)
        /// Zone fill for layout editor
        public static let zoneFill = Palette.color(
            light: Color.black.opacity(0.06),
            dark: Color.white.opacity(0.08)
        )
        /// Zone fill on hover
        public static let zoneFillHover = Palette.color(
            light: Color.black.opacity(0.10),
            dark: Color.white.opacity(0.12)
        )
        /// Zone stroke default
        public static let zoneStroke = Palette.color(
            light: Color.black.opacity(0.12),
            dark: Color.white.opacity(0.20)
        )
        /// Zone stroke when selected
        public static let zoneStrokeSelected = Brand.accent.opacity(0.85)
        /// Zone fill when targeted by drag
        public static let zoneTargetFill = Brand.accent.opacity(0.12)
        /// Split control background
        public static let splitControlFill = Palette.color(
            light: Color.black.opacity(0.05),
            dark: Color.white.opacity(0.08)
        )
        /// Split control hover background
        public static let splitControlHover = Palette.color(
            light: Color.black.opacity(0.10),
            dark: Color.white.opacity(0.16)
        )
        /// Split control stroke
        public static let splitControlStroke = Palette.color(
            light: Color.black.opacity(0.12),
            dark: Color.white.opacity(0.20)
        )
        /// App chip background
        public static let appChipFill = Palette.color(
            light: Color.black.opacity(0.05),
            dark: Color.white.opacity(0.08)
        )
        /// App chip hover background
        public static let appChipHover = Palette.color(
            light: Color.black.opacity(0.10),
            dark: Color.white.opacity(0.14)
        )
    }

    /// Layout preset tile tokens
    public enum LayoutPreview {
        public static let tileFill = Palette.color(
            light: Color.black.opacity(0.04),
            dark: Color.white.opacity(0.06)
        )
        public static let tileStroke = Palette.color(
            light: Color.black.opacity(0.10),
            dark: Color.white.opacity(0.15)
        )
        public static let tileSelectedFill = Brand.accent.opacity(0.15)
        public static let tileSelectedStroke = Brand.accent.opacity(0.60)
    }

    /// Drag target tokens
    public enum Drag {
        public static let targetFill = Brand.accent.opacity(0.12)
        public static let targetStroke = Brand.accent.opacity(0.80)
    }

    /// Special app indicator colors for apps with special behaviors (Chrome, IDEs, terminals)
    public enum SpecialApp {
        /// Chrome/browser color - orange accent
        public static var chrome: Color { Brand.accent }
        /// IDE/editor color - use the single muted accent
        public static var ide: Color { Brand.accent }
        /// Terminal color - use the single muted accent
        public static var terminal: Color { Brand.accent }
    }

    /// Animation tokens for pulsating effects and transitions
    public enum Animation {
        /// Duration for pulse animation cycle
        public static let pulseDuration: Double = 0.8
        /// Minimum opacity during pulse animation
        public static let pulseOpacityMin: Double = 0.25
        /// Maximum opacity during pulse animation
        public static let pulseOpacityMax: Double = 0.6
        /// Opacity when element is selected (no pulsing)
        public static let selectedOpacity: Double = 0.9
        /// Default border width for pulsating borders
        public static let pulseBorderWidthDefault: CGFloat = 1.5
        /// Selected border width for pulsating borders
        public static let pulseBorderWidthSelected: CGFloat = 2.5
        /// Size of indicator dots
        public static let indicatorDotSize: CGFloat = 8
    }
}
