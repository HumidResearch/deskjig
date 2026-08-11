//
//  DSKeyboardShortcut.swift
//  DeskJig
//
//  Created by Claude Code on 02/02/26.
//

import SwiftUI
import Foundation
import KeyboardShortcuts
import DeskJigShared

// MARK: - Key Badge

/// A single key badge that displays a keyboard key.
/// Matches the React design system kbd styling with subtle bottom shadow.
struct DSKeyBadge: View {
    let key: String
    var size: DSKeyBadgeSize = .medium

    var body: some View {
        Text(key)
            .font(brand: size.font)
            .foregroundStyle(DesignTokens.Text.primary)
            .padding(.horizontal, size.horizontalPadding)
            .padding(.vertical, size.verticalPadding)
            .frame(minWidth: size.minWidth)
            .background {
                RoundedRectangle(cornerRadius: DesignTokens.CornerRadius.small)
                    .fill(DesignTokens.Surface.elevated)
            }
            .overlay {
                RoundedRectangle(cornerRadius: DesignTokens.CornerRadius.small)
                    .stroke(DesignTokens.Border.subtle, lineWidth: 1)
            }
            // Subtle bottom shadow for "raised key" effect
            .shadow(color: .black.opacity(0.15), radius: 0, x: 0, y: 1)
    }
}

/// Size variants for key badges
enum DSKeyBadgeSize {
    case small
    case medium
    case large

    @MainActor var font: Font.BrandFont {
        switch self {
        case .small: return .body4
        case .medium: return .body3
        case .large: return .body2
        }
    }

    var horizontalPadding: CGFloat {
        switch self {
        case .small: return 4
        case .medium: return 6
        case .large: return 8
        }
    }

    var verticalPadding: CGFloat {
        switch self {
        case .small: return 2
        case .medium: return 3
        case .large: return 4
        }
    }

    /// Minimum width for consistent badge sizing across single characters and words
    var minWidth: CGFloat {
        switch self {
        case .small: return 22
        case .medium: return 26
        case .large: return 30
        }
    }
}

// MARK: - Keyboard Shortcut Display

/// A read-only keyboard shortcut display showing multiple key badges with "+" separator.
/// Example: ⌘ + Shift + K
struct DSKeyboardShortcut: View {
    let keys: [String]
    var size: DSKeyBadgeSize = .medium

    init(keys: [String], size: DSKeyBadgeSize = .medium) {
        self.keys = keys
        self.size = size
    }

    /// Convenience initializer from a shortcut string like "⌘⇧K"
    init(shortcut: String, size: DSKeyBadgeSize = .medium) {
        self.keys = Self.parseShortcut(shortcut)
        self.size = size
    }

    var body: some View {
        HStack(spacing: 4) {
            ForEach(Array(keys.enumerated()), id: \.offset) { index, key in
                if index > 0 {
                    Text("+")
                        .font(brand: size.font)
                        .foregroundStyle(DesignTokens.Text.muted)
                }
                DSKeyBadge(key: key, size: size)
            }
        }
    }

    /// Parse a shortcut string into individual key components
    private static func parseShortcut(_ shortcut: String) -> [String] {
        var keys: [String] = []
        var remainingChars = shortcut

        // Map of modifier symbols to display names
        let modifierMap: [(String, String)] = [
            ("⌘", "⌘"),
            ("⇧", "⇧"),
            ("⌥", "⌥"),
            ("⌃", "⌃"),
            ("⇪", "⇪")
        ]

        // Extract modifiers first
        for (symbol, display) in modifierMap {
            if remainingChars.contains(symbol) {
                keys.append(display)
                remainingChars = remainingChars.replacingOccurrences(of: symbol, with: "")
            }
        }

        // Remaining characters are the main key(s)
        let trimmed = remainingChars.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty {
            keys.append(trimmed.uppercased())
        }

        return keys
    }
}

// MARK: - Hotkey Badge

/// Compact hotkey badge for card footers - shows shortcut or "Record" placeholder.
/// Features:
/// - Shows help tooltip explaining functionality
/// - Shows a popover for recording/editing the shortcut
/// - When unset: "Record" button with dashed border
struct DSHotkeyBadge<PopoverContent: View>: View {
    let shortcut: String?  // nil = show "Record" button
    var size: DSKeyBadgeSize = .small
    var showHelpIcon: Bool = true
    var onTap: (() -> Void)? = nil
    var onClear: (() -> Void)? = nil
    var shortcutName: KeyboardShortcuts.Name? = nil
    @ViewBuilder var popoverContent: () -> PopoverContent

    @State private var isHovering = false
    @State private var showingPopover = false
    @State private var showingHelpPopover = false
    @State private var isHoveringHelpIcon = false
    @State private var isHoveringHelpPopover = false
    @State private var isHelpPopoverPinned = false
    @State private var storedShortcut: String? = nil
    @State private var pendingHelpPopoverClose: DispatchWorkItem? = nil

    init(
        shortcut: String?,
        size: DSKeyBadgeSize = .small,
        showHelpIcon: Bool = true,
        onTap: (() -> Void)? = nil,
        onClear: (() -> Void)? = nil,
        shortcutName: KeyboardShortcuts.Name? = nil,
        @ViewBuilder popoverContent: @escaping () -> PopoverContent
    ) {
        self.shortcut = shortcut
        self.size = size
        self.showHelpIcon = showHelpIcon
        self.onTap = onTap
        self.onClear = onClear
        self.shortcutName = shortcutName
        self.popoverContent = popoverContent
    }

    private var resolvedShortcut: String? {
        storedShortcut ?? shortcut
    }

    private var hasShortcut: Bool {
        resolvedShortcut != nil && !resolvedShortcut!.isEmpty
    }

    private var shouldShowHelpIcon: Bool {
        showHelpIcon && (
            isHovering ||
            !hasShortcut ||
            isHoveringHelpIcon ||
            isHoveringHelpPopover ||
            showingHelpPopover ||
            isHelpPopoverPinned
        )
    }

    var body: some View {
        HStack(spacing: DesignTokens.Spacing.gapSmall) {
            // Help icon with tooltip (only when hovering or unset)
            if shouldShowHelpIcon {
                ZStack {
                    // Non-zero alpha fill ensures the full circle hit target is interactive.
                    Circle()
                        .fill(Color.primary.opacity(0.001))

                    Image(systemName: "questionmark.circle")
                        .font(.system(size: DesignTokens.IconSize.tiny))
                        .foregroundStyle(DesignTokens.Text.muted)
                }
                .frame(width: 24, height: 24)
                .contentShape(Circle())
                .onTapGesture {
                    if isHelpPopoverPinned {
                        isHelpPopoverPinned = false
                        syncHelpPopoverVisibility()
                    } else {
                        isHelpPopoverPinned = true
                        showingHelpPopover = true
                    }
                }
                .popover(isPresented: helpPopoverBinding, attachmentAnchor: .point(.top), arrowEdge: .bottom) {
                    helpPopoverContent
                }
                .onHover { hovering in
                    isHoveringHelpIcon = hovering
                    syncHelpPopoverVisibility()
                }
            }

            // Badge content
            Button {
                if showsPopover {
                    showingPopover = true
                }
                onTap?()
            } label: {
                badgeContent
            }
            .buttonStyle(.plain)
            .brightenOnHover()
            .help(helpText)
            .popover(isPresented: popoverBinding) {
                popoverContent()
            }
            .fixedSize()
        }
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                isHovering = hovering
            }
        }
        .onAppear(perform: refreshStoredShortcut)
        .onChange(of: isHovering) { _, hovering in
            if !hovering && hasShortcut {
                isHoveringHelpIcon = false
                isHoveringHelpPopover = false
                isHelpPopoverPinned = false
                showingHelpPopover = false
                pendingHelpPopoverClose?.cancel()
                pendingHelpPopoverClose = nil
            }
        }
        .onChange(of: showingPopover) { _, isPresented in
            if !isPresented {
                refreshStoredShortcut()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)) { _ in
            if shortcutName != nil {
                refreshStoredShortcut()
            }
        }
    }

    private var helpText: String {
        if hasShortcut {
            return "Press this shortcut to open this workspace quickly.\nClick to record a new shortcut."
        } else {
            return "Record a shortcut to open this workspace quickly.\nClick this control to start recording."
        }
    }

    private var helpPopoverContent: some View {
        Text(helpText)
            .font(brand: .body4)
            .foregroundStyle(DesignTokens.Text.primary)
            .multilineTextAlignment(.leading)
            .lineSpacing(2)
            .frame(width: 250, alignment: .leading)
            .padding(12)
            .onHover { hovering in
                isHoveringHelpPopover = hovering
                syncHelpPopoverVisibility()
            }
    }

    private var helpPopoverBinding: Binding<Bool> {
        Binding(
            get: { showingHelpPopover },
            set: { isPresented in
                showingHelpPopover = isPresented
                if isPresented { return }
                isHelpPopoverPinned = false
                if !isHoveringHelpIcon && !isHoveringHelpPopover {
                    isHoveringHelpIcon = false
                    isHoveringHelpPopover = false
                }
            }
        )
    }

    private func syncHelpPopoverVisibility() {
        pendingHelpPopoverClose?.cancel()
        pendingHelpPopoverClose = nil

        if isHelpPopoverPinned || isHoveringHelpIcon || isHoveringHelpPopover {
            showingHelpPopover = true
            return
        }

        let closeWorkItem = DispatchWorkItem {
            if !isHelpPopoverPinned && !isHoveringHelpIcon && !isHoveringHelpPopover {
                showingHelpPopover = false
            }
        }
        pendingHelpPopoverClose = closeWorkItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: closeWorkItem)
    }

    @ViewBuilder
    private var badgeContent: some View {
        if hasShortcut {
            DSKeyboardShortcut(shortcut: resolvedShortcut!, size: size)
        } else {
            HStack(spacing: DesignTokens.Spacing.gapTiny) {
                Image(systemName: "keyboard")
                    .font(.system(size: DesignTokens.IconSize.tiny))
                Text("Record")
                    .font(brand: size.font)
            }
            .foregroundStyle(DesignTokens.Text.tertiary)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background {
                RoundedRectangle(cornerRadius: DesignTokens.CornerRadius.medium)
                    .fill(DesignTokens.Surface.card)
            }
            .overlay {
                RoundedRectangle(cornerRadius: DesignTokens.CornerRadius.medium)
                    .stroke(DesignTokens.Border.subtle,
                            style: StrokeStyle(lineWidth: 1, dash: [4, 2]))
            }
        }
    }

    private var showsPopover: Bool {
        PopoverContent.self != EmptyView.self
    }

    private var popoverBinding: Binding<Bool> {
        Binding(
            get: { showsPopover && showingPopover },
            set: { showingPopover = $0 }
        )
    }

    private func refreshStoredShortcut() {
        guard let shortcutName else {
            storedShortcut = nil
            return
        }
        storedShortcut = Self.shortcutString(for: shortcutName)
    }

    private static func shortcutString(for name: KeyboardShortcuts.Name) -> String? {
        guard let shortcut = KeyboardShortcuts.getShortcut(for: name) else {
            return nil
        }
        return shortcutString(shortcut)
    }

    private static func shortcutString(_ shortcut: KeyboardShortcuts.Shortcut) -> String {
        var parts: [String] = []
        if shortcut.modifiers.contains(.control) {
            parts.append("⌃")
        }
        if shortcut.modifiers.contains(.option) {
            parts.append("⌥")
        }
        if shortcut.modifiers.contains(.shift) {
            parts.append("⇧")
        }
        if shortcut.modifiers.contains(.command) {
            parts.append("⌘")
        }
        if let key = shortcut.key?.stringValue.uppercased(), !key.isEmpty {
            parts.append(key)
        }
        return parts.joined()
    }
}

extension DSHotkeyBadge where PopoverContent == EmptyView {
    init(
        shortcut: String?,
        size: DSKeyBadgeSize = .small,
        showHelpIcon: Bool = true,
        onTap: (() -> Void)? = nil,
        onClear: (() -> Void)? = nil,
        shortcutName: KeyboardShortcuts.Name? = nil
    ) {
        self.init(
            shortcut: shortcut,
            size: size,
            showHelpIcon: showHelpIcon,
            onTap: onTap,
            onClear: onClear,
            shortcutName: shortcutName,
            popoverContent: { EmptyView() }
        )
    }
}

// MARK: - Hotkey Badge Popover

/// Shared popover content for DSHotkeyBadge in the design system.
/// Mirrors the WorkspaceCardView recorder layout.
struct DSHotkeyRecorderPopover: View {
    let name: KeyboardShortcuts.Name
    var conflictNames: [KeyboardShortcuts.Name] = []
    var conflictLabelProvider: ((KeyboardShortcuts.Name) -> String)? = nil

    @State private var conflictMessage: String? = nil
    @State private var didDisableShortcuts: Bool = false
    @State private var initialShortcut: KeyboardShortcuts.Shortcut? = nil
    @State private var isRevertingConflict: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Record Shortcut")
                .font(brand: .h4)
                .foregroundStyle(DesignTokens.Text.primary)

            KeyboardShortcuts.Recorder(for: name, onChange: handleShortcutChange)
                .frame(width: 150)

            Text("Press your desired key combination")
                .font(brand: .body3)
                .foregroundStyle(DesignTokens.Text.secondary)

            if let conflictMessage {
                DSStatusLabel(
                    text: conflictMessage,
                    systemIcon: "exclamationmark.triangle.fill",
                    color: DesignTokens.Status.warning,
                    font: .body4,
                    iconSize: DesignTokens.IconSize.tiny
                )
            }
        }
        .padding(16)
        .background {
            RoundedRectangle(cornerRadius: DesignTokens.CornerRadius.xLarge)
                .fill(DesignTokens.Surface.panel)
        }
        .overlay {
            RoundedRectangle(cornerRadius: DesignTokens.CornerRadius.xLarge)
                .stroke(DesignTokens.Border.regular, lineWidth: 1)
        }
        .onAppear {
            initialShortcut = KeyboardShortcuts.getShortcut(for: name)
            refreshConflictState()
            disableWorkspaceShortcuts()
        }
        .onDisappear {
            restoreWorkspaceShortcuts()
        }
        .onReceive(NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)) { _ in
            if !conflictNames.isEmpty {
                refreshConflictState()
            }
        }
    }

    private func handleShortcutChange(_ shortcut: KeyboardShortcuts.Shortcut?) {
        if isRevertingConflict {
            isRevertingConflict = false
            return
        }

        if let message = conflictMessage(for: shortcut) {
            conflictMessage = message
            isRevertingConflict = true
            KeyboardShortcuts.setShortcut(initialShortcut, for: name)
            return
        }

        conflictMessage = nil
        initialShortcut = shortcut
    }

    private func refreshConflictState() {
        conflictMessage = conflictMessage(for: KeyboardShortcuts.getShortcut(for: name))
    }

    private func conflictMessage(for shortcut: KeyboardShortcuts.Shortcut?) -> String? {
        guard let shortcut, !conflictNames.isEmpty else {
            return nil
        }

        for other in conflictNames where other != name {
            if KeyboardShortcuts.getShortcut(for: other) == shortcut {
                return conflictLabelProvider?(other) ?? "Shortcut already assigned"
            }
        }

        return nil
    }

    private var allShortcutNames: [KeyboardShortcuts.Name] {
        var names = conflictNames
        if !names.contains(name) {
            names.append(name)
        }
        return names
    }

    private func disableWorkspaceShortcuts() {
        guard !didDisableShortcuts else { return }
        didDisableShortcuts = true
        for shortcutName in allShortcutNames {
            KeyboardShortcuts.disable(shortcutName)
        }
    }

    private func restoreWorkspaceShortcuts() {
        guard didDisableShortcuts else { return }
        didDisableShortcuts = false
        for shortcutName in allShortcutNames {
            KeyboardShortcuts.enable(shortcutName)
        }
    }
}

// MARK: - Keyboard Shortcut Recorder

/// An interactive keyboard shortcut recorder that displays the current shortcut
/// as individual key badges with a clear (X) button.
/// Styled to match DSHotkeyBadge for visual consistency.
struct DSKeyboardShortcutRecorder: View {
    @Binding var shortcut: String?
    var placeholder: String = "Record shortcut"
    var size: DSKeyBadgeSize = .medium
    var onRecord: (() -> Void)? = nil
    var onClear: (() -> Void)? = nil

    @State private var isRecording = false
    @State private var isHovering = false

    private var hasShortcut: Bool {
        shortcut != nil && !shortcut!.isEmpty
    }

    var body: some View {
        HStack(spacing: DesignTokens.Spacing.gapSmall) {
            if hasShortcut {
                // Shortcut is set - show with menu for change/clear
                Menu {
                    Button {
                        isRecording = true
                        onRecord?()
                    } label: {
                        Label("Change Shortcut", systemImage: "keyboard")
                    }

                    Divider()

                    Button(role: .destructive) {
                        shortcut = nil
                        onClear?()
                    } label: {
                        Label("Clear Shortcut", systemImage: "trash")
                    }
                } label: {
                    DSKeyboardShortcut(shortcut: shortcut!, size: size)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
            } else {
                // No shortcut - show "Record" button with dashed border
                Button {
                    isRecording = true
                    onRecord?()
                } label: {
                    HStack(spacing: DesignTokens.Spacing.gapTiny) {
                        Image(systemName: "keyboard")
                            .font(.system(size: DesignTokens.IconSize.tiny))
                        Text(isRecording ? "Type shortcut..." : placeholder)
                            .font(brand: size.font)
                    }
                    .foregroundStyle(isRecording ? DesignTokens.Text.secondary : DesignTokens.Text.tertiary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background {
                        RoundedRectangle(cornerRadius: DesignTokens.CornerRadius.medium)
                            .fill(DesignTokens.Surface.card)
                    }
                    .overlay {
                        RoundedRectangle(cornerRadius: DesignTokens.CornerRadius.medium)
                            .stroke(
                                isRecording ? DesignTokens.Brand.accent : DesignTokens.Border.subtle,
                                style: StrokeStyle(lineWidth: 1, dash: isRecording ? [] : [4, 2])
                            )
                    }
                }
                .buttonStyle(.plain)
                .brightenOnHover()
            }
        }
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                isHovering = hovering
            }
        }
    }
}

// MARK: - Preview

#Preview("Keyboard Shortcuts") {
    let previewHotkeyOne = KeyboardShortcuts.Name("designSystem.preview.hotkey.one")
    let previewHotkeyTwo = KeyboardShortcuts.Name("designSystem.preview.hotkey.two")
    let previewHotkeyEmpty = KeyboardShortcuts.Name("designSystem.preview.hotkey.empty")

    VStack(alignment: .leading, spacing: 24) {
        Text("Keyboard Shortcuts")
            .font(brand: .h3)
            .foregroundStyle(DesignTokens.Text.primary)

        // Individual key badges
        VStack(alignment: .leading, spacing: 12) {
            Text("Key Badges")
                .font(brand: .label2)
                .foregroundStyle(DesignTokens.Text.secondary)

            HStack(spacing: 8) {
                DSKeyBadge(key: "⌘", size: .small)
                DSKeyBadge(key: "⇧", size: .medium)
                DSKeyBadge(key: "K", size: .large)
            }

            HStack(spacing: 8) {
                DSKeyBadge(key: "⌥")
                DSKeyBadge(key: "⌃")
                DSKeyBadge(key: "Space")
                DSKeyBadge(key: "Enter")
            }
        }

        Divider()
            .background(DesignTokens.Border.subtle)

        // Keyboard shortcut displays
        VStack(alignment: .leading, spacing: 12) {
            Text("Shortcut Displays")
                .font(brand: .label2)
                .foregroundStyle(DesignTokens.Text.secondary)

            DSKeyboardShortcut(keys: ["⌘", "K"])
            DSKeyboardShortcut(keys: ["⌘", "⇧", "P"])
            DSKeyboardShortcut(shortcut: "⌘⇧K")
            DSKeyboardShortcut(shortcut: "⌥⌃Space", size: .small)
        }

        Divider()
            .background(DesignTokens.Border.subtle)

        // Recorder
        VStack(alignment: .leading, spacing: 12) {
            Text("Shortcut Recorder")
                .font(brand: .label2)
                .foregroundStyle(DesignTokens.Text.secondary)

            DSKeyboardShortcutRecorder(shortcut: .constant("⌘⇧W"))
            DSKeyboardShortcutRecorder(shortcut: .constant(nil), placeholder: "Click to record")
        }

        Divider()
            .background(DesignTokens.Border.subtle)

        // Hotkey badges
        VStack(alignment: .leading, spacing: 12) {
            Text("Hotkey Badges")
                .font(brand: .label2)
                .foregroundStyle(DesignTokens.Text.secondary)

            Text("With shortcut (click for popover):")
                .font(brand: .body4)
                .foregroundStyle(DesignTokens.Text.tertiary)

            HStack(spacing: 12) {
                DSHotkeyBadge(shortcut: "⌘1", onTap: { }, onClear: { }, shortcutName: previewHotkeyOne) {
                    DSHotkeyRecorderPopover(name: previewHotkeyOne)
                }
                DSHotkeyBadge(shortcut: "⌘⇧W", onTap: { }, onClear: { }, shortcutName: previewHotkeyTwo) {
                    DSHotkeyRecorderPopover(name: previewHotkeyTwo)
                }
            }

            Text("Without shortcut (unset state):")
                .font(brand: .body4)
                .foregroundStyle(DesignTokens.Text.tertiary)

            HStack(spacing: 12) {
                DSHotkeyBadge(shortcut: nil, onTap: { }, shortcutName: previewHotkeyEmpty) {
                    DSHotkeyRecorderPopover(name: previewHotkeyEmpty)
                }
            }

            Text("Hover to see help icon")
                .font(brand: .body4)
                .foregroundStyle(DesignTokens.Text.muted)
        }
    }
    .padding(32)
    .background(Color.black.opacity(0.9))
}
