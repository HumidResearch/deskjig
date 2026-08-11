//
//  DSChromeConfigPanel.swift
//  DeskJig
//
//  Created by Claude Code on 02/02/26.
//

import SwiftUI
import AppKit
import DeskJigShared

/// Load tabs status for async operation feedback.
enum DSLoadTabsStatus: Equatable {
    case idle
    case loading
    case success
    case error(String)
}

/// A configuration panel for Chrome windows with profile selector and tab management.
///
/// Features:
/// - Chrome profile dropdown selector
/// - Restore tabs toggle
/// - Tab list with add/remove capability
/// - Load tabs from Chrome button with loading/error states
///
/// Usage:
/// ```swift
/// DSChromeConfigPanel(
///     window: window,
///     selectedProfile: $profile,
///     shouldRestoreTabs: $restoreTabs,
///     tabs: $tabs,
///     profiles: chromeProfiles,
///     onLoadTabs: { loadTabsFromChrome() },
///     onDismiss: { selectedWindowId = nil }
/// )
/// ```
struct DSChromeConfigPanel: View {
    let window: DSPreviewWindow
    @Binding var selectedProfile: String?
    @Binding var shouldRestoreTabs: Bool
    @Binding var tabs: [String]
    var profiles: [DSSelectOption<String>]
    /// Async callback for loading tabs. Return true on success, false on failure.
    var onLoadTabs: (() async -> Bool)?
    var onAddTab: ((String) -> Void)?
    var onRemoveTab: ((Int) -> Void)?
    var onDismiss: (() -> Void)?

    @State private var loadTabsStatus: DSLoadTabsStatus = .idle

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.gapMedium) {
            // Header with app icon, name, Chrome tag, dismiss
            headerRow

            // Help text
            helpTextView

            // Profile selector
            DSFormField(label: "CHROME PROFILE") {
                DSSelect(
                    options: profiles,
                    selection: $selectedProfile,
                    placeholder: "Select profile..."
                )
            }

            // Restore tabs toggle
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Restore tabs")
                        .font(brand: .body3)
                        .foregroundStyle(DesignTokens.Text.primary)
                    Text("Re-open saved tabs when launching")
                        .font(brand: .body4)
                        .foregroundStyle(DesignTokens.Text.tertiary)
                }
                Spacer()
                Toggle("", isOn: $shouldRestoreTabs)
                    .toggleStyle(.switch)
                    .tint(DesignTokens.Brand.accent)
            }

            // Tabs list (collapsible)
            if shouldRestoreTabs {
                tabsSection
            }

            // Load tabs from Chrome button with loading/error states
            if onLoadTabs != nil {
                VStack(alignment: .leading, spacing: DesignTokens.Spacing.gapSmall) {
                    Button {
                        Task {
                            loadTabsStatus = .loading
                            let success = await onLoadTabs?() ?? false
                            loadTabsStatus = success ? .success : .error("Failed to load tabs from Chrome")

                            // Reset success state after delay
                            if success {
                                await Task.sleepUnlessCancelled(nanoseconds: 1_500_000_000)
                                if loadTabsStatus == .success {
                                    loadTabsStatus = .idle
                                }
                            }
                        }
                    } label: {
                        HStack(spacing: DesignTokens.Spacing.gapSmall) {
                            switch loadTabsStatus {
                            case .loading:
                                ProgressView()
                                    .controlSize(.small)
                            case .success:
                                Image(systemName: "checkmark")
                                    .foregroundStyle(DesignTokens.Status.success)
                            case .error:
                                Image(systemName: "exclamationmark.triangle")
                                    .foregroundStyle(DesignTokens.Status.error)
                            case .idle:
                                Image(systemName: "arrow.clockwise")
                            }
                            Text(loadTabsButtonText)
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.dsButton(variant: loadTabsButtonVariant))
                    .disabled(loadTabsStatus == .loading)

                    // Error message
                    if case .error(let message) = loadTabsStatus {
                        HStack(spacing: DesignTokens.Spacing.gapTiny) {
                            Image(systemName: "exclamationmark.circle")
                                .font(.system(size: DesignTokens.IconSize.tiny))
                            Text(message)
                        }
                        .font(brand: .body4)
                        .foregroundStyle(DesignTokens.Status.error)
                    }
                }
            }
        }
        .padding(DesignTokens.Card.padding)
        .dsCard(style: .config)
    }

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

    private var loadTabsButtonText: String {
        switch loadTabsStatus {
        case .loading:
            return "Loading..."
        case .success:
            return "Tabs loaded"
        case .error:
            return "Retry"
        case .idle:
            return "Load tabs from Chrome"
        }
    }

    private var loadTabsButtonVariant: DSButtonVariant {
        switch loadTabsStatus {
        case .error:
            return .danger
        case .success:
            return .success
        default:
            return .secondary
        }
    }

    @ViewBuilder
    private var helpTextView: some View {
        HStack(alignment: .top, spacing: DesignTokens.Spacing.gapSmall) {
            Image(systemName: "info.circle")
                .font(.system(size: DesignTokens.IconSize.small))
                .foregroundStyle(DesignTokens.Text.tertiary)
            Text("Configure which Chrome profile and tabs to restore for this window.")
                .font(brand: .body4)
                .foregroundStyle(DesignTokens.Text.secondary)
        }
    }

    @ViewBuilder
    private var tabsSection: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.gapSmall) {
            Text("SAVED TABS (\(tabs.count))")
                .font(brand: .label4)
                .foregroundStyle(DesignTokens.Text.tertiary)

            ForEach(Array(tabs.enumerated()), id: \.offset) { index, tab in
                DSTabRow(
                    url: tab,
                    onRemove: { onRemoveTab?(index) }
                )
            }

            // Add tab row
            if let onAddTab {
                DSAddTabRow(onAdd: onAddTab)
            }
        }
    }
}

// MARK: - Tab Row

/// A row displaying a single tab URL with optional remove button.
struct DSTabRow: View {
    let url: String
    var onRemove: (() -> Void)?
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: DesignTokens.Spacing.gapSmall) {
            Image(systemName: "globe")
                .font(.system(size: DesignTokens.IconSize.small))
                .foregroundStyle(DesignTokens.Text.tertiary)

            Text(displayURL)
                .font(brand: .body4)
                .foregroundStyle(DesignTokens.Text.secondary)
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer()

            if isHovering, onRemove != nil {
                Button {
                    onRemove?()
                } label: {
                    Image(systemName: "xmark")
                        .font(brand: Font.brandBody(size: 10))
                        .foregroundStyle(DesignTokens.Text.tertiary)
                }
                .buttonStyle(.plain)
                .brightenOnHover()
                .transition(.opacity)
            }
        }
        .padding(.horizontal, DesignTokens.Spacing.gapRegular)
        .padding(.vertical, DesignTokens.Spacing.gapSmall)
        .background(DesignTokens.Surface.card)
        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.CornerRadius.medium))
        .onHover { isHovering = $0 }
        .animation(.easeInOut(duration: 0.15), value: isHovering)
    }

    /// Display a shortened URL (removes https:// prefix)
    private var displayURL: String {
        var display = url
        if display.hasPrefix("https://") {
            display = String(display.dropFirst(8))
        } else if display.hasPrefix("http://") {
            display = String(display.dropFirst(7))
        }
        return display
    }
}

// MARK: - Add Tab Row

/// A row for adding new tab URLs with validation.
struct DSAddTabRow: View {
    var onAdd: ((String) -> Void)?
    @State private var newURL: String = ""
    @State private var showValidationWarning: Bool = false
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.gapTiny) {
            HStack(spacing: DesignTokens.Spacing.gapSmall) {
                Image(systemName: "plus")
                    .font(.system(size: DesignTokens.IconSize.small))
                    .foregroundStyle(DesignTokens.Text.tertiary)

                TextField("https://example.com", text: $newURL)
                    .textFieldStyle(.plain)
                    .font(brand: .body4)
                    .foregroundStyle(DesignTokens.Text.primary)
                    .focused($isFocused)
                    .onChange(of: newURL) { _, newValue in
                        // Clear warning when user starts typing again
                        if showValidationWarning && isValidURL(newValue) {
                            showValidationWarning = false
                        }
                    }
                    .onSubmit {
                        addTab()
                    }

                if !newURL.isEmpty {
                    Button {
                        addTab()
                    } label: {
                        Text("Add")
                            .font(brand: .label4)
                    }
                    .buttonStyle(.dsButton(variant: .tertiary, size: .small))
                }
            }
            .padding(.horizontal, DesignTokens.Spacing.gapRegular)
            .padding(.vertical, DesignTokens.Spacing.gapSmall)
            .background {
                RoundedRectangle(cornerRadius: DesignTokens.CornerRadius.medium)
                    .stroke(
                        borderColor,
                        style: StrokeStyle(lineWidth: 1, dash: (isFocused || showValidationWarning) ? [] : [4, 2])
                    )
            }

            // Validation warning
            if showValidationWarning {
                HStack(spacing: DesignTokens.Spacing.gapTiny) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: DesignTokens.IconSize.tiny))
                    Text("Please enter a valid URL (e.g., https://example.com)")
                }
                .font(brand: .body4)
                .foregroundStyle(DesignTokens.Status.warning)
                .padding(.leading, DesignTokens.Spacing.gapRegular)
            }
        }
        .animation(.easeInOut(duration: 0.15), value: isFocused)
        .animation(.easeInOut(duration: 0.15), value: showValidationWarning)
    }

    private var borderColor: Color {
        if showValidationWarning {
            return DesignTokens.Status.warning
        } else if isFocused {
            return DesignTokens.Brand.accent
        } else {
            return DesignTokens.Border.subtle
        }
    }

    /// Validates if a string is a valid URL
    private func isValidURL(_ string: String) -> Bool {
        guard !string.isEmpty else { return false }

        // Add https:// if no scheme present for validation
        var urlString = string
        if !urlString.contains("://") {
            urlString = "https://\(urlString)"
        }

        guard let url = URL(string: urlString),
              let host = url.host,
              !host.isEmpty else {
            return false
        }

        // Check for valid domain pattern (at least one dot in domain, or localhost)
        return host.contains(".") || host == "localhost"
    }

    private func addTab() {
        guard !newURL.isEmpty else { return }

        if isValidURL(newURL) {
            // Add https:// prefix if missing
            var urlToAdd = newURL
            if !urlToAdd.contains("://") {
                urlToAdd = "https://\(urlToAdd)"
            }
            onAdd?(urlToAdd)
            newURL = ""
            showValidationWarning = false
        } else {
            showValidationWarning = true
        }
    }
}

// MARK: - Preview

#Preview("Chrome Config Panel") {
    VStack(spacing: 24) {
        Text("Chrome Config Panel")
            .font(brand: .h3)
            .foregroundStyle(DesignTokens.Text.primary)

        DSChromeConfigPanel(
            window: DSPreviewWindow(
                appName: "Google Chrome",
                xPercent: 0,
                yPercent: 0,
                widthPercent: 0.5,
                heightPercent: 1,
                specialAppType: .chrome
            ),
            selectedProfile: .constant("Default"),
            shouldRestoreTabs: .constant(true),
            tabs: .constant([
                "https://github.com/anthropics/claude-code",
                "https://stackoverflow.com/questions/swift",
                "https://developer.apple.com/documentation"
            ]),
            profiles: [
                DSSelectOption(id: "Default", label: "Default"),
                DSSelectOption(id: "Work", label: "Work"),
                DSSelectOption(id: "Personal", label: "Personal")
            ],
            onLoadTabs: {
                await Task.sleepUnlessCancelled(nanoseconds: 2_000_000_000)
                return true
            },
            onAddTab: { _ in },
            onRemoveTab: { _ in },
            onDismiss: { }
        )
        .frame(width: 400)
    }
    .padding(32)
    .background(Color.black.opacity(0.9))
}
