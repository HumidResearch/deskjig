//
//  LaunchStrategyManager.swift
//  DeskJig
//
//  State manager for workspace launch configuration in the SnapshotViewer.
//  All settings are ephemeral - they reset when selecting a different workspace.
//

import SwiftUI
import DeskJigShared

// MARK: - Strategy Displayable Protocol

/// Protocol for strategy enums that provide a displayName for UI
protocol StrategyDisplayable {
    var displayName: String { get }
}

// MARK: - Strategy Enums

/// Match strategies for window restoration - aligned with MatchMethod from Fluent API
enum WindowMatchStrategy: String, CaseIterable, Identifiable, StrategyDisplayable {
    case documentPath = "documentPath"
    case bentoTitle = "bentoTitle"
    case titlePattern = "titlePattern"
    case frameMatch = "frameMatch"
    case bundleIdOnly = "bundleIdOnly"
    case chromeWindowId = "chromeWindowId"
    case chromeProfile = "chromeProfile"       // Chrome: Match by profile name
    case chromeTabUrls = "chromeTabUrls"       // Chrome: Match by tab URL overlap

    var id: String { rawValue }

    /// Human-readable display name with technical identifier for UI
    var displayName: String {
        switch self {
        case .documentPath: return "Document Path (documentPath)"
        case .bentoTitle: return "Terminal Title (bentoTitle)"
        case .titlePattern: return "Title Pattern (titlePattern)"
        case .frameMatch: return "Frame Match (frameMatch)"
        case .bundleIdOnly: return "Bundle ID Only (bundleIdOnly)"
        case .chromeWindowId: return "Chrome Window ID (chromeWindowId)"
        case .chromeProfile: return "Profile Match (chromeProfile)"
        case .chromeTabUrls: return "Tab URLs (chromeTabUrls)"
        }
    }

    var description: String {
        switch self {
        case .documentPath: return "Match by AX API document path (IDEs/editors)"
        case .bentoTitle: return "Match by exact \(BundleIdentity.terminalTitleTokenPrefix):dir:index title (terminals)"
        case .titlePattern: return "Match by window title pattern"
        case .frameMatch: return "Match by window position/size"
        case .bundleIdOnly: return "Match any window from app"
        case .chromeWindowId: return "Match by Chrome internal window ID"
        case .chromeProfile: return "Match by Chrome profile name (default for Chrome)"
        case .chromeTabUrls: return "Match by overlapping tab URLs"
        }
    }

    /// Convert to Fluent API MatchMethod
    func toMatchMethod() -> MatchMethod {
        switch self {
        case .documentPath: return .documentPath
        case .bentoTitle: return .bentoTitle
        case .titlePattern: return .titlePattern
        case .frameMatch: return .frameMatch
        case .bundleIdOnly: return .bundleIdOnly
        case .chromeWindowId: return .chromeWindowId
        case .chromeProfile: return .chromeProfile
        case .chromeTabUrls: return .chromeTabUrls
        }
    }

    /// Create from Fluent API MatchMethod
    static func from(_ method: MatchMethod) -> WindowMatchStrategy {
        switch method {
        case .documentPath: return .documentPath
        case .bentoTitle: return .bentoTitle
        case .titlePattern: return .titlePattern
        case .frameMatch: return .frameMatch
        case .bundleIdOnly: return .bundleIdOnly
        case .chromeWindowId: return .chromeWindowId
        case .chromeProfile: return .chromeProfile
        case .chromeTabUrls: return .chromeTabUrls
        }
    }
}

/// Launch methods for app launching - aligned with ExpLaunchMethod from Fluent API
enum AppLaunchMethod: String, CaseIterable, Identifiable, StrategyDisplayable {
    case cli = "cli"
    case commandFile = "commandFile"
    case appleScript = "appleScript"
    case open = "open"
    case workspaceFile = "workspaceFile"

    var id: String { rawValue }

    /// Human-readable display name with technical identifier for UI
    var displayName: String {
        switch self {
        case .cli: return "CLI (cli)"
        case .commandFile: return "Command File (commandFile)"
        case .appleScript: return "AppleScript (appleScript)"
        case .open: return "Open Command (open)"
        case .workspaceFile: return "Workspace File (workspaceFile)"
        }
    }

    var description: String {
        switch self {
        case .cli: return "Direct CLI invocation (Cursor, VS Code, Ghostty, Kitty, Alacritty)"
        case .commandFile: return "Shell .command file (Terminal.app, iTerm2)"
        case .appleScript: return "AppleScript automation"
        case .open: return "macOS open command"
        case .workspaceFile: return "IDE .code-workspace file launch"
        }
    }

    /// Convert to Fluent API ExpLaunchMethod
    func toExpLaunchMethod() -> ExpLaunchMethod {
        switch self {
        case .cli: return .cli
        case .commandFile: return .commandFile
        case .appleScript: return .appleScript
        case .open: return .open
        case .workspaceFile: return .workspaceFile
        }
    }

    /// Create from Fluent API ExpLaunchMethod
    static func from(_ expMethod: ExpLaunchMethod) -> AppLaunchMethod {
        switch expMethod {
        case .cli: return .cli
        case .commandFile: return .commandFile
        case .appleScript: return .appleScript
        case .open: return .open
        case .workspaceFile: return .workspaceFile
        }
    }
}

/// Method for restoring Chrome tabs in existing windows
enum ChromeRestoreMethod: String, CaseIterable, Identifiable, StrategyDisplayable {
    case appleScript = "appleScript"  // Default - reliable, no extension needed
    case native = "native"            // Faster, requires extension connected

    var id: String { rawValue }

    /// Human-readable display name with technical identifier for UI
    var displayName: String {
        switch self {
        case .appleScript: return "AppleScript (appleScript)"
        case .native: return "Native Messaging (native)"
        }
    }

    var description: String {
        switch self {
        case .appleScript:
            return "AppleScript automation - reliable, no extension needed (~200ms)"
        case .native:
            return "Chrome extension API - faster, requires extension connected (~50ms)"
        }
    }
}

/// Launch execution mode
enum LaunchExecutionMode: String, CaseIterable, Identifiable {
    case parallel = "Parallel"
    case synchronous = "Synchronous"

    var id: String { rawValue }

    var description: String {
        switch self {
        case .parallel: return "Launch all windows concurrently (faster)"
        case .synchronous: return "Launch windows one at a time (more reliable)"
        }
    }
}

// MARK: - IDE Launch Mode Extension

/// Extension to add displayName to IDELaunchMode from DeskJigShared
extension IDELaunchMode: StrategyDisplayable {
    /// Human-readable display name with CLI flag for UI
    var displayName: String {
        switch self {
        case .newWindow: return "New Window (--new-window)"
        case .reuseWindow: return "Reuse Window (--reuse-window)"
        case .workspaceFile: return "Workspace File (.code-workspace)"
        case .gotoLine: return "Go to Line (--goto)"
        case .diffFiles: return "Diff Files (--diff)"
        }
    }
}

// MARK: - Per-Window Strategy

/// Per-window launch strategy configuration
struct WindowLaunchStrategy: Equatable {
    var matchMethod: WindowMatchStrategy = .bundleIdOnly  // Default to generic bundle matching
    var launchMethod: AppLaunchMethod = .open
    var ideLaunchMode: IDELaunchMode = .reuseWindow  // Prefer reusing existing windows
    var chromeMethod: ChromeRestoreMethod = .appleScript
    var lockPriority: LockPriority = .medium
    /// Override target screen index (nil = use original screen from workspace)
    var targetScreenIndex: Int? = nil
}

// MARK: - Debug Log Entry

/// A single debug log entry matching DeskJigLog format
struct DebugLogEntry: Identifiable, Equatable {
    let id: UUID
    let timestamp: Date
    let phase: RestorationPhase
    let runId: String
    let taskId: String?
    let elapsed: TimeInterval
    let message: String
    let data: [String: String]

    init(
        phase: RestorationPhase,
        runId: String,
        taskId: String? = nil,
        elapsed: TimeInterval,
        message: String,
        data: [String: String] = [:]
    ) {
        self.id = UUID()
        self.timestamp = Date()
        self.phase = phase
        self.runId = runId
        self.taskId = taskId
        self.elapsed = elapsed
        self.message = message
        self.data = data
    }

    /// Formatted log line in DeskJigLog style
    var formattedLine: String {
        let idPart = taskId.map { "\(runId):\($0)" } ?? runId
        let elapsedStr = String(format: "+%.3fs", elapsed)
        return "RT:[\(idPart)][\(phase.rawValue)]\(elapsedStr) \(message)"
    }

    /// Data summary for display
    var dataSummary: String? {
        guard !data.isEmpty else { return nil }
        return "(" + data.map { "\($0.key)=\($0.value)" }.joined(separator: ", ") + ")"
    }

    /// Color for phase
    var phaseColor: Color {
        switch phase {
        case .start: return DesignTokens.Brand.accent
        case .launch: return DesignTokens.Brand.accent
        case .match: return data["found"] == "true" ? DesignTokens.Brand.accent : DesignTokens.Status.error
        case .position: return data["success"] == "true" ? DesignTokens.Brand.accent : DesignTokens.Status.error
        case .chrome: return DesignTokens.Brand.accent
        case .ide: return DesignTokens.Brand.accent
        case .complete: return data["success"] == "true" ? DesignTokens.Brand.accent : DesignTokens.Status.error
        case .lock:
            // Color based on lock result
            if message.contains("ACQUIRED") { return DesignTokens.Brand.accent }
            if message.contains("RELEASED") { return DesignTokens.Brand.accent }
            if message.contains("DENIED") || message.contains("TIMEOUT") { return DesignTokens.Status.error }
            if message.contains("QUEUED") { return DesignTokens.Brand.accent }
            return DesignTokens.Text.secondary
        case .partition, .handler, .openByPath, .pending, .postRestore, .task, .hide, .tmux:
            return DesignTokens.Text.secondary
        }
    }

    static func == (lhs: DebugLogEntry, rhs: DebugLogEntry) -> Bool {
        lhs.id == rhs.id
    }
}

// MARK: - Launch Strategy Manager

/// ViewModel/state manager for launch configuration.
/// All settings are ephemeral - they reset when selecting a different workspace.
@Observable
final class LaunchStrategyManager {

    // MARK: - Global Options

    /// Whether to use window locks during restoration
    var useWindowLocks: Bool = true

    /// Timeout for window locks
    var lockTimeout: Int = 10  // seconds

    /// Preview mode - don't actually launch, just simulate
    var isDryRun: Bool = false

    /// Launch execution mode (parallel vs synchronous)
    var executionMode: LaunchExecutionMode = .parallel

    // MARK: - Chrome Supplementation Options

    /// Whether to enable Chrome supplementation for better profile matching
    var enableChromeSupplementation: Bool = true

    /// Method to use for fetching Chrome tab URLs during supplementation
    var chromeFetchMethod: ChromeFetchMethod = .appleScript

    // MARK: - Terminal Supplementation Options

    /// Whether to enable terminal supplementation for better working directory matching
    var enableTerminalSupplementation: Bool = true

    /// Method to use for fetching terminal working directories during supplementation
    var terminalFetchMethod: TerminalFetchMethod = .axWithLsofFallback

    // MARK: - IDE Supplementation Options

    /// Whether to enable IDE supplementation for better document path matching
    var enableIDESupplementation: Bool = true

    /// Method to use for fetching IDE document paths during supplementation
    var ideFetchMethod: IDEFetchMethod = .cursorStateWithAXFallback

    // MARK: - Post-Restoration Options

    /// Whether to raise all workspace windows to the front after restoration completes.
    /// This ensures the restored workspace is visible and in the correct z-order.
    /// Default: true - matches the behavior of the legacy restoration path.
    var raiseWindowsAfterRestore: Bool = true

    /// Delay in milliseconds before raising windows after positioning.
    /// Allows windows to settle before z-order manipulation.
    var raiseDelayMs: Int = 100

    private let raisePositioningService = WindowPositioningService(lockManager: WindowLockManager())

    // MARK: - Per-Window Strategies

    /// Per-window strategy overrides keyed by WorkspaceWindow.id
    var windowStrategies: [UUID: WindowLaunchStrategy] = [:]

    // MARK: - Debug Log

    /// Debug log entries from restoration
    var logEntries: [DebugLogEntry] = []

    /// Whether a launch is currently in progress
    var isLaunching: Bool = false

    /// Current run ID for this launch
    var currentRunId: String?

    /// Start time for elapsed calculation
    private var launchStartTime: Date?
    private let chromeMatcher = ChromeWindowMatcher()

    // MARK: - UI State

    /// Whether the debug log section is expanded
    var isDebugLogExpanded: Bool = false

    /// Filter for debug log entries
    var logFilter: String = ""

    /// Selected window ID for detail view
    var selectedWindowId: UUID?

    // MARK: - Computed Properties

    /// Filtered log entries based on filter string
    var filteredLogEntries: [DebugLogEntry] {
        guard !logFilter.isEmpty else { return logEntries }
        return logEntries.filter { entry in
            entry.message.localizedCaseInsensitiveContains(logFilter) ||
            entry.phase.rawValue.localizedCaseInsensitiveContains(logFilter) ||
            entry.taskId?.localizedCaseInsensitiveContains(logFilter) == true
        }
    }

    // MARK: - Methods

    /// Reset all settings (called when workspace selection changes)
    func reset() {
        useWindowLocks = true
        lockTimeout = 10
        isDryRun = false
        executionMode = .parallel
        enableChromeSupplementation = true
        chromeFetchMethod = .appleScript
        enableTerminalSupplementation = true
        terminalFetchMethod = .axWithLsofFallback
        enableIDESupplementation = true
        ideFetchMethod = .cursorStateWithAXFallback
        raiseWindowsAfterRestore = true
        raiseDelayMs = 100
        windowStrategies.removeAll()
        screenOverrides.removeAll()
        screenMappings.removeAll()
        logEntries.removeAll()
        isLaunching = false
        currentRunId = nil
        launchStartTime = nil
        isDebugLogExpanded = false
        logFilter = ""
        selectedWindowId = nil
    }

    /// Reset and apply default strategies for the selected workspace.
    func prepareForWorkspace(_ workspace: WorkspaceHandle) {
        reset()
        applyDefaultStrategies(for: workspace)
    }

    /// Apply app-specific default strategies for each window in the workspace.
    func applyDefaultStrategies(for workspace: WorkspaceHandle) {
        for window in workspace.windows {
            let strategy = computeDefaultStrategy(for: window)
            setStrategy(strategy, for: window.id)
        }
    }

    // MARK: - Screen Overrides

    /// Per-window screen overrides keyed by WorkspaceWindow.id
    var screenOverrides: [UUID: Int] = [:]

    /// Get screen override for a window (nil = use original)
    func screenOverride(for windowId: UUID) -> Int? {
        screenOverrides[windowId]
    }

    /// Set screen override for a window
    func setScreenOverride(_ screenIndex: Int?, for windowId: UUID) {
        if let index = screenIndex {
            screenOverrides[windowId] = index
        } else {
            screenOverrides.removeValue(forKey: windowId)
        }
    }

    // MARK: - Screen Mappings (Bulk)

    /// Maps original screen index to target screen index for bulk redirection
    /// Key: original workspace screen index, Value: target system screen index
    var screenMappings: [Int: Int] = [:]

    /// Get target screen for an original screen index (nil = no mapping, use original)
    func screenMapping(for originalIndex: Int) -> Int? {
        screenMappings[originalIndex]
    }

    /// Set screen mapping for all windows on a screen
    func setScreenMapping(_ targetIndex: Int?, for originalIndex: Int) {
        if let target = targetIndex {
            screenMappings[originalIndex] = target
        } else {
            screenMappings.removeValue(forKey: originalIndex)
        }
    }

    /// Get effective screen for a window (considers both per-window override and screen mapping)
    /// Priority: per-window override > screen mapping > original
    func effectiveScreen(for window: WorkspaceWindow) -> Int {
        // Per-window override takes precedence
        if let windowOverride = screenOverrides[window.id] {
            return windowOverride
        }
        // Then screen mapping
        if let originalScreen = window.screenIndex,
           let mappedScreen = screenMappings[originalScreen] {
            return mappedScreen
        }
        // Otherwise use original
        return window.screenIndex ?? 0
    }

    /// Get strategy for a specific window, returning default if not set
    func strategy(for windowId: UUID) -> WindowLaunchStrategy {
        windowStrategies[windowId] ?? WindowLaunchStrategy()
    }

    /// Update strategy for a specific window
    func setStrategy(_ strategy: WindowLaunchStrategy, for windowId: UUID) {
        windowStrategies[windowId] = strategy
    }

    /// Reset strategy for a specific window to defaults
    func resetStrategy(for windowId: UUID) {
        windowStrategies.removeValue(forKey: windowId)
    }

    /// Compute the default strategy for a window based on its app type.
    private func computeDefaultStrategy(for window: WorkspaceWindow) -> WindowLaunchStrategy {
        var strategy = WindowLaunchStrategy()
        let bundleId = window.bundleIdentifier

        // Chrome apps
        if chromeBundleIdentifiers.contains(bundleId) {
            strategy.matchMethod = .chromeProfile
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
        if cliBundleIds.contains(bundleId) {
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
        if commandFileBundleIds.contains(bundleId) {
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
        if ideBundleIds.contains(bundleId) {
            strategy.matchMethod = .documentPath
            strategy.launchMethod = .cli
            strategy.ideLaunchMode = .reuseWindow
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

        // Default for unknown/generic apps
        strategy.matchMethod = .frameMatch
        strategy.launchMethod = .open
        strategy.lockPriority = .low
        return strategy
    }

    // MARK: - Launch Control

    /// Start a new launch session
    func startLaunch() {
        let runId = Self.generateRunId()
        TraceFileWriter.shared.start(runId: runId)

        currentRunId = runId
        launchStartTime = Date()
        isLaunching = true
        logEntries.removeAll()
        isDebugLogExpanded = true

        addLogEntry(
            phase: .start,
            message: "Beginning workspace restoration",
            data: [
                "dryRun": isDryRun ? "true" : "false",
                "useWindowLocks": useWindowLocks ? "true" : "false",
                "executionMode": executionMode.rawValue,
                "lockTimeout": "\(lockTimeout)s"
            ]
        )
    }

    /// Log a lock acquisition attempt
    func logLockAttempt(
        windowId: String,
        appName: String,
        priority: LockPriority,
        result: String,
        holder: String? = nil
    ) {
        var data: [String: String] = [
            "windowId": windowId,
            "app": appName,
            "priority": priority.description,
            "result": result
        ]
        if let holder = holder {
            data["currentHolder"] = holder
        }

        addLogEntry(
            phase: .match,
            taskId: appName.lowercased().replacingOccurrences(of: " ", with: "-"),
            message: "Lock \(result) for \(appName)",
            data: data
        )
    }

    /// Log a lock release
    func logLockRelease(windowId: String, appName: String) {
        addLogEntry(
            phase: .match,
            taskId: appName.lowercased().replacingOccurrences(of: " ", with: "-"),
            message: "Lock released for \(appName)",
            data: [
                "windowId": windowId,
                "app": appName,
                "action": "released"
            ]
        )
    }

    /// End the current launch session
    func endLaunch(success: Bool, windowCount: Int) {
        addLogEntry(
            phase: .complete,
            message: success ? "Restoration completed" : "Restoration failed",
            data: ["success": success ? "true" : "false", "windowCount": "\(windowCount)"]
        )
        isLaunching = false
    }

    /// Add a log entry
    func addLogEntry(
        phase: RestorationPhase,
        taskId: String? = nil,
        message: String,
        data: [String: String] = [:]
    ) {
        let elapsed = launchStartTime.map { Date().timeIntervalSince($0) } ?? 0
        let entry = DebugLogEntry(
            phase: phase,
            runId: currentRunId ?? "unknown",
            taskId: taskId,
            elapsed: elapsed,
            message: message,
            data: data
        )
        logEntries.append(entry)
    }

    /// Clear all log entries
    func clearLog() {
        logEntries.removeAll()
    }

    /// Generate a run ID in format: restore_HHMMSS_xxxxxx
    private static func generateRunId() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HHmmss"
        let timestamp = formatter.string(from: Date())
        let chars = "abcdefghijklmnopqrstuvwxyz0123456789"
        let suffix = String((0..<6).map { _ in chars.randomElement()! })
        return "restore_\(timestamp)_\(suffix)"
    }

    /// Export log as text
    func exportLog() -> String {
        logEntries.map { entry in
            var line = entry.formattedLine
            if let summary = entry.dataSummary {
                line += "\n  \(summary)"
            }
            return line
        }.joined(separator: "\n")
    }

    // MARK: - Post-Restore Operations

    /// Performs the post-restoration raise phase to bring all workspace windows to the front.
    /// This matches the behavior of the legacy restoration path (ensureWorkspaceWindowsOnTop).
    ///
    /// - Parameters:
    ///   - workspace: The workspace being restored
    ///   - chromeBundleIdentifiers: Set of Chrome bundle identifiers for profile matching
    /// - Returns: Number of windows successfully raised
    @discardableResult
    func performPostRestoreRaise(
        workspace: WorkspaceHandle,
        chromeBundleIdentifiers: Set<String>
    ) async -> Int {
        guard raiseWindowsAfterRestore else {
            addLogEntry(
                phase: .postRestore,
                message: "Skipping post-restore raise (disabled)",
                data: [:]
            )
            return 0
        }

        addLogEntry(
            phase: .postRestore,
            message: "Starting post-restore raise phase",
            data: ["delay": "\(raiseDelayMs)ms"]
        )

        // Small delay to let windows settle after positioning
        await Task.sleepUnlessCancelled(for: .milliseconds(raiseDelayMs))

        // Capture fresh snapshot to get current window states
        var finalSnapshot = await SystemSnapshotCapture.captureQuick(
            runId: "\(currentRunId ?? "unknown")-post"
        )

        let needsIDESupplementation = enableIDESupplementation &&
            workspace.windows.contains { BundleRegistry.isIDE($0.bundleIdentifier) }
        if needsIDESupplementation {
            addLogEntry(
                phase: .postRestore,
                message: "Post-restore IDE supplementation",
                data: ["method": ideFetchMethod.rawValue]
            )
            let ideSupplementationService = IDESupplementationService()
            finalSnapshot = await ideSupplementationService.supplementIDEWindows(
                in: finalSnapshot,
                method: ideFetchMethod,
                runId: currentRunId ?? "unknown"
            )
        }

        let needsChromeSupplementation = enableChromeSupplementation &&
            workspace.windows.contains { chromeBundleIdentifiers.contains($0.bundleIdentifier) }
        if needsChromeSupplementation {
            addLogEntry(
                phase: .postRestore,
                message: "Post-restore Chrome supplementation",
                data: ["method": chromeFetchMethod.rawValue]
            )
            let chromeSupplementationService = ChromeSupplementationService()
            finalSnapshot = await chromeSupplementationService.supplementChromeWindows(
                in: finalSnapshot,
                method: chromeFetchMethod,
                runId: currentRunId ?? "unknown"
            )
        }

        var raisedCount = 0

        // IDE bundle IDs that need special path-based matching
        let ideBundleIds: Set<String> = [
            "com.todesktop.230313mzl4w4u92",  // Cursor
            "com.microsoft.VSCode"
        ]

        // Raise each workspace window in order (last window in list will be topmost)
        for window in workspace.windows {
            // Find matching window in snapshot by bundle ID
            let candidates = finalSnapshot.windows.filter { $0.bundleId == window.bundleIdentifier }

            var matchedWindow: SnapshotWindow?
            var matchMethod = "none"
            var matchFailed = false

            // For terminals with managed titles, match by exact title
            if window.windowTitle.hasPrefix("\(BundleIdentity.terminalTitleTokenPrefix):") {
                matchedWindow = candidates.first { $0.title == window.windowTitle }
                matchMethod = matchedWindow != nil ? "bentoTitle" : "bentoTitle-failed"
                matchFailed = matchedWindow == nil
            }
            // For IDEs, match by document path containing the project folder
            // IMPORTANT: Do NOT fall back to generic matching - if no path match, skip raising
            else if let openPath = window.openPath, ideBundleIds.contains(window.bundleIdentifier) {
                let folderName = (openPath as NSString).lastPathComponent.lowercased()

                if let ideMatch = finalSnapshot.findIDEWindow(withDocumentPath: openPath, bundleId: window.bundleIdentifier) {
                    matchedWindow = ideMatch
                    matchMethod = "ideDocumentPath"
                } else {
                    matchedWindow = candidates.first {
                        ($0.ideDocumentPath ?? $0.documentPath)?.lowercased().contains(folderName) == true ||
                        $0.title?.lowercased().contains(folderName) == true
                    }
                    matchMethod = matchedWindow != nil ? "idePathFallback" : "idePath-failed"
                }

                matchFailed = matchedWindow == nil

                if matchFailed {
                    addLogEntry(
                        phase: .postRestore,
                        message: "IDE match failed - no window for project",
                        data: [
                            "app": window.appName,
                            "expectedFolder": folderName,
                            "candidateCount": "\(candidates.count)",
                            "candidateTitles": candidates.compactMap { $0.title }.joined(separator: "|")
                        ]
                    )
                }
            }
            // For Chrome, match by profile - use supplementation data when available
            // IMPORTANT: Do NOT fall back to generic matching - if no profile match, skip raising
            else if chromeBundleIdentifiers.contains(window.bundleIdentifier),
                    let chromeState = window.chromeState {
                let profileDisplayName = chromeState.appleScriptProfileName

                if let selection = chromeMatcher.selectRaiseCandidate(
                    candidates: candidates,
                    chromeState: chromeState
                ) {
                    matchedWindow = selection.window
                    matchMethod = selection.method
                } else {
                    let axMatches = chromeMatcher.matchWindowsByAxProfileForRaise(
                        candidates: candidates,
                        profileDisplayName: profileDisplayName
                    )

                    if axMatches.count == 1 {
                        matchedWindow = axMatches[0]
                        matchMethod = "chromeProfileAX"
                    } else if axMatches.count > 1 {
                        matchedWindow = axMatches.sorted {
                            ($0.zOrderIndex ?? Int.max) < ($1.zOrderIndex ?? Int.max)
                        }.first
                        matchMethod = "chromeProfileAXFrontmost"

                        addLogEntry(
                            phase: .postRestore,
                            message: "Chrome profile matched multiple windows; using frontmost",
                            data: [
                                "profile": profileDisplayName,
                                "candidateIds": axMatches.map { "\($0.windowId)" }.joined(separator: ",")
                            ]
                        )
                    } else {
                        matchedWindow = chromeMatcher.matchFallbackProfileWindow(
                            candidates: candidates,
                            profileDisplayName: profileDisplayName
                        )
                        matchMethod = matchedWindow != nil ? "chromeProfileFallback" : "chromeProfile-failed"
                    }
                }

                matchFailed = matchedWindow == nil

                if matchFailed {
                    addLogEntry(
                        phase: .postRestore,
                        message: "Chrome match failed - no window for profile",
                        data: [
                            "app": window.appName,
                            "expectedProfile": profileDisplayName,
                            "candidateCount": "\(candidates.count)",
                            "candidateTitles": candidates.compactMap { $0.title }.joined(separator: "|")
                        ]
                    )
                }
            }
            // Default: take first matching window by bundle ID (only for generic apps)
            else if !candidates.isEmpty {
                matchedWindow = candidates.first
                matchMethod = "bundleId"
            }

            if let snapshotWindow = matchedWindow {
                let handle: WindowHandle?

                if chromeBundleIdentifiers.contains(window.bundleIdentifier),
                   let chromeState = window.chromeState {
                    handle = chromeMatcher.resolveHandle(
                        snapshotWindow: snapshotWindow,
                        chromeState: chromeState
                    )
                    handle?.raise()?.activate()
                } else {
                    let preferredStrategy = WindowHandleResolver.preferredStrategy(
                        workspaceWindow: window,
                        snapshotWindow: snapshotWindow
                    )
                    handle = await raisePositioningService.raiseWindow(
                        windowId: snapshotWindow.windowId,
                        preferredStrategy: preferredStrategy
                    )
                }

                if let handle {
                    raisedCount += 1
                    var logData: [String: String] = [
                        "app": window.appName,
                        "windowId": "\(snapshotWindow.windowId)",
                        "title": snapshotWindow.title ?? "untitled",
                        "method": matchMethod
                    ]

                    if chromeBundleIdentifiers.contains(window.bundleIdentifier) {
                        logData["axTitle"] = handle.title ?? "unknown"
                    }

                    addLogEntry(
                        phase: .postRestore,
                        message: "Raised window",
                        data: logData
                    )
                } else {
                    addLogEntry(
                        phase: .postRestore,
                        message: "Could not get AX handle for matched window",
                        data: [
                            "app": window.appName,
                            "windowId": "\(snapshotWindow.windowId)",
                            "title": snapshotWindow.title ?? "untitled",
                            "method": matchMethod
                        ]
                    )
                }
            } else if matchFailed {
                // Already logged specific failure above
            } else if candidates.isEmpty {
                addLogEntry(
                    phase: .postRestore,
                    message: "No candidates for window",
                    data: [
                        "app": window.appName,
                        "bundleId": window.bundleIdentifier
                    ]
                )
            }
        }

        addLogEntry(
            phase: .postRestore,
            message: "Post-restore raise phase complete",
            data: ["raised": "\(raisedCount)", "total": "\(workspace.windowCount)"]
        )

        return raisedCount
    }

    // MARK: - Trace Log Integration

    /// Imports log entries from the TraceFileWriter NDJSON file.
    /// Uses the RestoreTraceLogReader API from DeskJigShared.
    /// Call this after restoration completes to show fluent API trace output.
    func importFluentApiTraceLogs() {
        guard RestoreTraceLogReader.hasLogs() else {
            let logPath = RestoreTraceLogReader.latestLogURL()?.path ?? RestoreTraceLogReader.logDirectoryURL.path
            addLogEntry(
                phase: .handler,
                message: "No trace log file found",
                data: ["path": logPath]
            )
            return
        }

        do {
            let traceEntries = try RestoreTraceLogReader.readLatest()
            let logFileName = RestoreTraceLogReader.latestLogURL()?.lastPathComponent ?? "restore-trace.ndjson"

            addLogEntry(
                phase: .handler,
                message: "Importing \(traceEntries.count) trace log entries from Fluent API",
                data: ["source": logFileName]
            )

            // Convert TraceLogEntry to DebugLogEntry
            for traceEntry in traceEntries {
                // Build data dictionary including frame info
                var entryData = traceEntry.data
                if let handler = traceEntry.handler {
                    entryData["handler"] = handler
                }
                if let window = traceEntry.window {
                    entryData["window"] = window
                }
                if let windowId = traceEntry.windowId {
                    entryData["windowId"] = windowId
                }
                if let frame = traceEntry.frame {
                    entryData["frame"] = "(\(Int(frame.origin.x)),\(Int(frame.origin.y)) \(Int(frame.width))x\(Int(frame.height)))"
                }
                if let targetFrame = traceEntry.targetFrame {
                    entryData["target"] = "(\(Int(targetFrame.origin.x)),\(Int(targetFrame.origin.y)) \(Int(targetFrame.width))x\(Int(targetFrame.height)))"
                }

                let entry = DebugLogEntry(
                    phase: traceEntry.phase,
                    runId: traceEntry.runId,
                    taskId: traceEntry.taskId,
                    elapsed: traceEntry.elapsed,
                    message: traceEntry.message,
                    data: entryData
                )
                logEntries.append(entry)
            }

            addLogEntry(
                phase: .handler,
                message: "Trace log import complete",
                data: ["entriesImported": "\(traceEntries.count)"]
            )

        } catch {
            addLogEntry(
                phase: .handler,
                message: "Failed to read trace log: \(error.localizedDescription)",
                data: ["error": error.localizedDescription]
            )
        }
    }

}
