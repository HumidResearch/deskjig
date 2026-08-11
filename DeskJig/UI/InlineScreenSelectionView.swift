//  InlineScreenSelectionView.swift
//  DeskJig
//
//  Inline screen selection UI displayed within the workspace launch overlay
//  when monitor configuration differs between saved workspace and current setup.
//

import SwiftUI
import DeskJigShared

@MainActor @Observable
final class InlineScreenSelectionState {
    var selectedMappings: [ScreenMappingInfo]

    init(analysis: ScreenMismatchAnalysis) {
        let normalizedMappings = Self.normalizedMappings(
            analysis.suggestedMappings,
            savedScreenCount: analysis.savedScreens.count,
            currentScreenCount: analysis.currentScreens.count
        )
        DeskJigLog.info(.app, "[ScreenSelection] INIT raw=\(analysis.suggestedMappings.map { "s\($0.savedIndex)->c\(String(describing: $0.currentIndex))" })")
        DeskJigLog.info(.app, "[ScreenSelection] INIT after=\(normalizedMappings.map { "s\($0.savedIndex)->c\(String(describing: $0.currentIndex))" })")
        selectedMappings = normalizedMappings
    }

    func assignedLayoutIndex(forMonitor currentIndex: Int) -> Int? {
        selectedMappings.first(where: { $0.currentIndex == currentIndex })?.savedIndex
    }

    func mappingForSavedScreen(_ savedIndex: Int) -> ScreenMappingInfo? {
        selectedMappings.first(where: { $0.savedIndex == savedIndex })
    }

    func assignedSavedScreenIndex(for currentIndex: Int) -> Int? {
        selectedMappings.first(where: { $0.currentIndex == currentIndex })?.savedIndex
    }

    func cycleLayout(forMonitor currentIndex: Int, savedScreenCount: Int, currentScreenCount: Int) {
        DeskJigLog.info(.app, "[ScreenSelection] CYCLE tapped=\(currentIndex) before=\(selectedMappings.map { "s\($0.savedIndex)->c\(String(describing: $0.currentIndex))" })")
        let currentAssigned = assignedLayoutIndex(forMonitor: currentIndex)

        let nextSavedIndex: Int?
        if let current = currentAssigned {
            let next = current + 1
            nextSavedIndex = next < savedScreenCount ? next : nil
        } else {
            nextSavedIndex = 0
        }

        var updated = selectedMappings
        var displacedMonitor: Int?
        if let nextSaved = nextSavedIndex,
           let existingMapping = updated.first(where: { $0.savedIndex == nextSaved }),
           let existingMonitor = existingMapping.currentIndex,
           existingMonitor != currentIndex {
            displacedMonitor = existingMonitor
        }

        for i in updated.indices where updated[i].currentIndex == currentIndex {
            updated[i].currentIndex = nil
        }

        if let nextSaved = nextSavedIndex {
            if let savedMappingIndex = updated.firstIndex(where: { $0.savedIndex == nextSaved }) {
                updated[savedMappingIndex].currentIndex = currentIndex
            } else {
                updated.append(
                    ScreenMappingInfo(savedIndex: nextSaved, currentIndex: currentIndex, matchKind: .geometry)
                )
            }
        }

        if let displaced = displacedMonitor {
            let assignedSavedIndices = Set(updated.compactMap { $0.currentIndex != nil ? $0.savedIndex : nil })
            let availableLayout = (0..<savedScreenCount).first { !assignedSavedIndices.contains($0) }
            if let available = availableLayout,
               let availableMappingIndex = updated.firstIndex(where: { $0.savedIndex == available }) {
                updated[availableMappingIndex].currentIndex = displaced
            }
        }

        selectedMappings = Self.normalizedMappings(
            updated,
            savedScreenCount: savedScreenCount,
            currentScreenCount: currentScreenCount
        )
        DeskJigLog.info(.app, "[ScreenSelection] CYCLE after=\(selectedMappings.map { "s\($0.savedIndex)->c\(String(describing: $0.currentIndex))" })")
    }

    func assignSavedScreen(
        _ savedIndex: Int,
        toCurrentScreen currentIndex: Int,
        savedScreenCount: Int,
        currentScreenCount: Int
    ) {
        var updatedMappings = selectedMappings
        let previousSavedIndexOnCurrent = updatedMappings.first(where: { $0.currentIndex == currentIndex })?.savedIndex
        let displacedMonitor = updatedMappings.first(where: { $0.savedIndex == savedIndex })?.currentIndex

        if let currentMappingIndex = updatedMappings.firstIndex(where: { $0.currentIndex == currentIndex }),
           updatedMappings[currentMappingIndex].savedIndex != savedIndex {
            updatedMappings[currentMappingIndex].currentIndex = nil
        }

        if let savedMappingIndex = updatedMappings.firstIndex(where: { $0.savedIndex == savedIndex }) {
            updatedMappings[savedMappingIndex].currentIndex = currentIndex
        } else {
            updatedMappings.append(
                ScreenMappingInfo(savedIndex: savedIndex, currentIndex: currentIndex, matchKind: .geometry)
            )
        }

        if let displacedMonitor,
           displacedMonitor != currentIndex,
           let previousSavedIndexOnCurrent,
           previousSavedIndexOnCurrent != savedIndex,
           let previousMappingIndex = updatedMappings.firstIndex(where: { $0.savedIndex == previousSavedIndexOnCurrent }) {
            updatedMappings[previousMappingIndex].currentIndex = displacedMonitor
        }

        selectedMappings = Self.normalizedMappings(
            updatedMappings,
            savedScreenCount: savedScreenCount,
            currentScreenCount: currentScreenCount
        )
    }

    func clearAssignment(
        forCurrentScreen currentIndex: Int,
        savedScreenCount: Int,
        currentScreenCount: Int
    ) {
        guard let mappingIndex = selectedMappings.firstIndex(where: { $0.currentIndex == currentIndex }) else { return }
        selectedMappings[mappingIndex].currentIndex = nil
        selectedMappings = Self.normalizedMappings(
            selectedMappings,
            savedScreenCount: savedScreenCount,
            currentScreenCount: currentScreenCount
        )
    }

    private static func normalizedMappings(
        _ mappings: [ScreenMappingInfo],
        savedScreenCount: Int,
        currentScreenCount: Int
    ) -> [ScreenMappingInfo] {
        var normalizedBySavedIndex: [Int: ScreenMappingInfo] = [:]
        var usedCurrentIndices = Set<Int>()

        for mapping in mappings.sorted(by: { lhs, rhs in
            if lhs.savedIndex == rhs.savedIndex {
                return (lhs.currentIndex ?? .max) < (rhs.currentIndex ?? .max)
            }
            return lhs.savedIndex < rhs.savedIndex
        }) {
            guard (0..<savedScreenCount).contains(mapping.savedIndex) else { continue }

            var normalized = mapping
            if let currentIndex = normalized.currentIndex {
                if !(0..<currentScreenCount).contains(currentIndex) || usedCurrentIndices.contains(currentIndex) {
                    normalized.currentIndex = nil
                } else {
                    usedCurrentIndices.insert(currentIndex)
                }
            }

            if normalizedBySavedIndex[mapping.savedIndex] == nil || normalized.currentIndex != nil {
                normalizedBySavedIndex[mapping.savedIndex] = normalized
            }
        }

        return (0..<savedScreenCount).map { savedIndex in
            normalizedBySavedIndex[savedIndex] ?? ScreenMappingInfo(savedIndex: savedIndex, currentIndex: nil)
        }
    }
}

/// View displayed within the launch overlay when screen topology differs between the
/// saved workspace and the current setup. Users confirm which saved layouts should
/// restore to which connected displays.
struct InlineScreenSelectionView: View {
    let workspaceName: String
    let workspace: Workspace
    let analysis: ScreenMismatchAnalysis
    let applicationManager: ApplicationManager
    let selectionState: InlineScreenSelectionState
    let presentedCurrentScreenIndex: Int?
    let onConfirm: ([ScreenMappingInfo]) -> Void
    let onCancel: () -> Void

    @State private var focusedSavedScreenIndex: Int?
    @State private var selectedCurrentScreenIndex: Int?
    @FocusState private var isScreenSelectionFocused: Bool

    private let noneAssignmentID = "__none__"

    init(
        workspaceName: String,
        workspace: Workspace,
        analysis: ScreenMismatchAnalysis,
        selectionState: InlineScreenSelectionState,
        presentedCurrentScreenIndex: Int? = nil,
        applicationManager: ApplicationManager,
        onConfirm: @escaping ([ScreenMappingInfo]) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.workspaceName = workspaceName
        self.workspace = workspace
        self.analysis = analysis
        self.applicationManager = applicationManager
        self.selectionState = selectionState
        self.presentedCurrentScreenIndex = presentedCurrentScreenIndex
        self.onConfirm = onConfirm
        self.onCancel = onCancel

        let initialCurrentIndex = presentedCurrentScreenIndex
            ?? analysis.suggestedMappings.first(where: { $0.currentIndex != nil })?.currentIndex
            ?? analysis.currentScreens.indices.first
        _selectedCurrentScreenIndex = State(initialValue: initialCurrentIndex)
        _focusedSavedScreenIndex = State(
            initialValue: initialCurrentIndex.flatMap { currentIndex in
                analysis.suggestedMappings.first(where: { $0.currentIndex == currentIndex })?.savedIndex
            } ?? analysis.suggestedMappings.first(where: { $0.currentIndex != nil })?.savedIndex
        )
    }

    var body: some View {
        GeometryReader { proxy in
            let availableHeight = max(
                proxy.size.height - (DesignTokens.Spacing.contentPaddingRegular * 2),
                320
            )

            ScrollView(.vertical, showsIndicators: false) {
                panelBody
                    .frame(maxWidth: 920)
            }
            .frame(maxHeight: availableHeight)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            .padding(.horizontal, DesignTokens.Spacing.contentPaddingRegular)
            .padding(.vertical, DesignTokens.Spacing.contentPaddingRegular)
        }
        .background(Color.clear)
        .focusable()
        .focused($isScreenSelectionFocused)
        .focusEffectDisabled()
        .onAppear {
            MainActor.async {
                isScreenSelectionFocused = true
            }
        }
    }

    private var panelBody: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.gapXLarge) {
            headerSection
            savedLayoutsSection
            actionButtons
        }
        .padding(DesignTokens.Spacing.contentPaddingLarge)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(maxWidth: 920)
        .background {
            RoundedRectangle(cornerRadius: DesignTokens.CornerRadius.xxLarge)
                .fill(DesignTokens.Surface.panel)
        }
        .overlay {
            RoundedRectangle(cornerRadius: DesignTokens.CornerRadius.xxLarge)
                .stroke(DesignTokens.Border.subtle, lineWidth: 1)
        }
        .shadow(
            color: Color.black.opacity(DesignTokens.Shadow.large.opacity),
            radius: DesignTokens.Shadow.large.radius,
            x: 0,
            y: DesignTokens.Shadow.large.y
        )
        .preferredColorScheme(.dark)
    }

    private var headerSection: some View {
        HStack(alignment: .top, spacing: DesignTokens.Spacing.gapMedium) {
            ZStack {
                RoundedRectangle(cornerRadius: DesignTokens.Card.headerIconCornerRadius)
                    .fill(DesignTokens.Surface.accentMuted)
                Image(systemName: "display.trianglebadge.exclamationmark")
                    .font(.system(size: DesignTokens.Card.headerIconSize, weight: .semibold))
                    .foregroundStyle(DesignTokens.Brand.accent)
            }
            .frame(width: 40, height: 40)

            VStack(alignment: .leading, spacing: DesignTokens.Spacing.gapSmall) {
                Text("Display Configuration Changed")
                    .font(brand: .h3)
                    .foregroundStyle(DesignTokens.Text.primary)

                Text(mismatchDescription)
                    .font(brand: .body3)
                    .foregroundStyle(DesignTokens.Text.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var arrangementSection: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.gapSmall) {
            Text("Display arrangement")
                .font(brand: .label3)
                .foregroundStyle(DesignTokens.Text.secondary)

            Text("Connected displays stay where macOS has arranged them. Use each display’s assignment menu to choose which saved workspace layout restores there.")
                .font(brand: .body4)
                .foregroundStyle(DesignTokens.Text.tertiary)

            DSDisplayArrangementCanvas(
                items: arrangementItems,
                preferredHeight: 280,
                onTap: handleArrangementTap(itemID:)
            )

            arrangementInspector
        }
    }

    private var savedLayoutsSection: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.gapMedium) {
            Text("Assign layouts to monitors")
                .font(brand: .label3)
                .foregroundStyle(DesignTokens.Text.secondary)

            Text(optionsInstructionText)
                .font(brand: .body4)
                .foregroundStyle(DesignTokens.Text.tertiary)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: DesignTokens.Spacing.gapMedium) {
                    if let presentedCurrentScreenIndex,
                       analysis.currentScreens.indices.contains(presentedCurrentScreenIndex) {
                        unassignedOptionCard(currentIndex: presentedCurrentScreenIndex)

                        ForEach(analysis.savedScreens.indices, id: \.self) { savedIndex in
                            savedLayoutOptionCard(
                                savedIndex: savedIndex,
                                screen: analysis.savedScreens[savedIndex],
                                currentIndex: presentedCurrentScreenIndex
                            )
                        }
                    } else {
                        ForEach(displayIndicesToRender, id: \.self) { currentIndex in
                            monitorAssignmentCard(currentIndex: currentIndex)
                        }
                    }
                }
            }
        }
    }

    private var optionsInstructionText: String {
        if presentedCurrentScreenIndex != nil {
            return "Click a saved layout to assign it to this monitor. Choosing a layout that is already in use will move the displaced monitor to this monitor's previous layout when possible."
        }

        return "Click a monitor to cycle through saved layouts. Each layout can only be assigned to one monitor."
    }

    private var displayIndicesToRender: [Int] {
        if let presentedCurrentScreenIndex,
           analysis.currentScreens.indices.contains(presentedCurrentScreenIndex) {
            return [presentedCurrentScreenIndex]
        }

        return Array(analysis.currentScreens.indices)
    }

    private func assignedLayoutIndex(forMonitor currentIndex: Int) -> Int? {
        selectionState.assignedLayoutIndex(forMonitor: currentIndex)
    }

    private func monitorAssignmentCard(currentIndex: Int) -> some View {
        let screen = analysis.currentScreens[currentIndex]

        return VStack(alignment: .leading, spacing: DesignTokens.Spacing.gapSmall) {
            monitorCardContent(currentIndex: currentIndex)

            HStack(spacing: 4) {
                Text(screen.name)
                    .font(brand: .body4)
                    .foregroundStyle(DesignTokens.Text.tertiary)
                    .lineLimit(1)

                if screen.isPrimary {
                    DSTag(label: "Primary", color: DesignTokens.Status.info, size: .small)
                }
            }
        }
        .padding(DesignTokens.Card.padding)
        .frame(width: 280, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: DesignTokens.Card.cornerRadius)
                .fill(monitorHasLayout(currentIndex) ? DesignTokens.Surface.card : DesignTokens.Surface.card.opacity(0.5))
        }
        .overlay {
            RoundedRectangle(cornerRadius: DesignTokens.Card.cornerRadius)
                .stroke(
                    monitorHasLayout(currentIndex) ? DesignTokens.Brand.accent : DesignTokens.Border.subtle,
                    style: StrokeStyle(
                        lineWidth: monitorHasLayout(currentIndex) ? 2 : 1,
                        dash: monitorHasLayout(currentIndex) ? [] : [8, 5]
                    )
                )
        }
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(.easeInOut(duration: 0.15)) {
                cycleLayout(forMonitor: currentIndex)
            }
        }
    }

    private func monitorHasLayout(_ currentIndex: Int) -> Bool {
        let assigned = assignedLayoutIndex(forMonitor: currentIndex)
        DeskJigLog.info(.app, "[ScreenSelection] hasLayout(\(currentIndex))=\(assigned != nil) assigned=\(String(describing: assigned)) maps=\(selectionState.selectedMappings.map { "s\($0.savedIndex)->c\(String(describing: $0.currentIndex))" })")
        return assigned != nil
    }

    private func unassignedOptionCard(currentIndex: Int) -> some View {
        let screen = analysis.currentScreens[currentIndex]
        let isSelected = assignedSavedScreenIndex(for: currentIndex) == nil

        return Button {
            clearAssignment(forCurrentScreen: currentIndex)
        } label: {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.gapSmall) {
                RoundedRectangle(cornerRadius: DesignTokens.CornerRadius.medium)
                    .fill(DesignTokens.Surface.elevated.opacity(0.3))
                    .frame(height: 118)
                    .overlay {
                        Text("No layout assigned")
                            .font(brand: .body4)
                            .foregroundStyle(DesignTokens.Text.muted)
                    }

                Text("No layout")
                    .font(brand: .label3)
                    .foregroundStyle(DesignTokens.Text.primary)

                Text("Leave \(screen.name) unused")
                    .font(brand: .body4)
                    .foregroundStyle(DesignTokens.Text.tertiary)
            }
            .padding(DesignTokens.Card.padding)
            .frame(width: 280, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: DesignTokens.Card.cornerRadius)
                    .fill(isSelected ? DesignTokens.Surface.accentMuted : DesignTokens.Surface.card)
            }
            .overlay {
                RoundedRectangle(cornerRadius: DesignTokens.Card.cornerRadius)
                    .stroke(
                        isSelected ? DesignTokens.Brand.accent : DesignTokens.Border.subtle,
                        lineWidth: isSelected ? 2 : 1
                    )
            }
        }
        .buttonStyle(.plain)
    }

    private func savedLayoutOptionCard(
        savedIndex: Int,
        screen: WorkspaceScreen,
        currentIndex: Int
    ) -> some View {
        let windowsOnScreen = workspace.windows.filter { $0.screenIndex == savedIndex }
        let remappedWindows = windowsOnScreen.map { $0.withScreenMapping(screenIndex: 0) }
        let assignedMonitorIndex = mappingForSavedScreen(savedIndex)?.currentIndex
        let isSelected = assignedMonitorIndex == currentIndex

        return Button {
            assignSavedScreen(savedIndex, toCurrentScreen: currentIndex)
        } label: {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.gapSmall) {
                WorkspaceLayoutPreview(
                    windows: remappedWindows,
                    screens: [screen],
                    height: 118,
                    showLabels: false,
                    showBackground: false,
                    iconProvider: { window in
                        applicationManager.findApplication(by: window.bundleIdentifier)?.icon
                    }
                )
                .frame(maxWidth: .infinity, alignment: .leading)

                Text("Layout \(savedIndex + 1)")
                    .font(brand: .label3)
                    .foregroundStyle(DesignTokens.Text.primary)

                Text(layoutOptionStatusText(savedIndex: savedIndex, currentIndex: currentIndex))
                    .font(brand: .body4)
                    .foregroundStyle(isSelected ? DesignTokens.Brand.accent : DesignTokens.Text.tertiary)
            }
            .padding(DesignTokens.Card.padding)
            .frame(width: 280, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: DesignTokens.Card.cornerRadius)
                    .fill(isSelected ? DesignTokens.Surface.accentMuted : DesignTokens.Surface.card)
            }
            .overlay {
                RoundedRectangle(cornerRadius: DesignTokens.Card.cornerRadius)
                    .stroke(
                        isSelected ? DesignTokens.Brand.accent : DesignTokens.Border.subtle,
                        lineWidth: isSelected ? 2 : 1
                    )
            }
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func monitorCardContent(currentIndex: Int) -> some View {
        if let savedIndex = assignedLayoutIndex(forMonitor: currentIndex),
           analysis.savedScreens.indices.contains(savedIndex) {
            let savedScreen = analysis.savedScreens[savedIndex]
            let windowsOnScreen = workspace.windows.filter { $0.screenIndex == savedIndex }
            let remappedWindows = windowsOnScreen.map { $0.withScreenMapping(screenIndex: 0) }

            WorkspaceLayoutPreview(
                windows: remappedWindows,
                screens: [savedScreen],
                height: 118,
                showLabels: false,
                showBackground: false,
                iconProvider: { window in
                    applicationManager.findApplication(by: window.bundleIdentifier)?.icon
                }
            )
            .frame(maxWidth: .infinity, alignment: .leading)

            Text("Layout \(savedIndex + 1)")
                .font(brand: .label3)
                .foregroundStyle(DesignTokens.Text.primary)
        } else {
            RoundedRectangle(cornerRadius: DesignTokens.CornerRadius.medium)
                .fill(DesignTokens.Surface.elevated.opacity(0.3))
                .frame(height: 118)
                .overlay {
                    Text("No layout assigned")
                        .font(brand: .body4)
                        .foregroundStyle(DesignTokens.Text.muted)
                }

            Text("Unassigned")
                .font(brand: .label3)
                .foregroundStyle(DesignTokens.Text.muted)
        }
    }

    private func cycleLayout(forMonitor currentIndex: Int) {
        selectionState.cycleLayout(
            forMonitor: currentIndex,
            savedScreenCount: analysis.savedScreens.count,
            currentScreenCount: analysis.currentScreens.count
        )
    }

    private var actionButtons: some View {
        HStack(spacing: DesignTokens.Spacing.gapMedium) {
            Button(action: onCancel) {
                Text("Cancel")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.dsButton(variant: .secondary, size: .large))
            .keyboardShortcut(.cancelAction)

            Button(action: confirmSelection) {
                Text("Restore Selected")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.dsButton(variant: .primary, size: .large))
            .keyboardShortcut(.defaultAction)
            .disabled(!canConfirm)
        }
    }

    private var mismatchDescription: String {
        if analysis.hasFewerScreens {
            return "This workspace was saved with \(analysis.savedScreenCount) display\(analysis.savedScreenCount == 1 ? "" : "s"), but only \(analysis.currentScreenCount) \(analysis.currentScreenCount == 1 ? "is" : "are") currently connected. Choose which saved layouts should restore to the displays you have now."
        }

        if analysis.hasMoreScreens {
            return "You have more displays connected now than when this workspace was saved. Review the assignments and confirm where each saved layout should restore."
        }

        if analysis.hasTopologyChange {
            return "The same number of displays is connected, but the arrangement or confidence of the matches has changed. Review the assignments before restoring."
        }

        return "Review the display assignments before restoring this workspace."
    }

    private var canConfirm: Bool {
        selectionState.selectedMappings.contains(where: { $0.currentIndex != nil })
    }

    private var arrangementInspector: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.gapSmall) {
            Text("Selected display")
                .font(brand: .label3)
                .foregroundStyle(DesignTokens.Text.secondary)

            HStack(alignment: .top, spacing: DesignTokens.Spacing.gapLarge) {
                VStack(alignment: .leading, spacing: 4) {
                    if let selectedArrangementCurrentIndex,
                       analysis.currentScreens.indices.contains(selectedArrangementCurrentIndex) {
                        let currentScreen = analysis.currentScreens[selectedArrangementCurrentIndex]
                        Text(currentScreen.name)
                            .font(brand: .label2)
                            .foregroundStyle(DesignTokens.Text.primary)

                        Text("\(Int(currentScreen.resolution.width)) x \(Int(currentScreen.resolution.height))")
                            .font(brand: .body4)
                            .foregroundStyle(DesignTokens.Text.tertiary)

                        Text(currentScreen.isPrimary ? "Primary connected display" : "Connected display")
                            .font(brand: .body4)
                            .foregroundStyle(DesignTokens.Text.muted)
                    } else {
                        Text("No connected display selected")
                            .font(brand: .label2)
                            .foregroundStyle(DesignTokens.Text.primary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                VStack(alignment: .leading, spacing: 4) {
                    Text("Saved layout")
                        .font(brand: .body4)
                        .foregroundStyle(DesignTokens.Text.tertiary)

                    DSSelect(
                        options: arrangementSelectOptions,
                        selection: arrangementAssignmentBinding,
                        placeholder: "Choose a layout"
                    )
                    .frame(width: 240)

                    Text("Assign a saved workspace layout to the selected connected display. DeskJig will keep the current macOS monitor arrangement.")
                        .font(brand: .body4)
                        .foregroundStyle(DesignTokens.Text.muted)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(width: 240, alignment: .leading)
                }
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: DesignTokens.CornerRadius.large)
                    .fill(DesignTokens.Surface.card)
                    .overlay(
                        RoundedRectangle(cornerRadius: DesignTokens.CornerRadius.large)
                            .stroke(DesignTokens.Border.subtle, lineWidth: 1)
                    )
            )
        }
    }

    private var arrangementSelectOptions: [DSSelectOption<String>] {
        savedLayoutAssignmentOptions.map { option in
            DSSelectOption(id: option.id, label: option.title)
        }
    }

    private var selectedArrangementCurrentIndex: Int? {
        if let selectedCurrentScreenIndex,
           analysis.currentScreens.indices.contains(selectedCurrentScreenIndex) {
            return selectedCurrentScreenIndex
        }

        return analysis.currentScreens.indices.first
    }

    private var arrangementAssignmentBinding: Binding<String?> {
        Binding(
            get: {
                guard let selectedArrangementCurrentIndex else { return nil }
                return assignedSavedScreenIndex(for: selectedArrangementCurrentIndex)
                    .map(savedLayoutAssignmentID(for:)) ?? noneAssignmentID
            },
            set: { optionID in
                guard let selectedArrangementCurrentIndex,
                      let optionID else { return }
                handleArrangementAssignment(
                    itemID: currentDisplayItemID(selectedArrangementCurrentIndex),
                    optionID: optionID
                )
            }
        )
    }

    private var arrangementItems: [DSDisplayArrangementItem] {
        let assignmentOptions = savedLayoutAssignmentOptions

        let liveItems = analysis.currentScreens.indices.map { currentIndex in
            let assignedSavedIndex = assignedSavedScreenIndex(for: currentIndex)
            let currentScreen = analysis.currentScreens[currentIndex]

            return DSDisplayArrangementItem(
                id: currentDisplayItemID(currentIndex),
                frame: currentScreen.frame,
                title: currentScreen.name,
                subtitle: "\(Int(currentScreen.resolution.width)) x \(Int(currentScreen.resolution.height))",
                detail: assignedSavedIndex == nil ? "No saved layout assigned" : "Connected display",
                assignmentTitle: assignedSavedIndex.map { "Saved layout \($0 + 1)" },
                assignmentSubtitle: assignedSavedIndex.map { savedScreenLabel(analysis.savedScreens[$0]) },
                isPrimary: currentScreen.isPrimary,
                isSelected: arrangementItemIsSelected(currentDisplayIndex: currentIndex, assignedSavedIndex: assignedSavedIndex),
                assignmentOptions: assignmentOptions,
                selectedAssignmentID: assignedSavedIndex.map(savedLayoutAssignmentID(for:)) ?? noneAssignmentID
            )
        }

        let ghostItems = analysis.savedScreens.indices
            .filter { mappingForSavedScreen($0)?.currentIndex == nil }
            .map { savedIndex in
                let savedScreen = analysis.savedScreens[savedIndex]
                return DSDisplayArrangementItem(
                    id: savedScreenItemID(savedIndex),
                    frame: savedScreen.frame,
                    title: savedScreen.name,
                    subtitle: "\(Int(savedScreen.resolution.width)) x \(Int(savedScreen.resolution.height))",
                    detail: "Saved layout \(savedIndex + 1)",
                    isPrimary: savedScreen.isPrimary,
                    isGhost: true,
                    isSelected: focusedSavedScreenIndex == savedIndex
                )
            }

        return liveItems + ghostItems
    }

    private var savedLayoutAssignmentOptions: [DSDisplayArrangementAssignmentOption] {
        let layoutOptions = analysis.savedScreens.indices.map { savedIndex in
            DSDisplayArrangementAssignmentOption(
                id: savedLayoutAssignmentID(for: savedIndex),
                title: "Saved layout \(savedIndex + 1)",
                subtitle: savedScreenLabel(analysis.savedScreens[savedIndex])
            )
        }

        return [
            DSDisplayArrangementAssignmentOption(
                id: noneAssignmentID,
                title: "No layout",
                subtitle: "Leave this display unused"
            )
        ] + layoutOptions
    }

    private func mappingForSavedScreen(_ savedIndex: Int) -> ScreenMappingInfo? {
        selectionState.mappingForSavedScreen(savedIndex)
    }

    private func assignedSavedScreenIndex(for currentIndex: Int) -> Int? {
        selectionState.assignedSavedScreenIndex(for: currentIndex)
    }

    private func handleArrangementTap(itemID: String) {
        if itemID.hasPrefix("saved-"),
           let savedIndex = Int(itemID.dropFirst("saved-".count)) {
            focusedSavedScreenIndex = savedIndex
            return
        }

        if itemID.hasPrefix("current-"),
           let currentIndex = Int(itemID.dropFirst("current-".count)) {
            selectedCurrentScreenIndex = currentIndex
            if let savedIndex = assignedSavedScreenIndex(for: currentIndex) {
                focusedSavedScreenIndex = savedIndex
            }
        }
    }

    private func handleArrangementAssignment(itemID: String, optionID: String) {
        guard itemID.hasPrefix("current-"),
              let currentIndex = Int(itemID.dropFirst("current-".count)) else { return }

        if optionID == noneAssignmentID {
            clearAssignment(forCurrentScreen: currentIndex)
            return
        }

        guard optionID.hasPrefix("saved-layout-"),
              let savedIndex = Int(optionID.dropFirst("saved-layout-".count)) else { return }
        assignSavedScreen(savedIndex, toCurrentScreen: currentIndex)
    }

    private func assignSavedScreen(_ savedIndex: Int, toCurrentScreen currentIndex: Int) {
        selectionState.assignSavedScreen(
            savedIndex,
            toCurrentScreen: currentIndex,
            savedScreenCount: analysis.savedScreens.count,
            currentScreenCount: analysis.currentScreens.count
        )
        focusedSavedScreenIndex = savedIndex
        selectedCurrentScreenIndex = currentIndex
    }

    private func clearAssignment(forCurrentScreen currentIndex: Int) {
        let clearedSavedIndex = assignedSavedScreenIndex(for: currentIndex)
        selectionState.clearAssignment(
            forCurrentScreen: currentIndex,
            savedScreenCount: analysis.savedScreens.count,
            currentScreenCount: analysis.currentScreens.count
        )
        focusedSavedScreenIndex = clearedSavedIndex
        selectedCurrentScreenIndex = currentIndex
    }

    private func arrangementItemIsSelected(currentDisplayIndex: Int, assignedSavedIndex: Int?) -> Bool {
        if selectedArrangementCurrentIndex == currentDisplayIndex {
            return true
        }

        if let assignedSavedIndex {
            return focusedSavedScreenIndex == assignedSavedIndex
        }

        return false
    }

    private func layoutOptionStatusText(savedIndex: Int, currentIndex: Int) -> String {
        guard let assignedMonitorIndex = mappingForSavedScreen(savedIndex)?.currentIndex,
              analysis.currentScreens.indices.contains(assignedMonitorIndex) else {
            return "Available"
        }

        if assignedMonitorIndex == currentIndex {
            return "Assigned here"
        }

        return "Assigned to \(analysis.currentScreens[assignedMonitorIndex].name)"
    }

    private func confirmSelection() {
        let finalMappings = selectionState.selectedMappings
            .filter { $0.currentIndex != nil }
            .sorted { $0.savedIndex < $1.savedIndex }
        onConfirm(finalMappings)
    }

    private func currentDisplayItemID(_ currentIndex: Int) -> String {
        "current-\(currentIndex)"
    }

    private func savedScreenItemID(_ savedIndex: Int) -> String {
        "saved-\(savedIndex)"
    }

    private func savedLayoutAssignmentID(for savedIndex: Int) -> String {
        "saved-layout-\(savedIndex)"
    }

    private func savedScreenLabel(_ screen: WorkspaceScreen) -> String {
        "\(screen.name) · \(Int(screen.resolution.width)) x \(Int(screen.resolution.height))"
    }
}

extension Notification.Name {
    static let inlineScreenSelectionMoveLeft = Notification.Name("InlineScreenSelectionMoveLeft")
    static let inlineScreenSelectionMoveRight = Notification.Name("InlineScreenSelectionMoveRight")
    static let inlineScreenSelectionConfirm = Notification.Name("InlineScreenSelectionConfirm")
}
