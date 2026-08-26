//
//  WorkspaceCardView.swift
//  DeskJig
//
//  Created by Claude Code on 01/30/26.
//

import SwiftUI
import DeskJigShared
import KeyboardShortcuts
import AppKit

/// Adapter that renders a workspace list item using the design system component.
struct WorkspaceCardView: View {
    enum EditPresentation {
        case inline
        case delegated
    }

    let workspace: WorkspaceWithApps
    let index: Int
    var isSelected: Bool = false
    @Binding var editorPathFieldFocused: Bool
    @Binding var isEditingWorkspace: Bool
    var editPresentation: EditPresentation = .inline
    var autoEditWorkspaceId: UUID? = nil
    var onAutoEditHandled: (() -> Void)? = nil
    var onRequestEditMetadata: ((Workspace) -> Void)? = nil
    var onEditLayout: ((Workspace) -> Void)? = nil
    var onDuplicateLayout: ((Workspace) -> Void)? = nil
    var onEditingFinished: (() -> Void)? = nil
    /// Mouse restore path (#51): Open button + card double-click.
    var onOpenWorkspace: ((Workspace) -> Void)? = nil
    /// Single click on the card body selects it (keyboard and mouse share selection).
    var onCardSelected: (() -> Void)? = nil

    @Environment(WorkspaceViewModel.self) private var vm
    @Environment(AppDelegate.self) private var appDelegate
    @EnvironmentObject private var confirmationManager: DSConfirmationManager

    @State private var isEditing: Bool = false
    @State private var editedName: String = ""
    @State private var editedIcon: String = ""

    @State private var selectedWindowId: UUID? = nil
    @State private var selectedWindowPath: String = ""
    @State private var selectedWindowPathStatus: DSFolderVerificationStatus = .none

    @State private var selectedChromeProfile: String? = nil
    @State private var selectedShouldRestoreTabs: Bool = false
    @State private var selectedChromeTabs: [String] = []

    @State private var chromeProfiles: [DSSelectOption<String>] = []
    @State private var chromeModifications: [UUID: ChromeWindowModification] = [:]
    @State private var openByPathModifications: [UUID: OpenByPathWindowModification] = [:]
    @State private var hasLoggedLayoutHealth = false

    private let anyChromeWindowMarker = "__ANY_CHROME_WINDOW__"

    private var chromeProfileManager: ChromeProfileManager {
        vm.overlayWindowManager.chromeConfigurationManager.chromeProfileManager
    }

    private var referenceWorkspaces: [Workspace] {
        vm.workspaces.map(\.workspace).filter { $0.id != workspace.workspace.id }
    }

    private var repairInference: WorkspaceLegacyLayoutRepairInference {
        workspace.workspace.monitorRepairResult(using: referenceWorkspaces)
    }

    private var repairPreviewWorkspace: Workspace {
        workspace.workspace.repairPreviewWorkspace(using: referenceWorkspaces)
    }

    var body: some View {
        DSWorkspaceListItem(
            name: workspace.workspace.name,
            icon: workspaceIcon,
            isFavorite: workspace.workspace.isFavorite,
            isSelected: isSelected,
            screens: previewScreens,
            shortcut: nil,
            shortcutRecorderName: .workspace(workspace.workspace.id),
            shortcutConflictNames: workspaceShortcutNames,
            shortcutConflictLabelProvider: { conflictName in
                if let name = workspaceName(for: conflictName) {
                    return "Already assigned to \"\(name)\""
                }
                return "Shortcut already assigned"
            },
            statusTagLabel: layoutHealthTagLabel,
            noticeTitle: repairNoticeTitle,
            noticeMessage: repairNoticeMessage,
            noticeActionTitle: repairActionTitle,
            onNoticeAction: repairActionTitle == nil ? nil : presentRepairConfirmation,
            noticeActions: repairNoticeActions,
            isEditing: $isEditing,
            editedName: $editedName,
            editedIcon: $editedIcon,
            selectedWindowId: $selectedWindowId,
            selectedWindowPath: $selectedWindowPath,
            selectedWindowPathStatus: selectedWindowPathStatus,
            onVerifySelectedPath: { path in
                verifySelectedPath(path)
            },
            onClearSelectedPath: {
                selectedWindowPath = ""
                selectedWindowPathStatus = .none
            },
            onApplyPathToAll: {
                applyPathToAllOpenByPathWindows(selectedWindowPath)
            },
            onPathFocusChange: { isFocused in
                editorPathFieldFocused = isFocused
            },
            selectedChromeProfile: $selectedChromeProfile,
            selectedShouldRestoreTabs: $selectedShouldRestoreTabs,
            selectedChromeTabs: $selectedChromeTabs,
            chromeProfiles: chromeProfiles,
            onLoadChromeTabs: {
                await loadChromeTabsFromRunningChrome()
            },
            onAddChromeTab: { url in
                selectedChromeTabs.append(url)
            },
            onRemoveChromeTab: { index in
                if selectedChromeTabs.indices.contains(index) {
                    selectedChromeTabs.remove(at: index)
                }
            },
            onEditTapped: {
                if editPresentation == .delegated {
                    onRequestEditMetadata?(workspace.workspace)
                } else if let onRequestEditMetadata {
                    onRequestEditMetadata(workspace.workspace)
                } else {
                    enterEditMode()
                }
            },
            onFavoriteTapped: {
                vm.toggleFavorite(workspace.workspace)
            },
            onSave: {
                saveChanges()
            },
            onCancel: {
                cancelEditing()
            },
            onDelete: {
                presentDeleteConfirmation()
            },
            onEditLayout: {
                onEditLayout?(workspace.workspace)
            },
            onDuplicateLayout: {
                onDuplicateLayout?(workspace.workspace)
            },
            onWindowTapped: { window in
                handleWindowTap(window)
            },
            onOpenTapped: onOpenWorkspace == nil ? nil : { onOpenWorkspace?(workspace.workspace) },
            onCardClicked: onCardSelected
        )
        .onAppear {
            handleAutoEdit(autoEditWorkspaceId)
            logLayoutHealthIfNeeded()
        }
        .onChange(of: autoEditWorkspaceId) { _, newValue in
            handleAutoEdit(newValue)
        }
        .onChange(of: selectedWindowId) { _, _ in
            guard let selectedId = selectedWindowId,
                  let selectedWindow = findWorkspaceWindow(id: selectedId) else {
                return
            }
            loadSelectedWindowState(window: selectedWindow)
        }
        .onChange(of: selectedChromeTabs) { _, _ in
            updateChromeModificationForSelectedWindow()
        }
        .onChange(of: selectedChromeProfile) { _, _ in
            updateChromeModificationForSelectedWindow()
        }
        .onChange(of: selectedShouldRestoreTabs) { _, newValue in
            if !newValue {
                selectedChromeTabs = []
            }
            updateChromeModificationForSelectedWindow()
        }
        .onChange(of: selectedWindowPath) { _, _ in
            selectedWindowPathStatus = .none
            updateOpenByPathModificationForSelectedWindow()
        }
        .onChange(of: isEditing) { _, newValue in
            isEditingWorkspace = newValue
            if !newValue {
                selectedWindowId = nil
                selectedWindowPathStatus = .none
                editorPathFieldFocused = false
            }
        }
    }

    // MARK: - Workspace Preview

    private var workspaceIcon: String {
        let icon = workspace.workspace.icon?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return icon.isEmpty ? WorkspaceEditorPanelContent.defaultEmoji : icon
    }

    private var previewScreens: [DSPreviewScreen] {
        let previewWorkspace = repairPreviewWorkspace
        let screens = previewWorkspace.screens ?? []
        let windows = previewWorkspace.windows

        if workspace.workspace.layoutHealth == .legacyFlattenedBrokenPreview &&
            !hasRepairCandidateOrChoice {
            return [
                DSPreviewScreen(
                    id: 0,
                    title: "Repair needed",
                    isPrimary: false,
                    windows: []
                )
            ]
        }

        if screens.isEmpty {
            let previewWindows = buildPreviewWindows(for: windows)
            return [
                DSPreviewScreen(
                    id: 0,
                    title: "Monitor 1",
                    isPrimary: true,
                    windows: previewWindows
                )
            ]
        }

        var windowsByScreen: [Int: [WorkspaceWindow]] = [:]
        var unassignedWindows: [WorkspaceWindow] = []

        for window in windows {
            guard let index = window.screenIndex, index >= 0, index < screens.count else {
                unassignedWindows.append(window)
                continue
            }
            windowsByScreen[index, default: []].append(window)
        }

        var previewScreens: [DSPreviewScreen] = []
        for (index, screen) in screens.enumerated() {
            let screenWindows = windowsByScreen[index] ?? []
            previewScreens.append(
                DSPreviewScreen(
                    id: index,
                    title: "Monitor \(index + 1)",
                    isPrimary: screen.isPrimary,
                    windows: buildPreviewWindows(for: screenWindows)
                )
            )
        }

        if !unassignedWindows.isEmpty {
            previewScreens.append(
                DSPreviewScreen(
                    id: -1,
                    title: "Unassigned",
                    isPrimary: false,
                    windows: buildPreviewWindows(for: unassignedWindows)
                )
            )
        }

        return previewScreens
    }

    private var layoutHealthTagLabel: String? {
        switch repairInference {
        case .resolved:
            return "Repair available"
        case .needsChoice:
            return "Choose mapping"
        case .unavailable:
            break
        }

        switch workspace.workspace.layoutHealth {
        case .healthy:
            return nil
        case .legacyFlattened:
            return "Legacy layout"
        case .legacyFlattenedBrokenPreview:
            return "Needs repair"
        }
    }

    private var repairNoticeTitle: String? {
        switch repairInference {
        case .resolved:
            return "Recovered monitor layout preview"
        case .needsChoice:
            return "Choose a recovered monitor mapping"
        case .unavailable:
            break
        }

        return workspace.workspace.layoutHealth == .legacyFlattenedBrokenPreview
            ? "Saved monitor layout is missing"
            : nil
    }

    private var repairNoticeMessage: String? {
        switch repairInference {
        case .resolved(let candidate):
            return "\(candidate.explanation) Review the preview and apply the repair if it matches what this workspace should look like."
        case .needsChoice(let candidates):
            let lead = candidates.first?.explanation ?? "DeskJig found several plausible monitor mappings from the saved config."
            return "\(lead) Pick the mapping that best matches this workspace before saving anything."
        case .unavailable(let reason):
            return workspace.workspace.layoutHealth == .legacyFlattenedBrokenPreview
                ? "This legacy workspace lost its monitor assignments, so DeskJig can’t show a reliable multi-display preview. DeskJig also couldn’t reconstruct it safely from the saved config: \(reason) If the intended apps are open now, you can still recapture the workspace from your current windows."
                : nil
        }
    }

    private var repairActionTitle: String? {
        switch repairInference {
        case .resolved:
            return "Apply repaired layout"
        case .needsChoice:
            return nil
        case .unavailable:
            break
        }

        return workspace.workspace.layoutHealth == .legacyFlattenedBrokenPreview
            ? "Recapture current windows"
            : nil
    }

    private var repairNoticeActions: [DSWorkspaceNoticeAction] {
        guard case .needsChoice(let candidates) = repairInference else { return [] }

        return Array(candidates.prefix(3)).enumerated().map { index, candidate in
            let title = "Use Mapping \(index + 1): \(candidate.selectionLabel)"
            let subtitle = candidate.monitorSummaries
                .map { "\($0.title): \($0.featureSummary)" }
                .joined(separator: " | ")

            return DSWorkspaceNoticeAction(
                id: "\(workspace.workspace.id.uuidString)-candidate-\(index)",
                title: title,
                subtitle: subtitle,
                action: { presentRepairConfirmation(for: candidate) }
            )
        }
    }

    private var hasRepairCandidateOrChoice: Bool {
        switch repairInference {
        case .resolved, .needsChoice:
            return true
        case .unavailable:
            return false
        }
    }

    private func buildPreviewWindows(for windows: [WorkspaceWindow]) -> [DSPreviewWindow] {
        let windowsNeedingFallback = windows.filter { $0.relativeFrame == nil }
        let fallbackFrames = fallbackRelativeFrames(count: windowsNeedingFallback.count)
        var fallbackIndex = 0

        return windows.map { window in
            let relativeFrame: RelativeWindowFrame
            if let frame = window.relativeFrame {
                relativeFrame = frame
            } else {
                relativeFrame = fallbackIndex < fallbackFrames.count
                    ? fallbackFrames[fallbackIndex]
                    : RelativeWindowFrame(xPercent: 0.1, yPercent: 0.1, widthPercent: 0.4, heightPercent: 0.4)
                fallbackIndex += 1
            }

            return DSPreviewWindow(
                id: window.id,
                appName: window.appName,
                icon: appIcon(for: window),
                xPercent: relativeFrame.xPercent,
                yPercent: relativeFrame.yPercent,
                widthPercent: relativeFrame.widthPercent,
                heightPercent: relativeFrame.heightPercent,
                specialAppType: DSSpecialAppType.from(bundleIdentifier: window.bundleIdentifier)
            )
        }
    }

    private func fallbackRelativeFrames(count: Int) -> [RelativeWindowFrame] {
        guard count > 0 else { return [] }
        let columns = Int(ceil(sqrt(Double(count))))
        let rows = Int(ceil(Double(count) / Double(columns)))
        let cellWidth = 1.0 / Double(columns)
        let cellHeight = 1.0 / Double(rows)

        var frames: [RelativeWindowFrame] = []
        for index in 0..<count {
            let row = index / columns
            let column = index % columns
            let insetX = cellWidth * 0.1
            let insetY = cellHeight * 0.1
            let width = cellWidth * 0.8
            let height = cellHeight * 0.8
            let x = Double(column) * cellWidth + insetX
            let y = Double(row) * cellHeight + insetY
            frames.append(RelativeWindowFrame(xPercent: x, yPercent: y, widthPercent: width, heightPercent: height))
        }
        return frames
    }

    private func appIcon(for window: WorkspaceWindow) -> NSImage? {
        return workspace.apps.first { $0.bundleIdentifier == window.bundleIdentifier }?.icon
    }

    private func findWorkspaceWindow(id: UUID) -> WorkspaceWindow? {
        workspace.workspace.windows.first { $0.id == id }
    }

    // MARK: - Selection Handling

    private func handleWindowTap(_ window: DSPreviewWindow) {
        guard isEditing, window.specialAppType != nil else { return }

        if selectedWindowId == window.id {
            withAnimation(.spring(duration: 0.25)) {
                selectedWindowId = nil
            }
            return
        }

        withAnimation(.spring(duration: 0.25)) {
            selectedWindowId = window.id
        }
    }

    private func loadSelectedWindowState(window: WorkspaceWindow) {
        selectedWindowPathStatus = .none

        if chromeBundleIdentifiers.contains(window.bundleIdentifier) {
            let modification = chromeModifications[window.id]
            let chromeState = window.chromeState

            if let modification {
                if modification.profileMatchMode == .anyWindow {
                    selectedChromeProfile = anyChromeWindowMarker
                } else {
                    selectedChromeProfile = modification.profileDirectory ?? chromeState?.profileDirectory
                }
                selectedChromeTabs = modification.tabURLs
            } else {
                if chromeState?.profileMatchMode == .anyWindow {
                    selectedChromeProfile = anyChromeWindowMarker
                } else {
                    selectedChromeProfile = chromeState?.profileDirectory
                }
                selectedChromeTabs = chromeState?.savedTabURLs ?? []
            }
            selectedShouldRestoreTabs = !selectedChromeTabs.isEmpty
            selectedWindowPath = ""
            return
        }

        if OpenByPathBundleIdentifiers.supported.contains(window.bundleIdentifier) {
            let modification = openByPathModifications[window.id]
            selectedWindowPath = modification?.openPath ?? window.openPath ?? ""
            selectedChromeProfile = nil
            selectedChromeTabs = []
            selectedShouldRestoreTabs = false
        }
    }

    // MARK: - Chrome Modifications

    private func updateChromeModificationForSelectedWindow() {
        guard let selectedId = selectedWindowId,
              let window = findWorkspaceWindow(id: selectedId),
              chromeBundleIdentifiers.contains(window.bundleIdentifier) else {
            return
        }

        let tabURLs = selectedShouldRestoreTabs ? selectedChromeTabs : []

        if selectedChromeProfile == anyChromeWindowMarker {
            chromeModifications[selectedId] = ChromeWindowModification(
                tabURLs: tabURLs,
                profileDirectory: nil,
                profileDisplayName: nil,
                profileHostedDomain: nil,
                profileUserName: nil,
                profileMatchMode: .anyWindow
            )
            return
        }

        var profileDisplayName: String? = nil
        var profileHostedDomain: String? = nil
        var profileUserName: String? = nil

        if let selectedDirectory = selectedChromeProfile,
           let profile = chromeProfileManager.profile(forDirectory: selectedDirectory) {
            profileDisplayName = profile.appleScriptDisplayName
            profileHostedDomain = profile.hostedDomain
            profileUserName = profile.userName
        }

        chromeModifications[selectedId] = ChromeWindowModification(
            tabURLs: tabURLs,
            profileDirectory: selectedChromeProfile,
            profileDisplayName: profileDisplayName,
            profileHostedDomain: profileHostedDomain,
            profileUserName: profileUserName,
            profileMatchMode: .specific
        )
    }

    private func loadChromeTabsFromRunningChrome() async -> Bool {
        guard let selectedId = selectedWindowId,
              let window = findWorkspaceWindow(id: selectedId),
              chromeBundleIdentifiers.contains(window.bundleIdentifier) else {
            return false
        }

        let windowTitle = window.windowTitle
        let currentProfileName = window.chromeState?.profileDisplayName
        let captures = await Task.detached {
            ChromeAutomationService.captureOpenWindows()
        }.value

        var matchedCapture = captures.first { capture in
            capture.title.localizedCaseInsensitiveContains(windowTitle) ||
            windowTitle.localizedCaseInsensitiveContains(capture.title.components(separatedBy: " - ").first ?? "")
        }

        if matchedCapture == nil, let profileName = currentProfileName {
            matchedCapture = captures.first { capture in
                guard let captureProfile = capture.profileAppleScriptName else { return false }
                return captureProfile == profileName ||
                    captureProfile.localizedCaseInsensitiveContains(profileName) ||
                    profileName.localizedCaseInsensitiveContains(captureProfile)
            }
        }

        let captureToUse: ChromeAppleScriptWindowCapture?
        if let matchedCapture {
            captureToUse = matchedCapture
        } else if captures.count == 1 {
            captureToUse = captures[0]
        } else {
            captureToUse = nil
        }

        guard let capture = captureToUse else {
            return false
        }

        await MainActor.run {
            selectedChromeTabs = capture.tabURLs
            selectedShouldRestoreTabs = !capture.tabURLs.isEmpty

            if let captureProfile = capture.profileAppleScriptName,
               let profile = chromeProfileManager.profile(forAppleScriptName: captureProfile) {
                selectedChromeProfile = profile.directory
            }
        }

        return true
    }

    // MARK: - Open By Path Modifications

    private func updateOpenByPathModificationForSelectedWindow() {
        guard let selectedId = selectedWindowId,
              let window = findWorkspaceWindow(id: selectedId),
              OpenByPathBundleIdentifiers.supported.contains(window.bundleIdentifier) else {
            return
        }

        let trimmed = selectedWindowPath.trimmingCharacters(in: .whitespacesAndNewlines)
        let openPath = trimmed.isEmpty ? nil : trimmed

        openByPathModifications[selectedId] = OpenByPathWindowModification(
            bundleIdentifier: window.bundleIdentifier,
            windowTitle: window.windowTitle,
            openPath: openPath
        )
    }

    private func verifySelectedPath(_ path: String) {
        selectedWindowPathStatus = .verifying

        Task { @MainActor in
            let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                selectedWindowPathStatus = .failed("Enter a path to verify.")
                return
            }

            guard trimmed.hasPrefix("/") || trimmed.hasPrefix("~") else {
                selectedWindowPathStatus = .failed("Path must start with `~/` or `/`.")
                return
            }

            let expanded = (trimmed as NSString).expandingTildeInPath
            let url = URL(fileURLWithPath: expanded).standardizedFileURL

            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
                selectedWindowPathStatus = .failed("Path does not exist.")
                return
            }

            guard isDirectory.boolValue else {
                selectedWindowPathStatus = .failed("Path is not a directory.")
                return
            }

            selectedWindowPathStatus = .verified
        }
    }

    private func applyPathToAllOpenByPathWindows(_ path: String) {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        let openPath = trimmed.isEmpty ? nil : trimmed

        for window in workspace.workspace.windows {
            guard BundleRegistry.isTerminal(window.bundleIdentifier) || BundleRegistry.isIDE(window.bundleIdentifier) else { continue }
            openByPathModifications[window.id] = OpenByPathWindowModification(
                bundleIdentifier: window.bundleIdentifier,
                windowTitle: window.windowTitle,
                openPath: openPath
            )
        }
        selectedWindowPathStatus = .none
    }

    // MARK: - Edit Mode Actions

    private func enterEditMode() {
        editedName = workspace.workspace.name
        editedIcon = workspace.workspace.icon ?? WorkspaceEditorPanelContent.defaultEmoji

        chromeModifications = [:]
        for window in workspace.workspace.windows {
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
            }
        }

        openByPathModifications = [:]
        for window in workspace.workspace.windows {
            if OpenByPathBundleIdentifiers.supported.contains(window.bundleIdentifier),
               let openPath = window.openPath {
                openByPathModifications[window.id] = OpenByPathWindowModification(
                    bundleIdentifier: window.bundleIdentifier,
                    windowTitle: window.windowTitle,
                    openPath: openPath
                )
            }
        }

        refreshChromeProfiles()
        selectedWindowId = nil

        withAnimation(.spring(duration: 0.25)) {
            isEditing = true
        }
    }

    private func handleAutoEdit(_ workspaceId: UUID?) {
        guard let workspaceId,
              workspaceId == workspace.workspace.id else { return }
        if !isEditing {
            enterEditMode()
        }
        onAutoEditHandled?()
    }

    private func refreshChromeProfiles() {
        let profiles = chromeProfileManager.refreshProfilesSync()
        var options: [DSSelectOption<String>] = [
            DSSelectOption(id: anyChromeWindowMarker, label: "Any Chrome Window")
        ]
        options.append(contentsOf: profiles.map { profile in
            DSSelectOption(id: profile.directory, label: profile.appleScriptName)
        })
        chromeProfiles = options
    }

    private func logLayoutHealthIfNeeded() {
        guard !hasLoggedLayoutHealth else { return }
        hasLoggedLayoutHealth = true

        let health = workspace.workspace.layoutHealth
        guard health != .healthy else { return }

        var fields: [String: String] = [
            "workspace": workspace.workspace.name,
            "workspaceID": workspace.workspace.id.uuidString,
            "layoutHealth": health.rawValue
        ]

        switch repairInference {
        case .resolved(let candidate):
            fields["repairInference"] = "available"
            fields["repairExplanation"] = candidate.explanation
            fields["repairConfidence"] = "\(candidate.confidence)"
        case .needsChoice(let candidates):
            fields["repairInference"] = "needsChoice"
            fields["repairCandidateCount"] = "\(candidates.count)"
        case .unavailable(let reason):
            fields["repairInference"] = "unavailable"
            fields["repairReason"] = reason
        }

        DeskJigLog.warn(.workspace, "Workspace card rendered for legacy flattened layout", fields: fields)
    }

    private func saveChanges() {
        let vmChromeModifications = chromeModifications.mapValues { mod in
            WorkspaceViewModel.ChromeWindowModification(
                tabURLs: mod.tabURLs,
                profileDirectory: mod.profileDirectory,
                profileDisplayName: mod.profileDisplayName,
                profileHostedDomain: mod.profileHostedDomain,
                profileUserName: mod.profileUserName,
                profileMatchMode: mod.profileMatchMode
            )
        }
        let vmOpenByPathModifications = openByPathModifications.mapValues { mod in
            WorkspaceViewModel.OpenByPathWindowModification(
                bundleIdentifier: mod.bundleIdentifier,
                windowTitle: mod.windowTitle,
                openPath: mod.openPath
            )
        }

        vm.updateWorkspaceInline(
            workspace: workspace.workspace,
            newName: editedName,
            newIcon: editedIcon,
            chromeModifications: vmChromeModifications,
            openByPathModifications: vmOpenByPathModifications
        )

        withAnimation(.spring(duration: 0.25)) {
            isEditing = false
            selectedWindowId = nil
        }
        onEditingFinished?()
    }

    private func cancelEditing() {
        withAnimation(.spring(duration: 0.25)) {
            isEditing = false
            selectedWindowId = nil
        }
        onEditingFinished?()
    }

    private func presentRepairConfirmation() {
        presentRepairConfirmation(for: nil)
    }

    private func presentRepairConfirmation(for selectedCandidate: WorkspaceLegacyLayoutRepairCandidate?) {
        DeskJigLog.info(.workspace, "Legacy workspace repair offered", fields: [
            "workspace": workspace.workspace.name,
            "workspaceID": workspace.workspace.id.uuidString,
            "layoutHealth": workspace.workspace.layoutHealth.rawValue,
            "repairInferenceAvailable": hasRepairCandidateOrChoice.description
        ])

        switch repairInference {
        case .resolved(let candidate):
            let candidateToApply = selectedCandidate ?? candidate
            confirmationManager.present(
                title: "Apply Repaired Layout?",
                message: "\(candidateToApply.explanation) This will save the reconstructed monitor assignments for \"\(workspace.workspace.name)\" without recapturing your current windows.",
                confirmTitle: "Apply Repair",
                cancelTitle: "Not Now",
                isDestructive: false,
                onConfirm: {
                    DeskJigLog.info(.workspace, "Inferred legacy workspace repair confirmed", fields: [
                        "workspace": workspace.workspace.name,
                        "workspaceID": workspace.workspace.id.uuidString
                    ])
                    vm.applyLegacyWorkspaceRepairCandidate(candidateToApply, to: workspace.workspace)
                },
                onCancel: {
                    DeskJigLog.info(.workspace, "Inferred legacy workspace repair ignored", fields: [
                        "workspace": workspace.workspace.name,
                        "workspaceID": workspace.workspace.id.uuidString
                    ])
                }
            )
        case .needsChoice(let candidates):
            guard let candidateToApply = selectedCandidate ?? candidates.first else { return }
            confirmationManager.present(
                title: "Apply Selected Mapping?",
                message: "\(candidateToApply.explanation) This will save the selected monitor assignment for \"\(workspace.workspace.name)\".",
                confirmTitle: "Use This Mapping",
                cancelTitle: "Not Now",
                isDestructive: false,
                onConfirm: {
                    DeskJigLog.info(.workspace, "Legacy workspace repair choice confirmed", fields: [
                        "workspace": workspace.workspace.name,
                        "workspaceID": workspace.workspace.id.uuidString,
                        "candidateScore": "\(candidateToApply.score)"
                    ])
                    vm.applyLegacyWorkspaceRepairCandidate(candidateToApply, to: workspace.workspace)
                },
                onCancel: {
                    DeskJigLog.info(.workspace, "Legacy workspace repair choice ignored", fields: [
                        "workspace": workspace.workspace.name,
                        "workspaceID": workspace.workspace.id.uuidString
                    ])
                }
            )
        case .unavailable:
            confirmationManager.present(
                title: "Recapture Workspace Layout?",
                message: "DeskJig could not reconstruct the missing monitor assignments for \"\(workspace.workspace.name)\" safely from the saved config. If the intended apps are open and arranged now, you can replace the saved layout using your current windows.",
                confirmTitle: "Recapture Layout",
                cancelTitle: "Not Now",
                isDestructive: false,
                onConfirm: {
                    DeskJigLog.info(.workspace, "Legacy workspace recapture confirmed", fields: [
                        "workspace": workspace.workspace.name,
                        "workspaceID": workspace.workspace.id.uuidString
                    ])
                    vm.recaptureLegacyWorkspaceLayout(workspace.workspace)
                },
                onCancel: {
                    DeskJigLog.info(.workspace, "Legacy workspace recapture ignored", fields: [
                        "workspace": workspace.workspace.name,
                        "workspaceID": workspace.workspace.id.uuidString
                    ])
                }
            )
        }
    }

    private func deleteWorkspace() {
        vm.deleteWorkspace(workspace.workspace)
        MainActor.async(after: .milliseconds(100)) {
            appDelegate.actionPanelManager?.updateDynamicContent()
        }
        onEditingFinished?()
    }

    private func presentDeleteConfirmation() {
        confirmationManager.present(
            title: "Delete Workspace?",
            message: "This will permanently remove the workspace and its saved layout.",
            confirmTitle: "Delete Workspace",
            cancelTitle: "Cancel",
            isDestructive: true,
            confirmAccessibilityIdentifier: "workspace.delete-confirm-button",
            onConfirm: { deleteWorkspace() },
            onCancel: {}
        )
    }

    // MARK: - Hotkey Helpers

    private var workspaceShortcutNames: [KeyboardShortcuts.Name] {
        vm.workspaces.map { .workspace($0.workspace.id) }
    }

    private func workspaceName(for name: KeyboardShortcuts.Name) -> String? {
        vm.workspaces.first { .workspace($0.workspace.id) == name }?.workspace.name
    }
}
