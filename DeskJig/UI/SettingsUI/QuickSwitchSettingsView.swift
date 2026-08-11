//  QuickSwitchSettingsView.swift
//  DeskJig

import SwiftUI
import DeskJigShared

struct QuickSwitchSettingsView: View {
    @Bindable var viewModel: QuickSwitchViewModel
    @EnvironmentObject var windowManager: WindowManager

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.gapMedium) {
            // Section header
            Text("Settings")
                .font(brand: .h4)
                .foregroundStyle(DesignTokens.Text.primary)

            HStack(spacing: DesignTokens.Spacing.gapRegular) {
                Text("Quick Switch Shortcut")
                    .font(brand: .body3)
                    .foregroundStyle(DesignTokens.Text.secondary)

                Spacer()

                QuickSwitchShortcutRecorder(showHelpIcon: true)
            }

            Divider()
                .background(DesignTokens.Border.subtle)

            // Root folders list
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.gapRegular) {
                Text("Root Folders")
                    .font(brand: .body3)
                    .foregroundStyle(DesignTokens.Text.secondary)

                if viewModel.rootFolders.isEmpty {
                    Text("No root folders configured")
                        .font(brand: .body4)
                        .foregroundStyle(DesignTokens.Text.tertiary)
                        .padding(.vertical, DesignTokens.Spacing.gapSmall)
                } else {
                    VStack(spacing: DesignTokens.Spacing.gapTiny) {
                        ForEach(viewModel.rootFolders) { folder in
                            rootFolderRow(folder)
                        }
                    }
                }

                Button {
                    showFolderPicker()
                } label: {
                    HStack(spacing: DesignTokens.Spacing.gapSmall) {
                        Image(systemName: "plus")
                            .font(.system(size: DesignTokens.IconSize.small, weight: .medium))
                        Text("Add Folder")
                            .font(brand: .body4)
                    }
                    .foregroundStyle(DesignTokens.Text.secondary)
                    .padding(.horizontal, DesignTokens.Spacing.itemPaddingHorizontal)
                    .padding(.vertical, DesignTokens.Spacing.gapSmall)
                    .background {
                        RoundedRectangle(cornerRadius: 6)
                            .fill(DesignTokens.Surface.card)
                    }
                }
                .buttonStyle(.plain)
                .brightenOnHover(0.1)
            }

            Divider()
                .background(DesignTokens.Border.subtle)

            // Global default workspace
            HStack(spacing: DesignTokens.Spacing.gapRegular) {
                Text("Default Layout")
                    .font(brand: .body3)
                    .foregroundStyle(DesignTokens.Text.secondary)

                Picker("", selection: Binding(
                    get: { viewModel.globalDefaultWorkspaceId ?? "" },
                    set: { newValue in
                        viewModel.globalDefaultWorkspaceId = newValue.isEmpty ? nil : newValue
                    }
                )) {
                    Text("Use first saved layout")
                        .tag("")
                    ForEach(windowManager.savedWorkspaces) { workspace in
                        Text(workspace.name)
                            .tag(workspace.id.uuidString)
                    }
                }
                .pickerStyle(.menu)
                .frame(maxWidth: 250)
            }

            Divider()
                .background(DesignTokens.Border.subtle)

            Text("Quick Switch respects the ignored displays configured in Workspace Restoration settings.")
                .font(brand: .body4)
                .foregroundStyle(DesignTokens.Text.tertiary)

            Divider()
                .background(DesignTokens.Border.subtle)

            VStack(alignment: .leading, spacing: DesignTokens.Spacing.gapRegular) {
                Text("Legacy Import")
                    .font(brand: .body3)
                    .foregroundStyle(DesignTokens.Text.secondary)

                Text("Import Quick Switch root folders, overrides, favorites, and default layout from DeskJig's old sandboxed settings only when you ask for it. This avoids macOS showing the privacy prompt every time DeskJig starts.")
                    .font(brand: .body4)
                    .foregroundStyle(DesignTokens.Text.tertiary)

                if let lastImportedAt = viewModel.lastLegacyImportAt {
                    Text("Last imported \(lastImportedAt.formatted(date: .abbreviated, time: .shortened))")
                        .font(brand: .body4)
                        .foregroundStyle(DesignTokens.Text.tertiary)
                }

                Button {
                    let result = viewModel.importLegacyQuickSwitchSettings()
                    presentLegacyImportResult(result)
                } label: {
                    HStack(spacing: DesignTokens.Spacing.gapSmall) {
                        Image(systemName: "square.and.arrow.down")
                            .font(.system(size: DesignTokens.IconSize.small, weight: .medium))
                        Text("Import Legacy Quick Switch Settings")
                            .font(brand: .body4)
                    }
                    .foregroundStyle(DesignTokens.Text.secondary)
                    .padding(.horizontal, DesignTokens.Spacing.itemPaddingHorizontal)
                    .padding(.vertical, DesignTokens.Spacing.gapSmall)
                    .background {
                        RoundedRectangle(cornerRadius: 6)
                            .fill(DesignTokens.Surface.card)
                    }
                }
                .buttonStyle(.plain)
                .brightenOnHover(0.1)
            }

            // Worktrees section
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.gapRegular) {
                Text("Worktrees")
                    .font(brand: .body3)
                    .foregroundStyle(DesignTokens.Text.secondary)

                // Storage path
                HStack(spacing: DesignTokens.Spacing.gapRegular) {
                    Text("Default Location")
                        .font(brand: .body4)
                        .foregroundStyle(DesignTokens.Text.tertiary)

                    Spacer()

                    Text(abbreviatedPath(viewModel.worktreeStoragePath))
                        .font(brand: .body4)
                        .foregroundStyle(DesignTokens.Text.primary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: 200, alignment: .trailing)

                    Button {
                        showWorktreeStoragePicker()
                    } label: {
                        Image(systemName: "folder")
                            .font(.system(size: DesignTokens.IconSize.small, weight: .medium))
                            .foregroundStyle(DesignTokens.Text.tertiary)
                    }
                    .buttonStyle(.plain)
                    .brightenOnHover(0.1)
                    .help("Choose worktree storage folder")

                    if viewModel.worktreeStoragePath != QuickSwitchViewModel.defaultWorktreeStoragePath {
                        Button {
                            viewModel.worktreeStoragePath = QuickSwitchViewModel.defaultWorktreeStoragePath
                        } label: {
                            Image(systemName: "arrow.counterclockwise")
                                .font(.system(size: DesignTokens.IconSize.small, weight: .medium))
                                .foregroundStyle(DesignTokens.Text.tertiary)
                        }
                        .buttonStyle(.plain)
                        .brightenOnHover(0.1)
                        .help("Reset to default")
                    }
                }

                // Branch name prefix
                HStack(spacing: DesignTokens.Spacing.gapRegular) {
                    Text("Branch Name Prefix")
                        .font(brand: .body4)
                        .foregroundStyle(DesignTokens.Text.tertiary)

                    Spacer()

                    TextField("e.g., wt/", text: $viewModel.worktreeBranchPrefix)
                        .textFieldStyle(.plain)
                        .font(brand: .body4)
                        .foregroundStyle(DesignTokens.Text.primary)
                        .frame(maxWidth: 120)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background {
                            RoundedRectangle(cornerRadius: 4)
                                .fill(DesignTokens.Surface.window)
                                .overlay {
                                    RoundedRectangle(cornerRadius: 4)
                                        .stroke(DesignTokens.Border.subtle, lineWidth: 1)
                                }
                        }
                }
            }
        }
        .padding(DesignTokens.Spacing.cardPaddingSmall)
        .background {
            RoundedRectangle(cornerRadius: DesignTokens.Card.cornerRadius)
                .fill(DesignTokens.Surface.card)
                .overlay {
                    RoundedRectangle(cornerRadius: DesignTokens.Card.cornerRadius)
                        .stroke(DesignTokens.Border.subtle, lineWidth: 1)
                }
        }
    }

    // MARK: - Root Folder Row

    private func rootFolderRow(_ folder: QuickSwitchRootFolder) -> some View {
        HStack(spacing: DesignTokens.Spacing.gapRegular) {
            // Enable/disable toggle
            Toggle("", isOn: Binding(
                get: { folder.isEnabled },
                set: { _ in viewModel.toggleFolder(folder) }
            ))
            .toggleStyle(.switch)
            .controlSize(.mini)
            .labelsHidden()

            // Folder icon + path
            Image(systemName: "folder.fill")
                .font(.system(size: DesignTokens.IconSize.small))
                .foregroundStyle(folder.isEnabled ? DesignTokens.Text.tertiary : DesignTokens.Text.muted)

            Text(abbreviatedPath(folder.path))
                .font(brand: .body4)
                .foregroundStyle(folder.isEnabled ? DesignTokens.Text.primary : DesignTokens.Text.tertiary)
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer()

            // Scan depth stepper
            HStack(spacing: 4) {
                Text("Depth:")
                    .font(brand: .label4)
                    .foregroundStyle(DesignTokens.Text.tertiary)

                Stepper(
                    value: Binding(
                        get: { folder.scanDepth },
                        set: { viewModel.updateScanDepth(for: folder, depth: $0) }
                    ),
                    in: 1...3
                ) {
                    Text("\(folder.scanDepth)")
                        .font(brand: .body4)
                        .foregroundStyle(DesignTokens.Text.secondary)
                        .monospacedDigit()
                }
                .controlSize(.mini)
            }

            // Remove button
            Button {
                viewModel.removeRootFolder(folder)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: DesignTokens.IconSize.small, weight: .medium))
                    .foregroundStyle(DesignTokens.Text.tertiary)
            }
            .buttonStyle(.plain)
            .brightenOnHover(0.1)
        }
        .padding(.horizontal, DesignTokens.Spacing.itemPaddingHorizontal)
        .padding(.vertical, DesignTokens.Spacing.gapSmall)
        .background {
            RoundedRectangle(cornerRadius: 6)
                .fill(DesignTokens.Surface.window)
        }
    }

    // MARK: - Helpers

    private func abbreviatedPath(_ path: String) -> String {
        let homePath = FileManager.default.homeDirectoryForCurrentUser.path
        if path.hasPrefix(homePath) {
            return "~" + path.dropFirst(homePath.count)
        }
        return path
    }

    private func showFolderPicker() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.title = "Select Root Folder"
        panel.prompt = "Add"

        if panel.runModal() == .OK, let url = panel.url {
            viewModel.addRootFolder(path: url.path)
        }
    }

    private func showWorktreeStoragePicker() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.title = "Select Worktree Storage Folder"
        panel.prompt = "Choose"

        if panel.runModal() == .OK, let url = panel.url {
            viewModel.worktreeStoragePath = url.path
        }
    }

    private func presentLegacyImportResult(_ result: QuickSwitchViewModel.LegacyImportResult) {
        let content: NotificationPresenter.NotificationContent
        let duration: NotificationPresenter.PresentationDuration

        switch result {
        case .imported:
            content = .init(
                "Legacy Quick Switch settings imported",
                text: "Imported legacy Quick Switch settings into your current DeskJig profile.",
                icon: "checkmark.circle.fill",
                iconColor: .green
            )
            duration = .seconds(5)

        case .noChanges:
            content = .init(
                "No legacy settings imported",
                text: "Your current Quick Switch settings already contain everything DeskJig could import.",
                icon: "info.circle.fill",
                iconColor: .blue
            )
            duration = .seconds(5)

        case .unavailable:
            content = .init(
                "No legacy settings found",
                text: "DeskJig couldn't find an older Quick Switch settings file to import.",
                icon: "info.circle.fill",
                iconColor: .blue
            )
            duration = .seconds(5)

        case .failed(let message):
            content = .init(
                "Legacy import failed",
                text: message,
                icon: "exclamationmark.triangle.fill",
                iconColor: .yellow
            )
            duration = .persistent
        }

        NotificationPresenter.present(content, for: duration)
    }
}
