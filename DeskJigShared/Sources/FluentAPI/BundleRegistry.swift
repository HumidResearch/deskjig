//  BundleRegistry.swift
//  DeskJigShared

import Foundation

// MARK: - Bundle Registry

/// Centralized bundle ID registry for the Fluent API.
///
/// Single source of truth for app categorization. Use this enum instead of
/// hardcoding bundle IDs throughout the codebase.
///
/// ## Overview
///
/// The registry provides:
/// - Named constants for common bundle IDs
/// - Category sets (terminals, IDEs, Chrome variants)
/// - Helper functions for categorization
/// - Task type mapping for logging
///
/// ## Example
///
/// ```swift
/// let bundleId = window.bundleId
///
/// if BundleRegistry.isTerminal(bundleId) {
///     // Use working directory matching
/// } else if BundleRegistry.isIDE(bundleId) {
///     // Use document path matching
/// } else if BundleRegistry.isChrome(bundleId) {
///     // Use Chrome profile matching
/// }
///
/// // Or get the task type directly
/// let taskType = BundleRegistry.taskType(for: bundleId)
/// ```
///
/// ## See Also
/// - ``RestorationTaskType``
/// - ``EnhancedSnapshot``
public enum BundleRegistry {

    // MARK: - Terminal Bundle IDs

    /// Ghostty terminal
    public static let ghostty = "com.mitchellh.ghostty"

    /// macOS Terminal.app
    public static let terminal = "com.apple.Terminal"

    /// iTerm2
    public static let iterm2 = "com.googlecode.iterm2"

    /// Kitty terminal
    public static let kitty = "net.kovidgoyal.kitty"

    /// Alacritty terminal
    public static let alacritty = "org.alacritty"

    // MARK: - IDE Bundle IDs

    /// Cursor IDE
    public static let cursor = "com.todesktop.230313mzl4w4u92"

    /// Codex IDE
    public static let codex = "com.openai.codex"

    /// Visual Studio Code
    public static let vscode = "com.microsoft.VSCode"

    /// Xcode
    public static let xcode = "com.apple.dt.Xcode"

    // MARK: - Chrome Bundle IDs

    /// Google Chrome
    public static let chrome = "com.google.Chrome"

    /// Google Chrome Canary
    public static let chromeCanary = "com.google.Chrome.canary"

    /// Google Chrome Beta
    public static let chromeBeta = "com.google.Chrome.beta"

    /// Google Chrome Dev
    public static let chromeDev = "com.google.Chrome.dev"

    // MARK: - Browser Bundle IDs

    /// Safari
    public static let safari = "com.apple.Safari"

    /// Firefox
    public static let firefox = "org.mozilla.firefox"

    /// Firefox Developer Edition
    public static let firefoxDeveloperEdition = "org.mozilla.firefoxdeveloperedition"

    /// Microsoft Edge
    public static let edge = "com.microsoft.edgemac"

    /// Brave
    public static let brave = "com.brave.Browser"

    /// Arc
    public static let arc = "company.thebrowser.Browser"

    /// Opera
    public static let opera = "com.operasoftware.Opera"

    // MARK: - Messaging Bundle IDs

    /// Messages
    public static let messages = "com.apple.iChat"

    /// Mail
    public static let mail = "com.apple.mail"

    /// Microsoft Teams
    public static let teams = "com.microsoft.teams"

    /// Signal
    public static let signal = "org.whispersystems.signal-desktop"

    /// Telegram
    public static let telegram = "com.tdesktop.Telegram"

    /// WhatsApp
    public static let whatsapp = "com.whatsapp.WhatsApp"

    /// Skype
    public static let skype = "com.skype.skype"

    // MARK: - Document Bundle IDs

    /// Preview
    public static let preview = "com.apple.Preview"

    /// Pages
    public static let pages = "com.apple.Pages"

    /// Numbers
    public static let numbers = "com.apple.Numbers"

    /// Keynote
    public static let keynote = "com.apple.Keynote"

    /// Microsoft Word
    public static let word = "com.microsoft.Word"

    /// Microsoft Excel
    public static let excel = "com.microsoft.Excel"

    /// Microsoft PowerPoint
    public static let powerpoint = "com.microsoft.Powerpoint"

    /// Adobe Acrobat Reader
    public static let acrobatReader = "com.adobe.Reader"

    /// PDF Expert
    public static let pdfExpert = "com.readdle.PDFExpert-Mac"

    // MARK: - Adobe Creative Bundle IDs

    /// Adobe Photoshop
    public static let photoshop = "com.adobe.Photoshop"

    /// Adobe Illustrator
    public static let illustrator = "com.adobe.illustrator"

    /// Adobe InDesign
    public static let inDesign = "com.adobe.InDesign"

    /// Adobe Premiere Pro 2026
    public static let premierePro26 = "com.adobe.PremierePro.26"

    // MARK: - Slow-Start Bundle IDs
    // Apps that show loading modals/splash screens on cold start

    /// Zoom
    public static let zoom = "us.zoom.xos"

    /// Discord
    public static let discord = "com.hnc.Discord"

    /// Slack
    public static let slack = "com.tinyspeck.slackmacgap"

    // MARK: - Tmux Constants

    /// Base window title prefix for DeskJig-managed tmux terminal windows.
    /// Used by all terminal launchers when launching with a tmux session.
    /// Individual windows get an indexed variant via `managedTmuxWindowTitle(index:)`.
    public static let managedTmuxWindowTitle = "bento:tmux:managed"

    /// Returns an indexed managed tmux window title: `bento:tmux:managed:0`, `bento:tmux:managed:1`, etc.
    /// Used to distinguish multiple tmux windows of the same terminal bundle in a workspace.
    public static func managedTmuxWindowTitle(index: Int) -> String {
        "\(managedTmuxWindowTitle):\(index)"
    }

    /// Returns a terminal-type-specific indexed managed tmux window title:
    /// `bento:tmux:managed:ghostty:0`, `bento:tmux:managed:iterm:0`, etc.
    public static func managedTmuxWindowTitle(bundleId: String, index: Int) -> String {
        "\(managedTmuxWindowTitle):\(managedTmuxTerminalTypeToken(for: bundleId)):\(index)"
    }

    public static func managedTmuxTerminalTypeToken(for bundleId: String) -> String {
        switch bundleId {
        case ghostty:
            return "ghostty"
        case iterm2:
            return "iterm"
        case terminal:
            return "terminal"
        case kitty:
            return "kitty"
        case alacritty:
            return "alacritty"
        default:
            let suffix = bundleId.split(separator: ".").last.map(String.init) ?? bundleId
            let sanitized = suffix.lowercased().filter { $0.isLetter || $0.isNumber }
            return sanitized.isEmpty ? "terminal" : sanitized
        }
    }

    // MARK: - Category Sets

    /// All terminal application bundle IDs
    public static let terminals: Set<String> = [
        ghostty,
        terminal,
        iterm2,
        kitty,
        alacritty
    ]

    /// All IDE application bundle IDs
    public static let ides: Set<String> = [
        cursor,
        codex,
        vscode,
        xcode
    ]

    /// All Chrome variant bundle IDs
    public static let chromes: Set<String> = [
        chrome,
        chromeCanary,
        chromeBeta,
        chromeDev
    ]

    /// All browser application bundle IDs
    public static let browsers: Set<String> = [
        chrome,
        chromeCanary,
        chromeBeta,
        chromeDev,
        safari,
        firefox,
        firefoxDeveloperEdition,
        edge,
        brave,
        arc,
        opera
    ]

    /// Messaging apps (chat + collaboration)
    public static let messaging: Set<String> = [
        slack,
        discord,
        messages,
        mail,
        teams,
        signal,
        telegram,
        whatsapp,
        skype
    ]

    /// Document and productivity apps
    public static let documents: Set<String> = [
        preview,
        pages,
        numbers,
        keynote,
        word,
        excel,
        powerpoint,
        acrobatReader,
        pdfExpert
    ]

    /// Adobe Creative apps that can surface transient launcher or home windows.
    public static let adobeCreativeApps: Set<String> = [
        photoshop,
        illustrator,
        inDesign,
        premierePro26
    ]

    /// Slow-start apps that show loading modals/splash screens on cold start.
    ///
    /// These apps are moved to a dedicated restoration phase with extended
    /// timeouts (30s instead of 10s) and a delay before positioning to allow
    /// modals to dismiss.
    public static let slowStarts: Set<String> = [
        zoom,
        discord,
        slack,
        xcode
    ]

    // MARK: - Categorization Helpers

    /// Returns whether the bundle ID is a terminal application.
    ///
    /// Terminal apps are matched by working directory parsed from window titles.
    ///
    /// - Parameter bundleId: The bundle identifier to check
    /// - Returns: `true` if the app is a terminal
    public static func isTerminal(_ bundleId: String) -> Bool {
        terminals.contains(bundleId)
    }

    /// Returns whether the bundle ID is an IDE application.
    ///
    /// IDEs are matched by document path from accessibility APIs.
    ///
    /// - Parameter bundleId: The bundle identifier to check
    /// - Returns: `true` if the app is an IDE
    public static func isIDE(_ bundleId: String) -> Bool {
        ides.contains(bundleId)
    }

    /// Returns whether the bundle ID is a Chrome variant.
    ///
    /// Chrome apps are matched by profile directory.
    ///
    /// - Parameter bundleId: The bundle identifier to check
    /// - Returns: `true` if the app is Chrome or a Chrome variant
    public static func isChrome(_ bundleId: String) -> Bool {
        chromes.contains(bundleId)
    }

    /// Returns whether the bundle ID is a browser application.
    public static func isBrowser(_ bundleId: String) -> Bool {
        browsers.contains(bundleId)
    }

    /// Returns whether the bundle ID is a messaging application.
    public static func isMessaging(_ bundleId: String) -> Bool {
        messaging.contains(bundleId)
    }

    /// Returns whether the bundle ID is a document or productivity application.
    public static func isDocument(_ bundleId: String) -> Bool {
        documents.contains(bundleId)
    }

    /// Returns whether the bundle ID is an Adobe Creative app.
    public static func isAdobeCreativeApp(_ bundleId: String) -> Bool {
        adobeCreativeApps.contains(bundleId)
    }

    /// Returns whether the bundle ID is a slow-start application.
    ///
    /// Slow-start apps (Zoom, Discord, Slack) show loading modals or splash
    /// screens on cold start. They are restored in a dedicated phase with
    /// extended timeouts and a delay before positioning.
    ///
    /// - Parameter bundleId: The bundle identifier to check
    /// - Returns: `true` if the app is a slow-start app
    public static func isSlowStart(_ bundleId: String) -> Bool {
        slowStarts.contains(bundleId)
    }

    /// Returns whether the bundle ID supports path-based matching.
    ///
    /// Path-based apps (terminals, IDEs) can be matched by their open path.
    ///
    /// - Parameter bundleId: The bundle identifier to check
    /// - Returns: `true` if the app supports path-based matching
    public static func supportsPathMatching(_ bundleId: String) -> Bool {
        isTerminal(bundleId) || isIDE(bundleId)
    }

    // MARK: - Task Type Mapping

    /// Returns the RestorationTaskType for a bundle ID.
    ///
    /// Used for categorizing tasks in logging.
    ///
    /// - Parameter bundleId: The bundle identifier
    /// - Returns: The appropriate task type for logging
    public static func taskType(for bundleId: String) -> RestorationTaskType {
        if isChrome(bundleId) {
            return .chrome
        }
        if isTerminal(bundleId) {
            return .terminal
        }
        if isIDE(bundleId) {
            return .ide
        }
        if isSlowStart(bundleId) {
            return .slowStart
        }
        return .defaultApp
    }
}
