//  RestorationRunID.swift
//  DeskJigShared

import Foundation

/// Canonical factory for restoration run-ids.
///
/// Single source of truth for the run-id format so it cannot drift between
/// producers (`FluentWorkspaceRestorer.makeRunId` and
/// `RestorationPlanBuilder` previously each defined their own copy).
///
/// - Important: The produced string MUST continue to match the regex
///   `restore_\d{1,6}_[a-z0-9]{6}` that downstream tooling and trace folding
///   rely on (audit invariant I-1). The `% 1_000_000` is intentionally
///   **not** zero-padded — this preserves the exact historical output and must
///   not be "fixed".
enum RestorationRunID {
    static func make() -> String {
        let timestamp = Int(Date().timeIntervalSince1970) % 1000000
        let random = String(UUID().uuidString.prefix(6)).lowercased()
        return "restore_\(timestamp)_\(random)"
    }
}
