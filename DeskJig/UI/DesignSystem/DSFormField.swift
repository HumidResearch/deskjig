//
//  DSFormField.swift
//  DeskJig
//
//  Created by Claude Code on 02/02/26.
//

import SwiftUI
import DeskJigShared

/// A wrapper component for consistent form field layout.
///
/// Provides standard layout with:
/// - Label
/// - Optional subtitle
/// - Content (ViewBuilder)
/// - Validation message (from state)
///
/// Layout order: Label -> Subtitle -> 8pt gap -> Content -> 4pt gap -> Validation
///
/// Usage:
/// ```swift
/// DSFormField(label: "Email", subtitle: "We'll never share your email") {
///     DSTextField(placeholder: "name@example.com", text: $email)
/// }
/// ```
struct DSFormField<Content: View>: View {
    let label: String
    var subtitle: String? = nil
    var validationState: DSValidationState = .none
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.gapSmall) {
            // Label and subtitle
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.gapTiny) {
                Text(label)
                    .font(brand: .label3)
                    .foregroundStyle(DesignTokens.Text.primary)

                if let subtitle {
                    Text(subtitle)
                        .font(brand: .body4)
                        .foregroundStyle(DesignTokens.Text.tertiary)
                }
            }

            // Content
            content()

            // Validation message (if not already shown by the content)
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
}

#Preview {
    VStack(alignment: .leading, spacing: 32) {
        Text("Form Fields")
            .font(brand: .h4)
            .foregroundStyle(DesignTokens.Text.primary)

        DSFormField(label: "Username") {
            DSTextField(placeholder: "Enter username...", text: .constant(""))
        }

        DSFormField(
            label: "Email Address",
            subtitle: "We'll never share your email with anyone"
        ) {
            DSTextField(
                placeholder: "name@example.com",
                text: .constant(""),
                leadingIcon: "envelope"
            )
        }

        DSFormField(
            label: "Country",
            subtitle: "Select your country of residence",
            validationState: .error("Please select a country")
        ) {
            DSSelect(
                options: [
                    DSSelectOption(id: "us", label: "United States"),
                    DSSelectOption(id: "uk", label: "United Kingdom"),
                    DSSelectOption(id: "ca", label: "Canada")
                ],
                selection: .constant(nil),
                placeholder: "Select country..."
            )
        }

        DSFormField(
            label: "Project Directory",
            validationState: .success("Directory exists")
        ) {
            DSTextField(
                placeholder: "/path/to/project",
                text: .constant("/Users/dev/myproject"),
                leadingIcon: "folder"
            )
        }
    }
    .padding(32)
    .frame(width: 400)
    .background(Color.black.opacity(0.9))
}
