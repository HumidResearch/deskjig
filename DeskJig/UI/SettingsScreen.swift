//  SettingsScreen.swift
//  DeskJig

import SwiftUI
import KeyboardShortcuts
import CocoaLumberjackSwift
import AppKit
import DeskJigShared

struct SettingsScreen: View {
    @EnvironmentObject var appUpdateController: SparkleController
    @EnvironmentObject var windowManager: WindowManager
    @State private var isThirdsExpanded = false
    @State private var isQuartersExpanded = false
    /// Search text binding from parent (DeskJigContentView)
    @Binding var searchQuery: String
    @AppStorage("menuAutoCloseDelaySeconds") private var autoCloseDelay: Double = 5.0
    @AppStorage("menuAutoCloseEnabled") private var autoCloseEnabled: Bool = true
    @AppStorage("uiScale") var uiScale: UIScale = .regular
    @AppStorage("appearance.fontFamily") private var appearanceFontFamily: AppFontFamily = .system
    @AppStorage("appearance.baseFontSize") private var appearanceBaseFontSize: Double = 12.0
    @AppStorage("restoreHideAllApps") private var restoreHideAllApps: Bool = false
    @AppStorage(URLHandoffAnimationPreferences.storageKey)
    private var urlHandoffAnimationPreset: URLHandoffAnimationPreset = URLHandoffAnimationPreferences.defaultPreset
    @State private var workspaceDisplayScreens: [FullScreenInfo] = []
    @State private var ignoredDisplayPreferences: [IgnoredDisplayPreference] = WorkspaceDisplayTopology.loadIgnoredDisplays()
    @State private var cliStatus: DeskJigCLIInstaller.Status?
    @State private var cliActionInProgress = false
    @State private var cliMessage: String? = nil
    @State private var cliError: String? = nil
    @State private var claudeHookStatus: AgentHookInstaller.IntegrationStatus?
    @State private var claudeSkillStatus: AgentHookInstaller.IntegrationStatus?
    @State private var codexHookStatus: AgentHookInstaller.IntegrationStatus?
    @State private var codexSkillStatus: AgentHookInstaller.IntegrationStatus?

    @State private var claudeHookBusy = false
    @State private var claudeSkillBusy = false
    @State private var codexHookBusy = false
    @State private var codexSkillBusy = false

    @State private var claudeHookMessage: String? = nil
    @State private var claudeSkillMessage: String? = nil
    @State private var codexHookMessage: String? = nil
    @State private var codexSkillMessage: String? = nil

    @State private var claudeHookError: String? = nil
    @State private var claudeSkillError: String? = nil
    @State private var codexHookError: String? = nil
    @State private var codexSkillError: String? = nil

    var versionText: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] ?? "0.0.0"
        return "You have version \(version) installed."
    }

    // MARK: - Search Filtering

    /// Checks if a label matches the search query (case-insensitive)
    private func matchesSearch(_ label: String) -> Bool {
        searchQuery.isEmpty || label.localizedCaseInsensitiveContains(searchQuery)
    }

    // Section visibility based on search
    private var showAppearance: Bool {
        matchesSearch("Appearance") ||
        matchesSearch("Font") ||
        matchesSearch("Font Size")
    }

    private var showUIScale: Bool {
        matchesSearch("Interface Scale") || matchesSearch("UI Scale")
    }

    private var showKeyboardShortcuts: Bool {
        matchesSearch("Keyboard Shortcuts") ||
        matchesSearch("Open DeskJig") ||
        matchesSearch("Move left") ||
        matchesSearch("Move right") ||
        matchesSearch("Move to top") ||
        matchesSearch("Move to bottom") ||
        matchesSearch("Left half") ||
        matchesSearch("Right half") ||
        matchesSearch("Top half") ||
        matchesSearch("Bottom half") ||
        matchesSearch("Center") ||
        matchesSearch("Maximize") ||
        matchesSearch("Thirds") ||
        matchesSearch("Quarters") ||
        matchesSearch("Hide app") ||
        matchesSearch("Show all apps") ||
        matchesSearch("Visibility")
    }

    private var showMenuBehavior: Bool {
        matchesSearch("Menu Behavior") ||
        matchesSearch("Auto-Close Menu") ||
        matchesSearch("Auto-Close Delay")
    }

    private var showWorkspaceRestoration: Bool {
        matchesSearch("Workspace Restoration") ||
        matchesSearch("Hide all apps before restore") ||
        matchesSearch("Ignored Displays") ||
        matchesSearch("Quick Switch")
    }

    private var showAppUpdates: Bool {
        matchesSearch("App Updates") ||
        matchesSearch("Check for Updates") ||
        matchesSearch("updates automatically")
    }

    private var showPermissions: Bool {
        matchesSearch("Permissions") ||
        matchesSearch("Accessibility")
    }

    private var showLogging: Bool {
        matchesSearch("Logging") ||
        matchesSearch("Logs") ||
        matchesSearch("Application Logs") ||
        matchesSearch("Diagnostic Logs")
    }

    private var showDeskJigCLI: Bool {
        // Hidden: this section used to live behind the Add-ons pane, which DeskJig
        // does not ship. The controls below are kept intact so CLI configuration can
        // be re-exposed once it has a new home in the settings tree.
        false
    }

    private var showAgentIntegrations: Bool {
        matchesSearch("Agent Integrations") ||
        matchesSearch("Claude") ||
        matchesSearch("Codex") ||
        matchesSearch("hooks") ||
        matchesSearch("notify") ||
        matchesSearch("url") ||
        matchesSearch("localhost") ||
        matchesSearch("URL handoff") ||
        matchesSearch("animation") ||
        matchesSearch("preset") ||
        matchesSearch("linear") ||
        matchesSearch("cubic") ||
        matchesSearch("ease")
    }

    private var hasNoResults: Bool {
        guard !searchQuery.isEmpty else { return false }

        let baseCondition = !showAppearance &&
            !showUIScale &&
            !showKeyboardShortcuts &&
            !showMenuBehavior &&
            !showWorkspaceRestoration &&
            !showAppUpdates &&
            !showPermissions &&
            !showLogging &&
            !showDeskJigCLI &&
            !showAgentIntegrations
        return baseCondition
    }

    private var cliStatusLabel: (text: String, icon: String, color: Color) {
        guard let cliStatus else {
            return ("Checking…", "arrow.clockwise", DesignTokens.Text.tertiary)
        }
        if cliStatus.isInstalled {
            return ("Installed", "checkmark.circle.fill", DesignTokens.Status.success)
        }
        return ("Not installed", "exclamationmark.triangle.fill", DesignTokens.Status.warning)
    }

    private var cliStatusDetail: String? {
        guard let cliStatus else { return nil }
        if cliStatus.isInstalled {
            return cliStatus.isUpToDate ? "Up to date" : "Update available"
        }
        return "Install to enable CLI access"
    }

    private var cliResolvedPath: String? {
        guard let cliStatus else { return nil }
        guard cliStatus.isInstalled else { return nil }
        return cliStatus.symlinkTarget ?? cliStatus.installPath
    }

    private var cliInstallButtonTitle: String {
        guard let cliStatus else { return "Install" }
        if cliStatus.isInstalled {
            return cliStatus.isUpToDate ? "Reinstall" : "Update"
        }
        return "Install"
    }

    private var shouldShowCLIUpdateBadge: Bool {
        guard let cliStatus else { return false }
        return cliStatus.isInstalled && !cliStatus.isUpToDate
    }

    private func integrationStatusLabel(for status: AgentHookInstaller.IntegrationStatus?) -> (text: String, icon: String, color: Color) {
        guard let status else {
            return ("Checking…", "arrow.clockwise", DesignTokens.Text.tertiary)
        }
        if status.hasError {
            return ("Error", "exclamationmark.triangle.fill", DesignTokens.Status.error)
        }
        if status.isInstalled && status.isUpToDate {
            return ("Installed", "checkmark.circle.fill", DesignTokens.Status.success)
        }
        if status.isInstalled && !status.isUpToDate {
            return ("Update available", "arrow.triangle.2.circlepath.circle.fill", DesignTokens.Status.warning)
        }
        return ("Not installed", "exclamationmark.triangle.fill", DesignTokens.Status.warning)
    }

    private func integrationStatusDetail(for status: AgentHookInstaller.IntegrationStatus?) -> String? {
        guard let status else { return nil }
        if let error = status.error {
            return error
        }
        if status.isInstalled && status.isUpToDate {
            return "Up to date"
        }
        if status.isInstalled && !status.isUpToDate {
            return "DeskJig-managed integration is stale"
        }
        return "Install to enable DeskJig quick-switch attention routing"
    }

    private func integrationRow(
        title: String,
        status: AgentHookInstaller.IntegrationStatus?,
        busy: Bool,
        message: String?,
        error: String?,
        onInstall: @escaping () -> Void,
        onRemove: @escaping () -> Void
    ) -> DSIntegrationRow {
        let label = integrationStatusLabel(for: status)
        return DSIntegrationRow(
            title: title,
            statusText: label.text,
            statusIcon: label.icon,
            statusColor: label.color,
            statusDetail: integrationStatusDetail(for: status),
            installPath: status?.installPath,
            isInstalled: status?.isInstalled == true,
            busy: busy,
            message: message,
            error: error,
            onInstall: onInstall,
            onRemove: onRemove
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            // No Results State
            if hasNoResults {
                VStack(spacing: 8) {
                    Text("No settings found")
                        .font(brand: .body2)
                        .foregroundStyle(DesignTokens.Text.secondary)
                    Text("Try a different search term")
                        .font(brand: .body4)
                        .foregroundStyle(DesignTokens.Text.tertiary)
                }
                .frame(width: 800, height: 200)
            }

            // Appearance Section
            if showAppearance {
                SettingsSection("Appearance") {
                    SettingsRow("Font Family") {
                        DSPicker(
                            options: AppFontFamily.allCases,
                            selection: $appearanceFontFamily,
                            labelText: { $0.description }
                        )
                    }

                    SettingsRow("Base Font Size") {
                        SettingsSlider(
                            value: $appearanceBaseFontSize,
                            range: 10.0...16.0,
                            step: 1.0,
                            unit: " pt",
                            sliderWidth: 160,
                            valueWidth: 60,
                            formatDecimals: 0
                        )
                    }
                }
            }

            // UI Scale Section
            if showUIScale {
                SettingsSection("UI Scale") {
                    SettingsRow("Interface Scale") {
                        DSPicker(
                            options: UIScale.allCases.map { $0 },
                            selection: $uiScale,
                            labelText: { $0.description }
                        )
                    }
                }
            }

            // Keyboard Shortcuts Section
            if showKeyboardShortcuts {
                SettingsSection("Keyboard Shortcuts") {
                    // Primary shortcuts
                    ShortcutSectionHeader(title: "Primary")
                    HotkeyRecorderView(title: "Open DeskJig:", name: .showWorkspaceView)

                    // Layout Helpers
                    ShortcutSectionHeader(title: "Layout Helpers", topPadding: 8)
                    HotkeyRecorderView(title: "Move left:", name: .moveWindowLeft)
                    HotkeyRecorderView(title: "Move right:", name: .moveWindowRight)
                    HotkeyRecorderView(title: "Move to top:", name: .moveWindowUp)
                    HotkeyRecorderView(title: "Move to bottom:", name: .moveWindowDown)
                    HotkeyRecorderView(title: "Left half:", name: .moveWindowToLeftHalf)
                    HotkeyRecorderView(title: "Right half:", name: .moveWindowToRightHalf)
                    HotkeyRecorderView(title: "Top half:", name: .moveWindowToTopHalf)
                    HotkeyRecorderView(title: "Bottom half:", name: .moveWindowToBottomHalf)
                    HotkeyRecorderView(title: "Center:", name: .centerWindow)
                    HotkeyRecorderView(title: "Maximize:", name: .maximizeWindow)

                    // Thirds (collapsible)
                    SettingsDisclosureGroup("Thirds", isExpanded: $isThirdsExpanded) {
                        HotkeyRecorderView(title: "Left third:", name: .moveWindowToLeftThird)
                        HotkeyRecorderView(title: "Center third:", name: .moveWindowToCenterThird)
                        HotkeyRecorderView(title: "Right third:", name: .moveWindowToRightThird)
                    }

                    // Quarters (collapsible)
                    SettingsDisclosureGroup("Quarters", isExpanded: $isQuartersExpanded) {
                        HotkeyRecorderView(title: "Top left:", name: .moveWindowToTopLeftQuarter)
                        HotkeyRecorderView(title: "Top right:", name: .moveWindowToTopRightQuarter)
                        HotkeyRecorderView(title: "Bottom left:", name: .moveWindowToBottomLeftQuarter)
                        HotkeyRecorderView(title: "Bottom right:", name: .moveWindowToBottomRightQuarter)
                    }

                    // Visibility
                    ShortcutSectionHeader(title: "Visibility", topPadding: 8)
                    HotkeyRecorderView(title: "Hide app:", name: .hideApp)
                    HotkeyRecorderView(title: "Hide all apps:", name: .hideAllApps)
                    HotkeyRecorderView(title: "Show all apps:", name: .showAllApps)
                }
            }

            // Menu Behavior Section
            if showMenuBehavior {
                SettingsSection("Menu Behavior") {
                    VStack(alignment: .leading, spacing: 16) {
                        SettingsToggle(
                            title: "Auto-Close Menu",
                            subtitle: "Automatically close the menu after a period of inactivity",
                            isOn: $autoCloseEnabled
                        )

                        Divider()
                            .background(DesignTokens.Border.subtle)

                        SettingsRowVertical(
                            "Auto-Close Delay",
                            subtitle: "Seconds of inactivity before the menu automatically closes"
                        ) {
                            SettingsSlider(
                                value: $autoCloseDelay,
                                range: 1.0...10.0,
                                step: 0.5,
                                unit: "s"
                            )
                        }
                        .opacity(autoCloseEnabled ? 1.0 : 0.5)
                        .disabled(!autoCloseEnabled)

                        HStack(spacing: 4) {
                            Image(systemName: "info.circle")
                                .font(.system(size: DesignTokens.IconSize.small, weight: .medium))
                            Text("Menu will close after this delay when no clicking or hovering occurs")
                        }
                        .font(brand: .body4)
                        .foregroundStyle(DesignTokens.Text.tertiary)
                    }
                }
            }

            // Workspace Restoration Section
            if showWorkspaceRestoration {
                SettingsSection("Workspace Restoration") {
                    SettingsToggle(
                        title: "Hide all apps before restore",
                        subtitle: "Temporarily hide all apps to reduce window overlap during restore",
                        isOn: $restoreHideAllApps
                    )

                    Divider()
                        .background(DesignTokens.Border.subtle)

                    SettingsRowVertical(
                        "Ignored Displays",
                        subtitle: "Ignored displays are excluded from workspace restore, Quick Switch, and future workspace saves."
                    ) {
                        ignoredDisplaysView
                    }
                }
            }

            // App Updates Section
            if showAppUpdates {
                SettingsSection("App Updates") {
                    VStack(alignment: .leading, spacing: 16) {
                        SettingsRow("Check for Updates") {
                            Button("Check Now") {
                                appUpdateController.checkForUpdates()
                            }
                            .buttonStyle(.dsAccent(size: .small))
                            .disabled(!appUpdateController.canCheckForUpdates)
                        }

                        Divider()
                            .background(DesignTokens.Border.subtle)

                        Text("DeskJig checks for updates automatically once per day.")
                            .font(brand: .body4)
                            .foregroundStyle(DesignTokens.Text.tertiary)

                        Text(versionText)
                            .font(brand: .body4)
                            .foregroundStyle(DesignTokens.Text.tertiary)
                    }
                }
            }

            // App Permissions Section
            if showPermissions {
                SettingsSection("App Permissions") {
                    ForEach(SettingsPane.allCases, id: \.self) { setting in
                        permissionSection(for: setting)
                    }
                }
            }

            // Logging Section
            if showLogging {
                SettingsSection("Logging") {
                    VStack(alignment: .leading, spacing: 12) {
                        SettingsRow("Application Logs") {
                            Button {
                                openLogsFolder()
                            } label: {
                                HStack(spacing: 6) {
                                    Image(systemName: "folder")
                                        .font(.system(size: DesignTokens.IconSize.small, weight: .medium))
                                    Text("Open Logs Folder")
                                }
                            }
                            .buttonStyle(.dsSecondary(size: .small))
                        }

                        VStack(alignment: .leading, spacing: 4) {
                            Text("Log Information")
                                .font(brand: .h6)
                                .foregroundStyle(DesignTokens.Text.secondary)
                            Text("Files rotate every 24 hours. Up to 7 days of logs are kept.")
                                .font(brand: .body4)
                                .foregroundStyle(DesignTokens.Text.tertiary)
                        }
                    }
                }
            }

            // DeskJig CLI Section
            if showDeskJigCLI {
                SettingsSection(
                    "DeskJig CLI",
                    badgeText: "Beta",
                    subtitle: "A command-line companion to DeskJig for organizing your desktop, managing workspaces, and controlling windows from the terminal."
                ) {
                    SettingsRow("Status", controlWidth: 320) {
                        VStack(alignment: .trailing, spacing: 4) {
                            DSStatusLabel(
                                text: cliStatusLabel.text,
                                systemIcon: cliStatusLabel.icon,
                                color: cliStatusLabel.color
                            )

                            if let statusDetail = cliStatusDetail {
                                Text(statusDetail)
                                    .font(brand: .body4)
                                    .foregroundStyle(DesignTokens.Text.tertiary)
                            }

                            if let path = cliResolvedPath {
                                Text("Path: \(path)")
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundStyle(DesignTokens.Text.tertiary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                        }
                    }

                    SettingsRow("Install / Update") {
                        Button {
                            runCLIInstall()
                        } label: {
                            if cliActionInProgress {
                                ProgressView()
                                    .progressViewStyle(.circular)
                                    .scaleEffect(0.8)
                            } else {
                                Text(cliInstallButtonTitle)
                            }
                        }
                        .buttonStyle(.dsAccent(size: .small))
                        .disabled(cliActionInProgress)
                    }

                    if shouldShowCLIUpdateBadge {
                        SettingsRow("Update Available") {
                            UpdateBadge(
                                text: "New Update",
                                color: DesignTokens.Status.success,
                                isActive: !cliActionInProgress
                            ) {
                                runCLIInstall()
                            }
                        }
                    }

                    #if DEBUG
                    if cliStatus?.isInstalled == true {
                        SettingsRow("Reset") {
                            Button("Remove Symlink") {
                                runCLIReset()
                            }
                            .buttonStyle(.dsSecondary(size: .small, foreground: DesignTokens.Status.error))
                            .disabled(cliActionInProgress)
                        }
                    }
                    #endif

                    if let cliMessage {
                        HStack(spacing: 6) {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: DesignTokens.IconSize.small, weight: .medium))
                            Text(cliMessage)
                                .font(brand: .body4)
                        }
                        .foregroundStyle(DesignTokens.Status.success)
                    }

                    if let cliError {
                        HStack(spacing: 6) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.system(size: DesignTokens.IconSize.small, weight: .medium))
                            Text(cliError)
                                .font(brand: .body4)
                        }
                        .foregroundStyle(DesignTokens.Status.error)
                    }

                    Text("Requires macOS administrator credentials.")
                        .font(brand: .body4)
                        .foregroundStyle(DesignTokens.Text.tertiary)
                }
                .onAppear {
                    refreshCLIStatus()
                }
            }

            if showAgentIntegrations {
                SettingsSection(
                    "Agent Integrations",
                    badgeText: "Beta",
                    subtitle: "Install hooks and skills so coding agents like Claude Code and Codex can notify you when they need attention, load a workspace, or slide in a URL preview without disturbing your current layout."
                ) {
                    SettingsRow("URL Handoff Animation") {
                        DSPicker(
                            options: URLHandoffAnimationPreset.allCases,
                            selection: $urlHandoffAnimationPreset,
                            labelText: { $0.settingsLabel }
                        )
                    }

                    Divider()
                        .background(DesignTokens.Border.subtle)

                    SettingsSubSection("Claude Code") {
                        integrationRow(
                            title: "Stop Hook",
                            status: claudeHookStatus,
                            busy: claudeHookBusy,
                            message: claudeHookMessage,
                            error: claudeHookError,
                            onInstall: { runClaudeHookInstall() },
                            onRemove: { runClaudeHookRemove() }
                        )

                        Divider()
                            .background(DesignTokens.Border.subtle)

                        integrationRow(
                            title: "Skill",
                            status: claudeSkillStatus,
                            busy: claudeSkillBusy,
                            message: claudeSkillMessage,
                            error: claudeSkillError,
                            onInstall: { runClaudeSkillInstall() },
                            onRemove: { runClaudeSkillRemove() }
                        )
                    }

                    SettingsSubSection("Codex") {
                        integrationRow(
                            title: "Notify Hook",
                            status: codexHookStatus,
                            busy: codexHookBusy,
                            message: codexHookMessage,
                            error: codexHookError,
                            onInstall: { runCodexHookInstall() },
                            onRemove: { runCodexHookRemove() }
                        )

                        Divider()
                            .background(DesignTokens.Border.subtle)

                        integrationRow(
                            title: "Skill",
                            status: codexSkillStatus,
                            busy: codexSkillBusy,
                            message: codexSkillMessage,
                            error: codexSkillError,
                            onInstall: { runCodexSkillInstall() },
                            onRemove: { runCodexSkillRemove() }
                        )
                    }

                }
                .onAppear {
                    refreshAgentHookStatuses()
                }
            }

        }
        .onAppear {
            DeskJigLog.info(.app, "[SettingsScreen] Appeared")
            refreshWorkspaceDisplayPreferences()
        }
        // Track setting changes in the local log
        .onChange(of: uiScale) { oldValue, newValue in
            DeskJigLog.info(.app, "Setting changed", fields: ["setting": "ui_scale", "value": newValue.rawValue, "previousValue": oldValue.rawValue])
        }
        .onChange(of: autoCloseEnabled) { oldValue, newValue in
            DeskJigLog.info(.app, "Setting changed", fields: ["setting": "autoclose", "value": "\(newValue)", "previousValue": "\(oldValue)"])
        }
        .onChange(of: autoCloseDelay) { oldValue, newValue in
            DeskJigLog.info(.app, "Setting changed", fields: ["setting": "autoclose_delay", "value": "\(newValue)", "previousValue": "\(oldValue)"])
        }
    }

    private var ignoredDisplaysView: some View {
        VStack(alignment: .leading, spacing: 10) {
            if workspaceDisplayScreens.isEmpty {
                Text("No displays detected.")
                    .font(brand: .body4)
                    .foregroundStyle(DesignTokens.Text.tertiary)
            } else {
                ForEach(workspaceDisplayScreens, id: \.displayFingerprint.persistentIdentifier) { screen in
                    Toggle(isOn: ignoredDisplayBinding(for: screen)) {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 8) {
                                Text(screen.name)
                                    .font(brand: .body3)
                                    .foregroundStyle(DesignTokens.Text.primary)

                                if screen.isPrimary {
                                    DSTag(
                                        label: "Primary",
                                        color: DesignTokens.Status.info,
                                        size: .small
                                    )
                                }
                            }

                            Text(ignoredDisplaySubtitle(for: screen))
                                .font(brand: .body4)
                                .foregroundStyle(DesignTokens.Text.tertiary)
                        }
                    }
                    .toggleStyle(.switch)
                    .tint(DesignTokens.Brand.accent)
                }
            }
        }
    }

    private func refreshWorkspaceDisplayPreferences() {
        windowManager.displayManager.refreshScreens()
        workspaceDisplayScreens = windowManager.displayManager.screens
        ignoredDisplayPreferences = WorkspaceDisplayTopology.loadIgnoredDisplays()
    }

    private func ignoredDisplayBinding(for screen: FullScreenInfo) -> Binding<Bool> {
        Binding(
            get: {
                WorkspaceDisplayTopology.isIgnored(screen, ignoredDisplays: ignoredDisplayPreferences)
            },
            set: { isIgnored in
                if isIgnored {
                    guard !WorkspaceDisplayTopology.isIgnored(screen, ignoredDisplays: ignoredDisplayPreferences) else { return }
                    ignoredDisplayPreferences.append(IgnoredDisplayPreference(screen: screen))
                } else {
                    ignoredDisplayPreferences.removeAll { $0.matches(screen) }
                }
                WorkspaceDisplayTopology.saveIgnoredDisplays(ignoredDisplayPreferences)
            }
        )
    }

    private func ignoredDisplaySubtitle(for screen: FullScreenInfo) -> String {
        let serialDescription = screen.serialNumber.map(String.init) ?? "n/a"
        return "Display ID \(screen.displayID) · \(Int(screen.resolution.width))x\(Int(screen.resolution.height)) · vendor \(screen.vendorID) model \(screen.modelNumber) serial \(serialDescription)"
    }

    /// Creates a section for a given Setting pane
    func permissionSection(for setting: SettingsPane) -> some View {
        SettingsRow(setting.name) {
            HStack(spacing: 12) {
                // Permission status
                if setting == .accessibility {
                    if windowManager.hasAccessibilityPermissions {
                        DSStatusLabel(
                            text: "Granted",
                            systemIcon: "checkmark.circle.fill",
                            color: DesignTokens.Status.success
                        )
                    } else {
                        DSStatusLabel(
                            text: "Not Granted",
                            systemIcon: "exclamationmark.triangle.fill",
                            color: DesignTokens.Status.error
                        )
                    }
                }

                Button {
                    windowManager.openSystemSettings(to: setting)
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.up.right.square")
                            .font(.system(size: DesignTokens.IconSize.small, weight: .medium))
                        Text("Open Settings")
                    }
                }
                .buttonStyle(.dsSecondary(size: .small))
            }
        }
    }
}

// MARK: - Functions

extension SettingsScreen {

    private func openLogsFolder() {
        // Get the default file logger to access its log directory
        let fileLogger = DDFileLogger()
        let logsDirectory = fileLogger.logFileManager.logsDirectory

        DeskJigLog.info(.app, "Opening logs folder", fields: ["path": logsDirectory])

        // Ensure the directory exists
        let fileManager = FileManager.default
        if !fileManager.fileExists(atPath: logsDirectory) {
            DeskJigLog.warn(.app, "Logs directory does not exist, creating", fields: ["path": logsDirectory])
            do {
                try fileManager.createDirectory(atPath: logsDirectory, withIntermediateDirectories: true)
            } catch {
                DeskJigLog.error(.app, "Failed to create logs directory", fields: ["error": "\(error)"])
                return
            }
        }

        // Open the logs directory in Finder
        let success = NSWorkspace.shared.open(URL(fileURLWithPath: logsDirectory))
        if success {
            DeskJigLog.info(.app, "Successfully opened logs folder in Finder")
        } else {
            DeskJigLog.error(.app, "Failed to open logs folder in Finder")
        }
    }

    private func refreshCLIStatus() {
        Task.detached(priority: .userInitiated) {
            let status = DeskJigCLIInstaller.status()
            await MainActor.run {
                cliStatus = status
            }
        }
    }

    private func refreshAgentHookStatuses() {
        Task.detached(priority: .userInitiated) {
            let status = AgentHookInstaller.status()
            await MainActor.run {
                claudeHookStatus = status.claudeHook
                claudeSkillStatus = status.claudeSkill
                codexHookStatus = status.codexHook
                codexSkillStatus = status.codexSkill
            }
        }
    }

    private func runCLIInstall() {
        guard !cliActionInProgress else { return }
        cliActionInProgress = true
        cliMessage = nil
        cliError = nil

        Task {
            let result = await DeskJigCLIInstaller.install()
            await MainActor.run {
                cliStatus = result.status
                cliMessage = result.message
                cliError = result.error
                cliActionInProgress = false
            }
        }
    }

    private func runClaudeHookInstall() {
        guard !claudeHookBusy else { return }
        claudeHookBusy = true
        claudeHookMessage = nil
        claudeHookError = nil

        Task {
            let result = await AgentHookInstaller.installClaudeHook()
            await MainActor.run {
                claudeHookStatus = result.status
                claudeHookMessage = result.message
                claudeHookError = result.error
                claudeHookBusy = false
            }
        }
    }

    private func runClaudeHookRemove() {
        guard !claudeHookBusy else { return }
        claudeHookBusy = true
        claudeHookMessage = nil
        claudeHookError = nil

        Task {
            let result = await AgentHookInstaller.removeClaudeHook()
            await MainActor.run {
                claudeHookStatus = result.status
                claudeHookMessage = result.message
                claudeHookError = result.error
                claudeHookBusy = false
            }
        }
    }

    private func runClaudeSkillInstall() {
        guard !claudeSkillBusy else { return }
        claudeSkillBusy = true
        claudeSkillMessage = nil
        claudeSkillError = nil

        Task {
            let result = await AgentHookInstaller.installClaudeSkill()
            await MainActor.run {
                claudeSkillStatus = result.status
                claudeSkillMessage = result.message
                claudeSkillError = result.error
                claudeSkillBusy = false
            }
        }
    }

    private func runClaudeSkillRemove() {
        guard !claudeSkillBusy else { return }
        claudeSkillBusy = true
        claudeSkillMessage = nil
        claudeSkillError = nil

        Task {
            let result = await AgentHookInstaller.removeClaudeSkill()
            await MainActor.run {
                claudeSkillStatus = result.status
                claudeSkillMessage = result.message
                claudeSkillError = result.error
                claudeSkillBusy = false
            }
        }
    }

    private func runCodexHookInstall() {
        guard !codexHookBusy else { return }
        codexHookBusy = true
        codexHookMessage = nil
        codexHookError = nil

        Task {
            let result = await AgentHookInstaller.installCodexHook()
            await MainActor.run {
                codexHookStatus = result.status
                codexHookMessage = result.message
                codexHookError = result.error
                codexHookBusy = false
            }
        }
    }

    private func runCodexHookRemove() {
        guard !codexHookBusy else { return }
        codexHookBusy = true
        codexHookMessage = nil
        codexHookError = nil

        Task {
            let result = await AgentHookInstaller.removeCodexHook()
            await MainActor.run {
                codexHookStatus = result.status
                codexHookMessage = result.message
                codexHookError = result.error
                codexHookBusy = false
            }
        }
    }

    private func runCodexSkillInstall() {
        guard !codexSkillBusy else { return }
        codexSkillBusy = true
        codexSkillMessage = nil
        codexSkillError = nil

        Task {
            let result = await AgentHookInstaller.installCodexSkill()
            await MainActor.run {
                codexSkillStatus = result.status
                codexSkillMessage = result.message
                codexSkillError = result.error
                codexSkillBusy = false
            }
        }
    }

    private func runCodexSkillRemove() {
        guard !codexSkillBusy else { return }
        codexSkillBusy = true
        codexSkillMessage = nil
        codexSkillError = nil

        Task {
            let result = await AgentHookInstaller.removeCodexSkill()
            await MainActor.run {
                codexSkillStatus = result.status
                codexSkillMessage = result.message
                codexSkillError = result.error
                codexSkillBusy = false
            }
        }
    }

    #if DEBUG
    private func runCLIReset() {
        guard !cliActionInProgress else { return }
        cliActionInProgress = true
        cliMessage = nil
        cliError = nil

        Task {
            let result = await DeskJigCLIInstaller.resetInstall()
            await MainActor.run {
                cliStatus = result.status
                cliMessage = result.message
                cliError = result.error
                cliActionInProgress = false
            }
        }
    }
    #endif
}

// MARK: - Extensions


extension SettingsPane {

    var name: String {
        switch self {
        case .accessibility: "Accessibility"
        }
    }

    var iconName: String {
        switch self {
        case .accessibility: "accessibility"
        }
    }
}

#Preview {
    @Previewable @State var searchQuery = ""

    SettingsScreen(searchQuery: $searchQuery)
        .environmentObject(SparkleController())
        .environmentObject(WindowManager())
}
