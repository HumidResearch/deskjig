//
//  WorkspaceWindowDetailRow.swift
//  DeskJig
//
//  Row component showing individual window details with expandable strategy configuration.
//

import SwiftUI
import AppKit
import DeskJigShared

struct WorkspaceWindowDetailRow: View {
    let window: WorkspaceWindow
    let iconProvider: (WorkspaceWindow) -> NSImage?
    @Bindable var strategyManager: LaunchStrategyManager
    /// Available screens for screen override picker
    let availableScreens: [ScreenOption]
    var isSelected: Bool = false
    var onSelect: (() -> Void)? = nil
    /// Callback to launch just this window
    var onLaunchWindow: ((WorkspaceWindow) -> Void)? = nil

    @State private var isExpanded: Bool = false

    // MARK: - App Type Detection

    private var isChrome: Bool {
        chromeBundleIdentifiers.contains(window.bundleIdentifier)
    }

    private var isTerminalOrIDE: Bool {
        OpenByPathBundleIdentifiers.supported.contains(window.bundleIdentifier)
    }

    private var isCLITerminal: Bool {
        cliTerminalBundleIds.contains(window.bundleIdentifier)
    }

    private var isCommandFileTerminal: Bool {
        commandFileTerminalBundleIds.contains(window.bundleIdentifier)
    }

    private var isIDE: Bool {
        ideBundleIds.contains(window.bundleIdentifier)
    }

    private var isTerminal: Bool {
        terminalBundleIds.contains(window.bundleIdentifier)
    }

    // MARK: - Filtered Strategy Options

    /// Available match strategies for this app type (ordered with default first)
    private var availableMatchStrategies: [WindowMatchStrategy] {
        if isTerminal {
            // Terminals: the frozen `bento:` title token is the primary match method
            return [.bentoTitle, .titlePattern, .frameMatch, .bundleIdOnly]
        } else if isIDE {
            // IDEs: Document Path is primary match method
            return [.documentPath, .titlePattern, .frameMatch, .bundleIdOnly]
        } else if isChrome {
            // Chrome: Profile Match is primary, then Tab URLs
            return [.chromeProfile, .chromeTabUrls, .frameMatch, .bundleIdOnly]
        } else {
            // Generic apps: Frame Match is default
            return [.frameMatch, .titlePattern, .bundleIdOnly]
        }
    }

    /// Available launch methods for this app type (ordered with default first)
    private var availableLaunchMethods: [AppLaunchMethod] {
        if isChrome {
            // Chrome: AppleScript is primary
            return [.appleScript, .open]
        } else if isCLITerminal {
            // CLI Terminals: CLI is primary (only option that works)
            return [.cli]
        } else if isCommandFileTerminal {
            // Command-file Terminals: Command File is primary (only option that works)
            return [.commandFile]
        } else if isIDE {
            // IDEs: CLI is primary, workspaceFile available
            return [.cli, .workspaceFile, .open]
        } else {
            // Generic apps: Open Command is default (only option)
            return [.open]
        }
    }

    // MARK: - Strategy State

    private var strategy: WindowLaunchStrategy {
        strategyManager.strategy(for: window.id)
    }

    /// Current screen override (nil = use original)
    private var screenOverride: Int? {
        strategyManager.screenOverride(for: window.id)
    }

    /// The effective target screen (override or original)
    private var effectiveScreen: Int {
        screenOverride ?? window.screenIndex ?? 0
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Main row
            mainRow

            // Expanded configuration
            if isExpanded {
                expandedConfiguration
            }
        }
        .background(isSelected ? DesignTokens.Brand.accent.opacity(0.1) : Color.clear)
        .cornerRadius(6)
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(isSelected ? DesignTokens.Brand.accent.opacity(0.3) : Color.clear, lineWidth: 1)
        )
    }

    // MARK: - Main Row

    private var mainRow: some View {
        HStack(spacing: 10) {
            // App icon
            appIcon

            // Info
            VStack(alignment: .leading, spacing: 2) {
                // App name and window title
                HStack(spacing: 6) {
                    Text(window.appName)
                        .font(.subheadline)
                        .fontWeight(.medium)
                        .lineLimit(1)

                    // Type badges
                    if isChrome {
                        badge(text: "Chrome", color: DesignTokens.Brand.accent)
                    }
                    if isTerminalOrIDE && window.openPath != nil {
                        badge(text: "Path", color: .cyan)
                    }
                }

                // Window title
                if !window.windowTitle.isEmpty && window.windowTitle != window.appName {
                    Text(window.windowTitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                // Path or Chrome profile
                pathOrProfileInfo
            }

            Spacer()

            // Frame info
            frameInfo

            // Expand button
            Button {
                withAnimation(.easeInOut(duration: 0.15)) {
                    isExpanded.toggle()
                }
            } label: {
                Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .onTapGesture {
            onSelect?()
        }
    }

    // MARK: - App Icon

    private var appIcon: some View {
        Group {
            if let icon = iconProvider(window) {
                Image(nsImage: icon)
                    .resizable()
                    .scaledToFit()
            } else {
                Image(systemName: "app.fill")
                    .font(.title2)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 28, height: 28)
    }

    // MARK: - Path or Profile Info

    @ViewBuilder
    private var pathOrProfileInfo: some View {
        if let openPath = window.openPath {
            HStack(spacing: 4) {
                Image(systemName: "folder")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Text(abbreviatePath(openPath))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        } else if let chromeState = window.chromeState {
            HStack(spacing: 4) {
                Image(systemName: "person.circle")
                    .font(.caption2)
                    .foregroundStyle(DesignTokens.Brand.accent.opacity(0.7))
                Text(chromeState.profileDisplayName)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                if !chromeState.savedTabURLs.isEmpty {
                    Text("\u{2022} \(chromeState.savedTabURLs.count) tabs")
                        .font(.caption2)
                        .foregroundStyle(.quaternary)
                }
            }
        }
    }

    // MARK: - Frame Info

    @ViewBuilder
    private var frameInfo: some View {
        if let frame = window.relativeFrame {
            VStack(alignment: .trailing, spacing: 0) {
                HStack(spacing: 2) {
                    if screenOverride != nil {
                        Image(systemName: "arrow.right")
                            .font(brand: Font.brandBody(size: 8))
                            .foregroundStyle(DesignTokens.Brand.accent)
                    }
                    Text("Screen \(effectiveScreen)")
                        .font(.caption2)
                        .foregroundStyle(screenOverride != nil ? DesignTokens.Brand.accent : DesignTokens.Text.tertiary)
                }
                Text("\(Int(frame.widthPercent * 100))% x \(Int(frame.heightPercent * 100))%")
                    .font(.caption2)
                    .foregroundStyle(.quaternary)
            }
        }
    }

    // MARK: - Badge

    private func badge(text: String, color: Color) -> some View {
        Text(text)
            .font(brand: Font.brandBody(size: 9))
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(color.opacity(0.2))
            .foregroundStyle(color)
            .cornerRadius(3)
    }

    // MARK: - Expanded Configuration

    private var expandedConfiguration: some View {
        VStack(alignment: .leading, spacing: 12) {
            Divider()
                .padding(.horizontal, 10)

            VStack(alignment: .leading, spacing: 10) {
                // Target Screen Override
                screenOverridePicker

                Divider()

                // Match Strategy (filtered by app type)
                strategyPicker(
                    title: "Match Strategy",
                    selection: matchMethodBinding,
                    options: availableMatchStrategies,
                    defaultValue: defaultStrategy.matchMethod
                )

                // Launch Method (filtered by app type)
                strategyPicker(
                    title: "Launch Method",
                    selection: launchMethodBinding,
                    options: availableLaunchMethods,
                    defaultValue: defaultStrategy.launchMethod
                )

                // IDE-specific options (Cursor, VS Code)
                if isIDE {
                    strategyPicker(
                        title: "IDE Launch Mode",
                        selection: ideLaunchModeBinding,
                        options: IDELaunchMode.allCases,
                        defaultValue: defaultStrategy.ideLaunchMode
                    )
                }

                // Chrome-specific options
                if isChrome {
                    strategyPicker(
                        title: "Tab Restoration Method",
                        selection: chromeMethodBinding,
                        options: ChromeRestoreMethod.allCases,
                        defaultValue: defaultStrategy.chromeMethod
                    )
                }

                // Lock Priority
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Lock Priority")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text("(default: \(defaultStrategy.lockPriority.description))")
                            .font(.caption2)
                            .foregroundStyle(.quaternary)
                    }
                    Picker("", selection: lockPriorityBinding) {
                        ForEach([LockPriority.low, .medium, .high, .critical], id: \.self) { priority in
                            Text(priority.description.capitalized).tag(priority)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }

                // Action buttons
                HStack {
                    Spacer()

                    Button {
                        strategyManager.resetStrategy(for: window.id)
                    } label: {
                        Label("Reset to Defaults", systemImage: "arrow.counterclockwise")
                            .font(.caption)
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)

                    // Launch single window button
                    if let onLaunchWindow {
                        Button {
                            onLaunchWindow(window)
                        } label: {
                            Label("Launch", systemImage: "play.fill")
                                .font(.caption)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .disabled(strategyManager.isLaunching)
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 10)
        }
        .background(DesignTokens.Surface.card)
    }

    // MARK: - Strategy Picker

    private func strategyPicker<T: Hashable & RawRepresentable & Equatable & StrategyDisplayable>(
        title: String,
        selection: Binding<T>,
        options: [T],
        defaultValue: T
    ) -> some View where T.RawValue == String {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                // Show "(default)" when current selection equals default
                if selection.wrappedValue == defaultValue {
                    Text("(default)")
                        .font(.caption2)
                        .foregroundStyle(DesignTokens.Brand.accent.opacity(0.7))
                }
            }
            Picker("", selection: selection) {
                ForEach(options, id: \.self) { option in
                    HStack {
                        Text(option.displayName)
                        // Mark the default option with a star
                        if option == defaultValue {
                            Image(systemName: "star.fill")
                                .font(brand: Font.brandBody(size: 8))
                        }
                    }
                    .tag(option)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
        }
    }

    // MARK: - Screen Override Picker

    private var screenOverridePicker: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Target Screen")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let originalIndex = window.screenIndex {
                    Text("(original: Screen \(originalIndex))")
                        .font(.caption2)
                        .foregroundStyle(.quaternary)
                }
            }

            HStack(spacing: 8) {
                Picker("", selection: screenOverrideBinding) {
                    Text("Original").tag(nil as Int?)
                    ForEach(availableScreens) { screen in
                        Text(screen.label).tag(screen.index as Int?)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()

                if screenOverride != nil {
                    Button {
                        strategyManager.setScreenOverride(nil, for: window.id)
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Reset to original screen")
                }
            }
        }
    }

    private var screenOverrideBinding: Binding<Int?> {
        Binding(
            get: { screenOverride },
            set: { strategyManager.setScreenOverride($0, for: window.id) }
        )
    }

    // MARK: - Bindings

    private var matchMethodBinding: Binding<WindowMatchStrategy> {
        Binding(
            get: { strategy.matchMethod },
            set: { newValue in
                var newStrategy = strategy
                newStrategy.matchMethod = newValue
                strategyManager.setStrategy(newStrategy, for: window.id)
            }
        )
    }

    private var launchMethodBinding: Binding<AppLaunchMethod> {
        Binding(
            get: { strategy.launchMethod },
            set: { newValue in
                var newStrategy = strategy
                newStrategy.launchMethod = newValue
                strategyManager.setStrategy(newStrategy, for: window.id)
            }
        )
    }

    private var ideLaunchModeBinding: Binding<IDELaunchMode> {
        Binding(
            get: { strategy.ideLaunchMode },
            set: { newValue in
                var newStrategy = strategy
                newStrategy.ideLaunchMode = newValue
                strategyManager.setStrategy(newStrategy, for: window.id)
            }
        )
    }

    private var chromeMethodBinding: Binding<ChromeRestoreMethod> {
        Binding(
            get: { strategy.chromeMethod },
            set: { newValue in
                var newStrategy = strategy
                newStrategy.chromeMethod = newValue
                strategyManager.setStrategy(newStrategy, for: window.id)
            }
        )
    }

    private var lockPriorityBinding: Binding<LockPriority> {
        Binding(
            get: { strategy.lockPriority },
            set: { newValue in
                var newStrategy = strategy
                newStrategy.lockPriority = newValue
                strategyManager.setStrategy(newStrategy, for: window.id)
            }
        )
    }

    // MARK: - Default Strategy

    /// Infers the recommended default strategy based on the window's app type
    private var defaultStrategy: WindowLaunchStrategy {
        var strategy = WindowLaunchStrategy()

        // Chrome apps
        if isChrome {
            strategy.matchMethod = .titlePattern
            strategy.launchMethod = .appleScript
            strategy.chromeMethod = .appleScript
            strategy.lockPriority = .high
            return strategy
        }

        // CLI-based terminals (Ghostty, Kitty, Alacritty)
        let cliBundleIds: Set<String> = [
            "com.mitchellh.ghostty",
            "net.kovidgoyal.kitty",
            "org.alacritty"
        ]
        if cliBundleIds.contains(window.bundleIdentifier) {
            strategy.matchMethod = .bentoTitle
            strategy.launchMethod = .cli
            strategy.lockPriority = window.openPath != nil ? .high : .medium
            return strategy
        }

        // Command-file terminals (Terminal.app, iTerm)
        let commandFileBundleIds: Set<String> = [
            "com.apple.Terminal",
            "com.googlecode.iterm2"
        ]
        if commandFileBundleIds.contains(window.bundleIdentifier) {
            strategy.matchMethod = .bentoTitle
            strategy.launchMethod = .commandFile
            strategy.lockPriority = window.openPath != nil ? .high : .medium
            return strategy
        }

        // IDEs (Cursor, VS Code)
        let ideBundleIds: Set<String> = [
            "com.todesktop.230313mzl4w4u92",  // Cursor
            "com.microsoft.VSCode"
        ]
        if ideBundleIds.contains(window.bundleIdentifier) {
            strategy.matchMethod = .documentPath
            strategy.launchMethod = .cli
            strategy.ideLaunchMode = .newWindow
            strategy.lockPriority = window.openPath != nil ? .high : .medium
            return strategy
        }

        // Other apps with openPath (likely editors)
        if window.openPath != nil {
            strategy.matchMethod = .documentPath
            strategy.launchMethod = .open
            strategy.lockPriority = .high
            return strategy
        }

        // Default for unknown apps
        strategy.matchMethod = .frameMatch
        strategy.launchMethod = .open
        strategy.lockPriority = .low
        return strategy
    }

    // MARK: - Helpers

    private func abbreviatePath(_ path: String) -> String {
        let homePath = NSHomeDirectory()
        if path.hasPrefix(homePath) {
            return "~" + path.dropFirst(homePath.count)
        }
        return path
    }
}

// MARK: - App Type Bundle IDs

private let terminalBundleIds: Set<String> = [
    "com.apple.Terminal",
    "com.googlecode.iterm2",
    "com.mitchellh.ghostty",
    "net.kovidgoyal.kitty",
    "org.alacritty"
]

private let cliTerminalBundleIds: Set<String> = [
    "com.mitchellh.ghostty",
    "net.kovidgoyal.kitty",
    "org.alacritty"
]

private let commandFileTerminalBundleIds: Set<String> = [
    "com.apple.Terminal",
    "com.googlecode.iterm2"
]

private let ideBundleIds: Set<String> = [
    "com.todesktop.230313mzl4w4u92",  // Cursor
    "com.microsoft.VSCode"
]

// MARK: - Screen Option

/// Represents an available screen for the screen override picker
struct ScreenOption: Identifiable, Hashable {
    let index: Int
    let label: String
    let isPrimary: Bool

    var id: Int { index }

    init(index: Int, name: String? = nil, isPrimary: Bool = false) {
        self.index = index
        self.isPrimary = isPrimary
        if let name = name, !name.isEmpty {
            self.label = isPrimary ? "Screen \(index): \(name) (Primary)" : "Screen \(index): \(name)"
        } else {
            self.label = isPrimary ? "Screen \(index) (Primary)" : "Screen \(index)"
        }
    }

    /// Create screen options from WorkspaceScreens
    static func from(screens: [WorkspaceScreen]?) -> [ScreenOption] {
        guard let screens = screens, !screens.isEmpty else {
            return [ScreenOption(index: 0, name: nil, isPrimary: true)]
        }

        return screens.enumerated().map { index, screen in
            ScreenOption(index: index, name: screen.name, isPrimary: screen.isPrimary)
        }
    }

    /// Create screen options from current NSScreen configuration
    static func fromCurrentScreens() -> [ScreenOption] {
        return NSScreen.screens.enumerated().map { index, screen in
            let name = screen.localizedName
            let isPrimary = screen == NSScreen.main
            return ScreenOption(index: index, name: name, isPrimary: isPrimary)
        }
    }
}

// MARK: - Preview

#Preview {
    let manager = LaunchStrategyManager()

    let window1 = WorkspaceWindow(
        bundleIdentifier: "com.todesktop.230313mzl4w4u92",
        appName: "Cursor",
        windowTitle: "deskjig - Cursor",
        openPath: "/Users/testuser/code/deskjig",
        screenIndex: 0,
        relativeFrame: RelativeWindowFrame(xPercent: 0, yPercent: 0, widthPercent: 0.5, heightPercent: 1.0)
    )

    let window2 = WorkspaceWindow(
        bundleIdentifier: "com.google.Chrome",
        appName: "Google Chrome",
        windowTitle: "GitHub - Chrome",
        chromeState: ChromeWindowState(
            profileDirectory: "Default",
            profileDisplayName: "Personal",
            savedTabURLs: ["https://github.com", "https://google.com", "https://anthropic.com"]
        ),
        screenIndex: 0,
        relativeFrame: RelativeWindowFrame(xPercent: 0.5, yPercent: 0, widthPercent: 0.5, heightPercent: 1.0)
    )

    let screens = [
        ScreenOption(index: 0, name: "Built-in Display", isPrimary: true),
        ScreenOption(index: 1, name: "Dell U2720Q", isPrimary: false)
    ]

    return VStack(spacing: 8) {
        WorkspaceWindowDetailRow(
            window: window1,
            iconProvider: { _ in nil },
            strategyManager: manager,
            availableScreens: screens,
            isSelected: true
        )
        WorkspaceWindowDetailRow(
            window: window2,
            iconProvider: { _ in nil },
            strategyManager: manager,
            availableScreens: screens,
            isSelected: false
        )
    }
    .padding()
    .frame(width: 500)
}
