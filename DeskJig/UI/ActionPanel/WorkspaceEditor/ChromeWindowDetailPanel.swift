//  ChromeWindowDetailPanel.swift
//  DeskJig
//
//  Chrome window detail panel for editing tabs and profiles
//

import SwiftUI
import DeskJigShared

struct ChromeWindowDetailPanel: View {
    let window: WorkspaceWindow
    let chromeProfileManager: ChromeProfileManager
    let initialModification: ChromeWindowModification?
    let isNewWorkspace: Bool
    let useSavedTabsFallback: Bool
    let onModificationChanged: (ChromeWindowModification) -> Void
    let onDismiss: () -> Void
    
    enum Tab: String, CaseIterable {
        case tabs = "Browser Tabs"
        case profiles = "Profiles"
    }
    
    @State private var selectedTab: Tab = .tabs
    @State private var profiles: [ChromeProfile] = []
    @State private var liveTabURLs: [String] = []
    @State private var selectedProfileDirectory: String? = nil
    @State private var selectedProfileDisplayName: String? = nil
    @State private var selectedProfileHostedDomain: String? = nil
    @State private var selectedProfileUserName: String? = nil
    @State private var isLoadingTabs: Bool = false

    /// Marker value indicating user explicitly chose "Any Chrome Window" (no profile restriction)
    private static let anyProfileMarker = "__ANY_CHROME_WINDOW__"

    /// Returns true if user selected "Any Chrome Window" option
    private var isAnyWindowSelected: Bool {
        selectedProfileDirectory == Self.anyProfileMarker
    }

    private var currentProfileDirectory: String? {
        if isAnyWindowSelected { return nil }
        return selectedProfileDirectory ?? window.chromeState?.profileDirectory
    }

    private var currentProfileDisplayName: String? {
        if isAnyWindowSelected { return nil }
        return selectedProfileDisplayName ?? window.chromeState?.profileDisplayName
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Header
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text("Chrome Window")
                            .font(brand: .h4)
                            .foregroundStyle(DesignTokens.Text.primary)
                        
                        if isLoadingTabs {
                            ProgressView()
                                .scaleEffect(0.6)
                                .tint(.white.opacity(0.6))
                        }
                    }
                    
                    if let profileName = currentProfileDisplayName {
                        Text("Profile: \(profileName)")
                            .font(brand: .label3)
                            .foregroundStyle(DesignTokens.Text.primary.opacity(0.6))
                    }
                    
                    Text(window.windowTitle)
                        .font(brand: Font.brandBody(size: 10))
                        .foregroundStyle(DesignTokens.Text.primary.opacity(0.4))
                        .lineLimit(1)
                }
                
                Spacer()
                
                Button(action: onDismiss) {
                    Image(systemName: "xmark.circle.fill")
                        .font(brand: Font.brandBody(size: 20))
                        .foregroundStyle(DesignTokens.Text.primary.opacity(0.6))
                        .brightenOnHover()
                }
                .buttonStyle(.plain)
            }
            
            // Segmented Control
            HStack(spacing: 0) {
                ForEach(Tab.allCases, id: \.self) { tab in
                    Button(action: {
                        withAnimation(.spring(duration: 0.2)) {
                            selectedTab = tab
                        }
                    }) {
                        Text(tab.rawValue)
                            .font(brand: .label2)
                            .foregroundStyle(selectedTab == tab ? DesignTokens.Text.primary : DesignTokens.Text.tertiary)
                            .padding(.vertical, 8)
                            .padding(.horizontal, 16)
                            .background {
                                if selectedTab == tab {
                                    Capsule()
                                        .fill(DesignTokens.Brand.accentMuted)
                                }
                            }
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(4)
            .background {
                Capsule()
                    .fill(DesignTokens.Surface.elevated)
            }
            
            // Content based on selected tab
            Group {
                switch selectedTab {
                case .tabs:
                    tabsListView
                case .profiles:
                    profilesListView
                }
            }
            .frame(maxHeight: 200)
        }
        .padding(16)
        .background {
            RoundedRectangle(cornerRadius: DesignTokens.Card.cornerRadius)
                .fill(DesignTokens.Surface.card)
                .overlay(
                    RoundedRectangle(cornerRadius: DesignTokens.Card.cornerRadius)
                        .stroke(DesignTokens.Border.regular, lineWidth: 1)
                )
        }
        .onAppear {
            // Initialize from previous modification if available
            if let initial = initialModification {
                liveTabURLs = initial.tabURLs
                if initial.profileMatchMode == .anyWindow {
                    selectedProfileDirectory = Self.anyProfileMarker
                    selectedProfileDisplayName = nil
                    selectedProfileHostedDomain = nil
                    selectedProfileUserName = nil
                } else {
                    selectedProfileDirectory = initial.profileDirectory
                    selectedProfileDisplayName = initial.profileDisplayName
                    selectedProfileHostedDomain = initial.profileHostedDomain
                    selectedProfileUserName = initial.profileUserName
                }
                isLoadingTabs = false
                DeskJigLog.info(.chrome, "ChromeWindowDetailPanel: Restored from previous modification", fields: ["tabs": initial.tabURLs.count, "profile": initial.profileDisplayName ?? "none"])
            } else if let chromeState = window.chromeState {
                // Pre-select profile regardless of new/edit mode
                if chromeState.profileMatchMode == .anyWindow {
                    selectedProfileDirectory = Self.anyProfileMarker
                    selectedProfileDisplayName = nil
                    selectedProfileHostedDomain = nil
                    selectedProfileUserName = nil
                } else {
                    selectedProfileDirectory = chromeState.profileDirectory
                    selectedProfileDisplayName = chromeState.profileDisplayName
                    selectedProfileHostedDomain = chromeState.profileHostedDomain
                    selectedProfileUserName = chromeState.profileUserName
                }

                // Only load saved tabs for existing workspaces (not new ones)
                if useSavedTabsFallback {
                    liveTabURLs = chromeState.savedTabURLs
                    DeskJigLog.info(.chrome, "ChromeWindowDetailPanel: Initialized from saved chrome state", fields: ["tabs": chromeState.savedTabURLs.count, "profile": chromeState.profileDisplayName])
                } else {
                    liveTabURLs = []
                    DeskJigLog.info(.chrome, "ChromeWindowDetailPanel: Pre-selected profile for new workspace", fields: ["profile": chromeState.profileDisplayName])
                }
            } else {
                liveTabURLs = []
            }

            refreshProfilesFromMachine()
        }
        .onChange(of: liveTabURLs) { oldValue, newValue in
            DeskJigLog.info(.chrome, "ChromeWindowDetailPanel: liveTabURLs changed", fields: ["oldCount": oldValue.count, "newCount": newValue.count])
            if oldValue != newValue {
                for (index, url) in newValue.enumerated() {
                    let oldURL = index < oldValue.count ? oldValue[index] : "<new>"
                    if oldURL != url {
                        DeskJigLog.info(.chrome, "Tab changed", fields: ["index": "\(index)", "from": oldURL, "to": url])
                    }
                }
            }
            notifyModificationChanged()
        }
        .onChange(of: selectedProfileDirectory) { oldValue, newValue in
            DeskJigLog.info(.chrome, "ChromeWindowDetailPanel: selectedProfileDirectory changed", fields: ["from": oldValue ?? "nil", "to": newValue ?? "nil"])
            notifyModificationChanged()
        }
        .onChange(of: selectedTab) { _, newValue in
            if newValue == .profiles {
                refreshProfilesFromMachine()
            }
        }
    }
    
    /// Notifies parent of current modification state
    private func notifyModificationChanged() {
        // If a profile has been actively selected (selectedProfileDirectory is set),
        // use the selected values even if some are nil (e.g., no hosted domain).
        // Only fall back to window.chromeState when NO profile selection has been made.
        let hasActiveProfileSelection = selectedProfileDirectory != nil

        // Special case: "Any Chrome Window" selected - clear all profile info
        let profileDir: String?
        let profileName: String?
        let profileDomain: String?
        let profileUserName: String?

        if isAnyWindowSelected {
            // User explicitly chose no profile restriction
            profileDir = nil
            profileName = nil
            profileDomain = nil
            profileUserName = nil
            DeskJigLog.info(.chrome, "ChromeWindowDetailPanel: 'Any Chrome Window' selected - clearing profile restriction")
        } else if hasActiveProfileSelection {
            profileDir = selectedProfileDirectory
            profileName = selectedProfileDisplayName
            profileDomain = selectedProfileHostedDomain
            profileUserName = selectedProfileUserName
        } else {
            profileDir = window.chromeState?.profileDirectory
            profileName = window.chromeState?.profileDisplayName
            profileDomain = window.chromeState?.profileHostedDomain
            profileUserName = window.chromeState?.profileUserName
        }

        let modification = ChromeWindowModification(
            tabURLs: liveTabURLs,
            profileDirectory: profileDir,
            profileDisplayName: profileName,
            profileHostedDomain: profileDomain,
            profileUserName: profileUserName,
            profileMatchMode: isAnyWindowSelected ? .anyWindow : .specific
        )
        DeskJigLog.info(.chrome, "ChromeWindowDetailPanel: notifyModificationChanged", fields: ["urlCount": modification.tabURLs.count, "profile": modification.profileDisplayName ?? "nil", "hostedDomain": modification.profileHostedDomain ?? "nil", "userName": modification.profileUserName ?? "nil", "hasActiveSelection": "\(hasActiveProfileSelection)", "isAnyWindow": "\(isAnyWindowSelected)"])
        for (index, url) in modification.tabURLs.enumerated() {
            DeskJigLog.info(.chrome, "URL in modification", fields: ["index": "\(index)", "url": url])
        }
        onModificationChanged(modification)
    }
    
    /// Fetches live tab data from Chrome by matching window title
    private func fetchLiveChromeTabs() {
        isLoadingTabs = true
        
        // Capture window title before async work
        let windowTitle = window.windowTitle
        
        // Use Task with @MainActor to properly update SwiftUI state
        Task { @MainActor in
            // Run Chrome capture on background thread
            let captures = await Task.detached {
                ChromeAutomationService.captureOpenWindows()
            }.value
            
            // Get the current profile info - prefer UI-selected profile, fall back to chromeState
            let currentProfile = selectedProfileDisplayName ?? window.chromeState?.profileDisplayName
            DeskJigLog.info(.chrome, "ChromeWindowDetailPanel: Got captures", fields: ["count": captures.count, "windowTitle": windowTitle, "profile": currentProfile ?? "nil"])

            // Try to match by window title first
            var matchedCapture = captures.first { capture in
                // Match if the window title contains the Chrome window's title
                // or if the capture title contains any part of the workspace window title
                capture.title.localizedCaseInsensitiveContains(windowTitle) ||
                windowTitle.localizedCaseInsensitiveContains(capture.title.components(separatedBy: " - ").first ?? "")
            }

            // Fallback: If title match fails, try matching by profile name
            if matchedCapture == nil, let profileName = currentProfile {
                matchedCapture = captures.first { capture in
                    guard let captureProfile = capture.profileAppleScriptName else { return false }
                    // Match if profile names are equal or one contains the other
                    return captureProfile == profileName ||
                           captureProfile.localizedCaseInsensitiveContains(profileName) ||
                           profileName.localizedCaseInsensitiveContains(captureProfile)
                }
                if matchedCapture != nil {
                    DeskJigLog.info(.chrome, "ChromeWindowDetailPanel: Matched by profile name", fields: ["profileName": profileName])
                }
            }

            var capturedProfileName: String? = nil

            if let capture = matchedCapture {
                liveTabURLs = capture.tabURLs
                capturedProfileName = capture.profileAppleScriptName
                DeskJigLog.info(.chrome, "ChromeWindowDetailPanel: Matched! Setting liveTabURLs", fields: ["count": capture.tabURLs.count])
            } else if captures.count == 1 {
                // If no match found, use the first Chrome window if there's only one
                liveTabURLs = captures[0].tabURLs
                capturedProfileName = captures[0].profileAppleScriptName
                DeskJigLog.info(.chrome, "ChromeWindowDetailPanel: Using single Chrome window", fields: ["tabs": captures[0].tabURLs.count])
            } else {
                DeskJigLog.warn(.chrome, "ChromeWindowDetailPanel: Could not match window", fields: ["windowTitle": windowTitle, "captureCount": captures.count])
            }
            
            // Try to resolve profile from AppleScript name
            if let profileName = capturedProfileName,
               let profile = chromeProfileManager.profile(forAppleScriptName: profileName) {
                selectedProfileDirectory = profile.directory
                // Use appleScriptDisplayName which prefers gaiaName first word (matches window titles)
                selectedProfileDisplayName = profile.appleScriptDisplayName
                selectedProfileHostedDomain = profile.hostedDomain
                selectedProfileUserName = profile.userName
                DeskJigLog.info(.chrome, "ChromeWindowDetailPanel: Resolved profile", fields: ["dir": profile.directory, "displayName": profile.appleScriptDisplayName, "hostedDomain": profile.hostedDomain ?? "nil"])
            }
            
            isLoadingTabs = false
            DeskJigLog.info(.chrome, "ChromeWindowDetailPanel: Done loading", fields: ["tabCount": liveTabURLs.count])
        }
    }
    
    // MARK: - Tabs List View
    
    private var tabsListView: some View {
        VStack(spacing: 8) {
            loadTabsButton

            if isLoadingTabs {
                VStack(spacing: 8) {
                    ProgressView()
                        .scaleEffect(0.8)
                        .tint(.white.opacity(0.6))
                    Text("Loading tabs from Chrome...")
                        .font(brand: .label2)
                        .foregroundStyle(DesignTokens.Text.primary.opacity(0.5))
                }
                .frame(maxWidth: .infinity, minHeight: 100)
            } else if liveTabURLs.isEmpty {
                VStack(spacing: 12) {
                    VStack(spacing: 8) {
                        Image(systemName: "globe")
                            .font(brand: Font.brandBody(size: 32))
                            .foregroundStyle(DesignTokens.Text.primary.opacity(0.3))
                        Text("No tabs")
                            .font(brand: .label2)
                            .foregroundStyle(DesignTokens.Text.primary.opacity(0.5))
                        Text("Add a URL to get started")
                            .font(brand: Font.brandBody(size: 10))
                            .foregroundStyle(DesignTokens.Text.primary.opacity(0.3))
                    }
                    
                    // Add new URL row - always show so users can add tabs
                    AddNewTabRow(
                        nextIndex: 0,
                        onAdd: { newURL in
                            withAnimation(.spring(duration: 0.2)) {
                                liveTabURLs.append(newURL)
                                DeskJigLog.info(.chrome, "ChromeTabRow: Added new tab", fields: ["url": newURL])
                            }
                        }
                    )
                    .padding(.horizontal, 8)
                }
                .frame(maxWidth: .infinity, minHeight: 100)
            } else {
                // Tab count header
                Text("\(liveTabURLs.count) tab(s)")
                    .font(brand: Font.brandBody(size: 10))
                    .foregroundStyle(DesignTokens.Text.primary.opacity(0.4))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.bottom, 4)
                
                ScrollView(.vertical, showsIndicators: true) {
                    LazyVStack(spacing: 4) {
                        ForEach(Array(liveTabURLs.indices), id: \.self) { index in
                            ChromeTabRow(
                                index: index,
                                url: Binding(
                                    get: { liveTabURLs[index] },
                                    set: { newValue in
                                        liveTabURLs[index] = newValue
                                    }
                                ),
                                onDelete: {
                                    withAnimation(.spring(duration: 0.2)) {
                                        if index < liveTabURLs.count {
                                            liveTabURLs.remove(at: index)
                                            DeskJigLog.info(.chrome, "ChromeTabRow: Deleted tab", fields: ["index": "\(index)"])
                                        }
                                    }
                                }
                            )
                        }
                        
                        // Add new URL row
                        AddNewTabRow(
                            nextIndex: liveTabURLs.count,
                            onAdd: { newURL in
                                withAnimation(.spring(duration: 0.2)) {
                                    liveTabURLs.append(newURL)
                                    DeskJigLog.info(.chrome, "ChromeTabRow: Added new tab", fields: ["url": newURL])
                                }
                            }
                        )
                    }
                    .padding(.vertical, 4)
                }
                .frame(minHeight: 80)
            }
        }
    }

    private var loadTabsButton: some View {
        Button(action: fetchLiveChromeTabs) {
            Label("Load tabs from Chrome", systemImage: "arrow.clockwise")
                .font(brand: .label3)
                .foregroundStyle(DesignTokens.Text.primary)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background {
                    Capsule()
                        .fill(DesignTokens.Brand.accentMuted)
                        .brightenOnHover()
                }
        }
        .buttonStyle(.plain)
        .help("Load tabs from Chrome (replaces the list)")
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    
    // MARK: - Profiles List View
    
    private var profilesListView: some View {
        Group {
            if profiles.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "person.circle")
                        .font(brand: Font.brandBody(size: 32))
                        .foregroundStyle(DesignTokens.Text.muted)
                    Text("No Chrome profiles found")
                        .font(brand: .label2)
                        .foregroundStyle(DesignTokens.Text.tertiary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(spacing: 4) {
                        // "Any Chrome Window" option - no profile restriction
                        AnyWindowRow(
                            isSelected: isAnyWindowSelected,
                            onTap: {
                                withAnimation(.spring(duration: 0.2)) {
                                    selectedProfileDirectory = Self.anyProfileMarker
                                    selectedProfileDisplayName = nil
                                    selectedProfileHostedDomain = nil
                                    selectedProfileUserName = nil
                                    DeskJigLog.info(.chrome, "Selected 'Any Chrome Window' - no profile restriction")
                                }
                            }
                        )

                        Divider()
                            .background(DesignTokens.Border.subtle)
                            .padding(.vertical, 4)

                        ForEach(profiles) { profile in
                            ChromeProfileRow(
                                profile: profile,
                                isSelected: !isAnyWindowSelected && profile.directory == currentProfileDirectory,
                                onTap: {
                                    withAnimation(.spring(duration: 0.2)) {
                                        selectedProfileDirectory = profile.directory
                                        // Use appleScriptDisplayName which prefers gaiaName first word (matches window titles)
                                        selectedProfileDisplayName = profile.appleScriptDisplayName
                                        selectedProfileHostedDomain = profile.hostedDomain
                                        selectedProfileUserName = profile.userName
                                        DeskJigLog.info(.chrome, "Selected profile", fields: ["displayName": profile.appleScriptDisplayName, "dir": profile.directory, "hostedDomain": profile.hostedDomain ?? "nil"])
                                    }
                                }
                            )
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
    }

    private func refreshProfilesFromMachine() {
        let refreshed = chromeProfileManager.refreshProfilesSync()
        profiles = refreshed

        guard let selectedProfileDirectory,
              !selectedProfileDirectory.isEmpty,
              selectedProfileDirectory != Self.anyProfileMarker,
              let profile = refreshed.first(where: { $0.directory == selectedProfileDirectory }) else {
            return
        }

        selectedProfileDisplayName = profile.appleScriptDisplayName
        selectedProfileHostedDomain = profile.hostedDomain
        selectedProfileUserName = profile.userName
    }
}
