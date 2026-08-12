//  LegacyStoreAdoptionTests.swift
//  DeskJigSharedTests

import Foundation
import Testing
@testable import DeskJigShared

/// Adoption of the account-scoped predecessor's per-user keys.
///
/// Every case runs against a throwaway plist file, never the real
/// `com.mscontrol.bento` suite — the same override shape the CLI uses under
/// `BENTOCLI_PREFS_PATH_OVERRIDE`, so the store here is byte-identical to what a
/// real install holds.
struct LegacyStoreAdoptionTests {

    // MARK: - Fixtures

    private static func makeWorkspace(_ name: String) -> Workspace {
        Workspace(
            name: name,
            workspaceWindows: [
                WorkspaceWindow(
                    id: UUID(),
                    bundleIdentifier: "com.example.\(name.lowercased())",
                    appName: name,
                    windowTitle: name,
                    screenIndex: 0,
                    relativeFrame: RelativeWindowFrame(xPercent: 0, yPercent: 0, widthPercent: 0.5, heightPercent: 1)
                )
            ]
        )
    }

    private static func encoded(_ names: [String]) throws -> Data {
        try JSONEncoder().encode(names.map { makeWorkspace($0) })
    }

    /// Temp plist + the store handle reading it.
    private struct Fixture {
        let url: URL
        let store: PlistFileLegacyAdoptionStore

        init() throws {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("deskjig-legacy-adoption-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            url = directory.appendingPathComponent("\(BundleIdentity.defaultsSuiteName).plist")
            store = PlistFileLegacyAdoptionStore(url: url)
        }

        func seed(_ entries: [String: Any]) {
            NSDictionary(dictionary: entries).write(to: url, atomically: true)
        }

        var raw: [String: Any] {
            (NSDictionary(contentsOf: url) as? [String: Any]) ?? [:]
        }

        func workspaceNames(forKey key: String) throws -> [String] {
            guard let data = raw[key] as? Data else { return [] }
            return try JSONDecoder().decode([Workspace].self, from: data).map(\.name)
        }

        func cleanUp() {
            try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
        }
    }

    // MARK: - Tests

    @Test("Adopts a per-user workspace store into the unprefixed key")
    func adoptsPerUserWorkspaceStore() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }

        let legacyKey = "JAffmXAnUrbmS85cs8oDySRIJ8d2.SavedWorkspaces"
        let legacyData = try Self.encoded(["Alpha", "Beta"])
        fixture.seed([legacyKey: legacyData])

        let adopted = LegacyStoreAdoption.adoptLegacyWorkspacesIfNeeded(in: fixture.store)
        #expect(adopted)

        // The app's read path now sees both workspaces under the frozen bare key.
        #expect(try fixture.workspaceNames(forKey: BundleIdentity.savedWorkspacesKey) == ["Alpha", "Beta"])
        // The one-shot flag is recorded...
        #expect(fixture.raw[LegacyStoreAdoption.workspacesAdoptionCompletedKey] as? Bool == true)
        // ...and the legacy original is left byte-identical.
        #expect(fixture.raw[legacyKey] as? Data == legacyData)
    }

    @Test("Adopted workspaces are not resurrected after the user deletes them all")
    func doesNotResurrectDeletedWorkspaces() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }

        let legacyKey = "JAffmXAnUrbmS85cs8oDySRIJ8d2.SavedWorkspaces"
        fixture.seed([legacyKey: try Self.encoded(["Alpha", "Beta"])])
        #expect(LegacyStoreAdoption.adoptLegacyWorkspacesIfNeeded(in: fixture.store))

        // User deletes everything: the bare key is rewritten as an empty collection.
        fixture.store.adoptionSetData(try Self.encoded([]), forKey: BundleIdentity.savedWorkspacesKey)

        let adoptedAgain = LegacyStoreAdoption.adoptLegacyWorkspacesIfNeeded(in: fixture.store)
        #expect(!adoptedAgain)
        #expect(try fixture.workspaceNames(forKey: BundleIdentity.savedWorkspacesKey).isEmpty)
    }

    @Test("The per-user store with the most workspaces wins")
    func richestCandidateWins() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }

        // Sorted-key order deliberately puts the smaller store first, so a
        // first-match implementation would fail this.
        fixture.seed([
            "aaaaaaUID.SavedWorkspaces": try Self.encoded(["Solo"]),
            "zzzzzzUID.SavedWorkspaces": try Self.encoded(["Alpha", "Beta", "Gamma"])
        ])

        #expect(LegacyStoreAdoption.adoptLegacyWorkspacesIfNeeded(in: fixture.store))
        #expect(try fixture.workspaceNames(forKey: BundleIdentity.savedWorkspacesKey) == ["Alpha", "Beta", "Gamma"])
    }

    @Test("An already-populated unprefixed store is left alone and flagged")
    func populatedStoreIsNotOverwritten() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }

        fixture.seed([
            BundleIdentity.savedWorkspacesKey: try Self.encoded(["Local"]),
            "JAffmXAnUrbmS85cs8oDySRIJ8d2.SavedWorkspaces": try Self.encoded(["Alpha", "Beta"])
        ])

        #expect(!LegacyStoreAdoption.adoptLegacyWorkspacesIfNeeded(in: fixture.store))
        #expect(try fixture.workspaceNames(forKey: BundleIdentity.savedWorkspacesKey) == ["Local"])
        #expect(fixture.raw[LegacyStoreAdoption.workspacesAdoptionCompletedKey] as? Bool == true)
    }

    @Test("A store with no legacy keys stays untouched and unflagged")
    func freshStoreIsANoOp() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }

        fixture.seed([:])
        #expect(!LegacyStoreAdoption.adoptLegacyWorkspacesIfNeeded(in: fixture.store))
        #expect(fixture.raw[BundleIdentity.savedWorkspacesKey] == nil)
        #expect(fixture.raw[LegacyStoreAdoption.workspacesAdoptionCompletedKey] == nil)
    }

    @Test("A per-user completion flag is adopted onto the bare key exactly once")
    func adoptsPerUserCompletionFlag() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }

        let baseKey = "SimpleOnboarding.Completed"
        let flagKey = LegacyStoreAdoption.onboardingAdoptionCompletedKey
        fixture.seed(["JAffmXAnUrbmS85cs8oDySRIJ8d2.\(baseKey)": true])

        #expect(LegacyStoreAdoption.adoptLegacyCompletionFlagIfNeeded(baseKey: baseKey, flagKey: flagKey, in: fixture.store))
        #expect(fixture.raw[baseKey] as? Bool == true)
        #expect(fixture.raw[flagKey] as? Bool == true)

        // A later reset must survive: with the flag set, the sweep never re-runs.
        fixture.store.adoptionSetBool(false, forKey: baseKey)
        #expect(!LegacyStoreAdoption.adoptLegacyCompletionFlagIfNeeded(baseKey: baseKey, flagKey: flagKey, in: fixture.store))
        #expect(fixture.raw[baseKey] as? Bool == false)
    }

    @Test("Logged source keys are masked to the first six UID characters")
    func maskedKeyHidesMostOfTheUID() {
        let masked = LegacyStoreAdoption.maskedKey(
            "JAffmXAnUrbmS85cs8oDySRIJ8d2.SavedWorkspaces",
            suffix: ".SavedWorkspaces"
        )
        #expect(masked == "JAffmX….SavedWorkspaces")
        #expect(!masked.contains("AnUrbmS85"))
    }

    // MARK: - App read path

    @Test("WorkspaceStorageService.loadWorkspaces() adopts a per-user store")
    func appLoadPathAdoptsPerUserStore() throws {
        // Throwaway suite — asserted distinct from the real one before use.
        let suiteName = "com.mscontrol.bento.tests.legacy-adoption.\(UUID().uuidString)"
        #expect(suiteName != BundleIdentity.defaultsSuiteName)
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let legacyKey = "JAffmXAnUrbmS85cs8oDySRIJ8d2.SavedWorkspaces"
        defaults.set(try Self.encoded(["Alpha", "Beta"]), forKey: legacyKey)

        let service = WorkspaceStorageService(defaults: defaults)
        #expect(service.loadWorkspaces().map(\.name) == ["Alpha", "Beta"])
        #expect(defaults.data(forKey: BundleIdentity.savedWorkspacesKey) != nil)
        #expect(defaults.bool(forKey: LegacyStoreAdoption.workspacesAdoptionCompletedKey))

        // Delete-all then reload: the flag keeps the legacy copy from coming back.
        defaults.set(try Self.encoded([]), forKey: BundleIdentity.savedWorkspacesKey)
        #expect(service.loadWorkspaces().isEmpty)
    }
}
