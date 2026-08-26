//  DeskJigContentView.swift
//  DeskJig

import SwiftUI
import DeskJigShared
import Combine

/// Main content view with vertical sidebar navigation layout.
struct DeskJigContentView: View {

    // MARK: - Data
    @EnvironmentObject var appUpdateController: SparkleController
    @Environment(WorkspaceViewModel.self) private var workspaceVM
    @Bindable var simpleOnboardingVM: SimpleOnboardingViewModel
    @Bindable var tutorialVM: OnboardingTutorialViewModel

    // MARK: - UI State
    #if DEBUG
    private static let defaultSection: SettingsSidebarSection = .designSystem
    #else
    private static let defaultSection: SettingsSidebarSection = .allWorkspaces
    #endif
    @AppStorage("settings.selectedSection") private var selectedSectionRaw: String = defaultSection.rawValue
    @State private var searchText: String = ""
    @FocusState private var isSearchFocused: Bool
    @FocusState private var isListFocused: Bool
    /// Keyboard selection in the workspace list, tracked by row identity.
    /// nil = search box focused (no row selected).
    @State private var selectedItem: WorkspaceListItemID? = nil
    /// Signal to expand the inline creator row (set from Return key)
    @State private var expandInlineCreator: Bool = false
    /// Whether inline creator is expanded (used to avoid search hijack)
    @State private var inlineCreatorIsOpen: Bool = false
    @State private var autoEditWorkspaceId: UUID? = nil
    @State private var pendingCreateSeed: WorkspaceViewModel.SettingsWorkspaceCreateSeed? = nil
    @State private var editorPathFieldFocused: Bool = false
    @State private var quickSwitchVM = QuickSwitchViewModel()
    @State private var isEditingWorkspace: Bool = false
    @StateObject private var confirmationManager = DSConfirmationManager()

    /// Publisher for externally navigating to a section (e.g., from ActionPanel)
    static let sectionPublisher = PassthroughSubject<SettingsSidebarSection, Never>()

    // MARK: - Computed Properties for Navigation

    /// Whether inline creator row should be shown (only in all mode when not searching)
    private var selectedSection: SettingsSidebarSection {
        SettingsSidebarSection(rawValue: selectedSectionRaw) ?? Self.defaultSection
    }

    private var isOnboardingGateActive: Bool {
        !simpleOnboardingVM.isCompleted
    }

    private var effectiveSelectedSection: SettingsSidebarSection {
        isOnboardingGateActive ? .tutorials : selectedSection
    }

    private var selectedSectionBinding: Binding<SettingsSidebarSection> {
        Binding(
            get: { effectiveSelectedSection },
            set: { newSection in
                guard !isOnboardingGateActive else {
                    selectedSectionRaw = SettingsSidebarSection.tutorials.rawValue
                    return
                }
                selectedSectionRaw = newSection.rawValue
            }
        )
    }

    private var showInlineCreatorRow: Bool {
        effectiveSelectedSection == .allWorkspaces && searchText.isEmpty
    }

    private var shouldShowTopBar: Bool {
        effectiveSelectedSection != .quickSwitch
    }

    /// Filtered workspaces based on search text and selected section (mirrors WorkspacesListView logic)
    private var filteredWorkspaces: [WorkspaceWithApps] {
        let baseWorkspaces = effectiveSelectedSection == .favorites ? workspaceVM.favoriteWorkspaces : workspaceVM.workspaces
        if searchText.isEmpty {
            return baseWorkspaces
        }
        return baseWorkspaces.filter {
            $0.workspace.name.localizedCaseInsensitiveContains(searchText)
        }
    }

    /// Visible rows in display order — the single source of truth keyboard
    /// navigation moves through.
    private var visibleListItems: [WorkspaceListItemID] {
        WorkspaceListNavigator.items(
            showCreator: showInlineCreatorRow,
            workspaceIds: filteredWorkspaces.map { $0.workspace.id }
        )
    }

    // MARK: - Navigation Functions

    /// Navigate down in the workspace list (supports key repeat)
    private func navigateDown() {
        guard effectiveSelectedSection.isWorkspaceSection else { return }
        // The expanded creator owns the content area (#597); the card list is
        // hidden, so there is nothing below the creator to navigate to.
        guard !inlineCreatorIsOpen else { return }
        selectedItem = WorkspaceListNavigator.next(after: selectedItem, in: visibleListItems)
    }

    /// Navigate up in the workspace list (supports key repeat)
    private func navigateUp() {
        guard effectiveSelectedSection.isWorkspaceSection else { return }
        guard !inlineCreatorIsOpen else { return }
        selectedItem = WorkspaceListNavigator.previous(before: selectedItem, in: visibleListItems)
    }

    /// Handle Return key press - open selected workspace or expand inline creator
    private func handleReturn() {
        guard effectiveSelectedSection.isWorkspaceSection else { return }
        // While the creator is expanded the card list is hidden (#597); don't
        // open a workspace the user can't see.
        guard !inlineCreatorIsOpen else { return }

        switch selectedItem {
        case .creator:
            expandInlineCreator = true
        case .workspace(let id):
            guard let item = filteredWorkspaces.first(where: { $0.workspace.id == id }) else { return }
            openWorkspaceFromList(item.workspace)
        case nil:
            break
        }
    }

    /// Opens by workspace identity — never by name or position — so Return
    /// always launches exactly the highlighted row (#51).
    private func openWorkspaceFromList(_ workspace: Workspace) {
        workspaceVM.openWorkspace(
            workspace,
            source: WorkspaceViewModel.settingsEnterLaunchSource,
            launchDisplayName: workspace.name
        )
    }

    private func routeToWorkspaceSearchIfNeeded(for query: String) {
        guard !isOnboardingGateActive else { return }
        guard effectiveSelectedSection != .settings else { return }
        guard !effectiveSelectedSection.isWorkspaceSection else { return }
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        withAnimation(.smooth(duration: 0.25)) {
            selectedSectionRaw = SettingsSidebarSection.allWorkspaces.rawValue
        }
    }

    private func enforceOnboardingGateIfNeeded() {
        guard isOnboardingGateActive else { return }
        DeskJigLog.info(.app, "Enforcing onboarding gate in Tutorials section")
        if selectedSectionRaw != SettingsSidebarSection.tutorials.rawValue {
            selectedSectionRaw = SettingsSidebarSection.tutorials.rawValue
        }
        simpleOnboardingVM.presentIfIncomplete()
    }

    private func reloadQuickSwitchState() {
        quickSwitchVM.reloadForCurrentUserContext(
            scanImmediately: effectiveSelectedSection == .quickSwitch
        )
    }

    var body: some View {
        ZStack {
            HStack(spacing: 0) {
                // Sidebar
                GlassSidebarBackground {
                    SettingsSidebar(
                        selectedSection: selectedSectionBinding,
                        isNavigationLocked: isOnboardingGateActive
                    )
                }
                .frame(width: DesignTokens.Spacing.sidebarWidth)
                .frame(maxHeight: .infinity)
                .ignoresSafeArea(edges: .top)

                // Main content area
                VStack(spacing: 0) {
                    // Top bar with search (for workspace and settings sections)
                    if shouldShowTopBar {
                        topBar
                            .padding(.horizontal, DesignTokens.Spacing.contentPaddingRegular)
                            .padding(.top, -DesignTokens.Spacing.contentPaddingSmall)
                            .padding(.bottom, DesignTokens.Spacing.gapRegular)
                            .frame(maxWidth: .infinity)
                            .background(
                                GlassTopBarBackground()
                                    .ignoresSafeArea(edges: .top)
                            )
                            .contentShape(Rectangle())
                            .background(Color.black.opacity(0.001))

                        Divider()
                            .background(DesignTokens.Border.subtle)
                    }

                    // Content area
                    ZStack {
                        DesignTokens.Surface.window

                        if effectiveSelectedSection == .quickSwitch {
                            contentForSection
                                .padding(.horizontal, DesignTokens.Spacing.contentPaddingLarge)
                                .padding(.top, DesignTokens.Spacing.contentPaddingRegular)
                                .padding(.bottom, DesignTokens.Spacing.contentPaddingLarge)
                                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        } else if effectiveSelectedSection == .tutorials {
                            contentForSection
                                .padding(.horizontal, DesignTokens.Spacing.contentPaddingLarge)
                                .padding(.vertical, DesignTokens.Spacing.gapSmall)
                                .frame(
                                    maxWidth: .infinity,
                                    maxHeight: .infinity,
                                    alignment: .topLeading
                                )
                        } else {
                            // Fill-or-scroll (#597): workspace sections are stretched
                            // to at least the viewport height so the creator/editor
                            // can flex to consume it (no outer scrollbar when the
                            // content fits); other sections keep intrinsic sizing.
                            GeometryReader { geometry in
                                ScrollViewReader { scrollProxy in
                                    ScrollView {
                                        contentForSection
                                            .padding(.horizontal, DesignTokens.Spacing.contentPaddingLarge)
                                            .padding(.top, DesignTokens.Spacing.contentPaddingRegular)
                                            .padding(.bottom, DesignTokens.Spacing.contentPaddingLarge)
                                            .frame(maxWidth: .infinity, alignment: .topLeading)
                                            .frame(
                                                minHeight: effectiveSelectedSection.isWorkspaceSection
                                                    ? geometry.size.height
                                                    : nil,
                                                alignment: .topLeading
                                            )
                                    }
                                    .scrollBounceBehavior(.basedOnSize)
                                    // Scroll to selected item when selection changes
                                    .onChange(of: selectedItem) { _, newItem in
                                        guard let item = newItem else { return }
                                        withAnimation(.smooth(duration: 0.2)) {
                                            scrollProxy.scrollTo(item.scrollAnchorID, anchor: .center)
                                        }
                                    }
                                    // Ensure editor header is visible when entering edit mode.
                                    .onChange(of: isEditingWorkspace) { _, editing in
                                        guard editing else { return }
                                        withAnimation(.smooth(duration: 0.2)) {
                                            scrollProxy.scrollTo("workspace-editor-root", anchor: .top)
                                        }
                                    }
                                }
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .padding(.top, 0)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .focusable()
                .focusEffectDisabled()
            }
        }
        .overlay {
            DSConfirmationOverlayHost()
                .environmentObject(confirmationManager)
        }
        .environmentObject(confirmationManager)
        .onAppear {
            reloadQuickSwitchState()
            if effectiveSelectedSection == .settings {
                appUpdateController.probeForUpdates(trigger: .settingsOpened)
            }

            enforceOnboardingGateIfNeeded()

            // Auto-focus search bar when settings opens
            if effectiveSelectedSection.isWorkspaceSection {
                isSearchFocused = true
            } else if effectiveSelectedSection == .quickSwitch {
                isSearchFocused = false
            }
        }
        .onChange(of: simpleOnboardingVM.isCompleted) { _, isCompleted in
            if isCompleted {
                return
            } else {
                enforceOnboardingGateIfNeeded()
            }
        }
        .onChange(of: simpleOnboardingVM.isPresented) { _, isPresented in
            guard isOnboardingGateActive, !isPresented else { return }
            enforceOnboardingGateIfNeeded()
        }
        .onChange(of: selectedSectionRaw) { _, _ in
            if isOnboardingGateActive {
                enforceOnboardingGateIfNeeded()
                selectedItem = nil
                return
            }
            let newSection = effectiveSelectedSection
            if newSection == .settings {
                appUpdateController.probeForUpdates(trigger: .settingsOpened)
            }
            // Focus search when switching to workspace section
            if newSection.isWorkspaceSection {
                isSearchFocused = true
                selectedItem = nil
            } else if newSection == .quickSwitch {
                // Quick Switch owns its own in-section search field.
                isSearchFocused = false
                selectedItem = nil
            } else {
                selectedItem = nil
            }
        }
        .onChange(of: searchText) { _, newValue in
            routeToWorkspaceSearchIfNeeded(for: newValue)
        }
        .onReceive(Self.sectionPublisher) { newSection in
            guard !isOnboardingGateActive else {
                enforceOnboardingGateIfNeeded()
                return
            }
            // Settings contains a large control surface; switching without animation
            // avoids expensive blur-transition work during the initial open path.
            if newSection == .settings {
                selectedSectionRaw = newSection.rawValue
            } else {
                withAnimation(.smooth(duration: 0.25)) {
                    selectedSectionRaw = newSection.rawValue
                }
            }
        }
        // Global arrow key navigation - fallback when search bar isn't focused (with key repeat)
        .onKeyPress(.downArrow, phases: [.down, .repeat]) { _ in
            guard effectiveSelectedSection.isWorkspaceSection else { return .ignored }
            // Let search bar handle it when focused
            guard !isSearchFocused else { return .ignored }
            navigateDown()
            return .handled
        }
        .onKeyPress(.upArrow, phases: [.down, .repeat]) { _ in
            guard effectiveSelectedSection.isWorkspaceSection else { return .ignored }
            // Let search bar handle it when focused
            guard !isSearchFocused else { return .ignored }
            navigateUp()
            return .handled
        }
        // Return opens the selected row — one handler for search-focused
        // (via WorkspaceSearchBar.onReturn) and list-focused states (#51)
        .onKeyPress(.return) {
            guard effectiveSelectedSection.isWorkspaceSection else { return .ignored }
            guard !isSearchFocused else { return .ignored }
            guard !inlineCreatorIsOpen, !isEditingWorkspace else { return .ignored }
            guard selectedItem != nil else { return .ignored }
            handleReturn()
            return .handled
        }
        // Auto-focus search when typing characters (all sections except settings)
        .onKeyPress(characters: .alphanumerics.union(.punctuationCharacters).union(.symbols)) { keyPress in
            guard !isOnboardingGateActive else { return .ignored }
            guard effectiveSelectedSection != .settings else { return .ignored }
            guard effectiveSelectedSection != .quickSwitch else { return .ignored }
            guard !inlineCreatorIsOpen else { return .ignored }
            guard !editorPathFieldFocused else { return .ignored }
            guard !isEditingWorkspace else { return .ignored }
            // Focus the search and append the typed character
            if !isSearchFocused {
                isSearchFocused = true
                searchText += keyPress.characters
                return .handled
            }
            return .ignored
        }
    }

    // MARK: - Top Bar

    private var topBar: some View {
        HStack {
            WorkspaceSearchBar(
                searchText: $searchText,
                isFocused: $isSearchFocused,
                placeholder: effectiveSelectedSection == .settings ? "Search settings..." : "Search workspaces...",
                onDownArrow: effectiveSelectedSection.isWorkspaceSection ? { navigateDown() } : nil,
                onUpArrow: effectiveSelectedSection.isWorkspaceSection ? { navigateUp() } : nil,
                onReturn: effectiveSelectedSection.isWorkspaceSection ? { handleReturn() } : nil
            )

            Spacer()

            // Update badge (only show on workspace sections)
            if appUpdateController.shouldShowUpdateBadge && effectiveSelectedSection.isWorkspaceSection {
                UpdateBadge {
                    appUpdateController.checkForUpdates()
                }
            }
        }
    }



    // MARK: - Content Routing

    @ViewBuilder
    private var contentForSection: some View {
        switch effectiveSelectedSection {
        case .allWorkspaces:
            // Show workspaces list with search filtering
            WorkspacesListView(
                searchText: $searchText,
                isSearchFocused: $isSearchFocused,
                editorPathFieldFocused: $editorPathFieldFocused,
                isEditingWorkspace: $isEditingWorkspace,
                isListFocused: $isListFocused,
                selectedItem: $selectedItem,
                expandInlineCreator: $expandInlineCreator,
                inlineCreatorIsOpen: $inlineCreatorIsOpen,
                autoEditWorkspaceId: $autoEditWorkspaceId,
                pendingCreateSeed: $pendingCreateSeed
            )
            .transition(.blurTransition(blurRadius: 4, scale: 0.98).animation(.smoothDefault))
        case .favorites:
            WorkspacesListView(
                filterMode: .favorites,
                searchText: $searchText,
                isSearchFocused: $isSearchFocused,
                editorPathFieldFocused: $editorPathFieldFocused,
                isEditingWorkspace: $isEditingWorkspace,
                isListFocused: $isListFocused,
                selectedItem: $selectedItem,
                expandInlineCreator: $expandInlineCreator,
                inlineCreatorIsOpen: $inlineCreatorIsOpen,
                autoEditWorkspaceId: $autoEditWorkspaceId,
                pendingCreateSeed: $pendingCreateSeed
            )
            .transition(.blurTransition(blurRadius: 4, scale: 0.98).animation(.smoothDefault))
        case .quickSwitch:
            QuickSwitchView(
                viewModel: quickSwitchVM,
                isActive: effectiveSelectedSection == .quickSwitch
            )
                .transition(.blurTransition(blurRadius: 4, scale: 0.98).animation(.smoothDefault))
        case .tutorials:
            TutorialsSection(simpleOnboardingVM: simpleOnboardingVM, tutorialVM: tutorialVM)
                .transition(.blurTransition(blurRadius: 4, scale: 0.98).animation(.smoothDefault))
        case .settings:
            SettingsSectionView(searchText: $searchText)
                .transition(.identity)
        case .helpFeedback:
            HelpSection()
                .transition(.blurTransition(blurRadius: 4, scale: 0.98).animation(.smoothDefault))
#if DEBUG
        case .designSystem:
            DesignSystemSectionView()
                .transition(.blurTransition(blurRadius: 4, scale: 0.98).animation(.smoothDefault))
#endif
        }
    }

    // MARK: - Section Views

    struct TutorialsSection: View {
        let simpleOnboardingVM: SimpleOnboardingViewModel
        @Bindable var tutorialVM: OnboardingTutorialViewModel

        var body: some View {
            VStack(alignment: .leading, spacing: 16) {
                if simpleOnboardingVM.isPresented {
                    SimpleOnboardingOverlay(
                        viewModel: simpleOnboardingVM,
                        currentStage: simpleOnboardingVM.currentStage,
                        isEmbeddedInMainContent: true
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                } else if tutorialVM.isPresented, let activeStage = tutorialVM.activeStage {
                    OnboardingTutorialOverlay(
                        viewModel: tutorialVM,
                        activeStage: activeStage,
                        isEmbeddedInMainContent: true
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                } else {
                    VStack(alignment: .leading, spacing: 16) {
                        TutorialButton(
                            systemImage: "star.circle.fill",
                            title: "Intro to DeskJig",
                            description: "Get started with DeskJig's core features",
                            action: { simpleOnboardingVM.startOnboarding() }
                        )

                        TutorialButton(
                            systemImage: "play.circle.fill",
                            title: "Using Hotkeys",
                            description: "Master keyboard shortcuts for window management",
                            action: { tutorialVM.startTutorial(stage: .launchHotkey) }
                        )
                    }
                    .padding(.top, DesignTokens.Spacing.contentPaddingRegular)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }

        struct TutorialButton: View {
            let systemImage: String
            let title: String
            let description: String
            let action: () -> Void
            @State private var isHovering: Bool = false

            var body: some View {
                Button(action: action) {
                    HStack(spacing: DesignTokens.Spacing.gapMedium) {
                        Image(systemName: systemImage)
                            .font(.system(size: DesignTokens.IconSize.xxLarge))
                            .foregroundStyle(DesignTokens.Text.primary)

                        VStack(alignment: .leading, spacing: DesignTokens.Spacing.gapTiny) {
                            Text(title)
                                .font(brand: .h4)
                                .foregroundStyle(DesignTokens.Text.primary)

                            Text(description)
                                .font(brand: .body3)
                                .foregroundStyle(DesignTokens.Text.secondary)
                        }

                        Spacer()

                        Image(systemName: "chevron.right")
                            .font(.system(size: DesignTokens.IconSize.medium, weight: .semibold))
                            .foregroundStyle(DesignTokens.Text.tertiary)
                    }
                    .padding(DesignTokens.Spacing.cardPaddingSmall)
                    .frame(maxWidth: 600, alignment: .leading)
                    .dsCard(isHighlighted: isHovering)
                    .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Card.cornerRadius))
                }
                .buttonStyle(.plain)
                .onHover { isHovering = $0 }
                .animation(.smooth(duration: 0.20), value: isHovering)
            }
        }
    }

    struct SettingsSectionView: View {
        @Binding var searchText: String

        var body: some View {
            SettingsScreen(searchQuery: $searchText)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    struct HelpSection: View {
        var body: some View {
            HelpFeedbackSection()
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }
}

#Preview {
    DeskJigContentView(
        simpleOnboardingVM: SimpleOnboardingViewModel(),
        tutorialVM: OnboardingTutorialViewModel()
    )
    .frame(width: 1200, height: 800)
    .environmentObject(WindowManager())
}
