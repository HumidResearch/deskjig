//  ProcessRunner.swift
//  DeskJigShared

import Foundation

/// Shared synchronous subprocess runner: captures stdout, discards stderr, and
/// returns `""` on launch failure. Consolidates the byte-identical `runCommand`
/// helpers previously duplicated in the supplementation services.
///
/// - Note: This is the behavior-preserving **synchronous** variant — it blocks
///   on `waitUntilExit()`. Moving these calls off the actor / running them
///   concurrently is tracked separately (Phase 4 / supp-01); do not change the
///   blocking semantics here.
enum ProcessRunner {
    static func run(_ launchPath: String, arguments: [String]) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return ""
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8) ?? ""
    }
}
