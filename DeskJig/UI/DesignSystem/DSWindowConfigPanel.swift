//
//  DSWindowConfigPanel.swift
//  DeskJig
//
//  Created by Claude Code on 02/02/26.
//

import SwiftUI
import AppKit
import DeskJigShared

/// An inline config panel for selected windows in workspace edit mode.
/// Routes to the appropriate config panel based on app type:
/// - Chrome: Shows profile selector, tabs management
/// - Terminal/IDE: Shows directory path picker
/// - Standard: Shows basic app info
struct DSWindowConfigPanel: View {
    let window: DSPreviewWindow

    // Path config bindings (for terminal/IDE)
    @Binding var directoryPath: String
    var pathVerificationStatus: DSFolderVerificationStatus = .none
    var onVerifyPath: ((String) -> Void)?
    var onClearPath: (() -> Void)?
    var onApplyPathToAll: (() -> Void)?
    var onPathFocusChange: ((Bool) -> Void)?

    // Chrome config bindings
    @Binding var chromeProfile: String?
    @Binding var shouldRestoreTabs: Bool
    @Binding var chromeTabs: [String]
    var chromeProfiles: [DSSelectOption<String>] = []
    /// Async callback for loading tabs. Return true on success, false on failure.
    var onLoadTabs: (() async -> Bool)?
    var onAddTab: ((String) -> Void)?
    var onRemoveTab: ((Int) -> Void)?

    // Common
    var onDismiss: (() -> Void)?

    var body: some View {
        switch window.specialAppType {
        case .chrome:
            DSChromeConfigPanel(
                window: window,
                selectedProfile: $chromeProfile,
                shouldRestoreTabs: $shouldRestoreTabs,
                tabs: $chromeTabs,
                profiles: chromeProfiles,
                onLoadTabs: onLoadTabs,
                onAddTab: onAddTab,
                onRemoveTab: onRemoveTab,
                onDismiss: onDismiss
            )
        case .terminal, .ide:
            pathConfigPanel
        case .none:
            standardAppPanel
        }
    }

    // MARK: - Path Config Panel (Terminal/IDE)

    @ViewBuilder
    private var pathConfigPanel: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.gapMedium) {
            // Header: App icon + name + type badge + close button
            headerRow

            // Help text
            helpTextView

            // Directory path section
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.gapSmall) {
                Text("DIRECTORY PATH")
                    .font(brand: .label4)
                    .foregroundStyle(DesignTokens.Text.tertiary)

                // Path on its own line
                HStack(spacing: 0) {
                    Image(systemName: "folder")
                        .font(.system(size: DesignTokens.IconSize.medium))
                        .foregroundStyle(DesignTokens.Text.tertiary)
                        .frame(width: 32)

                    TextField("~/code/my-project", text: $directoryPath)
                        .textFieldStyle(.plain)
                        .font(brand: .body3)
                        .foregroundStyle(DesignTokens.Text.primary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .padding(.horizontal, DesignTokens.Form.inputPaddingHorizontal)
                .frame(height: DesignTokens.Form.inputHeight)
                .background(
                    RoundedRectangle(cornerRadius: DesignTokens.Form.cornerRadius)
                        .fill(DesignTokens.Surface.input)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: DesignTokens.Form.cornerRadius)
                        .stroke(DesignTokens.Border.subtle, lineWidth: 1)
                )

                // Browse, Verify, Clear on one line
                HStack(spacing: DesignTokens.Spacing.gapSmall) {
                    Button("Browse") {
                        openFolderPanel()
                    }
                    .buttonStyle(.dsButton(variant: .secondary, size: .small))

                    if let onVerifyPath {
                        Button {
                            onVerifyPath(directoryPath)
                        } label: {
                            switch pathVerificationStatus {
                            case .verifying:
                                ProgressView()
                                    .controlSize(.small)
                            case .verified:
                                HStack(spacing: 4) {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(DesignTokens.Status.success)
                                    Text("Verified")
                                }
                            case .failed:
                                HStack(spacing: 4) {
                                    Image(systemName: "xmark.circle.fill")
                                        .foregroundStyle(DesignTokens.Status.error)
                                    Text("Failed")
                                }
                            case .none:
                                Text("Verify")
                            }
                        }
                        .buttonStyle(.dsButton(variant: .secondary, size: .small))
                        .disabled(pathVerificationStatus == .verifying)
                    }

                    Button {
                        onClearPath?()
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "trash")
                            Text("Clear")
                        }
                    }
                    .buttonStyle(.dsButton(variant: .tertiary, size: .small))
                }
            }

            if let onApplyPathToAll {
                Button { onApplyPathToAll() } label: {
                    HStack(spacing: DesignTokens.Spacing.gapSmall) {
                        Image(systemName: "arrow.triangle.2.circlepath")
                        Text(applyToAllLabel)
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.dsButton(variant: .secondary))
            }
        }
        .padding(DesignTokens.Card.padding)
        .dsCard(style: .config)
    }

    // MARK: - Standard App Panel

    @ViewBuilder
    private var standardAppPanel: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.gapMedium) {
            headerRow
            helpTextView
        }
        .padding(DesignTokens.Card.padding)
        .dsCard(style: .config)
    }

    // MARK: - Shared Components

    @ViewBuilder
    private var headerRow: some View {
        HStack {
            if let icon = window.icon {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 20, height: 20)
            } else {
                Text(String(window.appName.prefix(1)).uppercased())
                    .font(brand: Font.brandBody(size: 12))
                    .foregroundStyle(DesignTokens.Text.primary.opacity(0.8))
                    .frame(width: 20, height: 20)
                    .background(DesignTokens.Surface.elevated)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
            }

            Text(window.appName)
                .font(brand: .label2)
                .foregroundStyle(DesignTokens.Text.primary)
                .lineLimit(1)
                .truncationMode(.tail)

            if let type = window.specialAppType {
                DSTag(label: type.displayName, color: type.color, size: .small)
                    .fixedSize()
            }

            Spacer()

            Button { onDismiss?() } label: {
                Image(systemName: "xmark")
                    .font(brand: Font.brandBody(size: 10))
                    .foregroundStyle(DesignTokens.Text.tertiary)
            }
            .buttonStyle(.plain)
            .brightenOnHover()
        }
    }

    @ViewBuilder
    private var helpTextView: some View {
        HStack(alignment: .top, spacing: DesignTokens.Spacing.gapSmall) {
            Image(systemName: "info.circle")
                .font(.system(size: DesignTokens.IconSize.small))
                .foregroundStyle(DesignTokens.Text.tertiary)
            Text(helpText)
                .font(brand: .body4)
                .foregroundStyle(DesignTokens.Text.secondary)
        }
    }

    private var helpText: String {
        switch window.specialAppType {
        case .terminal:
            return "Set a directory path to open when this terminal window is restored. The terminal will change to this directory on launch."
        case .ide:
            return "Set a project path to open when this IDE window is restored. The IDE will open this directory on launch."
        case .chrome:
            return "Configure which Chrome profile and tabs to restore for this window."
        case .none:
            return "This app will be launched with default settings."
        }
    }

    private var applyToAllLabel: String {
        "Apply path to all Terminals & IDEs"
    }

    private func openFolderPanel() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser
        panel.prompt = "Select"
        panel.message = "Choose a folder"

        if panel.runModal() == .OK, let url = panel.url {
            directoryPath = url.path
        }
    }
}

// MARK: - Convenience Initializer (backwards compatibility for path-only usage)

extension DSWindowConfigPanel {
    /// Convenience initializer for path-based config only (Terminal/IDE)
    init(
        window: DSPreviewWindow,
        directoryPath: Binding<String>,
        pathVerificationStatus: DSFolderVerificationStatus = .none,
        onVerifyPath: ((String) -> Void)? = nil,
        onClearPath: (() -> Void)? = nil,
        onApplyPathToAll: (() -> Void)? = nil,
        onPathFocusChange: ((Bool) -> Void)? = nil,
        onDismiss: (() -> Void)? = nil
    ) {
        self.window = window
        self._directoryPath = directoryPath
        self.pathVerificationStatus = pathVerificationStatus
        self.onVerifyPath = onVerifyPath
        self.onClearPath = onClearPath
        self.onApplyPathToAll = onApplyPathToAll
        self.onPathFocusChange = onPathFocusChange
        // Chrome bindings - defaults
        self._chromeProfile = .constant(nil)
        self._shouldRestoreTabs = .constant(false)
        self._chromeTabs = .constant([])
        self.chromeProfiles = []
        self.onLoadTabs = nil
        self.onAddTab = nil
        self.onRemoveTab = nil
        self.onDismiss = onDismiss
    }
}

// MARK: - Preview

#Preview("Window Config Panel") {
    VStack(spacing: 24) {
        Text("Window Config Panel")
            .font(brand: .h3)
            .foregroundStyle(DesignTokens.Text.primary)

        // Chrome config
        DSWindowConfigPanel(
            window: DSPreviewWindow(
                appName: "Google Chrome",
                xPercent: 0,
                yPercent: 0,
                widthPercent: 0.5,
                heightPercent: 1,
                specialAppType: .chrome
            ),
            directoryPath: .constant(""),
            chromeProfile: .constant("Default"),
            shouldRestoreTabs: .constant(true),
            chromeTabs: .constant([
                "https://github.com",
                "https://stackoverflow.com"
            ]),
            chromeProfiles: [
                DSSelectOption(id: "Default", label: "Default"),
                DSSelectOption(id: "Work", label: "Work")
            ],
            onDismiss: { }
        )
        .frame(width: 400)

        // Terminal config
        DSWindowConfigPanel(
            window: DSPreviewWindow(
                appName: "Ghostty",
                xPercent: 0,
                yPercent: 0,
                widthPercent: 1,
                heightPercent: 1,
                specialAppType: .terminal
            ),
            directoryPath: .constant("/Users/developer/projects"),
            pathVerificationStatus: .verified,
            onVerifyPath: { _ in },
            onClearPath: { },
            onDismiss: { }
        )
        .frame(width: 400)

        // IDE config
        DSWindowConfigPanel(
            window: DSPreviewWindow(
                appName: "VS Code",
                xPercent: 0,
                yPercent: 0,
                widthPercent: 1,
                heightPercent: 1,
                specialAppType: .ide
            ),
            directoryPath: .constant(""),
            pathVerificationStatus: .none,
            onVerifyPath: { _ in },
            onClearPath: { },
            onDismiss: { }
        )
        .frame(width: 400)

        // Standard app (no special type)
        DSWindowConfigPanel(
            window: DSPreviewWindow(
                appName: "Finder",
                xPercent: 0,
                yPercent: 0,
                widthPercent: 1,
                heightPercent: 1
            ),
            directoryPath: .constant(""),
            onDismiss: { }
        )
        .frame(width: 400)
    }
    .padding(32)
    .background(Color.black.opacity(0.9))
}
