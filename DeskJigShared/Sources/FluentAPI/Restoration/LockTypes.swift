//  LockTypes.swift
//  DeskJigShared

import Foundation
import CoreGraphics

// MARK: - Lock Priority

/// Priority levels for lock acquisition in window restoration.
///
/// When multiple restoration tasks want to claim the same window,
/// the task with higher priority wins. Priority is determined by
/// how the window was matched:
///
/// - Path-matched windows (terminals with directories, IDEs with projects) get `.high`
/// - Title-matched windows get `.medium`
/// - Frame-matched windows (fallback) get `.low`
/// - Exact CGWindowID matches (preserved from save) get `.critical`
///
/// ## Overview
///
/// The priority system ensures that specific matches (like a terminal
/// opened to `~/projects/myapp`) take precedence over generic matches
/// (like "any Finder window in this position").
///
/// ## Example
///
/// ```swift
/// // Path-matched terminal gets high priority
/// let priority: LockPriority = .high
///
/// // Frame-only match gets low priority
/// let fallbackPriority: LockPriority = .low
///
/// // Compare priorities
/// if priority > fallbackPriority {
///     // Path match wins
/// }
/// ```
///
/// ## See Also
/// - ``WindowLock``
/// - ``WindowLockManager``
public enum LockPriority: Int, Comparable, Sendable, CustomStringConvertible {
    /// Frame-based match only (fallback when no other match found)
    case low = 0

    /// Title match (window title matches saved title)
    case medium = 1

    /// Path-matched window (documentPath, openPath, or Chrome profile)
    case high = 2

    /// Exact identity match (same CGWindowID as when saved)
    case critical = 3

    public static func < (lhs: LockPriority, rhs: LockPriority) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    public var description: String {
        switch self {
        case .low: return "low"
        case .medium: return "medium"
        case .high: return "high"
        case .critical: return "critical"
        }
    }
}

// MARK: - Window Lock

/// Represents a held lock on a window for restoration.
///
/// A `WindowLock` is acquired by a restoration task to prevent other
/// tasks from claiming the same window. Locks have an expiration time
/// to prevent deadlocks if a task fails.
///
/// ## Overview
///
/// Locks are acquired through ``WindowLockManager/requestLock(for:requesterId:priority:timeout:)``
/// and released through ``WindowLockManager/releaseLock(_:)``. Each lock
/// tracks:
/// - Which window is locked (`windowId`)
/// - Who holds the lock (`holderId`)
/// - The priority level (`priority`)
/// - When the lock was acquired and when it expires
///
/// ## Example
///
/// ```swift
/// // Lock is returned when acquired
/// let result = await lockManager.requestLock(
///     for: windowId,
///     requesterId: "restore-task-1",
///     priority: .high
/// )
///
/// if case .acquired(let lock) = result {
///     print("Got lock on window \(lock.windowId)")
///     print("Expires at: \(lock.expiresAt ?? "never")")
///
///     // Do restoration work...
///
///     // Release when done
///     await lockManager.releaseLock(lock)
/// }
/// ```
///
/// ## See Also
/// - ``LockPriority``
/// - ``LockResult``
/// - ``WindowLockManager``
public struct WindowLock: Sendable, Equatable, CustomStringConvertible {
    /// The CGWindowID of the locked window
    public let windowId: CGWindowID

    /// Unique identifier of the task holding this lock
    public let holderId: String

    /// Priority level of this lock
    public let priority: LockPriority

    /// When the lock was acquired
    public let acquiredAt: Date

    /// When the lock expires (nil = no expiration)
    public let expiresAt: Date?

    /// Internal token for lock validation
    internal let token: UUID

    /// Creates a new window lock.
    ///
    /// - Parameters:
    ///   - windowId: The window being locked
    ///   - holderId: The task acquiring the lock
    ///   - priority: Lock priority level
    ///   - acquiredAt: Acquisition timestamp (defaults to now)
    ///   - expiresAt: Expiration timestamp (nil for no expiration)
    public init(
        windowId: CGWindowID,
        holderId: String,
        priority: LockPriority,
        acquiredAt: Date = Date(),
        expiresAt: Date? = nil
    ) {
        self.windowId = windowId
        self.holderId = holderId
        self.priority = priority
        self.acquiredAt = acquiredAt
        self.expiresAt = expiresAt
        self.token = UUID()
    }

    /// Whether this lock has expired.
    public var isExpired: Bool {
        guard let expiresAt = expiresAt else { return false }
        return Date() > expiresAt
    }

    /// Time remaining until expiration in seconds.
    public var timeRemaining: TimeInterval? {
        guard let expiresAt = expiresAt else { return nil }
        return expiresAt.timeIntervalSinceNow
    }

    public var description: String {
        let expiry = expiresAt.map { "expires \($0)" } ?? "no expiry"
        return "WindowLock(window=\(windowId), holder=\(holderId), priority=\(priority), \(expiry))"
    }

    public static func == (lhs: WindowLock, rhs: WindowLock) -> Bool {
        lhs.token == rhs.token
    }
}

// MARK: - Lock Result

/// Result of attempting to acquire a lock on a window.
///
/// When requesting a lock through ``WindowLockManager/requestLock(for:requesterId:priority:timeout:)``,
/// one of four outcomes is possible:
///
/// - `.acquired`: Lock was obtained successfully
/// - `.queued`: Request is waiting for a higher-priority holder to release
/// - `.denied`: Lock cannot be acquired (lower priority than current holder)
/// - `.timedOut`: Request timed out waiting for the lock
///
/// ## Example
///
/// ```swift
/// let result = await lockManager.requestLock(
///     for: windowId,
///     requesterId: "task-1",
///     priority: .high
/// )
///
/// switch result {
/// case .acquired(let lock):
///     // Use the lock
///     defer { Task { await lockManager.releaseLock(lock) } }
///     await positionWindow(windowId)
///
/// case .queued(let position):
///     print("Waiting in queue at position \(position)")
///
/// case .denied(let reason, let holder):
///     print("Denied: \(reason), held by: \(holder ?? "unknown")")
///
/// case .timedOut:
///     print("Lock request timed out")
/// }
/// ```
///
/// ## See Also
/// - ``WindowLock``
/// - ``WindowLockManager``
public enum LockResult: Sendable {
    /// Lock was successfully acquired
    case acquired(WindowLock)

    /// Request is queued, waiting for higher-priority holder
    case queued(position: Int)

    /// Lock was denied (lower priority than current holder)
    case denied(reason: String, currentHolder: String?)

    /// Request timed out
    case timedOut

    /// Chrome window is awaiting supplementation (profile/tab data not yet available).
    /// The lock request should be retried after Chrome supplementation completes.
    case awaitingChromeSupplementation

    /// Whether the lock was successfully acquired.
    public var isAcquired: Bool {
        if case .acquired = self { return true }
        return false
    }

    /// The lock if acquired, nil otherwise.
    public var lock: WindowLock? {
        if case .acquired(let lock) = self { return lock }
        return nil
    }

    /// Whether the lock is waiting for Chrome supplementation.
    public var isAwaitingSupplementation: Bool {
        if case .awaitingChromeSupplementation = self { return true }
        return false
    }
}

// MARK: - Lock Request

/// Internal representation of a pending lock request.
///
/// Used by ``WindowLockManager`` to track requests that are waiting
/// for locks to become available.
internal struct LockRequest: Sendable {
    let windowId: CGWindowID
    let requesterId: String
    let priority: LockPriority
    let requestTime: Date
    let timeout: Duration?
    let id: UUID

    init(
        windowId: CGWindowID,
        requesterId: String,
        priority: LockPriority,
        timeout: Duration? = nil
    ) {
        self.windowId = windowId
        self.requesterId = requesterId
        self.priority = priority
        self.requestTime = Date()
        self.timeout = timeout
        self.id = UUID()
    }

    /// Whether this request has timed out.
    var isTimedOut: Bool {
        guard let timeout = timeout else { return false }
        let elapsed = Date().timeIntervalSince(requestTime)
        return elapsed > Double(timeout.components.seconds)
    }
}
