//
//  DSAppConfigCard.swift
//  DeskJig
//
//  Created by Claude Code on 02/02/26.
//

import SwiftUI
import DeskJigShared

/// App configuration modes for DSAppConfigCard
enum DSAppConfigMode: String {
    case chromeProfile = "Chrome Profile"
    case openByPath = "Open by Path"
    case standard = "Standard"

    var description: String {
        switch self {
        case .chromeProfile:
            return "Restore specific Chrome profile and tabs"
        case .openByPath:
            return "Open app at a specific file or directory"
        case .standard:
            return "Standard app restoration"
        }
    }
}

/// A composed card component for app configuration panels.
///
/// Features:
/// - Header with app icon, name, and mode indicator
/// - Mode-specific content (Chrome profile picker, folder path, or standard info)
/// - Uses existing DS components (DSSelect, DSFolderPicker, SettingsToggle)
///
/// Usage:
/// ```swift
/// // Chrome Profile mode
/// DSAppConfigCard(
///     mode: .chromeProfile,
///     appName: "Google Chrome",
///     bundleId: "com.google.Chrome",
///     chromeProfile: $selectedProfile,
///     shouldRestoreTabs: $restoreTabs,
///     tabs: ["Tab 1", "Tab 2"]
/// )
///
/// // Open-by-Path mode
/// DSAppConfigCard(
///     mode: .openByPath,
///     appName: "VS Code",
///     bundleId: "com.microsoft.VSCode",
///     path: $projectPath,
///     pathVerificationStatus: .verified
/// )
/// ```
struct DSAppConfigCard: View {
    let mode: DSAppConfigMode
    let appName: String
    let bundleId: String
    var icon: String = "app.fill"

    // Chrome Profile mode bindings
    @Binding var chromeProfile: String?
    @Binding var shouldRestoreTabs: Bool
    var chromeProfiles: [DSSelectOption<String>] = []
    var tabs: [String] = []

    // Open-by-Path mode bindings
    @Binding var path: String
    var pathVerificationStatus: DSFolderVerificationStatus = .none
    var onVerifyPath: ((String) -> Void)? = nil

    // State for tabs disclosure
    @State private var isTabsExpanded: Bool = false

    var body: some View {
        DSCard(style: .config) {
            VStack(alignment: .leading, spacing: 0) {
                // Header
                DSCardHeader(
                    icon: icon,
                    title: appName,
                    subtitle: mode.rawValue
                )
                .padding(DesignTokens.Card.padding)

                // Divider
                Divider()
                    .background(DesignTokens.Border.subtle)

                // Mode-specific content
                VStack(alignment: .leading, spacing: DesignTokens.Spacing.gapMedium) {
                    switch mode {
                    case .chromeProfile:
                        chromeProfileContent
                    case .openByPath:
                        openByPathContent
                    case .standard:
                        standardContent
                    }
                }
                .padding(DesignTokens.Card.padding)
            }
        }
    }

    // MARK: - Mode-specific content views

    @ViewBuilder
    private var chromeProfileContent: some View {
        // Profile selector
        DSFormField(label: "Profile") {
            DSSelect(
                options: chromeProfiles,
                selection: $chromeProfile,
                placeholder: "Select profile..."
            )
        }

        // Restore tabs toggle
        SettingsToggle(
            title: "Restore Tabs",
            subtitle: "Reopen previously saved tabs when restoring this app",
            isOn: $shouldRestoreTabs
        )

        // Tabs list (expandable)
        if !tabs.isEmpty {
            DisclosureGroup(isExpanded: $isTabsExpanded) {
                VStack(alignment: .leading, spacing: DesignTokens.Spacing.gapSmall) {
                    ForEach(tabs, id: \.self) { tab in
                        HStack(spacing: DesignTokens.Spacing.gapSmall) {
                            Image(systemName: "globe")
                                .font(.system(size: DesignTokens.IconSize.small))
                                .foregroundStyle(DesignTokens.Text.tertiary)
                            Text(tab)
                                .font(brand: .body4)
                                .foregroundStyle(DesignTokens.Text.secondary)
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }
                    }
                }
                .padding(.top, DesignTokens.Spacing.gapSmall)
            } label: {
                HStack(spacing: DesignTokens.Spacing.gapSmall) {
                    Text("Saved Tabs")
                        .font(brand: .label3)
                        .foregroundStyle(DesignTokens.Text.secondary)
                    Text("(\(tabs.count))")
                        .font(brand: .body4)
                        .foregroundStyle(DesignTokens.Text.tertiary)
                }
            }
            .tint(DesignTokens.Text.secondary)
        }
    }

    @ViewBuilder
    private var openByPathContent: some View {
        DSFormField(
            label: "Path",
            subtitle: "The file or directory to open with this app"
        ) {
            DSFolderPicker(
                path: $path,
                placeholder: "/path/to/project",
                verificationStatus: pathVerificationStatus,
                onVerify: onVerifyPath
            )
        }
    }

    @ViewBuilder
    private var standardContent: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.gapSmall) {
            HStack(spacing: DesignTokens.Spacing.gapSmall) {
                Text("Bundle ID:")
                    .font(brand: .body3)
                    .foregroundStyle(DesignTokens.Text.tertiary)
                Text(bundleId)
                    .font(brand: .body3)
                    .foregroundStyle(DesignTokens.Text.secondary)
            }

            Text(mode.description)
                .font(brand: .body4)
                .foregroundStyle(DesignTokens.Text.muted)
        }
    }
}

// MARK: - Convenience initializers

extension DSAppConfigCard {
    /// Initialize for Chrome Profile mode
    init(
        appName: String,
        bundleId: String,
        icon: String = "globe",
        chromeProfile: Binding<String?>,
        shouldRestoreTabs: Binding<Bool>,
        chromeProfiles: [DSSelectOption<String>] = [],
        tabs: [String] = []
    ) {
        self.mode = .chromeProfile
        self.appName = appName
        self.bundleId = bundleId
        self.icon = icon
        self._chromeProfile = chromeProfile
        self._shouldRestoreTabs = shouldRestoreTabs
        self.chromeProfiles = chromeProfiles
        self.tabs = tabs
        self._path = .constant("")
        self.pathVerificationStatus = .none
        self.onVerifyPath = nil
    }

    /// Initialize for Open-by-Path mode
    init(
        appName: String,
        bundleId: String,
        icon: String = "folder",
        path: Binding<String>,
        pathVerificationStatus: DSFolderVerificationStatus = .none,
        onVerifyPath: ((String) -> Void)? = nil
    ) {
        self.mode = .openByPath
        self.appName = appName
        self.bundleId = bundleId
        self.icon = icon
        self._chromeProfile = .constant(nil)
        self._shouldRestoreTabs = .constant(false)
        self.chromeProfiles = []
        self.tabs = []
        self._path = path
        self.pathVerificationStatus = pathVerificationStatus
        self.onVerifyPath = onVerifyPath
    }

    /// Initialize for Standard mode
    init(
        appName: String,
        bundleId: String,
        icon: String = "app.fill"
    ) {
        self.mode = .standard
        self.appName = appName
        self.bundleId = bundleId
        self.icon = icon
        self._chromeProfile = .constant(nil)
        self._shouldRestoreTabs = .constant(false)
        self.chromeProfiles = []
        self.tabs = []
        self._path = .constant("")
        self.pathVerificationStatus = .none
        self.onVerifyPath = nil
    }
}

#Preview {
    ScrollView {
        VStack(alignment: .leading, spacing: 24) {
            Text("App Config Cards")
                .font(brand: .h4)
                .foregroundStyle(DesignTokens.Text.primary)

            // Chrome Profile mode
            VStack(alignment: .leading, spacing: 8) {
                Text("Chrome Profile Mode")
                    .font(brand: .body3)
                    .foregroundStyle(DesignTokens.Text.secondary)

                DSAppConfigCard(
                    appName: "Google Chrome",
                    bundleId: "com.google.Chrome",
                    icon: "globe",
                    chromeProfile: .constant("Default"),
                    shouldRestoreTabs: .constant(true),
                    chromeProfiles: [
                        DSSelectOption(id: "Default", label: "Default"),
                        DSSelectOption(id: "Work", label: "Work"),
                        DSSelectOption(id: "Personal", label: "Personal")
                    ],
                    tabs: [
                        "GitHub - Pull Requests",
                        "Stack Overflow - Swift Question",
                        "Apple Developer Documentation"
                    ]
                )
            }

            // Open-by-Path mode
            VStack(alignment: .leading, spacing: 8) {
                Text("Open by Path Mode")
                    .font(brand: .body3)
                    .foregroundStyle(DesignTokens.Text.secondary)

                DSAppConfigCard(
                    appName: "VS Code",
                    bundleId: "com.microsoft.VSCode",
                    icon: "chevron.left.forwardslash.chevron.right",
                    path: .constant("/Users/developer/projects/myapp"),
                    pathVerificationStatus: .verified
                )
            }

            // Standard mode
            VStack(alignment: .leading, spacing: 8) {
                Text("Standard Mode")
                    .font(brand: .body3)
                    .foregroundStyle(DesignTokens.Text.secondary)

                DSAppConfigCard(
                    appName: "Slack",
                    bundleId: "com.tinyspeck.slackmacgap",
                    icon: "message"
                )
            }
        }
        .padding(32)
    }
    .frame(width: 500, height: 800)
    .background(Color.black.opacity(0.9))
}
