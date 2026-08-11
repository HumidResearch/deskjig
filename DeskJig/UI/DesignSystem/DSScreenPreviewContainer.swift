//
//  DSScreenPreviewContainer.swift
//  DeskJig
//
//  Created by Claude Code on 02/02/26.
//

import SwiftUI
import AppKit
import DeskJigShared

// MARK: - Screen Data

/// Data model for a screen/monitor in the preview
struct DSPreviewScreen: Identifiable {
    let id: Int
    let title: String
    var isPrimary: Bool = false
    var windows: [DSPreviewWindow] = []
}

// MARK: - Screen Preview Container

/// A container that displays multiple monitor previews in a horizontal scroll view.
/// Includes an optional refresh button and unassigned windows section.
struct DSScreenPreviewContainer: View {
    let screens: [DSPreviewScreen]
    var height: CGFloat = 110
    var showLabels: Bool = true
    var showBackground: Bool = true
    var isInEditMode: Bool = false
    var selectedWindowId: UUID? = nil
    var onWindowTapped: ((DSPreviewWindow) -> Void)? = nil
    var onRefresh: (() -> Void)? = nil
    var onAddScreen: (() -> Void)? = nil

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
                ForEach(screens) { screen in
                    DSMonitorPreview(
                        title: screen.title,
                        windows: screen.windows,
                        isPrimary: screen.isPrimary,
                        showLabel: showLabels,
                        height: height,
                        isInEditMode: isInEditMode,
                        selectedWindowId: selectedWindowId,
                        onWindowTapped: onWindowTapped
                    )
                }
            }
            .padding(.vertical, 4)
            .frame(height: height)
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 8)
        .background {
            if showBackground {
                RoundedRectangle(cornerRadius: DesignTokens.Card.cornerRadius)
                    .fill(DesignTokens.Preview.containerFill)
                    .overlay(
                        RoundedRectangle(cornerRadius: DesignTokens.Card.cornerRadius)
                            .stroke(DesignTokens.Preview.containerStroke, lineWidth: 1)
                    )
            }
        }
        .frame(height: height + 40)
        .overlay(alignment: .topTrailing) {
            if onRefresh != nil || onAddScreen != nil {
                HStack(spacing: 6) {
                    if let onAddScreen {
                        addButton(action: onAddScreen)
                    }
                    if let onRefresh {
                        refreshButton(action: onRefresh)
                    }
                }
                .padding(.top, 18)
                .padding(.trailing, 12)
            }
        }
    }

    @ViewBuilder
    private func refreshButton(action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: "arrow.clockwise")
                .font(brand: Font.brandBody(size: 10))
                .foregroundStyle(DesignTokens.Text.tertiary)
                .frame(width: 18, height: 18)
                .background(
                    Circle()
                        .fill(DesignTokens.Surface.elevated)
                )
                .brightenOnHover()
        }
        .buttonStyle(.plain)
        .padding(.top, 22)
        .padding(.trailing, 14)
        .help("Refresh visible apps")
    }

    @ViewBuilder
    private func addButton(action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: "plus")
                .font(brand: Font.brandBody(size: 10))
                .foregroundStyle(DesignTokens.Text.tertiary)
                .frame(width: 18, height: 18)
                .background(
                    Circle()
                        .fill(DesignTokens.Surface.elevated)
                )
                .brightenOnHover()
        }
        .buttonStyle(.plain)
        .help("Add monitor")
    }
}

// MARK: - Preview

#Preview("Screen Preview Container") {
    VStack(spacing: 24) {
        Text("Screen Preview Container")
            .font(brand: .h3)
            .foregroundStyle(DesignTokens.Text.primary)

        // Multi-monitor setup
        DSScreenPreviewContainer(
            screens: [
                DSPreviewScreen(
                    id: 0,
                    title: "Monitor 1",
                    isPrimary: true,
                    windows: [
                        DSPreviewWindow(
                            appName: "Chrome",
                            xPercent: 0.0,
                            yPercent: 0.0,
                            widthPercent: 0.5,
                            heightPercent: 1.0,
                            specialAppType: .chrome
                        ),
                        DSPreviewWindow(
                            appName: "VS Code",
                            xPercent: 0.5,
                            yPercent: 0.0,
                            widthPercent: 0.5,
                            heightPercent: 1.0,
                            specialAppType: .ide
                        )
                    ]
                ),
                DSPreviewScreen(
                    id: 1,
                    title: "Monitor 2",
                    isPrimary: false,
                    windows: [
                        DSPreviewWindow(
                            appName: "Slack",
                            xPercent: 0.0,
                            yPercent: 0.0,
                            widthPercent: 1.0,
                            heightPercent: 0.6
                        ),
                        DSPreviewWindow(
                            appName: "Terminal",
                            xPercent: 0.0,
                            yPercent: 0.6,
                            widthPercent: 1.0,
                            heightPercent: 0.4
                        )
                    ]
                )
            ],
            isInEditMode: true,
            onRefresh: { print("Refresh tapped") }
        )

        // Single monitor
        DSScreenPreviewContainer(
            screens: [
                DSPreviewScreen(
                    id: 0,
                    title: "Display",
                    isPrimary: true,
                    windows: [
                        DSPreviewWindow(
                            appName: "Finder",
                            xPercent: 0.1,
                            yPercent: 0.1,
                            widthPercent: 0.4,
                            heightPercent: 0.5
                        ),
                        DSPreviewWindow(
                            appName: "Notes",
                            xPercent: 0.5,
                            yPercent: 0.3,
                            widthPercent: 0.4,
                            heightPercent: 0.6
                        )
                    ]
                )
            ]
        )
    }
    .padding(32)
    .background(Color.black.opacity(0.9))
}
