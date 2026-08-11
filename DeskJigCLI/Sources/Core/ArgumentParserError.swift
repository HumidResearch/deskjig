//  ArgumentParserError.swift
//  DeskJigCLI

import Foundation

// MARK: - Argument Parser Error

/// An argument-parsing error shared by the frontend parser and Core action handlers.
enum ArgumentParserError: Error, CustomStringConvertible {
    case missingValue(argument: String)
    case invalidValue(argument: String, value: String, expected: String)
    case unknownArgument(String)
    case conflictingArguments(String, String)
    case missingRequiredArgument(String)
    
    var description: String {
        switch self {
        case .missingValue(let arg):
            return "Missing value for argument '\(arg)'"
        case .invalidValue(let arg, let value, let expected):
            return "Invalid value '\(value)' for argument '\(arg)'. Expected: \(expected)"
        case .unknownArgument(let arg):
            return "Unknown argument: '\(arg)'"
        case .conflictingArguments(let arg1, let arg2):
            return "Conflicting arguments: '\(arg1)' and '\(arg2)'"
        case .missingRequiredArgument(let arg):
            return "Missing required argument: '\(arg)'"
        }
    }
}

extension ArgumentParserError: LocalizedError {
    var errorDescription: String? { description }
}
