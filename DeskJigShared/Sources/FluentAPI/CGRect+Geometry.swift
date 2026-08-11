//  CGRect+Geometry.swift
//  DeskJigShared

import CoreGraphics
import Foundation

/// Shared frame geometry helpers used across the Fluent API and restoration
/// subsystem. Consolidates ~10 divergent `framesMatch`/`frameMatches` copies,
/// ~5 `frameDistance` copies, and the 4 `formatFrame`/`frameDescription` helpers
/// (plus their inline interpolations) into a single source of truth.
///
/// Behavior is preserved exactly: each call site continues to pass its own
/// tolerance, and the `strict` flag reproduces the strict `<` comparison that
/// `WindowPositioningService` historically used (every other site used `<=`).
extension CGRect {
    /// Canonical compact trace string in the form `"x,y wxh"` using integer
    /// truncation.
    ///
    /// - Important: This string is parsed by `RestoreTraceLogReader`
    ///   (`frame=` / `target=` fields). It MUST remain byte-identical to the
    ///   previous `formatFrame` output to satisfy audit-logging invariant I-3.
    var traceDescription: String {
        "\(Int(origin.x)),\(Int(origin.y)) \(Int(width))x\(Int(height))"
    }

    /// Per-axis tolerance comparison of origin (x/y) and size (width/height).
    ///
    /// - Parameters:
    ///   - other: The frame to compare against.
    ///   - tolerance: Maximum allowed per-axis delta.
    ///   - strict: When `true`, uses strict `<` (the historical
    ///     `WindowPositioningService` semantics); when `false` (default) uses
    ///     `<=`, matching every other call site.
    func approximatelyEquals(_ other: CGRect, tolerance: CGFloat, strict: Bool = false) -> Bool {
        if strict {
            return abs(origin.x - other.origin.x) < tolerance &&
                abs(origin.y - other.origin.y) < tolerance &&
                abs(width - other.width) < tolerance &&
                abs(height - other.height) < tolerance
        }
        return abs(origin.x - other.origin.x) <= tolerance &&
            abs(origin.y - other.origin.y) <= tolerance &&
            abs(width - other.width) <= tolerance &&
            abs(height - other.height) <= tolerance
    }

    /// Manhattan distance between two frames: `|dx| + |dy| + |dw| + |dh|`.
    /// Used as a tie-break "closeness" metric when selecting candidate windows.
    func manhattanDistance(to other: CGRect) -> CGFloat {
        abs(origin.x - other.origin.x) +
        abs(origin.y - other.origin.y) +
        abs(width - other.width) +
        abs(height - other.height)
    }
}
