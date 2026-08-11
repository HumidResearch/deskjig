//
//  DSSelect.swift
//  DeskJig
//
//  Created by Claude Code on 02/02/26.
//

import SwiftUI
import DeskJigShared

enum DSSelectSize {
    case regular
    case compact

    @MainActor var font: Font.BrandFont {
        switch self {
        case .regular:
            return .body2
        case .compact:
            return .body3
        }
    }

    var horizontalPadding: CGFloat {
        switch self {
        case .regular:
            return DesignTokens.Form.inputPaddingHorizontal
        case .compact:
            return 10
        }
    }

    var height: CGFloat {
        switch self {
        case .regular:
            return DesignTokens.Form.inputHeight
        case .compact:
            return 32
        }
    }
}

/// A select option for DSSelect dropdown.
struct DSSelectOption<T: Hashable>: Identifiable {
    let id: T
    let label: String

    init(id: T, label: String) {
        self.id = id
        self.label = label
    }
}

/// A styled dropdown picker component with validation support.
///
/// Features:
/// - Consistent styling with DSTextField
/// - Validation state support
/// - Generic type support for option values
///
/// Usage:
/// ```swift
/// DSSelect(
///     options: [
///         DSSelectOption(id: "us", label: "United States"),
///         DSSelectOption(id: "uk", label: "United Kingdom")
///     ],
///     selection: $selectedCountry,
///     placeholder: "Select country"
/// )
/// ```
struct DSSelect<T: Hashable>: View {
    let options: [DSSelectOption<T>]
    @Binding var selection: T?
    var placeholder: String = "Select..."
    var validationState: DSValidationState = .none
    var size: DSSelectSize = .regular

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.gapTiny) {
            Menu {
                ForEach(options) { option in
                    Button(option.label) {
                        selection = option.id
                    }
                }
            } label: {
                HStack {
                    Text(selectedLabel)
                        .font(brand: size.font)
                        .foregroundStyle(
                            selection == nil
                                ? DesignTokens.Text.tertiary
                                : DesignTokens.Text.primary
                        )
                        .lineLimit(1)
                        .truncationMode(.tail)

                    Spacer()

                    Image(systemName: "chevron.down")
                        .font(.system(size: DesignTokens.IconSize.small, weight: .medium))
                        .foregroundStyle(DesignTokens.Text.tertiary)
                }
                .padding(.horizontal, size.horizontalPadding)
                .frame(height: size.height)
                .background(
                    RoundedRectangle(cornerRadius: DesignTokens.Form.cornerRadius)
                        .fill(DesignTokens.Surface.input)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: DesignTokens.Form.cornerRadius)
                        .stroke(validationState.borderColor, lineWidth: 1)
                )
            }
            .buttonStyle(.plain)

            // Validation message
            if let message = validationState.message {
                HStack(spacing: DesignTokens.Spacing.gapTiny) {
                    if let icon = validationState.icon {
                        Image(systemName: icon)
                            .font(.system(size: DesignTokens.IconSize.tiny))
                    }
                    Text(message)
                }
                .font(brand: .body4)
                .foregroundStyle(validationState.messageColor)
            }
        }
    }

    private var selectedLabel: String {
        if let selection, let option = options.first(where: { $0.id == selection }) {
            return option.label
        }
        return placeholder
    }
}

#Preview {
    VStack(alignment: .leading, spacing: 24) {
        Text("Dropdowns")
            .font(brand: .h4)
            .foregroundStyle(DesignTokens.Text.primary)

        VStack(alignment: .leading, spacing: 16) {
            Text("Basic")
                .font(brand: .body3)
                .foregroundStyle(DesignTokens.Text.secondary)
            DSSelect(
                options: [
                    DSSelectOption(id: "opt1", label: "Option 1"),
                    DSSelectOption(id: "opt2", label: "Option 2"),
                    DSSelectOption(id: "opt3", label: "Option 3")
                ],
                selection: .constant(nil),
                placeholder: "Select an option..."
            )
        }

        VStack(alignment: .leading, spacing: 16) {
            Text("With Selection")
                .font(brand: .body3)
                .foregroundStyle(DesignTokens.Text.secondary)
            DSSelect(
                options: [
                    DSSelectOption(id: "opt1", label: "Option 1"),
                    DSSelectOption(id: "opt2", label: "Option 2"),
                    DSSelectOption(id: "opt3", label: "Option 3")
                ],
                selection: .constant("opt2"),
                placeholder: "Select an option..."
            )
        }

        VStack(alignment: .leading, spacing: 16) {
            Text("Error State")
                .font(brand: .body3)
                .foregroundStyle(DesignTokens.Text.secondary)
            DSSelect(
                options: [
                    DSSelectOption(id: "opt1", label: "Option 1"),
                    DSSelectOption(id: "opt2", label: "Option 2")
                ],
                selection: .constant(nil),
                placeholder: "Select...",
                validationState: .error("Selection is required")
            )
        }

        VStack(alignment: .leading, spacing: 16) {
            Text("Success State")
                .font(brand: .body3)
                .foregroundStyle(DesignTokens.Text.secondary)
            DSSelect(
                options: [
                    DSSelectOption(id: "opt1", label: "Option 1"),
                    DSSelectOption(id: "opt2", label: "Option 2")
                ],
                selection: .constant("opt1"),
                placeholder: "Select...",
                validationState: .success("Great choice!")
            )
        }
    }
    .padding(32)
    .frame(width: 400)
    .background(Color.black.opacity(0.9))
}
