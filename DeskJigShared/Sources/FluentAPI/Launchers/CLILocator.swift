//  CLILocator.swift
//  DeskJigShared

import Foundation
import AppKit

// MARK: - CLI Locator

/// Public API for detecting CLI installation status for various apps.
///
/// ## Example
///
/// ```swift
/// let status = CLILocator.cursorCLI()
/// if status.isInstalled {
///     print("Cursor CLI at: \(status.path ?? "")")
/// } else {
///     print("Cursor CLI not found")
/// }
/// ```
public enum CLILocator {

    // MARK: - Types

    /// Status of CLI installation for an app
    public struct CLIStatus: Sendable {
        /// Whether the CLI is installed and executable
        public let isInstalled: Bool

        /// Path to the CLI executable, if found
        public let path: String?

        /// Where the CLI was found
        public let source: CLISource?

        public init(isInstalled: Bool, path: String?, source: CLISource?) {
            self.isInstalled = isInstalled
            self.path = path
            self.source = source
        }
    }

    /// Where the CLI was found
    public enum CLISource: String, Sendable {
        /// Found in system PATH
        case path = "PATH"
        /// Found inside the app bundle
        case appBundle = "App Bundle"
    }

    // MARK: - IDE CLIs

    /// Check if Cursor CLI is installed
    public static func cursorCLI() -> CLIStatus {
        let bundleId = "com.todesktop.230313mzl4w4u92"

        // Check PATH first
        if let pathCLI = locateInPath("cursor") {
            return CLIStatus(isInstalled: true, path: pathCLI.path, source: .path)
        }

        // Check app bundle
        if let bundleCLI = locateInAppBundle(
            bundleID: bundleId,
            relativePath: "Contents/Resources/app/bin/cursor"
        ) {
            return CLIStatus(isInstalled: true, path: bundleCLI.path, source: .appBundle)
        }

        return CLIStatus(isInstalled: false, path: nil, source: nil)
    }

    /// Check if VS Code CLI is installed
    public static func vscodeCLI() -> CLIStatus {
        let bundleId = "com.microsoft.VSCode"

        // Check PATH first
        if let pathCLI = locateInPath("code") {
            return CLIStatus(isInstalled: true, path: pathCLI.path, source: .path)
        }

        // Check app bundle
        if let bundleCLI = locateInAppBundle(
            bundleID: bundleId,
            relativePath: "Contents/Resources/app/bin/code"
        ) {
            return CLIStatus(isInstalled: true, path: bundleCLI.path, source: .appBundle)
        }

        return CLIStatus(isInstalled: false, path: nil, source: nil)
    }

    /// Check if Codex CLI is installed
    public static func codexCLI() -> CLIStatus {
        let bundleId = "com.openai.codex"

        // Check PATH first
        if let pathCLI = locateInPath("codex") {
            return CLIStatus(isInstalled: true, path: pathCLI.path, source: .path)
        }

        // Check app bundle executable as a last resort
        if let bundleCLI = locateInAppBundle(
            bundleID: bundleId,
            relativePath: "Contents/MacOS/Codex"
        ) {
            return CLIStatus(isInstalled: true, path: bundleCLI.path, source: .appBundle)
        }

        return CLIStatus(isInstalled: false, path: nil, source: nil)
    }

    // MARK: - Terminal CLIs

    /// Check if Ghostty CLI is installed
    public static func ghosttyCLI() -> CLIStatus {
        let bundleId = "com.mitchellh.ghostty"

        // Check PATH first
        if let pathCLI = locateInPath("ghostty") {
            return CLIStatus(isInstalled: true, path: pathCLI.path, source: .path)
        }

        // Ghostty app is typically launched via `open -na` with args, not a separate CLI
        // But check app bundle for completeness
        if let bundleCLI = locateInAppBundle(
            bundleID: bundleId,
            relativePath: "Contents/MacOS/ghostty"
        ) {
            return CLIStatus(isInstalled: true, path: bundleCLI.path, source: .appBundle)
        }

        return CLIStatus(isInstalled: false, path: nil, source: nil)
    }

    /// Check if kitty CLI is installed
    public static func kittyCLI() -> CLIStatus {
        let bundleId = "net.kovidgoyal.kitty"

        // Check PATH first
        if let pathCLI = locateInPath("kitty") {
            return CLIStatus(isInstalled: true, path: pathCLI.path, source: .path)
        }

        // Check app bundle
        if let bundleCLI = locateInAppBundle(
            bundleID: bundleId,
            relativePath: "Contents/MacOS/kitty"
        ) {
            return CLIStatus(isInstalled: true, path: bundleCLI.path, source: .appBundle)
        }

        return CLIStatus(isInstalled: false, path: nil, source: nil)
    }

    /// Check if Alacritty CLI is installed
    public static func alacrittyCLI() -> CLIStatus {
        let bundleId = "org.alacritty"

        // Check PATH first
        if let pathCLI = locateInPath("alacritty") {
            return CLIStatus(isInstalled: true, path: pathCLI.path, source: .path)
        }

        // Check app bundle
        if let bundleCLI = locateInAppBundle(
            bundleID: bundleId,
            relativePath: "Contents/MacOS/alacritty"
        ) {
            return CLIStatus(isInstalled: true, path: bundleCLI.path, source: .appBundle)
        }

        return CLIStatus(isInstalled: false, path: nil, source: nil)
    }

    /// Check if iTerm2 CLI tools are installed
    public static func itermCLI() -> CLIStatus {
        // iTerm2 shell integration scripts
        let itermIntegration = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".iterm2_shell_integration.zsh")

        if FileManager.default.fileExists(atPath: itermIntegration.path) {
            return CLIStatus(isInstalled: true, path: itermIntegration.path, source: .path)
        }

        // iTerm2 command line tools (it2*)
        if let pathCLI = locateInPath("it2copy") {
            return CLIStatus(isInstalled: true, path: pathCLI.path, source: .path)
        }

        return CLIStatus(isInstalled: false, path: nil, source: nil)
    }

    // MARK: - IDE CLIs (Xcode)

    /// Check if Xcode CLI (xed) is installed
    public static func xcodeCLI() -> CLIStatus {
        // xed is installed as part of Xcode Command Line Tools at /usr/bin/xed
        let xedPath = "/usr/bin/xed"
        if FileManager.default.isExecutableFile(atPath: xedPath) {
            return CLIStatus(isInstalled: true, path: xedPath, source: .path)
        }

        return CLIStatus(isInstalled: false, path: nil, source: nil)
    }

    // MARK: - Generic Lookup

    /// Check CLI installation for any app by bundle ID
    public static func cliStatus(for bundleId: String) -> CLIStatus {
        switch bundleId {
        case "com.todesktop.230313mzl4w4u92":
            return cursorCLI()
        case "com.openai.codex":
            return codexCLI()
        case "com.microsoft.VSCode":
            return vscodeCLI()
        case "com.mitchellh.ghostty":
            return ghosttyCLI()
        case "net.kovidgoyal.kitty":
            return kittyCLI()
        case "org.alacritty":
            return alacrittyCLI()
        case "com.googlecode.iterm2":
            return itermCLI()
        case "com.apple.dt.Xcode":
            return xcodeCLI()
        default:
            return CLIStatus(isInstalled: false, path: nil, source: nil)
        }
    }

    // MARK: - Helpers

    private static func locateInPath(_ name: String) -> URL? {
        let env = ProcessInfo.processInfo.environment
        guard let pathValue = env["PATH"], !pathValue.isEmpty else { return nil }

        // Also check common locations that might not be in PATH when running from Xcode
        let additionalPaths = ["/opt/homebrew/bin", "/usr/local/bin"]

        let allPaths = pathValue.split(separator: ":").map(String.init) + additionalPaths

        for directory in allPaths {
            let candidate = URL(fileURLWithPath: directory).appendingPathComponent(name)
            if FileManager.default.isExecutableFile(atPath: candidate.path) {
                return candidate
            }
        }

        return nil
    }

    private static func locateInAppBundle(bundleID: String, relativePath: String) -> URL? {
        guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            return nil
        }

        let candidate = appURL.appendingPathComponent(relativePath)
        if FileManager.default.isExecutableFile(atPath: candidate.path) {
            return candidate
        }

        return nil
    }
}
