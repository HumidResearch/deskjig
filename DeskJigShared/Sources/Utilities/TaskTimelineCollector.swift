//
//  TaskTimelineCollector.swift
//  DeskJigShared
//
//  Collects timeline events across parallel restoration tasks
//  and generates reports showing parallelism achieved and bottlenecks.
//

import Foundation

/// Collects and analyzes timeline events from parallel restoration tasks
public actor TaskTimelineCollector {
    private var events: [TimelineEvent] = []
    public let runId: String
    public let startTime: Date

    public init(runId: String, startTime: Date = Date()) {
        self.runId = runId
        self.startTime = startTime
    }

    // MARK: - Event Recording

    public struct TimelineEvent: Sendable {
        public let timestamp: Date
        public let elapsedMs: Int
        public let taskId: String
        public let taskType: RestorationTaskType
        public let phase: String
        public let message: String
        public let data: [String: String]

        public init(
            timestamp: Date,
            elapsedMs: Int,
            taskId: String,
            taskType: RestorationTaskType,
            phase: String,
            message: String,
            data: [String: String] = [:]
        ) {
            self.timestamp = timestamp
            self.elapsedMs = elapsedMs
            self.taskId = taskId
            self.taskType = taskType
            self.phase = phase
            self.message = message
            self.data = data
        }
    }

    /// Record an event from a task context
    public func record(
        task: RestorationTaskContext,
        phase: String,
        message: String,
        data: [String: String] = [:]
    ) {
        let now = Date()
        let elapsedMs = Int(now.timeIntervalSince(startTime) * 1000)
        let event = TimelineEvent(
            timestamp: now,
            elapsedMs: elapsedMs,
            taskId: task.taskId,
            taskType: task.taskType,
            phase: phase,
            message: message,
            data: data
        )
        events.append(event)
    }

    /// Record a raw event (for orchestrator-level events)
    public func record(
        taskId: String,
        taskType: RestorationTaskType,
        phase: String,
        message: String,
        data: [String: String] = [:]
    ) {
        let now = Date()
        let elapsedMs = Int(now.timeIntervalSince(startTime) * 1000)
        let event = TimelineEvent(
            timestamp: now,
            elapsedMs: elapsedMs,
            taskId: taskId,
            taskType: taskType,
            phase: phase,
            message: message,
            data: data
        )
        events.append(event)
    }

    // MARK: - Report Generation

    public struct TaskTimelineReport: Sendable {
        public let runId: String
        public let totalDurationMs: Int
        public let taskCount: Int
        public let parallelFactor: Double
        public let serialEstimateMs: Int
        public let bottleneckTask: String?
        public let bottleneckDurationMs: Int?
        public let summary: String
        public let taskSummaries: [TaskSummary]
        public let events: [TimelineEvent]
    }

    public struct TaskSummary: Sendable, Equatable {
        public let taskId: String
        public let taskType: RestorationTaskType
        public let startMs: Int
        public let endMs: Int
        public let durationMs: Int
        public let success: Bool
    }

    /// Generate a comprehensive timeline report
    public func generateReport() -> TaskTimelineReport {
        let sortedEvents = events.sorted { $0.elapsedMs < $1.elapsedMs }
        let totalDurationMs = sortedEvents.last?.elapsedMs ?? 0

        // Group events by task to compute task durations
        var taskStartTimes: [String: Int] = [:]
        var taskEndTimes: [String: Int] = [:]
        var taskTypes: [String: RestorationTaskType] = [:]
        var taskSuccess: [String: Bool] = [:]

        for event in sortedEvents {
            let taskId = event.taskId
            taskTypes[taskId] = event.taskType

            if taskStartTimes[taskId] == nil {
                taskStartTimes[taskId] = event.elapsedMs
            }
            taskEndTimes[taskId] = event.elapsedMs

            // Check for completion events
            if event.phase == "COMPLETE" || event.phase == "complete" {
                taskSuccess[taskId] = event.data["success"] == "true" || !event.message.lowercased().contains("fail")
            }
        }

        // Build task summaries
        var taskSummaries: [TaskSummary] = []
        var serialEstimateMs = 0
        var bottleneckTask: String?
        var bottleneckDurationMs = 0

        for (taskId, startMs) in taskStartTimes {
            guard taskId != "orchestrator" else { continue }  // Skip orchestrator meta-events

            let endMs = taskEndTimes[taskId] ?? startMs
            let durationMs = endMs - startMs
            serialEstimateMs += durationMs

            if durationMs > bottleneckDurationMs {
                bottleneckDurationMs = durationMs
                bottleneckTask = taskId
            }

            taskSummaries.append(TaskSummary(
                taskId: taskId,
                taskType: taskTypes[taskId] ?? .defaultApp,
                startMs: startMs,
                endMs: endMs,
                durationMs: durationMs,
                success: taskSuccess[taskId] ?? true
            ))
        }

        // Sort by start time
        taskSummaries.sort { $0.startMs < $1.startMs }

        // Calculate parallelism factor
        let parallelFactor = totalDurationMs > 0 ? Double(serialEstimateMs) / Double(totalDurationMs) : 1.0

        // Build summary string
        let summary = buildSummaryString(
            totalDurationMs: totalDurationMs,
            taskCount: taskSummaries.count,
            parallelFactor: parallelFactor,
            serialEstimateMs: serialEstimateMs,
            bottleneckTask: bottleneckTask,
            bottleneckDurationMs: bottleneckDurationMs,
            taskSummaries: taskSummaries
        )

        return TaskTimelineReport(
            runId: runId,
            totalDurationMs: totalDurationMs,
            taskCount: taskSummaries.count,
            parallelFactor: parallelFactor,
            serialEstimateMs: serialEstimateMs,
            bottleneckTask: bottleneckTask,
            bottleneckDurationMs: bottleneckDurationMs > 0 ? bottleneckDurationMs : nil,
            summary: summary,
            taskSummaries: taskSummaries,
            events: sortedEvents
        )
    }

    private func buildSummaryString(
        totalDurationMs: Int,
        taskCount: Int,
        parallelFactor: Double,
        serialEstimateMs: Int,
        bottleneckTask: String?,
        bottleneckDurationMs: Int,
        taskSummaries: [TaskSummary]
    ) -> String {
        var lines: [String] = []

        lines.append("=== Restoration Timeline [\(runId)] ===")
        lines.append(String(format: "Total: %.1fs | Tasks: %d | Parallel factor: %.1fx",
                           Double(totalDurationMs) / 1000.0,
                           taskCount,
                           parallelFactor))
        lines.append("")

        // Timeline visualization
        for summary in taskSummaries {
            let status = summary.success ? "done" : "FAIL"
            let prefix = summary == taskSummaries.last ? "\\-" : "|-"
            let paddedTaskId = summary.taskId.padding(toLength: 20, withPad: " ", startingAt: 0)
            lines.append("[\(String(format: "%4d", summary.startMs))ms] \(prefix) \(paddedTaskId) \(status) (\(summary.durationMs)ms)")
        }

        lines.append("")

        // Bottleneck info
        if let bottleneck = bottleneckTask, bottleneckDurationMs > 0, totalDurationMs > 0 {
            let percentage = Int(Double(bottleneckDurationMs) / Double(totalDurationMs) * 100)
            lines.append("Bottleneck: \(bottleneck) (\(bottleneckDurationMs)ms) - \(percentage)% of total time")
        }

        lines.append(String(format: "Parallelism achieved: %.1fx (serial would be %.1fs)",
                           parallelFactor,
                           Double(serialEstimateMs) / 1000.0))

        return lines.joined(separator: "\n")
    }

    // MARK: - Gantt Data for Visualization

    public struct GanttEntry: Sendable {
        public let taskId: String
        public let taskType: RestorationTaskType
        public let startMs: Int
        public let endMs: Int
        public let events: [TimelineEvent]
    }

    /// Generate data suitable for Gantt chart visualization
    public func generateGanttData() -> [GanttEntry] {
        var taskEvents: [String: [TimelineEvent]] = [:]
        var taskTypes: [String: RestorationTaskType] = [:]
        var taskStartTimes: [String: Int] = [:]
        var taskEndTimes: [String: Int] = [:]

        for event in events {
            let taskId = event.taskId
            taskTypes[taskId] = event.taskType

            if taskEvents[taskId] == nil {
                taskEvents[taskId] = []
            }
            taskEvents[taskId]?.append(event)

            if taskStartTimes[taskId] == nil {
                taskStartTimes[taskId] = event.elapsedMs
            }
            taskEndTimes[taskId] = event.elapsedMs
        }

        var entries: [GanttEntry] = []
        for (taskId, events) in taskEvents {
            guard taskId != "orchestrator" else { continue }

            entries.append(GanttEntry(
                taskId: taskId,
                taskType: taskTypes[taskId] ?? .defaultApp,
                startMs: taskStartTimes[taskId] ?? 0,
                endMs: taskEndTimes[taskId] ?? 0,
                events: events.sorted { $0.elapsedMs < $1.elapsedMs }
            ))
        }

        return entries.sorted { $0.startMs < $1.startMs }
    }

    // MARK: - Event Access

    public func getAllEvents() -> [TimelineEvent] {
        events.sorted { $0.elapsedMs < $1.elapsedMs }
    }

    public func getEventsForTask(_ taskId: String) -> [TimelineEvent] {
        events.filter { $0.taskId == taskId }.sorted { $0.elapsedMs < $1.elapsedMs }
    }
}
