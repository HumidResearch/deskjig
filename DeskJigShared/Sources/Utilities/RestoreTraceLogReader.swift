//
//  RestoreTraceLogReader.swift
//  DeskJigShared
//
//  API for reading and parsing TraceFileWriter NDJSON output.
//  Use this to import trace logs into UI or analysis tools.
//

import Foundation
import CoreGraphics

// MARK: - Trace Log Entry

/// A parsed trace log entry from the TraceFileWriter NDJSON file.
public struct TraceLogEntry: Identifiable, Sendable, Equatable {
    public let id: UUID
    public let timestamp: Date
    public let phase: RestorationPhase
    public let runId: String
    public let taskId: String?
    public let taskType: String?
    public let elapsed: TimeInterval
    public let message: String
    public let handler: String?
    public let window: String?
    public let windowId: String?
    public let frame: CGRect?
    public let targetFrame: CGRect?
    public let data: [String: String]

    public init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        phase: RestorationPhase,
        runId: String,
        taskId: String? = nil,
        taskType: String? = nil,
        elapsed: TimeInterval,
        message: String,
        handler: String? = nil,
        window: String? = nil,
        windowId: String? = nil,
        frame: CGRect? = nil,
        targetFrame: CGRect? = nil,
        data: [String: String] = [:]
    ) {
        self.id = id
        self.timestamp = timestamp
        self.phase = phase
        self.runId = runId
        self.taskId = taskId
        self.taskType = taskType
        self.elapsed = elapsed
        self.message = message
        self.handler = handler
        self.window = window
        self.windowId = windowId
        self.frame = frame
        self.targetFrame = targetFrame
        self.data = data
    }

    /// Formatted log line in DeskJigLog style
    public var formattedLine: String {
        let idPart = taskId.map { "\(runId):\($0)" } ?? runId
        let elapsedStr = String(format: "+%.3fs", elapsed)
        var parts = ["RT:[\(idPart)][\(phase.rawValue)]\(elapsedStr)"]
        if let h = handler { parts.append("handler=\(h)") }
        if let w = window { parts.append("window='\(w)'") }
        if let f = frame { parts.append("frame=(\(Int(f.origin.x)),\(Int(f.origin.y)) \(Int(f.size.width))x\(Int(f.size.height)))") }
        if let tf = targetFrame { parts.append("target=(\(Int(tf.origin.x)),\(Int(tf.origin.y)) \(Int(tf.size.width))x\(Int(tf.size.height)))") }
        parts.append(message)
        return parts.joined(separator: " ")
    }

    /// Data fields as a summary string
    public var dataSummary: String? {
        guard !data.isEmpty else { return nil }
        return "(" + data.map { "\($0.key)=\($0.value)" }.joined(separator: ", ") + ")"
    }

    public static func == (lhs: TraceLogEntry, rhs: TraceLogEntry) -> Bool {
        lhs.id == rhs.id
    }
}

// MARK: - Trace Log Reader

/// Reader for TraceFileWriter NDJSON output files.
///
/// Use this to parse trace logs from workspace restoration for display or analysis.
///
/// ## Example
///
/// ```swift
/// // Read the latest trace log
/// let entries = try RestoreTraceLogReader.readLatest()
/// for entry in entries {
///     print(entry.formattedLine)
/// }
///
/// // Read logs for a specific run ID
/// let runEntries = try RestoreTraceLogReader.readLatest(runId: "restore_123456_abc123")
/// ```
public enum RestoreTraceLogReader {
    private static let restoreTracePattern = #"^restore_\d{1,6}_[a-z0-9]{6}\.ndjson$"#

    /// Default log file location
    public static var logURL: URL {
        FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs/\(BundleIdentity.logDirectoryName)/\(BundleIdentity.restoreTraceDirectoryName).ndjson")
    }

    /// Per-run log directory location
    public static var logDirectoryURL: URL {
        FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs/\(BundleIdentity.logDirectoryName)/\(BundleIdentity.restoreTraceDirectoryName)")
    }

    /// Per-run log file location
    public static func logURL(for runId: String) -> URL {
        logDirectoryURL.appendingPathComponent("\(runId).ndjson")
    }

    /// Returns the most recent per-run trace log file if available.
    public static func latestLogURL() -> URL? {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: logDirectoryURL,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }

        let candidates = files.filter { isRestoreTraceLog($0) }
        guard !candidates.isEmpty else { return nil }

        return candidates.max(by: { lhs, rhs in
            let lhsDate = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            let rhsDate = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            return lhsDate < rhsDate
        })
    }

    /// Reads and parses the latest trace log file.
    ///
    /// - Parameters:
    ///   - url: Optional custom log file URL. Defaults to the standard location.
    ///   - runId: Optional run ID filter. If provided, only entries matching this run ID are returned.
    ///
    /// - Returns: Array of parsed trace log entries.
    /// - Throws: If the file cannot be read or parsed.
    public static func readLatest(
        from url: URL? = nil,
        runId: String? = nil
    ) throws -> [TraceLogEntry] {
        let fileURL: URL
        if let url {
            fileURL = url
        } else if let runId {
            let runURL = logURL(for: runId)
            fileURL = FileManager.default.fileExists(atPath: runURL.path) ? runURL : logURL
        } else if let latest = latestLogURL() {
            fileURL = latest
        } else {
            fileURL = logURL
        }

        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return []
        }

        let content = try String(contentsOf: fileURL, encoding: .utf8)
        return parse(content: content, runId: runId)
    }

    /// Parses NDJSON content into trace log entries.
    ///
    /// - Parameters:
    ///   - content: The NDJSON string content to parse.
    ///   - runId: Optional run ID filter.
    ///
    /// - Returns: Array of parsed trace log entries.
    public static func parse(content: String, runId filterRunId: String? = nil) -> [TraceLogEntry] {
        let lines = content.components(separatedBy: "\n").filter { !$0.isEmpty }
        var entries: [TraceLogEntry] = []

        for line in lines {
            guard let data = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                continue
            }

            guard let entry = parseEntry(from: json) else {
                continue
            }

            // Apply run ID filter if specified
            if let filterRunId = filterRunId, entry.runId != filterRunId {
                continue
            }

            entries.append(entry)
        }

        return entries
    }

    /// Checks if a trace log file exists and has content.
    public static func hasLogs(at url: URL? = nil) -> Bool {
        let fileURL: URL
        if let url {
            fileURL = url
        } else if let latest = latestLogURL() {
            fileURL = latest
        } else {
            fileURL = logURL
        }
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return false
        }
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
              let size = attributes[.size] as? Int else {
            return false
        }
        return size > 0
    }

    /// Gets the run ID from the most recent trace log.
    public static func latestRunId(from url: URL? = nil) -> String? {
        guard let entries = try? readLatest(from: url), let first = entries.first else {
            return nil
        }
        return first.runId
    }

    // MARK: - Private

    private static func parseEntry(from json: [String: Any]) -> TraceLogEntry? {
        // Parse phase
        let phaseStr = json["phase"] as? String ?? "HANDLER"
        let phase = RestorationPhase(rawValue: phaseStr) ?? .handler

        // Parse run ID and task ID
        let runId = json["runId"] as? String ?? "unknown"
        let taskId = json["taskId"] as? String
        let taskType = json["taskType"] as? String

        // Parse elapsed time (could be "elapsed" as Double or "elapsedMs" as Int)
        let elapsed: TimeInterval
        if let elapsedDouble = json["elapsed"] as? Double {
            elapsed = elapsedDouble
        } else if let elapsedMs = json["elapsedMs"] as? Int {
            elapsed = Double(elapsedMs) / 1000.0
        } else {
            elapsed = 0
        }

        // Parse message
        let message = json["message"] as? String ?? ""

        // Parse optional fields
        let handler = json["handler"] as? String
        let window = json["window"] as? String

        // Parse windowId (could be String or Int)
        let windowId: String?
        if let wid = json["windowId"] as? String {
            windowId = wid
        } else if let widInt = json["windowId"] as? Int {
            windowId = String(widInt)
        } else {
            windowId = nil
        }

        // Parse frame
        let frame = parseFrame(from: json["frame"])
        let targetFrame = parseFrame(from: json["targetFrame"])

        // Parse timestamp
        let timestamp: Date
        if let ts = json["timestamp"] as? Int {
            timestamp = Date(timeIntervalSince1970: Double(ts) / 1000.0)
        } else {
            timestamp = Date()
        }

        // Parse nested data fields into flat [String: String]
        var dataDict: [String: String] = [:]
        if let nestedData = json["data"] as? [String: Any] {
            for (key, value) in nestedData {
                dataDict[key] = stringValue(from: value)
            }
        }

        return TraceLogEntry(
            timestamp: timestamp,
            phase: phase,
            runId: runId,
            taskId: taskId,
            taskType: taskType,
            elapsed: elapsed,
            message: message,
            handler: handler,
            window: window,
            windowId: windowId,
            frame: frame,
            targetFrame: targetFrame,
            data: dataDict
        )
    }

    private static func isRestoreTraceLog(_ url: URL) -> Bool {
        url.lastPathComponent.range(of: restoreTracePattern, options: .regularExpression) != nil
    }

    private static func parseFrame(from value: Any?) -> CGRect? {
        guard let frameDict = value as? [String: Any] else {
            return nil
        }
        guard let x = frameDict["x"] as? Int,
              let y = frameDict["y"] as? Int,
              let w = frameDict["w"] as? Int,
              let h = frameDict["h"] as? Int else {
            return nil
        }
        return CGRect(x: CGFloat(x), y: CGFloat(y), width: CGFloat(w), height: CGFloat(h))
    }

    private static func stringValue(from value: Any) -> String {
        switch value {
        case let str as String:
            return str
        case let int as Int:
            return String(int)
        case let bool as Bool:
            return bool ? "true" : "false"
        case let double as Double:
            return String(format: "%.2f", double)
        case let array as [Any]:
            return array.map { stringValue(from: $0) }.joined(separator: ", ")
        default:
            return String(describing: value)
        }
    }
}
