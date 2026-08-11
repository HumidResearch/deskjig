//
//  DSIntegrationRow.swift
//  DeskJig
//
//  Created by Claude Code on 05/03/26.
//

import SwiftUI
import DeskJigShared

/// A compact integration row combining title, status badge, and action buttons on one line.
struct DSIntegrationRow: View {
    let title: String
    let statusText: String
    let statusIcon: String
    let statusColor: Color
    let statusDetail: String?
    let installPath: String?
    let isInstalled: Bool
    let busy: Bool
    let message: String?
    let error: String?
    let onInstall: () -> Void
    let onRemove: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: DesignTokens.Spacing.gapSmall) {
                // Left: type label
                Text(title)
                    .font(brand: .body3)
                    .foregroundStyle(DesignTokens.Text.primary)
                    .frame(width: 120, alignment: .leading)

                // Center: status badge
                DSStatusLabel(
                    text: statusText,
                    systemIcon: statusIcon,
                    color: statusColor,
                    font: .body4,
                    iconSize: DesignTokens.IconSize.small
                )

                Spacer()

                // Right: action buttons
                HStack(spacing: DesignTokens.Spacing.gapSmall) {
                    Button {
                        onInstall()
                    } label: {
                        if busy {
                            ProgressView()
                                .progressViewStyle(.circular)
                                .scaleEffect(0.7)
                                .frame(width: 14, height: 14)
                        } else {
                            Text(isInstalled ? "Update" : "Install")
                        }
                    }
                    .buttonStyle(.dsAccent(size: .small))
                    .disabled(busy)

                    if isInstalled {
                        Button {
                            onRemove()
                        } label: {
                            Text("Remove")
                        }
                        .buttonStyle(.dsButton(variant: .danger, size: .small))
                        .disabled(busy)
                    }
                }
            }
            .padding(.vertical, DesignTokens.Spacing.gapTiny)
            .help(installPath ?? "")

            // Inline success message
            if let message {
                HStack(spacing: 4) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: DesignTokens.IconSize.small, weight: .medium))
                    Text(message)
                        .font(brand: .body4)
                }
                .foregroundStyle(DesignTokens.Status.success)
                .padding(.top, 2)
            }

            // Inline error message
            if let error {
                HStack(spacing: 4) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: DesignTokens.IconSize.small, weight: .medium))
                    Text(error)
                        .font(brand: .body4)
                }
                .foregroundStyle(DesignTokens.Status.error)
                .padding(.top, 2)
            }
        }
    }
}

#Preview {
    VStack(spacing: 16) {
        DSIntegrationRow(
            title: "Stop Hook",
            statusText: "Installed",
            statusIcon: "checkmark.circle.fill",
            statusColor: DesignTokens.Status.success,
            statusDetail: "Up to date",
            installPath: "~/.claude/hooks/stop.sh",
            isInstalled: true,
            busy: false,
            message: nil,
            error: nil,
            onInstall: {},
            onRemove: {}
        )

        Divider().background(DesignTokens.Border.subtle)

        DSIntegrationRow(
            title: "Skill",
            statusText: "Not installed",
            statusIcon: "exclamationmark.triangle.fill",
            statusColor: DesignTokens.Status.warning,
            statusDetail: nil,
            installPath: nil,
            isInstalled: false,
            busy: false,
            message: nil,
            error: nil,
            onInstall: {},
            onRemove: {}
        )
    }
    .padding(16)
    .dsCard(cornerRadius: DesignTokens.CornerRadius.medium)
    .padding(32)
    .background(Color.black.opacity(0.9))
}
