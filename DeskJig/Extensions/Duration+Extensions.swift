//
//  Duration+Extensions.swift
//  DeskJig
//

import Foundation

extension Duration {
    /// Initializes a `Duration` from a `TimeInterval`.
    ///
    /// This initializer converts a `TimeInterval` (which represents seconds) into a `Duration`.
    ///
    /// - Parameter timeInterval: The `TimeInterval` to convert to a `Duration`.
    /// - Returns: The corresponding `Duration` for the `TimeInterval`. Will return nil
    /// if the provided `timeInterval` `.isNan` or `.isInfinite`.
    public init?(timeInterval: TimeInterval) {
        // Handle NaN and infinity
        guard !timeInterval.isNaN && !timeInterval.isInfinite else {
            return nil
        }

        let seconds: Int64
        let attoseconds: Int64

        if timeInterval >= 0 {
            seconds = Int64(timeInterval)
            let fractionalPart = timeInterval - TimeInterval(seconds)
            attoseconds = Int64((fractionalPart * 1e18).rounded())

            // Handle possible overflow due to rounding
            guard attoseconds != 1_000_000_000_000_000_000 else {
                self.init(secondsComponent: seconds + 1, attosecondsComponent: 0)
                return
            }
        } else {
            // For negative durations, floor to the next lower integer
            seconds = Int64(floor(timeInterval))
            let fractionalPart = timeInterval - TimeInterval(seconds)
            // Ensure attoseconds are positive
            attoseconds = Int64((-fractionalPart * 1e18).rounded())

            // Handle possible overflow due to rounding
            guard attoseconds != 1_000_000_000_000_000_000 else {
                self.init(secondsComponent: seconds - 1, attosecondsComponent: 0)
                return
            }
        }

        self.init(secondsComponent: seconds, attosecondsComponent: attoseconds)
    }

    /// Converts the `Duration` instance into a `TimeInterval` in seconds. This will lose any precision
    /// beyond 13 decimal places.
    ///
    /// - Returns: A `TimeInterval` representing the same duration.
    public var timeInterval: TimeInterval {
        let seconds = TimeInterval(self.components.seconds)
        let attoseconds = TimeInterval(self.components.attoseconds) / 1_000_000_000_000_000_000

        if self.components.seconds >= 0 {
            return seconds + attoseconds
        } else {
            return seconds - attoseconds
        }
    }

    /// Converts the `Duration` instance into a `TimeInterval` in seconds. This will lose any precision
    /// beyond 13 decimal places.
    ///
    /// - Returns: A `TimeInterval` representing the same duration.
    public var seconds: TimeInterval {
        timeInterval
    }
}
