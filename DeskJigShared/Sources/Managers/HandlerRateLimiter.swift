//
//  HandlerRateLimiter.swift
//  DeskJigShared
//
//  Created by Marco Freedom on 21.11.2025.
//

import Foundation

/// Rate limiter for window restoration handler calls
/// Ensures handlers are not called more frequently than the specified interval
/// with guaranteed trailing call execution
public class HandlerRateLimiter {
    
    private let minimumInterval: TimeInterval
    private var nextAvailableSlot: [String: Date] = [:]
    private var pendingTaskCount: Int = 0
    private let lock = NSLock()
    
    public init(minimumInterval: TimeInterval = 0.15) {
        self.minimumInterval = minimumInterval
    }
    
    /// Execute work with rate limiting
    /// - Parameters:
    ///   - key: Unique identifier for the handler (e.g., handler type name)
    ///   - work: The work to execute
    public func execute(key: String, work: @escaping () -> Void) {
        lock.lock()
        defer { lock.unlock() }
        
        let now = Date()
        // Determine the next available slot for this key
        // It must be at least 'now', and at least 'minimumInterval' after the previous slot
        let scheduledTime = max(now, nextAvailableSlot[key] ?? Date.distantPast)
        let delay = scheduledTime.timeIntervalSince(now)
        
        // Update the next available slot for this key
        nextAvailableSlot[key] = scheduledTime + minimumInterval
        
        // Increment pending task count
        pendingTaskCount += 1
        
        if delay <= 0 {
            DeskJigLog.trace(.app, "HandlerRateLimiter: Executing immediately for \(key)")
        } else {
            DeskJigLog.trace(.app, "HandlerRateLimiter: Scheduling work for \(key) after \(String(format: "%.0fms", delay * 1000))")
        }
        
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            work()
            
            self?.lock.lock()
            self?.pendingTaskCount -= 1
            self?.lock.unlock()
        }
    }
    
    /// Reset rate limiter state
    public func reset() {
        lock.lock()
        defer { lock.unlock() }
        
        // We cannot easily cancel scheduled asyncAfter blocks,
        // but we can reset our tracking state.
        // The pending blocks will still run but their side effects should be handled by the caller
        // (e.g. checking if restoration is still valid).
        
        nextAvailableSlot.removeAll()
        // We don't reset pendingTaskCount because the tasks are still technically running/scheduled
        // and waitForPendingWork should probably still wait for them?
        // Or we should accept that reset() implies we don't care about them anymore.
        // But since we can't cancel them, they will decrement the count when they run.
        
        DeskJigLog.info(.app, "HandlerRateLimiter: Reset state (pending tasks will still execute)")
    }
    
    /// Wait for all pending work to complete
    /// - Parameter completion: Called when all pending work is done
    public func waitForPendingWork(completion: @escaping () -> Void) {
        lock.lock()
        let hasPendingWork = pendingTaskCount > 0
        lock.unlock()
        
        if !hasPendingWork {
            completion()
            return
        }
        
        // Check again after a short delay
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            guard let self = self else {
                completion()
                return
            }
            
            // Recursively wait
            self.waitForPendingWork(completion: completion)
        }
    }
}

