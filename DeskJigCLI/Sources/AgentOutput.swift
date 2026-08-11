//  AgentOutput.swift
//  DeskJigCLI

import DeskJigShared
import Foundation

struct AgentCommandResult: Codable {
    let success: Bool
    let exitCode: Int
    let action: String
    let durationMs: Double
    let totalDurationMs: Double?
    let message: String?
    let error: String?
    let data: AnyCodableValue?

    init(from result: CommandResult, durationMs: Double, totalDurationMs: Double? = nil) {
        self.success = result.success
        self.exitCode = result.exitCode
        self.action = result.action
        self.durationMs = durationMs
        self.totalDurationMs = totalDurationMs
        self.message = result.message
        self.error = result.error
        self.data = result.data
    }
}

struct AgentBatchResult: Codable {
    let success: Bool
    let exitCode: Int
    let durationMs: Double
    let totalActions: Int
    let successCount: Int
    let failureCount: Int
    let results: [AgentCommandResult]
}

enum AgentOutputFormatter {
    static func formatText(_ result: AgentCommandResult) -> String {
        var parts: [String] = []
        parts.append("status=\(result.success ? "success" : "failure")")
        parts.append("action=\(result.action)")
        parts.append("exit_code=\(result.exitCode)")
        parts.append(String(format: "duration_ms=%.2f", result.durationMs))
        if let totalDurationMs = result.totalDurationMs {
            parts.append(String(format: "total_duration_ms=%.2f", totalDurationMs))
        }
        if let message = result.message, !message.isEmpty {
            parts.append("message=\"\(escape(message))\"")
        }
        if let error = result.error, !error.isEmpty {
            parts.append("error=\"\(escape(error))\"")
        }
        return parts.joined(separator: " ")
    }

    static func formatText(_ batch: AgentBatchResult) -> String {
        var output = ""
        for result in batch.results {
            output += formatText(result) + "\n"
        }

        output += "\n"
        output += String(repeating: "-", count: 40) + "\n"
        output += "status=\(batch.success ? "success" : "failure")"
        output += " total=\(batch.totalActions)"
        output += " success=\(batch.successCount)"
        output += " failure=\(batch.failureCount)"
        output += " exit_code=\(batch.exitCode)"
        output += String(format: " duration_ms=%.2f", batch.durationMs)
        return output
    }

    private static func escape(_ value: String) -> String {
        return value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
    }
}
