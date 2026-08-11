//
//  TerminalCommandFile.swift
//  DeskJigShared
//
//  Helper for generating .command files that set stable terminal titles
//  and working directories for OpenByPath terminals.
//

import Foundation

enum TerminalCommandFile {
    static func create(forDirectory directoryURL: URL, titleToken: String) throws -> URL {
        try create(
            forDirectory: directoryURL,
            titleToken: titleToken,
            launchCommand: "exec /bin/zsh -l"
        )
    }

    static func create(
        forDirectory directoryURL: URL,
        titleToken: String,
        launchCommand: String
    ) throws -> URL {
        let standardizedDirectory = directoryURL.standardizedFileURL
        let tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("deskjig-terminal-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)

        let commandURL = tempDirectory.appendingPathComponent("launch.command")

        let escapedTitle = escapeForDoubleQuotes(titleToken)
        let escapedDirectory = escapeForDoubleQuotes(standardizedDirectory.path)
        let escapedZdotdir = escapeForDoubleQuotes(tempDirectory.path)
        let escapedLaunchCommand = escapeForDoubleQuotes(launchCommand)

        // BENTO_TITLE_TOKEN is a legacy env-var name (see docs/LEGACY_IDENTIFIERS.md).
        let script = """
        #!/bin/zsh
        printf '\\033[2J\\033[H'
        export SHELL_SESSIONS_DISABLE=1
        export BENTO_TITLE_TOKEN="\(escapedTitle)"
        export ZDOTDIR="\(escapedZdotdir)"
        cd "\(escapedDirectory)"
        printf '\\033]0;%s\\007' "$BENTO_TITLE_TOKEN"
        \(escapedLaunchCommand)
        """

        try script.write(to: commandURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: commandURL.path)
        try createZshDotfiles(in: tempDirectory)
        return commandURL
    }

    private static func escapeForDoubleQuotes(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    private static func createZshDotfiles(in directory: URL) throws {
        let zshenvURL = directory.appendingPathComponent(".zshenv")
        let zprofileURL = directory.appendingPathComponent(".zprofile")
        let zshrcURL = directory.appendingPathComponent(".zshrc")

        let zshenv = """
        if [ -r "$HOME/.zshenv" ]; then
          source "$HOME/.zshenv"
        fi
        """

        let zprofile = """
        if [ -r "$HOME/.zprofile" ]; then
          source "$HOME/.zprofile"
        fi
        """

        let zshrc = """
        if [ -r "$HOME/.zshrc" ]; then
          source "$HOME/.zshrc"
        fi

        autoload -Uz add-zsh-hook
        deskjig_set_title() {
          print -Pn "\\\\e]0;${BENTO_TITLE_TOKEN}\\\\a"
        }
        add-zsh-hook precmd deskjig_set_title
        deskjig_set_title
        """

        try zshenv.write(to: zshenvURL, atomically: true, encoding: .utf8)
        try zprofile.write(to: zprofileURL, atomically: true, encoding: .utf8)
        try zshrc.write(to: zshrcURL, atomically: true, encoding: .utf8)
    }
}
