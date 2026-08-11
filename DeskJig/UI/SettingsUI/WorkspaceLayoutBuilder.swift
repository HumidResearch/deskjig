//
//  WorkspaceLayoutBuilder.swift
//  DeskJig
//
//  Created by Codex on 02/04/26.
//

import SwiftUI
import AppKit
import DeskJigShared

struct WorkspaceLayoutBuilder: View {
    @Bindable var viewModel: WorkspaceDraftViewModel
    @Binding var editorPathFieldFocused: Bool
    var isSelected: Bool
    let primaryTitle: String
    let secondaryTitle: String
    let primaryAccessibilityIdentifier: String
    let secondaryAccessibilityIdentifier: String
    let onPrimary: () -> Void
    let onSecondary: () -> Void
    var isPrimaryEnabled: Bool

    @EnvironmentObject private var confirmationManager: DSConfirmationManager

    @State private var isHovering = false
    @State private var isPickingIcon = false
    @State private var searchQuery = ""
    @State private var selectedFilter: AppFilter = .all
    @State private var selectedWindowPathStatus: DSFolderVerificationStatus = .none
    @State private var isArrangementExpanded = true
    /// Preset grid starts expanded so picking a layout is step 1; choosing a
    /// preset folds the grid into the inline layout pill (#598), and the pill
    /// re-expands a compact grid for switching presets.
    @State private var isPresetPickerExpanded = true

    private let headerElementHeight: CGFloat = 36
    private let zoneLayoutListWidth: CGFloat = 320
    private let zoneLayoutEditorMinWidth: CGFloat = 420
    /// Zone canvas grows with the available creator height between these
    /// bounds (#597) — the upper bound keeps zones from becoming towers.
    private let zoneLayoutEditorPreviewMinHeight: CGFloat = 300
    private let zoneLayoutEditorPreviewMaxHeight: CGFloat = 620

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.gapRegular) {
            headerRow

            // Fill-or-scroll (#597): the builder is given the full remaining
            // creator height so the zone-layout row can flex to consume it;
            // the scroll view only engages when the window is shorter than
            // the sections' minimum heights.
            GeometryReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: DesignTokens.Spacing.gapRegular) {
                        builderSection
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .frame(minHeight: proxy.size.height, alignment: .top)
                }
                .scrollBounceBehavior(.basedOnSize)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DSWindowDragControl(isMovableByBackground: false))
        .padding(DesignTokens.Card.padding)
        .dsCard(isHighlighted: isHovering || isSelected)
        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Card.cornerRadius))
        .onHover { isHovering = $0 }
        .animation(.smooth(duration: 0.15), value: isHovering)
        .onChange(of: viewModel.selectedWindowId) { _, _ in
            selectedWindowPathStatus = .none
            if viewModel.selectedWindowId == nil {
                editorPathFieldFocused = false
            }
        }
        .onChange(of: searchQuery) { _, _ in
            selectedFilter = .all
        }
    }

    // MARK: - Header

    private var headerRow: some View {
        HStack(spacing: DesignTokens.Spacing.gapSmall) {
            Button { isPickingIcon = true } label: {
                Text(viewModel.workspaceIcon)
                    .font(brand: .h4)
                    .frame(width: headerElementHeight, height: headerElementHeight)
                    .background {
                        RoundedRectangle(cornerRadius: DesignTokens.CornerRadius.medium)
                            .fill(DesignTokens.Surface.card)
                    }
                    .overlay {
                        RoundedRectangle(cornerRadius: DesignTokens.CornerRadius.medium)
                            .stroke(DesignTokens.Border.regular, lineWidth: 1)
                    }
            }
            .buttonStyle(.plain)
            .brightenOnHover()
            .popover(isPresented: $isPickingIcon) {
                DSEmojiPicker(selectedEmoji: $viewModel.workspaceIcon, isPresented: $isPickingIcon)
            }

            DSTextField(
                placeholder: "Workspace name",
                text: $viewModel.workspaceName,
                accessibilityIdentifier: "workspace.name-field"
            )
                .frame(maxWidth: 220)

            Spacer()

            HStack(spacing: DesignTokens.Spacing.gapSmall) {
                Button(action: onSecondary) {
                    Text(secondaryTitle)
                }
                .buttonStyle(.dsButton(variant: .secondary, size: .medium, formHeight: true))
                .frame(height: headerElementHeight)
                .brightenOnHover()
                .accessibilityIdentifier(secondaryAccessibilityIdentifier)

                Button(action: onPrimary) {
                    Text(primaryTitle)
                }
                .buttonStyle(.dsButton(variant: .primary, size: .medium, formHeight: true))
                .frame(height: headerElementHeight)
                .brightenOnHover()
                .disabled(!isPrimaryEnabled)
                .accessibilityIdentifier(primaryAccessibilityIdentifier)
            }
        }
    }

    // MARK: - Builder

    private var builderSection: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.gapMedium) {
            arrangementSection

            zoneLayoutSection

            VStack(alignment: .leading, spacing: DesignTokens.Spacing.gapSmall) {
                Text("Add apps")
                    .font(brand: .label3)
                    .foregroundStyle(DesignTokens.Text.secondary)

                Text("Drag apps into zones, or click a zone in the Select tab to load it.")
                    .font(brand: .body4)
                    .foregroundStyle(DesignTokens.Text.tertiary)

                appFilterBar

                DSAppSearchBar(
                    query: $searchQuery,
                    results: filteredApps,
                    onSelectApp: { app in
                        guard let selectedZoneId = viewModel.selectedZoneId,
                              let screenIndex = viewModel.screenIndex(containing: selectedZoneId) else { return }
                        viewModel.assignApp(bundleId: app.bundleId, to: selectedZoneId, screenIndex: screenIndex)
                    }
                )
            }
        }
    }

    // MARK: - Data Mapping
    private var safeSelectedScreenIndex: Int {
        if viewModel.screens.indices.contains(viewModel.selectedScreenIndex) {
            return viewModel.selectedScreenIndex
        }
        return 0
    }

    private var selectedScreen: WorkspaceDraftViewModel.DraftScreen? {
        guard viewModel.screens.indices.contains(safeSelectedScreenIndex) else { return nil }
        return viewModel.screens[safeSelectedScreenIndex]
    }

    private let addMonitorSentinel = -1

    private var monitorDropdownOptions: [DSSelectOption<Int>] {
        var options = viewModel.orderedScreenIndices().map { index in
            DSSelectOption(id: index, label: viewModel.screens[index].title)
        }
        if viewModel.screens.count < viewModel.maxScreens {
            options.append(DSSelectOption(id: addMonitorSentinel, label: "+ Add monitor"))
        }
        return options
    }

    private var monitorDropdownSelection: Binding<Int?> {
        Binding<Int?>(
            get: { safeSelectedScreenIndex },
            set: { newIndex in
                guard let index = newIndex else { return }
                if index == addMonitorSentinel {
                    viewModel.addVirtualScreen()
                } else {
                    selectMonitor(screenIndex: index)
                }
            }
        )
    }

    private var layoutPresetSection: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.gapSmall) {
            HStack(spacing: DesignTokens.Spacing.gapSmall) {
                Text("Layout preset")
                    .font(brand: .label3)
                    .foregroundStyle(DesignTokens.Text.secondary)

                if let screen = selectedScreen {
                    Text(screen.title)
                        .font(brand: .body4)
                        .foregroundStyle(DesignTokens.Text.muted)

                    Text(viewModel.displayName(for: safeSelectedScreenIndex))
                        .font(brand: .body4)
                        .foregroundStyle(DesignTokens.Text.tertiary)

                    if viewModel.isGhostScreen(safeSelectedScreenIndex) {
                        DSTag(label: "Saved Only", color: DesignTokens.Status.warning, size: .small)
                    }
                }

                // Collapsed picker (#598): the grid folds into this pill after
                // a preset is picked; clicking it toggles the compact grid.
                DSLayoutPresetPill(
                    preset: layoutPreset(for: safeSelectedScreenIndex),
                    isExpanded: isPresetPickerExpanded,
                    onTap: {
                        withAnimation(.smooth(duration: 0.18)) {
                            isPresetPickerExpanded.toggle()
                        }
                    }
                )
            }

            if isPresetPickerExpanded {
                DSLayoutPresetPicker(
                    presets: LayoutPreset.allCases,
                    selectedPreset: layoutPreset(for: safeSelectedScreenIndex),
                    onSelect: { preset in
                        viewModel.setLayout(preset, for: safeSelectedScreenIndex)
                        withAnimation(.smooth(duration: 0.18)) {
                            isPresetPickerExpanded = false
                        }
                    },
                    isCompact: true
                )
                .padding(.leading, 2)
                .transition(.animatedBlur)
            }
        }
    }

    private var zoneLayoutSection: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.gapSmall) {
            Text("Zone layout")
                .font(brand: .label3)
                .foregroundStyle(DesignTokens.Text.secondary)

            Text("Pick a workspace display to edit its monitor assignment and zone layout.")
                .font(brand: .body4)
                .foregroundStyle(DesignTokens.Text.tertiary)

            HStack(alignment: .top, spacing: DesignTokens.Spacing.gapMedium) {
                appConfigSidebar
                    .frame(width: zoneLayoutListWidth)

                selectedMonitorEditor
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    /// The sidebar never participates in the row-height calculation (#597):
    /// it fills whatever height the zone canvas column sets and scrolls its
    /// own content internally when the config panel outgrows that height.
    private var appConfigSidebar: some View {
        GeometryReader { proxy in
            ScrollView {
                appConfigSidebarContent
                    .frame(maxWidth: .infinity, minHeight: proxy.size.height, alignment: .topLeading)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .padding(DesignTokens.Card.paddingCompact)
        .background(zoneLayoutPanelBackground)
    }

    private var appConfigSidebarContent: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.gapSmall) {
            Text("App configuration")
                .font(brand: .body4)
                .foregroundStyle(DesignTokens.Text.tertiary)

            selectedZoneStackSection

            if let selectedWindow = selectedPreviewWindow {
                DSWindowConfigPanel(
                    window: selectedWindow,
                    directoryPath: selectedWindowPathBinding,
                    pathVerificationStatus: selectedWindowPathStatus,
                    onVerifyPath: verifySelectedPath,
                    onClearPath: {
                        selectedWindowPathBinding.wrappedValue = ""
                        selectedWindowPathStatus = .none
                    },
                    onApplyPathToAll: {
                        viewModel.applyOpenPathToAllOpenByPathWindows(
                            path: selectedWindowPathBinding.wrappedValue
                        )
                        selectedWindowPathStatus = .none
                    },
                    onPathFocusChange: { isFocused in
                        editorPathFieldFocused = isFocused
                    },
                    chromeProfile: selectedChromeProfileBinding,
                    shouldRestoreTabs: selectedShouldRestoreTabsBinding,
                    chromeTabs: selectedChromeTabsBinding,
                    chromeProfiles: chromeProfileOptions,
                    onLoadTabs: {
                        await loadChromeTabsForSelectedWindow()
                    },
                    onAddTab: { url in
                        var tabs = selectedChromeTabsBinding.wrappedValue
                        tabs.append(url)
                        selectedChromeTabsBinding.wrappedValue = tabs
                    },
                    onRemoveTab: { index in
                        var tabs = selectedChromeTabsBinding.wrappedValue
                        if tabs.indices.contains(index) {
                            tabs.remove(at: index)
                            selectedChromeTabsBinding.wrappedValue = tabs
                        }
                    },
                    onDismiss: { viewModel.selectedWindowId = nil }
                )
                .onChange(of: selectedWindowPathBinding.wrappedValue) { _, _ in
                    if selectedWindowPathStatus != .none {
                        selectedWindowPathStatus = .none
                    }
                }
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "app.dashed")
                        .font(.system(size: 28))
                        .foregroundStyle(DesignTokens.Text.muted)

                    Text("Select an app in a zone to configure it")
                        .font(brand: .body4)
                        .foregroundStyle(DesignTokens.Text.muted)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.vertical, 40)
            }
        }
    }

    @ViewBuilder
    private var selectedZoneStackSection: some View {
        if let zoneId = viewModel.selectedZoneId,
           let screenIndex = viewModel.screenIndex(containing: zoneId),
           let zone = viewModel.zones(for: screenIndex).first(where: { $0.id == zoneId }) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(zone.assignedWindowIDs.count > 1 ? "Folder stack" : "Zone contents")
                        .font(brand: .label3)
                        .foregroundStyle(DesignTokens.Text.secondary)

                    Spacer()

                    if zone.assignedWindowIDs.count > 1 {
                        Text("\(zone.assignedWindowIDs.count) apps")
                            .font(brand: .body4)
                            .foregroundStyle(DesignTokens.Text.tertiary)
                    }
                }

                if zone.assignedWindowIDs.isEmpty {
                    Text("Drop multiple apps into this zone to prototype a folder tab stack.")
                        .font(brand: .body4)
                        .foregroundStyle(DesignTokens.Text.tertiary)
                } else {
                    VStack(spacing: 8) {
                        ForEach(Array(zone.assignedWindowIDs.enumerated()), id: \.element) { index, windowId in
                            if let window = viewModel.window(for: windowId) {
                                zoneStackRow(
                                    zoneId: zoneId,
                                    window: window,
                                    index: index,
                                    count: zone.assignedWindowIDs.count
                                )
                            }
                        }
                    }
                }
            }
            .padding(12)
            .background {
                RoundedRectangle(cornerRadius: DesignTokens.CornerRadius.large)
                    .fill(DesignTokens.Surface.card)
            }
            .overlay {
                RoundedRectangle(cornerRadius: DesignTokens.CornerRadius.large)
                    .stroke(DesignTokens.Border.subtle, lineWidth: 1)
            }
        } else {
            EmptyView()
        }
    }

    private func zoneStackRow(
        zoneId: UUID,
        window: WorkspaceDraftViewModel.DraftWindow,
        index: Int,
        count: Int
    ) -> some View {
        let isSelected = viewModel.selectedWindowId == window.id

        return HStack(spacing: 8) {
            Group {
                if let icon = window.appInfo.icon {
                    Image(nsImage: icon)
                        .resizable()
                } else {
                    Image(systemName: "app.fill")
                        .font(brand: Font.brandBody(size: 14))
                        .foregroundStyle(DesignTokens.Text.muted)
                }
            }
            .frame(width: 18, height: 18)

            VStack(alignment: .leading, spacing: 2) {
                Text(window.appInfo.name)
                    .font(brand: .body4)
                    .foregroundStyle(DesignTokens.Text.primary)
                    .lineLimit(1)

                Text(window.windowTitle)
                    .font(brand: .body4)
                    .foregroundStyle(DesignTokens.Text.tertiary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 4) {
                Button {
                    viewModel.moveWindowInZone(zoneId: zoneId, windowId: window.id, by: -1)
                } label: {
                    Image(systemName: "arrow.up")
                        .font(brand: Font.brandBody(size: 10))
                }
                .buttonStyle(.plain)
                .disabled(index == 0)

                Button {
                    viewModel.moveWindowInZone(zoneId: zoneId, windowId: window.id, by: 1)
                } label: {
                    Image(systemName: "arrow.down")
                        .font(brand: Font.brandBody(size: 10))
                }
                .buttonStyle(.plain)
                .disabled(index == count - 1)

                Button {
                    viewModel.unassignWindow(window.id)
                    if viewModel.selectedWindowId == window.id {
                        viewModel.selectedWindowId = viewModel.zoneWindowIDs(zoneId: zoneId).first
                    }
                } label: {
                    Image(systemName: "minus.circle")
                        .font(brand: Font.brandBody(size: 10))
                }
                .buttonStyle(.plain)
            }
            .foregroundStyle(DesignTokens.Text.secondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background {
            RoundedRectangle(cornerRadius: DesignTokens.CornerRadius.medium)
                .fill(isSelected ? DesignTokens.LayoutPreview.tileSelectedFill : DesignTokens.Surface.card)
        }
        .overlay {
            RoundedRectangle(cornerRadius: DesignTokens.CornerRadius.medium)
                .stroke(isSelected ? DesignTokens.LayoutPreview.tileSelectedStroke : DesignTokens.Border.subtle, lineWidth: 1)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            viewModel.selectedZoneId = zoneId
            viewModel.selectedWindowId = window.id
        }
    }

    private var monitorList: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.gapSmall) {
            Text("Workspace displays")
                .font(brand: .body4)
                .foregroundStyle(DesignTokens.Text.tertiary)

            VStack(spacing: 8) {
                ForEach(viewModel.orderedScreenIndices(), id: \.self) { index in
                    monitorRow(for: viewModel.screens[index], index: index)
                }
            }

            addMonitorButton
                .padding(.top, 4)
        }
        .padding(DesignTokens.Card.paddingCompact)
        .background(zoneLayoutPanelBackground)
    }

    @ViewBuilder
    private func monitorRow(for screen: WorkspaceDraftViewModel.DraftScreen, index: Int) -> some View {
        let isSelected = safeSelectedScreenIndex == index

        HStack(alignment: .top, spacing: 8) {
            Button {
                selectMonitor(screenIndex: index)
            } label: {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .top, spacing: DesignTokens.Spacing.gapSmall) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(screen.title)
                                .font(brand: .label3)
                                .foregroundStyle(DesignTokens.Text.primary)
                                .lineLimit(1)

                            Text(viewModel.displayName(for: index))
                                .font(brand: .body4)
                                .foregroundStyle(DesignTokens.Text.muted)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)

                        HStack(spacing: 6) {
                            monitorBadges(for: index)
                        }
                    }

                    VStack(alignment: .leading, spacing: 2) {
                        Text(monitorAssignmentSummary(for: index))
                            .font(brand: .body4)
                            .foregroundStyle(DesignTokens.Text.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)

                        Text(viewModel.resolutionText(for: index))
                            .font(brand: .body4)
                            .foregroundStyle(DesignTokens.Text.tertiary)
                            .lineLimit(1)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background {
                    RoundedRectangle(cornerRadius: DesignTokens.CornerRadius.large)
                        .fill(isSelected ? DesignTokens.Surface.cardHover : DesignTokens.Surface.card)
                }
                .overlay {
                    RoundedRectangle(cornerRadius: DesignTokens.CornerRadius.large)
                        .stroke(isSelected ? DesignTokens.Brand.accent : DesignTokens.Border.subtle, lineWidth: isSelected ? 2 : 1)
                }
            }
            .buttonStyle(.plain)
            .brightenOnHover()

            if viewModel.screens.count > 1 {
                removeMonitorButton(screenIndex: index)
                    .padding(.top, 8)
            }
        }
    }

    private func removeMonitorButton(screenIndex: Int) -> some View {
        Button {
            viewModel.removeScreen(at: screenIndex)
        } label: {
            Image(systemName: "xmark.circle.fill")
                .font(brand: Font.brandBody(size: 12))
                .foregroundStyle(DesignTokens.Text.muted)
                .frame(width: 24, height: 24)
        }
        .buttonStyle(.plain)
        .brightenOnHover()
    }

    @ViewBuilder
    private var selectedMonitorEditor: some View {
        if let screen = selectedScreen {
            let screenIndex = safeSelectedScreenIndex

            VStack(alignment: .leading, spacing: DesignTokens.Spacing.gapMedium) {
                HStack(spacing: DesignTokens.Spacing.gapSmall) {
                    DSSelect(
                        options: monitorDropdownOptions,
                        selection: monitorDropdownSelection,
                        placeholder: "Select monitor...",
                        size: .compact
                    )
                    .frame(maxWidth: 200)

                    monitorBadges(for: screenIndex)

                    Spacer(minLength: 0)

                    HStack(spacing: 6) {
                        if viewModel.currentDisplayIndex(for: screenIndex) != nil {
                            cloneCurrentScreenButton(for: screenIndex)
                        }

                        if viewModel.screens.count > 1 {
                            Button {
                                viewModel.removeScreen(at: screenIndex)
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .font(brand: Font.brandBody(size: 12))
                                    .foregroundStyle(DesignTokens.Text.muted)
                                    .frame(width: 28, height: 28)
                                    .background {
                                        Circle()
                                            .fill(DesignTokens.Surface.card)
                                    }
                            }
                            .buttonStyle(.plain)
                            .brightenOnHover()
                        }
                    }
                }

                layoutPresetSection

                VStack(alignment: .leading, spacing: DesignTokens.Spacing.gapSmall) {
                    HStack {
                        Text("Zones")
                            .font(brand: .body3)
                            .foregroundStyle(DesignTokens.Text.secondary)

                        Spacer(minLength: 0)

                        Text("Select a zone to load it or drop an app into it.")
                            .font(brand: .body4)
                            .foregroundStyle(DesignTokens.Text.tertiary)
                    }

                    DSZoneEditor(
                        zones: zoneItems(for: screenIndex),
                        onDrop: { payload, zoneId in
                            handleDrop(payload: payload, zoneId: zoneId, screenIndex: screenIndex)
                        },
                        onSelectApp: { windowId in
                            viewModel.selectedWindowId = windowId
                        },
                        onSplitVertical: { zoneId in
                            viewModel.splitZone(zoneId: zoneId, direction: .vertical, screenIndex: screenIndex)
                        },
                        onSplitHorizontal: { zoneId in
                            viewModel.splitZone(zoneId: zoneId, direction: .horizontal, screenIndex: screenIndex)
                        },
                        onCloseZone: { zoneId in
                            viewModel.closeZone(zoneId: zoneId, screenIndex: screenIndex)
                        },
                        onSelectZone: { zoneId in
                            selectZone(zoneId, in: screenIndex)
                        },
                        onResizeBoundary: { axis, boundary, range, delta in
                            viewModel.resizeZoneBoundary(
                                screenIndex: screenIndex,
                                axis: axis,
                                boundary: boundary,
                                affectedRange: range,
                                delta: delta
                            )
                        },
                        onSelectMonitor: {
                            selectMonitor(screenIndex: screenIndex)
                        },
                        isPrimary: screen.isPrimary,
                        isSelectedMonitor: safeSelectedScreenIndex == screenIndex,
                        inset: 18
                    )
                    .frame(maxWidth: .infinity)
                    .frame(
                        minHeight: zoneLayoutEditorPreviewMinHeight,
                        maxHeight: zoneLayoutEditorPreviewMaxHeight
                    )
                    .padding(12)
                    .background {
                        RoundedRectangle(cornerRadius: DesignTokens.CornerRadius.xLarge)
                            .fill(DesignTokens.Surface.card)
                            .overlay(
                                RoundedRectangle(cornerRadius: DesignTokens.CornerRadius.xLarge)
                                    .stroke(DesignTokens.Border.subtle, lineWidth: 1)
                            )
                    }
                    // Creator canvas clips its content so zone chrome can
                    // never paint outside the card (#596).
                    .clipShape(RoundedRectangle(cornerRadius: DesignTokens.CornerRadius.xLarge))
                }
            }
            .padding(DesignTokens.Card.paddingCompact)
            .background(zoneLayoutPanelBackground)
        } else {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.gapSmall) {
                Text("No monitor selected")
                    .font(brand: .body3)
                    .foregroundStyle(DesignTokens.Text.secondary)

                Text("Select a workspace display to edit its zones.")
                    .font(brand: .body4)
                    .foregroundStyle(DesignTokens.Text.tertiary)
            }
            .padding(DesignTokens.Card.paddingCompact)
            .background(zoneLayoutPanelBackground)
        }
    }

    private func monitorDetailGrid(for screenIndex: Int) -> some View {
        let columns = Array(repeating: GridItem(.flexible(), spacing: DesignTokens.Spacing.gapSmall, alignment: .leading), count: 3)

        return LazyVGrid(columns: columns, alignment: .leading, spacing: DesignTokens.Spacing.gapSmall) {
            monitorDetailCard(title: "Status", value: viewModel.screenDetailText(for: screenIndex))
            monitorDetailCard(title: "Resolution", value: viewModel.resolutionText(for: screenIndex))
            monitorDetailCard(title: "Assignment", value: monitorAssignmentSummary(for: screenIndex))
        }
    }

    private func monitorDetailCard(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(brand: .body4)
                .foregroundStyle(DesignTokens.Text.tertiary)

            Text(value)
                .font(brand: .body3)
                .foregroundStyle(DesignTokens.Text.primary)
                .lineLimit(2)
                .truncationMode(.middle)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background {
            RoundedRectangle(cornerRadius: DesignTokens.CornerRadius.large)
                .fill(DesignTokens.Surface.card)
                .overlay(
                    RoundedRectangle(cornerRadius: DesignTokens.CornerRadius.large)
                        .stroke(DesignTokens.Border.subtle, lineWidth: 1)
                )
        }
    }

    @ViewBuilder
    private func monitorAssignmentEditor(for screenIndex: Int) -> some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.gapSmall) {
            Text("Connected display assignment")
                .font(brand: .body4)
                .foregroundStyle(DesignTokens.Text.tertiary)

            if viewModel.currentDisplayIndex(for: screenIndex) != nil {
                DSSelect(
                    options: assignmentSelectOptions,
                    selection: assignmentBinding(for: screenIndex),
                    placeholder: "Choose layout",
                    size: .compact
                )
                .frame(maxWidth: 280)

                Text("Changing this keeps the selected display and arrangement preview synced to the same monitor.")
                    .font(brand: .body4)
                    .foregroundStyle(DesignTokens.Text.tertiary)
            } else {
                Text("This saved workspace display is not currently assigned to a connected monitor. Use the monitor arrangement above to map it when that monitor is available.")
                    .font(brand: .body4)
                    .foregroundStyle(DesignTokens.Text.tertiary)
            }
        }
    }

    private var zoneLayoutPanelBackground: some View {
        RoundedRectangle(cornerRadius: DesignTokens.CornerRadius.xLarge)
            .fill(DesignTokens.Surface.elevated)
            .overlay(
                RoundedRectangle(cornerRadius: DesignTokens.CornerRadius.xLarge)
                    .stroke(DesignTokens.Border.subtle, lineWidth: 1)
            )
    }

    private var addMonitorButton: some View {
        Button {
            viewModel.addVirtualScreen()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "plus.circle")
                Text("Add monitor")
            }
            .font(brand: .body4)
        }
        .buttonStyle(.dsButton(variant: .secondary, size: .small))
        .frame(height: 32)
        .disabled(viewModel.screens.count >= viewModel.maxScreens)
    }

    private func cloneCurrentScreenButton(for screenIndex: Int) -> some View {
        Button {
            presentCloneLayoutConfirmation(for: screenIndex)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "document.on.document")
                Text(viewModel.isCloningScreenLayout && safeSelectedScreenIndex == screenIndex ? "Cloning..." : "Clone current screen")
            }
            .font(brand: .body4)
        }
        .buttonStyle(.dsButton(variant: .secondary, size: .small))
        .frame(height: 32)
        .disabled(viewModel.isCloningScreenLayout)
        .accessibilityIdentifier("workspace.clone-screen-button")
    }

    private var arrangementSection: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.gapSmall) {
            HStack(spacing: DesignTokens.Spacing.gapSmall) {
                Button {
                    withAnimation(.smooth(duration: 0.18)) {
                        isArrangementExpanded.toggle()
                    }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: isArrangementExpanded ? "chevron.down" : "chevron.right")
                            .font(brand: Font.brandBody(size: 11))
                            .foregroundStyle(DesignTokens.Text.tertiary)

                        Text("Monitor arrangement")
                            .font(brand: .label3)
                            .foregroundStyle(DesignTokens.Text.secondary)
                    }
                }
                .buttonStyle(.plain)

                Spacer()

                addMonitorButton
            }

            Text(arrangementSummaryText)
                .font(brand: .body4)
                .foregroundStyle(DesignTokens.Text.tertiary)

            if isArrangementExpanded {
                DSDisplayArrangementCanvas(
                    items: arrangementItems,
                    preferredHeight: 376,
                    onTap: handleArrangementTap(itemID:)
                )
                .padding(16)
                .background(
                    RoundedRectangle(cornerRadius: DesignTokens.CornerRadius.large)
                        .fill(DesignTokens.Surface.cardHover)
                        .overlay(
                            RoundedRectangle(cornerRadius: DesignTokens.CornerRadius.large)
                                .stroke(DesignTokens.Border.subtle, lineWidth: 1)
                        )
                )
                .padding(.top, 6)
            }
        }
        .padding(.bottom, 8)
    }

    private func layoutPreset(for screenIndex: Int) -> LayoutPreset {
        guard viewModel.layouts.indices.contains(screenIndex) else { return .fiftyFifty }
        return viewModel.layouts[screenIndex].preset
    }

    private let noneAssignmentID = "__none__"

    private var arrangementItems: [DSDisplayArrangementItem] {
        let assignmentOptions = savedScreenAssignmentOptions

        let liveItems = viewModel.currentDisplays.indices.map { currentIndex in
            let assignedScreenIndex = viewModel.assignedScreenIndex(for: currentIndex)
            let assignmentTitle = assignedScreenIndex.map { viewModel.screens[$0].title }
            let assignmentSubtitle = assignedScreenIndex.map { viewModel.displayName(for: $0) }

            return DSDisplayArrangementItem(
                id: currentDisplayItemID(currentIndex),
                frame: viewModel.currentDisplays[currentIndex].frame,
                title: viewModel.currentDisplays[currentIndex].name,
                subtitle: resolutionText(for: viewModel.currentDisplays[currentIndex].resolution),
                detail: assignedScreenIndex == nil ? "No workspace layout assigned" : "Connected display",
                assignmentTitle: assignmentTitle,
                assignmentSubtitle: assignmentSubtitle,
                isPrimary: viewModel.currentDisplays[currentIndex].isPrimary,
                isSelected: arrangementItemSelected(currentDisplayIndex: currentIndex, assignedScreenIndex: assignedScreenIndex),
                isLinkedHighlight: arrangementItemLinkedHighlight(currentDisplayIndex: currentIndex),
                assignmentOptions: assignmentOptions,
                selectedAssignmentID: assignedScreenIndex.map(savedScreenAssignmentID(for:)) ?? noneAssignmentID
            )
        }

        let ghostItems = viewModel.orderedScreenIndices()
            .filter(viewModel.isGhostScreen)
            .map { screenIndex in
                DSDisplayArrangementItem(
                    id: savedScreenItemID(screenIndex),
                    frame: viewModel.screens[screenIndex].frame,
                    title: viewModel.displayName(for: screenIndex),
                    subtitle: viewModel.resolutionText(for: screenIndex),
                    detail: viewModel.screens[screenIndex].title,
                    isPrimary: viewModel.screens[screenIndex].isPrimary,
                    isGhost: true,
                    isSelected: viewModel.selectedScreenIndex == screenIndex
                )
            }

        return liveItems + ghostItems
    }

    private var savedScreenAssignmentOptions: [DSDisplayArrangementAssignmentOption] {
        let screenOptions = viewModel.orderedScreenIndices().map { screenIndex in
            DSDisplayArrangementAssignmentOption(
                id: savedScreenAssignmentID(for: screenIndex),
                title: viewModel.screens[screenIndex].title,
                subtitle: "\(viewModel.displayName(for: screenIndex)) · \(viewModel.resolutionText(for: screenIndex))"
            )
        }

        return [
            DSDisplayArrangementAssignmentOption(
                id: noneAssignmentID,
                title: "No layout",
                subtitle: "Leave this display unassigned"
            )
        ] + screenOptions
    }

    private func currentDisplayItemID(_ currentIndex: Int) -> String {
        "current-\(currentIndex)"
    }

    private func savedScreenItemID(_ screenIndex: Int) -> String {
        "saved-\(screenIndex)"
    }

    private func savedScreenAssignmentID(for screenIndex: Int) -> String {
        "saved-layout-\(screenIndex)"
    }

    private func resolutionText(for resolution: CGSize) -> String {
        "\(Int(resolution.width)) x \(Int(resolution.height))"
    }

    private var arrangementSummaryText: String {
        let assignedCount = viewModel.currentDisplays.indices.compactMap { viewModel.assignedScreenIndex(for: $0) }.count
        return "\(viewModel.currentDisplays.count) connected display\(viewModel.currentDisplays.count == 1 ? "" : "s"), \(assignedCount) assigned. Select a display below to map a saved workspace layout without changing the macOS arrangement."
    }

    private var assignmentSelectOptions: [DSSelectOption<String>] {
        savedScreenAssignmentOptions.map { option in
            DSSelectOption(id: option.id, label: option.title)
        }
    }

    private func assignmentBinding(for screenIndex: Int) -> Binding<String?> {
        Binding(
            get: {
                guard let currentDisplayIndex = viewModel.currentDisplayIndex(for: screenIndex) else { return nil }
                return viewModel.assignedScreenIndex(for: currentDisplayIndex)
                    .map(savedScreenAssignmentID(for:)) ?? noneAssignmentID
            },
            set: { optionID in
                guard let currentDisplayIndex = viewModel.currentDisplayIndex(for: screenIndex),
                      let optionID else { return }
                handleArrangementAssignment(
                    itemID: currentDisplayItemID(currentDisplayIndex),
                    optionID: optionID
                )
            }
        )
    }

    private func arrangementItemSelected(currentDisplayIndex: Int, assignedScreenIndex: Int?) -> Bool {
        if let assignedScreenIndex {
            return viewModel.selectedScreenIndex == assignedScreenIndex
        }

        return viewModel.selectedDisplayTargetIndex == currentDisplayIndex
    }

    private func arrangementItemLinkedHighlight(currentDisplayIndex: Int) -> Bool {
        if let selectedDisplayTargetIndex = viewModel.selectedDisplayTargetIndex {
            return selectedDisplayTargetIndex == currentDisplayIndex
        }

        guard let selectedScreenIndex = viewModel.screens.indices.contains(viewModel.selectedScreenIndex)
            ? viewModel.selectedScreenIndex
            : nil else {
            return false
        }

        return viewModel.currentDisplayIndex(for: selectedScreenIndex) == currentDisplayIndex
    }

    private func handleArrangementTap(itemID: String) {
        if itemID.hasPrefix("current-"),
           let currentDisplayIndex = Int(itemID.dropFirst("current-".count)) {
            viewModel.selectedDisplayTargetIndex = currentDisplayIndex
            if let assignedScreenIndex = viewModel.assignedScreenIndex(for: currentDisplayIndex) {
                selectMonitor(screenIndex: assignedScreenIndex)
            } else {
                viewModel.selectedZoneId = nil
                viewModel.selectedWindowId = nil
                if viewModel.screens.indices.contains(0) {
                    viewModel.selectedScreenIndex = 0
                }
                highlightCurrentDisplay(index: currentDisplayIndex)
            }
            return
        }

        if itemID.hasPrefix("saved-"),
           let screenIndex = Int(itemID.dropFirst("saved-".count)) {
            selectMonitor(screenIndex: screenIndex)
        }
    }

    private func handleArrangementAssignment(itemID: String, optionID: String) {
        guard itemID.hasPrefix("current-"),
              let currentDisplayIndex = Int(itemID.dropFirst("current-".count)) else { return }

        if optionID == noneAssignmentID {
            if let assignedScreenIndex = viewModel.assignedScreenIndex(for: currentDisplayIndex) {
                viewModel.assignScreen(assignedScreenIndex, toCurrentDisplay: nil)
            }
            viewModel.selectedDisplayTargetIndex = currentDisplayIndex
            viewModel.selectedZoneId = nil
            viewModel.selectedWindowId = nil
            highlightCurrentDisplay(index: currentDisplayIndex)
            return
        }

        guard optionID.hasPrefix("saved-layout-"),
              let screenIndex = Int(optionID.dropFirst("saved-layout-".count)) else { return }
        viewModel.assignScreen(screenIndex, toCurrentDisplay: currentDisplayIndex)
        viewModel.selectedZoneId = nil
        viewModel.selectedWindowId = nil
        highlightCurrentDisplay(index: currentDisplayIndex)
    }

    @ViewBuilder
    private func monitorBadges(for screenIndex: Int) -> some View {
        if viewModel.currentDisplay(for: screenIndex)?.isPrimary == true || viewModel.screens[screenIndex].isPrimary {
            DSTag(label: "Primary", color: DesignTokens.Status.info, size: .small)
        }

        if viewModel.isGhostScreen(screenIndex) {
            DSTag(label: "Saved Only", color: DesignTokens.Status.warning, size: .small)
        }
    }

    private func monitorAssignmentSummary(for screenIndex: Int) -> String {
        if let currentDisplay = viewModel.currentDisplay(for: screenIndex) {
            return currentDisplay.name
        }

        return "Not assigned to a connected display"
    }

    private func selectMonitor(screenIndex: Int) {
        guard viewModel.screens.indices.contains(screenIndex) else { return }

        viewModel.selectedScreenIndex = screenIndex
        viewModel.selectedDisplayTargetIndex = viewModel.currentDisplayIndex(for: screenIndex)
        viewModel.selectedZoneId = nil
        viewModel.selectedWindowId = nil
        highlightCurrentDisplay(for: screenIndex)
    }

    private func selectZone(_ zoneId: UUID, in screenIndex: Int) {
        guard viewModel.screens.indices.contains(screenIndex) else { return }

        viewModel.selectedScreenIndex = screenIndex
        viewModel.selectedDisplayTargetIndex = viewModel.currentDisplayIndex(for: screenIndex)
        viewModel.selectedZoneId = zoneId
        highlightCurrentDisplay(for: screenIndex)

        if let zone = viewModel.zones(for: screenIndex).first(where: { $0.id == zoneId }) {
            if zone.assignedWindowIDs.isEmpty {
                viewModel.selectedWindowId = nil
            } else {
                viewModel.selectedWindowId = zone.primaryAssignedWindowID
            }
        } else {
            viewModel.selectedWindowId = nil
        }
    }

    private func highlightCurrentDisplay(for screenIndex: Int) {
        guard let currentDisplayIndex = viewModel.currentDisplayIndex(for: screenIndex) else { return }
        highlightCurrentDisplay(index: currentDisplayIndex)
    }

    private func highlightCurrentDisplay(index currentDisplayIndex: Int) {
        guard viewModel.currentDisplays.indices.contains(currentDisplayIndex) else { return }
        let currentDisplay = viewModel.currentDisplays[currentDisplayIndex]
        WindowHighlightOverlay.shared.showDisplayHighlight(
            around: currentDisplay.frame
        )
    }

    private func presentCloneLayoutConfirmation(for screenIndex: Int) {
        guard viewModel.screens.indices.contains(screenIndex) else { return }

        let monitorName = viewModel.screens[screenIndex].title
        let displayName = viewModel.displayName(for: screenIndex)

        confirmationManager.present(
            title: "Overwrite \(monitorName) Layout?",
            message: "This will replace the current zone layout for \(monitorName) with the windows currently visible on \(displayName). Any apps already assigned in this zone layout will be overwritten.",
            confirmTitle: "Clone Current Screen",
            cancelTitle: "Cancel",
            isDestructive: true,
            confirmAccessibilityIdentifier: "workspace.clone-screen-confirm",
            onConfirm: {
                Task { @MainActor in
                    _ = await viewModel.cloneCurrentDisplayLayout(into: screenIndex)
                }
            },
            onCancel: {}
        )
    }

    private func zoneItems(for screenIndex: Int) -> [DSZone] {
        let zones = viewModel.zones(for: screenIndex)
        return zones.map { zone in
            let app: DSZoneApp?
            let selectedWindowId = viewModel.selectedWindowId
            if let windowId = zone.primaryAssignedWindowID,
               let window = viewModel.windowsById[windowId] {
                app = DSZoneApp(
                    id: window.id,
                    name: window.appInfo.name,
                    icon: window.appInfo.icon,
                    specialAppType: DSSpecialAppType.from(bundleIdentifier: window.bundleId)
                )
            } else {
                app = nil
            }

            return DSZone(
                id: zone.id,
                frame: zone.frame,
                app: app,
                stackCount: zone.assignedWindowIDs.count,
                isSelected: selectedWindowId.map { zone.assignedWindowIDs.contains($0) } ?? false,
                isFocused: zone.id == viewModel.selectedZoneId,
                canSplitVertical: zone.canSplitVertical,
                canSplitHorizontal: zone.canSplitHorizontal
            )
        }
    }

    private func handleDrop(payload: String, zoneId: UUID, screenIndex: Int) -> Bool {
        if payload.hasPrefix("app:") {
            let bundleId = String(payload.dropFirst(4))
            viewModel.assignApp(bundleId: bundleId, to: zoneId, screenIndex: screenIndex)
            return true
        }

        if payload.hasPrefix("window:") {
            let idString = String(payload.dropFirst(7))
            if let windowId = UUID(uuidString: idString) {
                viewModel.assignWindow(windowId, to: zoneId, screenIndex: screenIndex)
                return true
            }
        }

        return false
    }

    private var filteredApps: [DSAppSearchResult] {
        let apps = viewModel.allInstalledApps
        let filtered: [AppInfo]
        if searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            filtered = apps
        } else {
            filtered = apps.filter { $0.name.localizedCaseInsensitiveContains(searchQuery) }
        }

        let categoryFiltered = filtered.filter { app in
            let bundleId = app.bundleIdentifier ?? app.path
            return selectedFilter.matches(bundleId: bundleId)
        }

        return categoryFiltered
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            .prefix(30)
            .map { app in
                let bundleId = app.bundleIdentifier ?? app.path
                return DSAppSearchResult(
                    id: bundleId,
                    name: app.name,
                    icon: app.icon,
                    bundleId: bundleId,
                    supportsMultipleInstances: BundleRegistry.isTerminal(bundleId) || BundleRegistry.isIDE(bundleId) || BundleRegistry.isChrome(bundleId)
                )
            }
    }

    private var appFilterBar: some View {
        HStack(spacing: DesignTokens.Spacing.gapSmall) {
            ForEach(AppFilter.allCases) { filter in
                Button {
                    selectedFilter = filter
                } label: {
                    Text(filter.label)
                        .font(brand: .label3)
                        .foregroundStyle(DesignTokens.Text.secondary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background {
                            RoundedRectangle(cornerRadius: DesignTokens.CornerRadius.medium)
                                .fill(selectedFilter == filter ? DesignTokens.LayoutPreview.tileSelectedFill : DesignTokens.WorkspaceBuilder.appChipFill)
                        }
                        .overlay {
                            RoundedRectangle(cornerRadius: DesignTokens.CornerRadius.medium)
                                .stroke(selectedFilter == filter ? DesignTokens.LayoutPreview.tileSelectedStroke : DesignTokens.Border.subtle, lineWidth: 1)
                        }
                }
                .buttonStyle(.plain)
                .brightenOnHover()
            }
        }
        .padding(.vertical, 2)
    }

    private enum AppFilter: String, CaseIterable, Identifiable {
        case all
        case terminals
        case ides
        case browsers
        case messaging
        case documents

        var id: String { rawValue }

        var label: String {
            switch self {
            case .all: return "All"
            case .terminals: return "Terminals"
            case .ides: return "IDEs"
            case .browsers: return "Browsers"
            case .messaging: return "Messaging"
            case .documents: return "Documents"
            }
        }

        func matches(bundleId: String) -> Bool {
            switch self {
            case .all:
                return true
            case .terminals:
                return BundleRegistry.isTerminal(bundleId)
            case .ides:
                return BundleRegistry.isIDE(bundleId)
            case .browsers:
                return BundleRegistry.isBrowser(bundleId)
            case .messaging:
                return BundleRegistry.isMessaging(bundleId)
            case .documents:
                return BundleRegistry.isDocument(bundleId)
            }
        }
    }

    // MARK: - Selected Window Config

    private var selectedPreviewWindow: DSPreviewWindow? {
        guard let selectedId = viewModel.selectedWindowId,
              let window = viewModel.windowsById[selectedId] else { return nil }

        if let zoneMatch = viewModel.zoneContaining(windowId: selectedId) {
            return DSPreviewWindow(
                id: window.id,
                appName: window.appInfo.name,
                icon: window.appInfo.icon,
                xPercent: zoneMatch.zone.frame.xPercent,
                yPercent: zoneMatch.zone.frame.yPercent,
                widthPercent: zoneMatch.zone.frame.widthPercent,
                heightPercent: zoneMatch.zone.frame.heightPercent,
                specialAppType: DSSpecialAppType.from(bundleIdentifier: window.bundleId)
            )
        }

        return DSPreviewWindow(
            id: window.id,
            appName: window.appInfo.name,
            icon: window.appInfo.icon,
            xPercent: 0,
            yPercent: 0,
            widthPercent: 1,
            heightPercent: 1,
            specialAppType: DSSpecialAppType.from(bundleIdentifier: window.bundleId)
        )
    }

    private var selectedWindowPathBinding: Binding<String> {
        guard let windowId = viewModel.selectedWindowId else {
            return .constant("")
        }
        return Binding(
            get: { viewModel.window(for: windowId)?.openPath ?? "" },
            set: { newValue in
                viewModel.setOpenPath(newValue, for: windowId)
            }
        )
    }

    private var selectedChromeProfileBinding: Binding<String?> {
        guard let windowId = viewModel.selectedWindowId else {
            return .constant(nil)
        }
        return Binding(
            get: { viewModel.window(for: windowId)?.chromeProfile },
            set: { newValue in
                viewModel.setChromeProfile(newValue, for: windowId)
            }
        )
    }

    private var selectedShouldRestoreTabsBinding: Binding<Bool> {
        guard let windowId = viewModel.selectedWindowId else {
            return .constant(false)
        }
        return Binding(
            get: { viewModel.window(for: windowId)?.shouldRestoreTabs ?? false },
            set: { newValue in
                viewModel.setShouldRestoreTabs(newValue, for: windowId)
            }
        )
    }

    private var selectedChromeTabsBinding: Binding<[String]> {
        guard let windowId = viewModel.selectedWindowId else {
            return .constant([])
        }
        return Binding(
            get: { viewModel.window(for: windowId)?.chromeTabs ?? [] },
            set: { newValue in
                viewModel.setChromeTabs(newValue, for: windowId)
            }
        )
    }

    private var chromeProfileOptions: [DSSelectOption<String>] {
        var options: [DSSelectOption<String>] = [
            DSSelectOption(id: viewModel.anyChromeWindowMarker, label: "Any Chrome Window")
        ]
        options.append(contentsOf: viewModel.availableChromeProfiles.map { profile in
            DSSelectOption(id: profile.directory, label: profile.appleScriptName)
        })
        return options
    }

    private func loadChromeTabsForSelectedWindow() async -> Bool {
        guard let windowId = viewModel.selectedWindowId else { return false }
        return await viewModel.loadChromeTabs(for: windowId)
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
}
