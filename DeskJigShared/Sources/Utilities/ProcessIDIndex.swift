import Foundation
import AppKit

struct ProcessIDIndexBuildResult<Value> {
    let valuesByProcessID: [pid_t: Value]
    let invalidProcessIDCount: Int
    let duplicateProcessIDs: [pid_t]
}

enum ProcessIDIndexBuilder {
    struct Entry<Value> {
        let processID: pid_t
        let sortKey: String
        let value: Value
    }

    static func build<Value>(_ entries: [Entry<Value>]) -> ProcessIDIndexBuildResult<Value> {
        let sortedEntries = entries.sorted { lhs, rhs in
            if lhs.processID != rhs.processID {
                return lhs.processID < rhs.processID
            }
            return lhs.sortKey < rhs.sortKey
        }

        var valuesByProcessID: [pid_t: Value] = [:]
        var invalidProcessIDCount = 0
        var duplicateProcessIDs = Set<pid_t>()

        for entry in sortedEntries {
            guard entry.processID > 0 else {
                invalidProcessIDCount += 1
                continue
            }

            if valuesByProcessID[entry.processID] != nil {
                duplicateProcessIDs.insert(entry.processID)
                continue
            }

            valuesByProcessID[entry.processID] = entry.value
        }

        return ProcessIDIndexBuildResult(
            valuesByProcessID: valuesByProcessID,
            invalidProcessIDCount: invalidProcessIDCount,
            duplicateProcessIDs: duplicateProcessIDs.sorted()
        )
    }
}

enum RunningApplicationIndex {
    static func appsByProcessID(
        from runningApplications: [NSRunningApplication],
        logSubsystem: LogSubsystem,
        logContext: String
    ) -> [pid_t: NSRunningApplication] {
        let entries = runningApplications.map { app in
            ProcessIDIndexBuilder.Entry(
                processID: app.processIdentifier,
                sortKey: deterministicSortKey(for: app),
                value: app
            )
        }
        let result = ProcessIDIndexBuilder.build(entries)
        logIndexingIssues(result: result, subsystem: logSubsystem, context: logContext)
        return result.valuesByProcessID
    }

    static func bundleIDsByProcessID(
        from runningApplications: [NSRunningApplication],
        logSubsystem: LogSubsystem,
        logContext: String
    ) -> [pid_t: String] {
        let appsByProcessID = appsByProcessID(
            from: runningApplications,
            logSubsystem: logSubsystem,
            logContext: logContext
        )
        return appsByProcessID.reduce(into: [:]) { result, item in
            guard let bundleIdentifier = item.value.bundleIdentifier else { return }
            result[item.key] = bundleIdentifier
        }
    }

    private static func deterministicSortKey(for app: NSRunningApplication) -> String {
        let bundleIdentifier = app.bundleIdentifier ?? ""
        let localizedName = app.localizedName ?? ""
        let executablePath = app.executableURL?.path ?? ""
        return "\(bundleIdentifier)|\(localizedName)|\(executablePath)"
    }

    private static func logIndexingIssues<Value>(
        result: ProcessIDIndexBuildResult<Value>,
        subsystem: LogSubsystem,
        context: String
    ) {
        guard result.invalidProcessIDCount > 0 || !result.duplicateProcessIDs.isEmpty else { return }

        DeskJigLog.warn(subsystem, "Ignoring invalid or duplicate running-application process IDs", fields: [
            "context": context,
            "invalidPIDCount": "\(result.invalidProcessIDCount)",
            "duplicatePIDCount": "\(result.duplicateProcessIDs.count)",
            "duplicatePIDs": result.duplicateProcessIDs.map(String.init).joined(separator: ",")
        ])
    }
}
