//
//  WorkspacesView.swift
//  DeskJig
//
//  Created by Jake Sax on 10/28/25.
//

import SwiftUI
import DeskJigShared
import KeyboardShortcuts
import AppKit

struct WorkspacesView: View {

    // MARK: Data
    @Environment(WorkspaceViewModel.self) private var vm

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Workspaces")
                .font(brand: .h2)
                .foregroundStyle(DesignTokens.Text.primary)

            LazyVGrid(
                columns: Array<GridItem>(
                    repeating: .init(
                        .flexible(minimum: 120, maximum: 400),
                        spacing: 20,
                        alignment: .topLeading
                    ),
                    count: 4
                ),
                alignment: .leading,
                spacing: 20
            ) {
                ForEach(
                    Array(vm.workspaces.enumerated()),
                    id: \.element.workspace.id
                ) { index, workspace in
                    WorkspaceTileView(workspace: workspace, index: index)
                        .transition(.animatedBlur)
                }
            }
        }
        .animation(.smoothDefault, value: vm.workspaces)
    }

    

    struct WorkspaceTileView: View {

        let workspace: WorkspaceWithApps
        let index: Int
        @Environment(WorkspaceViewModel.self) private var vm

        @State private var isHovering: Bool = false

        var body: some View {
            Button {
                vm.editWorkspace(workspace.workspace)
            } label: {
                VStack(alignment: .leading, spacing: DesignTokens.Spacing.gapMedium) {
                    Group {
                        iconText +
                        Text("   ") +
                        Text(workspace.workspace.name)
                    }
                    .foregroundStyle(DesignTokens.Text.primary)
                    .lineLimit(2)
                    .font(brand: .h4)

                    AppIconsView(apps: workspace.apps)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(.bottom, 16)
                .padding(24)
                .overlay(alignment: .topTrailing) {
                    if isHovering {
                        Image(systemName: "pencil.circle.fill")
                            .font(.system(size: DesignTokens.IconSize.large))
                            .foregroundStyle(DesignTokens.Text.secondary)
                            .padding(6)
                            .transition(.blurReplace)
                    }
                }
                .dsCard(isHighlighted: isHovering)
                .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Card.cornerRadius))
            }
            .animation(.smooth(duration: 0.15), value: isHovering)
            .onHover(perform: { isHovering = $0 })
            .buttonStyle(.plain)
        }

        private var iconText: Text {
            if let icon = workspace.workspace.icon {
                Text(icon)
            } else {
                Text((index + 1).description)
                    .foregroundStyle(DesignTokens.Text.muted)
            }
        }

        struct WorkspaceEditorView: View {

            let workspace: Workspace
            let updateName: (String) -> Void
            let deleteWorkspace: () -> Void
            @Binding var isPresented: Bool
            @Environment(WorkspaceViewModel.self) private var vm
            @Environment(AppDelegate.self) private var appDelegate

            @State private var isConfirmingDeleteWorkspace: Bool = false
            @State private var name: String = ""
            @State private var icon: String = ""
            @State private var isPickingIcon: Bool = false

            static let defaultEmoji: String = "📁"
            static let workspaceEmojis: [String] = [
                "📁", "🗂️", "🧭", "🪶", "🪄", "⚙️", "🧱", "💻", "🧑‍💻", "🧠", "🧩", "🔧", "🧰",
                "📡", "🎨", "✏️", "🖌️", "🧵", "📸", "🎬", "🪩", "🤝", "🏠", "🫶", "🧺", "📊",
                "🏗️", "🌱", "🌿", "🌸", "☀️", "🌙", "🔮", "📖", "🪴", "🔥", "⚡", "🚀", "🎯",
                "⏳", "🗄️", "💡", "🔒", "💼", "🧾", "📈", "🏦", "🧮", "💬", "🌍", "🕸️", "🏛️",
            ]

            var body: some View {
                VStack(alignment: .leading, spacing: 32) {
                    Button("Delete Workspace") {
                        isConfirmingDeleteWorkspace = true
                    }
                    .buttonStyle(
                        .deskJig(
                            font: .body4,
                            backgroundStyle: DesignTokens.Surface.card,
                            brightnessOnHover: 0.08
                        )
                    )
                    .controlSize(.mini)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .confirmationDialog(
                        "Delete Workspace?",
                        isPresented: $isConfirmingDeleteWorkspace
                    ) {
                        Button(
                            "Delete Workspace?",
                            role: .destructive,
                            action: {
                                withAnimation(.smoothDefault) {
                                    deleteWorkspace()
                                }
                                // Refresh action panel menu
                                MainActor.async(after: .milliseconds(100)) {
                                    appDelegate.actionPanelManager?.updateDynamicContent()
                                }
                                isPresented = false
                            }
                        )
                    }

                    // Name and Icon
                    HStack(spacing: 16) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Workspace Name")
                                .font(brand: .body2)
                                .foregroundStyle(DesignTokens.Text.secondary)
                            TextField("Workspace Name", text: $name)
                                .font(brand: .h3)
                                .foregroundStyle(DesignTokens.Text.primary)
                                .textFieldStyle(.plain)
                                .padding(12)
                                .background {
                                    RoundedRectangle(cornerRadius: 8)
                                        .fill(DesignTokens.Surface.elevated)
                                        .stroke(DesignTokens.Border.subtle, lineWidth: 1)
                                }
                        }

                        VStack(alignment: .leading, spacing: 8) {
                            Text("Icon")
                                .font(brand: .body2)
                                .foregroundStyle(DesignTokens.Text.secondary)
                            iconPicker
                        }
                    }

                    // Keyboard Shortcut
                    keyboardShortcutRecorder

                    // App Icons
                    if let workspaceWithApps = vm.workspaces.first(where: { $0.workspace.id == workspace.id }) {
                        let referenceWorkspaces = vm.workspaces.map(\.workspace).filter { $0.id != workspace.id }
                        let previewWorkspace = workspaceWithApps.workspace.repairPreviewWorkspace(using: referenceWorkspaces)
                        VStack(alignment: .leading, spacing: 0) {
                            Text("Apps in Workspace")
                                .font(brand: .body2)
                                .foregroundStyle(DesignTokens.Text.secondary)
                            WorkspaceLayoutPreview(
                                windows: previewWorkspace.windows,
                                screens: previewWorkspace.screens ?? [],
                                height: 120,
                                showLabels: true,
                                iconProvider: { window in
                                    return workspaceWithApps.apps.first { $0.bundleIdentifier == window.bundleIdentifier }?.icon
                                }
                            )
                            .padding(.top, 6)
                        }
                    }

                    VStack(alignment: .leading, spacing: 12) {
                        // Edit Layout Button
                        Button {
                            vm.editWorkspace(workspace)
                            isPresented = false
                        } label: {
                            Text("Edit Layout")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(
                            .deskJig(
                                backgroundStyle: DesignTokens.Surface.card,
                                brightnessOnHover: 0.08
                            )
                        )

                        // Save and Cancel
                        HStack(spacing: 12) {
                            Button {
                                isPresented = false
                            } label: {
                                Text("Cancel")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(
                                .deskJig(
                                    backgroundStyle: DesignTokens.Surface.card,
                                    brightnessOnHover: 0.08
                                )
                            )

                            Button {
                                withAnimation(.smoothDefault) {
                                    saveWorkspace()
                                }
                                isPresented = false
                            } label: {
                                Text("Save")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.deskJig)
                            .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }
                    }
                }
                .padding(32)
                .background {
                    RoundedRectangle(cornerRadius: 20)
                        .fill(DesignTokens.Surface.panel)
                }
                .onAppear {
                    name = workspace.name
                    icon = workspace.icon ?? Self.defaultEmoji
                }
            }

            private var iconPicker: some View {
                Button {
                    isPickingIcon.toggle()
                } label: {
                    Text(icon)
                        .font(brand: .h3)
                        .padding(12)
                        .background {
                            RoundedRectangle(cornerRadius: 8)
                                .fill(DesignTokens.Surface.elevated)
                                .stroke(DesignTokens.Border.subtle, lineWidth: 1)
                        }
                }
                .buttonStyle(.plain)
                .popover(isPresented: $isPickingIcon) {
                    LazyHGrid(
                        rows: [
                            .init(.fixed(32), spacing: 4),
                            .init(.fixed(32), spacing: 4),
                            .init(.fixed(32), spacing: 4),
                            .init(.fixed(32), spacing: 4)
                        ],
                        spacing: 4
                    ) {
                        ForEach(Self.workspaceEmojis, id: \.description) { emoji in
                            Button {
                                withAnimation(.smoothDefault) {
                                    icon = emoji
                                }
                                isPickingIcon = false
                            } label: {
                                    Text(emoji)
                                        .font(brand: .h4)
                                        .padding(6)
                                        .background {
                                            RoundedRectangle(cornerRadius: 8)
                                                .fill(
                                                    icon == emoji ? DesignTokens.Surface.cardHover : DesignTokens.Surface.card
                                                )
                                        }
                                        .padding(2)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(8)
                    .background {
                        RoundedRectangle(cornerRadius: DesignTokens.Card.cornerRadius)
                            .fill(DesignTokens.Surface.panel)
                    }
                }
            }

            private var keyboardShortcutRecorder: some View {
                VStack(alignment: .leading, spacing: DesignTokens.Spacing.gapSmall) {
                    HStack(spacing: DesignTokens.Spacing.gapSmall) {
                        Image(systemName: "keyboard")
                            .font(.system(size: DesignTokens.IconSize.medium, weight: .medium))
                            .foregroundStyle(DesignTokens.Text.secondary)

                        Text("Keyboard Shortcut")
                            .font(brand: .body2)
                            .foregroundStyle(DesignTokens.Text.secondary)
                    }

                    KeyboardShortcuts.Recorder(for: .workspace(workspace.id)) {
                        EmptyView()
                    }
                    .padding(8)
                    .background {
                        RoundedRectangle(cornerRadius: 8)
                            .fill(DesignTokens.Surface.elevated)
                            .stroke(DesignTokens.Border.subtle, lineWidth: 1)
                    }
                }
            }

            private func saveWorkspace() {
                // Update name and icon
                vm.windowManager.updateWorkspaceMetadata(
                    for: workspace,
                    newName: name,
                    newIcon: icon
                )
                updateName(name)
            }
        }
    }

    struct AppIconsView: View {
        let apps: [AppInfo]
        var appsToDisplay: Int = 4
        let appSize: CGFloat = 36
        let appIconPaddingPercentage = 0.15

        var body: some View {
            HStack(spacing: 4) {
                ForEach(Array(apps.prefix(appsToDisplay).enumerated()), id: \.offset) { _, app in
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

                if apps.count > appsToDisplay {
                    let placeholderAppSize = appSize * (1 - appIconPaddingPercentage)
                    Text("+\(apps.count - appsToDisplay)")
                        .font(brand: .h5)
                        .foregroundStyle(DesignTokens.Text.primary)
                        .frame(width: placeholderAppSize, height: placeholderAppSize)
                        .background {
                            RoundedRectangle(cornerRadius: 6)
                                .fill(DesignTokens.Surface.elevated)
                        }
                }
            }
            .padding(.leading, appSize * -appIconPaddingPercentage)
        }
    }
}

struct WorkspaceWithApps: Hashable, Sendable {
    let workspace: Workspace
    let apps: [AppInfo]
}

//#Preview {
//    WorkspacesView()
//}
