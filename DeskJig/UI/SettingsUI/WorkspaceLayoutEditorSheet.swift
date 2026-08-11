//
//  WorkspaceLayoutEditorSheet.swift
//  DeskJig
//
//  Created by Codex on 02/04/26.
//

import SwiftUI
import DeskJigShared

struct WorkspaceLayoutEditorContent: View {
    let workspace: Workspace
    let onClose: () -> Void

    @Environment(WorkspaceViewModel.self) private var vm

    @State private var draftViewModel: WorkspaceDraftViewModel?
    @State private var editorPathFieldFocused = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let draftViewModel {
                WorkspaceLayoutBuilder(
                    viewModel: draftViewModel,
                    editorPathFieldFocused: $editorPathFieldFocused,
                    isSelected: false,
                    primaryTitle: draftViewModel.isSaving ? "Saving..." : "Save Layout",
                    secondaryTitle: "Cancel",
                    primaryAccessibilityIdentifier: "workspace.editor.save-button",
                    secondaryAccessibilityIdentifier: "workspace.editor.cancel-button",
                    onPrimary: {
                        Task { @MainActor in
                            let success = await draftViewModel.saveEdits(to: workspace)
                            if success {
                                onClose()
                            }
                        }
                    },
                    onSecondary: {
                        onClose()
                    },
                    isPrimaryEnabled: draftViewModel.canCreateWorkspace && !draftViewModel.isSaving
                )
            } else {
                ProgressView("Loading layout...")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear {
            if draftViewModel == nil {
                let builder = WorkspaceDraftViewModel(
                    applicationManager: vm.applicationManager,
                    displayManager: vm.windowManager.displayManager,
                    chromeProfileManager: ChromeProfileManager(),
                    workspaceManager: vm.windowManager.workspaceManagerService
                )
                builder.load(from: workspace)
                draftViewModel = builder
            }
        }
    }
}

struct WorkspaceLayoutEditorSheet: View {
    let workspace: Workspace

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        WorkspaceLayoutEditorContent(workspace: workspace) {
            dismiss()
        }
        .padding(24)
        .frame(minWidth: 980, minHeight: 720)
    }
}
