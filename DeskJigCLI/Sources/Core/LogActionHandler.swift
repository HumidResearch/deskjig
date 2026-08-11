//  LogActionHandler.swift
//  DeskJigCLI

import Foundation
import DeskJigShared

/// Handler for log-related CLI actions
final class LogActionHandler: ActionHandler {

    private weak var executor: ActionExecutor?
    private let fileManager = FileManager.default

    init(executor: ActionExecutor) {
        self.executor = executor
    }

    func canHandle(action: CLIAction) -> Bool {
        switch action {
        case .listRunIds, .showRunId:
            return true
        default:
            return false
        }
    }

    func execute(action: CLIAction) async -> CommandResult {
        guard let executor = executor else {
            return .failure(action: "log", exitCode: .generalError, error: "Executor deallocated")
        }

        switch action {
        case .listRunIds(let lines, let since):
            return executeListRunIds(lines: lines, since: since, executor: executor)
        case .showRunId(let runId, let lines):
            return executeShowRunId(runId: runId, lines: lines, executor: executor)
        default:
            return .failure(action: action.description, exitCode: .generalError, error: "Action not handled by LogActionHandler")
        }
    }

    // MARK: - Private Implementation

    /// List workspace restoration run IDs from log files
    private func executeListRunIds(lines: Int?, since: String?, executor: ActionExecutor) -> CommandResult {
        // Legacy path ~/Library/Logs/Bento — frozen, shared with the app.
        let logsDir = BundleIdentity.logDirectoryURL

        guard fileManager.fileExists(atPath: logsDir.path) else {
            return .failure(
                action: "list-run-ids",
                exitCode: .notFound,
                error: "Logs directory not found: \(logsDir.path)"
            )
        }

        // Get all log files
        let logFiles: [URL]
        do {
            logFiles = try fileManager.contentsOfDirectory(at: logsDir, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles])
                .filter({ $0.pathExtension == "log" })
                .sorted(by: { lhs, rhs in
                    let lhsDate = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                    let rhsDate = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                    return lhsDate > rhsDate // Most recent first
                })
        } catch {
            return .failure(
                action: "list-run-ids",
                exitCode: .actionFailed,
                error: "Failed to read logs directory: \(error.localizedDescription)"
            )
        }

        if logFiles.isEmpty {
            return .failure(
                action: "list-run-ids",
                exitCode: .notFound,
                error: "No log files found in \(logsDir.path)"
            )
        }

        // Parse date filter if provided
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd"
        let sinceDate = since.flatMap { dateFormatter.date(from: $0) }

        // Regex to match run IDs: restore_HHMMSS_XXXXXX
        let runIdPattern = #"\[restore_(\d{6}_[a-z0-9]{6})\]"#
        guard let regex = try? NSRegularExpression(pattern: runIdPattern, options: []) else {
            return .failure(
                action: "list-run-ids",
                exitCode: .generalError,
                error: "Failed to compile regex pattern"
            )
        }

        struct RunIdEntry: Codable {
            let runId: String
            let timestamp: String
            let source: String // "CLI" or "App"
            let logFile: String
        }

        var runIds: [String: RunIdEntry] = [:]

        func shouldSkipLine(_ lineStr: String) -> Bool {
            guard let sinceDate else { return false }
            if let timestampRange = lineStr.range(of: #"\d{4}-\d{2}-\d{2}"#, options: .regularExpression) {
                let dateStr = String(lineStr[timestampRange])
                if let lineDate = dateFormatter.date(from: dateStr), lineDate < sinceDate {
                    return true
                }
            }
            return false
        }

        func processLine(_ lineStr: String, logFile: URL) {
            if shouldSkipLine(lineStr) {
                return
            }

            let range = NSRange(lineStr.startIndex..<lineStr.endIndex, in: lineStr)
            let matches = regex.matches(in: lineStr, options: [], range: range)

            for match in matches {
                if let runIdRange = Range(match.range(at: 1), in: lineStr) {
                    let runId = String(lineStr[runIdRange])

                    let source = lineStr.contains("[CLI]") ? "CLI" : "App"

                    var timestamp = ""
                    if let timestampRange = lineStr.range(of: #"\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}"#, options: .regularExpression) {
                        timestamp = String(lineStr[timestampRange])
                    }

                    if runIds[runId] == nil {
                        runIds[runId] = RunIdEntry(
                            runId: "restore_\(runId)",
                            timestamp: timestamp,
                            source: source,
                            logFile: logFile.lastPathComponent
                        )
                    }
                }
            }
        }

        for logFile in logFiles {
            if let limit = lines {
                guard limit > 0 else { continue }
                let tailLines = readLastLines(from: logFile, maxLines: limit)
                for line in tailLines {
                    processLine(line, logFile: logFile)
                }
            } else {
                withEachLine(in: logFile) { line in
                    processLine(line, logFile: logFile)
                }
            }
        }

        let sortedEntries = runIds.values.sorted { $0.timestamp > $1.timestamp }

        if executor.shouldEmitTextOutput {
            if sortedEntries.isEmpty {
                print("No restoration run IDs found in logs.")
            } else {
                print("Workspace Restoration Run IDs:")
                print(String(repeating: "=", count: 80))
                print("\("RUN ID".padding(toLength: 28, withPad: " ", startingAt: 0))\("TIMESTAMP".padding(toLength: 20, withPad: " ", startingAt: 0))\("SOURCE".padding(toLength: 8, withPad: " ", startingAt: 0))LOG FILE")
                print(String(repeating: "-", count: 80))
                for entry in sortedEntries {
                    let runId = entry.runId.padding(toLength: 28, withPad: " ", startingAt: 0)
                    let timestamp = entry.timestamp.padding(toLength: 20, withPad: " ", startingAt: 0)
                    let source = entry.source.padding(toLength: 8, withPad: " ", startingAt: 0)
                    print("\(runId)\(timestamp)\(source)\(entry.logFile)")
                }
            }
        }

        return .success(
            action: "list-run-ids",
            message: "Found \(sortedEntries.count) restoration run ID(s)",
            data: AnyCodableValue.from(sortedEntries)
        )
    }

    /// Show log entries for a specific run ID
    private func executeShowRunId(runId: String, lines: Int?, executor: ActionExecutor) -> CommandResult {
        // Legacy path ~/Library/Logs/Bento — frozen, shared with the app.
        let logsDir = BundleIdentity.logDirectoryURL

        guard fileManager.fileExists(atPath: logsDir.path) else {
            return .failure(
                action: "show-run-id",
                exitCode: .notFound,
                error: "Logs directory not found: \(logsDir.path)"
            )
        }

        // Get all log files
        let logFiles: [URL]
        do {
            logFiles = try fileManager.contentsOfDirectory(at: logsDir, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles])
                .filter({ $0.pathExtension == "log" })
                .sorted(by: { lhs, rhs in
                    let lhsDate = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                    let rhsDate = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                    return lhsDate > rhsDate
                })
        } catch {
            return .failure(
                action: "show-run-id",
                exitCode: .actionFailed,
                error: "Failed to read logs directory: \(error.localizedDescription)"
            )
        }

        // Normalize run ID (add restore_ prefix if not present)
        let normalizedRunId: String
        if runId.hasPrefix("restore_") {
            normalizedRunId = runId
        } else {
            normalizedRunId = "restore_\(runId)"
        }

        var matchingLines: [String] = []
        let maxLines = max(lines ?? 500, 0)

        func appendMatch(_ line: String) {
            guard maxLines > 0 else { return }
            matchingLines.append(line)
            if matchingLines.count > maxLines {
                matchingLines.removeFirst()
            }
        }

        for logFile in logFiles {
            guard maxLines > 0 else { break }

            withEachLine(in: logFile) { line in
                if line.contains("[\(normalizedRunId)]") {
                    appendMatch(line)
                }
            }

            if matchingLines.count >= maxLines {
                break
            }
        }

        if executor.shouldEmitTextOutput {
            if matchingLines.isEmpty {
                print("No log entries found for run ID: \(normalizedRunId)")
            } else {
                print("Log entries for \(normalizedRunId) (\(matchingLines.count) line(s)):")
                print(String(repeating: "=", count: 80))
                for line in matchingLines.suffix(maxLines) {
                    print(line)
                }
            }
        }

        struct ShowRunIdOutput: Codable {
            let runId: String
            let lineCount: Int
            let lines: [String]
        }

        let output = ShowRunIdOutput(
            runId: normalizedRunId,
            lineCount: matchingLines.count,
            lines: matchingLines
        )

        return .success(
            action: "show-run-id",
            message: matchingLines.isEmpty ? "No log entries found for \(normalizedRunId)" : "Found \(matchingLines.count) log entry(ies) for \(normalizedRunId)",
            data: AnyCodableValue.from(output)
        )
    }

    private func withEachLine(in url: URL, handler: (String) -> Void) {
        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: url)
        } catch {
            // Skipping a file silently would understate results ("no matches"
            // when the file simply couldn't be opened).
            DeskJigLog.warn(.cli, "logs: failed to open \(url.lastPathComponent) for reading: \(error.localizedDescription)")
            return
        }
        defer { try? handle.close() }

        let newline = Data([0x0A])
        var buffer = Data()
        let chunkSize = 8 * 1024

        while true {
            let data = handle.readData(ofLength: chunkSize)
            if data.isEmpty {
                break
            }
            buffer.append(data)

            while let range = buffer.range(of: newline) {
                let lineData = buffer.subdata(in: 0..<range.lowerBound)
                buffer.removeSubrange(0...range.lowerBound)
                handler(String(decoding: lineData, as: UTF8.self))
            }
        }

        if !buffer.isEmpty {
            handler(String(decoding: buffer, as: UTF8.self))
        }
    }

    private func readLastLines(from url: URL, maxLines: Int) -> [String] {
        guard maxLines > 0 else { return [] }
        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: url)
        } catch {
            DeskJigLog.warn(.cli, "logs: failed to open \(url.lastPathComponent) for tail read: \(error.localizedDescription)")
            return []
        }
        defer { try? handle.close() }

        let fileSize = (try? handle.seekToEnd()) ?? 0
        var offset = fileSize
        let chunkSize = 8 * 1024
        var chunks: [Data] = []
        var newlineCount = 0

        while offset > 0 && newlineCount <= maxLines {
            let readSize = min(chunkSize, Int(offset))
            offset -= UInt64(readSize)
            if (try? handle.seek(toOffset: offset)) == nil {
                break
            }
            let data = handle.readData(ofLength: readSize)
            chunks.append(data)
            newlineCount += countNewlines(in: data)
        }

        var buffer = Data()
        buffer.reserveCapacity(chunks.reduce(0) { $0 + $1.count })
        for chunk in chunks.reversed() {
            buffer.append(chunk)
        }

        let lines = buffer
            .split(separator: 0x0A, omittingEmptySubsequences: false)
            .map { String(decoding: $0, as: UTF8.self) }
        if lines.count <= maxLines {
            return lines
        }
        return Array(lines.suffix(maxLines))
    }

    private func countNewlines(in data: Data) -> Int {
        var count = 0
        for byte in data {
            if byte == 0x0A {
                count += 1
            }
        }
        return count
    }
}
