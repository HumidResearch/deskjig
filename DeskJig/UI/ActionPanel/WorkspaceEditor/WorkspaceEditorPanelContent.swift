//  WorkspaceEditorPanelContent.swift
//  DeskJig
//
//  Main content view for the workspace editor panel
//

import SwiftUI
import AppKit
import DeskJigShared
import KeyboardShortcuts

/// Represents user modifications to a Chrome window's tabs and profile
struct ChromeWindowModification {
    var tabURLs: [String]
    var profileDirectory: String?
    var profileDisplayName: String?
    var profileHostedDomain: String?
    var profileUserName: String?
    var profileMatchMode: ChromeProfileMatchMode = .specific
}

/// Represents user modifications to an app window's "open by path" behavior.
struct OpenByPathWindowModification {
    var bundleIdentifier: String
    var windowTitle: String
    var openPath: String?
}

struct WorkspaceEditorPanelContent: View {
    
    let editedWorkspace: WorkspaceViewModel.EditingWorkspace
    var workspace: Workspace { editedWorkspace.workspace }
    @Bindable var workspaceVM: WorkspaceViewModel
    weak var actionPanelManager: ActionPanelManager?
    let onDismiss: () -> Void
    var onHeightChanged: ((Bool) -> Void)? = nil
    
    @State private var previewWindows: [WorkspaceWindow] = []
    @State private var previewScreens: [WorkspaceScreen] = []
    @State private var name: String = ""
    @State private var icon: String = Self.defaultEmoji
    @State private var isPickingIcon: Bool = false
    @State private var selectedScreenIndices: Set<Int> = []
    @State private var isConfirmingDelete: Bool = false
    @State private var isConfirmingEditLayout: Bool = false
    @State private var selectedChromeWindow: WorkspaceWindow? = nil
    @State private var selectedOpenByPathWindow: WorkspaceWindow? = nil
    @State private var previewRefreshTask: Task<Void, Never>? = nil
    @State private var isPreviewRefreshing = false
    /// Tracks modified Chrome state for each window by window ID
    @State private var chromeModifications: [UUID: ChromeWindowModification] = [:]
    /// Tracks modified open-by-path state for each window by window ID
    @State private var openByPathModifications: [UUID: OpenByPathWindowModification] = [:]
    @State private var openByPathValidationError: String? = nil
    @FocusState private var isFocused: Bool
    
    static let defaultEmoji: String = "📁"
    static let workspaceEmojis: [String] = [
        "📁", "🗂️", "🧭", "🪶", "🪄", "⚙️", "🧱", "💻", "🧑‍💻", "🧠", "🧩", "🔧", "🧰",
        "📡", "🎨", "✏️", "🖌️", "🧵", "📸", "🎬", "🪩", "🤝", "🏠", "🫶", "🧺", "📊",
        "🏗️", "🌱", "🌿", "🌸", "☀️", "🌙", "🔮", "📖", "🪴", "🔥", "⚡", "🚀", "🎯",
        "⏳", "🗄️", "💡", "🔒", "💼", "🧾", "📈", "🏦", "🧮", "💬", "🌍", "🕸️", "🏛️",
    ]
    private let previewRefreshIntervalNs: UInt64 = 500_000_000

    private var availableScreens: [FullScreenInfo] {
        WorkspaceDisplayTopology.effectiveScreens(from: workspaceVM.windowManager.displayManager)
    }

    private var shouldAutoRefreshPreview: Bool {
        editedWorkspace.isNew || workspaceVM.isEditingLayout
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            // Header with name, icon, and delete button
            HStack(spacing: 16) {
                iconPicker
                textField
                
                Spacer()
                
                // Delete button (only for existing workspaces and NOT in layout editing mode)
                if !editedWorkspace.isNew && !workspaceVM.isEditingLayout {
                    Button(action: {
                        isConfirmingDelete = true
                    }) {
                        Image(systemName: "trash")
                            .font(brand: Font.brandBody(size: 16))
                            .foregroundStyle(DesignTokens.Text.secondary)
                            .padding(8)
                            .background {
                                Circle()
                                    .fill(DesignTokens.Surface.elevated)
                                    .stroke(DesignTokens.Border.subtle, lineWidth: 1)
                            }
                            .brightenOnHover()
                    }
                    .buttonStyle(.plain)
                }
            }
            
            // Divider after header
            Divider()
                .background(DesignTokens.Border.subtle)
                .padding(.bottom, 8)
            
            // Content section - two column layout
            VStack(spacing: 16) {
                // Keyboard shortcut row (ONLY show when editing existing workspace AND NOT in layout editing mode)
                if !editedWorkspace.isNew && !workspaceVM.isEditingLayout {
                    HStack(alignment: .center, spacing: 32) {
                        Text("Keyboard Shortcut")
                            .font(brand: .label3)
                            .foregroundStyle(DesignTokens.Text.secondary)
                            .frame(width: 160, alignment: .leading)
                        
                        KeyboardShortcuts.Recorder(for: .workspace(workspace.id))
                            .padding(6)
                            .padding(.horizontal, 4)
                            .background {
                                Capsule()
                                    .fill(DesignTokens.Surface.elevated)
                            }
                        
                        Spacer()
                    }
                }
                
                // Screen selector - only show when creating new workspace or editing layout
                if (editedWorkspace.isNew || workspaceVM.isEditingLayout) && availableScreens.count > 1 {
                    CompactScreenSelector(
                        selectedScreenIndices: $selectedScreenIndices,
                        screens: availableScreens
                    )
                }

                // Apps row
                HStack(spacing: 32) {
                    Text("Apps in this workspace")
                        .font(brand: .label3)
                        .foregroundStyle(DesignTokens.Text.secondary)
                        .frame(width: 160, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)

                    WorkspaceLayoutPreview(
                        windows: previewWindows,
                        screens: previewScreens,
                        screenFilter: selectedScreenIndices,
                        height: 120,
                        showLabels: true,
                        iconProvider: iconForWindow(_:),
                        onWindowTapped: { window in
                            if chromeBundleIdentifiers.contains(window.bundleIdentifier) {
                                withAnimation(.spring(duration: 0.25)) {
                                    if selectedChromeWindow?.id == window.id {
                                        selectedChromeWindow = nil
                                    } else {
                                        selectedChromeWindow = window
                                    }
                                    selectedOpenByPathWindow = nil
                                }
                                onHeightChanged?(selectedChromeWindow != nil)
                                return
                            }

                            if OpenByPathBundleIdentifiers.supported.contains(window.bundleIdentifier) {
                                withAnimation(.spring(duration: 0.25)) {
                                    if selectedOpenByPathWindow?.id == window.id {
                                        selectedOpenByPathWindow = nil
                                    } else {
                                        selectedOpenByPathWindow = window
                                    }
                                    selectedChromeWindow = nil
                                }
                                onHeightChanged?(selectedOpenByPathWindow != nil)
                                return
                            }

                            withAnimation(.spring(duration: 0.25)) {
                                selectedChromeWindow = nil
                                selectedOpenByPathWindow = nil
                            }
                            onHeightChanged?(false)
                        },
                        onRefresh: (editedWorkspace.isNew || workspaceVM.isEditingLayout) ? {
                            Task { await refreshWorkspacePreview() }
                        } : nil
                    )

                    Spacer()
                }
                .padding(.bottom, 12)
                
                // Chrome window detail panel
                if let chromeWindow = selectedChromeWindow {
                    ChromeWindowDetailPanel(
                        window: chromeWindow,
                        chromeProfileManager: workspaceVM.overlayWindowManager.chromeConfigurationManager.chromeProfileManager,
                        initialModification: chromeModifications[chromeWindow.id],
                        isNewWorkspace: editedWorkspace.isNew,
                        useSavedTabsFallback: !editedWorkspace.isNew,
                        onModificationChanged: { modification in
                            DeskJigLog.info(.workspace, "WorkspaceEditorPanelContent: Received modification", fields: ["windowId": "\(chromeWindow.id)", "urlCount": modification.tabURLs.count, "profile": modification.profileDisplayName ?? "none"])
                            for (index, url) in modification.tabURLs.enumerated() {
                                DeskJigLog.info(.workspace, "URL in modification", fields: ["index": "\(index)", "url": url])
                            }
                            chromeModifications[chromeWindow.id] = modification
                            DeskJigLog.info(.workspace, "WorkspaceEditorPanelContent: chromeModifications updated", fields: ["count": chromeModifications.count])
                        },
                        onDismiss: {
                            withAnimation(.spring(duration: 0.25)) {
                                selectedChromeWindow = nil
                            }
                            // Notify panel manager to collapse height
                            onHeightChanged?(false)
                        }
                    )
                    // Force view recreation when switching Chrome windows to re-initialize state
                    .id(chromeWindow.id)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }

                // Open-by-path detail panel
                if let openByPathWindow = selectedOpenByPathWindow {
                    OpenByPathWindowDetailPanel(
                        window: openByPathWindow,
                        initialModification: openByPathModifications[openByPathWindow.id],
                        onModificationChanged: { modification in
                            openByPathModifications[openByPathWindow.id] = modification
                        },
                        onDismiss: {
                            withAnimation(.spring(duration: 0.25)) {
                                selectedOpenByPathWindow = nil
                            }
                            onHeightChanged?(false)
                        }
                    )
                    .id(openByPathWindow.id)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            
            // Divider before buttons
            Divider()
                .background(DesignTokens.Border.subtle)

            HStack(spacing: 12) {

                Button(action: {
                    DeskJigLog.info(.workspace, "Cancel button pressed")
                    workspaceVM.cancelWorkspaceEditing()
                    onDismiss()
                }) {
                    Text("Cancel")
                        .font(brand: .label2)
                        .foregroundStyle(DesignTokens.Text.primary)
                        .allowsHitTesting(false)
                        .padding(8)
                        .padding(.horizontal, 12)
                        .background {
                            Capsule()
                                .fill(DesignTokens.Surface.elevated)
                        }
                }
                .buttonStyle(.plain)

                Spacer()
                
                // Only show "Edit Layout" button when editing existing workspace AND NOT already in layout editing mode
                if !editedWorkspace.isNew && !workspaceVM.isEditingLayout {
                Button(action: {
                    DeskJigLog.info(.workspace, "Edit Layout button pressed - showing confirmation")
                    isConfirmingEditLayout = true
                }) {
                    primaryButton("Edit Layout")
                }
                .buttonStyle(.plain)
                }
                
                Button(action: {
                    DeskJigLog.info(.workspace, "=== SAVE WORKSPACE PRESSED ===")
                    NSApp.keyWindow?.makeFirstResponder(nil)
                    DispatchQueue.main.async {
                        DeskJigLog.info(.workspace, "WorkspaceEditorPanelContent: chromeModifications at save time", fields: ["count": chromeModifications.count])
                        for (windowId, mod) in chromeModifications {
                            DeskJigLog.info(.workspace, "Chrome modification", fields: ["windowId": "\(windowId)", "urlCount": mod.tabURLs.count, "profile": mod.profileDisplayName ?? "nil"])
                            for (index, url) in mod.tabURLs.enumerated() {
                                DeskJigLog.info(.workspace, "Chrome URL", fields: ["index": "\(index)", "url": url])
                            }
                        }

                        DeskJigLog.info(.workspace, "WorkspaceEditorPanelContent: openByPathModifications at save time", fields: ["count": openByPathModifications.count])
                        for (windowId, mod) in openByPathModifications {
                            DeskJigLog.info(.workspace, "OpenByPath modification", fields: ["windowId": "\(windowId)", "bundleId": mod.bundleIdentifier, "openPath": mod.openPath ?? "nil"])
                        }

                        guard validateOpenByPathModificationsForSave() else {
                            DeskJigLog.warn(.workspace, "WorkspaceEditorPanelContent: openByPath validation failed", fields: ["error": openByPathValidationError ?? "unknown error"])
                            return
                        }
                        
                        // Apply Chrome modifications to preview windows before saving
                        applyChromModificationsToPreviewWindows()
                        
                        // Convert panel modifications to view model type
                        let vmModifications = chromeModifications.mapValues { mod in
                            WorkspaceViewModel.ChromeWindowModification(
                                tabURLs: mod.tabURLs,
                                profileDirectory: mod.profileDirectory,
                                profileDisplayName: mod.profileDisplayName,
                                profileHostedDomain: mod.profileHostedDomain,
                                profileUserName: mod.profileUserName,
                                profileMatchMode: mod.profileMatchMode
                            )
                        }
                        
                        DeskJigLog.info(.workspace, "WorkspaceEditorPanelContent: Passing modifications to saveWorkspace", fields: ["count": vmModifications.count])

                        let vmOpenByPathModifications = openByPathModifications.mapValues { mod in
                            WorkspaceViewModel.OpenByPathWindowModification(
                                bundleIdentifier: mod.bundleIdentifier,
                                windowTitle: mod.windowTitle,
                                openPath: mod.openPath
                            )
                        }
                        
                        workspaceVM.saveWorkspace(
                            withName: name,
                            andIcon: icon,
                            screenIndices: selectedScreenIndices,
                            chromeModifications: vmModifications,
                            openByPathModifications: vmOpenByPathModifications
                        )
                        // Refresh workspace list after save
                        MainActor.async(after: .seconds(0.2)) {
                            actionPanelManager?.updateDynamicContent()
                        }
                        onDismiss()
                    }
                }) {
                    primaryButton("Save Workspace")
                }
                .buttonStyle(.plain)
            }
            .padding(.top, 12)
        }
        .padding(20)
        .dsCard()
        .overlay {
            Group {
                if isConfirmingDelete {
                    DeleteConfirmationOverlay(
                        workspaceName: workspace.name,
                        onConfirm: {
                            workspaceVM.deleteWorkspace(workspace)
                            // Refresh workspace list in action panel
                            MainActor.async(after: .milliseconds(100)) {
                                actionPanelManager?.updateDynamicContent()
                            }
                            onDismiss()
                        },
                        onCancel: {
                            isConfirmingDelete = false
                        }
                    )
                }

                if isConfirmingEditLayout {
                    EditLayoutConfirmationOverlay(
                        workspaceName: workspace.name,
                        onEditWithoutRestoring: {
                            DeskJigLog.info(.workspace, "Edit Without Restoring selected")
                            isConfirmingEditLayout = false
                            workspaceVM.enterLayoutEditingModeWithoutRestore()
                        },
                        onRestoreAndEdit: {
                            DeskJigLog.info(.workspace, "Restore & Edit selected")
                            isConfirmingEditLayout = false
                            workspaceVM.enterLayoutEditingMode()
                        },
                        onCancel: {
                            isConfirmingEditLayout = false
                        }
                    )
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 20))
        }
        .preferredColorScheme(nil)
        .transition(
            .blurTransition(blurRadius: 4, yOffset: .zero, scale: 0.6, anchor: .center)
            .animation(.bouncy(duration: 0.3, extraBounce: 0.1))
        )
        .onAppear {
            DeskJigLog.info(.workspace, "WorkspaceEditorPanelContent appeared - setting name and icon")
            name = workspace.name
            icon = workspace.icon ?? Self.defaultEmoji
            
            Task { await refreshWorkspacePreview() }
            updatePreviewAutoRefresh()

            // Initialize selected screens
            if editedWorkspace.isNew {
                // For new workspaces, default to all screens selected
                selectedScreenIndices = Set(availableScreens.indices)
            } else if let mainDisplayID = NSScreen.main?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
                      let currentIndex = availableScreens.firstIndex(where: { $0.displayID == mainDisplayID.intValue }) {
                // For existing workspaces, default to current screen
                selectedScreenIndices = [currentIndex]
                // Include all screens that have windows to prevent them appearing as "Unassigned"
                let screensWithWindows = Set(workspace.windows.compactMap { $0.screenIndex })
                selectedScreenIndices = selectedScreenIndices.union(screensWithWindows)
            } else {
                // Fallback to all screens
                selectedScreenIndices = Set(availableScreens.indices)
            }

            // Pre-populate chrome modifications from existing workspace windows
            if !editedWorkspace.isNew {
                for window in workspace.windows {
                    if let chromeState = window.chromeState,
                       chromeBundleIdentifiers.contains(window.bundleIdentifier) {
                        chromeModifications[window.id] = ChromeWindowModification(
                            tabURLs: chromeState.savedTabURLs,
                            profileDirectory: chromeState.profileDirectory,
                            profileDisplayName: chromeState.profileDisplayName,
                            profileHostedDomain: chromeState.profileHostedDomain,
                            profileUserName: chromeState.profileUserName,
                            profileMatchMode: chromeState.profileMatchMode
                        )
                        DeskJigLog.info(.workspace, "Loaded existing chrome state", fields: ["windowId": "\(window.id)", "tabs": chromeState.savedTabURLs.count])
                    }
                }
            }

            // Pre-populate open-by-path modifications from existing workspace windows
            if !editedWorkspace.isNew {
                for window in workspace.windows {
                    guard OpenByPathBundleIdentifiers.supported.contains(window.bundleIdentifier) else { continue }
                    guard let openPath = window.openPath else { continue }
                    openByPathModifications[window.id] = OpenByPathWindowModification(
                        bundleIdentifier: window.bundleIdentifier,
                        windowTitle: window.windowTitle,
                        openPath: openPath
                    )
                    DeskJigLog.info(.workspace, "Loaded existing openPath", fields: ["windowId": "\(window.id)", "openPath": openPath])
                }
            }
        }
        .onReceive(workspaceVM.windowManager.$windows) { _ in
            Task { await refreshWorkspacePreview() }
        }
        .onChange(of: workspaceVM.isEditingLayout) {
            Task { await refreshWorkspacePreview() }
            updatePreviewAutoRefresh()
        }
        .onChange(of: selectedScreenIndices) {
            Task { await refreshWorkspacePreview() }
        }
        .onDisappear {
            stopPreviewAutoRefresh()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity) // fill panel to give room for shadows to not clip
        .alert(
            "Invalid Open Path",
            isPresented: Binding(
                get: { openByPathValidationError != nil },
                set: { presented in
                    if !presented { openByPathValidationError = nil }
                }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(openByPathValidationError ?? "")
        }
    }
    
    private func primaryButton(_ text: String) -> some View {
        Text(text)
            .font(brand: .label2)
            .foregroundStyle(DesignTokens.Text.primary)
            .allowsHitTesting(false)
            .padding(8)
            .padding(.horizontal, 12)
            .background {
                Capsule()
                    .fill(DesignTokens.Brand.accentMuted)
                    .overlay(
                        Capsule()
                            .stroke(DesignTokens.Brand.accent.opacity(0.35), lineWidth: 1)
                    )
            }
    }
    
    private var textField: some View {
        TextField("My Workspace", text: $name)
            .font(brand: .h3)
            .focused($isFocused)
            .foregroundStyle(DesignTokens.Text.primary)
            .textFieldStyle(.plain)
            .frame(width: 180)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background {
                RoundedRectangle(cornerRadius: 8)
                    .fill(DesignTokens.Surface.input)
                    .stroke(DesignTokens.Border.subtle, lineWidth: 1)
            }
    }
    
    private var iconPicker: some View {
        Button {
            isPickingIcon.toggle()
        } label: {
            Text(icon)
                .font(brand: .h3)
                .padding(4)
                .background {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(DesignTokens.Surface.elevated)
                }
                .brightenOnHover()
        }
        .buttonStyle(.plain)
        .popover(isPresented: $isPickingIcon) {
            LazyHGrid(
                rows: [
                    .init(.fixed(28), spacing: 4),
                    .init(.fixed(28), spacing: 4),
                    .init(.fixed(28), spacing: 4),
                    .init(.fixed(28), spacing: 4)
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
                            .padding(4)
                            .background {
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(
                                        icon == emoji ? DesignTokens.Border.subtle : DesignTokens.Surface.elevated
                                    )
                            }
                            .brightenOnHover()
                            .padding(2)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(4)
            .padding(.horizontal, 4)
        }
    }
    
    @MainActor
    private func refreshWorkspacePreview() async {
        if editedWorkspace.isNew || workspaceVM.isEditingLayout {
            guard !isPreviewRefreshing else { return }
            isPreviewRefreshing = true
            defer { isPreviewRefreshing = false }

            let snapshot = await workspaceVM.windowManager.captureWorkspaceSnapshot(
                screenIndices: selectedScreenIndices,
                minVisibilityOverride: 1.0,
                skipSupplementation: true  // Skip supplementation for preview to reduce log verbosity
            )
            previewWindows = snapshot.windows
            previewScreens = snapshot.screens
            remapChromeModificationsToPreviewWindowsIfNeeded()
        } else {
            let referenceWorkspaces = workspaceVM.workspaces.map(\.workspace).filter { $0.id != workspace.id }
            let previewWorkspace = workspace.repairPreviewWorkspace(using: referenceWorkspaces)
            previewWindows = previewWorkspace.windows
            previewScreens = previewWorkspace.screens ?? []
        }
    }

    private func updatePreviewAutoRefresh() {
        if shouldAutoRefreshPreview {
            startPreviewAutoRefresh()
        } else {
            stopPreviewAutoRefresh()
        }
    }

    private func startPreviewAutoRefresh() {
        guard previewRefreshTask == nil else { return }
        previewRefreshTask = Task {
            while !Task.isCancelled {
                await refreshWorkspacePreview()
                guard await Task.sleepUnlessCancelled(nanoseconds: previewRefreshIntervalNs) else { break }
            }
        }
    }

    private func stopPreviewAutoRefresh() {
        previewRefreshTask?.cancel()
        previewRefreshTask = nil
    }

    private func iconForWindow(_ window: WorkspaceWindow) -> NSImage? {
        workspaceVM.applicationManager.findApplication(by: window.bundleIdentifier)?.icon
    }
    
    /// Applies Chrome modifications from the UI to the preview windows
    private func applyChromModificationsToPreviewWindows() {
        guard !chromeModifications.isEmpty else { return }

        remapChromeModificationsToPreviewWindowsIfNeeded()
        
        DeskJigLog.info(.workspace, "Applying Chrome modifications to preview windows", fields: ["count": chromeModifications.count])
        
        previewWindows = previewWindows.map { window in
            guard let modification = chromeModifications[window.id] else {
                return window
            }
            let isAnyWindow = modification.profileMatchMode == .anyWindow

            // Create updated ChromeWindowState
            let newChromeState = ChromeWindowState(
                profileDirectory: isAnyWindow ? "" : (modification.profileDirectory ?? window.chromeState?.profileDirectory ?? ""),
                profileDisplayName: isAnyWindow ? "" : (modification.profileDisplayName ?? window.chromeState?.profileDisplayName ?? ""),
                profileHostedDomain: isAnyWindow ? nil : (modification.profileHostedDomain ?? window.chromeState?.profileHostedDomain),
                profileUserName: isAnyWindow ? nil : (modification.profileUserName ?? window.chromeState?.profileUserName),
                profileMatchMode: modification.profileMatchMode,
                shouldRestoreTabs: !modification.tabURLs.isEmpty,
                savedTabURLs: modification.tabURLs,
                focusedTabIndex: window.chromeState?.focusedTabIndex,
                chromeWindowId: window.chromeState?.chromeWindowId
            )
            
            DeskJigLog.info(.workspace, "Chrome modification applied", fields: ["windowId": "\(window.id)", "tabs": modification.tabURLs.count, "profile": modification.profileDisplayName ?? "none"])
            
            return window.withChromeState(newChromeState)
        }
    }

    private func remapChromeModificationsToPreviewWindowsIfNeeded() {
        guard workspaceVM.isEditingLayout || editedWorkspace.isNew else { return }
        guard !chromeModifications.isEmpty else { return }

        let chromeWindows = previewWindows.filter { chromeBundleIdentifiers.contains($0.bundleIdentifier) }
        guard !chromeWindows.isEmpty else { return }

        let previewWindowIDs = Set(chromeWindows.map(\.id))
        if chromeModifications.keys.allSatisfy(previewWindowIDs.contains) {
            return
        }

        var remaining = chromeModifications
        var remapped: [UUID: ChromeWindowModification] = [:]

        for window in chromeWindows {
            if let direct = chromeModifications[window.id] {
                remapped[window.id] = direct
                remaining.removeValue(forKey: window.id)
            }
        }

        for window in chromeWindows where remapped[window.id] == nil {
            let windowMatchMode = window.chromeState?.profileMatchMode ?? .specific
            let profileDirectory = window.chromeState?.profileDirectory ?? ""
            if let match = remaining.first(where: {
                $0.value.profileMatchMode == windowMatchMode &&
                    ($0.value.profileDirectory ?? "") == profileDirectory
            }) {
                remapped[window.id] = match.value
                remaining.removeValue(forKey: match.key)
            }
        }

        let unmatchedWindows = chromeWindows.filter { remapped[$0.id] == nil }
        if unmatchedWindows.count == 1, remaining.count == 1, let lone = remaining.first?.value {
            remapped[unmatchedWindows[0].id] = lone
        }

        if !remapped.isEmpty {
            chromeModifications = remapped
        }
    }

    private func validateOpenByPathModificationsForSave() -> Bool {
        openByPathValidationError = nil

        for (_, modification) in openByPathModifications {
            guard let rawOpenPath = modification.openPath else { continue }
            let trimmed = rawOpenPath.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }

            guard trimmed.hasPrefix("/") || trimmed.hasPrefix("~") else {
                openByPathValidationError = "\(displayName(forOpenByPathBundleID: modification.bundleIdentifier)) path must start with `~/` or `/`.\n\nEntered: \(trimmed)"
                return false
            }

            let expanded = (trimmed as NSString).expandingTildeInPath
            let url = URL(fileURLWithPath: expanded).standardizedFileURL

            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
                openByPathValidationError = "\(displayName(forOpenByPathBundleID: modification.bundleIdentifier)) path does not exist.\n\nResolved: \(url.path)"
                return false
            }

            guard isDirectory.boolValue else {
                openByPathValidationError = "\(displayName(forOpenByPathBundleID: modification.bundleIdentifier)) path must be a directory.\n\nResolved: \(url.path)"
                return false
            }
        }

        return true
    }

    private func displayName(forOpenByPathBundleID bundleIdentifier: String) -> String {
        switch bundleIdentifier {
        case OpenByPathBundleIdentifiers.cursor:
            return "Cursor"
        case OpenByPathBundleIdentifiers.codex:
            return "Codex"
        case OpenByPathBundleIdentifiers.ghostty:
            return "Ghostty"
        case OpenByPathBundleIdentifiers.vscode:
            return "VS Code"
        case OpenByPathBundleIdentifiers.terminal:
            return "Terminal"
        case OpenByPathBundleIdentifiers.iterm2:
            return "iTerm"
        case OpenByPathBundleIdentifiers.kitty:
            return "kitty"
        case OpenByPathBundleIdentifiers.alacritty:
            return "Alacritty"
        case OpenByPathBundleIdentifiers.xcode:
            return "Xcode"
        default:
            return bundleIdentifier
        }
    }
}
