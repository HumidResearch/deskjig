//  XcodePathMatching.swift
//  DeskJigShared

import Foundation

/// Shared Xcode-specific path comparison helpers.
///
/// Consolidates the byte-identical copies that lived in `OpenByPathMatcher`,
/// `OpenByPathRestorationService`, and `RestorationExecutor`.
///
/// - Warning: `FluentXcodeLauncher` and `WorkspaceZOrderService` intentionally
///   keep their own variants — the launcher compares via `comparableDocumentPath`
///   and the z-order service is bundle-id-aware (non-Xcode requires an exact
///   match). Do not fold those in here.
enum XcodePathMatching {
    /// Normalize for Xcode comparison: `file://`/percent/tilde normalize, then if
    /// the path points at a `.xcworkspace`/`.xcodeproj` bundle, return its
    /// containing directory.
    static func normalizeComparable(_ path: String?) -> String? {
        guard let normalized = PathNormalization.normalizeURLPath(path) else { return nil }
        if normalized.hasSuffix(".xcworkspace") || normalized.hasSuffix(".xcodeproj") {
            return URL(fileURLWithPath: normalized).deletingLastPathComponent().path
        }
        return normalized
    }

    /// True when `observedPath` equals `expectedDirectory` or is nested under it.
    static func pathMatchesDirectory(observedPath: String, expectedDirectory: String) -> Bool {
        observedPath == expectedDirectory || observedPath.hasPrefix("\(expectedDirectory)/")
    }
}

