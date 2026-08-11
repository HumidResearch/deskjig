//
//  WindowActionsView.swift
//  DeskJig
//
//  Actions panel for testing Fluent API window operations
//

import SwiftUI
import DeskJigShared

// MARK: - Finder Method Selection

/// Available methods for finding windows in the Fluent API
enum WindowFinderSelection: String, CaseIterable, Identifiable {
    case windowId = "Window ID"
    case pidAndFrame = "PID + Frame"
    case pidAndTitle = "PID + Title"
    case frameOnly = "Frame Only"
    case titleExact = "Exact Title"
    case appName = "App Name"
    case bundleId = "Bundle ID"

    var id: String { rawValue }

    var description: String {
        switch self {
        case .windowId: return "Most precise - uses CGWindowID"
        case .pidAndFrame: return "PID + frame position"
        case .pidAndTitle: return "PID + exact window title"
        case .frameOnly: return "Frame position only"
        case .titleExact: return "Exact window title"
        case .appName: return "App display name (risky for Chrome)"
        case .bundleId: return "Bundle identifier"
        }
    }

    var warningMessage: String? {
        switch self {
        case .appName: return "May match wrong window for multi-window apps"
        case .bundleId: return "May match wrong window for multi-window apps"
        case .frameOnly: return "Frame positions can overlap"
        default: return nil
        }
    }

    var precisionLevel: Int {
        switch self {
        case .windowId: return 5
        case .pidAndFrame: return 4
        case .pidAndTitle: return 4
        case .frameOnly: return 3
        case .titleExact: return 3
        case .bundleId: return 2
        case .appName: return 1
        }
    }
}

// MARK: - Match Result Display

struct MatchResultView: View {
    let result: WindowFinderResult?
    let infoResult: WindowInfoFinderResult?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let result = result {
                HStack {
                    Image(systemName: result.isSuccess ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .foregroundStyle(result.isSuccess ? DesignTokens.Brand.accent : DesignTokens.Status.error)
                    Text(result.isSuccess ? "Match Found" : "No Match")
                        .font(.caption)
                        .fontWeight(.semibold)
                }

                Group {
                    LabeledContent("Method", value: result.matchMethod.rawValue)
                    LabeledContent("Duration", value: String(format: "%.1fms", result.matchDuration * 1000))
                    LabeledContent("Checked", value: "\(result.candidatesChecked) windows")

                    if let details = result.matchDetails {
                        Text(details)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }

                    Text("Criteria: \(result.inputCriteria.summary)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                .font(.caption)
            } else if let infoResult = infoResult {
                HStack {
                    Image(systemName: infoResult.isSuccess ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .foregroundStyle(infoResult.isSuccess ? DesignTokens.Brand.accent : DesignTokens.Status.error)
                    Text(infoResult.isSuccess ? "Info Found" : "Not Found")
                        .font(.caption)
                        .fontWeight(.semibold)
                }

                Group {
                    LabeledContent("Method", value: infoResult.matchMethod.rawValue)
                    LabeledContent("Duration", value: String(format: "%.1fms", infoResult.matchDuration * 1000))
                    LabeledContent("Checked", value: "\(infoResult.candidatesChecked) windows")

                    if let details = infoResult.matchDetails {
                        Text(details)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .font(.caption)
            }
        }
        .padding(8)
        .background(.quaternary)
        .cornerRadius(6)
    }
}

// MARK: - Main View

struct WindowActionsView: View {
    let window: SnapshotWindow?
    let onRefresh: () -> Void

    @State private var actionInProgress = false
    @State private var lastActionResult: String?
    @State private var selectedFinderMethod: WindowFinderSelection = .windowId
    @State private var selectedAXStrategy: AXMatchingStrategy = .frameOnly
    @State private var lastMatchResult: WindowFinderResult?
    @State private var showMatchDetails = true

    // Animation settings
    @State private var animationEnabled = false
    @State private var animationDuration: Double = 0.25
    @State private var selectedEasing: AnimationEasing = .easeOutCubic

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Window Actions")
                .font(.headline)

            if window == nil {
                Text("Select a window to perform actions")
                    .foregroundStyle(.secondary)
                    .font(.caption)
            } else {
                // Finder Method Selector
                finderMethodSection

                Divider()

                // Animation Controls
                animationControlsSection

                Divider()

                // Position Actions
                positionActionsSection

                Divider()

                // State Actions
                stateActionsSection

                Divider()

                // Dangerous Actions
                dangerousActionsSection

                // Match Result Details
                if showMatchDetails, lastMatchResult != nil {
                    Divider()
                    matchResultSection
                }

                // Status
                statusSection
            }
        }
        .disabled(window == nil || actionInProgress)
    }

    // MARK: - Sections

    private var finderMethodSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Finder Method")
                    .font(.subheadline)
                    .fontWeight(.semibold)
                    .foregroundStyle(.secondary)

                Spacer()

                Toggle("Details", isOn: $showMatchDetails)
                    .toggleStyle(.checkbox)
                    .font(.caption)
            }

            Picker("Method", selection: $selectedFinderMethod) {
                ForEach(WindowFinderSelection.allCases) { method in
                    HStack {
                        Text(method.rawValue)
                        if method.precisionLevel >= 4 {
                            Image(systemName: "star.fill")
                                .foregroundStyle(DesignTokens.Brand.accent)
                                .font(.caption2)
                        }
                    }
                    .tag(method)
                }
            }
            .pickerStyle(.menu)

            Text(selectedFinderMethod.description)
                .font(.caption2)
                .foregroundStyle(.secondary)

            // AX Matching Strategy selector (only for Window ID method)
            if selectedFinderMethod == .windowId {
                axMatchingStrategySection
            }

            if let warning = selectedFinderMethod.warningMessage {
                HStack(spacing: 4) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(DesignTokens.Brand.accent)
                    Text(warning)
                }
                .font(.caption2)
                .foregroundStyle(DesignTokens.Brand.accent)
            }
        }
    }

    private var axMatchingStrategySection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("AX Matching Strategy")
                .font(.caption2)
                .foregroundStyle(.tertiary)

            // Use menu picker instead of segmented to prevent overflow
            Picker("Strategy", selection: $selectedAXStrategy) {
                ForEach(AXMatchingStrategy.allCases) { strategy in
                    Text(strategy.rawValue).tag(strategy)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()

            Text(selectedAXStrategy.description)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)

            if let warning = selectedAXStrategy.warningMessage {
                HStack(spacing: 4) {
                    Image(systemName: "info.circle")
                        .foregroundStyle(DesignTokens.Brand.accent)
                    Text(warning)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .font(.caption2)
                .foregroundStyle(DesignTokens.Brand.accent)
            }
        }
        .padding(6)
        .background(.quinary)
        .cornerRadius(6)
    }

    private var animationControlsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Animation")
                .font(.subheadline)
                .fontWeight(.semibold)
                .foregroundStyle(.secondary)

            Toggle("Enable Animation", isOn: $animationEnabled)
                .toggleStyle(.checkbox)
                .font(.caption)

            if animationEnabled {
                VStack(alignment: .leading, spacing: 4) {
                    // Duration slider
                    HStack {
                        Text("Duration")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                        Spacer()
                        Text(String(format: "%.2fs", animationDuration))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    Slider(value: $animationDuration, in: 0.1...1.0, step: 0.05)
                        .controlSize(.small)

                    // Easing picker
                    Picker("Easing", selection: $selectedEasing) {
                        ForEach(AnimationEasing.allCases) { easing in
                            Text(easing.displayName).tag(easing)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .font(.caption)
                }
                .padding(6)
                .background(.quinary)
                .cornerRadius(6)
            }
        }
    }

    private var positionActionsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Position")
                .font(.subheadline)
                .fontWeight(.semibold)
                .foregroundStyle(.secondary)

            // Halves row
            HStack(spacing: 4) {
                ActionButton(label: "Left", icon: "rectangle.lefthalf.filled") {
                    performPositionAction { $0.moveToLeftHalf(animated: animationEnabled, options: currentAnimationOptions) }
                }
                ActionButton(label: "Right", icon: "rectangle.righthalf.filled") {
                    performPositionAction { $0.moveToRightHalf(animated: animationEnabled, options: currentAnimationOptions) }
                }
                ActionButton(label: "Top", icon: "rectangle.tophalf.filled") {
                    performPositionAction { $0.moveToTopHalf(animated: animationEnabled, options: currentAnimationOptions) }
                }
                ActionButton(label: "Bottom", icon: "rectangle.bottomhalf.filled") {
                    performPositionAction { $0.moveToBottomHalf(animated: animationEnabled, options: currentAnimationOptions) }
                }
            }

            // Quarters row
            HStack(spacing: 4) {
                ActionButton(label: "TL", icon: "rectangle.topthird.inset.filled") {
                    performPositionAction { $0.moveToTopLeftQuarter(animated: animationEnabled, options: currentAnimationOptions) }
                }
                ActionButton(label: "TR", icon: "rectangle.topthird.inset.filled") {
                    performPositionAction { $0.moveToTopRightQuarter(animated: animationEnabled, options: currentAnimationOptions) }
                }
                ActionButton(label: "BL", icon: "rectangle.bottomthird.inset.filled") {
                    performPositionAction { $0.moveToBottomLeftQuarter(animated: animationEnabled, options: currentAnimationOptions) }
                }
                ActionButton(label: "BR", icon: "rectangle.bottomthird.inset.filled") {
                    performPositionAction { $0.moveToBottomRightQuarter(animated: animationEnabled, options: currentAnimationOptions) }
                }
            }

            // Full/Center row
            HStack(spacing: 4) {
                ActionButton(label: "Max", icon: "rectangle.fill") {
                    performPositionAction { $0.maximize(animated: animationEnabled, options: currentAnimationOptions) }
                }
                ActionButton(label: "Center", icon: "rectangle.center.inset.filled") {
                    performPositionAction { $0.center(animated: animationEnabled, options: currentAnimationOptions) }
                }
            }
        }
    }

    /// Current animation options based on UI settings
    private var currentAnimationOptions: WindowAnimationOptions {
        WindowAnimationOptions(
            duration: animationDuration,
            easing: selectedEasing,
            staggerDelay: 0
        )
    }

    private var stateActionsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("State")
                .font(.subheadline)
                .fontWeight(.semibold)
                .foregroundStyle(.secondary)

            HStack(spacing: 4) {
                ActionButton(label: "Raise", icon: "arrow.up.square") {
                    performAction { $0.raise() }
                }
                ActionButton(label: "Activate", icon: "star.fill") {
                    performAction { $0.activate() }
                }
                ActionButton(label: "Tap", icon: "hand.tap.fill") {
                    performAction { $0.tap() }
                }
            }

            HStack(spacing: 4) {
                ActionButton(label: "Min", icon: "minus.circle") {
                    performAction { $0.minimize() }
                }
                ActionButton(label: "Restore", icon: "arrow.up.left.and.arrow.down.right") {
                    performAction { $0.unminimize() }
                }
                ActionButton(label: "Screenshot", icon: "camera.fill") {
                    performScreenshot()
                }
            }

            HStack(spacing: 4) {
                ActionButton(label: "Hide App", icon: "eye.slash") {
                    performAction { $0.hide() }
                }
                ActionButton(label: "Unhide", icon: "eye") {
                    performAction { $0.unhide() }
                }
            }
        }
    }

    private var dangerousActionsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Dangerous")
                .font(.subheadline)
                .fontWeight(.semibold)
                .foregroundStyle(DesignTokens.Status.error)

            ActionButton(label: "Close Window", icon: "xmark.circle.fill", destructive: true) {
                performAction { $0.close() }
            }
        }
    }

    private var matchResultSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Last Match Result")
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundStyle(.secondary)

            MatchResultView(result: lastMatchResult, infoResult: nil)
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
            } else if let result = lastActionResult {
                Text(result)
                    .font(.caption)
                    .foregroundStyle(result.contains("Failed") ? DesignTokens.Status.error : DesignTokens.Brand.accent)
            }
        }
    }

    // MARK: - Action Execution

    private func performAction(_ action: @escaping (WindowHandle) -> WindowHandle?) {
        guard let window = window else { return }

        actionInProgress = true
        lastActionResult = nil
        lastMatchResult = nil

        Task { @MainActor in
            let matchResult = findWindowWithSelectedMethod(window)
            lastMatchResult = matchResult

            if let handle = matchResult.window {
                let result = action(handle)
                if result != nil {
                    lastActionResult = "Success via \(selectedFinderMethod.rawValue)"
                    WindowHighlightOverlay.shared.showHighlight(around: window.frame)
                } else {
                    lastActionResult = "Action returned nil"
                }
            } else {
                lastActionResult = "Failed: \(matchResult.matchDetails ?? "Window not found")"
            }

            // Small delay before refresh to let the window settle
            await Task.sleepUnlessCancelled(for: .milliseconds(200))
            onRefresh()
            actionInProgress = false
        }
    }

    /// Performs a position action with animation support
    private func performPositionAction(_ action: @escaping (WindowHandle) -> WindowHandle?) {
        guard let window = window else { return }

        actionInProgress = true
        lastActionResult = nil
        lastMatchResult = nil

        Task { @MainActor in
            let matchResult = findWindowWithSelectedMethod(window)
            lastMatchResult = matchResult

            if let handle = matchResult.window {
                let result = action(handle)
                if result != nil {
                    let animationNote = animationEnabled ? " (animated)" : ""
                    lastActionResult = "Success via \(selectedFinderMethod.rawValue)\(animationNote)"
                    WindowHighlightOverlay.shared.showHighlight(around: window.frame)
                } else {
                    lastActionResult = "Action returned nil"
                }
            } else {
                lastActionResult = "Failed: \(matchResult.matchDetails ?? "Window not found")"
            }

            // Longer delay when animated to let animation complete
            let delay = animationEnabled ? Int(animationDuration * 1000 + 200) : 200
            await Task.sleepUnlessCancelled(for: .milliseconds(delay))
            onRefresh()
            actionInProgress = false
        }
    }

    /// Captures a screenshot of the selected window
    private func performScreenshot() {
        guard let window = window else { return }

        actionInProgress = true
        lastActionResult = nil

        Task { @MainActor in
            do {
                // Save to ~/Downloads with auto-generated filename
                let downloadsURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first!
                let filename = "window_\(window.windowId)_\(Int(Date().timeIntervalSince1970)).png"
                let path = downloadsURL.appendingPathComponent(filename).path

                try await WindowScreenshot.save(windowId: CGWindowID(window.windowId), to: path)
                lastActionResult = "Screenshot saved to Downloads/\(filename)"
            } catch {
                lastActionResult = "Screenshot failed: \(error.localizedDescription)"
            }

            actionInProgress = false
        }
    }

    private func findWindowWithSelectedMethod(_ window: SnapshotWindow) -> WindowFinderResult {
        switch selectedFinderMethod {
        case .windowId:
            return Window.findWithResult(windowId: window.windowId, axMatchStrategy: selectedAXStrategy)

        case .pidAndFrame:
            return Window.findWithResult(
                processID: window.pid,
                frame: window.frame,
                frameTolerance: 10
            )

        case .pidAndTitle:
            return Window.findWithResult(
                processID: window.pid,
                title: window.title
            )

        case .frameOnly:
            return Window.findWithResult(matchingFrame: window.frame, tolerance: 10)

        case .titleExact:
            if let title = window.title {
                return Window.findWithResult(title: title)
            } else {
                return WindowFinderResult.notFound(
                    method: .titleExact,
                    criteria: WindowFinderCriteria(),
                    duration: 0,
                    candidatesChecked: 0,
                    reason: "Window has no title"
                )
            }

        case .appName:
            if let appName = window.appName {
                return Window.findWithResult(appName: appName)
            } else {
                return WindowFinderResult.notFound(
                    method: .appName,
                    criteria: WindowFinderCriteria(),
                    duration: 0,
                    candidatesChecked: 0,
                    reason: "Window has no app name"
                )
            }

        case .bundleId:
            if let bundleId = window.bundleId {
                return Window.findWithResult(bundleID: bundleId)
            } else {
                return WindowFinderResult.notFound(
                    method: .bundleId,
                    criteria: WindowFinderCriteria(),
                    duration: 0,
                    candidatesChecked: 0,
                    reason: "Window has no bundle ID"
                )
            }
        }
    }
}

// MARK: - Action Button

struct ActionButton: View {
    let label: String
    let icon: String
    var destructive: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 2) {
                Image(systemName: icon)
                    .font(.caption)
                Text(label)
                    .font(.caption2)
            }
            .frame(minWidth: 40, minHeight: 36)
        }
        .buttonStyle(.bordered)
        .tint(destructive ? DesignTokens.Status.error : nil)
    }
}