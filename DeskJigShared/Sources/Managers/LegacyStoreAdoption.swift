//
//  LegacyStoreAdoption.swift
//  DeskJigShared
//

import Foundation

/// Minimal key/value surface the one-time legacy adoption sweep needs.
///
/// Two backings exist in practice: a `UserDefaults` suite (the app, and the CLI
/// when it talks to the real cfprefsd-backed domain) and a plain plist file (the
/// CLI under `BENTOCLI_PREFS_PATH_OVERRIDE`, and tests). Both read paths must run
/// the same adoption logic, so the logic is written against this protocol instead
/// of against `UserDefaults` directly.
public protocol LegacyAdoptionStore {
    /// Every key currently present in the store.
    func adoptionAllKeys() -> [String]
    func adoptionData(forKey key: String) -> Data?
    func adoptionBool(forKey key: String) -> Bool
    func adoptionSetData(_ data: Data, forKey key: String)
    func adoptionSetBool(_ value: Bool, forKey key: String)
}

extension UserDefaults: LegacyAdoptionStore {
    public func adoptionAllKeys() -> [String] {
        Array(dictionaryRepresentation().keys)
    }

    public func adoptionData(forKey key: String) -> Data? {
        data(forKey: key)
    }

    public func adoptionBool(forKey key: String) -> Bool {
        bool(forKey: key)
    }

    public func adoptionSetData(_ data: Data, forKey key: String) {
        set(data, forKey: key)
    }

    public func adoptionSetBool(_ value: Bool, forKey key: String) {
        set(value, forKey: key)
    }
}

/// `LegacyAdoptionStore` backed by a plist file read/written in place.
///
/// This is the store shape the CLI uses under `BENTOCLI_PREFS_PATH_OVERRIDE`,
/// where writes deliberately bypass cfprefsd and land in the file directly.
public struct PlistFileLegacyAdoptionStore: LegacyAdoptionStore {
    private let url: URL

    public init(url: URL) {
        self.url = url
    }

    private var contents: [String: Any] {
        (NSDictionary(contentsOf: url) as? [String: Any]) ?? [:]
    }

    private func write(_ dictionary: [String: Any]) {
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        NSDictionary(dictionary: dictionary).write(to: url, atomically: true)
    }

    public func adoptionAllKeys() -> [String] {
        Array(contents.keys)
    }

    public func adoptionData(forKey key: String) -> Data? {
        contents[key] as? Data
    }

    public func adoptionBool(forKey key: String) -> Bool {
        (contents[key] as? NSNumber)?.boolValue ?? false
    }

    public func adoptionSetData(_ data: Data, forKey key: String) {
        var updated = contents
        updated[key] = data
        write(updated)
    }

    public func adoptionSetBool(_ value: Bool, forKey key: String) {
        var updated = contents
        updated[key] = value
        write(updated)
    }
}

/// One-time adoption of per-user (account-scoped) keys left behind by the
/// commercial predecessor.
///
/// The predecessor namespaced its per-user state by Firebase UID —
/// `"<uid>.SavedWorkspaces"`, `"<uid>.SimpleOnboarding.Completed"` — and only fell
/// back to the bare key when no account was signed in. The local-only port reads
/// the bare keys exclusively, so an existing *authenticated* install looks empty:
/// its 24 saved workspaces sit under a UID-prefixed key nothing reads any more.
///
/// This sweep copies the richest legacy value forward onto the bare key exactly
/// once, guarded by a persisted flag. The flag is load-bearing: without it, a user
/// who adopts their workspaces and then deletes them all would have them
/// resurrected on the next load. The prefixed originals are never modified or
/// removed — the legacy app may still be installed, and the copy is cheap.
///
/// `TutorialProgressStore.load()` implements the same idea for `*.tutorialProgress`
/// (union-merge rather than pick-one, because progress is monotonic).
public enum LegacyStoreAdoption {

    /// Bare `UserDefaults` flag recording that the saved-workspace sweep already ran.
    public static let workspacesAdoptionCompletedKey = "legacyPerUserStoreAdoption.completed"

    /// Bare `UserDefaults` flag recording that the onboarding-completion sweep already ran.
    public static let onboardingAdoptionCompletedKey = "legacyPerUserStoreAdoption.onboardingCompleted"

    /// Masks a UID-prefixed key down to something safe to log: `JAffmX….SavedWorkspaces`.
    static func maskedKey(_ key: String, suffix: String) -> String {
        guard key.hasSuffix(suffix) else { return "…\(suffix)" }
        let uid = String(key.dropLast(suffix.count))
        return "\(uid.prefix(6))….\(suffix.dropFirst())"
    }

    // MARK: - Saved workspaces

    /// Adopts the richest `"<uid>.SavedWorkspaces"` value onto the bare
    /// `"SavedWorkspaces"` key, once per install.
    ///
    /// - Returns: `true` when legacy workspaces were copied forward on this call.
    @discardableResult
    public static func adoptLegacyWorkspacesIfNeeded(in store: LegacyAdoptionStore) -> Bool {
        let primaryKey = BundleIdentity.savedWorkspacesKey

        guard !store.adoptionBool(forKey: workspacesAdoptionCompletedKey) else { return false }

        // Already-populated bare store: nothing to adopt, but record the decision
        // so later deletions can't be undone by a future sweep.
        if let existing = store.adoptionData(forKey: primaryKey), workspaceCount(in: existing) ?? 0 > 0 {
            store.adoptionSetBool(true, forKey: workspacesAdoptionCompletedKey)
            DeskJigLog.info(.workspace, "LegacyStoreAdoption: Unprefixed workspace store already populated; marking adoption complete")
            return false
        }

        let suffix = ".\(primaryKey)"
        let candidateKeys = store.adoptionAllKeys()
            .filter { $0 != primaryKey && $0.hasSuffix(suffix) }
            .sorted()

        guard !candidateKeys.isEmpty else {
            // Genuinely fresh store — nothing legacy exists to resurrect, so leave
            // the flag unset and let a later load try again.
            return false
        }

        struct Candidate {
            let key: String
            let data: Data
            let count: Int
        }

        let candidates: [Candidate] = candidateKeys.compactMap { key in
            guard let data = store.adoptionData(forKey: key),
                  let count = workspaceCount(in: data) else { return nil }
            return Candidate(key: key, data: data, count: count)
        }

        // Most workspaces wins; ties break on raw byte count (richer snapshot).
        let best = candidates.max { lhs, rhs in
            lhs.count != rhs.count ? lhs.count < rhs.count : lhs.data.count < rhs.data.count
        }

        guard let best, best.count > 0 else {
            store.adoptionSetBool(true, forKey: workspacesAdoptionCompletedKey)
            DeskJigLog.warn(.workspace, "LegacyStoreAdoption: Found per-user workspace keys but none were adoptable", fields: [
                "candidateCount": "\(candidateKeys.count)"
            ])
            return false
        }

        store.adoptionSetData(best.data, forKey: primaryKey)
        store.adoptionSetBool(true, forKey: workspacesAdoptionCompletedKey)

        DeskJigLog.info(.workspace, "LegacyStoreAdoption: Adopted per-user saved workspaces", fields: [
            "sourceKey": maskedKey(best.key, suffix: suffix),
            "candidateCount": "\(candidateKeys.count)",
            "workspaceCount": "\(best.count)",
            "byteCount": "\(best.data.count)"
        ])
        return true
    }

    private static func workspaceCount(in data: Data) -> Int? {
        do {
            return try JSONDecoder().decode([Workspace].self, from: data).count
        } catch {
            DeskJigLog.warn(.workspace, "LegacyStoreAdoption: Failed to decode candidate workspace payload: \(error)")
            return nil
        }
    }

    // MARK: - Boolean completion flags

    /// Adopts a per-user boolean completion flag (`"<uid>.<baseKey>"`) onto its bare
    /// key, once per install. Any legacy copy being `true` wins — completion is
    /// monotonic, and re-showing a finished flow is the failure being fixed.
    ///
    /// - Returns: `true` when a legacy `true` was copied forward on this call.
    @discardableResult
    public static func adoptLegacyCompletionFlagIfNeeded(
        baseKey: String,
        flagKey: String,
        in store: LegacyAdoptionStore
    ) -> Bool {
        guard !store.adoptionBool(forKey: flagKey) else { return false }

        if store.adoptionBool(forKey: baseKey) {
            store.adoptionSetBool(true, forKey: flagKey)
            return false
        }

        let suffix = ".\(baseKey)"
        let candidateKeys = store.adoptionAllKeys()
            .filter { $0 != baseKey && $0.hasSuffix(suffix) }
            .sorted()

        guard !candidateKeys.isEmpty else { return false }

        guard let adoptedKey = candidateKeys.first(where: { store.adoptionBool(forKey: $0) }) else {
            store.adoptionSetBool(true, forKey: flagKey)
            return false
        }

        store.adoptionSetBool(true, forKey: baseKey)
        store.adoptionSetBool(true, forKey: flagKey)
        DeskJigLog.info(.app, "LegacyStoreAdoption: Adopted per-user completion flag", fields: [
            "sourceKey": maskedKey(adoptedKey, suffix: suffix),
            "baseKey": baseKey
        ])
        return true
    }
}
