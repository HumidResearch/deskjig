//
//  WorkspaceRowView.swift
//  DeskJig
//
//  Created by Claude Code on 01/30/26.
//

import SwiftUI
import DeskJigShared

/// A row-style workspace tile for single-column list layout.
/// Displays icon, name, and app icons horizontally with edit indicator on hover.
struct WorkspaceRowView: View {
    let workspace: WorkspaceWithApps
    let index: Int
    @Environment(WorkspaceViewModel.self) private var vm
    @State private var isHovering: Bool = false

    var body: some View {
        Button {
            vm.editWorkspace(workspace.workspace)
        } label: {
            HStack(spacing: 16) {
                // Icon/Index
                iconView
                    .frame(width: 32)

                // Workspace name
                Text(workspace.workspace.name)
                    .font(brand: .body2)
                    .foregroundStyle(DesignTokens.Text.primary)
                    .lineLimit(1)

                Spacer()

                // App icons
                AppIconsRow(apps: workspace.apps)

                // Pencil icon on hover
                if isHovering {
                    Image(systemName: "pencil.circle.fill")
                        .font(brand: Font.brandBody(size: 16))
                        .foregroundStyle(DesignTokens.Text.secondary)
                        .transition(.blurReplace)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
            .dsCard(style: .workspace, isHighlighted: isHovering)
            .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Card.cornerRadius))
        }
        .animation(.smooth(duration: 0.15), value: isHovering)
        .onHover { isHovering = $0 }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var iconView: some View {
        if let icon = workspace.workspace.icon {
            Text(icon)
                .font(brand: .h4)
                .frame(width: 32, height: 32)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(DesignTokens.Surface.elevated)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(DesignTokens.Border.subtle, lineWidth: 1)
                )
        } else {
            Text((index + 1).description)
                .font(brand: .h4)
                .foregroundStyle(DesignTokens.Text.muted)
                .frame(width: 32, height: 32)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(DesignTokens.Surface.elevated)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(DesignTokens.Border.subtle, lineWidth: 1)
                )
        }
    }
}

/// Horizontal row of app icons for the list view.
private struct AppIconsRow: View {
    let apps: [AppInfo]
    let maxAppsToDisplay: Int = 6
    let appSize: CGFloat = 28

    var body: some View {
        HStack(spacing: 4) {
            ForEach(Array(apps.prefix(maxAppsToDisplay).enumerated()), id: \.offset) { _, app in
                if let icon = app.icon {
                    Image(nsImage: icon)
                        .resizable()
                        .frame(width: appSize, height: appSize)
                } else {
                    Image(systemName: "questionmark.app.fill")
                        .resizable()
                        .frame(width: appSize, height: appSize)
                        .foregroundStyle(DesignTokens.Text.muted)
                }
            }

            if apps.count > maxAppsToDisplay {
                Text("+\(apps.count - maxAppsToDisplay)")
                    .font(brand: .body3)
                    .foregroundStyle(DesignTokens.Text.secondary)
                    .frame(width: appSize, height: appSize)
                    .background {
                        RoundedRectangle(cornerRadius: 6)
                            .fill(DesignTokens.Surface.card)
                    }
            }
        }
    }
}
