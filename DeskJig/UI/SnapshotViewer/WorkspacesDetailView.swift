//
//  WorkspacesDetailView.swift
//  DeskJig
//
//  Enhanced detail view for Workspaces section - workspace list with actions,
//  visual preview, per-window strategy configuration, and debug logging.
//

import SwiftUI
import AppKit
import DeskJigShared

struct WorkspacesDetailView: View {
    @Bindable var viewModel: SnapshotViewerViewModel
    @State private var selectedWorkspace: WorkspaceHandle?
    @State private var strategyManager = LaunchStrategyManager()
    @State private var previousWorkspaceId: UUID?

    // Lock manager for window positioning
    private let lockManager = WindowLockManager()

    private var restorationController: WorkspaceRestorationController {
        WorkspaceRestorationController(strategyManager: strategyManager, lockManager: lockManager)
    }

    var body: some View {
        HSplitView {
            // Workspace list
            workspaceListPane
                .frame(minWidth: 300, idealWidth: 400)

            // Workspace detail (when selected)
            if let workspace = selectedWorkspace {
                workspaceDetailPane(workspace: workspace)
                    .frame(minWidth: 450)
            } else {
                emptyDetailPane
                    .frame(minWidth: 300)
            }
        }
        .onChange(of: selectedWorkspace?.id) { oldValue, newValue in
            // Reset strategy manager when workspace selection changes
            if oldValue != newValue {
                if let workspace = selectedWorkspace {
                    strategyManager.prepareForWorkspace(workspace)
                } else {
                    strategyManager.reset()
                }
                previousWorkspaceId = newValue
            }
        }
    }

    // MARK: - Workspace List Pane

    private var workspaceListPane: some View {
        VStack(spacing: 0) {
            // Header with count and search
            VStack(spacing: 12) {
                HStack {
                    Text("Workspaces")
                        .font(.headline)

                    Spacer()

                    Text("\(Workspaces.count) total")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    if !Workspaces.isEmpty {
                        Text("\u{2022} \(viewModel.recentWorkspaces.count) recent")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }

                // Search field
                HStack {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.tertiary)
                    TextField("Search workspaces...", text: $viewModel.workspaceSearchQuery)
                        .textFieldStyle(.plain)
                    if !viewModel.workspaceSearchQuery.isEmpty {
                        Button {
                            viewModel.workspaceSearchQuery = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.tertiary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(8)
                .background(DesignTokens.Surface.cardHover)
                .cornerRadius(6)
            }
            .padding()

            Divider()

            // Operation result message
            if let result = viewModel.workspaceOperationResult {
                HStack {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(DesignTokens.Brand.accent)
                    Text(result)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(DesignTokens.Brand.accent.opacity(0.12))

                Divider()
            }

            // Workspace list
            if viewModel.filteredWorkspaceHandles.isEmpty {
                emptyWorkspaceState
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(viewModel.filteredWorkspaceHandles, id: \.id) { handle in
                            WorkspaceCard(
                                handle: handle,
                                isSelected: selectedWorkspace?.id == handle.id,
                                onSelect: { selectedWorkspace = handle },
                                onLegacyRestore: { viewModel.restoreWorkspace(handle) },
                                onFluentRestore: {
                                    selectedWorkspace = handle
                                    strategyManager.prepareForWorkspace(handle)
                                    restorationController.launchWorkspace(handle, source: "workspaceRowFluent")
                                },
                                onFluentRestorerRestore: {
                                    selectedWorkspace = handle
                                    strategyManager.prepareForWorkspace(handle)
                                    launchFluentWorkspaceRestorer(handle, source: "workspaceRowFluentRestorer")
                                }
                            )
                        }
                    }
                    .padding()

                    // Cache data section at bottom
                    if viewModel.cacheInfo != nil {
                        Divider()
                            .padding(.horizontal)
                        cacheDataSection
                            .padding()
                    }
                }
            }
        }
        .task {
            viewModel.loadCacheInfo()
        }
    }

    private var emptyWorkspaceState: some View {
        VStack(spacing: 12) {
            Image(systemName: "tray")
                .font(.largeTitle)
                .foregroundStyle(.tertiary)
            Text(viewModel.workspaceSearchQuery.isEmpty ? "No Workspaces" : "No Matching Workspaces")
                .font(.headline)
                .foregroundStyle(.secondary)
            Text(viewModel.workspaceSearchQuery.isEmpty
                ? "Save a workspace to see it here"
                : "Try a different search term")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Empty Detail Pane

    private var emptyDetailPane: some View {
        VStack(spacing: 12) {
            Image(systemName: "sidebar.right")
                .font(.largeTitle)
                .foregroundStyle(.tertiary)
            Text("Select a Workspace")
                .font(.headline)
                .foregroundStyle(.secondary)
            Text("Choose a workspace from the list to view details")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(DesignTokens.Surface.card)
    }

    // MARK: - Enhanced Workspace Detail Pane

    private func workspaceDetailPane(workspace: WorkspaceHandle) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // 1. Header Section
                headerSection(workspace: workspace)

                Divider()

                // 2. Visual Preview Section with Screen Mapping
                WorkspacePreviewSection(
                    windows: workspace.windows,
                    screens: workspace.screens,
                    iconProvider: iconProvider,
                    selectedWindowId: strategyManager.selectedWindowId,
                    onWindowTapped: { window in
                        strategyManager.selectedWindowId = window.id
                    },
                    currentSystemScreens: ScreenOption.fromCurrentScreens(),
                    screenMappings: strategyManager.screenMappings,
                    onScreenMappingChanged: { originalIndex, targetIndex in
                        strategyManager.setScreenMapping(targetIndex, for: originalIndex)
                        // Propagate to per-window overrides for all windows on this screen
                        for window in workspace.windows where window.screenIndex == originalIndex {
                            strategyManager.setScreenOverride(targetIndex, for: window.id)
                        }
                    }
                )

                Divider()

                // 3. Windows List Section
                windowsListSection(workspace: workspace)

                Divider()

                // 4. Launch Configuration Section
                LaunchConfigurationSection(
                    strategyManager: strategyManager,
                    workspace: workspace,
                    onLaunch: {
                        restorationController.launchWorkspace(workspace, source: "workspaceLaunchButton")
                    }
                )

                // 5. Debug Log Section (collapsible)
                debugLogSection

                // 6. Quick Actions and Metadata (collapsed)
                DisclosureGroup {
                    VStack(alignment: .leading, spacing: 16) {
                        quickActionsSection(workspace: workspace)
                        Divider()
                        metadataSection(workspace: workspace)
                        RenameSection(handle: workspace)
                    }
                } label: {
                    Text("More Options")
                        .font(.subheadline)
                        .fontWeight(.semibold)
                        .foregroundStyle(.secondary)
                }
            }
            .padding()
        }
        .background(DesignTokens.Surface.card)
    }

    // MARK: - Header Section

    private func headerSection(workspace: WorkspaceHandle) -> some View {
        HStack {
            if let icon = workspace.icon {
                Text(icon)
                    .font(.largeTitle)
            } else {
                Image(systemName: "square.stack.3d.up.fill")
                    .font(.largeTitle)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(workspace.name)
                    .font(.title2)
                    .fontWeight(.semibold)

                HStack(spacing: 8) {
                    Text("\(workspace.windowCount) windows")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                    if let screens = workspace.screens {
                        Text("\u{2022} \(screens.count) screens")
                            .font(.subheadline)
                            .foregroundStyle(.tertiary)
                    }
                }
            }

            Spacer()
        }
    }

    // MARK: - Windows List Section

    private func windowsListSection(workspace: WorkspaceHandle) -> some View {
        let availableScreens = ScreenOption.fromCurrentScreens()

        return VStack(alignment: .leading, spacing: 10) {
            Text("Windows")
                .font(.subheadline)
                .fontWeight(.semibold)
                .foregroundStyle(.secondary)

            // Group windows by type
            let groupedWindows = groupWindowsByType(workspace.windows)

            ForEach(groupedWindows.keys.sorted(), id: \.self) { groupName in
                if let windows = groupedWindows[groupName], !windows.isEmpty {
                    windowGroup(title: groupName, windows: windows, availableScreens: availableScreens)
                }
            }
        }
    }

    private func windowGroup(title: String, windows: [WorkspaceWindow], availableScreens: [ScreenOption]) -> some View {
        DisclosureGroup {
            VStack(spacing: 4) {
                ForEach(windows) { window in
                    WorkspaceWindowDetailRow(
                        window: window,
                        iconProvider: iconProvider,
                        strategyManager: strategyManager,
                        availableScreens: availableScreens,
                        isSelected: strategyManager.selectedWindowId == window.id,
                        onSelect: {
                            strategyManager.selectedWindowId = window.id
                        },
                        onLaunchWindow: { windowToLaunch in
                            restorationController.launchSingleWindow(windowToLaunch)
                        }
                    )
                }
            }
        } label: {
            HStack {
                Text(title)
                    .font(.caption)
                    .fontWeight(.medium)
                Text("\(windows.count)")
                    .font(.caption2)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(DesignTokens.Surface.elevated)
                    .cornerRadius(4)
            }
        }
    }

    private func groupWindowsByType(_ windows: [WorkspaceWindow]) -> [String: [WorkspaceWindow]] {
        var groups: [String: [WorkspaceWindow]] = [:]

        for window in windows {
            let groupName: String
            if chromeBundleIdentifiers.contains(window.bundleIdentifier) {
                groupName = "Chrome"
            } else if OpenByPathBundleIdentifiers.supported.contains(window.bundleIdentifier) {
                groupName = "Terminals & IDEs"
            } else {
                groupName = "Other Apps"
            }
            groups[groupName, default: []].append(window)
        }

        return groups
    }

    // MARK: - Debug Log Section

    private var debugLogSection: some View {
        DisclosureGroup(isExpanded: $strategyManager.isDebugLogExpanded) {
            RestoreDebugLogView(strategyManager: strategyManager)
        } label: {
            HStack {
                Text("Debug Log")
                    .font(.subheadline)
                    .fontWeight(.semibold)
                    .foregroundStyle(.secondary)

                if !strategyManager.logEntries.isEmpty {
                    Text("\(strategyManager.logEntries.count)")
                        .font(.caption2)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(DesignTokens.Brand.accent.opacity(0.2))
                        .foregroundStyle(DesignTokens.Brand.accent)
                        .cornerRadius(4)
                }

                if strategyManager.isLaunching {
                    ProgressView()
                        .scaleEffect(0.6)
                }
            }
        }
    }

    // MARK: - Quick Actions Section

    private func quickActionsSection(workspace: WorkspaceHandle) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Quick Actions")
                .font(.headline)

            HStack(spacing: 12) {
                actionButton(
                    title: "Restore",
                    icon: "arrow.counterclockwise",
                    color: DesignTokens.Brand.accent
                ) {
                    viewModel.restoreWorkspace(workspace)
                }

                actionButton(
                    title: "Duplicate",
                    icon: "doc.on.doc",
                    color: DesignTokens.Brand.accent
                ) {
                    viewModel.duplicateWorkspace(workspace)
                }

                actionButton(
                    title: "Delete",
                    icon: "trash",
                    color: DesignTokens.Status.error
                ) {
                    viewModel.deleteWorkspace(workspace)
                    selectedWorkspace = nil
                }
            }
        }
    }

    // MARK: - Metadata Section

    private func metadataSection(workspace: WorkspaceHandle) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Details")
                .font(.headline)

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                detailItem(label: "ID", value: String(workspace.id.uuidString.prefix(8)) + "...")
                detailItem(label: "Window Count", value: "\(workspace.windowCount)")
                detailItem(label: "Created", value: workspace.createdAt.formatted(date: .abbreviated, time: .shortened))
                if let lastActivated = workspace.lastActivatedAt {
                    detailItem(label: "Last Activated", value: lastActivated.formatted(date: .abbreviated, time: .shortened))
                }
            }
        }
    }


    private func iconProvider(_ window: WorkspaceWindow) -> NSImage? {
        guard let appPath = window.applicationPath else {
            return NSWorkspace.shared.icon(forFile: "/System/Applications/Utilities/Terminal.app")
        }
        return NSWorkspace.shared.icon(forFile: appPath)
    }

    private func detailItem(label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.tertiary)
            Text(value)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .background(DesignTokens.Surface.card)
        .cornerRadius(6)
    }

    private func actionButton(title: String, icon: String, color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.title3)
                Text(title)
                    .font(.caption)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
        }
        .buttonStyle(.bordered)
        .tint(color)
    }

    // MARK: - Cache Data Section

    @ViewBuilder
    private var cacheDataSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Storage Cache")
                    .font(.headline)

                Spacer()

                Button {
                    viewModel.loadCacheInfo()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .help("Refresh cache info")
            }

            if let cache = viewModel.cacheInfo {
                HStack(alignment: .top, spacing: 12) {
                    // Local cache card
                    cacheCard(
                        title: "Local Cache",
                        icon: "internaldrive",
                        details: [
                            ("Key", cache.localCacheKey),
                            ("Workspaces", "\(cache.localCacheWorkspaceCount)"),
                            ("Size", ByteCountFormatter.string(fromByteCount: Int64(cache.localCacheSizeBytes), countStyle: .file))
                        ]
                    )
                }
            }
        }
    }

    private func cacheCard(title: String, icon: String, details: [(String, String)]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: icon)
                    .foregroundStyle(.secondary)
                Text(title)
                    .font(.subheadline)
                    .fontWeight(.medium)
            }

            ForEach(details, id: \.0) { label, value in
                HStack {
                    Text(label)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                    Spacer()
                    Text(value)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DesignTokens.Surface.card)
        .cornerRadius(8)
    }

    private func launchFluentWorkspaceRestorer(_ handle: WorkspaceHandle, source: String) {
        if strategyManager.isDryRun {
            DeskJigLog.debug(.workspace, "FluentWorkspaceRestorer skipped (dryRun)", fields: ["source": source, "workspace": handle.name])
            return
        }

        DeskJigLog.debug(.workspace, "FluentWorkspaceRestorer triggered", fields: ["workspace": handle.name, "source": source])

        let workspace = handle.underlyingWorkspace
        let maxConcurrency = strategyManager.executionMode == .synchronous ? 1 : RestorationOptions.default.maxConcurrency
        let chromeFetchMethod: ChromeFetchMethod = strategyManager.enableChromeSupplementation
            ? strategyManager.chromeFetchMethod
            : .disabled
        let terminalFetchMethod: TerminalFetchMethod = strategyManager.enableTerminalSupplementation
            ? strategyManager.terminalFetchMethod
            : .disabled
        let ideFetchMethod: IDEFetchMethod = strategyManager.enableIDESupplementation
            ? strategyManager.ideFetchMethod
            : .disabled

        let options = RestorationOptions(
            lockTimeout: .seconds(strategyManager.lockTimeout),
            maxConcurrency: maxConcurrency,
            includeChromeCapture: strategyManager.enableChromeSupplementation,
            includeAXEnrichment: strategyManager.enableIDESupplementation,
            hideAllAppsBeforeRestore: UserDefaults.standard.bool(forKey: "restoreHideAllApps"),
            chromeFetchMethod: chromeFetchMethod,
            terminalFetchMethod: terminalFetchMethod,
            ideFetchMethod: ideFetchMethod
        )

        Task {
            let restorer = FluentWorkspaceRestorer.shared
            do {
                let result = try await restorer.restore(workspace: workspace, options: options)
                DeskJigLog.debug(.workspace, "FluentWorkspaceRestorer complete", fields: [
                    "success": result.success,
                    "restored": result.windowsRestored,
                    "failed": result.windowsFailed,
                    "skipped": result.windowsSkipped
                ], runId: result.runId)
            } catch {
                DeskJigLog.error(.workspace, "FluentWorkspaceRestorer failed", fields: [
                    "workspace": handle.name,
                    "error": error.localizedDescription
                ])
            }
        }
    }
}

// MARK: - Workspace Card

struct WorkspaceCard: View {
    let handle: WorkspaceHandle
    let isSelected: Bool
    let onSelect: () -> Void
    let onLegacyRestore: () -> Void
    let onFluentRestore: () -> Void
    let onFluentRestorerRestore: () -> Void

    var body: some View {
        HStack {
            // Icon
            if let icon = handle.icon {
                Text(icon)
                    .font(.title2)
                    .frame(width: 40)
            } else {
                Image(systemName: "square.stack")
                    .font(.title2)
                    .foregroundStyle(.secondary)
                    .frame(width: 40)
            }

            // Info
            VStack(alignment: .leading, spacing: 4) {
                Text(handle.name)
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .lineLimit(1)

                HStack(spacing: 8) {
                    Text("\(handle.windowCount) windows")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    if let lastActivated = handle.lastActivatedAt {
                        Text("\u{2022}")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                        Text(lastActivated.formatted(date: .abbreviated, time: .omitted))
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
            }

            Spacer()

            // Quick restore button
            HStack(spacing: 8) {
                Button(action: onLegacyRestore) {
                    Image(systemName: "arrow.counterclockwise")
                        .font(.caption)
                }
                .buttonStyle(.bordered)
                .tint(DesignTokens.Brand.accent)
                .help("Restore workspace (Legacy)")

                Button(action: onFluentRestore) {
                    Image(systemName: "play.fill")
                        .font(.caption)
                }
                .buttonStyle(.bordered)
                .tint(DesignTokens.Brand.accent)
                .help("Restore workspace (Fluent)")

                Button(action: onFluentRestorerRestore) {
                    Image(systemName: "sparkles")
                        .font(.caption)
                }
                .buttonStyle(.bordered)
                .tint(DesignTokens.Brand.accent)
                .help("Restore workspace (Fluent v2)")
            }
        }
        .padding()
        .background(isSelected ? DesignTokens.Brand.accent.opacity(0.15) : DesignTokens.Surface.card)
        .cornerRadius(8)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(isSelected ? DesignTokens.Brand.accent : Color.clear, lineWidth: 2)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            onSelect()
        }
    }
}

// MARK: - Rename Section

struct RenameSection: View {
    let handle: WorkspaceHandle
    @State private var isRenaming = false
    @State private var newName: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Rename")
                .font(.headline)

            if isRenaming {
                HStack {
                    TextField("New name", text: $newName)
                        .textFieldStyle(.roundedBorder)

                    Button("Save") {
                        _ = handle.rename(newName).save()
                        isRenaming = false
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(newName.isEmpty)

                    Button("Cancel") {
                        isRenaming = false
                    }
                    .buttonStyle(.bordered)
                }
            } else {
                Button {
                    newName = handle.name
                    isRenaming = true
                } label: {
                    Label("Rename Workspace", systemImage: "pencil")
                }
                .buttonStyle(.bordered)
            }
        }
    }
}
