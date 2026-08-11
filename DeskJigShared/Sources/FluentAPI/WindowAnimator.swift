//  WindowAnimator.swift
//  DeskJigShared

import AppKit

// MARK: - Window Animator

/// Main animation engine using AX frame stepping
public actor WindowAnimator {
    public static let shared = WindowAnimator()

    /// Track active animations to allow cancellation (keyed by window identityKey)
    private var activeAnimations: [String: AnimationState] = [:]

    /// Resolves the AX window service at animation time (FluentServices is configured
    /// after app startup, so the service cannot be captured eagerly). Injected with a
    /// default so production call sites stay unchanged while tests can supply a mock;
    /// methods must use this instead of referencing `FluentServices.shared` directly (#481).
    private let axWindowServiceProvider: @Sendable () -> AXWindowServiceProtocol?

    /// Internal (not private) so tests can construct a non-shared animator with a
    /// mock provider via `@testable import`; production code uses `.shared`.
    init(
        axWindowServiceProvider: @escaping @Sendable () -> AXWindowServiceProtocol? = {
            FluentServices.shared.axWindowService
        }
    ) {
        self.axWindowServiceProvider = axWindowServiceProvider
    }

    // MARK: - Single Window Animation

    /// Animate a single window to target frame
    /// - Parameters:
    ///   - window: The AXWindow to animate
    ///   - targetFrame: The destination frame
    ///   - options: Animation options
    /// - Returns: Result of the animation operation
    public func animate(
        window: AXWindow,
        to targetFrame: CGRect,
        options: WindowAnimationOptions = .default
    ) async -> WindowAnimationResult {
        let startFrame = window.frame
        let startTime = Date()

        // Cancel any existing animation for this window
        if let existing = activeAnimations[window.identityKey] {
            existing.cancel()
        }

        let state = AnimationState()
        activeAnimations[window.identityKey] = state

        defer {
            activeAnimations.removeValue(forKey: window.identityKey)
        }

        let success = await animateWithAXStepping(
            window: window,
            from: startFrame,
            to: targetFrame,
            options: options,
            state: state
        )

        return WindowAnimationResult(
            windowIdentityKey: window.identityKey,
            success: success,
            finalFrame: targetFrame,
            duration: Date().timeIntervalSince(startTime),
            wasInterrupted: state.isCancelled
        )
    }

    // MARK: - Multiple Window Animation

    /// Animate multiple windows simultaneously
    /// - Parameters:
    ///   - windows: Array of (window, targetFrame) tuples
    ///   - options: Animation options
    ///   - onProgress: Optional callback for progress updates
    /// - Returns: Array of animation results
    public func animateMany(
        windows: [(AXWindow, CGRect)],
        options: WindowAnimationOptions = .default,
        onProgress: ((Int, Int) -> Void)? = nil
    ) async -> [WindowAnimationResult] {
        let total = windows.count
        var completed = 0

        if options.staggerDelay > 0 {
            // Staggered: Launch with delays
            return await withTaskGroup(of: WindowAnimationResult.self) { group in
                for (index, (window, targetFrame)) in windows.enumerated() {
                    group.addTask {
                        // Wait for stagger delay
                        let delay = options.staggerDelay * Double(index)
                        await Task.sleepUnlessCancelled(nanoseconds: UInt64(delay * 1_000_000_000))

                        return await self.animate(
                            window: window,
                            to: targetFrame,
                            options: options
                        )
                    }
                }

                var results: [WindowAnimationResult] = []
                for await result in group {
                    results.append(result)
                    completed += 1
                    onProgress?(completed, total)
                }
                return results
            }
        } else {
            // Parallel: All at once
            return await withTaskGroup(of: WindowAnimationResult.self) { group in
                for (window, targetFrame) in windows {
                    group.addTask {
                        await self.animate(window: window, to: targetFrame, options: options)
                    }
                }

                var results: [WindowAnimationResult] = []
                for await result in group {
                    results.append(result)
                    completed += 1
                    onProgress?(completed, total)
                }
                return results
            }
        }
    }

    /// Cancel animation for a specific window by its identityKey
    public func cancelAnimation(for identityKey: String) {
        activeAnimations[identityKey]?.cancel()
    }

    /// Cancel all active animations
    public func cancelAllAnimations() {
        for state in activeAnimations.values {
            state.cancel()
        }
    }

    // MARK: - AX Stepping Animation Implementation

    private func animateWithAXStepping(
        window: AXWindow,
        from startFrame: CGRect,
        to targetFrame: CGRect,
        options: WindowAnimationOptions,
        state: AnimationState
    ) async -> Bool {
        DeskJigLog.debug(.window, "WindowAnimator: Starting animation for window \(window.identityKey)")

        let steps = max(1, Int(options.duration * 60))  // 60fps target
        let stepDuration: UInt64 = UInt64(1_000_000_000 / 60)  // ~16.67ms

        guard let service = axWindowServiceProvider() else {
            DeskJigLog.error(.window, "WindowAnimator: AXWindowService not available")
            return false
        }

        for step in 0..<steps {
            guard !state.isCancelled else {
                DeskJigLog.debug(.window, "WindowAnimator: Animation cancelled at step \(step)/\(steps)")
                return false
            }

            let t = options.easing.apply(Double(step + 1) / Double(steps))

            let x = startFrame.origin.x + (targetFrame.origin.x - startFrame.origin.x) * t
            let y = startFrame.origin.y + (targetFrame.origin.y - startFrame.origin.y) * t
            let w = startFrame.width + (targetFrame.width - startFrame.width) * t
            let h = startFrame.height + (targetFrame.height - startFrame.height) * t

            let interpolatedFrame = CGRect(x: x, y: y, width: w, height: h)

            // AX calls are thread-safe in practice (and we can't use MainActor
            // because the caller may be blocking main thread with a semaphore)
            _ = service.move(window, to: interpolatedFrame)

            // Task cancellation: stop without snapping to the (possibly stale)
            // target frame, mirroring the cancelAnimation path above.
            guard await Task.sleepUnlessCancelled(nanoseconds: stepDuration) else {
                DeskJigLog.debug(.window, "WindowAnimator: Animation task cancelled at step \(step)/\(steps)")
                return false
            }
        }

        // Ensure final position is exact
        _ = service.move(window, to: targetFrame)

        DeskJigLog.debug(.window, "WindowAnimator: Animation completed for window \(window.identityKey)")
        return true
    }
}

// MARK: - Animation State

/// Internal state tracking for individual animations
private final class AnimationState: @unchecked Sendable {
    private var _isCancelled = false
    private let lock = NSLock()

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return _isCancelled
    }

    func cancel() {
        lock.lock()
        _isCancelled = true
        lock.unlock()
    }
}
