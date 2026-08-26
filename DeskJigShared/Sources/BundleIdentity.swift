import Foundation

/// Single source of truth for DeskJig's bundle-level identity strings. 
///
/// **Every value here is a legacy identifier inherited from the app's commercial
/// predecessor and MUST NOT change.** Existing installs key their macOS permission
/// grants (TCC), saved workspaces, running tmux sessions, terminal window titles and
/// URL-scheme registration to these exact strings; changing one is a breaking
/// migration, not a rename. See `docs/LEGACY_IDENTIFIERS.md`.
///
/// The Swift symbol names are DeskJig's; only the *values* are frozen.
public enum BundleIdentity {

    // MARK: - Bundle

    /// Application bundle identifier. Anchors Accessibility / Screen Recording /
    /// AppleEvents TCC grants, the keychain access group and update identity.
    public static let bundleID = "com.mscontrol.bento"

    /// Privileged helper tool bundle identifier (SMJobBless label for the
    /// bentoctl CLI installer). Matches `helperLabel` in
    /// `Nexus/CLIHelper/BentoCLIBlessHelper.swift`, `Nexus/Model/BentoCLIInstaller.swift`,
    /// and `bentoctl/Commands/InstallCommand.swift` — must stay byte-identical or the
    /// installed helper's launchd label stops matching.
    public static let helperBundleID = "com.mscontrol.bento.bentoctl-helper"

    // MARK: - Defaults

    /// Shared `UserDefaults` suite read and written by both the app and the CLI.
    /// This is *the* app↔CLI data contract.
    public static let defaultsSuiteName = "com.mscontrol.bento"

    /// Key holding the saved workspace collection inside `defaultsSuiteName`.
    public static let savedWorkspacesKey = "SavedWorkspaces"

    /// Release-build gate for the `bento://restore` URL.
    public static let allowAppRestoreURLKey = "BentoAllowAppRestoreURL"

    /// Shared defaults suite, or `.standard` if the suite cannot be opened.
    public static var sharedDefaults: UserDefaults {
        UserDefaults(suiteName: defaultsSuiteName) ?? .standard
    }

    // MARK: - URL scheme

    /// Registered URL scheme (without the `://`).
    public static let urlScheme = "bento"

    // MARK: - Notifications

    /// `DistributedNotificationCenter` name used to tell the other side (app or CLI)
    /// that the saved-workspace store changed underneath it.
    public static let workspacesChangedNotificationName = "com.mscontrol.bento.workspaces-changed-externally"

    // MARK: - Filesystem

    /// Directory name under `~/Library/Logs` holding all app + CLI logs.
    public static let logDirectoryName = "Bento"

    /// Absolute log directory URL (`~/Library/Logs/Bento`).
    public static var logDirectoryURL: URL {
        FileManager.default
            .homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs", isDirectory: true)
            .appendingPathComponent(logDirectoryName, isDirectory: true)
    }

    /// Subdirectory of `logDirectoryURL` holding per-run restoration traces.
    public static let restoreTraceDirectoryName = "restore-trace"

    /// Install path of the legacy CLI symlink kept for compatibility.
    public static let legacyCLIInstallPath = "/usr/local/bin/bentoctl"

    // MARK: - tmux

    /// Prefix of the tmux server socket: `/tmp/deskjig-tmux-<uid>.sock`.
    /// Renamed from the legacy `bento-tmux` by maintainer decision (2026-08-25):
    /// sessions on the old socket become unmanaged after upgrade and are
    /// recreated on the next workspace restore — the same outcome as the
    /// Reset Sessions button, accepted as a one-time break.
    public static let tmuxSocketPrefix = "deskjig-tmux"

    /// Absolute tmux socket path for the current user.
    public static var tmuxSocketPath: String {
        "/tmp/\(tmuxSocketPrefix)-\(getuid()).sock"
    }

    // MARK: - Terminal window titles

    /// Leading token of the managed terminal window title: `bento:<dir>:<idx>`.
    /// These titles live on already-open terminal windows and inside saved
    /// snapshots — matching breaks on the first restore after a rename.
    public static let terminalTitleTokenPrefix = "bento"

    // MARK: - Uniform type identifiers

    /// Exported UTI for `.windowsnapshot` files.
    public static let windowSnapshotUTI = "com.nexus.windowsnapshot"

    // MARK: - Chrome

    /// Native-messaging host identifier the published Chrome extension pairs with.
    public static let nativeMessagingHostID = "com.bento.native"
}
