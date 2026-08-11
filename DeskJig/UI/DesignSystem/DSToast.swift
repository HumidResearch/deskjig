//
//  DSToast.swift
//  DeskJig
//
//  Created by Codex on 02/05/26.
//

import SwiftUI
import AppKit
import DeskJigShared

/// Design-system toast component for transient app notifications.
///
/// Supports icon, message, optional subtext, optional action button,
/// and an always-visible close control.
public struct ToastDetailLine: Equatable, Sendable {
    public let label: String
    public let value: String

    public init(label: String, value: String) {
        self.label = label
        self.value = value
    }
}

struct DSToast: View {
    let icon: String
    let message: String
    var subtext: String? = nil
    var detailLines: [ToastDetailLine] = []
    var iconColor: Color = DesignTokens.Brand.accent
    var appIconPath: String? = nil
    var appIconName: String? = nil
    var forceDarkAppearance: Bool = false
    var actionTitle: String? = nil
    var actionContext: String? = nil
    var actionUsesGreenStyle: Bool = false
    var actionPulses: Bool = false
    var secondaryActionTitle: String? = nil
    var secondaryActionUsesGreenStyle: Bool = false
    var secondaryActionPulses: Bool = false
    var showsCloseControl: Bool = true
    var action: (() -> Void)? = nil
    var secondaryAction: (() -> Void)? = nil
    var onClose: () -> Void

    @State private var isActionPulseExpanded = false
    @State private var isSecondaryActionPulseExpanded = false

    private var shouldShowAction: Bool {
        guard let actionTitle, !actionTitle.isEmpty else { return false }
        return action != nil
    }

    private var shouldShowSecondaryAction: Bool {
        guard let secondaryActionTitle, !secondaryActionTitle.isEmpty else { return false }
        return secondaryAction != nil
    }

    private var shouldShowAnyActions: Bool {
        shouldShowAction || shouldShowSecondaryAction
    }

    private var normalizedSubtext: String? {
        guard let subtext else { return nil }
        let lines = subtext
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        guard !lines.isEmpty else { return nil }
        return lines.joined(separator: "\n")
    }

    private var normalizedActionContext: String? {
        guard let actionContext else { return nil }
        let trimmed = actionContext.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    var body: some View {
        let toastBody = HStack(alignment: .top, spacing: DesignTokens.Spacing.gapRegular) {
            iconView

            VStack(alignment: .leading, spacing: DesignTokens.Spacing.gapTiny) {
                Text(message)
                    .font(brand: .h4)
                    .fontWeight(.bold)
                    .foregroundStyle(headingColor)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)

                if let normalizedSubtext {
                    Text(normalizedSubtext)
                        .font(brand: .body3)
                        .foregroundStyle(subtextColor)
                        .lineLimit(3)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if !detailLines.isEmpty {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(Array(detailLines.enumerated()), id: \.offset) { _, line in
                            HStack(alignment: .firstTextBaseline, spacing: 6) {
                                Text(line.label)
                                    .font(brand: .body4)
                                    .foregroundStyle(detailLabelColor)
                                Text(line.value)
                                    .font(brand: .body4)
                                    .foregroundStyle(detailValueColor)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                        }
                    }
                    .padding(.top, 2)
                }

                if shouldShowAnyActions {
                    HStack(alignment: .center, spacing: DesignTokens.Spacing.gapSmall) {
                        if shouldShowAction, let actionTitle, let action {
                            Button(actionTitle, action: action)
                                .buttonStyle(.dsButton(variant: actionUsesGreenStyle ? .green : .secondary, size: .small))
                                .scaleEffect(actionPulses ? (isActionPulseExpanded ? 1.03 : 1.0) : 1.0)
                                .shadow(
                                    color: actionPulses ? DesignTokens.Status.success.opacity(isActionPulseExpanded ? 0.55 : 0.25) : .clear,
                                    radius: actionPulses ? (isActionPulseExpanded ? 12 : 4) : 0,
                                    x: 0,
                                    y: 0
                                )
                                .animation(
                                    actionPulses ? .easeInOut(duration: DesignTokens.Animation.pulseDuration).repeatForever(autoreverses: true) : nil,
                                    value: isActionPulseExpanded
                                )
                                .onAppear {
                                    if actionPulses {
                                        isActionPulseExpanded = true
                                    }
                                }
                                .onChange(of: actionPulses) { _, newValue in
                                    isActionPulseExpanded = newValue
                                }
                                .accessibilityLabel(actionTitle)
                        }

                        if shouldShowSecondaryAction,
                           let secondaryActionTitle,
                           let secondaryAction {
                            Button(secondaryActionTitle, action: secondaryAction)
                                .buttonStyle(.dsButton(variant: secondaryActionUsesGreenStyle ? .green : .secondary, size: .small))
                                .scaleEffect(secondaryActionPulses ? (isSecondaryActionPulseExpanded ? 1.03 : 1.0) : 1.0)
                                .shadow(
                                    color: secondaryActionPulses ? DesignTokens.Status.success.opacity(isSecondaryActionPulseExpanded ? 0.55 : 0.25) : .clear,
                                    radius: secondaryActionPulses ? (isSecondaryActionPulseExpanded ? 12 : 4) : 0,
                                    x: 0,
                                    y: 0
                                )
                                .animation(
                                    secondaryActionPulses ? .easeInOut(duration: DesignTokens.Animation.pulseDuration).repeatForever(autoreverses: true) : nil,
                                    value: isSecondaryActionPulseExpanded
                                )
                                .onAppear {
                                    if secondaryActionPulses {
                                        isSecondaryActionPulseExpanded = true
                                    }
                                }
                                .onChange(of: secondaryActionPulses) { _, newValue in
                                    isSecondaryActionPulseExpanded = newValue
                                }
                                .accessibilityLabel(secondaryActionTitle)
                        }

                        if let normalizedActionContext {
                            Text(normalizedActionContext)
                                .font(brand: .body4)
                                .foregroundStyle(actionContextColor)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if showsCloseControl {
                Button {
                    onClose()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: DesignTokens.IconSize.small, weight: .semibold))
                        .foregroundStyle(DesignTokens.Text.secondary)
                }
                .buttonStyle(.dsButton(variant: .tertiary, size: .small, isIconOnly: true))
                .accessibilityLabel("Close notification")
            }
        }
        .padding(DesignTokens.Card.padding)
        .frame(maxWidth: 420, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: DesignTokens.CornerRadius.xxLarge)
                .fill(DesignTokens.Surface.panel)
                .allowsHitTesting(false)
        }
        .overlay {
            RoundedRectangle(cornerRadius: DesignTokens.CornerRadius.xxLarge)
                .stroke(DesignTokens.Border.regular, lineWidth: 1)
                .allowsHitTesting(false)
        }
        .shadow(
            color: Color.black.opacity(DesignTokens.Shadow.medium.opacity),
            radius: DesignTokens.Shadow.medium.radius,
            x: 0,
            y: DesignTokens.Shadow.medium.y
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(accessibilityLabel))

        if forceDarkAppearance {
            toastBody
                .environment(\.colorScheme, .dark)
        } else {
            toastBody
        }
    }

    @ViewBuilder
    private var iconView: some View {
        if let appIcon = resolvedAppIcon {
            ZStack {
                RoundedRectangle(cornerRadius: DesignTokens.CornerRadius.large)
                    .fill(Color.white.opacity(0.08))

                Image(nsImage: appIcon)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .frame(width: 20, height: 20)
            }
            .frame(width: 32, height: 32)
        } else {
            ZStack {
                RoundedRectangle(cornerRadius: DesignTokens.CornerRadius.large)
                    .fill(iconColor.opacity(0.14))

                Image(systemName: icon)
                    .font(.system(size: DesignTokens.IconSize.large, weight: .semibold))
                    .foregroundStyle(iconColor)
            }
            .frame(width: 32, height: 32)
        }
    }

    private var accessibilityLabel: String {
        if let normalizedSubtext {
            return "\(message). \(normalizedSubtext)"
        }
        return message
    }

    private var headingColor: Color {
        if forceDarkAppearance {
            return Color.white.opacity(0.99)
        }
        return DesignTokens.Text.primary
    }

    private var subtextColor: Color {
        if forceDarkAppearance {
            return Color.white.opacity(0.88)
        }
        return DesignTokens.Text.secondary
    }

    private var actionContextColor: Color {
        if forceDarkAppearance {
            return Color.white.opacity(0.72)
        }
        return DesignTokens.Text.secondary
    }

    private var detailLabelColor: Color {
        if forceDarkAppearance {
            return Color.white.opacity(0.55)
        }
        return DesignTokens.Text.tertiary
    }

    private var detailValueColor: Color {
        if forceDarkAppearance {
            return Color.white.opacity(0.82)
        }
        return DesignTokens.Text.secondary
    }

    private var resolvedAppIcon: NSImage? {
        if let trimmedName = appIconName?.trimmingCharacters(in: .whitespacesAndNewlines),
           !trimmedName.isEmpty,
           let namedIcon = NSImage(named: NSImage.Name(trimmedName)),
           namedIcon.isValid {
            return namedIcon
        }

        guard
            let trimmedPath = appIconPath?.trimmingCharacters(in: .whitespacesAndNewlines),
            !trimmedPath.isEmpty,
            FileManager.default.fileExists(atPath: trimmedPath)
        else {
            return nil
        }
        let appIcon = NSWorkspace.shared.icon(forFile: trimmedPath)
        return appIcon.isValid ? appIcon : nil
    }
}

#Preview {
    VStack(alignment: .leading, spacing: 16) {
        DSToast(
            icon: "checkmark.circle.fill",
            message: "Workspace saved",
            subtext: "All window positions were captured successfully.",
            iconColor: DesignTokens.Brand.accent,
            onClose: {}
        )

        DSToast(
            icon: "arrow.uturn.backward.circle.fill",
            message: "Workspace removed",
            subtext: "You can restore this action for the next 10 seconds.",
            iconColor: DesignTokens.Status.error,
            actionTitle: "Undo",
            action: {},
            onClose: {}
        )

        DSToast(
            icon: "waveform.circle.fill",
            message: "Launch app",
            subtext: "Executing in 3s",
            iconColor: .blue,
            forceDarkAppearance: true,
            actionTitle: "Cancel",
            action: {},
            onClose: {}
        )
    }
    .padding(32)
    .background(DesignTokens.Surface.window)
}
