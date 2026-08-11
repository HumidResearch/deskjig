//
//  DSMonitorPreview.swift
//  DeskJig
//
//  Created by Claude Code on 02/02/26.
//

import SwiftUI
import AppKit
import DeskJigShared

// MARK: - Monitor Preview Data

/// Data model for a window in the monitor preview
struct DSPreviewWindow: Identifiable {
    let id: UUID
    let appName: String
    let icon: NSImage?
    let xPercent: Double
    let yPercent: Double
    let widthPercent: Double
    let heightPercent: Double
    var specialAppType: DSSpecialAppType?

    init(
        id: UUID = UUID(),
        appName: String,
        icon: NSImage? = nil,
        xPercent: Double,
        yPercent: Double,
        widthPercent: Double,
        heightPercent: Double,
        specialAppType: DSSpecialAppType? = nil
    ) {
        self.id = id
        self.appName = appName
        self.icon = icon
        self.xPercent = xPercent
        self.yPercent = yPercent
        self.widthPercent = widthPercent
        self.heightPercent = heightPercent
        self.specialAppType = specialAppType
    }
}

// MARK: - Monitor Preview

/// A single monitor preview showing windows positioned within.
/// Uses design tokens for consistent styling.
struct DSMonitorPreview: View {
    let title: String
    let windows: [DSPreviewWindow]
    var isPrimary: Bool = false
    var showLabel: Bool = true
    var height: CGFloat = 110
    var isInEditMode: Bool = false
    var selectedWindowId: UUID? = nil
    var onWindowTapped: ((DSPreviewWindow) -> Void)? = nil

    private let maxWindows = 8
    private let layoutCalculator = DSLayoutBoundsCalculator()
    private let shadowPadding: CGFloat = 8

    private var contentHeight: CGFloat {
        showLabel ? height - 18 : height
    }

    private var width: CGFloat {
        let fixedRatio: CGFloat = 1.6
        return contentHeight * fixedRatio
    }

    private var displayStrokeColor: Color {
        DesignTokens.Preview.monitorStrokeSecondary
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            GeometryReader { geometry in
                let adjustedSize = CGSize(
                    width: geometry.size.width - shadowPadding * 2,
                    height: geometry.size.height - shadowPadding * 2
                )
                let iconSize = layoutCalculator.iconSize(for: adjustedSize)
                let limitedWindows = Array(windows.prefix(maxWindows))

                ZStack(alignment: .topLeading) {
                    // Monitor frame
                    RoundedRectangle(cornerRadius: DesignTokens.Card.cornerRadius)
                        .fill(DesignTokens.Preview.monitorFill)
                        .overlay(
                            RoundedRectangle(cornerRadius: DesignTokens.Card.cornerRadius)
                                .stroke(displayStrokeColor, lineWidth: 1)
                        )
                        .shadow(
                            color: Color.black.opacity(DesignTokens.Shadow.small.opacity),
                            radius: DesignTokens.Shadow.small.radius,
                            x: 0,
                            y: DesignTokens.Shadow.small.y
                        )

                    // Render windows
                    windowsContent(
                        windows: limitedWindows,
                        size: adjustedSize,
                        iconSize: iconSize
                    )

                    // Overflow indicator
                    if windows.count > maxWindows {
                        overflowIndicator(
                            count: windows.count - maxWindows,
                            iconSize: iconSize,
                            size: adjustedSize
                        )
                    }
                }
                .frame(width: adjustedSize.width, height: adjustedSize.height)
                .offset(x: shadowPadding, y: shadowPadding)
            }
            .frame(width: width, height: contentHeight)

            if showLabel {
                Text(title)
                    .font(brand: .label4)
                    .foregroundStyle(DesignTokens.Text.tertiary)
                    .padding(.leading, shadowPadding)
            }
        }
        .frame(width: width)
    }

    @ViewBuilder
    private func windowsContent(
        windows: [DSPreviewWindow],
        size: CGSize,
        iconSize: CGFloat
    ) -> some View {
        let bounds = layoutCalculator.layoutBounds(for: size)
        if bounds.width > 0 && bounds.height > 0 {
            let normalizer = DSLayoutNormalizer(frameCount: windows.count)
            let layoutLookup = buildLayoutLookup(windows: windows, normalizer: normalizer, bounds: bounds)
            let iconPositions = buildIconPositions(
                windows: windows,
                layoutLookup: layoutLookup,
                bounds: bounds,
                iconSize: iconSize
            )

            // Render windows in reverse order (back to front)
            ForEach(windows.reversed()) { window in
                // Window rectangle
                if let rect = layoutLookup[window.id] {
                    DSWindowPreviewRect(
                        rect: rect,
                        isSelected: selectedWindowId == window.id
                    ) {
                        onWindowTapped?(window)
                    }
                }

                // App icon
                if let position = iconPositions[window.id] {
                    DSWindowPreviewIcon(
                        icon: window.icon,
                        fallback: window.appName,
                        size: iconSize,
                        position: position,
                        onTap: { onWindowTapped?(window) },
                        specialAppType: window.specialAppType,
                        isInEditMode: isInEditMode,
                        isSelected: selectedWindowId == window.id
                    )
                }
            }
        }
    }

    private func buildLayoutLookup(
        windows: [DSPreviewWindow],
        normalizer: DSLayoutNormalizer,
        bounds: CGRect
    ) -> [UUID: CGRect] {
        var lookup: [UUID: CGRect] = [:]
        for window in windows {
            let normalized = normalizer.normalizedRect(
                xPercent: window.xPercent,
                yPercent: window.yPercent,
                widthPercent: window.widthPercent,
                heightPercent: window.heightPercent
            )
            lookup[window.id] = layoutCalculator.layoutRect(fromNormalized: normalized, within: bounds)
        }
        return lookup
    }

    private func buildIconPositions(
        windows: [DSPreviewWindow],
        layoutLookup: [UUID: CGRect],
        bounds: CGRect,
        iconSize: CGFloat
    ) -> [UUID: CGPoint] {
        var positions: [UUID: CGPoint] = [:]
        let fallbackCount = windows.filter { layoutLookup[$0.id] == nil }.count
        let insetBounds = layoutCalculator.adjustedFallbackBounds(for: bounds, iconSize: iconSize)
        let fallbackPositions = layoutCalculator.gridPositions(count: fallbackCount, in: insetBounds)
        var fallbackIndex = 0

        for window in windows {
            if let rect = layoutLookup[window.id] {
                positions[window.id] = CGPoint(x: rect.midX, y: rect.midY)
            } else if fallbackIndex < fallbackPositions.count {
                positions[window.id] = fallbackPositions[fallbackIndex]
                fallbackIndex += 1
            } else {
                positions[window.id] = CGPoint(x: bounds.midX, y: bounds.midY)
            }
        }

        return positions
    }

    @ViewBuilder
    private func overflowIndicator(count: Int, iconSize: CGFloat, size: CGSize) -> some View {
        Text("+\(count)")
            .font(.system(size: iconSize * 0.45, weight: .semibold))
            .foregroundStyle(DesignTokens.Text.primary)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                Capsule().fill(DesignTokens.Surface.cardHover)
            )
            .position(x: size.width - iconSize * 0.7, y: size.height - iconSize * 0.6)
    }
}

// MARK: - Preview

#Preview("Monitor Preview") {
    VStack(spacing: 24) {
        Text("Monitor Preview")
            .font(brand: .h3)
            .foregroundStyle(DesignTokens.Text.primary)

        HStack(spacing: 16) {
            // Primary monitor
            DSMonitorPreview(
                title: "Monitor 1",
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
                ],
                isPrimary: true,
                isInEditMode: true
            )

            // Secondary monitor
            DSMonitorPreview(
                title: "Monitor 2",
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
                ],
                isPrimary: false
            )
        }
    }
    .padding(32)
    .background(Color.black.opacity(0.9))
}
