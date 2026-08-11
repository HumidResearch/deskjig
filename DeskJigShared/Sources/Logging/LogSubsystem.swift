public enum LogSubsystem: String, Sendable, CaseIterable {
    // Restoration pipeline
    case restorationOrchestrator = "restore.orchestrator"
    case restorationExecutor = "restore.executor"
    case restorationPlanner = "restore.planner"
    case restorationChrome = "restore.chrome"
    case restorationPositioning = "restore.positioning"
    case restorationPostRestore = "restore.postRestore"
    case restorationSnapshot = "restore.snapshot"
    case restorationTrace = "restore.trace"

    // Window management
    case window = "window"
    case windowPositioning = "window.positioning"

    // Workspace
    case workspace = "workspace"

    // Terminal/tmux
    case tmux = "tmux"
    case terminal = "terminal"

    // Chrome
    case chrome = "chrome"

    // CLI
    case cli = "cli"

    // Permissions
    case permissions = "permissions"

    // Onboarding
    case onboarding = "onboarding"

    // App lifecycle
    case app = "app"
    case telemetry = "telemetry"

    /// Category prefix for wildcard matching (e.g., "restore" for "restore.executor")
    public var category: String { rawValue.components(separatedBy: ".").first ?? rawValue }
}
