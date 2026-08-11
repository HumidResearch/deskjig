//  DirectoryWorkspaceEditorPanelContent.swift
//  DeskJig
//
//  Editor panel for creating and editing Directory Workspaces.
//  Only shows open-by-path windows, requires directory paths for all windows.
//

import SwiftUI
import AppKit
import DeskJigShared

/// Represents user modifications to a window's directory path
struct DirectoryWindowModification: Equatable {
    var bundleIdentifier: String
    var windowTitle: String
    var directoryPath: String?
}

struct DirectoryWorkspaceEditorPanelContent: View {

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
    @State private var selectedWindow: WorkspaceWindow? = nil
    @State private var previewRefreshTask: Task<Void, Never>? = nil
    @State private var isPreviewRefreshing = false
    /// Tracks directory path modifications for each window by window ID
    @State private var directoryModifications: [UUID: DirectoryWindowModification] = [:]
    @State private var validationError: String? = nil
    @FocusState private var isFocused: Bool

    static let defaultEmoji: String = "📂"
    static let workspaceEmojis: [String] = [
        "📂", "🗂️", "🧭", "🪶", "🪄", "⚙️", "🧱", "💻", "🧑‍💻", "🧠", "🧩", "🔧", "🧰",
        "📡", "🎨", "✏️", "🖌️", "🧵", "📸", "🎬", "🪩", "🤝", "🏠", "🫶", "🧺", "📊",
        "🏗️", "🌱", "🌿", "🌸", "☀️", "🌙", "🔮", "📖", "🪴", "🔥", "⚡", "🚀", "🎯",
        "⏳", "🗄️", "💡", "🔒", "💼", "🧾", "📈", "🏦", "🧮", "💬", "🌍", "🕸️", "🏛️",
    ]
    private let previewRefreshIntervalNs: UInt64 = 500_000_000

    private var availableScreens: [FullScreenInfo] {
        WorkspaceDisplayTopology.effectiveScreens(from: workspaceVM.windowManager.displayManager)
    }

    /// Whether this is creating a new directory workspace vs editing an existing one
    private var isNewWorkspace: Bool {
        workspaceVM.directoryWorkspaceBeingEdited?.workspace == nil
    }

    /// The existing directory workspace being edited, if any
    private var existingWorkspace: DirectoryWorkspace? {
        workspaceVM.directoryWorkspaceBeingEdited?.workspace
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            // Header with name, icon, and delete button
            HStack(spacing: 16) {
                iconPicker
                textField

                Spacer()

                // Delete button (only for existing sessions)
                if !isNewWorkspace {
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

            // Content section
            VStack(spacing: 16) {
                // Screen selector - only show when creating new workspace and multiple screens
                if isNewWorkspace && availableScreens.count > 1 {
                    CompactScreenSelector(
                        selectedScreenIndices: $selectedScreenIndices,
                        screens: availableScreens
                    )
                }

                // Apps row - filtered to only open-by-path windows
                HStack(spacing: 32) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Open-by-path windows")
                            .font(brand: .label3)
                            .foregroundStyle(DesignTokens.Text.secondary)

                        if previewWindows.isEmpty {
                            Text("No open-by-path windows found")
                                .font(brand: .label3)
                                .foregroundStyle(DesignTokens.Text.tertiary)
                        }
                    }
                    .frame(width: 160, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)

                    if !previewWindows.isEmpty {
                        WorkspaceLayoutPreview(
                            windows: previewWindows,
                            screens: previewScreens,
                            screenFilter: selectedScreenIndices,
                            height: 120,
                            showLabels: true,
                            iconProvider: iconForWindow(_:),
                            onWindowTapped: { window in
                                withAnimation(.spring(duration: 0.25)) {
                                    if selectedWindow?.id == window.id {
                                        selectedWindow = nil
                                    } else {
                                        selectedWindow = window
                                    }
                                }
                                onHeightChanged?(selectedWindow != nil)
                            },
                            onRefresh: isNewWorkspace ? {
                                Task { await refreshWorkspacePreview() }
                            } : nil
                        )
                    }

                    Spacer()
                }
                .padding(.bottom, 12)

                // Directory path detail panel for selected window
                if let selectedWin = selectedWindow {
                    DirectoryPathDetailPanel(
                        window: selectedWin,
                        initialModification: directoryModifications[selectedWin.id],
                        onModificationChanged: { modification in
                            DeskJigLog.info(.workspace, "DirectoryWorkspaceEditor: Received modification", fields: ["windowId": "\(selectedWin.id)", "path": modification.directoryPath ?? "nil"])
                            directoryModifications[selectedWin.id] = modification
                        },
                        onDismiss: {
                            withAnimation(.spring(duration: 0.25)) {
                                selectedWindow = nil
                            }
                            onHeightChanged?(false)
                        }
                    )
                    .id(selectedWin.id)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }

                // Validation message showing which windows need paths
                if !windowsMissingPaths.isEmpty {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(DesignTokens.Status.warning)
                        Text("\(windowsMissingPaths.count) window(s) need a directory path")
                            .font(brand: .label3)
                            .foregroundStyle(DesignTokens.Status.warning)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            // Divider before buttons
            Divider()
                .background(DesignTokens.Border.subtle)

            HStack(spacing: 12) {

                Button(action: {
                    DeskJigLog.info(.workspace, "Cancel button pressed")
                    workspaceVM.cancelDirectoryWorkspaceEditing()
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

                Spacer()

                Button(action: {
                    DeskJigLog.info(.workspace, "=== SAVE DIRECTORY WORKSPACE PRESSED ===")
                    DeskJigLog.info(.workspace, "directoryModifications at save time", fields: ["count": directoryModifications.count])

                    guard validateModificationsForSave() else {
                        DeskJigLog.warn(.workspace, "Validation failed", fields: ["error": validationError ?? "unknown error"])
                        return
                    }

                    // Convert to OpenByPathWindowModification for compatibility with existing save logic
                    let openByPathModifications = directoryModifications.mapValues { mod in
                        WorkspaceViewModel.OpenByPathWindowModification(
                            bundleIdentifier: mod.bundleIdentifier,
                            windowTitle: mod.windowTitle,
                            openPath: mod.directoryPath
                        )
                    }

                    workspaceVM.saveDirectoryWorkspace(
                        withName: name,
                        andIcon: icon,
                        screenIndices: selectedScreenIndices,
                        windows: previewWindows,
                        screens: previewScreens,
                        openByPathModifications: openByPathModifications
                    )
                    // Refresh workspace list after save
                    MainActor.async(after: .seconds(0.2)) {
                        actionPanelManager?.updateDynamicContent()
                    }
                    onDismiss()
                }) {
                    primaryButton("Save")
                }
                .disabled(!canSave)
                .opacity(canSave ? 1.0 : 0.5)
            }
            .buttonStyle(.plain)
            .padding(.top, 12)
        }
        .padding(20)
        .dsCard()
        .preferredColorScheme(nil)
        .transition(
            .blurTransition(blurRadius: 4, yOffset: .zero, scale: 0.6, anchor: .center)
            .animation(.bouncy(duration: 0.3, extraBounce: 0.1))
        )
        .onAppear {
            DeskJigLog.info(.workspace, "DirectoryWorkspaceEditorPanelContent appeared")

            if let workspace = existingWorkspace {
                name = workspace.name
                icon = workspace.icon ?? Self.defaultEmoji

                // Pre-populate modifications from existing workspace (best-effort)
                for windowSpec in workspace.windowSpecs() {
                    // We need to find the corresponding WorkspaceWindow if any
                    // For editing, we'll show the stored path
                    // Note: For existing sessions, we don't have WorkspaceWindow UUIDs matching
                    // We'll handle this in a simplified way for now
                    _ = windowSpec
                }
            } else {
                name = "My Directory Workspace"
            }

            Task { await refreshWorkspacePreview() }
            updatePreviewAutoRefresh()

            // Initialize selected screens - default to current screen
            if let mainDisplayID = NSScreen.main?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
               let currentIndex = availableScreens.firstIndex(where: { $0.displayID == mainDisplayID.intValue }) {
                selectedScreenIndices = [currentIndex]
            } else {
                selectedScreenIndices = Set(availableScreens.indices)
            }
        }
        .onReceive(workspaceVM.windowManager.$windows) { _ in
            if isNewWorkspace {
                Task { await refreshWorkspacePreview() }
            }
        }
        .onChange(of: selectedScreenIndices) {
            if isNewWorkspace {
                Task { await refreshWorkspacePreview() }
            }
        }
        .onDisappear {
            stopPreviewAutoRefresh()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay {
            if isConfirmingDelete, let workspace = existingWorkspace {
                DeleteConfirmationOverlay(
                    workspaceName: workspace.name,
                    onConfirm: {
                        workspaceVM.deleteDirectoryWorkspace(workspace)
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
        }
        .alert(
            "Invalid Configuration",
            isPresented: Binding(
                get: { validationError != nil },
                set: { presented in
                    if !presented { validationError = nil }
                }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(validationError ?? "")
        }
    }

    // MARK: - Computed Properties

    private var windowsMissingPaths: [WorkspaceWindow] {
        previewWindows.filter { window in
            let mod = directoryModifications[window.id]
            let path = mod?.directoryPath?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return path.isEmpty
        }
    }

    private var canSave: Bool {
        !previewWindows.isEmpty && windowsMissingPaths.isEmpty && !name.isEmpty
    }

    // MARK: - UI Components

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
        TextField("My Directory Workspace", text: $name)
            .font(brand: .h3)
            .focused($isFocused)
            .foregroundStyle(DesignTokens.Text.primary)
            .textFieldStyle(.plain)
            .frame(width: 200)
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

    // MARK: - Helper Methods

    @MainActor
    private func refreshWorkspacePreview() async {
        guard isNewWorkspace else { return }
        guard !isPreviewRefreshing else { return }
        isPreviewRefreshing = true
        defer { isPreviewRefreshing = false }

        let snapshot = await workspaceVM.windowManager.captureWorkspaceSnapshot(
            screenIndices: selectedScreenIndices,
            minVisibilityOverride: 1.0,
            skipSupplementation: true  // Skip supplementation for preview to reduce log verbosity
        )

        // Filter to only supported apps
        previewWindows = snapshot.windows.filter { window in
            OpenByPathBundleIdentifiers.supported.contains(window.bundleIdentifier)
        }
        previewScreens = snapshot.screens

        DeskJigLog.info(.workspace, "DirectoryWorkspaceEditor: Captured open-by-path windows", fields: ["count": previewWindows.count])
    }

    private func updatePreviewAutoRefresh() {
        if isNewWorkspace {
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

    private func validateModificationsForSave() -> Bool {
        validationError = nil

        // Check that all windows have paths
        for window in previewWindows {
            let mod = directoryModifications[window.id]
            guard let rawPath = mod?.directoryPath else {
                validationError = "\(displayName(for: window.bundleIdentifier)) window needs a directory path.\n\nClick on each window to assign a directory."
                return false
            }

            let trimmed = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                validationError = "\(displayName(for: window.bundleIdentifier)) window needs a directory path.\n\nClick on each window to assign a directory."
                return false
            }

            guard trimmed.hasPrefix("/") || trimmed.hasPrefix("~") else {
                validationError = "\(displayName(for: window.bundleIdentifier)) path must start with `~/` or `/`.\n\nEntered: \(trimmed)"
                return false
            }

            let expanded = (trimmed as NSString).expandingTildeInPath
            let url = URL(fileURLWithPath: expanded).standardizedFileURL

            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
                validationError = "\(displayName(for: window.bundleIdentifier)) path does not exist.\n\nResolved: \(url.path)"
                return false
            }

            guard isDirectory.boolValue else {
                validationError = "\(displayName(for: window.bundleIdentifier)) path must be a directory.\n\nResolved: \(url.path)"
                return false
            }
        }

        return true
    }

    private func displayName(for bundleIdentifier: String) -> String {
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

// MARK: - Directory Path Detail Panel

/// Detail panel for entering a directory path for a window
struct DirectoryPathDetailPanel: View {
    let window: WorkspaceWindow
    let initialModification: DirectoryWindowModification?
    let onModificationChanged: (DirectoryWindowModification) -> Void
    let onDismiss: () -> Void

    @State private var pathInput: String = ""
    @State private var verification: VerificationState = .unknown
    @State private var isVerifying: Bool = false

    enum VerificationState: Equatable {
        case unknown
        case valid(resolvedPath: String)
        case invalid(message: String)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header

            VStack(alignment: .leading, spacing: 8) {
                Text("Directory to open")
                    .font(brand: .label2)
                    .foregroundStyle(DesignTokens.Text.primary.opacity(0.75))

                TextField("~/code/my-project", text: $pathInput)
                    .font(brand: Font.brandBody(size: 12))
                    .foregroundStyle(DesignTokens.Text.primary)
                    .textFieldStyle(.plain)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background {
                        RoundedRectangle(cornerRadius: 8)
                            .fill(DesignTokens.Surface.input)
                            .stroke(DesignTokens.Border.subtle, lineWidth: 1)
                    }

                HStack(spacing: 10) {
                    Button(action: verifyPath) {
                        HStack(spacing: 6) {
                            if isVerifying {
                                ProgressView()
                                    .scaleEffect(0.7)
                                    .tint(.white.opacity(0.8))
                            } else {
                                Image(systemName: "checkmark.seal")
                                    .font(brand: Font.brandBody(size: 12))
                                    .foregroundStyle(DesignTokens.Text.primary.opacity(0.75))
                            }
                            Text("Verify")
                                .font(brand: .label2)
                                .foregroundStyle(DesignTokens.Text.primary)
                        }
                        .padding(.vertical, 6)
                        .padding(.horizontal, 10)
                        .background {
                            Capsule()
                                .fill(DesignTokens.Surface.elevated)
                                
                        }
                    }
                    .buttonStyle(.plain)

                    Button(action: clearPath) {
                        Text("Clear")
                            .font(brand: .label2)
                            .foregroundStyle(DesignTokens.Text.primary)
                            .padding(.vertical, 6)
                            .padding(.horizontal, 10)
                            .background {
                                Capsule()
                                    .fill(DesignTokens.Surface.elevated)
                                    
                            }
                    }
                    .buttonStyle(.plain)

                    Spacer()
                }

                verificationView
            }
        }
        .padding(16)
        .background {
            RoundedRectangle(cornerRadius: DesignTokens.Card.cornerRadius)
                .fill(DesignTokens.Surface.elevated)
                .overlay(
                    RoundedRectangle(cornerRadius: DesignTokens.Card.cornerRadius)
                        .stroke(DesignTokens.Border.regular, lineWidth: 1)
                )
        }
        .onAppear {
            pathInput = initialPath
            notifyModificationChanged()
        }
        .onChange(of: pathInput) { _, _ in
            verification = .unknown
            notifyModificationChanged()
        }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("\(displayName(for: window.bundleIdentifier)) Window")
                    .font(brand: .h4)
                    .foregroundStyle(DesignTokens.Text.primary)

                Text(window.windowTitle.isEmpty ? "Window" : window.windowTitle)
                    .font(brand: Font.brandBody(size: 10))
                    .foregroundStyle(DesignTokens.Text.tertiary)
                    .lineLimit(1)
            }

            Spacer()

            Button(action: onDismiss) {
                Image(systemName: "xmark.circle.fill")
                    .font(brand: Font.brandBody(size: 20))
                    .foregroundStyle(DesignTokens.Text.secondary)
                    .brightenOnHover()
            }
            .buttonStyle(.plain)
        }
    }

    private var initialPath: String {
        if let path = initialModification?.directoryPath, !path.isEmpty {
            return path
        }
        return window.openPath ?? ""
    }

    private var verificationView: some View {
        Group {
            switch verification {
            case .unknown:
                Text("Use `~/…` or `/…` and verify it exists.")
                    .font(brand: .label3)
                    .foregroundStyle(DesignTokens.Text.primary.opacity(0.45))
            case .valid(let resolvedPath):
                Label("Found: \(resolvedPath)", systemImage: "checkmark.circle.fill")
                    .font(brand: .label3)
                    .foregroundStyle(DesignTokens.Brand.accent.opacity(0.9))
            case .invalid(let message):
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(brand: .label3)
                    .foregroundStyle(DesignTokens.Brand.accent.opacity(0.9))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func clearPath() {
        pathInput = ""
        verification = .unknown
        notifyModificationChanged()
    }

    private func verifyPath() {
        isVerifying = true
        defer { isVerifying = false }

        let trimmed = pathInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            verification = .invalid(message: "Enter a path to verify.")
            return
        }

        guard trimmed.hasPrefix("/") || trimmed.hasPrefix("~") else {
            verification = .invalid(message: "Path must start with `~/` or `/`.")
            return
        }

        let expanded = (trimmed as NSString).expandingTildeInPath
        let url = URL(fileURLWithPath: expanded).standardizedFileURL

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            verification = .invalid(message: "Path does not exist.")
            return
        }
        guard isDirectory.boolValue else {
            verification = .invalid(message: "Path is not a directory.")
            return
        }

        verification = .valid(resolvedPath: url.path)
    }

    private func notifyModificationChanged() {
        let trimmed = pathInput.trimmingCharacters(in: .whitespacesAndNewlines)
        let path = trimmed.isEmpty ? nil : trimmed

        let modification = DirectoryWindowModification(
            bundleIdentifier: window.bundleIdentifier,
            windowTitle: window.windowTitle,
            directoryPath: path
        )

        DeskJigLog.info(.workspace, "DirectoryPathDetailPanel: notifyModificationChanged", fields: ["bundleID": modification.bundleIdentifier, "path": modification.directoryPath ?? "nil"])
        onModificationChanged(modification)
    }

    private func displayName(for bundleIdentifier: String) -> String {
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
