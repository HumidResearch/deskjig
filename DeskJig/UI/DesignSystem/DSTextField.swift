//
//  DSTextField.swift
//  DeskJig
//
//  Created by Claude Code on 02/02/26.
//

import SwiftUI
import DeskJigShared

/// A styled text input component with validation support.
///
/// Features:
/// - Focus ring animation
/// - Leading icon support (SF Symbol)
/// - Trailing validation icon
/// - Validation message display
///
/// Usage:
/// ```swift
/// DSTextField(
///     placeholder: "Enter your name",
///     text: $name,
///     leadingIcon: "person",
///     validationState: .error("Name is required")
/// )
/// ```
struct DSTextField: View {
    let placeholder: String
    @Binding var text: String
    var leadingIcon: String? = nil
    var validationState: DSValidationState = .none
    var isDisabled: Bool = false
    var accessibilityIdentifier: String? = nil

    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.gapTiny) {
            HStack(spacing: 0) {
                // Leading icon
                if let leadingIcon {
                    Image(systemName: leadingIcon)
                        .font(.system(size: DesignTokens.IconSize.medium))
                        .foregroundStyle(DesignTokens.Text.tertiary)
                        .frame(width: 32)
                }

                // Text field
                identifiedTextField

                // Trailing validation icon
                if let icon = validationState.icon {
                    Image(systemName: icon)
                        .font(.system(size: DesignTokens.IconSize.medium))
                        .foregroundStyle(validationState.iconColor)
                        .frame(width: 24)
                }
            }
            .padding(.horizontal, DesignTokens.Form.inputPaddingHorizontal)
            .frame(height: DesignTokens.Form.inputHeight)
            .background(
                RoundedRectangle(cornerRadius: DesignTokens.Form.cornerRadius)
                    .fill(DesignTokens.Surface.input)
            )
            .overlay(
                RoundedRectangle(cornerRadius: DesignTokens.Form.cornerRadius)
                    .stroke(
                        isFocused ? validationState.focusBorderColor : validationState.borderColor,
                        lineWidth: isFocused ? DesignTokens.Form.focusRingWidth : 1
                    )
            )
            .animation(.easeInOut(duration: 0.15), value: isFocused)
            .opacity(isDisabled ? DesignTokens.Opacity.disabled : 1)

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

    private var textField: some View {
        TextField(placeholder, text: $text)
            .textFieldStyle(.plain)
            .font(brand: .body2)
            .foregroundStyle(isDisabled ? DesignTokens.Text.tertiary : DesignTokens.Text.primary)
            .focused($isFocused)
            .disabled(isDisabled)
    }

    @ViewBuilder
    private var identifiedTextField: some View {
        if let accessibilityIdentifier {
            textField.accessibilityIdentifier(accessibilityIdentifier)
        } else {
            textField
        }
    }
}

/// A styled multi-line text area component.
///
/// Features:
/// - Focus ring animation
/// - Placeholder text
/// - Consistent form tokens with extra internal padding
struct DSTextArea: View {
    let placeholder: String
    @Binding var text: String
    var validationState: DSValidationState = .none
    var minHeight: CGFloat = 140
    var maxHeight: CGFloat = 240
    var isDisabled: Bool = false

    @FocusState private var isFocused: Bool

    private var horizontalPadding: CGFloat {
        DesignTokens.Form.inputPaddingHorizontal + 4
    }

    private var verticalPadding: CGFloat {
        DesignTokens.Form.inputPaddingVertical + 4
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            TextEditor(text: $text)
                .font(brand: .body2)
                .foregroundStyle(isDisabled ? DesignTokens.Text.tertiary : DesignTokens.Text.primary)
                .scrollContentBackground(.hidden)
                .focused($isFocused)
                .disabled(isDisabled)
                .padding(.horizontal, horizontalPadding)
                .padding(.vertical, verticalPadding)

            if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text(placeholder)
                    .font(brand: .body3)
                    .foregroundStyle(DesignTokens.Text.tertiary)
                    .padding(.horizontal, horizontalPadding + 2)
                    .padding(.vertical, verticalPadding + 2)
                    .allowsHitTesting(false)
            }
        }
        .frame(minHeight: minHeight, maxHeight: maxHeight)
        .background(
            RoundedRectangle(cornerRadius: DesignTokens.Form.cornerRadius)
                .fill(DesignTokens.Surface.input)
        )
        .overlay(
            RoundedRectangle(cornerRadius: DesignTokens.Form.cornerRadius)
                .stroke(
                    isFocused ? validationState.focusBorderColor : validationState.borderColor,
                    lineWidth: isFocused ? DesignTokens.Form.focusRingWidth : 1
                )
        )
        .animation(.easeInOut(duration: 0.15), value: isFocused)
        .opacity(isDisabled ? DesignTokens.Opacity.disabled : 1)
    }
}

#Preview {
    VStack(alignment: .leading, spacing: 24) {
        Text("Text Fields")
            .font(brand: .h4)
            .foregroundStyle(DesignTokens.Text.primary)

        VStack(alignment: .leading, spacing: 16) {
            Text("Basic")
                .font(brand: .body3)
                .foregroundStyle(DesignTokens.Text.secondary)
            DSTextField(
                placeholder: "Enter text...",
                text: .constant("")
            )
        }

        VStack(alignment: .leading, spacing: 16) {
            Text("With Leading Icon")
                .font(brand: .body3)
                .foregroundStyle(DesignTokens.Text.secondary)
            DSTextField(
                placeholder: "Search...",
                text: .constant(""),
                leadingIcon: "magnifyingglass"
            )
        }

        VStack(alignment: .leading, spacing: 16) {
            Text("Error State")
                .font(brand: .body3)
                .foregroundStyle(DesignTokens.Text.secondary)
            DSTextField(
                placeholder: "Email address",
                text: .constant("invalid-email"),
                leadingIcon: "envelope",
                validationState: .error("Please enter a valid email")
            )
        }

        VStack(alignment: .leading, spacing: 16) {
            Text("Success State")
                .font(brand: .body3)
                .foregroundStyle(DesignTokens.Text.secondary)
            DSTextField(
                placeholder: "Username",
                text: .constant("johndoe"),
                leadingIcon: "person",
                validationState: .success("Username available")
            )
        }

        VStack(alignment: .leading, spacing: 16) {
            Text("Disabled")
                .font(brand: .body3)
                .foregroundStyle(DesignTokens.Text.secondary)
            DSTextField(
                placeholder: "Disabled input",
                text: .constant("Cannot edit"),
                isDisabled: true
            )
        }
    }
    .padding(32)
    .frame(width: 400)
    .background(Color.black.opacity(0.9))
}

#Preview("Text Areas") {
    VStack(alignment: .leading, spacing: 16) {
        Text("Text Areas")
            .font(brand: .h4)
            .foregroundStyle(DesignTokens.Text.primary)

        DSTextArea(
            placeholder: "Write a detailed description...",
            text: .constant("")
        )

        DSTextArea(
            placeholder: "Disabled",
            text: .constant("Cannot edit this text"),
            isDisabled: true
        )
    }
    .padding(24)
    .frame(width: 480)
    .background(Color.black.opacity(0.9))
}
