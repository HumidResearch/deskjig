//
//  DSWorkspaceListItem.swift
//  DeskJig
//
//  Created by Claude Code on 02/02/26.
//

import SwiftUI
import AppKit
import KeyboardShortcuts
import DeskJigShared

struct DSWorkspaceNoticeAction: Identifiable {
    let id: String
    let title: String
    let subtitle: String?
    let action: () -> Void
}

/// An interactive workspace card component for listing workspaces.
/// Supports normal display mode and edit mode with inline editing.
struct DSWorkspaceListItem: View {
    // Data
    let name: String
    let icon: String
    let isFavorite: Bool
    var isSelected: Bool = false
    let screens: [DSPreviewScreen]
    let shortcut: String?
    var shortcutRecorderName: KeyboardShortcuts.Name? = nil
    var shortcutConflictNames: [KeyboardShortcuts.Name] = []
    var shortcutConflictLabelProvider: ((KeyboardShortcuts.Name) -> String)? = nil
    var statusTagLabel: String? = nil
    var noticeTitle: String? = nil
    var noticeMessage: String? = nil
    var noticeActionTitle: String? = nil
    var onNoticeAction: (() -> Void)? = nil
    var noticeActions: [DSWorkspaceNoticeAction] = []

    // Edit mode bindings
    @Binding var isEditing: Bool
    @Binding var editedName: String
    @Binding var editedIcon: String
    @Binding var selectedWindowId: UUID?

    // Selected window config bindings (for path-based apps: terminal/IDE)
    @Binding var selectedWindowPath: String
    var selectedWindowPathStatus: DSFolderVerificationStatus = .none
    var onVerifySelectedPath: ((String) -> Void)?
    var onClearSelectedPath: (() -> Void)?
    var onApplyPathToAll: (() -> Void)? = nil
    var onPathFocusChange: ((Bool) -> Void)? = nil

    // Chrome config bindings (for Chrome windows)
    @Binding var selectedChromeProfile: String?
    @Binding var selectedShouldRestoreTabs: Bool
    @Binding var selectedChromeTabs: [String]
    var chromeProfiles: [DSSelectOption<String>] = []
    /// Async callback for loading tabs. Return true on success, false on failure.
    var onLoadChromeTabs: (() async -> Bool)?
    var onAddChromeTab: ((String) -> Void)?
    var onRemoveChromeTab: ((Int) -> Void)?

    // Callbacks
    var onEditTapped: (() -> Void)?
    var onFavoriteTapped: (() -> Void)?
    var onSave: (() -> Void)?
    var onCancel: (() -> Void)?
    var onDelete: (() -> Void)?
    var onEditLayout: (() -> Void)? = nil
    var onDuplicateLayout: (() -> Void)? = nil
    var onRecordShortcut: (() -> Void)?
    var onClearShortcut: (() -> Void)?
    var onWindowTapped: ((DSPreviewWindow) -> Void)?

    @State private var isHovering = false
    @State private var isPickingIcon = false

    /// Standard height for header elements (36px)
    private let headerElementHeight: CGFloat = 36

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.gapRegular) {
            headerRow

            if isEditing {
                ScrollView {
                    VStack(alignment: .leading, spacing: DesignTokens.Spacing.gapRegular) {
                        helpTextRow

                        // Monitor previews - reuse existing DS components
                        DSScreenPreviewContainer(
                            screens: screens,
                            isInEditMode: isEditing,
                            selectedWindowId: selectedWindowId,
                            onWindowTapped: onWindowTapped
                        )

                        // Selected window panel
                        if let selectedId = selectedWindowId,
                           let selectedWindow = findWindow(id: selectedId) {
                            Divider()
                                .background(DesignTokens.Border.subtle)

                            selectedWindowHeader(for: selectedWindow)

                            DSWindowConfigPanel(
                                window: selectedWindow,
                                directoryPath: $selectedWindowPath,
                                pathVerificationStatus: selectedWindowPathStatus,
                                onVerifyPath: onVerifySelectedPath,
                                onClearPath: onClearSelectedPath,
                                onApplyPathToAll: onApplyPathToAll,
                                onPathFocusChange: onPathFocusChange,
                                chromeProfile: $selectedChromeProfile,
                                shouldRestoreTabs: $selectedShouldRestoreTabs,
                                chromeTabs: $selectedChromeTabs,
                                chromeProfiles: chromeProfiles,
                                onLoadTabs: onLoadChromeTabs,
                                onAddTab: onAddChromeTab,
                                onRemoveTab: onRemoveChromeTab,
                                onDismiss: { selectedWindowId = nil }
                            )
                        }

                        footerRow
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .scrollBounceBehavior(.basedOnSize)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            } else {
                // Monitor previews - reuse existing DS components
                DSScreenPreviewContainer(
                    screens: screens,
                    isInEditMode: isEditing,
                    selectedWindowId: selectedWindowId,
                    onWindowTapped: onWindowTapped
                )

                if let noticeTitle, let noticeMessage {
                    noticeView(title: noticeTitle, message: noticeMessage)
                }

                footerRow
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(DesignTokens.Card.padding)
        .dsCard(style: .workspace, isHighlighted: isHovering || isSelected)
        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Card.cornerRadius))
        .onHover { isHovering = $0 }
        .animation(.smooth(duration: 0.15), value: isHovering)
    }

    /// Find a window by ID across all screens
    private func findWindow(id: UUID) -> DSPreviewWindow? {
        for screen in screens {
            if let window = screen.windows.first(where: { $0.id == id }) {
                return window
            }
        }
        return nil
    }

    @ViewBuilder
    private func selectedWindowHeader(for window: DSPreviewWindow) -> some View {
        HStack(spacing: DesignTokens.Spacing.gapSmall) {
            Text("Selected:")
                .font(brand: .body3)
                .foregroundStyle(DesignTokens.Text.tertiary)
            Text(window.appName)
                .font(brand: .body3)
                .foregroundStyle(DesignTokens.Text.primary)
                .fontWeight(.medium)
        }
    }

    @ViewBuilder
    private var helpTextRow: some View {
        HStack(spacing: DesignTokens.Spacing.gapSmall) {
            Text("Click apps with glowing borders to configure special abilities")
                .font(brand: .body4)
                .foregroundStyle(DesignTokens.Text.tertiary)

            Image(systemName: "questionmark.circle")
                .font(.system(size: DesignTokens.IconSize.small))
                .foregroundStyle(DesignTokens.Text.muted)
                .help("Special apps like Chrome, IDEs, and terminals can be configured with additional abilities.")
        }
    }

    @ViewBuilder
    private var headerRow: some View {
        HStack(spacing: DesignTokens.Spacing.gapSmall) {
            if isEditing {
                // Edit mode: Icon picker + editable name + Save/Cancel
                emojiPickerButton

                DSTextField(
                    placeholder: "Workspace name",
                    text: $editedName,
                    accessibilityIdentifier: "workspace.name-field"
                )
                    .frame(maxWidth: 200)

                Spacer()

                HStack(spacing: DesignTokens.Spacing.gapSmall) {
                    // Cancel button - matches height of emoji picker/input
                    Button { onCancel?() } label: {
                        Text("Cancel")
                    }
                    .buttonStyle(.dsButton(variant: .secondary, size: .small))
                    .brightenOnHover()
                    .accessibilityIdentifier("workspace.editor.cancel-button")

                    // Save button - matches height of emoji picker/input
                    Button { onSave?() } label: {
                        Text("Save")
                    }
                    .buttonStyle(.dsButton(variant: .primary, size: .small))
                    .brightenOnHover()
                    .accessibilityIdentifier("workspace.editor.save-button")
                }
            } else {
                // Normal mode: icon + name + edit + favorite
                HStack(spacing: DesignTokens.Spacing.gapSmall) {
                    Text(icon).font(brand: .h4)
                    Text(name)
                        .font(brand: .body2)
                        .foregroundStyle(DesignTokens.Text.primary)
                    if let statusTagLabel {
                        DSTag(label: statusTagLabel, color: DesignTokens.Status.warning, size: .small)
                    }
                }
                Spacer()
                HStack(spacing: DesignTokens.Spacing.gapTiny) {
                    // Edit button - matches 28px height of favorite button
                    Button { onEditTapped?() } label: {
                        HStack(spacing: DesignTokens.Spacing.gapTiny) {
                            Image(systemName: "pencil")
                                .font(.system(size: DesignTokens.IconSize.small))
                            Text("Edit")
                                .font(brand: .body4)
                        }
                    }
                    .buttonStyle(.dsButton(variant: .secondary, size: .small))
                    .brightenOnHover()
                    .accessibilityIdentifier("workspace.card.edit-button")
                    .accessibilityValue(name)

                    Button { onFavoriteTapped?() } label: {
                        Image(systemName: isFavorite ? "star.fill" : "star")
                    }
                    .buttonStyle(.dsFavorite(isSelected: isFavorite))
                    .accessibilityIdentifier("workspace.card.favorite-button")
                    .accessibilityValue(name)
                }
            }
        }
    }

    @ViewBuilder
    private func noticeView(title: String, message: String) -> some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.gapSmall) {
            HStack(alignment: .center, spacing: DesignTokens.Spacing.gapSmall) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: DesignTokens.IconSize.small, weight: .semibold))
                    .foregroundStyle(DesignTokens.Status.warning)

                Text(title)
                    .font(brand: .body3)
                    .foregroundStyle(DesignTokens.Text.primary)
            }

            Text(message)
                .font(brand: .body4)
                .foregroundStyle(DesignTokens.Text.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if !noticeActions.isEmpty {
                VStack(alignment: .leading, spacing: DesignTokens.Spacing.gapSmall) {
                    ForEach(noticeActions) { action in
                        Button {
                            action.action()
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(action.title)
                                    .font(brand: .label3)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                if let subtitle = action.subtitle, !subtitle.isEmpty {
                                    Text(subtitle)
                                        .font(brand: .body4)
                                        .foregroundStyle(DesignTokens.Text.secondary)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                            }
                        }
                        .buttonStyle(.dsButton(variant: .secondary, size: .small))
                        .brightenOnHover()
                    }
                }
            } else if let noticeActionTitle, let onNoticeAction {
                Button {
                    onNoticeAction()
                } label: {
                    HStack(spacing: DesignTokens.Spacing.gapTiny) {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: DesignTokens.IconSize.tiny, weight: .medium))
                        Text(noticeActionTitle)
                            .font(brand: .label3)
                    }
                }
                .buttonStyle(.dsButton(variant: .warning, size: .small))
                .brightenOnHover()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(DesignTokens.Card.paddingCompact)
        .background(DesignTokens.Status.warning.opacity(0.10))
        .overlay(
            RoundedRectangle(cornerRadius: DesignTokens.CornerRadius.medium)
                .stroke(DesignTokens.Status.warning.opacity(0.32), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.CornerRadius.medium))
    }

    private var emojiPickerButton: some View {
        Button { isPickingIcon = true } label: {
            Text(editedIcon)
                .font(brand: .h4)
                .frame(width: headerElementHeight, height: headerElementHeight)
                .background {
                    RoundedRectangle(cornerRadius: DesignTokens.CornerRadius.medium)
                        .fill(DesignTokens.Surface.card)
                }
                .overlay {
                    RoundedRectangle(cornerRadius: DesignTokens.CornerRadius.medium)
                        .stroke(DesignTokens.Border.regular, lineWidth: 1)
                }
        }
        .buttonStyle(.plain)
        .brightenOnHover()
        .popover(isPresented: $isPickingIcon) {
            DSEmojiPicker(selectedEmoji: $editedIcon, isPresented: $isPickingIcon)
        }
    }

    @ViewBuilder
    private var hotkeyBadge: some View {
        if let shortcutRecorderName {
            DSHotkeyBadge(
                shortcut: shortcut,
                onTap: onRecordShortcut,
                onClear: onClearShortcut,
                shortcutName: shortcutRecorderName
            ) {
                DSHotkeyRecorderPopover(
                    name: shortcutRecorderName,
                    conflictNames: shortcutConflictNames,
                    conflictLabelProvider: shortcutConflictLabelProvider
                )
            }
        } else {
            DSHotkeyBadge(shortcut: shortcut, onTap: onRecordShortcut, onClear: onClearShortcut)
        }
    }

    @ViewBuilder
    private var footerRow: some View {
        HStack(spacing: DesignTokens.Spacing.gapSmall) {
            Spacer()

            if isEditing {
                if let onDuplicateLayout {
                    Button {
                        onDuplicateLayout()
                    } label: {
                        HStack(spacing: DesignTokens.Spacing.gapTiny) {
                            Image(systemName: "square.on.square")
                                .font(.system(size: DesignTokens.IconSize.tiny, weight: .medium))
                            Text("Duplicate layout")
                                .font(brand: .label3)
                        }
                    }
                    .buttonStyle(.dsButton(variant: .secondary, size: .small))
                    .brightenOnHover()
                }

                if let onEditLayout {
                    Button {
                        onEditLayout()
                    } label: {
                        HStack(spacing: DesignTokens.Spacing.gapTiny) {
                            Image(systemName: "rectangle.split.2x1")
                                .font(.system(size: DesignTokens.IconSize.tiny, weight: .medium))
                            Text("Edit layout")
                                .font(brand: .label3)
                        }
                    }
                    .buttonStyle(.dsButton(variant: .secondary, size: .small))
                    .brightenOnHover()
                }
            }

            hotkeyBadge

            if isEditing, onDelete != nil {
                Button {
                    onDelete?()
                } label: {
                    HStack(spacing: DesignTokens.Spacing.gapTiny) {
                        Image(systemName: "trash")
                            .font(.system(size: DesignTokens.IconSize.tiny, weight: .medium))
                        Text("Delete")
                            .font(brand: .label3)
                    }
                }
                .buttonStyle(.dsButton(variant: .danger, size: .small))
                .accessibilityIdentifier("workspace.editor.delete-button")
            }
        }
    }
}

// MARK: - Convenience Initializer (backwards compatibility)

extension DSWorkspaceListItem {
    /// Convenience initializer without Chrome config bindings (for path-only usage)
    init(
        name: String,
        icon: String,
        isFavorite: Bool,
        isSelected: Bool = false,
        screens: [DSPreviewScreen],
        shortcut: String?,
        shortcutRecorderName: KeyboardShortcuts.Name? = nil,
        shortcutConflictNames: [KeyboardShortcuts.Name] = [],
        shortcutConflictLabelProvider: ((KeyboardShortcuts.Name) -> String)? = nil,
        isEditing: Binding<Bool>,
        editedName: Binding<String>,
        editedIcon: Binding<String>,
        selectedWindowId: Binding<UUID?>,
        selectedWindowPath: Binding<String>,
        selectedWindowPathStatus: DSFolderVerificationStatus = .none,
        onVerifySelectedPath: ((String) -> Void)? = nil,
        onClearSelectedPath: (() -> Void)? = nil,
        onEditTapped: (() -> Void)? = nil,
        onFavoriteTapped: (() -> Void)? = nil,
        onSave: (() -> Void)? = nil,
        onCancel: (() -> Void)? = nil,
        onRecordShortcut: (() -> Void)? = nil,
        onWindowTapped: ((DSPreviewWindow) -> Void)? = nil
    ) {
        self.name = name
        self.icon = icon
        self.isFavorite = isFavorite
        self.isSelected = isSelected
        self.screens = screens
        self.shortcut = shortcut
        self.shortcutRecorderName = shortcutRecorderName
        self.shortcutConflictNames = shortcutConflictNames
        self.shortcutConflictLabelProvider = shortcutConflictLabelProvider
        self.statusTagLabel = nil
        self.noticeTitle = nil
        self.noticeMessage = nil
        self.noticeActionTitle = nil
        self.onNoticeAction = nil
        self.noticeActions = []
        self._isEditing = isEditing
        self._editedName = editedName
        self._editedIcon = editedIcon
        self._selectedWindowId = selectedWindowId
        self._selectedWindowPath = selectedWindowPath
        self.selectedWindowPathStatus = selectedWindowPathStatus
        self.onVerifySelectedPath = onVerifySelectedPath
        self.onClearSelectedPath = onClearSelectedPath
        // Chrome defaults
        self._selectedChromeProfile = .constant(nil)
        self._selectedShouldRestoreTabs = .constant(false)
        self._selectedChromeTabs = .constant([])
        self.chromeProfiles = []
        self.onLoadChromeTabs = nil
        self.onAddChromeTab = nil
        self.onRemoveChromeTab = nil
        self.onEditTapped = onEditTapped
        self.onFavoriteTapped = onFavoriteTapped
        self.onSave = onSave
        self.onCancel = onCancel
        self.onDelete = nil
        self.onEditLayout = nil
        self.onDuplicateLayout = nil
        self.onRecordShortcut = onRecordShortcut
        self.onClearShortcut = nil
        self.onWindowTapped = onWindowTapped
    }

    /// Convenience initializer without any window config bindings
    init(
        name: String,
        icon: String,
        isFavorite: Bool,
        isSelected: Bool = false,
        screens: [DSPreviewScreen],
        shortcut: String?,
        isEditing: Binding<Bool>,
        editedName: Binding<String>,
        editedIcon: Binding<String>,
        selectedWindowId: Binding<UUID?>,
        onEditTapped: (() -> Void)? = nil,
        onFavoriteTapped: (() -> Void)? = nil,
        onSave: (() -> Void)? = nil,
        onCancel: (() -> Void)? = nil,
        onRecordShortcut: (() -> Void)? = nil,
        onWindowTapped: ((DSPreviewWindow) -> Void)? = nil
    ) {
        self.name = name
        self.icon = icon
        self.isFavorite = isFavorite
        self.isSelected = isSelected
        self.screens = screens
        self.shortcut = shortcut
        self.statusTagLabel = nil
        self.noticeTitle = nil
        self.noticeMessage = nil
        self.noticeActionTitle = nil
        self.onNoticeAction = nil
        self.noticeActions = []
        self._isEditing = isEditing
        self._editedName = editedName
        self._editedIcon = editedIcon
        self._selectedWindowId = selectedWindowId
        self._selectedWindowPath = .constant("")
        self.selectedWindowPathStatus = .none
        self.onVerifySelectedPath = nil
        self.onClearSelectedPath = nil
        // Chrome defaults
        self._selectedChromeProfile = .constant(nil)
        self._selectedShouldRestoreTabs = .constant(false)
        self._selectedChromeTabs = .constant([])
        self.chromeProfiles = []
        self.onLoadChromeTabs = nil
        self.onAddChromeTab = nil
        self.onRemoveChromeTab = nil
        self.onEditTapped = onEditTapped
        self.onFavoriteTapped = onFavoriteTapped
        self.onSave = onSave
        self.onCancel = onCancel
        self.onDelete = nil
        self.onEditLayout = nil
        self.onDuplicateLayout = nil
        self.onRecordShortcut = onRecordShortcut
        self.onClearShortcut = nil
        self.onWindowTapped = onWindowTapped
    }
}

// MARK: - Preview

#Preview("Workspace List Item") {
    VStack(spacing: 24) {
        Text("Workspace List Items")
            .font(brand: .h3)
            .foregroundStyle(DesignTokens.Text.primary)

        // Normal mode
        DSWorkspaceListItem(
            name: "Research",
            icon: "🔍",
            isFavorite: true,
            screens: [
                DSPreviewScreen(
                    id: 0,
                    title: "Display",
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
                            appName: "Notes",
                            xPercent: 0.5,
                            yPercent: 0.0,
                            widthPercent: 0.5,
                            heightPercent: 1.0
                        )
                    ]
                )
            ],
            shortcut: "⌘1",
            isEditing: .constant(false),
            editedName: .constant("Research"),
            editedIcon: .constant("🔍"),
            selectedWindowId: .constant(nil)
        )
        .frame(width: 400)

        // Edit mode
        DSWorkspaceListItem(
            name: "Development",
            icon: "💻",
            isFavorite: false,
            screens: [
                DSPreviewScreen(
                    id: 0,
                    title: "Display",
                    isPrimary: true,
                    windows: [
                        DSPreviewWindow(
                            appName: "VS Code",
                            xPercent: 0.0,
                            yPercent: 0.0,
                            widthPercent: 0.6,
                            heightPercent: 1.0,
                            specialAppType: .ide
                        ),
                        DSPreviewWindow(
                            appName: "Terminal",
                            xPercent: 0.6,
                            yPercent: 0.0,
                            widthPercent: 0.4,
                            heightPercent: 1.0
                        )
                    ]
                )
            ],
            shortcut: nil,
            isEditing: .constant(true),
            editedName: .constant("Development"),
            editedIcon: .constant("💻"),
            selectedWindowId: .constant(nil)
        )
        .frame(width: 400)
    }
    .padding(32)
    .background(Color.black.opacity(0.9))
}
