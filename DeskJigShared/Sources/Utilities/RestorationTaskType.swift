//
//  RestorationTaskType.swift
//  DeskJigShared
//

import Foundation

/// Type of restoration task for categorization.
public enum RestorationTaskType: String, Sendable {
    case chrome = "chrome"
    case openByPath = "openByPath"
    case defaultApp = "default"
    case snapshot = "snapshot"
    case terminal = "terminal"
    case ide = "ide"
    case slowStart = "slowStart"
}
