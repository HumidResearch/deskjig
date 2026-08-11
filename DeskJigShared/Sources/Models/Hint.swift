//  Hint.swift
//  DeskJigShared

import Foundation
import SwiftUI

public enum Hint: String, Sendable, Hashable, Identifiable, CaseIterable {
    case workspaceCreation
    public var id: Self { self }

    /// The key to identify the hint to be marked as "read"/"dismissed" in
    /// UserDefaults.
    public var key: String { "hint.\(rawValue)" }
    
    public var content: Hint.Content {
        switch self {
        case .workspaceCreation:
            Content(
                title: "Hints",
                body: [
                    .bullet("Launch apps you want to include for this workspace."),
                    .bullet("You can create as many workspaces as you want. One for each task."),
                    .bullet("Arrange them in your ideal configuration for any given task.")
                ]
            )
        }
    }
}

public extension Hint {
    /// Whether the hint has been dismissed by the user before.
    func hasBeenDismissed() -> Bool {
        UserDefaults.standard.bool(forKey: key)
    }

    /// Marks the hint as dismissed, not to be presented again.
    func markAsDismissed() {
        UserDefaults.standard.set(true, forKey: key)
    }
}

public extension Hint {
    struct Content: Sendable, Hashable {
        public let title: String
        public let body: [TextElement]

        public enum TextElement: Hashable, Sendable {
            case plain(String)
            case bullet(String)
        }
    }
}
