//  FluentLauncherFactory.swift
//  DeskJigShared

import Foundation

public enum FluentLauncherFactory {
    public static func launcher(for bundleId: String) -> (any FluentAppLauncher)? {
        switch bundleId {
        case OpenByPathBundleIdentifiers.ghostty:
            return FluentGhosttyLauncher()
        case OpenByPathBundleIdentifiers.terminal:
            return FluentTerminalLauncher.terminal()
        case OpenByPathBundleIdentifiers.iterm2:
            return FluentTerminalLauncher.iTerm()
        case OpenByPathBundleIdentifiers.kitty:
            return FluentKittyLauncher()
        case OpenByPathBundleIdentifiers.alacritty:
            return FluentAlacrittyLauncher()
        case OpenByPathBundleIdentifiers.cursor:
            return FluentIDELauncher.cursor()
        case OpenByPathBundleIdentifiers.codex:
            return FluentCodexLauncher()
        case OpenByPathBundleIdentifiers.vscode:
            return FluentIDELauncher.vscode()
        case OpenByPathBundleIdentifiers.xcode:
            return FluentXcodeLauncher()
        default:
            return nil
        }
    }
}
