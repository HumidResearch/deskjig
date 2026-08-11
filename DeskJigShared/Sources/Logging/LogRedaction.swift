import Foundation

/// Redaction of potentially sensitive values in log output.
///
/// The predecessor app redacted window titles only inside its remote log shipper, and
/// that redaction was compiled out entirely in Debug builds (`#if DEBUG return message`).
/// DeskJig ships no remote logger, so redaction moved to the *file* sink — and
/// deliberately does **not** inherit the build-configuration split: `redact(_:)` behaves
/// identically in Debug and Release. Whether it runs at all is a user setting, not a
/// property of how the binary was compiled.
///
/// Redaction is off by default because DeskJig's logs never leave the machine and
/// window titles are the primary signal when debugging a restore. Turn it on before
/// collecting a diagnostics bundle to share:
///
///     defaults write com.mscontrol.bento bento.logRedaction.enabled -bool true
public enum LogRedaction {

    /// Defaults key controlling whether the file sink redacts. Legacy `bento.` prefix
    /// matches the other logging defaults keys on existing installs.
    public static let enabledDefaultsKey = "bento.logRedaction.enabled"

    /// Whether redaction is currently enabled. Identical in Debug and Release.
    public static var isEnabled: Bool {
        BundleIdentity.sharedDefaults.bool(forKey: enabledDefaultsKey)
    }

    /// Applies redaction when enabled, otherwise returns the message unchanged.
    public static func redactIfEnabled(_ message: String) -> String {
        isEnabled ? redact(message) : message
    }

    /// Redacts window titles and the user's home-directory path from a log message.
    ///
    /// Window titles are logged wrapped in single quotes throughout the codebase, so
    /// single-quoted runs are the redaction unit. The user's home path is replaced with
    /// `~` so directory-derived workspace names do not leak the account name.
    public static func redact(_ message: String) -> String {
        var result = quotedTitlePattern.stringByReplacingMatches(
            in: message,
            range: NSRange(message.startIndex..., in: message),
            withTemplate: "'[redacted]'"
        )

        let home = NSHomeDirectory()
        if !home.isEmpty {
            result = result.replacingOccurrences(of: home, with: "~")
        }

        return result
    }

    /// Redacts the values of a structured log field dictionary that are known to carry
    /// window titles or filesystem paths.
    public static func redactFields(_ fields: [String: any Sendable]) -> [String: any Sendable] {
        guard isEnabled else { return fields }
        var redacted = fields
        for (key, value) in fields {
            guard sensitiveFieldKeys.contains(key.lowercased()), let string = value as? String else { continue }
            redacted[key] = redact(string)
        }
        return redacted
    }

    // MARK: - Private

    /// Single-quoted runs of up to 200 characters — the shape window titles are logged in.
    private static let quotedTitlePattern: NSRegularExpression = {
        // The pattern is a compile-time constant, so this cannot fail.
        // swiftlint:disable:next force_try
        try! NSRegularExpression(pattern: #"'([^']{1,200})'"#)
    }()

    private static let sensitiveFieldKeys: Set<String> = [
        "title", "windowtitle", "expectedtitle", "customtitle",
        "path", "directory", "directorypath", "documentpath", "workingdirectory", "cwd"
    ]
}
