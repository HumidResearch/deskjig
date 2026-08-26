//  QuickSwitchView.swift
//  DeskJig

import SwiftUI
import DeskJigShared

struct QuickSwitchView: View {
    @Bindable var viewModel: QuickSwitchViewModel
    let isActive: Bool
    @Environment(WorkspaceViewModel.self) private var workspaceVM
    @EnvironmentObject var windowManager: WindowManager

    @State private var searchText: String = ""
    @State private var selectedDirectoryIndex: Int? = nil
    @State private var editingDirectoryPath: String? = nil
    @State private var showSettings: Bool = false
    @State private var branchRefreshTask: Task<Void, Never>?
    @FocusState private var isSearchFocused: Bool

    private var savedWorkspaces: [Workspace] {
        windowManager.savedWorkspaces
    }

    private var filteredDirectories: [ScannedDirectory] {
        QuickSwitchSearch.rankedDirectories(
            viewModel.scannedDirectories,
            query: normalizedSearchText,
            favoriteDirectoryPaths: viewModel.favoriteDirectories
        )
    }

    private var normalizedSearchText: String {
        searchText
            .unicodeScalars
            .filter { !CharacterSet.controlCharacters.contains($0) }
            .map(String.init)
            .joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var selectedDirectory: ScannedDirectory? {
        guard let selectedDirectoryIndex,
              filteredDirectories.indices.contains(selectedDirectoryIndex) else { return nil }
        return filteredDirectories[selectedDirectoryIndex]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            header
                .padding(.bottom, DesignTokens.Spacing.gapMedium)

            // Settings (gear-toggled) replace the pane content while open, in
            // every state — so root folders and tmux are configurable even
            // before any root folder or workspace exists — and scroll, since
            // the card is taller than the window.
            if showSettings {
                ScrollView(.vertical, showsIndicators: false) {
                    QuickSwitchSettingsView(viewModel: viewModel)
                }
            } else if savedWorkspaces.isEmpty {
                emptyWorkspacesState
            } else if viewModel.rootFolders.isEmpty {
                emptyRootFoldersState
            } else {
                // Layout picker
                layoutPicker
                    .padding(.bottom, DesignTokens.Spacing.gapMedium)

                // Search bar
                searchBar
                    .padding(.bottom, DesignTokens.Spacing.gapRegular)

                // Directory list
                if filteredDirectories.isEmpty {
                    emptyDirectoriesState
                } else {
                    directoryList
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear {
            viewModel.pruneInvalidLayoutSelections(savedWorkspaces: savedWorkspaces)
            viewModel.scanDirectories()
            viewModel.refreshGitBranches()
            requestSearchFocus()
            if selectedDirectoryIndex == nil, !filteredDirectories.isEmpty {
                selectedDirectoryIndex = 0
            }
        }
        .onChange(of: filteredDirectories.map(\.id)) { _, filteredIDs in
            guard !filteredIDs.isEmpty else {
                selectedDirectoryIndex = nil
                editingDirectoryPath = nil
                return
            }

            if let selectedDirectoryIndex {
                self.selectedDirectoryIndex = min(selectedDirectoryIndex, filteredIDs.count - 1)
            } else {
                self.selectedDirectoryIndex = 0
            }
        }
        .onChange(of: savedWorkspaces.map(\.id)) { _, _ in
            viewModel.pruneInvalidLayoutSelections(savedWorkspaces: savedWorkspaces)
        }
        .onChange(of: isActive) { _, active in
            if active {
                viewModel.refreshGitBranches()
                requestSearchFocus()
                startBranchPolling()
            } else {
                stopBranchPolling()
            }
        }
        .onDisappear {
            stopBranchPolling()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            guard isActive else { return }
            requestSearchFocus()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
            guard isActive else { return }
            viewModel.refreshGitBranches()
            startBranchPolling()
            requestSearchFocus()
        }
        .onKeyPress(.downArrow, phases: [.down, .repeat]) { _ in
            guard !isSearchFocused else { return .ignored }
            navigateDown()
            return .handled
        }
        .onKeyPress(.upArrow, phases: [.down, .repeat]) { _ in
            guard !isSearchFocused else { return .ignored }
            navigateUp()
            return .handled
        }
        .onKeyPress(.return, phases: .down) { _ in
            guard !isSearchFocused else { return .ignored }
            handleReturn()
            return .handled
        }
        .onKeyPress(.escape, phases: .down) { _ in
            handleEscape()
            return .handled
        }
        .onKeyPress(characters: .alphanumerics.union(.punctuationCharacters).union(.symbols)) { keyPress in
            if !isSearchFocused {
                isSearchFocused = true
                searchText += keyPress.characters
                return .handled
            }
            return .ignored
        }
        .sheet(isPresented: $viewModel.isWorktreeSheetPresented) {
            WorktreeCreationSheet(viewModel: viewModel)
        }
        .sheet(isPresented: $viewModel.isArchiveWorktreePresented) {
            if let directory = viewModel.archiveWorktreeDirectory {
                ArchiveWorktreeSheet(
                    directory: directory,
                    hasUncommittedChanges: viewModel.archiveWorktreeHasChanges,
                    deleteBranch: $viewModel.archiveWorktreeDeleteBranch,
                    onArchive: {
                        viewModel.archiveWorktree(force: viewModel.archiveWorktreeHasChanges)
                    },
                    onCancel: {
                        viewModel.isArchiveWorktreePresented = false
                    }
                )
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.gapTiny) {
                Text("Quick Switch")
                    .font(brand: .h2)
                    .foregroundStyle(DesignTokens.Text.primary)

                Text("Switch your terminal and IDE windows to any project directory")
                    .font(brand: .body3)
                    .foregroundStyle(DesignTokens.Text.secondary)
            }

            Spacer()

            QuickSwitchShortcutRecorder()

            Button {
                withAnimation(.smooth(duration: 0.2)) {
                    showSettings.toggle()
                }
            } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: DesignTokens.IconSize.large, weight: .medium))
                    .foregroundStyle(showSettings ? DesignTokens.Text.primary : DesignTokens.Text.secondary)
                    .padding(DesignTokens.Spacing.gapSmall)
                    .background {
                        RoundedRectangle(cornerRadius: 6)
                            .fill(showSettings ? DesignTokens.Surface.cardHover : Color.clear)
                    }
            }
            .buttonStyle(.plain)
            .brightenOnHover(0.1)
        }
    }

    // MARK: - Layout Picker

    private var layoutPicker: some View {
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
                ForEach(savedWorkspaces) { workspace in
                    Text(workspace.name)
                        .tag(workspace.id.uuidString)
                }
            }
            .pickerStyle(.menu)
            .frame(maxWidth: 300)
        }
    }

    // MARK: - Search Bar

    private var searchBar: some View {
        HStack(spacing: DesignTokens.Spacing.gapRegular) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: DesignTokens.IconSize.medium))
                .foregroundStyle(DesignTokens.Text.tertiary)

            TextField("Search directories...", text: $searchText)
                .textFieldStyle(.plain)
                .font(brand: .body3)
                .foregroundStyle(DesignTokens.Text.primary)
                .focused($isSearchFocused)
                .onKeyPress(.downArrow, phases: [.down, .repeat]) { _ in
                    navigateDown()
                    return .handled
                }
                .onKeyPress(.upArrow, phases: [.down, .repeat]) { _ in
                    navigateUp()
                    return .handled
                }
                .onSubmit {
                    handleReturn()
                }
                .onChange(of: searchText) { _, _ in
                    selectedDirectoryIndex = filteredDirectories.isEmpty ? nil : 0
                }

            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: DesignTokens.IconSize.medium))
                        .foregroundStyle(DesignTokens.Text.tertiary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, DesignTokens.Spacing.itemPaddingHorizontal)
        .padding(.vertical, DesignTokens.Spacing.itemPaddingVertical + 2)
        .background {
            RoundedRectangle(cornerRadius: 8)
                .fill(DesignTokens.Surface.card)
                .overlay {
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(isSearchFocused ? DesignTokens.Border.regular : DesignTokens.Border.subtle, lineWidth: 1)
                }
        }
    }

    // MARK: - Directory List

    private var directoryList: some View {
        ScrollViewReader { scrollProxy in
            ScrollView {
                LazyVStack(spacing: DesignTokens.Spacing.gapTiny) {
                    ForEach(Array(filteredDirectories.enumerated()), id: \.element.id) { index, directory in
                        DirectoryRow(
                            directory: directory,
                            isSelected: selectedDirectoryIndex == index,
                            effectiveLayoutName: resolvedLayoutName(for: directory),
                            gitBranch: directory.gitBranch,
                            isWorktree: directory.isWorktree,
                            isFavorited: viewModel.isDirectoryFavorite(directory.path),
                            hasOverride: viewModel.directoryOverrideWorkspaceId(for: directory.path) != nil,
                            isEditorPresented: editorPresentationBinding(for: directory.path),
                            onTap: {
                                selectedDirectoryIndex = index
                            },
                            onDoubleTap: {
                                selectedDirectoryIndex = index
                                handleReturn()
                            },
                            onEditTap: {
                                selectedDirectoryIndex = index
                                editingDirectoryPath = directory.path
                            },
                            onFavoriteTap: {
                                viewModel.toggleDirectoryFavorite(for: directory.path)
                            },
                            editorContent: {
                                DirectoryLayoutPopover(
                                    directory: directory,
                                    savedWorkspaces: savedWorkspaces,
                                    currentOverrideWorkspaceId: viewModel.directoryOverrideWorkspaceId(for: directory.path),
                                    onSelection: { workspaceId in
                                        if let workspaceId {
                                            viewModel.setDirectoryOverride(for: directory.path, workspaceId: workspaceId)
                                        } else {
                                            viewModel.clearDirectoryOverride(for: directory.path)
                                        }
                                        editingDirectoryPath = nil
                                    },
                                    onCreateWorktree: directory.gitBranch != nil && !directory.isWorktree ? {
                                        editingDirectoryPath = nil
                                        viewModel.beginWorktreeCreation(for: directory)
                                    } : nil,
                                    onArchiveWorktree: directory.isWorktree ? {
                                        editingDirectoryPath = nil
                                        viewModel.beginArchiveWorktree(for: directory)
                                    } : nil,
                                    onRevealInFinder: {
                                        editingDirectoryPath = nil
                                        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: directory.path)
                                    }
                                )
                            }
                        )
                        .id(directory.id)
                    }
                }
            }
            .scrollBounceBehavior(.basedOnSize)
            .onChange(of: selectedDirectoryIndex) { _, selectedDirectoryIndex in
                guard let selectedDirectoryIndex,
                      filteredDirectories.indices.contains(selectedDirectoryIndex) else { return }
                let directoryID = filteredDirectories[selectedDirectoryIndex].id
                scrollProxy.scrollTo(directoryID, anchor: .center)
            }
        }
    }

    // MARK: - Empty States

    private var emptyWorkspacesState: some View {
        VStack(spacing: DesignTokens.Spacing.gapMedium) {
            Image(systemName: "rectangle.3.group")
                .font(.system(size: 32))
                .foregroundStyle(DesignTokens.Text.tertiary)

            Text("Create a workspace first")
                .font(brand: .h4)
                .foregroundStyle(DesignTokens.Text.secondary)

            Text("Quick Switch uses your saved workspace layouts to arrange windows. Create a workspace with your preferred terminal and IDE layout.")
                .font(brand: .body3)
                .foregroundStyle(DesignTokens.Text.tertiary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 400)

            Button {
                DeskJigContentView.sectionPublisher.send(.allWorkspaces)
            } label: {
                Text("Go to Workspaces")
                    .font(brand: .body3)
                    .foregroundStyle(DesignTokens.Text.primary)
                    .padding(.horizontal, DesignTokens.Spacing.cardPaddingSmall)
                    .padding(.vertical, DesignTokens.Spacing.gapSmall)
                    .background {
                        RoundedRectangle(cornerRadius: 6)
                            .fill(DesignTokens.Surface.elevated)
                    }
            }
            .buttonStyle(.plain)
            .brightenOnHover(0.1)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 60)
    }

    private var emptyRootFoldersState: some View {
        VStack(spacing: DesignTokens.Spacing.gapMedium) {
            Image(systemName: "folder.badge.plus")
                .font(.system(size: 32))
                .foregroundStyle(DesignTokens.Text.tertiary)

            Text("Add a root folder")
                .font(brand: .h4)
                .foregroundStyle(DesignTokens.Text.secondary)

            Text("Configure folders containing your projects (e.g., ~/code) to populate the directory list.")
                .font(brand: .body3)
                .foregroundStyle(DesignTokens.Text.tertiary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 400)

            Button {
                showFolderPicker()
            } label: {
                HStack(spacing: DesignTokens.Spacing.gapSmall) {
                    Image(systemName: "plus")
                        .font(.system(size: DesignTokens.IconSize.small, weight: .medium))
                    Text("Add Folder")
                        .font(brand: .body3)
                }
                .foregroundStyle(DesignTokens.Text.primary)
                .padding(.horizontal, DesignTokens.Spacing.cardPaddingSmall)
                .padding(.vertical, DesignTokens.Spacing.gapSmall)
                .background {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(DesignTokens.Surface.elevated)
                }
            }
            .buttonStyle(.plain)
            .brightenOnHover(0.1)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 60)
    }

    private var emptyDirectoriesState: some View {
        VStack(spacing: DesignTokens.Spacing.gapRegular) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 24))
                .foregroundStyle(DesignTokens.Text.tertiary)

            if searchText.isEmpty {
                Text("No directories found")
                    .font(brand: .body3)
                    .foregroundStyle(DesignTokens.Text.secondary)

                Text("Check that your root folders contain project directories.")
                    .font(brand: .body4)
                    .foregroundStyle(DesignTokens.Text.tertiary)
            } else {
                Text("No directories matching \"\(searchText)\"")
                    .font(brand: .body3)
                    .foregroundStyle(DesignTokens.Text.secondary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 40)
    }

    // MARK: - Navigation

    private func navigateDown() {
        guard !filteredDirectories.isEmpty else { return }

        if let idx = selectedDirectoryIndex {
            if idx < filteredDirectories.count - 1 {
                selectedDirectoryIndex = idx + 1
            }
        } else {
            selectedDirectoryIndex = 0
        }
    }

    private func navigateUp() {
        guard !filteredDirectories.isEmpty else { return }

        if let idx = selectedDirectoryIndex {
            if idx > 0 {
                selectedDirectoryIndex = idx - 1
            }
        } else {
            selectedDirectoryIndex = filteredDirectories.count - 1
        }
    }

    private func handleReturn() {
        guard let directory = selectedDirectory ?? filteredDirectories.first else { return }
        let workspace = viewModel.resolveDefaultWorkspace(for: directory.path, savedWorkspaces: savedWorkspaces)
            ?? savedWorkspaces.first
        guard let workspace else { return }

        viewModel.switchToDirectory(directory, layout: workspace, workspaceVM: workspaceVM)
    }

    private func handleEscape() {
        closeMainWindow()
    }

    private func requestSearchFocus() {
        isSearchFocused = false
        Task { @MainActor in
            await Task.yield()
            isSearchFocused = true
            await Task.sleepUnlessCancelled(nanoseconds: 60_000_000)
            isSearchFocused = true
        }
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

    private func startBranchPolling() {
        stopBranchPolling()
        branchRefreshTask = Task { @MainActor in
            while !Task.isCancelled {
                guard await Task.sleepUnlessCancelled(nanoseconds: 5_000_000_000) else { break } // 5 seconds
                guard !Task.isCancelled else { break }
                viewModel.refreshGitBranches()
            }
        }
    }

    private func stopBranchPolling() {
        branchRefreshTask?.cancel()
        branchRefreshTask = nil
    }

    private func closeMainWindow() {
        if let mainWindow = NSApplication.shared.windows.first(where: { $0.title == DeskJigApp.mainWindowTitle }) {
            mainWindow.close()
            return
        }

        if let keyWindow = NSApplication.shared.keyWindow {
            keyWindow.close()
            return
        }

        NSApplication.shared.mainWindow?.close()
    }

    private func resolvedLayoutName(for directory: ScannedDirectory) -> String {
        viewModel.resolveDefaultWorkspace(for: directory.path, savedWorkspaces: savedWorkspaces)?.name ?? "No layout"
    }

    private func editorPresentationBinding(for directoryPath: String) -> Binding<Bool> {
        Binding(
            get: { editingDirectoryPath == directoryPath },
            set: { isPresented in
                if isPresented {
                    editingDirectoryPath = directoryPath
                } else if editingDirectoryPath == directoryPath {
                    editingDirectoryPath = nil
                }
            }
        )
    }

}

enum QuickSwitchSearch {
    private struct RankedDirectory {
        let directory: ScannedDirectory
        let score: Int
    }

    static func rankedDirectories(
        _ directories: [ScannedDirectory],
        query: String,
        favoriteDirectoryPaths: Set<String>
    ) -> [ScannedDirectory] {
        let tokens = tokenize(query)
        let ranked = directories.compactMap { directory -> RankedDirectory? in
            if tokens.isEmpty {
                return RankedDirectory(directory: directory, score: 0)
            }
            guard let score = score(directory: directory, tokens: tokens) else {
                return nil
            }
            return RankedDirectory(directory: directory, score: score)
        }

        return ranked
            .sorted {
                compare(
                    lhs: $0,
                    rhs: $1,
                    favoriteDirectoryPaths: favoriteDirectoryPaths
                )
            }
            .map(\.directory)
    }

    private static func tokenize(_ query: String) -> [String] {
        normalize(query)
            .split(whereSeparator: { $0.isWhitespace || $0 == "/" || $0 == "\\" })
            .map(String.init)
            .filter { !$0.isEmpty }
    }

    private static func score(directory: ScannedDirectory, tokens: [String]) -> Int? {
        let normalizedName = normalize(directory.name)
        let normalizedPath = normalize(directory.path)
        let normalizedShortPath = normalize(abbreviatedPath(directory.path))
        let normalizedBranch = normalize(directory.gitBranch ?? "")
        let hasBranch = !normalizedBranch.isEmpty

        var totalScore = 0
        for token in tokens {
            let inName = normalizedName.contains(token)
            let inPath = normalizedPath.contains(token) || normalizedShortPath.contains(token)
            let inBranch = hasBranch && normalizedBranch.contains(token)
            guard inName || inPath || inBranch else { return nil }

            if inName {
                if normalizedName == token {
                    totalScore += 260
                } else if normalizedName.hasPrefix(token) {
                    totalScore += 190
                } else {
                    totalScore += 130
                }
            }

            if inPath {
                totalScore += inName ? 18 : 54
                if normalizedShortPath.hasSuffix("/\(token)") || normalizedPath.hasSuffix("/\(token)") {
                    totalScore += 20
                }
            }

            if inBranch {
                if normalizedBranch == token {
                    totalScore += 210
                } else if normalizedBranch.hasPrefix(token) {
                    totalScore += 150
                } else {
                    totalScore += 98
                }

                if inName || inPath {
                    totalScore += 12
                }
            }
        }

        let fullQuery = tokens.joined(separator: " ")
        if normalizedName.hasPrefix(fullQuery) {
            totalScore += 56
        } else if normalizedName.contains(fullQuery) {
            totalScore += 26
        } else if normalizedBranch.hasPrefix(fullQuery) {
            totalScore += 36
        } else if normalizedBranch.contains(fullQuery) {
            totalScore += 22
        } else if normalizedPath.contains(fullQuery) || normalizedShortPath.contains(fullQuery) {
            totalScore += 14
        }

        return totalScore
    }

    private static func normalize(_ value: String) -> String {
        value.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
    }

    private static func abbreviatedPath(_ path: String) -> String {
        let homePath = FileManager.default.homeDirectoryForCurrentUser.path
        if path.hasPrefix(homePath) {
            return "~" + path.dropFirst(homePath.count)
        }
        return path
    }

    private static func compare(
        lhs: RankedDirectory,
        rhs: RankedDirectory,
        favoriteDirectoryPaths: Set<String>
    ) -> Bool {
        let lhsFavorited = favoriteDirectoryPaths.contains(lhs.directory.path)
        let rhsFavorited = favoriteDirectoryPaths.contains(rhs.directory.path)
        if lhsFavorited != rhsFavorited {
            return lhsFavorited
        }

        if lhs.score != rhs.score {
            return lhs.score > rhs.score
        }

        let nameCompare = lhs.directory.name.localizedCaseInsensitiveCompare(rhs.directory.name)
        if nameCompare == .orderedSame {
            let lhsDepth = pathDepth(lhs.directory.path)
            let rhsDepth = pathDepth(rhs.directory.path)
            if lhsDepth != rhsDepth {
                return lhsDepth < rhsDepth
            }
            if lhs.directory.path.count != rhs.directory.path.count {
                return lhs.directory.path.count < rhs.directory.path.count
            }
        } else {
            return nameCompare == .orderedAscending
        }

        return lhs.directory.path.localizedCaseInsensitiveCompare(rhs.directory.path) == .orderedAscending
    }

    private static func pathDepth(_ path: String) -> Int {
        path.split(separator: "/").count
    }
}

struct QuickSwitchShortcutRecorder: View {
    var showHelpIcon: Bool = false

    var body: some View {
        DSHotkeyBadge(
            shortcut: nil,
            size: .small,
            showHelpIcon: showHelpIcon,
            shortcutName: .quickSwitch
        ) {
            DSHotkeyRecorderPopover(name: .quickSwitch)
        }
    }
}

// MARK: - DirectoryRow

private struct DirectoryRow<EditorContent: View>: View {
    let directory: ScannedDirectory
    let isSelected: Bool
    let effectiveLayoutName: String
    let gitBranch: String?
    let isWorktree: Bool
    let isFavorited: Bool
    let hasOverride: Bool
    @Binding var isEditorPresented: Bool
    let onTap: () -> Void
    let onDoubleTap: () -> Void
    let onEditTap: () -> Void
    let onFavoriteTap: () -> Void
    let editorContent: () -> EditorContent

    @State private var isHovering: Bool = false

    var body: some View {
        HStack(spacing: DesignTokens.Spacing.gapRegular) {
            Button {
                onTap()
            } label: {
                HStack(spacing: DesignTokens.Spacing.gapRegular) {
                    Image(systemName: isWorktree ? "arrow.triangle.branch" : "folder.fill")
                        .font(.system(size: DesignTokens.IconSize.medium))
                        .foregroundStyle(isWorktree ? DesignTokens.Status.info : DesignTokens.Text.tertiary)
                        .frame(width: DesignTokens.IconSize.xLarge)

                    HStack(spacing: DesignTokens.Spacing.gapSmall) {
                        Text(directory.name)
                            .font(brand: .body3)
                            .foregroundStyle(DesignTokens.Text.primary)
                            .lineLimit(1)
                            .layoutPriority(2)

                        Text("|")
                            .font(brand: .label4)
                            .foregroundStyle(DesignTokens.Text.muted)

                        Text(relativePath)
                            .font(brand: .label4)
                            .foregroundStyle(DesignTokens.Text.tertiary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .layoutPriority(1)

                        if let gitBranchLabel {
                            DSTag(label: gitBranchLabel, color: DesignTokens.Status.info, size: .small)
                                .fixedSize(horizontal: true, vertical: false)
                                .accessibilityLabel("Git branch \(gitBranchLabel)")
                        }

                        if isWorktree {
                            DSTag(label: "worktree", color: DesignTokens.Text.tertiary, size: .small)
                                .fixedSize(horizontal: true, vertical: false)
                        }
                    }

                    Spacer()

                    layoutBadge
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .simultaneousGesture(
                TapGesture(count: 2).onEnded { onDoubleTap() }
            )

            if shouldShowRowActions {
                starButton
            }

            if isHovering || isSelected || isEditorPresented {
                gearButton
            }
        }
        .padding(.horizontal, DesignTokens.Spacing.itemPaddingHorizontal)
        .padding(.vertical, DesignTokens.Spacing.itemPaddingVertical)
        .background {
            RoundedRectangle(cornerRadius: 8)
                .fill(backgroundColor)
        }
        .onHover { isHovering = $0 }
        .animation(.smooth(duration: 0.15), value: isHovering)
        .animation(.smooth(duration: 0.15), value: isSelected)
        .animation(.smooth(duration: 0.15), value: isEditorPresented)
    }

    private var layoutBadge: some View {
        HStack(spacing: DesignTokens.Spacing.gapTiny) {
            if hasOverride {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: DesignTokens.IconSize.tiny))
            }
            Text(effectiveLayoutName)
                .font(brand: .label4)
                .lineLimit(1)
        }
        .foregroundStyle(hasOverride ? DesignTokens.Text.primary : DesignTokens.Text.tertiary)
        .padding(.horizontal, DesignTokens.Spacing.gapSmall)
        .padding(.vertical, 4)
        .background {
            RoundedRectangle(cornerRadius: 6)
                .fill(hasOverride ? DesignTokens.Surface.elevated : DesignTokens.Surface.window)
                .overlay {
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(DesignTokens.Border.subtle, lineWidth: 1)
                }
        }
    }

    private var starButton: some View {
        Button {
            onFavoriteTap()
        } label: {
            Image(systemName: isFavorited ? "star.fill" : "star")
                .font(.system(size: DesignTokens.IconSize.small, weight: .medium))
                .foregroundStyle(isFavorited ? DesignTokens.Text.primary : DesignTokens.Text.tertiary)
                .frame(width: 24, height: 24)
                .background {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(DesignTokens.Surface.window)
                }
        }
        .buttonStyle(.plain)
        .help("Favorite this directory for Quick Switch")
        .accessibilityLabel("Favorite this directory for Quick Switch")
    }

    private var gearButton: some View {
        Button {
            onEditTap()
            isEditorPresented = true
        } label: {
            Image(systemName: hasOverride ? "gearshape.fill" : "gearshape")
                .font(.system(size: DesignTokens.IconSize.small, weight: .medium))
                .foregroundStyle(hasOverride ? DesignTokens.Text.primary : DesignTokens.Text.tertiary)
                .frame(width: 24, height: 24)
                .background {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(DesignTokens.Surface.window)
                }
        }
        .buttonStyle(.plain)
        .help("Set default layout for this directory")
        .accessibilityLabel("Set default layout for this directory")
        .popover(isPresented: $isEditorPresented, arrowEdge: .trailing) {
            editorContent()
        }
    }

    private var shouldShowRowActions: Bool {
        isHovering || isSelected || isEditorPresented || isFavorited
    }

    private var relativePath: String {
        let homePath = FileManager.default.homeDirectoryForCurrentUser.path
        if directory.path.hasPrefix(homePath) {
            return "~" + directory.path.dropFirst(homePath.count)
        }
        return directory.path
    }

    private var gitBranchLabel: String? {
        guard let gitBranch else { return nil }
        let trimmed = gitBranch.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private var backgroundColor: Color {
        if isSelected {
            return DesignTokens.Surface.cardHover
        } else if isHovering {
            return DesignTokens.Surface.card
        } else {
            return .clear
        }
    }
}

private struct DirectoryLayoutPopover: View {
    let directory: ScannedDirectory
    let savedWorkspaces: [Workspace]
    let currentOverrideWorkspaceId: UUID?
    let onSelection: (UUID?) -> Void
    var onCreateWorktree: (() -> Void)? = nil
    var onArchiveWorktree: (() -> Void)? = nil
    var onRevealInFinder: (() -> Void)? = nil

    @FocusState private var isPickerFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.gapRegular) {
            Text("Default layout for \(directory.name)")
                .font(brand: .body3)
                .foregroundStyle(DesignTokens.Text.primary)

            Text(relativePath)
                .font(brand: .label4)
                .foregroundStyle(DesignTokens.Text.tertiary)
                .lineLimit(1)
                .truncationMode(.middle)

            Picker("Layout", selection: Binding(
                get: { currentOverrideWorkspaceId?.uuidString ?? "" },
                set: { newValue in
                    if newValue.isEmpty {
                        onSelection(nil)
                    } else if let workspaceId = UUID(uuidString: newValue) {
                        onSelection(workspaceId)
                    }
                }
            )) {
                Text("Use global default")
                    .tag("")
                ForEach(savedWorkspaces) { workspace in
                    Text(workspace.name)
                        .tag(workspace.id.uuidString)
                }
            }
            .pickerStyle(.menu)
            .focused($isPickerFocused)

            if onCreateWorktree != nil || onArchiveWorktree != nil || onRevealInFinder != nil {
                Divider()
                    .background(DesignTokens.Border.subtle)

                VStack(alignment: .leading, spacing: DesignTokens.Spacing.gapTiny) {
                    if let onCreateWorktree {
                        Button {
                            onCreateWorktree()
                        } label: {
                            Label("Create Worktree...", systemImage: "arrow.triangle.branch")
                                .font(brand: .body4)
                                .foregroundStyle(DesignTokens.Text.primary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.vertical, 4)
                                .padding(.horizontal, 6)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .brightenOnHover(0.1)
                    }

                    if let onArchiveWorktree {
                        Button {
                            onArchiveWorktree()
                        } label: {
                            Label("Archive Worktree...", systemImage: "archivebox")
                                .font(brand: .body4)
                                .foregroundStyle(DesignTokens.Status.error)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.vertical, 4)
                                .padding(.horizontal, 6)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .brightenOnHover(0.1)
                    }

                    if let onRevealInFinder {
                        Button {
                            onRevealInFinder()
                        } label: {
                            Label("Reveal in Finder", systemImage: "folder")
                                .font(brand: .body4)
                                .foregroundStyle(DesignTokens.Text.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.vertical, 4)
                                .padding(.horizontal, 6)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .brightenOnHover(0.1)
                    }
                }
            }
        }
        .padding(DesignTokens.Spacing.cardPaddingSmall)
        .frame(width: 320)
        .onAppear {
            isPickerFocused = false
            Task { @MainActor in
                await Task.yield()
                isPickerFocused = true
            }
        }
    }

    private var relativePath: String {
        let homePath = FileManager.default.homeDirectoryForCurrentUser.path
        if directory.path.hasPrefix(homePath) {
            return "~" + directory.path.dropFirst(homePath.count)
        }
        return directory.path
    }
}
