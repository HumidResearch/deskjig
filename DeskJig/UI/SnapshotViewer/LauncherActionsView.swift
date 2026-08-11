//
//  LauncherActionsView.swift
//  DeskJig
//
//  Actions panel for testing Fluent API launcher operations (terminals, IDEs)
//

import SwiftUI
import DeskJigShared

// MARK: - Launcher Selection

/// Available launchers for testing
enum LauncherSelection: String, CaseIterable, Identifiable {
    case ghostty = "Ghostty"
    case terminal = "Terminal"
    case iTerm = "iTerm"
    case kitty = "Kitty"
    case alacritty = "Alacritty"
    case cursor = "Cursor"
    case codex = "Codex"
    case vscode = "VS Code"

    var id: String { rawValue }

    var bundleId: String {
        switch self {
        case .ghostty: return "com.mitchellh.ghostty"
        case .terminal: return "com.apple.Terminal"
        case .iTerm: return "com.googlecode.iterm2"
        case .kitty: return "net.kovidgoyal.kitty"
        case .alacritty: return "org.alacritty"
        case .cursor: return "com.todesktop.230313mzl4w4u92"
        case .codex: return "com.openai.codex"
        case .vscode: return "com.microsoft.VSCode"
        }
    }

    var supportsTitle: Bool {
        switch self {
        case .ghostty, .terminal, .iTerm, .kitty, .alacritty:
            return true  // Terminals support the frozen `bento:` title token
        case .cursor, .codex, .vscode:
            return false  // IDEs don't support custom window titles via CLI
        }
    }

    var isTerminal: Bool {
        switch self {
        case .ghostty, .terminal, .iTerm, .kitty, .alacritty:
            return true
        case .cursor, .codex, .vscode:
            return false
        }
    }

    var description: String {
        switch self {
        case .ghostty: return "CLI: --working-directory, --title"
        case .terminal: return "Command file with title escape sequence"
        case .iTerm: return "Command file with title escape sequence"
        case .kitty: return "CLI: --single-instance, --directory, --title"
        case .alacritty: return "CLI: --working-directory, --title"
        case .cursor: return "CLI: --new-window <path>"
        case .codex: return "CLI: codex app <path>"
        case .vscode: return "CLI: --new-window <path>"
        }
    }
}

// MARK: - Launch Result Display

struct LaunchResultView: View {
    let result: LaunchTestResult

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Image(systemName: result.success ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .foregroundStyle(result.success ? DesignTokens.Brand.accent : DesignTokens.Status.error)
                Text(statusText)
                    .font(.caption)
                    .fontWeight(.semibold)
            }

            // Show reuse indicator prominently
            if result.wasReused {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .foregroundStyle(DesignTokens.Brand.accent)
                    Text("Reused existing window")
                        .foregroundStyle(DesignTokens.Brand.accent)
                }
                .font(.caption2)
            }

            Group {
                LabeledContent("Method", value: result.method)
                LabeledContent("Duration", value: "\(result.durationMs)ms")
                if !result.notes.isEmpty {
                    Text(result.notes.joined(separator: ", "))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .font(.caption)
        }
        .padding(8)
        .background(.quaternary)
        .cornerRadius(6)
    }

    private var statusText: String {
        if !result.success {
            return "Launch Failed"
        }
        return result.wasReused ? "Found Existing" : "Created New"
    }
}

struct MatchTestResultView: View {
    let result: MatchTestResult

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Image(systemName: result.found ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .foregroundStyle(result.found ? DesignTokens.Brand.accent : DesignTokens.Brand.accent)
                Text(result.found ? "Match Found" : "No Match")
                    .font(.caption)
                    .fontWeight(.semibold)
            }

            Group {
                if let confidence = result.confidence {
                    LabeledContent("Confidence", value: String(format: "%.0f%%", confidence * 100))
                }
                if let method = result.method {
                    LabeledContent("Method", value: method)
                }
                if let windowId = result.windowId {
                    LabeledContent("Window ID", value: "\(windowId)")
                }
                if let title = result.matchedTitle {
                    Text("Title: \(title)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            .font(.caption)
        }
        .padding(8)
        .background(.quaternary)
        .cornerRadius(6)
    }
}

// MARK: - Result Types

struct LaunchTestResult {
    let success: Bool
    let method: String
    let durationMs: Int
    let notes: [String]
    let wasReused: Bool  // True if matched existing window instead of launching
}

struct MatchTestResult {
    let found: Bool
    let confidence: Double?
    let method: String?
    let windowId: UInt32?
    let matchedTitle: String?
}

// MARK: - Main View

struct LauncherActionsView: View {
    let window: SnapshotWindow?
    let snapshot: SystemSnapshot?
    let onRefresh: () -> Void

    @State private var selectedLauncher: LauncherSelection = .ghostty
    @State private var customDirectory: String = ""
    @State private var customTitle: String = ""
    @State private var autoGenerateTitle = true

    // IDE-specific options
    @State private var ideLaunchMode: IDELaunchMode = .newWindow
    @State private var gotoLineInput: String = ""  // e.g., "src/main.ts:42:5"
    @State private var diffFile1: String = ""
    @State private var diffFile2: String = ""

    @State private var actionInProgress = false
    @State private var launchResult: LaunchTestResult?
    @State private var matchResult: MatchTestResult?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Launcher Actions")
                .font(.headline)

            // Launcher Selection
            launcherSelectionSection

            Divider()

            // Configuration
            configurationSection

            // IDE Options (only for IDEs)
            if !selectedLauncher.isTerminal {
                Divider()
                ideOptionsSection
            }

            Divider()

            // Actions (Launch, Match, Reuse)
            launchActionsSection

            // Results
            if launchResult != nil || matchResult != nil {
                Divider()
                resultsSection
            }

            // Status
            statusSection
        }
        .disabled(actionInProgress)
        .onAppear {
            populateFromWindow()
        }
        .onChange(of: window?.id) { _, _ in
            populateFromWindow()
        }
    }

    // MARK: - Sections

    private var launcherSelectionSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Launcher")
                .font(.subheadline)
                .fontWeight(.semibold)
                .foregroundStyle(.secondary)

            Picker("Launcher", selection: $selectedLauncher) {
                ForEach(LauncherSelection.allCases) { launcher in
                    HStack {
                        Text(launcher.rawValue)
                        if launcher.supportsTitle {
                            Image(systemName: "tag")
                                .font(.caption2)
                                .foregroundStyle(DesignTokens.Brand.accent)
                        }
                    }
                    .tag(launcher)
                }
            }
            .pickerStyle(.menu)

            Text(selectedLauncher.description)
                .font(.caption2)
                .foregroundStyle(.secondary)

            if !selectedLauncher.supportsTitle {
                HStack(spacing: 4) {
                    Image(systemName: "info.circle")
                        .foregroundStyle(DesignTokens.Brand.accent)
                    Text("IDEs don't support custom window titles")
                }
                .font(.caption2)
                .foregroundStyle(DesignTokens.Brand.accent)
            }
        }
    }

    private var configurationSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Configuration")
                .font(.subheadline)
                .fontWeight(.semibold)
                .foregroundStyle(.secondary)

            // Directory input
            VStack(alignment: .leading, spacing: 2) {
                Text("Directory")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                TextField("e.g., ~/code/project", text: $customDirectory)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.caption, design: .monospaced))
            }

            // Title input (only for terminals)
            if selectedLauncher.supportsTitle {
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text("Title")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                        Spacer()
                        Toggle("Auto", isOn: $autoGenerateTitle)
                            .toggleStyle(.checkbox)
                            .font(.caption2)
                    }

                    // Always show editable text field
                    TextField("e.g., \(BundleIdentity.terminalTitleTokenPrefix):deskjig:0", text: titleBinding)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.caption, design: .monospaced))

                    if autoGenerateTitle {
                        Text("Auto-updates from directory")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
            }

            // Populate from window button
            if window != nil {
                Button {
                    populateFromWindow()
                } label: {
                    Label("Populate from Window", systemImage: "arrow.down.doc")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
            }
        }
    }

    private var ideOptionsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("IDE Options")
                .font(.subheadline)
                .fontWeight(.semibold)
                .foregroundStyle(.secondary)

            // CLI Status
            cliStatusView

            // Launch Mode picker
            VStack(alignment: .leading, spacing: 2) {
                Text("Launch Mode")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Picker("Mode", selection: $ideLaunchMode) {
                    ForEach(IDELaunchMode.allCases, id: \.self) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
            }

            // Mode-specific inputs
            switch ideLaunchMode {
            case .gotoLine:
                VStack(alignment: .leading, spacing: 2) {
                    Text("File:Line:Column")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    TextField("e.g., src/main.ts:42:5", text: $gotoLineInput)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.caption, design: .monospaced))
                }

            case .diffFiles:
                VStack(alignment: .leading, spacing: 4) {
                    Text("Diff Files")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    TextField("File 1", text: $diffFile1)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.caption, design: .monospaced))
                    TextField("File 2", text: $diffFile2)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.caption, design: .monospaced))
                }

            case .workspaceFile:
                HStack(spacing: 4) {
                    Image(systemName: "info.circle")
                        .foregroundStyle(DesignTokens.Brand.accent)
                    Text("Creates .code-workspace from directory")
                }
                .font(.caption2)
                .foregroundStyle(.secondary)

            default:
                EmptyView()
            }
        }
    }

    @ViewBuilder
    private var cliStatusView: some View {
        let status = CLILocator.cliStatus(for: selectedLauncher.bundleId)

        HStack(spacing: 6) {
            if status.isInstalled {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(DesignTokens.Brand.accent)
                VStack(alignment: .leading, spacing: 0) {
                    Text("CLI installed")
                        .font(.caption)
                    if let source = status.source {
                        Text("via \(source.rawValue)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            } else {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(DesignTokens.Text.secondary)
                VStack(alignment: .leading, spacing: 0) {
                    Text("CLI not found")
                        .font(.caption)
                    if selectedLauncher == .cursor || selectedLauncher == .vscode {
                        Link("Install CLI", destination: URL(string: "https://code.visualstudio.com/docs/configure/command-line")!)
                            .font(.caption2)
                    }
                }
            }
        }
        .padding(6)
        .background(status.isInstalled ? DesignTokens.Brand.accent.opacity(0.12) : DesignTokens.Surface.cardHover)
        .cornerRadius(4)
    }

    private var launchActionsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Actions")
                .font(.subheadline)
                .fontWeight(.semibold)
                .foregroundStyle(.secondary)

            // Row 1: Launch New and Match
            HStack(spacing: 8) {
                Button {
                    performLaunch()
                } label: {
                    Label("Launch New", systemImage: "plus.app")
                }
                .buttonStyle(.bordered)
                .disabled(customDirectory.isEmpty && effectiveTitle.isEmpty)

                Button {
                    performMatchTest()
                } label: {
                    Label("Match", systemImage: "magnifyingglass")
                }
                .buttonStyle(.bordered)
                .disabled(customDirectory.isEmpty && effectiveTitle.isEmpty)
            }

            // Row 2: Launch & Match and Launch with Reuse
            HStack(spacing: 8) {
                Button {
                    performLaunchAndMatch()
                } label: {
                    Label("Launch & Match", systemImage: "plus.magnifyingglass")
                }
                .buttonStyle(.bordered)
                .disabled(customDirectory.isEmpty && effectiveTitle.isEmpty)

                Button {
                    performLaunchWithReuse()
                } label: {
                    Label("Reuse or Launch", systemImage: "arrow.triangle.2.circlepath")
                }
                .buttonStyle(.borderedProminent)
                .disabled(customDirectory.isEmpty && effectiveTitle.isEmpty)
            }

            Text("Launch New: Always creates new window\nMatch: Check if window exists\nLaunch & Match: Creates then verifies\nReuse or Launch: Uses existing or creates new")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }


    private var resultsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Results")
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundStyle(.secondary)

            if let result = launchResult {
                LaunchResultView(result: result)
            }

            if let result = matchResult {
                MatchTestResultView(result: result)
            }
        }
    }

    private var statusSection: some View {
        Group {
            if actionInProgress {
                HStack {
                    ProgressView()
                        .scaleEffect(0.8)
                    Text("Performing action...")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: - Computed Properties

    private var generatedBentoTitle: String {
        guard !customDirectory.isEmpty else { return "\(BundleIdentity.terminalTitleTokenPrefix):unknown:0" }
        let expanded = (customDirectory as NSString).expandingTildeInPath
        let basename = (expanded as NSString).lastPathComponent
        return "\(BundleIdentity.terminalTitleTokenPrefix):\(basename):0"
    }

    /// Binding that allows editing the title, but updates customTitle when auto is off
    private var titleBinding: Binding<String> {
        Binding(
            get: {
                autoGenerateTitle ? generatedBentoTitle : customTitle
            },
            set: { newValue in
                // When user edits, disable auto-generate
                if autoGenerateTitle && newValue != generatedBentoTitle {
                    autoGenerateTitle = false
                }
                customTitle = newValue
            }
        )
    }

    private var effectiveTitle: String {
        if selectedLauncher.supportsTitle {
            return autoGenerateTitle ? generatedBentoTitle : customTitle
        }
        return ""
    }

    // MARK: - Actions

    private func populateFromWindow() {
        guard let window = window else { return }

        // Auto-select launcher based on bundle ID
        if let bundleId = window.bundleId {
            for launcher in LauncherSelection.allCases {
                if launcher.bundleId == bundleId {
                    selectedLauncher = launcher
                    break
                }
            }
        }

        // Populate directory from documentPath or parsed working directory
        if let docPath = window.documentPath {
            customDirectory = docPath
        }

        // Populate title if it looks like a managed terminal title
        if let title = window.title,
           title.hasPrefix("\(BundleIdentity.terminalTitleTokenPrefix):") {
            customTitle = title
            autoGenerateTitle = false
        }
    }

    private func performLaunch() {
        actionInProgress = true
        launchResult = nil
        matchResult = nil

        Task { @MainActor in
            let result = await executeLaunch(wasReused: false)
            launchResult = result
            actionInProgress = false

            // Refresh after launch
            await Task.sleepUnlessCancelled(for: .milliseconds(500))
            onRefresh()
        }
    }

    private func performLaunchAndMatch() {
        actionInProgress = true
        launchResult = nil
        matchResult = nil

        Task { @MainActor in
            // Launch
            let launchRes = await executeLaunch(wasReused: false)
            launchResult = launchRes

            // Wait for window to appear
            await Task.sleepUnlessCancelled(for: .milliseconds(1000))

            // Refresh snapshot
            onRefresh()
            await Task.sleepUnlessCancelled(for: .milliseconds(300))

            // Try to match
            matchResult = await executeMatchTest()

            actionInProgress = false
        }
    }

    private func performLaunchWithReuse() {
        actionInProgress = true
        launchResult = nil
        matchResult = nil

        Task { @MainActor in
            // First, try to match an existing window
            let existingMatch = await executeMatchTest()

            if existingMatch.found {
                // Found existing window - report as reused
                matchResult = existingMatch
                launchResult = LaunchTestResult(
                    success: true,
                    method: "reused",
                    durationMs: 0,
                    notes: ["Reused existing window with title: \(existingMatch.matchedTitle ?? "unknown")"],
                    wasReused: true
                )
            } else {
                // No match found - launch new window
                let launchRes = await executeLaunch(wasReused: false)
                launchResult = launchRes

                // Wait for window to appear
                await Task.sleepUnlessCancelled(for: .milliseconds(1000))

                // Refresh snapshot
                onRefresh()
                await Task.sleepUnlessCancelled(for: .milliseconds(300))

                // Try to match the newly created window
                matchResult = await executeMatchTest()
            }

            actionInProgress = false
        }
    }

    private func performMatchTest() {
        actionInProgress = true
        matchResult = nil

        Task { @MainActor in
            matchResult = await executeMatchTest()
            actionInProgress = false
        }
    }

    private func executeLaunch(wasReused: Bool) async -> LaunchTestResult {
        let startTime = Date()
        let expandedDir = customDirectory.isEmpty ? nil : (customDirectory as NSString).expandingTildeInPath
        let title = effectiveTitle.isEmpty ? nil : effectiveTitle

        // Create a dummy task context for logging
        let taskType: RestorationTaskType = selectedLauncher.isTerminal ? .terminal : .ide
        let taskContext = RestorationTaskContext(
            taskId: "launcher_test",
            taskType: taskType,
            runId: "test_\(Int(Date().timeIntervalSince1970))"
        )

        do {
            let launcher = getLauncher()

            // Use extended launch for IDEs with mode support
            if !selectedLauncher.isTerminal, let ideLauncher = launcher as? FluentIDELauncher {
                let result = try await ideLauncher.launchWithMode(
                    directory: expandedDir,
                    mode: ideLaunchMode,
                    fileWithLine: ideLaunchMode == .gotoLine ? gotoLineInput : nil,
                    diffFiles: ideLaunchMode == .diffFiles ? (diffFile1, diffFile2) : nil,
                    task: taskContext
                )

                return LaunchTestResult(
                    success: result.success,
                    method: "\(result.method.rawValue) (\(ideLaunchMode.rawValue))",
                    durationMs: result.launchDurationMs,
                    notes: result.notes,
                    wasReused: wasReused
                )
            }

            // Standard launch for terminals
            let result = try await launcher.launch(
                directory: expandedDir,
                title: title,
                task: taskContext
            )

            return LaunchTestResult(
                success: result.success,
                method: result.method.rawValue,
                durationMs: result.launchDurationMs,
                notes: result.notes,
                wasReused: wasReused
            )
        } catch {
            let durationMs = Int(Date().timeIntervalSince(startTime) * 1000)
            return LaunchTestResult(
                success: false,
                method: "error",
                durationMs: durationMs,
                notes: ["Error: \(error.localizedDescription)"],
                wasReused: false
            )
        }
    }

    private func executeMatchTest() async -> MatchTestResult {
        let expandedDir = customDirectory.isEmpty ? nil : (customDirectory as NSString).expandingTildeInPath
        let title = effectiveTitle.isEmpty ? nil : effectiveTitle

        // Create a dummy task context for logging
        let taskType: RestorationTaskType = selectedLauncher.isTerminal ? .terminal : .ide
        let taskContext = RestorationTaskContext(
            taskId: "match_test",
            taskType: taskType,
            runId: "test_\(Int(Date().timeIntervalSince1970))"
        )

        guard let snapshot = snapshot else {
            return MatchTestResult(
                found: false,
                confidence: nil,
                method: nil,
                windowId: nil,
                matchedTitle: "No snapshot available"
            )
        }

        // Convert to SystemSnapshot for launcher matching
        let expSnapshot = SystemSnapshot(
            captureTime: snapshot.captureTime,
            captureDurationMs: snapshot.captureDurationMs,
            runId: snapshot.runId,
            displays: snapshot.displays,
            windows: snapshot.windows
        )

        let launcher = getLauncher()
        let match = launcher.matchWindow(
            in: expSnapshot,
            directory: expandedDir,
            title: title,
            task: taskContext
        )

        if let match = match {
            return MatchTestResult(
                found: true,
                confidence: match.confidence.confidenceValue,
                method: match.method.rawValue,
                windowId: match.window.windowId,
                matchedTitle: match.window.title
            )
        } else {
            return MatchTestResult(
                found: false,
                confidence: nil,
                method: nil,
                windowId: nil,
                matchedTitle: nil
            )
        }
    }

    private func getLauncher() -> any FluentAppLauncher {
        switch selectedLauncher {
        case .ghostty:
            return FluentGhosttyLauncher()
        case .terminal:
            return FluentTerminalLauncher.terminal()
        case .iTerm:
            return FluentTerminalLauncher.iTerm()
        case .kitty:
            return FluentKittyLauncher()
        case .alacritty:
            return FluentAlacrittyLauncher()
        case .cursor:
            return FluentIDELauncher.cursor()
        case .codex:
            return FluentCodexLauncher()
        case .vscode:
            return FluentIDELauncher.vscode()
        }
    }
}

// MARK: - Match Confidence Extension

extension ExpMatchConfidence {
    var confidenceValue: Double {
        switch self {
        case .exact: return 1.0
        case .high: return 0.85
        case .medium: return 0.65
        case .low: return 0.2
        }
    }
}
