import Foundation

/// Writes structured NDJSON trace files for debugging.
/// Available in all builds, gated by `bento.traceLogging.enabled` UserDefaults key.
///
/// Error-handling policy: all file I/O in this type is intentionally
/// `try?`/best-effort. This writer runs inside `DeskJigLog.emit` — reporting its
/// own failures through `DeskJigLog` would recurse straight back here, and trace
/// files are a diagnostic sidecar whose loss must never break logging or the
/// operation being traced. Silence is the correct behavior for every site below.
public final class TraceFileWriter: @unchecked Sendable {
    public static let shared = TraceFileWriter()

    private static let restoreTracePattern = #"^restore_\d{1,6}_[a-z0-9]{6}\.ndjson$"#

    private let lock = NSRecursiveLock()
    private var startTime: Date?
    private var currentRunId: String?

    public static let enabledKey = "bento.traceLogging.enabled"

    private init() {}

    /// Whether trace file writing is enabled
    public var isEnabled: Bool {
        #if DEBUG
        return true
        #else
        return UserDefaults.standard.bool(forKey: Self.enabledKey)
        #endif
    }

    // MARK: - Lifecycle

    /// Start a new trace session
    public func start(runId: String) {
        lock.lock()
        defer { lock.unlock() }
        startTime = Date()
        currentRunId = runId

        guard isEnabled else { return }

        let isRetry = runId.contains("_retry_")
        let baseRunId = Self.extractBaseRunId(runId)

        ensureLogDirectoryExists()

        if !isRetry {
            cleanupOldTraces(keepCount: 10)
            let runLog = runLogURL(for: baseRunId)
            try? "".write(to: runLog, atomically: true, encoding: .utf8)
        }
    }

    /// End the current trace session
    public func complete(success: Bool, windowCount: Int) {
        lock.lock()
        defer { lock.unlock() }
        startTime = nil
    }

    /// Emit a JSON summary file for a run
    public func emitSummary(runId: String, fields: [String: String], message: String = "Restoration summary") {
        guard isEnabled else { return }

        var payload = fields
        payload["runId"] = runId
        payload["message"] = message
        payload["timestampMs"] = "\(Int(Date().timeIntervalSince1970 * 1000))"

        guard JSONSerialization.isValidJSONObject(payload),
              let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted]) else {
            return
        }

        lock.lock()
        defer { lock.unlock() }
        ensureLogDirectoryExists()
        try? data.write(to: summaryLogURL(for: runId), options: [.atomic])
    }

    // MARK: - Write (called from DeskJigLog.emit)

    func writeIfEnabled(
        subsystem: LogSubsystem,
        level: LogLevel,
        message: String,
        fields: [String: any Sendable],
        runId: String?,
        threadName: String,
        queueLabel: String,
        isMainThread: Bool,
        file: String,
        function: String,
        line: UInt
    ) {
        guard isEnabled else { return }

        // Only write traces for restoration subsystems or explicitly scoped runs.
        let isRestorationSubsystem = subsystem.category == "restore"
        guard isRestorationSubsystem || runId != nil || currentRunId != nil else { return }

        lock.lock()
        let id = runId ?? currentRunId ?? "no-id"
        let elapsed = startTime.map { Date().timeIntervalSince($0) } ?? 0
        lock.unlock()

        var payload: [String: Any] = [
            "runId": id,
            "subsystem": subsystem.rawValue,
            "level": levelString(level),
            "message": message,
            "thread": isMainThread ? "main" : (threadName.isEmpty ? queueLabel : threadName),
            "queue": queueLabel,
            "isMainThread": isMainThread,
            "file": (file as NSString).lastPathComponent,
            "line": line,
            "function": function,
            "elapsedMs": Int(elapsed * 1000),
            "timestamp": Int(Date().timeIntervalSince1970 * 1000)
        ]

        if !fields.isEmpty {
            let safeFields = fields.compactMapValues { value -> Any? in
                if let str = value as? String { return str }
                if let num = value as? Int { return num }
                if let num = value as? Double { return num }
                if let bool = value as? Bool { return bool }
                if let point = value as? CGPoint {
                    return ["x": Int(point.x), "y": Int(point.y)]
                }
                if let size = value as? CGSize {
                    return ["w": Int(size.width), "h": Int(size.height)]
                }
                if let rect = value as? CGRect {
                    return ["x": Int(rect.origin.x), "y": Int(rect.origin.y), "w": Int(rect.width), "h": Int(rect.height)]
                }
                return "\(value)"
            }
            if !safeFields.isEmpty {
                payload["fields"] = safeFields
            }
        }

        guard JSONSerialization.isValidJSONObject(payload),
              let json = try? JSONSerialization.data(withJSONObject: payload, options: []),
              var jsonLine = String(data: json, encoding: .utf8) else {
            return
        }

        jsonLine.append("\n")
        guard let lineData = jsonLine.data(using: .utf8) else { return }

        lock.lock()
        defer { lock.unlock() }
        let traceURL = runLogURL(for: id)
        ensureLogDirectoryExists(for: traceURL)
        appendLine(lineData, to: traceURL)
    }

    // MARK: - File Management

    private func resolveBaseLogDirectory() -> URL {
        let fm = FileManager.default
        let defaultBase = fm.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs/\(BundleIdentity.logDirectoryName)")

        if let customPath = ProcessInfo.processInfo.environment["BENTO_LOG_PATH"],
           !customPath.trimmingCharacters(in: .whitespaces).isEmpty {
            let url = URL(fileURLWithPath: customPath)
            try? fm.createDirectory(at: url, withIntermediateDirectories: true)
            return url
        }

        if let worktreeName = detectWorktreeName() {
            return defaultBase.appendingPathComponent("worktrees/\(worktreeName)")
        }

        return defaultBase
    }

    private func detectWorktreeName() -> String? {
        if let envWorktree = ProcessInfo.processInfo.environment["BENTO_WORKTREE_NAME"],
           !envWorktree.isEmpty {
            return envWorktree
        }
        if let worktreeName = Bundle.main.object(forInfoDictionaryKey: "BentoWorktreeName") as? String,
           !worktreeName.isEmpty,
           worktreeName != "$(BENTO_WORKTREE_NAME)" {
            return worktreeName
        }
        return nil
    }

    private var baseLogDirectory: URL { resolveBaseLogDirectory() }

    private var logDirectoryURL: URL {
        baseLogDirectory.appendingPathComponent(BundleIdentity.restoreTraceDirectoryName)
    }

    private func runLogURL(for runId: String) -> URL {
        let baseId = Self.extractBaseRunId(runId)
        return logDirectoryURL.appendingPathComponent("\(baseId).ndjson")
    }

    private func summaryLogURL(for runId: String) -> URL {
        let baseId = Self.extractBaseRunId(runId)
        return logDirectoryURL.appendingPathComponent("\(baseId)-summary.json")
    }

    static func extractBaseRunId(_ runId: String) -> String {
        if let range = runId.range(of: "_retry_\\d+$", options: .regularExpression) {
            return String(runId[..<range.lowerBound])
        }
        return runId
    }

    private func ensureLogDirectoryExists() {
        guard !FileManager.default.fileExists(atPath: logDirectoryURL.path) else { return }
        try? FileManager.default.createDirectory(at: logDirectoryURL, withIntermediateDirectories: true)
    }

    private func ensureLogDirectoryExists(for fileURL: URL) {
        let directoryURL = fileURL.deletingLastPathComponent()
        guard !FileManager.default.fileExists(atPath: directoryURL.path) else { return }
        try? FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
    }

    private func cleanupOldTraces(keepCount: Int) {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(
            at: logDirectoryURL,
            includingPropertiesForKeys: [.contentModificationDateKey]
        ) else { return }

        let traceFiles = files.filter { Self.isRestoreTraceFile($0) }
        let sorted = traceFiles.sorted { lhs, rhs in
            let lhsDate = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let rhsDate = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return lhsDate > rhsDate
        }

        for file in sorted.dropFirst(keepCount) {
            try? fm.removeItem(at: file)
            let baseName = file.deletingPathExtension().lastPathComponent
            let summaryURL = logDirectoryURL.appendingPathComponent("\(baseName)-summary.json")
            try? fm.removeItem(at: summaryURL)
        }
    }

    private static func isRestoreTraceFile(_ url: URL) -> Bool {
        url.lastPathComponent.range(of: restoreTracePattern, options: .regularExpression) != nil
    }

    private func appendLine(_ lineData: Data, to url: URL) {
        if let fileHandle = try? FileHandle(forWritingTo: url) {
            defer { try? fileHandle.close() }
            fileHandle.seekToEndOfFile()
            fileHandle.write(lineData)
        } else {
            try? lineData.write(to: url)
        }
    }

    private func levelString(_ level: LogLevel) -> String {
        switch level {
        case .trace: return "trace"
        case .debug: return "debug"
        case .info: return "info"
        case .warn: return "warn"
        case .error: return "error"
        }
    }
}
