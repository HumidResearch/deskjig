//  PathNormalization.swift
//  DeskJigShared

import Foundation

/// Canonical path-normalization helpers for the restoration subsystem.
///
/// - Warning: There are intentionally **multiple** variants because call sites
///   require different semantics. Do NOT collapse them into one. Several other
///   historical `normalizePath` copies deliberately diverge (case-folding in
///   the terminal/IDE supplementation cwd-compare paths, trailing-slash-only in
///   `WindowPositioningService`, symlink resolution in `EnhancedSnapshot`) and
///   merging those would change which windows match during restore. Only the
///   two byte-identical clusters below are consolidated here.
enum PathNormalization {
    /// Expand `~` and standardize the path. Used by the terminal launchers and
    /// IDE supplementation working-directory comparisons.
    static func standardize(_ path: String) -> String {
        let expanded = (path as NSString).expandingTildeInPath
        return URL(fileURLWithPath: expanded).standardizedFileURL.path
    }

    /// Trim, strip a leading `file://`, percent-decode, expand `~`, then
    /// standardize. Returns `nil` for nil/empty input. Used by the open-by-path
    /// matchers and the restoration executor for document-path comparisons.
    static func normalizeURLPath(_ path: String?) -> String? {
        guard let path else { return nil }
        var trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.hasPrefix("file://") {
            trimmed = String(trimmed.dropFirst("file://".count))
        }
        trimmed = trimmed.removingPercentEncoding ?? trimmed
        let expanded = (trimmed as NSString).expandingTildeInPath
        return URL(fileURLWithPath: expanded).standardizedFileURL.path
    }
}

