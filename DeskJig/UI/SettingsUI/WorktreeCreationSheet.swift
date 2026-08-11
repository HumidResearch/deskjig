//
//  WorktreeCreationSheet.swift
//  DeskJig
//
//  Worktree creation form and archive confirmation sheet for QuickSwitch.
//

import SwiftUI
import DeskJigShared

struct WorktreeCreationSheet: View {
    @Bindable var viewModel: QuickSwitchViewModel
    @Environment(\.dismiss) private var dismiss
    @FocusState private var isBranchNameFocused: Bool

    private var resolvedWorktreePath: String {
        guard let repoPath = viewModel.worktreeResolvedRepoPath else { return "" }
        let repoName = URL(fileURLWithPath: repoPath).lastPathComponent
        let branchName = viewModel.worktreeNewBranchName
        let base = (abbreviatedStoragePath as NSString).appendingPathComponent(repoName)
        if branchName.isEmpty {
            return (base as NSString).appendingPathComponent("...")
        }
        return (base as NSString).appendingPathComponent(branchName)
    }

    private var abbreviatedStoragePath: String {
        let path = viewModel.worktreeStoragePath
        let homePath = FileManager.default.homeDirectoryForCurrentUser.path
        let expanded = (path as NSString).expandingTildeInPath
        if expanded.hasPrefix(homePath) {
            return "~" + expanded.dropFirst(homePath.count)
        }
        return path
    }

    private var fullBranchName: String {
        viewModel.worktreeBranchPrefix + viewModel.worktreeNewBranchName
    }

    private var branchNameValidation: DSValidationState {
        let name = viewModel.worktreeNewBranchName
        guard !name.isEmpty else { return .none }

        if !QuickSwitchViewModel.isValidBranchName(fullBranchName) {
            return .error("Invalid branch name")
        }

        if viewModel.worktreeAvailableBranches.contains(fullBranchName) {
            return .error("Branch already exists")
        }

        return .success("")
    }

    private var canCreate: Bool {
        !viewModel.worktreeNewBranchName.isEmpty
            && !branchNameHasError
            && !viewModel.worktreeCreationInProgress
    }

    private var branchNameHasError: Bool {
        if case .error = branchNameValidation { return true }
        return false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.gapMedium) {
            // Header
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.gapTiny) {
                Text("Create Worktree")
                    .font(brand: .h3)
                    .foregroundStyle(DesignTokens.Text.primary)

                if let source = viewModel.worktreeSourceDirectory {
                    Text("From \(source.name)")
                        .font(brand: .body4)
                        .foregroundStyle(DesignTokens.Text.tertiary)
                }
            }

            // Branch name
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.gapTiny) {
                Text("Branch Name")
                    .font(brand: .label3)
                    .foregroundStyle(DesignTokens.Text.secondary)

                HStack(spacing: 0) {
                    if !viewModel.worktreeBranchPrefix.isEmpty {
                        Text(viewModel.worktreeBranchPrefix)
                            .font(brand: .body3)
                            .foregroundStyle(DesignTokens.Text.tertiary)
                            .padding(.leading, 10)
                    }

                    DSTextField(
                        placeholder: "my-feature",
                        text: $viewModel.worktreeNewBranchName,
                        validationState: branchNameValidation
                    )
                    .focused($isBranchNameFocused)
                }
            }

            // Base branch
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.gapTiny) {
                Text("Base Branch")
                    .font(brand: .label3)
                    .foregroundStyle(DesignTokens.Text.secondary)

                if viewModel.worktreeAvailableBranches.isEmpty {
                    DSTextField(
                        placeholder: "main",
                        text: $viewModel.worktreeBaseBranch
                    )
                } else {
                    Picker("", selection: $viewModel.worktreeBaseBranch) {
                        ForEach(viewModel.worktreeAvailableBranches, id: \.self) { branch in
                            Text(branch).tag(branch)
                        }
                    }
                    .pickerStyle(.menu)
                }
            }

            // Worktree location (read-only)
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.gapTiny) {
                Text("Location")
                    .font(brand: .label3)
                    .foregroundStyle(DesignTokens.Text.secondary)

                Text(resolvedWorktreePath)
                    .font(brand: .body4)
                    .foregroundStyle(DesignTokens.Text.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background {
                        RoundedRectangle(cornerRadius: 6)
                            .fill(DesignTokens.Surface.window)
                            .overlay {
                                RoundedRectangle(cornerRadius: 6)
                                    .stroke(DesignTokens.Border.subtle, lineWidth: 1)
                            }
                    }
            }

            // Error message
            if let error = viewModel.worktreeCreationError {
                Text(error)
                    .font(brand: .body4)
                    .foregroundStyle(DesignTokens.Status.error)
                    .padding(.horizontal, 4)
            }

            // Actions
            HStack(spacing: DesignTokens.Spacing.gapSmall) {
                Button("Cancel") {
                    viewModel.isWorktreeSheetPresented = false
                }
                .buttonStyle(.dsButton(variant: .secondary, size: .medium))

                Spacer()

                Button {
                    viewModel.createWorktree()
                } label: {
                    if viewModel.worktreeCreationInProgress {
                        ProgressView()
                            .controlSize(.small)
                            .padding(.horizontal, 8)
                    } else {
                        Text("Create")
                    }
                }
                .buttonStyle(.dsButton(variant: .primary, size: .medium))
                .disabled(!canCreate)
            }
        }
        .padding(DesignTokens.Card.padding)
        .frame(width: 420)
        .onAppear {
            isBranchNameFocused = true
        }
    }
}

// MARK: - Archive Worktree Sheet

struct ArchiveWorktreeSheet: View {
    let directory: ScannedDirectory
    let hasUncommittedChanges: Bool
    @Binding var deleteBranch: Bool
    let onArchive: () -> Void
    let onCancel: () -> Void

    private var relativePath: String {
        let homePath = FileManager.default.homeDirectoryForCurrentUser.path
        if directory.path.hasPrefix(homePath) {
            return "~" + directory.path.dropFirst(homePath.count)
        }
        return directory.path
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.gapRegular) {
            Text("Archive Worktree")
                .font(brand: .h3)
                .foregroundStyle(DesignTokens.Text.primary)

            VStack(alignment: .leading, spacing: DesignTokens.Spacing.gapSmall) {
                Text(relativePath)
                    .font(brand: .body4)
                    .foregroundStyle(DesignTokens.Text.tertiary)
                    .lineLimit(2)
                    .truncationMode(.middle)

                Text("This will remove the worktree directory and de-register it from git.")
                    .font(brand: .body3)
                    .foregroundStyle(DesignTokens.Text.secondary)
            }

            if hasUncommittedChanges {
                HStack(spacing: DesignTokens.Spacing.gapSmall) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: DesignTokens.IconSize.medium))
                        .foregroundStyle(DesignTokens.Status.warning)
                    Text("This worktree has uncommitted changes that will be lost.")
                        .font(brand: .body4)
                        .foregroundStyle(DesignTokens.Status.warning)
                }
                .padding(DesignTokens.Spacing.gapSmall)
                .background {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(DesignTokens.Status.warning.opacity(0.1))
                }
            }

            if let branchName = directory.gitBranch {
                Toggle(isOn: $deleteBranch) {
                    Text("Also delete branch \"\(branchName)\"")
                        .font(brand: .body4)
                        .foregroundStyle(DesignTokens.Text.secondary)
                }
                .toggleStyle(.checkbox)
            }

            HStack(spacing: DesignTokens.Spacing.gapSmall) {
                Button("Cancel") {
                    onCancel()
                }
                .buttonStyle(.dsButton(variant: .secondary, size: .medium))

                Spacer()

                Button("Archive") {
                    onArchive()
                }
                .buttonStyle(.dsButton(variant: deleteBranch ? .danger : .primary, size: .medium))
            }
        }
        .padding(DesignTokens.Card.padding)
        .frame(width: 420)
    }
}
