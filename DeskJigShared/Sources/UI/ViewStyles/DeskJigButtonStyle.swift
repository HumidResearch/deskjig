//
//  DeskJigButtonStyle.swift
//  DeskJig
//
//  Created by Paulo Fierro on 30/9/25.
//

import SwiftUI

@MainActor public struct DeskJigButtonStyle: ButtonStyle {
    
    private let font: Font.BrandFont
    private let foregroundStyle: Color
    private let backgroundStyle: (_ isHovering: Bool) -> Color
    private let brightnessOnHover: CGFloat
    
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.controlSize) private var size
    
    @State private var isHovering: Bool = false
    
    private var maxWidth: CGFloat? {
        switch size {
        case .mini, .small, .regular: nil
        default: .infinity
        }
    }
    private var horizontalPadding: CGFloat {
        switch size {
        case .mini: 10
        case .small: 16
        case .regular: 20
        default: 0
        }
    }
    private var height: CGFloat {
        switch size {
        case .mini: 28
        case .small: 36
        case .regular: 40
        default: 48
        }
    }
    
    public init(
        font: Font.BrandFont,
        foregroundStyle: Color,
        backgroundStyle: @escaping (_ isHovering: Bool) -> Color,
        brightnessOnHover: CGFloat
    ) {
        self.foregroundStyle = foregroundStyle
        self.backgroundStyle = backgroundStyle
        self.font = font
        self.brightnessOnHover = brightnessOnHover
    }
    
    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(brand: font)
            .foregroundStyle(foregroundStyle.opacity(isHovering ? 1 : 0.92))
            .frame(height: height)
            .padding(.horizontal, horizontalPadding)
            .frame(maxWidth: maxWidth)
            .background {
                Capsule()
                    .fill(backgroundStyle(isHovering))
                    .brightness(isHovering ? brightnessOnHover : 0)
                    .shadow(color: .black.opacity(0.2), radius: 12, y: 3)
            }
            .opacity(isEnabled ? 1 : 0.5)
            .scaleEffect(configuration.isPressed ? 1.04 : 1)
            .onHover { isHovering = $0 }
            .animation(.smooth(duration: 0.2), value: isHovering)
            .animation(.smooth(duration: 0.2), value: isEnabled)
            .animation(.smooth(duration: 0.2), value: configuration.isPressed)
    }
    
}

@MainActor public extension ButtonStyle where Self == DeskJigButtonStyle {
    static var deskJig: DeskJigButtonStyle { .deskJig() }
    
    static func deskJig(
        foregroundStyle: Color = .white,
        backgroundStyle: Color = Color.black.opacity(0.96),
        brightnessOnHover: CGFloat = -0.08
    ) -> DeskJigButtonStyle {
        DeskJigButtonStyle(
            font: .body2,
            foregroundStyle: foregroundStyle,
            backgroundStyle: { isHovering in
                backgroundStyle.opacity(isHovering ? 1 : 0.9)
            },
            brightnessOnHover: brightnessOnHover
        )
    }
    
    static func deskJig(
        foregroundStyle: Color = .white,
        backgroundStyle: @escaping (_ isHovering: Bool) -> Color,
        brightnessOnHover: CGFloat = -0.08
    ) -> DeskJigButtonStyle {
        DeskJigButtonStyle(
            font: .body2,
            foregroundStyle: foregroundStyle,
            backgroundStyle: backgroundStyle,
            brightnessOnHover: brightnessOnHover
        )
    }

    static func deskJig(
        font: Font.BrandFont,
        foregroundStyle: Color = .white,
        backgroundStyle: Color = Color.black.opacity(0.96),
        brightnessOnHover: CGFloat = -0.08
    ) -> DeskJigButtonStyle {
        DeskJigButtonStyle(
            font: font,
            foregroundStyle: foregroundStyle,
            backgroundStyle: { isHovering in
                backgroundStyle.opacity(isHovering ? 1 : 0.9)
            },
            brightnessOnHover: brightnessOnHover
        )
    }

    static func deskJig(
        font: Font.BrandFont,
        foregroundStyle: Color = .white,
        backgroundStyle: @escaping (_ isHovering: Bool) -> Color,
        brightnessOnHover: CGFloat = -0.08
    ) -> DeskJigButtonStyle {
        DeskJigButtonStyle(
            font: font,
            foregroundStyle: foregroundStyle,
            backgroundStyle: backgroundStyle,
            brightnessOnHover: brightnessOnHover
        )
    }
    
    static func deskJigSimple(
        colorScheme: ColorScheme = .dark
    ) -> DeskJigButtonStyle {
        DeskJigButtonStyle(
            font: .body2,
            foregroundStyle: colorScheme == .dark ? .white : .black,
            backgroundStyle: { isHovering in
                (colorScheme == .dark ? Color.black : Color.white)
                    .opacity(isHovering ? 0.08 : 0)
            },
            brightnessOnHover: 0
        )
    }

    static func deskJigSimple(
        font: Font.BrandFont,
        colorScheme: ColorScheme = .dark
    ) -> DeskJigButtonStyle {
        DeskJigButtonStyle(
            font: font,
            foregroundStyle: colorScheme == .dark ? .white : .black,
            backgroundStyle: { isHovering in
                (colorScheme == .dark ? Color.black : Color.white)
                    .opacity(isHovering ? 0.08 : 0)
            },
            brightnessOnHover: 0
        )
    }
}

#Preview {
    VStack {
        Button(
            action: {},
            label: {
                Text("I'm a button")
                    .frame(maxWidth: 200)
            }
        )
        .buttonStyle(.deskJig)
        
        Button(
            action: {},
            label: {
                Text("I'm disabled")
                    .frame(maxWidth: 200)
            }
        )
        .buttonStyle(.deskJig)
        .disabled(true)
    }
    .padding()
}
