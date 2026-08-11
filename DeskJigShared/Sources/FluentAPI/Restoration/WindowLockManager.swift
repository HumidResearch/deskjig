//  WindowLockManager.swift
//  DeskJigShared

import Foundation
import CoreGraphics

// MARK: - Window Lock Manager

/// Thread-safe priority-based lock coordination for window restoration.
///
/// `WindowLockManager` coordinates access to windows during workspace restoration,
/// preventing multiple tasks from trying to position the same window. It uses a
/// priority-based system where higher-priority requests can preempt lower-priority
/// holders.
///
/// ## Overview
///
/// During workspace restoration, multiple windows need to be positioned. Some windows
/// might match multiple workspace entries (e.g., a generic Finder window could match
/// several saved positions). The lock manager ensures each window is claimed by at
/// most one restoration task.
///
/// Priority levels:
/// - `.critical`: Exact window ID match (highest)
/// - `.high`: Path-matched (terminal with directory, IDE with project)
/// - `.medium`: Title-matched
/// - `.low`: Frame-matched only (lowest)
///
/// ## Example
///
/// ```swift
/// let manager = WindowLockManager(defaultTimeout: .seconds(10))
///
/// // Request a high-priority lock for a path-matched terminal
/// let result = await manager.requestLock(
///     for: terminalWindowId,
///     requesterId: "restore-terminal-1",
///     priority: .high
/// )
///
/// switch result {
/// case .acquired(let lock):
///     // Position the window
///     await positionWindow(terminalWindowId, to: targetFrame)
///
///     // Release when done
///     await manager.releaseLock(lock)
///
/// case .denied(let reason, _):
///     // Another task has higher priority
///     print("Cannot claim window: \(reason)")
///
/// case .timedOut:
///     print("Lock request timed out")
///
/// case .queued:
///     // Waiting for higher-priority holder to release
///     break
/// }
/// ```
///
/// ## Thread Safety
///
/// `WindowLockManager` is an actor, providing automatic thread-safe access
/// to all methods. All lock operations are serialized.
///
/// ## See Also
/// - ``LockPriority``
/// - ``WindowLock``
/// - ``LockResult``
public actor WindowLockManager {

    // MARK: - Properties

    /// Active locks indexed by window ID
    private var activeLocks: [CGWindowID: WindowLock] = [:]

    /// Permanently claimed windows for the current session (prevents cross-task stealing)
    private var claimedWindows: Set<CGWindowID> = []

    /// Clamped frame tracking for cross-task neighbor adjustment (keyed by runId)
    private var clampedFrames: [String: [ClampedFrame]] = [:]

    /// Positioned frame tracking for run-scoped clamp compensation (keyed by runId)
    private var positionedFrames: [String: [PositionedFrame]] = [:]

    /// Pending requests waiting for locks
    private var pendingRequests: [CGWindowID: [PendingRequest]] = [:]

    /// Default timeout for lock requests
    private let defaultTimeout: Duration

    /// Timer for cleanup task
    private var cleanupTask: Task<Void, Never>?

    /// Pending request with continuation for async waiting
    private struct PendingRequest: Sendable {
        let request: LockRequest
        let continuation: CheckedContinuation<LockResult, Never>
    }

    // MARK: - Initialization

    /// Creates a new lock manager with the specified default timeout.
    ///
    /// - Parameter defaultTimeout: Default timeout for lock requests. Locks that
    ///   aren't released within this duration after acquisition will auto-expire.
    ///   Defaults to 10 seconds.
    ///
    /// ## Example
    ///
    /// ```swift
    /// // Create manager with 30-second timeout
    /// let manager = WindowLockManager(defaultTimeout: .seconds(30))
    /// ```
    public init(defaultTimeout: Duration = .seconds(10)) {
        self.defaultTimeout = defaultTimeout
    }

    deinit {
        cleanupTask?.cancel()
    }

    // MARK: - Lock Acquisition

    /// Requests a lock on a window with priority-based conflict resolution.
    ///
    /// If the window is not locked, the lock is acquired immediately. If the
    /// window is locked by a lower-priority task, the request is queued and
    /// will be granted when the current holder releases.
    ///
    /// If the window is locked by a higher or equal priority task, the request
    /// is denied immediately.
    ///
    /// - Parameters:
    ///   - windowId: The CGWindowID of the window to lock
    ///   - requesterId: Unique identifier for the requesting task
    ///   - priority: Lock priority level for conflict resolution
    ///   - timeout: Optional custom timeout (uses manager's default if nil)
    ///
    /// - Returns: A `LockResult` indicating success, denial, queue position, or timeout
    ///
    /// ## Example
    ///
    /// ```swift
    /// let result = await manager.requestLock(
    ///     for: 12345,
    ///     requesterId: "restore-task-1",
    ///     priority: .high,
    ///     timeout: .seconds(5)
    /// )
    ///
    /// if case .acquired(let lock) = result {
    ///     defer { Task { await manager.releaseLock(lock) } }
    ///     // Use the window...
    /// }
    /// ```
    public func requestLock(
        for windowId: CGWindowID,
        requesterId: String,
        priority: LockPriority,
        timeout: Duration? = nil
    ) async -> LockResult {
        let effectiveTimeout = timeout ?? defaultTimeout

        // Check if window is already locked
        if let existingLock = activeLocks[windowId] {
            // Check if expired
            if existingLock.isExpired {
                // Remove expired lock and proceed
                activeLocks.removeValue(forKey: windowId)
            } else if existingLock.holderId == requesterId {
                // Same task already holds the lock - return it
                return .acquired(existingLock)
            } else if priority > existingLock.priority {
                // Higher priority - queue and wait for release
                return await waitForLock(
                    windowId: windowId,
                    requesterId: requesterId,
                    priority: priority,
                    timeout: effectiveTimeout
                )
            } else {
                // Lower or equal priority - denied
                return .denied(
                    reason: "Window locked by \(existingLock.priority) priority task",
                    currentHolder: existingLock.holderId
                )
            }
        }

        // Window not locked - acquire immediately
        return acquireLock(
            windowId: windowId,
            holderId: requesterId,
            priority: priority,
            timeout: effectiveTimeout
        )
    }

    /// Attempts to acquire a lock without waiting.
    ///
    /// Unlike ``requestLock(for:requesterId:priority:timeout:)``, this method
    /// returns immediately without queuing if the lock cannot be acquired.
    ///
    /// - Parameters:
    ///   - windowId: The CGWindowID of the window to lock
    ///   - requesterId: Unique identifier for the requesting task
    ///   - priority: Lock priority level
    ///   - timeout: Optional lock duration (uses manager's default if nil)
    ///
    /// - Returns: A `LockResult` - either `.acquired` or `.denied`
    ///
    /// ## Example
    ///
    /// ```swift
    /// let result = await manager.tryAcquire(
    ///     for: windowId,
    ///     requesterId: "task-1",
    ///     priority: .medium
    /// )
    ///
    /// guard case .acquired(let lock) = result else {
    ///     // Window is already locked
    ///     return
    /// }
    /// ```
    public func tryAcquire(
        for windowId: CGWindowID,
        requesterId: String,
        priority: LockPriority,
        timeout: Duration? = nil
    ) -> LockResult {
        let effectiveTimeout = timeout ?? defaultTimeout

        // Check if window is already locked
        if let existingLock = activeLocks[windowId] {
            if existingLock.isExpired {
                activeLocks.removeValue(forKey: windowId)
            } else if existingLock.holderId == requesterId {
                return .acquired(existingLock)
            } else {
                return .denied(
                    reason: "Window locked by \(existingLock.priority) priority task",
                    currentHolder: existingLock.holderId
                )
            }
        }

        return acquireLock(
            windowId: windowId,
            holderId: requesterId,
            priority: priority,
            timeout: effectiveTimeout
        )
    }

    // MARK: - Lock Release

    /// Releases a held lock, allowing other tasks to claim the window.
    ///
    /// If there are pending higher-priority requests for this window,
    /// the highest-priority request will be granted automatically.
    ///
    /// - Parameter lock: The lock to release
    ///
    /// - Returns: `true` if the lock was successfully released
    ///
    /// ## Example
    ///
    /// ```swift
    /// // After finishing with the window
    /// await manager.releaseLock(lock)
    /// ```
    @discardableResult
    public func releaseLock(_ lock: WindowLock) -> Bool {
        // Verify this is the current lock
        guard let currentLock = activeLocks[lock.windowId],
              currentLock.token == lock.token else {
            return false
        }

        // Remove the lock
        activeLocks.removeValue(forKey: lock.windowId)

        // Grant to highest priority pending request
        grantPendingRequest(for: lock.windowId)

        return true
    }

    /// Releases all locks held by a specific task.
    ///
    /// Useful for cleanup when a restoration task fails or is cancelled.
    ///
    /// - Parameter holderId: The task identifier whose locks should be released
    ///
    /// - Returns: Number of locks released
    ///
    /// ## Example
    ///
    /// ```swift
    /// // Clean up all locks for a failed task
    /// let released = await manager.releaseAllLocks(for: "restore-task-1")
    /// print("Released \(released) locks")
    /// ```
    @discardableResult
    public func releaseAllLocks(for holderId: String) -> Int {
        var released = 0
        for (windowId, lock) in activeLocks where lock.holderId == holderId {
            activeLocks.removeValue(forKey: windowId)
            grantPendingRequest(for: windowId)
            released += 1
        }
        return released
    }

    // MARK: - Lock Status

    /// Checks the lock status for a window.
    ///
    /// - Parameter windowId: The window to check
    ///
    /// - Returns: Tuple with lock status, holder ID, and priority
    ///
    /// ## Example
    ///
    /// ```swift
    /// let status = await manager.status(for: windowId)
    /// if status.locked {
    ///     print("Locked by \(status.holder ?? "unknown") at \(status.priority ?? .low)")
    /// }
    /// ```
    public func status(for windowId: CGWindowID) -> (locked: Bool, holder: String?, priority: LockPriority?) {
        if let lock = activeLocks[windowId], !lock.isExpired {
            return (true, lock.holderId, lock.priority)
        }
        return (false, nil, nil)
    }

    /// Returns all currently held locks.
    ///
    /// - Returns: Array of all active locks
    public func allLocks() -> [WindowLock] {
        Array(activeLocks.values.filter { !$0.isExpired })
    }

    /// Returns the number of active locks.
    public var lockCount: Int {
        activeLocks.values.filter { !$0.isExpired }.count
    }

    /// Returns the number of pending requests.
    public var pendingCount: Int {
        pendingRequests.values.reduce(0) { $0 + $1.count }
    }

    // MARK: - Claims

    /// Check if a window is permanently claimed by another task
    public func isClaimed(_ windowId: CGWindowID) -> Bool {
        claimedWindows.contains(windowId)
    }

    /// Mark a window as permanently claimed
    public func claim(_ windowId: CGWindowID) {
        claimedWindows.insert(windowId)
    }

    /// Reset all claims (e.g. at start of restoration)
    public func resetClaims() {
        claimedWindows.removeAll()
    }

    // MARK: - Clamped Frame Tracking

    /// A record of a window whose app enforced a minimum size, causing the actual
    /// frame to differ from the restoration target.
    public struct ClampedFrame: Sendable {
        public let windowId: CGWindowID?
        public let originalTarget: CGRect
        public let actualFrame: CGRect
    }

    /// A record of a window positioned during a restoration run.
    public struct PositionedFrame: Sendable {
        public let windowId: CGWindowID?
        public let bundleId: String?
        public let originalTarget: CGRect
        public let effectiveTarget: CGRect
        public let finalFrame: CGRect
    }

    /// Registers a clamped frame so that later-positioning windows can avoid overlap.
    /// When `windowId` is provided, the frame is upserted (latest wins) to avoid stale
    /// clamp state accumulating for a single window across retries and reflows.
    public func registerClampedFrame(
        runId: String,
        windowId: CGWindowID? = nil,
        originalTarget: CGRect,
        actualFrame: CGRect
    ) {
        let frame = ClampedFrame(windowId: windowId, originalTarget: originalTarget, actualFrame: actualFrame)
        if let windowId,
           let existingIndex = clampedFrames[runId]?.lastIndex(where: { $0.windowId == windowId }) {
            clampedFrames[runId]?[existingIndex] = frame
            return
        }
        clampedFrames[runId, default: []].append(frame)
    }

    /// Returns all clamped frames registered for the given run.
    public func getClampedFrames(for runId: String) -> [ClampedFrame] {
        clampedFrames[runId] ?? []
    }

    /// Clears clamped frame records for a completed run.
    public func clearClampedFrames(for runId: String) {
        clampedFrames.removeValue(forKey: runId)
    }

    /// Clears clamped frame records for a specific window in a run.
    public func clearClampedFrame(runId: String, windowId: CGWindowID) {
        guard var frames = clampedFrames[runId] else { return }
        frames.removeAll { $0.windowId == windowId }
        if frames.isEmpty {
            clampedFrames.removeValue(forKey: runId)
        } else {
            clampedFrames[runId] = frames
        }
    }

    /// Registers or updates a positioned frame for the run.
    public func registerPositionedFrame(
        runId: String,
        windowId: CGWindowID?,
        bundleId: String? = nil,
        originalTarget: CGRect,
        effectiveTarget: CGRect,
        finalFrame: CGRect
    ) {
        let frame = PositionedFrame(
            windowId: windowId,
            bundleId: bundleId,
            originalTarget: originalTarget,
            effectiveTarget: effectiveTarget,
            finalFrame: finalFrame
        )

        if let windowId,
           let existingIndex = positionedFrames[runId]?.firstIndex(where: { $0.windowId == windowId }) {
            positionedFrames[runId]?[existingIndex] = frame
            return
        }

        positionedFrames[runId, default: []].append(frame)
    }

    /// Updates an already-registered positioned frame by window ID.
    public func updatePositionedFrame(
        runId: String,
        windowId: CGWindowID,
        effectiveTarget: CGRect,
        finalFrame: CGRect
    ) {
        guard let existingIndex = positionedFrames[runId]?.firstIndex(where: { $0.windowId == windowId }) else {
            return
        }
        let existing = positionedFrames[runId]![existingIndex]
        positionedFrames[runId]![existingIndex] = PositionedFrame(
            windowId: windowId,
            bundleId: existing.bundleId,
            originalTarget: existing.originalTarget,
            effectiveTarget: effectiveTarget,
            finalFrame: finalFrame
        )
    }

    /// Returns all positioned frame records for the given run.
    public func getPositionedFrames(for runId: String) -> [PositionedFrame] {
        positionedFrames[runId] ?? []
    }

    /// Clears positioned frame records for a completed run.
    public func clearPositionedFrames(for runId: String) {
        positionedFrames.removeValue(forKey: runId)
    }

    /// Cleans up expired locks and timed-out pending requests.
    ///
    /// - Returns: Number of expired items cleaned up
    @discardableResult
    public func cleanupExpired() -> Int {
        var cleaned = 0

        // Clean expired locks
        for (windowId, lock) in activeLocks where lock.isExpired {
            activeLocks.removeValue(forKey: windowId)
            grantPendingRequest(for: windowId)
            cleaned += 1
        }

        // Clean timed-out requests
        for (windowId, requests) in pendingRequests {
            let validRequests = requests.filter { pending in
                if pending.request.isTimedOut {
                    pending.continuation.resume(returning: .timedOut)
                    cleaned += 1
                    return false
                }
                return true
            }
            if validRequests.isEmpty {
                pendingRequests.removeValue(forKey: windowId)
            } else {
                pendingRequests[windowId] = validRequests
            }
        }

        return cleaned
    }

    /// Releases all locks and cancels all pending requests.
    ///
    /// Used for cleanup during shutdown or cancellation.
    public func reset() {
        // Cancel all pending requests
        for (_, requests) in pendingRequests {
            for pending in requests {
                pending.continuation.resume(returning: .denied(reason: "Lock manager reset", currentHolder: nil))
            }
        }
        pendingRequests.removeAll()

        // Clear all locks
        activeLocks.removeAll()
        claimedWindows.removeAll()
        clampedFrames.removeAll()
        positionedFrames.removeAll()

        // Cancel cleanup task
        cleanupTask?.cancel()
        cleanupTask = nil
    }

    // MARK: - Private Methods

    private func acquireLock(
        windowId: CGWindowID,
        holderId: String,
        priority: LockPriority,
        timeout: Duration
    ) -> LockResult {
        let expiresAt = Date().addingTimeInterval(Double(timeout.components.seconds))
        let lock = WindowLock(
            windowId: windowId,
            holderId: holderId,
            priority: priority,
            expiresAt: expiresAt
        )
        activeLocks[windowId] = lock
        startCleanupTaskIfNeeded()
        return .acquired(lock)
    }

    private func waitForLock(
        windowId: CGWindowID,
        requesterId: String,
        priority: LockPriority,
        timeout: Duration
    ) async -> LockResult {
        let request = LockRequest(
            windowId: windowId,
            requesterId: requesterId,
            priority: priority,
            timeout: timeout
        )

        return await withCheckedContinuation { continuation in
            let pending = PendingRequest(request: request, continuation: continuation)

            if pendingRequests[windowId] == nil {
                pendingRequests[windowId] = []
            }
            pendingRequests[windowId]?.append(pending)

            // Sort by priority (highest first)
            pendingRequests[windowId]?.sort { $0.request.priority > $1.request.priority }

            startCleanupTaskIfNeeded()
        }
    }

    private func grantPendingRequest(for windowId: CGWindowID) {
        guard var requests = pendingRequests[windowId], !requests.isEmpty else {
            return
        }

        // Get highest priority request
        let pending = requests.removeFirst()

        if requests.isEmpty {
            pendingRequests.removeValue(forKey: windowId)
        } else {
            pendingRequests[windowId] = requests
        }

        // Grant the lock
        let timeout = pending.request.timeout ?? defaultTimeout
        let result = acquireLock(
            windowId: windowId,
            holderId: pending.request.requesterId,
            priority: pending.request.priority,
            timeout: timeout
        )

        pending.continuation.resume(returning: result)
    }

    private func startCleanupTaskIfNeeded() {
        guard cleanupTask == nil else { return }

        cleanupTask = Task { [weak self] in
            while !Task.isCancelled {
                guard await Task.sleepUnlessCancelled(for: .seconds(5)) else { break }
                await self?.cleanupExpired()
            }
        }
    }
}

// MARK: - Convenience Extensions

extension WindowLockManager {
    /// Executes a closure while holding a lock, automatically releasing afterward.
    ///
    /// - Parameters:
    ///   - windowId: The window to lock
    ///   - requesterId: The task requesting the lock
    ///   - priority: Lock priority
    ///   - timeout: Lock timeout
    ///   - operation: The async operation to perform while holding the lock
    ///
    /// - Returns: The result of the operation, or nil if lock couldn't be acquired
    ///
    /// ## Example
    ///
    /// ```swift
    /// let positioned = await manager.withLock(
    ///     for: windowId,
    ///     requesterId: "task-1",
    ///     priority: .high
    /// ) { lock in
    ///     await positionWindow(windowId, to: frame)
    ///     return true
    /// }
    /// ```
    public func withLock<T: Sendable>(
        for windowId: CGWindowID,
        requesterId: String,
        priority: LockPriority,
        timeout: Duration? = nil,
        operation: @Sendable (WindowLock) async throws -> T
    ) async rethrows -> T? {
        let result = await requestLock(
            for: windowId,
            requesterId: requesterId,
            priority: priority,
            timeout: timeout
        )

        guard case .acquired(let lock) = result else {
            return nil
        }

        defer { _ = releaseLock(lock) }
        return try await operation(lock)
    }
}
