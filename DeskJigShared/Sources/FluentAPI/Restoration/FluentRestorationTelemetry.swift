//  FluentRestorationTelemetry.swift
//  DeskJigShared

import Foundation
import CoreGraphics

/// Encapsulates structured workspace restoration telemetry.
public struct WorkspaceRestorationLogPayload: Codable {
    public enum EventType: String, Codable {
        case started
        case complete
    }

    public struct WindowSummary: Codable {
        public let app: String
        public let title: String
        public let bundleId: String?
        public let screenIndex: Int?
        public let displayId: Int?
        public let x: Int
        public let y: Int
        public let width: Int
        public let height: Int
        public let zIndex: Int
        public let isWorkspace: Bool

        public init(
            app: String,
            title: String,
            bundleId: String?,
            screenIndex: Int?,
            displayId: Int?,
            x: Int,
            y: Int,
            width: Int,
            height: Int,
            zIndex: Int,
            isWorkspace: Bool
        ) {
            self.app = app
            self.title = title
            self.bundleId = bundleId
            self.screenIndex = screenIndex
            self.displayId = displayId
            self.x = x
            self.y = y
            self.width = width
            self.height = height
            self.zIndex = zIndex
            self.isWorkspace = isWorkspace
        }
    }

    public struct DisplaySummary: Codable {
        public let screenIndex: Int
        public let displayId: Int
        public let name: String?
        public let x: Int
        public let y: Int
        public let width: Int
        public let height: Int
        public let visibleX: Int
        public let visibleY: Int
        public let visibleWidth: Int
        public let visibleHeight: Int

        public init(
            screenIndex: Int,
            displayId: Int,
            name: String?,
            x: Int,
            y: Int,
            width: Int,
            height: Int,
            visibleX: Int,
            visibleY: Int,
            visibleWidth: Int,
            visibleHeight: Int
        ) {
            self.screenIndex = screenIndex
            self.displayId = displayId
            self.name = name
            self.x = x
            self.y = y
            self.width = width
            self.height = height
            self.visibleX = visibleX
            self.visibleY = visibleY
            self.visibleWidth = visibleWidth
            self.visibleHeight = visibleHeight
        }
    }

    public struct WindowChanges: Codable {
        public struct MovedWindow: Codable {
            public let app: String
            public let title: String
            public let fromX: Int
            public let fromY: Int
            public let toX: Int
            public let toY: Int
            public let distance: Int

            public init(
                app: String,
                title: String,
                fromX: Int,
                fromY: Int,
                toX: Int,
                toY: Int,
                distance: Int
            ) {
                self.app = app
                self.title = title
                self.fromX = fromX
                self.fromY = fromY
                self.toX = toX
                self.toY = toY
                self.distance = distance
            }
        }

        public let new: [String]
        public let closed: [String]
        public let moved: [MovedWindow]
        public let unchanged: [String]

        public init(new: [String], closed: [String], moved: [MovedWindow], unchanged: [String]) {
            self.new = new
            self.closed = closed
            self.moved = moved
            self.unchanged = unchanged
        }
    }

    public struct ZOrderStatus: Codable {
        public let expectedTop: [String]
        public let actualTop: [String]
        public let workspaceWindowsOnTop: Bool

        public init(expectedTop: [String], actualTop: [String], workspaceWindowsOnTop: Bool) {
            self.expectedTop = expectedTop
            self.actualTop = actualTop
            self.workspaceWindowsOnTop = workspaceWindowsOnTop
        }
    }

    public let workspaceId: String
    public let workspaceName: String
    public let eventType: EventType
    public let message: String
    public let accuracy: Double?
    public let missingWindows: Int?
    public let extraWindows: Int?
    public let isPerfect: Bool?
    public let retryAttempt: Int?
    public let expectedWindows: Int?
    public let actualWindows: Int?
    public let screenCount: Int?
    public let windowSummary: String?
    public let fullReport: String?
    public let windows: [WindowSummary]
    public let displays: [DisplaySummary]
    public let windowChanges: WindowChanges?
    public let positionErrors: [String]?
    public let zOrderStatus: ZOrderStatus?
    public let missingWindowsDetail: String?
    public let extraWindowsDetail: String?
    public let positionAccuracyDetail: String?
    public let durationMs: Int?
    public let traceId: String?
    public let sequence: Int?
    public let schemaVersion: Int?

    public init(
        workspaceId: String,
        workspaceName: String,
        eventType: EventType,
        message: String,
        accuracy: Double?,
        missingWindows: Int?,
        extraWindows: Int?,
        isPerfect: Bool?,
        retryAttempt: Int?,
        expectedWindows: Int?,
        actualWindows: Int?,
        screenCount: Int?,
        windowSummary: String?,
        fullReport: String?,
        windows: [WindowSummary],
        displays: [DisplaySummary],
        windowChanges: WindowChanges?,
        positionErrors: [String]?,
        zOrderStatus: ZOrderStatus?,
        missingWindowsDetail: String?,
        extraWindowsDetail: String?,
        positionAccuracyDetail: String?,
        durationMs: Int? = nil,
        traceId: String? = nil,
        sequence: Int? = nil,
        schemaVersion: Int? = nil
    ) {
        self.workspaceId = workspaceId
        self.workspaceName = workspaceName
        self.eventType = eventType
        self.message = message
        self.accuracy = accuracy
        self.missingWindows = missingWindows
        self.extraWindows = extraWindows
        self.isPerfect = isPerfect
        self.retryAttempt = retryAttempt
        self.expectedWindows = expectedWindows
        self.actualWindows = actualWindows
        self.screenCount = screenCount
        self.windowSummary = windowSummary
        self.fullReport = fullReport
        self.windows = windows
        self.displays = displays
        self.windowChanges = windowChanges
        self.positionErrors = positionErrors
        self.zOrderStatus = zOrderStatus
        self.missingWindowsDetail = missingWindowsDetail
        self.extraWindowsDetail = extraWindowsDetail
        self.positionAccuracyDetail = positionAccuracyDetail
        self.durationMs = durationMs
        self.traceId = traceId
        self.sequence = sequence
        self.schemaVersion = schemaVersion
    }
}

public typealias RestorationLogHandler = (WorkspaceRestorationLogPayload) -> Void

public enum FluentRestorationTelemetry {
    public static var restorationLogHandler: RestorationLogHandler?
    public static var restorationSummaryHandler: RestorationSummaryHandler?

    /// Result of evaluating restoration success
    public struct RestorationEvaluation: Sendable {
        public let isPerfect: Bool
        public let hasTimeout: Bool
        public let issues: [String]

        public init(isPerfect: Bool, hasTimeout: Bool, issues: [String]) {
            self.isPerfect = isPerfect
            self.hasTimeout = hasTimeout
            self.issues = issues
        }
    }
}

/// Compact timeline entry for debugging restoration flow
public struct RestorationTimelineEntry: Codable {
    public let t: Int
    public let phase: String
    public let app: String?
    public let strategy: String?
    public let details: [String: String]?

    public init(t: Int, phase: String, app: String? = nil, strategy: String? = nil, details: [String: String]? = nil) {
        self.t = t
        self.phase = phase
        self.app = app
        self.strategy = strategy
        self.details = details
    }
}

/// Per-app restoration summary
public struct AppRestorationSummary: Codable {
    public let name: String
    public let bundleId: String
    public let windows: Int
    public let status: String
    public let launchStrategy: String?
    public let matchStrategy: String?
    public let launchMs: Int?
    public let identifyMs: Int?
    public let positionMs: Int?
    public let error: String?

    public init(
        name: String,
        bundleId: String,
        windows: Int,
        status: String,
        launchStrategy: String? = nil,
        matchStrategy: String? = nil,
        launchMs: Int? = nil,
        identifyMs: Int? = nil,
        positionMs: Int? = nil,
        error: String? = nil
    ) {
        self.name = name
        self.bundleId = bundleId
        self.windows = windows
        self.status = status
        self.launchStrategy = launchStrategy
        self.matchStrategy = matchStrategy
        self.launchMs = launchMs
        self.identifyMs = identifyMs
        self.positionMs = positionMs
        self.error = error
    }
}

/// Overall workspace restoration summary for analytics
public struct WorkspaceRestorationSummary: Codable {
    public let runId: String
    public let workspaceId: String
    public let workspaceName: String
    public let success: Bool
    public let durationMs: Int
    public let retryAttempt: Int
    public let expectedWindows: Int
    public let restoredWindows: Int
    public let positionAccuracy: Double
    public let strategiesUsed: [String]
    public let apps: [AppRestorationSummary]
    public let timeline: [RestorationTimelineEntry]?
    public let failure: RestorationFailure?

    public init(
        runId: String,
        workspaceId: String,
        workspaceName: String,
        success: Bool,
        durationMs: Int,
        retryAttempt: Int,
        expectedWindows: Int,
        restoredWindows: Int,
        positionAccuracy: Double,
        strategiesUsed: [String],
        apps: [AppRestorationSummary],
        timeline: [RestorationTimelineEntry]? = nil,
        failure: RestorationFailure? = nil
    ) {
        self.runId = runId
        self.workspaceId = workspaceId
        self.workspaceName = workspaceName
        self.success = success
        self.durationMs = durationMs
        self.retryAttempt = retryAttempt
        self.expectedWindows = expectedWindows
        self.restoredWindows = restoredWindows
        self.positionAccuracy = positionAccuracy
        self.strategiesUsed = strategiesUsed
        self.apps = apps
        self.timeline = timeline
        self.failure = failure
    }
}

/// Failure details for workspace restoration
public struct RestorationFailure: Codable {
    public let reason: String
    public let expectedWindows: Int
    public let actualWindows: Int
    public let missingApps: [String]
    public let positionAccuracy: Double
    public let lastPhase: String

    public init(
        reason: String,
        expectedWindows: Int,
        actualWindows: Int,
        missingApps: [String],
        positionAccuracy: Double,
        lastPhase: String
    ) {
        self.reason = reason
        self.expectedWindows = expectedWindows
        self.actualWindows = actualWindows
        self.missingApps = missingApps
        self.positionAccuracy = positionAccuracy
        self.lastPhase = lastPhase
    }
}

public typealias RestorationSummaryHandler = (WorkspaceRestorationSummary) -> Void
