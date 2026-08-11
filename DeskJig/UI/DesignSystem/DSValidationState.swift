//
//  DSValidationState.swift
//  DeskJig
//
//  Created by Claude Code on 02/02/26.
//

import SwiftUI
import DeskJigShared

/// Validation states for form components.
/// Use this enum to consistently represent validation feedback across all form inputs.
enum DSValidationState: Equatable, Hashable {
    /// Default state - no validation feedback
    case none
    /// Error state - red border, error icon, and message
    case error(String)
    /// Success state - green border, check icon, and message
    case success(String)

    /// Border color for the input in its default (unfocused) state
    var borderColor: Color {
        switch self {
        case .none:
            return DesignTokens.Border.subtle
        case .error:
            return DesignTokens.Status.error
        case .success:
            return DesignTokens.Status.success
        }
    }

    /// Border color when the input is focused
    var focusBorderColor: Color {
        switch self {
        case .none:
            return DesignTokens.Brand.accent
        case .error:
            return DesignTokens.Status.error
        case .success:
            return DesignTokens.Status.success
        }
    }

    /// The validation message to display, if any
    var message: String? {
        switch self {
        case .none:
            return nil
        case .error(let message), .success(let message):
            return message
        }
    }

    /// Color for the validation message text
    var messageColor: Color {
        switch self {
        case .none:
            return DesignTokens.Text.secondary
        case .error:
            return DesignTokens.Status.error
        case .success:
            return DesignTokens.Status.success
        }
    }

    /// SF Symbol icon name for the trailing validation icon
    var icon: String? {
        switch self {
        case .none:
            return nil
        case .error:
            return "exclamationmark.circle.fill"
        case .success:
            return "checkmark.circle.fill"
        }
    }

    /// Color for the validation icon
    var iconColor: Color {
        switch self {
        case .none:
            return .clear
        case .error:
            return DesignTokens.Status.error
        case .success:
            return DesignTokens.Status.success
        }
    }
}

#Preview {
    VStack(alignment: .leading, spacing: 16) {
        Text("Validation States")
            .font(brand: .h4)
            .foregroundStyle(DesignTokens.Text.primary)

        ForEach([
            DSValidationState.none,
            DSValidationState.error("This field is required"),
            DSValidationState.success("Looks good!")
        ], id: \.self) { state in
            HStack(spacing: 8) {
                if let icon = state.icon {
                    Image(systemName: icon)
                        .foregroundStyle(state.iconColor)
                }
                Text(state.message ?? "No message")
                    .foregroundStyle(state.messageColor)
            }
            .font(brand: .body3)
        }
    }
    .padding(24)
    .background(Color.black.opacity(0.9))
}
