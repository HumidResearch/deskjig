//
//  RestorationTaskContext.swift
//  DeskJigShared
//

import Foundation

/// Context for tracking individual parallel tasks within a restoration.
public struct RestorationTaskContext: Sendable {
    public let taskId: String           // e.g., "chrome-profile1", "cursor-1"
    public let taskType: RestorationTaskType
    public let startTime: Date
    public let runId: String

    public var fullId: String { "\(runId):\(taskId)" }

    public init(taskId: String, taskType: RestorationTaskType, startTime: Date = Date(), runId: String) {
        self.taskId = taskId
        self.taskType = taskType
        self.startTime = startTime
        self.runId = runId
    }

    /// Elapsed milliseconds since task started
    public var elapsedMs: Int {
        Int(Date().timeIntervalSince(startTime) * 1000)
    }
}
