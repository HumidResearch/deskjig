//  WorkspaceDeletionView.swift
//  DeskJig
//
//  Created by Marco Freedom on 10.09.2025.
//

import SwiftUI

import DeskJigShared

struct WorkspaceDeletionView: View {
    let workspace: Workspace
    let onDelete: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(spacing: 24) {
            Spacer()
            // Warning icon
            Image(systemName: "exclamationmark.triangle")
                .font(brand: Font.brandBody(size: 60))
                .foregroundColor(DesignTokens.Brand.accent)
                .padding(.top, 20)

            Text("Are you sure you want to delete '\(workspace.name)'?")
                .font(.title)
                .foregroundColor(DesignTokens.Text.primary)
                .multilineTextAlignment(.center)

            // Spacer to push buttons down
            Spacer()

            // Buttons
            HStack(spacing: 16) {
                // Cancel button
                Button(action: onCancel) {
                    Text("Cancel")
                        .font(.headline)
                        .fontWeight(.semibold)
                        .foregroundColor(DesignTokens.Text.primary)
                        .padding(.horizontal, 24)
                        .padding(.vertical, 12)
                        .background(DesignTokens.Surface.card)
                        .cornerRadius(25)
                }
                .buttonStyle(.plain)

                Spacer()

                // Delete button
                Button(action: onDelete) {
                    Text("Delete")
                        .font(.headline)
                        .fontWeight(.semibold)
                        .foregroundColor(DesignTokens.Status.error)
                        .padding(.horizontal, 24)
                        .padding(.vertical, 12)
                        .background(
                            Capsule()
                                .fill(DesignTokens.Surface.card)
                                .stroke(DesignTokens.Status.error.opacity(0.6), lineWidth: 1)
                        )
                        .cornerRadius(25)
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.return)
            }
        }
    }
}

#Preview {
    WorkspaceDeletionView(
        workspace: Workspace(
            name: "Test Workspace",
            workspaceWindows: []
        ),
        onDelete: {
            DeskJigLog.info(.workspace, "Delete workspace")
        },
        onCancel: {
            DeskJigLog.info(.workspace, "Cancel deletion")
        }
    )
    .frame(width: 500, height: 325)
    .background(DesignTokens.Brand.accent.opacity(0.3))
}
