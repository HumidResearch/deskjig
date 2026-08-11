import Foundation

// MARK: - Cancellation-Aware Sleep (#474)

/// `try? await Task.sleep(...)` swallows `CancellationError`, so a cancelled
/// polling/retry loop keeps running to its full timeout instead of unwinding.
/// These helpers make the cancellation signal explicit at every sleep site:
///
/// - In a throwing context, prefer `try await Task.sleep(...)` directly — it
///   already propagates `CancellationError`.
/// - In non-throwing contexts (most restoration/polling code), use
///   `Task.sleepUnlessCancelled(...)` and exit the loop when it returns `false`:
///
///       guard await Task.sleepUnlessCancelled(for: .milliseconds(100)) else { break }
///
/// - For fire-and-forget UI delays where proceeding immediately on
///   cancellation is acceptable, the result may be discarded.
///
/// When the shared retry utility lands (#409), retry loops should migrate to
/// it; this helper remains for one-off delays and can back its sleep step.
extension Task where Success == Never, Failure == Never {

    /// Sleeps for the given duration unless the surrounding task is cancelled.
    ///
    /// - Returns: `true` if the full duration elapsed, `false` if the task was
    ///   cancelled before or during the sleep. Loops must honor `false` by
    ///   exiting promptly; only fire-and-forget delays may discard the result.
    @discardableResult
    public static func sleepUnlessCancelled(for duration: Duration) async -> Bool {
        do {
            try await Task.sleep(for: duration)
            return true
        } catch {
            return false
        }
    }

    /// Nanosecond convenience for call sites migrated from
    /// `Task.sleep(nanoseconds:)`.
    @discardableResult
    public static func sleepUnlessCancelled(nanoseconds: UInt64) async -> Bool {
        do {
            try await Task.sleep(nanoseconds: nanoseconds)
            return true
        } catch {
            return false
        }
    }
}
