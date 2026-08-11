//  OpenByPathConfiguration.swift
//  DeskJigShared

import Foundation

public enum OpenByPathBundleIdentifiers {
    public static let cursor = "com.todesktop.230313mzl4w4u92"
    public static let codex = "com.openai.codex"
    public static let ghostty = "com.mitchellh.ghostty"
    public static let vscode = "com.microsoft.VSCode"
    public static let terminal = "com.apple.Terminal"
    public static let iterm2 = "com.googlecode.iterm2"
    public static let kitty = "net.kovidgoyal.kitty"
    public static let alacritty = "org.alacritty"
    public static let xcode = "com.apple.dt.Xcode"

    public static let supported: Set<String> = [
        cursor,
        codex,
        ghostty,
        vscode,
        terminal,
        iterm2,
        kitty,
        alacritty,
        xcode,
    ]
}
