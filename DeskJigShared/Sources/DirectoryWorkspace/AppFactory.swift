//  AppFactory.swift
//  DeskJigShared

import Foundation

// MARK: - App Factory

/// Factory for creating app-specific window specifications for DirectoryWorkspace
/// Usage:
/// ```swift
/// try await DirectoryApp.ghostty()
///     .withWindowTitle("\(BundleIdentity.terminalTitleTokenPrefix):api:0")
///     .inDirectory("~/code/api")
///     .atPosition(.leftHalf, screen: 0)
///     .launch()
/// ```
public enum DirectoryApp {
    
    // MARK: - Ghostty
    
    /// Create a WindowSpec for Ghostty terminal
    /// - Returns: A WindowSpec configured with OpenByPathAppLauncher
    public static func ghostty() -> WindowSpec {
        let launcher = OpenByPathAppLauncher.ghostty()
        return WindowSpec(launcher: launcher)
    }
    
    // MARK: - Cursor
    
    /// Create a WindowSpec for Cursor editor
    /// - Returns: A WindowSpec configured with OpenByPathAppLauncher
    public static func cursor() -> WindowSpec {
        let launcher = OpenByPathAppLauncher.cursor()
        return WindowSpec(launcher: launcher)
    }

    // MARK: - Codex

    /// Create a WindowSpec for Codex editor
    /// - Returns: A WindowSpec configured with OpenByPathAppLauncher
    public static func codex() -> WindowSpec {
        let launcher = OpenByPathAppLauncher.codex()
        return WindowSpec(launcher: launcher)
    }

    // MARK: - VS Code

    /// Create a WindowSpec for VS Code editor
    /// - Returns: A WindowSpec configured with OpenByPathAppLauncher
    public static func vscode() -> WindowSpec {
        let launcher = OpenByPathAppLauncher.vscode()
        return WindowSpec(launcher: launcher)
    }

    // MARK: - Terminal

    /// Create a WindowSpec for Terminal.app
    /// - Returns: A WindowSpec configured with OpenByPathAppLauncher
    public static func terminal() -> WindowSpec {
        let launcher = OpenByPathAppLauncher.terminal()
        return WindowSpec(launcher: launcher)
    }
    
    // MARK: - iTerm

    /// Create a WindowSpec for iTerm2 terminal
    /// - Returns: A WindowSpec configured with OpenByPathAppLauncher
    public static func iterm() -> WindowSpec {
        let launcher = OpenByPathAppLauncher.iterm()
        return WindowSpec(launcher: launcher)
    }

    // MARK: - kitty

    /// Create a WindowSpec for kitty terminal
    /// - Returns: A WindowSpec configured with OpenByPathAppLauncher
    public static func kitty() -> WindowSpec {
        let launcher = OpenByPathAppLauncher.kitty()
        return WindowSpec(launcher: launcher)
    }

    // MARK: - Alacritty

    /// Create a WindowSpec for Alacritty terminal
    /// - Returns: A WindowSpec configured with OpenByPathAppLauncher
    public static func alacritty() -> WindowSpec {
        let launcher = OpenByPathAppLauncher.alacritty()
        return WindowSpec(launcher: launcher)
    }

    // MARK: - Xcode

    /// Create a WindowSpec for Xcode IDE
    /// - Returns: A WindowSpec configured with OpenByPathAppLauncher
    public static func xcode() -> WindowSpec {
        let launcher = OpenByPathAppLauncher.xcode()
        return WindowSpec(launcher: launcher)
    }

    // MARK: - Custom Launcher
    
    /// Create a WindowSpec with a custom launcher
    /// - Parameter launcher: The app launcher to use
    /// - Returns: A WindowSpec configured with the provided launcher
    public static func custom(_ launcher: any AppLauncher) -> WindowSpec {
        return WindowSpec(launcher: launcher)
    }
}
