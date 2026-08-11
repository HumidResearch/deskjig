//  TmuxSessionState.swift
//  DeskJigShared

import Foundation

/// State of a tmux session associated with a workspace window.
///
/// When a terminal window is running inside tmux at workspace save time,
/// this state is captured to enable fast session switching on workspace restore.
///
/// ## Example
///
/// ```swift
/// let state = TmuxSessionState(
///     sessionName: "bento_a1b2c3d4_f1a2b3c4",
///     initialWorkingDirectory: "/Users/dev/code/deskjig"
/// )
///
/// // Stored on WorkspaceWindow
/// let window = window.withTmuxState(state)
/// ```
public struct TmuxSessionState: Codable, Hashable, Sendable {
    /// The tmux session name (e.g., "bento_a1b2c3d4_f1a2b3c4")
    public let sessionName: String

    /// The initial working directory for the session
    public let initialWorkingDirectory: String

    public init(sessionName: String, initialWorkingDirectory: String) {
        self.sessionName = sessionName
        self.initialWorkingDirectory = initialWorkingDirectory
    }
}
