//
//  DSPicker.swift
//  DeskJig
//
//  Created by Claude Code on 02/02/26.
//

import SwiftUI
import DeskJigShared

/// A styled menu picker component that matches the design system.
/// Shows selected value with dropdown arrow, uses design token fonts.
///
/// Usage:
/// ```swift
/// DSPicker(
///     options: UIScale.allCases,
///     selection: $selectedScale
/// ) { scale in
///     scale.description
/// }
/// ```
struct DSPicker<T: Hashable & Identifiable, Label: View>: View {
    let options: [T]
    @Binding var selection: T
    let label: (T) -> Label

    init(
        options: [T],
        selection: Binding<T>,
        @ViewBuilder label: @escaping (T) -> Label
    ) {
        self.options = options
        self._selection = selection
        self.label = label
    }

    var body: some View {
        Menu {
            ForEach(options) { option in
                Button {
                    selection = option
                } label: {
                    label(option)
                }
            }
        } label: {
            HStack(spacing: DesignTokens.Spacing.gapSmall) {
                label(selection)
                    .font(brand: .body3)
                    .foregroundStyle(DesignTokens.Text.primary)

                Image(systemName: "chevron.down")
                    .font(.system(size: DesignTokens.IconSize.small, weight: .medium))
                    .foregroundStyle(DesignTokens.Text.tertiary)
            }
            .padding(.horizontal, DesignTokens.Form.inputPaddingHorizontal)
            .padding(.vertical, DesignTokens.Form.inputPaddingVertical)
            .background(
                RoundedRectangle(cornerRadius: DesignTokens.Form.cornerRadius)
                    .fill(DesignTokens.Surface.input)
            )
            .overlay(
                RoundedRectangle(cornerRadius: DesignTokens.Form.cornerRadius)
                    .stroke(DesignTokens.Border.subtle, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }
}

/// Convenience initializer for String labels
extension DSPicker where Label == Text {
    init(
        options: [T],
        selection: Binding<T>,
        labelText: @escaping (T) -> String
    ) {
        self.options = options
        self._selection = selection
        self.label = { Text(labelText($0)) }
    }
}

#Preview {
    VStack(alignment: .leading, spacing: 24) {
        Text("Pickers")
            .font(brand: .h4)
            .foregroundStyle(DesignTokens.Text.primary)

        HStack {
            Text("Interface Scale")
                .font(brand: .label2)
                .foregroundStyle(DesignTokens.Text.secondary)
            Spacer()
            DSPicker(
                options: ["Compact", "Regular", "Large"],
                selection: .constant("Regular"),
                labelText: { $0 }
            )
        }
        .frame(width: 500)
    }
    .padding(32)
    .background(Color.black.opacity(0.9))
}

// Make String Identifiable for preview
extension String: @retroactive Identifiable {
    public var id: String { self }
}
