//
//  RestorationPhase.swift
//  DeskJigShared
//

import Foundation

/// Phase of a workspace restoration operation.
public enum RestorationPhase: String, Sendable {
    case start = "START"
    case partition = "PARTITION"
    case handler = "HANDLER"
    case task = "TASK"
    case chrome = "CHROME"
    case ide = "IDE"
    case openByPath = "OPENPATH"
    case pending = "PENDING"
    case postRestore = "POST"
    case complete = "COMPLETE"
    case launch = "LAUNCH"
    case match = "MATCH"
    case position = "POSITION"
    case lock = "LOCK"
    case hide = "HIDE"
    case tmux = "TMUX"
}
