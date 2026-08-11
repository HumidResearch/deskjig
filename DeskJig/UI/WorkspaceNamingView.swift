//  WorkspaceNamingView.swift
//  DeskJig
//
//  Created by Marco Freedom on 06.09.2025.
//

import SwiftUI
import DeskJigShared


struct WorkspaceNamingView: View {
    let mode: WorkspaceNamingMode
    let onSave: (String) -> Void
    let onCancel: () -> Void

    @State private var workspaceName: String = ""
    @FocusState private var isTextFieldFocused: Bool

    var body: some View {
        VStack(spacing: 24) {
            Spacer()
            
            // Text field
            VStack(alignment: .leading, spacing: 8) {
                Text("Workspace Name")
                    .font(.title)
                    .foregroundColor(DesignTokens.Text.primary.opacity(0.8))

                TextField("Enter new workspace name", text: $workspaceName)
                    .textFieldStyle(.plain)
                    .font(.title3)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color.white.opacity(0.1))
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .stroke(DesignTokens.Brand.accent.opacity(0.5), lineWidth: 2)
                            )
                    )
                    .foregroundColor(DesignTokens.Text.primary)
                    .focused($isTextFieldFocused)
                    .onSubmit {
                        handleSave()
                    }
            }

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
                        .background(Color.gray.opacity(0.6))
                        .cornerRadius(25)
                }
                .buttonStyle(.plain)

                Spacer()

                // Create/Save button
                Button(action: handleSave) {
                    Text(buttonText)
                        .font(.headline)
                        .fontWeight(.semibold)
                        .foregroundColor(DesignTokens.Text.primary)
                        .padding(.horizontal, 24)
                        .padding(.vertical, 12)
                        .background(
                            workspaceName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?
                            Color.gray.opacity(0.4) : DesignTokens.Brand.accent.opacity(0.8)
                        )
                        .cornerRadius(25)
                }
                .buttonStyle(.plain)
                .disabled(workspaceName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .keyboardShortcut(.return)
            }
        }
        .onAppear {
            // Set initial name based on mode
            switch mode {
            case .create:
                let dateFormatter = DateFormatter()
                dateFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
                workspaceName = "Workspace \(dateFormatter.string(from: Date()))"
            case .rename(let workspace):
                workspaceName = workspace.name
            }

            // Focus the text field
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                isTextFieldFocused = true
            }
        }
    }

    private var titleText: String {
        switch mode {
        case .create:
            return "Create New Workspace"
        case .rename:
            return "Rename Workspace"
        }
    }

    private var buttonText: String {
        switch mode {
        case .create:
            return "Create"
        case .rename:
            return "Save"
        }
    }

    private func handleSave() {
        let trimmedName = workspaceName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedName.isEmpty {
            onSave(trimmedName)
        }
    }
}

#Preview {
    WorkspaceNamingView(
        mode: .create,
        onSave: { name in
            DeskJigLog.info(.workspace, "Save workspace", fields: ["name": name])
        },
        onCancel: {
            DeskJigLog.info(.workspace, "Cancel workspace naming")
        }
    )
    .frame(width: 500, height: 325)
    .background(DesignTokens.Brand.accent.opacity(0.3))
}
