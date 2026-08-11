//
//  DSConfirmationModal.swift
//  DeskJig
//
//  Created by Claude Code on 02/03/26.
//

import SwiftUI
import DeskJigShared

/// A reusable confirmation modal for destructive or important actions.
struct DSConfirmationModal: View {
    let title: String
    var message: String? = nil
    var confirmTitle: String = "Confirm"
    var cancelTitle: String = "Cancel"
    var isDestructive: Bool = true
    var confirmAccessibilityIdentifier: String? = nil
    var onConfirm: () -> Void
    var onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.gapRegular) {
            Text(title)
                .font(brand: .h3)
                .foregroundStyle(DesignTokens.Text.primary)

            if let message {
                Text(message)
                    .font(brand: .body3)
                    .foregroundStyle(DesignTokens.Text.secondary)
            }

            HStack(spacing: DesignTokens.Spacing.gapSmall) {
                Button(cancelTitle) {
                    onCancel()
                }
                .buttonStyle(.dsButton(variant: .secondary, size: .medium))

                Spacer()

                identifiedConfirmButton
            }
        }
        .padding(DesignTokens.Card.padding)
        .background {
            RoundedRectangle(cornerRadius: DesignTokens.CornerRadius.large)
                .fill(DesignTokens.Surface.panel)
        }
        .overlay {
            RoundedRectangle(cornerRadius: DesignTokens.CornerRadius.large)
                .stroke(DesignTokens.Border.subtle, lineWidth: 1)
        }
        .shadow(
            color: Color.black.opacity(DesignTokens.Shadow.large.opacity),
            radius: DesignTokens.Shadow.large.radius,
            x: 0,
            y: DesignTokens.Shadow.large.y
        )
    }

    private var confirmButton: some View {
        Button(confirmTitle) {
            onConfirm()
        }
        .buttonStyle(.dsButton(variant: isDestructive ? .danger : .primary, size: .medium))
    }

    @ViewBuilder
    private var identifiedConfirmButton: some View {
        if let confirmAccessibilityIdentifier {
            confirmButton.accessibilityIdentifier(confirmAccessibilityIdentifier)
        } else {
            confirmButton
        }
    }
}

struct DSConfirmationConfig {
    let title: String
    var message: String?
    var confirmTitle: String
    var cancelTitle: String
    var isDestructive: Bool
    var confirmAccessibilityIdentifier: String?
    var onConfirm: () -> Void
    var onCancel: () -> Void
}

final class DSConfirmationManager: ObservableObject {
    @Published var config: DSConfirmationConfig? = nil

    func present(
        title: String,
        message: String? = nil,
        confirmTitle: String = "Confirm",
        cancelTitle: String = "Cancel",
        isDestructive: Bool = true,
        confirmAccessibilityIdentifier: String? = nil,
        onConfirm: @escaping () -> Void,
        onCancel: @escaping () -> Void
    ) {
        config = DSConfirmationConfig(
            title: title,
            message: message,
            confirmTitle: confirmTitle,
            cancelTitle: cancelTitle,
            isDestructive: isDestructive,
            confirmAccessibilityIdentifier: confirmAccessibilityIdentifier,
            onConfirm: onConfirm,
            onCancel: onCancel
        )
    }

    func dismiss() {
        config = nil
    }
}

/// Full-screen overlay presentation for DSConfirmationModal.
struct DSConfirmationOverlayHost: View {
    @EnvironmentObject private var manager: DSConfirmationManager

    var body: some View {
        if let config = manager.config {
            ZStack {
                Color.black
                    .opacity(DesignTokens.Opacity.overlay)
                    .ignoresSafeArea()
                    .onTapGesture {
                        manager.dismiss()
                        config.onCancel()
                    }

                DSConfirmationModal(
                    title: config.title,
                    message: config.message,
                    confirmTitle: config.confirmTitle,
                    cancelTitle: config.cancelTitle,
                    isDestructive: config.isDestructive,
                    confirmAccessibilityIdentifier: config.confirmAccessibilityIdentifier,
                    onConfirm: {
                        manager.dismiss()
                        config.onConfirm()
                    },
                    onCancel: {
                        manager.dismiss()
                        config.onCancel()
                    }
                )
                .frame(maxWidth: 520)
                .padding(DesignTokens.Spacing.contentPaddingLarge)
            }
            .transition(.opacity)
            .animation(.smooth(duration: 0.15), value: manager.config != nil)
        }
    }
}

#Preview("Confirmation Modal") {
    DSConfirmationModal(
        title: "Delete Workspace?",
        message: "This will permanently remove the workspace and its saved layout.",
        confirmTitle: "Delete Workspace",
        cancelTitle: "Cancel",
        isDestructive: true,
        onConfirm: {},
        onCancel: {}
    )
    .frame(width: 420)
    .background(Color.black.opacity(0.9))
}
