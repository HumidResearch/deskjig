//
//  WorkspaceInlineCreatorRow.swift
//  DeskJig
//
//  Created by Codex on 02/03/26.
//

import SwiftUI
import AppKit
import DeskJigShared

struct WorkspaceInlineCreatorRow: View {
    @Binding var isExpanded: Bool
    @Binding var editorPathFieldFocused: Bool
    var isSelected: Bool
    var viewModel: WorkspaceDraftViewModel?
    let onExpand: () -> Void
    let onCreate: () -> Void
    let onCancel: () -> Void

    var body: some View {
        if isExpanded, let viewModel {
            WorkspaceLayoutBuilder(
                viewModel: viewModel,
                editorPathFieldFocused: $editorPathFieldFocused,
                isSelected: isSelected,
                primaryTitle: viewModel.isSaving ? "Creating..." : "Create",
                secondaryTitle: "Cancel",
                primaryAccessibilityIdentifier: "workspace.create-button",
                secondaryAccessibilityIdentifier: "workspace.create-cancel-button",
                onPrimary: onCreate,
                onSecondary: onCancel,
                isPrimaryEnabled: viewModel.canCreateWorkspace && !viewModel.isSaving
            )
        } else {
            CollapsedInlineCreatorRow(isSelected: isSelected, onExpand: onExpand)
        }
    }
}

private struct CollapsedInlineCreatorRow: View {
    var isSelected: Bool
    let onExpand: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: onExpand) {
            HStack(spacing: DesignTokens.Spacing.gapMedium) {
                Image(systemName: "plus.circle")
                    .font(.system(size: DesignTokens.IconSize.xLarge))
                    .foregroundStyle(DesignTokens.Text.secondary)

                VStack(alignment: .leading, spacing: 4) {
                    Text("Create new workspace")
                        .font(brand: .h5)
                        .foregroundStyle(DesignTokens.Text.primary)

                    Text("Lay out monitors, then drop apps into zones")
                        .font(brand: .body3)
                        .foregroundStyle(DesignTokens.Text.tertiary)
                }

                Spacer()

                Image(systemName: "chevron.down")
                    .font(.system(size: DesignTokens.IconSize.small, weight: .medium))
                    .foregroundStyle(DesignTokens.Text.muted)
            }
            .padding(DesignTokens.Card.padding)
            .dsCard(style: .workspace, isHighlighted: isHovering || isSelected)
            .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Card.cornerRadius))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("workspace.new-row")
        .onHover { isHovering = $0 }
        .animation(.smooth(duration: 0.15), value: isHovering)
    }
}
