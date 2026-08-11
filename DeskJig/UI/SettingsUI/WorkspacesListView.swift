//
//  WorkspacesListView.swift
//  DeskJig
//
//  Created by Claude Code on 01/30/26.
//

import SwiftUI
import DeskJigShared

/// Filter mode for workspace list - shows all workspaces or only favorites.
enum WorkspacesFilterMode {
    case all
    case favorites
}

/// Single-column list view for workspaces with search filtering.
/// Replaces the 4-column grid layout with a vertical list (one workspace per row).
struct WorkspacesListView: View {
    private enum ActiveWorkspaceEditor: Equatable {
        case metadata(UUID)
        case layout(UUID)

        var workspaceId: UUID {
            switch self {
            case .metadata(let workspaceId), .layout(let workspaceId):
                return workspaceId
            }
        }
    }

    /// Filter mode to show all workspaces or only favorites
    var filterMode: WorkspacesFilterMode = .all
    @Binding var searchText: String
    var isSearchFocused: FocusState<Bool>.Binding
    @Binding var editorPathFieldFocused: Bool
    @Binding var isEditingWorkspace: Bool
    var isListFocused: FocusState<Bool>.Binding
    /// Selected index for keyboard navigation, passed from parent.
    /// nil = search box focused, 0 = inline creator, 1+ = workspace cards
    @Binding var selectedIndex: Int?
    /// Signals from parent to expand the inline creator (e.g., Return from search)
    @Binding var expandInlineCreator: Bool
    /// Reflects whether the inline creator is expanded (for top-level key handling)
    @Binding var inlineCreatorIsOpen: Bool
    @Binding var autoEditWorkspaceId: UUID?
    @Binding var pendingCreateSeed: WorkspaceViewModel.SettingsWorkspaceCreateSeed?
    @Environment(WorkspaceViewModel.self) private var vm
    @State private var draftViewModel: WorkspaceDraftViewModel?
    @State private var isInlineCreatorExpanded: Bool = false
    @State private var activeEditor: ActiveWorkspaceEditor?

    private var showInlineCreator: Bool {
        filterMode == .all && searchText.isEmpty
    }

    /// Filtered workspaces based on search text and filter mode.
    private var filteredWorkspaces: [WorkspaceWithApps] {
        let baseWorkspaces = filterMode == .favorites ? vm.favoriteWorkspaces : vm.workspaces
        if searchText.isEmpty {
            return baseWorkspaces
        }
        return baseWorkspaces.filter {
            $0.workspace.name.localizedCaseInsensitiveContains(searchText)
        }
    }

    /// Total number of selectable items (inline creator + workspace cards)
    private var totalSelectableItems: Int {
        let creatorCount = showInlineCreator ? 1 : 0
        return creatorCount + filteredWorkspaces.count
    }

    /// Title text based on filter mode
    private var titleText: String {
        filterMode == .favorites ? "Favorite Workspaces" : "Workspaces"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text(titleText)
                .font(brand: .h2)
                .foregroundStyle(DesignTokens.Text.primary)

            if let activeEditor {
                activeEditorView(for: activeEditor)
                    .id("workspace-editor-root")
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else {
                listContent
            }
        }
        .animation(.smoothDefault, value: vm.workspaces)
        .animation(.smoothDefault, value: searchText)
        .focusable()
        .focused(isListFocused)
        .focusEffectDisabled()
        // Arrow key navigation is handled by parent (DeskJigContentView) via search bar
        // to support key repeat without focus changes
        .onKeyPress(.return) {
            guard activeEditor == nil else { return .ignored }
            handleReturn()
            return .handled
        }
        // Escape key to clear selection and focus search
        .onKeyPress(.escape) {
            guard activeEditor == nil else { return .ignored }
            selectedIndex = nil
            isListFocused.wrappedValue = false
            isSearchFocused.wrappedValue = true
            return .handled
        }
        // Sync selection state when search focus changes
        .onChange(of: isSearchFocused.wrappedValue) { _, isFocused in
            if isFocused, activeEditor == nil {
                selectedIndex = nil
            }
        }
        // Reset selection when search text changes
        .onChange(of: searchText) { _, _ in
            guard activeEditor == nil else { return }
            selectedIndex = nil
            if !showInlineCreator {
                isInlineCreatorExpanded = false
            }
        }
        .onChange(of: isInlineCreatorExpanded) { _, newValue in
            inlineCreatorIsOpen = newValue
            if !newValue {
                editorPathFieldFocused = false
            }
        }
        .onChange(of: expandInlineCreator) { _, shouldExpand in
            if activeEditor != nil {
                expandInlineCreator = false
                return
            }
            if shouldExpand {
                expandInlineCreatorRow()
                expandInlineCreator = false
            }
        }
        .onChange(of: activeEditor) { _, newValue in
            isEditingWorkspace = newValue != nil
            guard newValue != nil else { return }
            isSearchFocused.wrappedValue = false
            selectedIndex = nil
            isInlineCreatorExpanded = false
            inlineCreatorIsOpen = false
            editorPathFieldFocused = false
        }
        .onAppear {
            handlePendingAutoEdit()
        }
        .onChange(of: autoEditWorkspaceId) { _, _ in
            handlePendingAutoEdit()
        }
    }

    // MARK: - Main Views

    private var listContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            // While the creator is expanded, show the existing workspaces as a
            // constant-height strip above it (#598) — the creator stays in
            // context with the list, and the trailing draft card mirrors the
            // form's icon + name live as the user types.
            if isInlineCreatorExpanded {
                existingWorkspacesStrip
                    .transition(.animatedBlur)
            }

            // Inline create row
            if showInlineCreator {
                WorkspaceInlineCreatorRow(
                    isExpanded: $isInlineCreatorExpanded,
                    editorPathFieldFocused: $editorPathFieldFocused,
                    isSelected: selectedIndex == 0,
                    viewModel: draftViewModel,
                    onExpand: { expandInlineCreatorRow() },
                    onCreate: { handleInlineCreate() },
                    onCancel: { cancelInlineCreate() }
                )
                .id("workspace-item-0")
                .transition(.animatedBlur)
            }

            // While the inline creator is expanded it owns the full content
            // height (#597) — the card list is hidden so the creator can flex
            // to fill the window instead of pushing cards below the fold.
            if !isInlineCreatorExpanded {
                // Workspace cards
                ForEach(Array(filteredWorkspaces.enumerated()), id: \.element.workspace.id) { index, workspace in
                    let itemIndex = showInlineCreator ? index + 1 : index
                    WorkspaceCardView(
                        workspace: workspace,
                        index: index,
                        isSelected: selectedIndex == itemIndex,
                        editorPathFieldFocused: $editorPathFieldFocused,
                        isEditingWorkspace: $isEditingWorkspace,
                        editPresentation: .delegated,
                        onRequestEditMetadata: { selectedWorkspace in
                            setActiveEditor(.metadata(selectedWorkspace.id))
                        },
                        onEditLayout: { selectedWorkspace in
                            handleEditLayout(workspace: selectedWorkspace)
                        },
                        onDuplicateLayout: { selectedWorkspace in
                            handleDuplicateLayout(workspace: selectedWorkspace)
                        }
                    )
                    .id("workspace-item-\(itemIndex)")
                    .transition(.animatedBlur)
                }

                // Empty state when no results from search
                if filteredWorkspaces.isEmpty && !searchText.isEmpty {
                    emptySearchState
                }

                // Empty state for favorites when no favorites exist
                if filterMode == .favorites && filteredWorkspaces.isEmpty && searchText.isEmpty {
                    emptyFavoritesState
                }
            }
        }
    }

    // MARK: - Existing Workspaces Strip (#598)

    /// Horizontal strip of existing workspace cards shown above the expanded
    /// creator, ending in a live "draft" card that mirrors the form's icon and
    /// name. Constant height: it never participates in the creator's
    /// fill-height calculation (#597) and scrolls horizontally on overflow.
    private var existingWorkspacesStrip: some View {
        HStack(alignment: .center, spacing: DesignTokens.Spacing.gapSmall) {
            Text("Workspaces".uppercased())
                .font(brand: .label3)
                .foregroundStyle(DesignTokens.Text.tertiary)
                .kerning(0.8)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: DesignTokens.Spacing.gapSmall) {
                    ForEach(filteredWorkspaces, id: \.workspace.id) { item in
                        WorkspaceStripCard(
                            icon: item.workspace.icon ?? "📁",
                            title: item.workspace.name,
                            subtitle: stripSubtitle(for: item),
                            isDraft: false
                        )
                    }

                    draftStripCard
                }
                .padding(.vertical, 2)
            }
        }
    }

    @ViewBuilder
    private var draftStripCard: some View {
        let draftName = draftViewModel?.workspaceName
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        WorkspaceStripCard(
            icon: draftViewModel?.workspaceIcon ?? "📁",
            title: draftName.isEmpty ? "New workspace" : draftName,
            subtitle: "draft — editing below",
            isDraft: true
        )
    }

    private func stripSubtitle(for item: WorkspaceWithApps) -> String {
        let appCount = item.apps.count
        var parts = ["\(appCount) app\(appCount == 1 ? "" : "s")"]
        if let screenCount = item.workspace.screens?.count, screenCount > 1 {
            parts.append("\(screenCount) monitors")
        }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private func activeEditorView(for editor: ActiveWorkspaceEditor) -> some View {
        if let workspace = workspaceWithApps(for: editor.workspaceId) {
            switch editor {
            case .metadata(let workspaceId):
                WorkspaceCardView(
                    workspace: workspace,
                    index: editorWorkspaceIndex(for: workspaceId),
                    isSelected: true,
                    editorPathFieldFocused: $editorPathFieldFocused,
                    isEditingWorkspace: $isEditingWorkspace,
                    editPresentation: .inline,
                    autoEditWorkspaceId: workspaceId,
                    onEditLayout: { selectedWorkspace in
                        setActiveEditor(.layout(selectedWorkspace.id))
                    },
                    onDuplicateLayout: { selectedWorkspace in
                        handleDuplicateLayout(workspace: selectedWorkspace)
                    },
                    onEditingFinished: {
                        closeActiveEditor()
                    }
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            case .layout:
                WorkspaceLayoutEditorContent(workspace: workspace.workspace) {
                    closeActiveEditor()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        } else {
            ProgressView("Loading workspace editor...")
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        }
    }

    // MARK: - Empty Search State

    private var emptySearchState: some View {
        VStack(spacing: DesignTokens.Spacing.gapRegular) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: DesignTokens.IconSize.xxxLarge))
                .foregroundStyle(DesignTokens.Text.muted)

            Text("No workspaces found")
                .font(brand: .h4)
                .foregroundStyle(DesignTokens.Text.secondary)

            Text("Try a different search term")
                .font(brand: .body3)
                .foregroundStyle(DesignTokens.Text.tertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }

    private var emptyFavoritesState: some View {
        VStack(spacing: DesignTokens.Spacing.gapRegular) {
            Image(systemName: "star")
                .font(brand: Font.brandBody(size: 40))
                .foregroundStyle(DesignTokens.Text.muted)

            Text("No Favorites Yet")
                .font(brand: .h4)
                .foregroundStyle(DesignTokens.Text.secondary)

            Text("Star a workspace to add it to your favorites")
                .font(brand: .body3)
                .foregroundStyle(DesignTokens.Text.tertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }

    // MARK: - Keyboard Navigation

    private func handleReturn() {
        guard let idx = selectedIndex else { return }

        if showInlineCreator {
            // Inline creator is at index 0, workspaces are at 1+
            if idx == 0 {
                expandInlineCreatorRow()
            } else {
                let workspaceIndex = idx - 1
                if workspaceIndex < filteredWorkspaces.count {
                    let workspace = filteredWorkspaces[workspaceIndex]
                    vm.openWorkspace(
                        named: workspace.workspace.name,
                        source: WorkspaceViewModel.settingsEnterLaunchSource
                    )
                }
            }
        } else if idx < filteredWorkspaces.count {
            // No inline creator (favorites mode or searching), workspaces are at 0+
            let workspace = filteredWorkspaces[idx]
            vm.openWorkspace(
                named: workspace.workspace.name,
                source: WorkspaceViewModel.settingsEnterLaunchSource
            )
        }
    }

    // MARK: - Inline Creator

    private func expandInlineCreatorRow() {
        guard showInlineCreator else { return }
        if draftViewModel == nil {
            draftViewModel = WorkspaceDraftViewModel(
                applicationManager: vm.applicationManager,
                displayManager: vm.windowManager.displayManager,
                chromeProfileManager: ChromeProfileManager(),
                workspaceManager: vm.windowManager.workspaceManagerService
            )
        }

        if pendingCreateSeed == .currentSnapshot {
            Task { @MainActor in
                let snapshot = await vm.windowManager.captureWorkspaceSnapshot()
                draftViewModel?.load(fromSnapshot: snapshot.windows, screens: snapshot.screens)
            }
        } else if !isInlineCreatorExpanded {
            draftViewModel?.reset()
        } else if pendingCreateSeed == .blank {
            draftViewModel?.reset()
        }

        pendingCreateSeed = nil
        isSearchFocused.wrappedValue = false
        isInlineCreatorExpanded = true
        inlineCreatorIsOpen = true
    }

    private func cancelInlineCreate() {
        draftViewModel?.reset()
        isInlineCreatorExpanded = false
        inlineCreatorIsOpen = false
        selectedIndex = nil
    }

    private func handleInlineCreate() {
        guard let draftViewModel else { return }

        Task { @MainActor in
            let success = await draftViewModel.createWorkspace()
            if success {
                draftViewModel.reset()
                isInlineCreatorExpanded = false
                inlineCreatorIsOpen = false
                selectedIndex = nil
            }
        }
    }

    // MARK: - Layout Editing

    private func handleEditLayout(workspace: Workspace) {
        setActiveEditor(.layout(workspace.id))
    }

    private func handleDuplicateLayout(workspace: Workspace) {
        let existingNames = Set(vm.workspaces.map { $0.workspace.name })
        let baseName = "Copy of \(workspace.name)"
        var candidateName = baseName
        var suffix = 2
        while existingNames.contains(candidateName) {
            candidateName = "\(baseName) \(suffix)"
            suffix += 1
        }

        if let duplicate = vm.windowManager.workspaceManagerService.duplicateWorkspace(workspace, newName: candidateName) {
            setActiveEditor(.layout(duplicate.id))
        }
    }

    private func handlePendingAutoEdit() {
        guard let workspaceId = autoEditWorkspaceId else { return }
        setActiveEditor(.metadata(workspaceId))
        autoEditWorkspaceId = nil
    }

    private func setActiveEditor(_ editor: ActiveWorkspaceEditor) {
        activeEditor = editor
    }

    private func closeActiveEditor() {
        activeEditor = nil
        editorPathFieldFocused = false
        isEditingWorkspace = false
    }

    private func workspaceWithApps(for workspaceId: UUID) -> WorkspaceWithApps? {
        vm.workspaces.first(where: { $0.workspace.id == workspaceId })
    }

    private func editorWorkspaceIndex(for workspaceId: UUID) -> Int {
        vm.workspaces.firstIndex(where: { $0.workspace.id == workspaceId }) ?? 0
    }
}

/// Compact, non-interactive workspace card used in the strip above the
/// expanded creator (#598). The draft variant is accent-highlighted to show
/// that the workspace being edited below will join this list.
private struct WorkspaceStripCard: View {
    let icon: String
    let title: String
    let subtitle: String
    let isDraft: Bool

    var body: some View {
        HStack(spacing: 9) {
            Text(icon)
                .font(brand: Font.brandBody(size: 17))

            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(brand: .label3)
                    .foregroundStyle(isDraft ? DesignTokens.Brand.accent : DesignTokens.Text.primary)
                    .lineLimit(1)

                Text(subtitle)
                    .font(brand: .body4)
                    .foregroundStyle(DesignTokens.Text.tertiary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background {
            RoundedRectangle(cornerRadius: DesignTokens.CornerRadius.large)
                .fill(isDraft ? DesignTokens.LayoutPreview.tileSelectedFill : DesignTokens.Surface.card)
        }
        .overlay {
            RoundedRectangle(cornerRadius: DesignTokens.CornerRadius.large)
                .stroke(
                    isDraft ? DesignTokens.LayoutPreview.tileSelectedStroke : DesignTokens.Border.subtle,
                    lineWidth: 1
                )
        }
        .accessibilityIdentifier(isDraft ? "workspace.strip-card.draft" : "workspace.strip-card")
    }
}
