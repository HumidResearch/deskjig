//
//  SettingsSlider.swift
//  DeskJig
//
//  Created by Claude Code on 02/02/26.
//

import SwiftUI
import DeskJigShared

/// A slider component with value display.
/// Matches the design system pattern from SettingsPanel.tsx Slider component.
struct SettingsSlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    var step: Double = 1.0
    var unit: String = "s"
    var sliderWidth: CGFloat = 128
    var valueWidth: CGFloat = 50
    var formatDecimals: Int = 1
    var onEditingChanged: ((Bool) -> Void)?

    var body: some View {
        HStack(spacing: 12) {
            Slider(
                value: $value,
                in: range,
                step: step
            ) { editing in
                onEditingChanged?(editing)
            }
            .frame(width: sliderWidth)
            .tint(DesignTokens.Brand.accent)

            Text(formattedValue)
                .font(brand: .body3)
                .foregroundStyle(DesignTokens.Text.secondary)
                .frame(width: valueWidth, alignment: .trailing)
        }
    }

    private var formattedValue: String {
        String(format: "%.\(formatDecimals)f\(unit)", value)
    }
}

/// Extension to define brand accent color (uses DesignTokens for consistency)
extension Color {
    static let brandAccent = DesignTokens.Brand.accent
}

#Preview {
    VStack(spacing: 24) {
        SettingsSlider(value: .constant(5.0), range: 1...10, step: 0.5, unit: "s")

        SettingsSlider(value: .constant(50), range: 0...100, step: 1, unit: "%", formatDecimals: 0)

        HStack {
            Text("Auto-Close Delay")
                .foregroundStyle(DesignTokens.Text.primary)
            Spacer()
            SettingsSlider(value: .constant(3.5), range: 1...10, step: 0.5)
        }
    }
    .padding(24)
    .background(Color.black.opacity(0.9))
}