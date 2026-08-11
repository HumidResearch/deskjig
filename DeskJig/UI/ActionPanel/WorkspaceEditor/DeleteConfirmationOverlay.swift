//  DeleteConfirmationOverlay.swift
//  DeskJig
//
//  Confirmation overlay for workspace deletion
//

import SwiftUI
import DeskJigShared

struct DeleteConfirmationOverlay: View {
    let workspaceName: String
    let onConfirm: () -> Void
    let onCancel: () -> Void
    
    var body: some View {
        ZStack {
            // Dimmed background
            Color.black.opacity(DesignTokens.Opacity.overlay)
                .ignoresSafeArea()
                .onTapGesture {
                    onCancel()
                }
            
            // Confirmation dialog
            VStack(spacing: 20) {
                VStack(spacing: 8) {
                    Text("Delete '\(workspaceName)'?")
                        .font(brand: .h3)
                        .foregroundStyle(DesignTokens.Text.primary)
                    
                    Text("This action cannot be undone.")
                        .font(brand: .label2)
                        .foregroundStyle(DesignTokens.Text.tertiary)
                }
                
                VStack(spacing: 12) {
                    Button(action: onConfirm) {
                        Text("Delete Workspace")
                            .font(brand: .label2)
                            .foregroundStyle(DesignTokens.Status.error)
                            .padding(12)
                            .frame(maxWidth: .infinity)
                            .background {
                                Capsule()
                                    .fill(DesignTokens.Surface.card)
                                    .stroke(DesignTokens.Status.error.opacity(0.6), lineWidth: 1)
                            }
                            .brightenOnHover()
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("workspace.delete-confirm-button")
                    
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
