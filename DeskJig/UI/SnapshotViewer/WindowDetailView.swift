//
//  WindowDetailView.swift
//  DeskJig
//
//  Detailed view of a selected window with collapsible sections
//

import SwiftUI
import DeskJigShared

struct WindowDetailView: View {
    let window: SnapshotWindow?
    let snapshot: SystemSnapshot?
    let onRefresh: () -> Void
    var onRefreshChrome: (() async -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let window {
                // Compact header with key info
                headerView(window)

                Divider()

                // Scrollable content with collapsible sections
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        // Identity section (always visible, compact)
                        identitySection(window)

                        // Geometry section (collapsible)
                        CollapsibleSection(title: "Geometry", icon: "rectangle.dashed") {
                            geometryContent(window)
                        }

                        // State section (collapsible)
                        CollapsibleSection(title: "State", icon: "circle.lefthalf.filled") {
                            stateContent(window)
                        }

                        // Chrome section (if applicable - show for Chrome windows)
                        if isChromeWindow(window) {
                            CollapsibleSection(title: "Chrome", icon: "globe") {
                                chromeContent(window)
                            }
                            .task(id: window.id) {
                                // Auto-load native messaging tabs and resolve window ID when Chrome section appears
                                // Using window.id as task ID ensures this runs when selection changes
                                if isNativeMessagingConnected {
                                    await resolveChromWindowId(for: window)
                                    await loadTabGroups()
                                    await loadAllChromeWindows()
                                }
                            }
                        }

                        // Document section (if applicable)
                        if window.documentPath != nil {
                            CollapsibleSection(title: "Document", icon: "doc.fill") {
                                documentContent(window)
                            }
                        }

                        Divider()
                            .padding(.vertical, 4)

                        // Window Actions (collapsed by default)
                        CollapsibleSection(title: "Window Actions", icon: "hand.tap", defaultExpanded: false) {
                            WindowActionsView(window: window, onRefresh: onRefresh)
                        }

                        // App Actions (collapsed by default)
                        CollapsibleSection(title: "App Actions", icon: "app.badge", defaultExpanded: false) {
                            AppActionsView(window: window, onRefresh: onRefresh)
                        }

                        // Launcher Actions (for terminals and IDEs, collapsed by default)
                        if isTerminalOrIDE(window) {
                            CollapsibleSection(title: "Launcher Actions", icon: "terminal", defaultExpanded: false) {
                                LauncherActionsView(window: window, snapshot: snapshot, onRefresh: onRefresh)
                            }
                        }

                        // Debug section (collapsed by default)
                        CollapsibleSection(title: "Debug Info", icon: "ladybug", defaultExpanded: false) {
                            debugContent(window)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                }
            } else {
                emptyState
            }
        }
        .alert("Name Tab Group", isPresented: $isShowingGroupNameAlert) {
            TextField("Group name", text: $newGroupName)
            Button("Cancel", role: .cancel) {
                pendingGroupId = nil
                newGroupName = ""
            }
            Button("Save") {
                Task { await saveGroupName() }
            }
        } message: {
            Text("Enter a name for the new tab group")
        }
    }

    // MARK: - Header

    private func headerView(_ window: SnapshotWindow) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(window.appName ?? "Unknown App")
                .font(.headline)
                .lineLimit(1)

            if let title = window.title, !title.isEmpty {
                Text(title)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            HStack(spacing: 12) {
                Label("\(window.windowId)", systemImage: "number")
                Label("PID \(window.pid)", systemImage: "gearshape")
                if let z = window.zOrderIndex {
                    Label("Z:\(z)", systemImage: "square.stack.3d.up")
                        .foregroundStyle(z == 0 ? DesignTokens.Brand.accent : .secondary)
                }
            }
            .font(.caption)
            .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.bar)
    }

    // MARK: - Sections

    private func identitySection(_ window: SnapshotWindow) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if let bundleId = window.bundleId {
                CompactRow(label: "Bundle ID", value: bundleId)
            }
        }
    }

    private func geometryContent(_ window: SnapshotWindow) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 16) {
                CompactRow(label: "Origin", value: String(format: "(%.0f, %.0f)", window.frame.origin.x, window.frame.origin.y))
                CompactRow(label: "Size", value: String(format: "%.0f × %.0f", window.frame.width, window.frame.height))
            }

            if let displayIndex = window.displayIndex {
                let displayName = snapshot?.displays.first(where: { $0.index == displayIndex })?.name ?? "Unknown"
                CompactRow(label: "Display", value: "\(displayIndex) - \(displayName)")
            }

            CompactRow(label: "Layer", value: "\(window.layer)")
        }
    }

    private func stateContent(_ window: SnapshotWindow) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 16) {
                StateIndicator(
                    label: "On Screen",
                    value: window.isOnScreen,
                    trueIcon: "eye.fill",
                    falseIcon: "eye.slash",
                    trueColor: DesignTokens.Brand.accent
                )

                if let minimized = window.isMinimized {
                    StateIndicator(
                        label: "Minimized",
                        value: minimized,
                        trueIcon: "minus.circle.fill",
                        falseIcon: "minus.circle",
                        trueColor: DesignTokens.Brand.accent
                    )
                }
            }

            if let fullScreen = window.isFullScreen, fullScreen {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .foregroundStyle(DesignTokens.Brand.accent)
                    Text("Full Screen")
                        .font(.caption)
                }
            }

            if window.mightBeOnDifferentSpace {
                HStack(spacing: 4) {
                    Image(systemName: "square.stack.3d.up")
                        .foregroundStyle(DesignTokens.Brand.accent)
                    Text("Possibly on different Space")
                        .font(.caption)
                        .foregroundStyle(DesignTokens.Brand.accent)
                }
            }
        }
    }

    // MARK: - App Type Helpers

    private func isTerminalOrIDE(_ window: SnapshotWindow) -> Bool {
        guard let bundleId = window.bundleId else { return false }
        return BundleRegistry.isTerminal(bundleId) || BundleRegistry.isIDE(bundleId)
    }

    // MARK: - Chrome Helpers (using ChromeFluentAPI)

    private func isChromeWindow(_ window: SnapshotWindow) -> Bool {
        snapshot?.chrome.isChrome(window) ?? false
    }

    private func matchingChromeCapture(for window: SnapshotWindow) -> ChromeWindowCapture? {
        snapshot?.chrome.capture(for: window)
    }

    private func extractedProfileName(for window: SnapshotWindow) -> String? {
        snapshot?.chrome.extractProfileName(from: window.title)
    }

    // MARK: - Native Messaging

    private var isNativeMessagingConnected: Bool {
        snapshot?.chrome.nativeMessaging?.isConnected ?? false
    }

    private var nativeMessagingStatusView: some View {
        HStack(spacing: 6) {
            if isNativeMessagingConnected {
                Image(systemName: "bolt.fill")
                    .foregroundStyle(DesignTokens.Brand.accent)
                Text("Live")
                    .font(.caption)
                    .foregroundStyle(DesignTokens.Brand.accent)
            } else {
                Image(systemName: "bolt.slash")
                    .foregroundStyle(DesignTokens.Brand.accent)
                Text("Extension Disconnected")
                    .font(.caption)
                    .foregroundStyle(DesignTokens.Brand.accent)
            }
        }
        .padding(.vertical, 2)
    }

    private func loadNativeMessagingTabs() async {
        guard let messaging = snapshot?.chrome.nativeMessaging else {
            nativeMessagingTabs = nil
            return
        }

        isLoadingNativeMessaging = true
        defer { isLoadingNativeMessaging = false }

        do {
            // Force refresh to get latest data
            let allTabs = try await messaging.allTabs(forceRefresh: true)
            nativeMessagingTabs = allTabs
        } catch {
            nativeMessagingTabs = nil
        }
    }

    /// Resolve the real Chrome Extension API window ID for the given macOS window
    /// This queries the extension directly since AppleScript window IDs don't match extension window IDs
    private func resolveChromWindowId(for window: SnapshotWindow) async {
        guard let messaging = snapshot?.chrome.nativeMessaging,
              let docPath = window.documentPath, !docPath.isEmpty else {
            chromeExtensionWindowId = nil
            nativeMessagingTabs = nil
            return
        }

        isLoadingNativeMessaging = true
        defer { isLoadingNativeMessaging = false }

        do {
            // Get all windows with their tabs from the extension
            let windows = try await messaging.allWindows(forceRefresh: true)
            let normalizedDocPath = normalizeURL(docPath)

            // Strategy 0: Match ANY tab URL (not just active tab)
            // The accessibility API's documentPath may not match the active tab
            if let match = windows.first(where: { w in
                w.tabs.contains(where: { normalizeURL($0.url) == normalizedDocPath })
            }) {
                chromeExtensionWindowId = match.id
                nativeMessagingTabs = match.tabs
                return
            }

            // Strategy 1: Exact URL match on active tab
            if let match = windows.first(where: { w in
                w.tabs.first(where: { $0.active })
                    .map { normalizeURL($0.url) == normalizedDocPath } ?? false
            }) {
                chromeExtensionWindowId = match.id
                nativeMessagingTabs = match.tabs
                return
            }

            // Strategy 2: Match by scheme + host for chrome:// URLs
            if docPath.hasPrefix("chrome://") {
                let chromePath = docPath.replacingOccurrences(of: "chrome://", with: "")
                    .components(separatedBy: "/").first ?? ""
                if let match = windows.first(where: { w in
                    w.tabs.first(where: { $0.active })?.url.contains("chrome://\(chromePath)") ?? false
                }) {
                    chromeExtensionWindowId = match.id
                    nativeMessagingTabs = match.tabs
                    return
                }
            }

            // Strategy 3: Match by hostname + first path component on active tab
            if let docURL = URL(string: docPath),
               let docHost = docURL.host {
                let docFirstPath = docURL.pathComponents.dropFirst().first ?? ""
                if let match = windows.first(where: { w in
                    guard let activeTab = w.tabs.first(where: { $0.active }),
                          let tabURL = URL(string: activeTab.url),
                          let tabHost = tabURL.host else { return false }
                    let tabFirstPath = tabURL.pathComponents.dropFirst().first ?? ""
                    return tabHost == docHost && (docFirstPath.isEmpty || tabFirstPath == docFirstPath)
                }) {
                    chromeExtensionWindowId = match.id
                    nativeMessagingTabs = match.tabs
                    return
                }
            }

            // Strategy 4: Match any tab by hostname + first path component
            if let docURL = URL(string: docPath),
               let docHost = docURL.host {
                let docFirstPath = docURL.pathComponents.dropFirst().first ?? ""
                if let match = windows.first(where: { w in
                    w.tabs.contains(where: { tab in
                        guard let tabURL = URL(string: tab.url),
                              let tabHost = tabURL.host else { return false }
                        let tabFirstPath = tabURL.pathComponents.dropFirst().first ?? ""
                        return tabHost == docHost && (docFirstPath.isEmpty || tabFirstPath == docFirstPath)
                    })
                }) {
                    chromeExtensionWindowId = match.id
                    nativeMessagingTabs = match.tabs
                    return
                }
            }

            // No match found
            chromeExtensionWindowId = nil
            nativeMessagingTabs = nil
        } catch {
            chromeExtensionWindowId = nil
            nativeMessagingTabs = nil
        }
    }

    /// Load tab groups for the current window
    private func loadTabGroups() async {
        guard let messaging = snapshot?.chrome.nativeMessaging,
              let windowId = chromeExtensionWindowId else {
            tabGroups = []
            return
        }

        isLoadingGroups = true
        defer { isLoadingGroups = false }

        do {
            tabGroups = try await messaging.getGroups(windowId: windowId)
        } catch {
            tabGroups = []
        }
    }

    /// Load all Chrome windows for move-to-window menu
    private func loadAllChromeWindows() async {
        guard let messaging = snapshot?.chrome.nativeMessaging else {
            allChromeWindows = nil
            return
        }

        do {
            allChromeWindows = try await messaging.allWindows(forceRefresh: false)
        } catch {
            allChromeWindows = nil
        }
    }

    @ViewBuilder
    private func nativeMessagingTabsSection(for window: SnapshotWindow) -> some View {
        // Show tabs for the resolved Chrome window ID
        if let tabs = nativeMessagingTabs, !tabs.isEmpty {
            Divider()
                .padding(.vertical, 4)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 4) {
                    Image(systemName: "bolt.fill")
                        .foregroundStyle(DesignTokens.Brand.accent)
                    Text("Real-time Tabs (\(tabs.count))")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }

                VStack(alignment: .leading, spacing: 4) {
                    ForEach(tabs.sorted { $0.index < $1.index }, id: \.id) { tab in
                        nativeMessagingTabRow(tab)
                    }
                }
            }
        } else if isLoadingNativeMessaging {
            HStack(spacing: 4) {
                ProgressView()
                    .scaleEffect(0.6)
                Text("Loading tabs...")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        } else if chromeExtensionWindowId == nil && isNativeMessagingConnected {
            HStack(spacing: 4) {
                Image(systemName: "questionmark.circle")
                    .foregroundStyle(DesignTokens.Brand.accent)
                Text("Could not match window - click Refresh")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private func findMatchingWindowTabs(for window: SnapshotWindow, from allTabs: [ChromeRealTimeTab]) -> [ChromeRealTimeTab] {
        // Strategy 1: Use Chrome capture's window ID (most reliable)
        // The capture's chromeWindowId matches the extension's windowId
        if let capture = matchingChromeCapture(for: window) {
            let windowTabs = allTabs.filter { $0.windowId == capture.chromeWindowId }
            if !windowTabs.isEmpty {
                return windowTabs.sorted { $0.index < $1.index }
            }
        }

        // Strategy 2: Match by document path (active tab URL) - fallback
        if let docPath = window.documentPath, !docPath.isEmpty {
            let normalizedDocPath = normalizeURL(docPath)
            // Find the active tab that matches this URL
            if let activeTab = allTabs.first(where: { $0.active && normalizeURL($0.url) == normalizedDocPath }) {
                // Return all tabs for that window
                return allTabs.filter { $0.windowId == activeTab.windowId }.sorted { $0.index < $1.index }
            }

            // Try partial matching as last resort
            if let activeTab = allTabs.first(where: {
                $0.active && (
                    normalizeURL($0.url).hasPrefix(normalizedDocPath) ||
                    normalizedDocPath.hasPrefix(normalizeURL($0.url))
                )
            }) {
                return allTabs.filter { $0.windowId == activeTab.windowId }.sorted { $0.index < $1.index }
            }
        }

        return []
    }

    private func normalizeURL(_ url: String) -> String {
        var normalized = url.lowercased()
        // Remove trailing slash
        if normalized.hasSuffix("/") { normalized.removeLast() }
        // Remove www. prefix
        normalized = normalized.replacingOccurrences(of: "://www.", with: "://")
        return normalized
    }

    private func nativeMessagingTabRow(_ tab: ChromeRealTimeTab) -> some View {
        HStack(spacing: 4) {
            // Selection checkbox (always visible)
            Toggle("", isOn: Binding(
                get: { selectedTabIds.contains(tab.id) },
                set: { if $0 { selectedTabIds.insert(tab.id) } else { selectedTabIds.remove(tab.id) } }
            ))
            .toggleStyle(.checkbox)
            .labelsHidden()
            .controlSize(.small)

            // Active indicator
            if tab.active {
                Image(systemName: "circle.fill")
                    .font(brand: Font.brandBody(size: 6))
                    .foregroundStyle(DesignTokens.Brand.accent)
            } else {
                Image(systemName: "circle")
                    .font(brand: Font.brandBody(size: 6))
                    .foregroundStyle(.tertiary)
            }

            // Tab group badge
            if let groupTitle = tab.groupTitle, !groupTitle.isEmpty {
                Text(groupTitle)
                    .font(brand: Font.brandBody(size: 9))
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(chromeGroupColor(tab.groupColor).opacity(0.3))
                    .foregroundStyle(chromeGroupColor(tab.groupColor))
                    .cornerRadius(3)
            } else if tab.groupId != nil {
                // Has group but no title - show colored dot
                Circle()
                    .fill(chromeGroupColor(tab.groupColor))
                    .frame(width: 8, height: 8)
            }

            // Status indicators
            if tab.pinned {
                Image(systemName: "pin.fill")
                    .font(brand: Font.brandBody(size: 8))
                    .foregroundStyle(DesignTokens.Brand.accent)
            }
            if tab.audible == true {
                Image(systemName: "speaker.wave.2.fill")
                    .font(brand: Font.brandBody(size: 8))
                    .foregroundStyle(DesignTokens.Brand.accent)
            }
            if tab.muted == true {
                Image(systemName: "speaker.slash.fill")
                    .font(brand: Font.brandBody(size: 8))
                    .foregroundStyle(DesignTokens.Status.error)
            }

            // Tab content (no textSelection to avoid context menu conflict)
            VStack(alignment: .leading, spacing: 1) {
                Text(tab.title.isEmpty ? "(No title)" : tab.title)
                    .font(.caption2)
                    .lineLimit(1)
                    .foregroundStyle(tab.active ? .primary : .secondary)

                Text(tab.url)
                    .font(brand: Font.brandBody(size: 11))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(.tertiary)
            }
        }
        .contentShape(Rectangle())
        .background(selectedTabIds.contains(tab.id) ? DesignTokens.Brand.accent.opacity(0.1) : Color.clear)
        .cornerRadius(4)
        .onTapGesture {
            if NSEvent.modifierFlags.contains(.command) {
                // Multi-select with Cmd+Click
                if selectedTabIds.contains(tab.id) {
                    selectedTabIds.remove(tab.id)
                } else {
                    selectedTabIds.insert(tab.id)
                }
            } else if NSEvent.modifierFlags.contains(.shift) && !selectedTabIds.isEmpty {
                // Shift-click for range selection (simplified: just add to selection)
                selectedTabIds.insert(tab.id)
            } else {
                // Single click - toggle selection instead of activating
                if selectedTabIds.contains(tab.id) {
                    selectedTabIds.remove(tab.id)
                } else {
                    selectedTabIds.insert(tab.id)
                }
            }
        }
        .contextMenu { tabContextMenu(for: tab) }
    }

    // MARK: - Tab Context Menu

    @ViewBuilder
    private func tabContextMenu(for tab: ChromeRealTimeTab) -> some View {
        // Activate/Focus
        Button {
            Task { await activateTab(tab.id) }
        } label: {
            Label("Activate Tab", systemImage: "arrow.up.forward.app")
        }

        // Copy URL
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(tab.url, forType: .string)
        } label: {
            Label("Copy URL", systemImage: "doc.on.doc")
        }

        Divider()

        // Pin/Unpin
        Button {
            Task { await toggleTabPinned(tab) }
        } label: {
            if tab.pinned {
                Label("Unpin Tab", systemImage: "pin.slash")
            } else {
                Label("Pin Tab", systemImage: "pin")
            }
        }

        // Mute/Unmute (only if audible or already muted)
        if tab.audible == true || tab.muted == true {
            Button {
                Task { await toggleTabMuted(tab) }
            } label: {
                if tab.muted == true {
                    Label("Unmute Tab", systemImage: "speaker.wave.2")
                } else {
                    Label("Mute Tab", systemImage: "speaker.slash")
                }
            }
        }

        Divider()

        // Tab Groups submenu
        Menu("Tab Group") {
            tabGroupMenu(for: tab)
        }

        Divider()

        // Move to Window submenu (if multiple windows exist)
        if let allWindows = allChromeWindows, allWindows.count > 1 {
            Menu("Move to Window") {
                moveToWindowMenu(for: tab, allWindows: allWindows)
            }
        }

        // Move to New Window
        Button {
            Task { await moveTabToNewWindow(tab.id) }
        } label: {
            Label("Move to New Window", systemImage: "rectangle.badge.plus")
        }

        Divider()

        // Close Tab
        Button(role: .destructive) {
            Task { await closeTab(tab.id) }
        } label: {
            Label("Close Tab", systemImage: "xmark")
        }
    }

    // MARK: - Tab Group Menu

    @ViewBuilder
    private func tabGroupMenu(for tab: ChromeRealTimeTab) -> some View {
        // Determine which tabs to operate on: selected tabs if this tab is selected, otherwise just this tab
        let tabsToGroup = selectedTabIds.contains(tab.id) && selectedTabIds.count > 1
            ? Array(selectedTabIds)
            : [tab.id]
        let isMultiple = tabsToGroup.count > 1

        if tab.groupId != nil {
            // Already in a group - show ungroup option
            Button {
                Task { await ungroupTab(tab.id) }
            } label: {
                Label("Remove from Group", systemImage: "rectangle.on.rectangle.slash")
            }
            Divider()
        }

        // Create new group (uses selected tabs if multiple selected)
        Button {
            Task { await createGroupWithTabs(tabsToGroup) }
        } label: {
            if isMultiple {
                Label("Create New Group (\(tabsToGroup.count) tabs)", systemImage: "rectangle.stack.badge.plus")
            } else {
                Label("Create New Group", systemImage: "rectangle.stack.badge.plus")
            }
        }

        // Add to existing groups
        if !tabGroups.isEmpty {
            Divider()
            ForEach(tabGroups) { group in
                Button {
                    Task { await addTabsToGroup(tabsToGroup, groupId: group.id) }
                } label: {
                    HStack {
                        Circle()
                            .fill(chromeGroupColor(group.color))
                            .frame(width: 8, height: 8)
                        Text(group.title.isEmpty ? "Untitled Group" : group.title)
                        if isMultiple {
                            Text("(\(tabsToGroup.count))")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Move to Window Menu

    @ViewBuilder
    private func moveToWindowMenu(for tab: ChromeRealTimeTab, allWindows: [ChromeRealTimeWindow]) -> some View {
        ForEach(allWindows.filter { $0.id != tab.windowId }, id: \.id) { window in
            Button {
                Task { await moveTabToWindow(tab.id, windowId: window.id) }
            } label: {
                let activeTab = window.tabs.first { $0.active }
                let title = activeTab?.title.prefix(30) ?? "Window \(window.id)"
                Text("\(title) (\(window.tabs.count) tabs)")
            }
        }
    }

    private func chromeGroupColor(_ color: String?) -> Color {
        guard color != nil else {
            return DesignTokens.Border.regular
        }
        return DesignTokens.Brand.accent
    }

    @State private var nativeMessagingTabs: [ChromeRealTimeTab]?
    @State private var isLoadingNativeMessaging = false
    @State private var chromeExtensionWindowId: Int?  // Real Chrome Extension API window ID
    @State private var lastActionError: String?  // Error feedback for user

    // Selection and group state for Chrome actions
    @State private var selectedTabIds: Set<Int> = []  // Multi-select for bulk operations
    @State private var tabGroups: [ChromeTabGroup] = []  // Cached groups for this window
    @State private var isLoadingGroups = false
    @State private var allChromeWindows: [ChromeRealTimeWindow]?  // For move-to-window menu

    // Group naming alert state
    @State private var isShowingGroupNameAlert = false
    @State private var pendingGroupId: Int? = nil
    @State private var newGroupName: String = ""

    private func chromeContent(_ window: SnapshotWindow) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            // Refresh button
            HStack {
                Spacer()
                Button {
                    Task {
                        lastActionError = nil
                        await onRefreshChrome?()
                        // Re-resolve window ID and refresh tabs
                        // resolveChromWindowId manages isLoadingNativeMessaging state
                        await resolveChromWindowId(for: window)
                    }
                } label: {
                    HStack(spacing: 4) {
                        if isLoadingNativeMessaging {
                            ProgressView()
                                .scaleEffect(0.6)
                        } else {
                            Image(systemName: "arrow.clockwise")
                        }
                        Text("Refresh")
                    }
                    .font(.caption)
                }
                .buttonStyle(.borderless)
                .disabled(isLoadingNativeMessaging)
            }

            // Native Messaging Status
            nativeMessagingStatusView

            // Current Profile section (from ChromeProfileManager via Fluent API)
            if let chromeAPI = snapshot?.chrome {
                if let profile = chromeAPI.matchingProfile(for: window) {
                    currentProfileSection(profile)
                } else if let profileName = extractedProfileName(for: window) {
                    // Fallback: just show extracted name
                    CompactRow(label: "Profile (from title)", value: profileName)
                }
            }

            // Native Messaging Tabs (real-time data from extension)
            if isNativeMessagingConnected {
                nativeMessagingTabsSection(for: window)
            }

            // AppleScript Capture Data (fallback/legacy)
            if let capture = matchingChromeCapture(for: window) {
                Divider()
                    .padding(.vertical, 4)

                CompactRow(label: "Chrome Window ID", value: "\(capture.chromeWindowId)")

                HStack(spacing: 16) {
                    CompactRow(label: "Active Tab", value: "\(capture.activeTabIndex)")
                    CompactRow(label: "Tab Count", value: "\(capture.tabUrls.count)")
                }

                // Tab URLs list
                if !capture.tabUrls.isEmpty {
                    Text("Tabs")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .padding(.top, 4)

                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(capture.tabUrls.enumerated()), id: \.offset) { index, url in
                            HStack(spacing: 4) {
                                // Active tab indicator (1-indexed)
                                if index + 1 == capture.activeTabIndex {
                                    Image(systemName: "circle.fill")
                                        .font(brand: Font.brandBody(size: 6))
                                        .foregroundStyle(DesignTokens.Brand.accent)
                                } else {
                                    Image(systemName: "circle")
                                        .font(brand: Font.brandBody(size: 6))
                                        .foregroundStyle(.tertiary)
                                }

                                Text(url)
                                    .font(brand: Font.brandBody(size: 11))
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                    .foregroundStyle(index + 1 == capture.activeTabIndex ? .primary : .secondary)
                                    .textSelection(.enabled)
                            }
                        }
                    }
                }
            } else if isChromeWindow(window) {
                HStack {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundStyle(DesignTokens.Brand.accent)
                    Text("No capture data available")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                Text("Try clicking Refresh above or enable Chrome toggle")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            // Other Profiles section
            if let chromeAPI = snapshot?.chrome {
                let otherProfiles = chromeAPI.otherProfiles(for: window)
                if !otherProfiles.isEmpty {
                    otherProfilesSection(otherProfiles)
                }
            }

            // Chrome Actions section
            chromeActionsSection(for: window)
        }
    }

    // MARK: - Chrome Actions Section

    @ViewBuilder
    private func chromeActionsSection(for window: SnapshotWindow) -> some View {
        if isNativeMessagingConnected {
            Divider()
                .padding(.vertical, 4)

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Actions")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)

                    Spacer()

                    // Show resolved window ID for debugging
                    if let windowId = chromeExtensionWindowId {
                        Text("Window: \(windowId)")
                            .font(brand: Font.brandBody(size: 11))
                            .foregroundStyle(.tertiary)
                    }
                }

                // Error feedback
                if let error = lastActionError {
                    HStack(spacing: 4) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(DesignTokens.Status.error)
                        Text(error)
                            .font(.caption2)
                            .foregroundStyle(DesignTokens.Status.error)
                        Spacer()
                        Button {
                            lastActionError = nil
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(6)
                    .background(DesignTokens.Status.error.opacity(0.1))
                    .cornerRadius(6)
                }

                // Show warning if window ID not resolved
                if chromeExtensionWindowId == nil {
                    HStack(spacing: 4) {
                        Image(systemName: "exclamationmark.circle")
                            .foregroundStyle(DesignTokens.Brand.accent)
                        Text("Could not match to Chrome window. Try clicking Refresh.")
                            .font(.caption2)
                            .foregroundStyle(DesignTokens.Brand.accent)
                    }
                }

                // Tab Actions Row
                HStack(spacing: 8) {
                    // Focus Window
                    Button {
                        Task { await focusChromeWindow() }
                    } label: {
                        Label("Focus", systemImage: "arrow.up.forward.app")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(chromeExtensionWindowId == nil)

                    // New Tab
                    Button {
                        Task { await createTabInWindow() }
                    } label: {
                        Label("New Tab", systemImage: "plus")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(chromeExtensionWindowId == nil)

                    // Close active tab
                    if let windowId = chromeExtensionWindowId,
                       let activeTab = nativeMessagingTabs?.first(where: { $0.windowId == windowId && $0.active }) {
                        Button(role: .destructive) {
                            Task { await closeTab(activeTab.id) }
                        } label: {
                            Label("Close Tab", systemImage: "xmark")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }

                // Bulk Actions Bar (when tabs are selected)
                if !selectedTabIds.isEmpty {
                    Divider()
                        .padding(.vertical, 4)

                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("\(selectedTabIds.count) tab\(selectedTabIds.count == 1 ? "" : "s") selected")
                                .font(.caption2)
                                .foregroundStyle(.secondary)

                            Spacer()

                            Button {
                                selectedTabIds.removeAll()
                            } label: {
                                Text("Clear")
                                    .font(.caption2)
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(DesignTokens.Brand.accent)
                        }

                        HStack(spacing: 8) {
                            // Group selected
                            Button {
                                Task { await groupSelectedTabs() }
                            } label: {
                                Label("Group", systemImage: "rectangle.stack")
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)

                            // Close selected
                            Button(role: .destructive) {
                                Task { await closeSelectedTabs() }
                            } label: {
                                Label("Close", systemImage: "xmark")
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                    }
                }

                // Window Management Section
                Divider()
                    .padding(.vertical, 4)

                VStack(alignment: .leading, spacing: 4) {
                    Text("Window")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)

                    HStack(spacing: 8) {
                        // Create new window
                        Button {
                            Task { await createNewChromeWindow() }
                        } label: {
                            Label("New Window", systemImage: "rectangle.badge.plus")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)

                        // Close window (destructive, with safety check)
                        Button(role: .destructive) {
                            Task { await closeCurrentChromeWindow() }
                        } label: {
                            Label("Close Window", systemImage: "xmark.rectangle")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(chromeExtensionWindowId == nil || (nativeMessagingTabs?.count ?? 0) > 10)
                        .help((nativeMessagingTabs?.count ?? 0) > 10 ? "Cannot close windows with more than 10 tabs for safety" : "Close this Chrome window")
                    }
                }
            }
        }
    }

    private func focusChromeWindow() async {
        guard let messaging = snapshot?.chrome.nativeMessaging else {
            lastActionError = "Chrome extension not connected"
            return
        }
        guard let windowId = chromeExtensionWindowId else {
            lastActionError = "Window ID not resolved - try clicking Refresh"
            return
        }

        lastActionError = nil
        do {
            try await messaging.focusWindow(id: windowId)
        } catch {
            lastActionError = "Focus failed: \(error.localizedDescription)"
        }
    }

    private func createTabInWindow() async {
        guard let messaging = snapshot?.chrome.nativeMessaging else {
            lastActionError = "Chrome extension not connected"
            return
        }
        guard let windowId = chromeExtensionWindowId else {
            lastActionError = "Window ID not resolved - try clicking Refresh"
            return
        }

        lastActionError = nil
        do {
            _ = try await messaging.createTab(url: "chrome://newtab", windowId: windowId)
            // Refresh tabs to show new tab
            nativeMessagingTabs = try await messaging.tabs(forWindowId: windowId)
        } catch {
            lastActionError = "Create tab failed: \(error.localizedDescription)"
        }
    }

    private func closeTab(_ tabId: Int) async {
        guard let messaging = snapshot?.chrome.nativeMessaging else {
            lastActionError = "Chrome extension not connected"
            return
        }

        lastActionError = nil
        do {
            try await messaging.closeTab(id: tabId)
            // Refresh tabs to reflect closed tab
            if let windowId = chromeExtensionWindowId {
                nativeMessagingTabs = try await messaging.tabs(forWindowId: windowId)
            }
        } catch {
            lastActionError = "Close tab failed: \(error.localizedDescription)"
        }
    }

    // MARK: - Tab Actions

    private func activateTab(_ tabId: Int) async {
        guard let messaging = snapshot?.chrome.nativeMessaging else {
            lastActionError = "Chrome extension not connected"
            return
        }
        lastActionError = nil
        do {
            try await messaging.activateTab(id: tabId)
            // Also focus the window
            if let windowId = chromeExtensionWindowId {
                try await messaging.focusWindow(id: windowId)
            }
        } catch {
            lastActionError = "Activate failed: \(error.localizedDescription)"
        }
    }

    private func toggleTabPinned(_ tab: ChromeRealTimeTab) async {
        guard let messaging = snapshot?.chrome.nativeMessaging else {
            lastActionError = "Chrome extension not connected"
            return
        }
        lastActionError = nil
        do {
            try await messaging.setTabPinned(id: tab.id, pinned: !tab.pinned)
            await refreshCurrentWindow()
        } catch {
            lastActionError = "Pin toggle failed: \(error.localizedDescription)"
        }
    }

    private func toggleTabMuted(_ tab: ChromeRealTimeTab) async {
        guard let messaging = snapshot?.chrome.nativeMessaging else {
            lastActionError = "Chrome extension not connected"
            return
        }
        let isMuted = tab.muted ?? false
        lastActionError = nil
        do {
            try await messaging.setTabMuted(id: tab.id, muted: !isMuted)
            await refreshCurrentWindow()
        } catch {
            lastActionError = "Mute toggle failed: \(error.localizedDescription)"
        }
    }

    // MARK: - Group Actions

    private func ungroupTab(_ tabId: Int) async {
        guard let messaging = snapshot?.chrome.nativeMessaging else {
            lastActionError = "Chrome extension not connected"
            return
        }
        lastActionError = nil
        do {
            try await messaging.ungroupTabs(tabIds: [tabId])
            await loadTabGroups()
            await refreshCurrentWindow()
        } catch {
            lastActionError = "Ungroup failed: \(error.localizedDescription)"
        }
    }

    private func addTabsToGroup(_ tabIds: [Int], groupId: Int) async {
        guard let messaging = snapshot?.chrome.nativeMessaging else {
            lastActionError = "Chrome extension not connected"
            return
        }
        lastActionError = nil
        do {
            _ = try await messaging.groupTabs(tabIds: tabIds, inGroupId: groupId)
            selectedTabIds.removeAll()  // Clear selection after grouping
            await refreshCurrentWindow()
        } catch {
            lastActionError = "Add to group failed: \(error.localizedDescription)"
        }
    }

    private func createGroupWithTabs(_ tabIds: [Int]) async {
        guard let messaging = snapshot?.chrome.nativeMessaging,
              let windowId = chromeExtensionWindowId else {
            lastActionError = "Chrome extension not connected or window not resolved"
            return
        }
        lastActionError = nil
        do {
            let groupId = try await messaging.groupTabs(tabIds: tabIds, windowId: windowId)
            selectedTabIds.removeAll()  // Clear selection after grouping
            await loadTabGroups()
            await refreshCurrentWindow()
            // Show alert to name the group
            pendingGroupId = groupId
            newGroupName = ""
            isShowingGroupNameAlert = true
        } catch {
            lastActionError = "Create group failed: \(error.localizedDescription)"
        }
    }

    private func groupSelectedTabs() async {
        guard let messaging = snapshot?.chrome.nativeMessaging,
              let windowId = chromeExtensionWindowId,
              !selectedTabIds.isEmpty else {
            lastActionError = "No tabs selected or extension not connected"
            return
        }
        lastActionError = nil
        do {
            let groupId = try await messaging.groupTabs(tabIds: Array(selectedTabIds), windowId: windowId)
            selectedTabIds.removeAll()
            await loadTabGroups()
            await refreshCurrentWindow()
            // Show alert to name the group
            pendingGroupId = groupId
            newGroupName = ""
            isShowingGroupNameAlert = true
        } catch {
            lastActionError = "Group tabs failed: \(error.localizedDescription)"
        }
    }

    private func saveGroupName() async {
        guard let groupId = pendingGroupId,
              let messaging = snapshot?.chrome.nativeMessaging,
              !newGroupName.trimmingCharacters(in: .whitespaces).isEmpty else {
            pendingGroupId = nil
            newGroupName = ""
            return
        }
        do {
            try await messaging.updateGroup(id: groupId, title: newGroupName.trimmingCharacters(in: .whitespaces))
            await loadTabGroups()
            await refreshCurrentWindow()
        } catch {
            lastActionError = "Failed to name group: \(error.localizedDescription)"
        }
        pendingGroupId = nil
        newGroupName = ""
    }

    // MARK: - Move Actions

    private func moveTabToWindow(_ tabId: Int, windowId: Int) async {
        guard let messaging = snapshot?.chrome.nativeMessaging else {
            lastActionError = "Chrome extension not connected"
            return
        }
        lastActionError = nil
        do {
            try await messaging.moveTabs(tabIds: [tabId], toWindow: windowId)
            await refreshCurrentWindow()
            await loadAllChromeWindows()
        } catch {
            lastActionError = "Move tab failed: \(error.localizedDescription)"
        }
    }

    private func moveTabToNewWindow(_ tabId: Int) async {
        guard let messaging = snapshot?.chrome.nativeMessaging else {
            lastActionError = "Chrome extension not connected"
            return
        }
        lastActionError = nil
        do {
            _ = try await messaging.moveTabToNewWindow(tabId: tabId)
            await refreshCurrentWindow()
            await loadAllChromeWindows()
        } catch {
            lastActionError = "Move to new window failed: \(error.localizedDescription)"
        }
    }

    // MARK: - Bulk Actions

    private func closeSelectedTabs() async {
        guard let messaging = snapshot?.chrome.nativeMessaging,
              !selectedTabIds.isEmpty else {
            lastActionError = "Chrome extension not connected or no tabs selected"
            return
        }
        lastActionError = nil
        do {
            // Use batch close for efficiency
            try await messaging.closeTabs(ids: Array(selectedTabIds))
            selectedTabIds.removeAll()
            await refreshCurrentWindow()
        } catch {
            lastActionError = "Close tabs failed: \(error.localizedDescription)"
        }
    }

    // MARK: - Window Actions

    private func createNewChromeWindow() async {
        guard let messaging = snapshot?.chrome.nativeMessaging else {
            lastActionError = "Chrome extension not connected"
            return
        }
        lastActionError = nil
        do {
            _ = try await messaging.createWindow()
            await loadAllChromeWindows()
        } catch {
            lastActionError = "Create window failed: \(error.localizedDescription)"
        }
    }

    private func closeCurrentChromeWindow() async {
        guard let messaging = snapshot?.chrome.nativeMessaging,
              let windowId = chromeExtensionWindowId else {
            lastActionError = "Chrome extension not connected or window not resolved"
            return
        }
        lastActionError = nil
        do {
            try await messaging.closeWindow(id: windowId)
        } catch {
            lastActionError = "Close window failed: \(error.localizedDescription)"
        }
    }

    // MARK: - Helper Methods

    private func refreshCurrentWindow() async {
        guard let messaging = snapshot?.chrome.nativeMessaging,
              let windowId = chromeExtensionWindowId else { return }
        do {
            nativeMessagingTabs = try await messaging.tabs(forWindowId: windowId)
        } catch {
            // Silently fail refresh
        }
    }

    // MARK: - Profile Section Views

    private func currentProfileSection(_ profile: ChromeProfile) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Image(systemName: "person.circle.fill")
                    .foregroundStyle(DesignTokens.Brand.accent)
                Text("Current Profile")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            VStack(alignment: .leading, spacing: 2) {
                // Display name (prominent)
                Text(profile.gaiaName ?? profile.displayName)
                    .font(.caption)
                    .fontWeight(.medium)

                // Email/username
                if let userName = profile.userName, !userName.isEmpty {
                    Text(userName)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                // Organization domain
                if let domain = profile.hostedDomain {
                    HStack(spacing: 4) {
                        Image(systemName: "building.2")
                            .font(brand: Font.brandBody(size: 9))
                        Text(domain)
                            .font(.caption2)
                    }
                    .foregroundStyle(DesignTokens.Brand.accent)
                }

                // Managed indicator
                if profile.isManaged {
                    HStack(spacing: 4) {
                        Image(systemName: "checkmark.shield")
                            .font(brand: Font.brandBody(size: 9))
                        Text("Managed account")
                            .font(.caption2)
                    }
                    .foregroundStyle(DesignTokens.Brand.accent)
                }

                // Profile directory (for debugging)
                Text("Directory: \(profile.directory)")
                    .font(brand: Font.brandBody(size: 11))
                    .foregroundStyle(.tertiary)
            }
            .padding(.leading, 20)
        }
    }

    @State private var isOtherProfilesExpanded = false

    private func otherProfilesSection(_ profiles: [ChromeProfile]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Divider()
                .padding(.vertical, 4)

            DisclosureGroup(isExpanded: $isOtherProfilesExpanded) {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(profiles) { profile in
                        otherProfileRow(profile)
                    }
                }
                .padding(.top, 4)
                .padding(.leading, 4)
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "person.2")
                    Text("Other Profiles (\(profiles.count))")
                        .font(.caption)
                }
                .foregroundStyle(.secondary)
            }
        }
    }

    private func otherProfileRow(_ profile: ChromeProfile) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 4) {
                Image(systemName: "person.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(profile.gaiaName ?? profile.displayName)
                    .font(.caption)
            }

            if let domain = profile.hostedDomain {
                Text(domain)
                    .font(.caption2)
                    .foregroundStyle(DesignTokens.Brand.accent)
                    .padding(.leading, 20)
            } else if let userName = profile.userName {
                Text(userName)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .padding(.leading, 20)
            }
        }
    }

    private func documentContent(_ window: SnapshotWindow) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if let docPath = window.documentPath {
                Text(docPath)
                    .font(brand: Font.brandBody(size: 12))
                    .textSelection(.enabled)
                    .foregroundStyle(DesignTokens.Brand.accent)
                    .lineLimit(3)
            }
        }
    }

    private func debugContent(_ window: SnapshotWindow) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            // Raw frame in horizontal scroll
            VStack(alignment: .leading, spacing: 2) {
                Text("Raw Frame")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)

                ScrollView(.horizontal, showsIndicators: true) {
                    Text("CGRect(x: \(window.frame.origin.x), y: \(window.frame.origin.y), width: \(window.frame.width), height: \(window.frame.height))")
                        .font(brand: Font.brandBody(size: 11))
                        .textSelection(.enabled)
                        .foregroundStyle(.secondary)
                }
            }

            // All IDs for debugging
            VStack(alignment: .leading, spacing: 2) {
                Text("IDs")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)

                Text("Window ID: \(window.windowId)")
                    .font(brand: Font.brandBody(size: 11))
                    .textSelection(.enabled)
                Text("PID: \(window.pid)")
                    .font(brand: Font.brandBody(size: 11))
                    .textSelection(.enabled)
                Text("Internal ID: \(window.id)")
                    .font(brand: Font.brandBody(size: 11))
                    .textSelection(.enabled)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Spacer()
            Image(systemName: "window.shade.closed")
                .font(.largeTitle)
                .foregroundStyle(.tertiary)
            Text("Select a window")
                .foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Collapsible Section

struct CollapsibleSection<Content: View>: View {
    let title: String
    let icon: String
    var defaultExpanded: Bool = true
    @ViewBuilder let content: Content

    @State private var isExpanded: Bool

    init(title: String, icon: String, defaultExpanded: Bool = true, @ViewBuilder content: () -> Content) {
        self.title = title
        self.icon = icon
        self.defaultExpanded = defaultExpanded
        self.content = content()
        self._isExpanded = State(initialValue: defaultExpanded)
    }

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            content
                .padding(.top, 4)
                .padding(.leading, 4)
        } label: {
            Label(title, systemImage: icon)
                .font(.subheadline)
                .fontWeight(.medium)
        }
    }
}

// MARK: - Compact Row (vertical layout for narrow panels)

struct CompactRow: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(.tertiary)
            Text(value)
                .font(.caption)
                .textSelection(.enabled)
                .lineLimit(2)
        }
    }
}

// MARK: - State Indicator

struct StateIndicator: View {
    let label: String
    let value: Bool
    let trueIcon: String
    let falseIcon: String
    let trueColor: Color

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: value ? trueIcon : falseIcon)
                .foregroundStyle(value ? trueColor : .secondary)
            Text(label)
                .font(.caption)
                .foregroundStyle(value ? .primary : .secondary)
        }
    }
}

// MARK: - Legacy DetailSection (kept for compatibility)

struct DetailSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.subheadline)
                .fontWeight(.semibold)
                .foregroundStyle(.secondary)
            content
        }
    }
}

// MARK: - Legacy DetailRow (kept for compatibility)

struct DetailRow: View {
    let label: String
    let value: String
    var dimmed: Bool = false
    var color: Color? = nil

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Text(label)
                .foregroundStyle(.secondary)
                .frame(minWidth: 60, alignment: .trailing)
            if let color = color {
                Text(value)
                    .textSelection(.enabled)
                    .foregroundStyle(color)
                    .lineLimit(2)
            } else if dimmed {
                Text(value)
                    .textSelection(.enabled)
                    .foregroundStyle(.tertiary)
                    .lineLimit(2)
            } else {
                Text(value)
                    .textSelection(.enabled)
                    .foregroundStyle(.primary)
                    .lineLimit(2)
            }
        }
        .font(.system(.caption, design: .monospaced))
    }
}
