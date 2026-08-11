//  EditLayoutConfirmationOverlay.swift
//  DeskJig
//
//  Confirmation overlay for editing workspace layout with options
//  to edit without restoring or to restore & edit
//

import SwiftUI
import DeskJigShared

struct EditLayoutConfirmationOverlay: View {
    let workspaceName: String
    let onEditWithoutRestoring: () -> Void
    let onRestoreAndEdit: () -> Void
    let onCancel: () -> Void

    var body: some View {
        ZStack {
            // Dimmed background
            Color.black.opacity(DesignTokens.Opacity.overlay)
                .onTapGesture {
                    onCancel()
                }

            // Confirmation dialog
            VStack(spacing: 20) {
                VStack(spacing: 8) {
                    Text("Edit Layout Options")
                        .font(brand: .h3)
                        .foregroundStyle(DesignTokens.Text.primary)

                    Text("Choose how to edit '\(workspaceName)'")
                        .font(brand: .label2)
                        .foregroundStyle(DesignTokens.Text.tertiary)
                }

                VStack(spacing: 12) {
                    // Edit Without Restoring option
                    Button(action: onEditWithoutRestoring) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Edit Without Restoring")
                                .font(brand: .label2)
                                .foregroundStyle(DesignTokens.Text.primary)
                            Text("Edit the layout using saved data. Your current windows stay as-is.")
                                .font(brand: .body4)
                                .foregroundStyle(DesignTokens.Text.tertiary)
                                .multilineTextAlignment(.leading)
                        }
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background {
                            RoundedRectangle(cornerRadius: DesignTokens.Card.cornerRadius)
                                .fill(DesignTokens.Surface.elevated)
                                .stroke(DesignTokens.Border.subtle, lineWidth: 1)
                        }
                        .brightenOnHover()
                    }
                    .buttonStyle(.plain)

                    // Restore & Edit option
                    Button(action: onRestoreAndEdit) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Restore & Edit")
                                .font(brand: .label2)
                                .foregroundStyle(DesignTokens.Text.primary)
                            Text("Restore workspace first, then edit the current window layout.")
                                .font(brand: .body4)
                                .foregroundStyle(DesignTokens.Text.tertiary)
                                .multilineTextAlignment(.leading)
                        }
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background {
                            RoundedRectangle(cornerRadius: DesignTokens.Card.cornerRadius)
                                .fill(DesignTokens.Surface.elevated)
                                .stroke(DesignTokens.Border.subtle, lineWidth: 1)
                        }
                        .brightenOnHover()
                    }
                    .buttonStyle(.plain)

                    // Cancel button
                    Button(action: onCancel) {
                        Text("Cancel")
                            .font(brand: .label2)
                            .foregroundStyle(DesignTokens.Text.primary)
                            .padding(12)
                            .frame(maxWidth: .infinity)
                            .background {
                                Capsule()
                                    .fill(DesignTokens.Surface.elevated)
                                    .stroke(DesignTokens.Border.subtle, lineWidth: 1)
                            }
                            .brightenOnHover()
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(24)
            .frame(width: 400)
            .dsCard()
            .transition(.blurTransition(blurRadius: 4, scale: 0.9, anchor: .center))
        }
    }
}
