//  ActionHandler.swift
//  DeskJigCLI

import Foundation

/// A modular handler for CLI actions.
protocol ActionHandler: AnyObject {
    func canHandle(action: CLIAction) -> Bool

    func execute(action: CLIAction) async -> CommandResult
}
