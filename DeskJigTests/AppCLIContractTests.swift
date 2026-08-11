// AppCLIContractTests.swift
// DeskJigTests

import Foundation
import Testing
import DeskJigShared

/// The app<->CLI contract, asserted IN PROCESS inside the app-hosted test bundle.
///
/// `deskjig` and DeskJig.app are separate processes that agree on exactly two
/// things: a shared `UserDefaults` suite (`com.mscontrol.bento`) holding the
/// workspace collection under the key `SavedWorkspaces`, and a distributed
/// notification that tells the app the store changed underneath it (#655).
/// Both values are frozen legacy identifiers (docs/LEGACY_IDENTIFIERS.md) — a
/// rename on either side silently orphans every installed user's workspaces,
/// which no compiler check would catch. These tests are the guard.
///
/// The CLI's own storage type (`SharedWorkspaceManager`, DeskJigCLI) is not
/// linkable from an app-hosted bundle, so the CLI side is reproduced here
/// exactly as it behaves under `BENTOCLI_PREFS_PATH_OVERRIDE`: a plist file
/// whose `SavedWorkspaces` value is `JSONEncoder`-encoded `[Workspace]` data.
/// That is the byte-level shape the app must be able to read back.
///
/// **The real defaults suite is never written.** Writes go to a temp plist and
/// to a per-test suite; the real suite is only read, and only to prove it was
/// left untouched.
@Suite(.serialized)
struct AppCLIContractTests {

    // MARK: - Frozen identifiers

    @Test("Storage contract uses the frozen suite, key and notification name")
    func storageContractIdentifiersAreFrozen() {
        // Spelled out as literals on purpose: this test exists to fail when the
        // constants are "cleaned up" into DeskJig-branded values.
        #expect(BundleIdentity.defaultsSuiteName == "com.mscontrol.bento")
        #expect(BundleIdentity.savedWorkspacesKey == "SavedWorkspaces")
        #expect(BundleIdentity.bundleID == BundleIdentity.defaultsSuiteName)
        #expect(
            WorkspaceExternalChangeSignal.notificationName.rawValue
                == "com.mscontrol.bento.workspaces-changed-externally"
        )
    }

    @Test("Test host is DeskJig.app under the frozen bundle id")
    func testHostIsTheDeskJigApp() {
        // App-hosted suite: Bundle.main is DeskJig.app, so the host process
        // resolves `UserDefaults(suiteName:)` to the same domain the CLI writes.
        // A nil identifier means the suite was run without the app host, where
        // nothing below it proves anything about the app's view of the store.
        let hostBundleID = Bundle.main.bundleIdentifier
        #expect(
            hostBundleID == BundleIdentity.bundleID,
            "Expected DeskJig.app as the test host, got \(hostBundleID ?? "no bundle identifier — suite is not app-hosted")"
        )
    }

    // MARK: - Store round trip

    @Test("Workspace written by the CLI storage path is read back by the app")
    func cliWrittenWorkspaceRoundTripsThroughTheAppReader() throws {
        let realSuite = UserDefaults(suiteName: BundleIdentity.defaultsSuiteName)
        let realStoreBefore = realSuite?.data(forKey: BundleIdentity.savedWorkspacesKey)

        let tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("appcli-contract-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        // Same file name the CLI would use, in a temp directory instead of
        // ~/Library/Preferences — the override path the CLI reads.
        let prefsURL = tempDirectory.appendingPathComponent("\(BundleIdentity.defaultsSuiteName).plist")
        setenv("BENTOCLI_PREFS_PATH_OVERRIDE", prefsURL.path, 1)
        defer { unsetenv("BENTOCLI_PREFS_PATH_OVERRIDE") }

        let window = WorkspaceWindow(
            id: UUID(),
            bundleIdentifier: "com.example.contract",
            appName: "Contract App",
            windowTitle: "Contract Window",
            screenIndex: 0,
            relativeFrame: RelativeWindowFrame(xPercent: 0, yPercent: 0, widthPercent: 0.5, heightPercent: 1)
        )
        let written = Workspace(name: "app-cli-contract", workspaceWindows: [window])

        // CLI side: JSON-encode the collection and store it under the frozen
        // key in the prefs plist (SharedWorkspaceManager.saveWorkspaces, override branch).
        let encoded = try JSONEncoder().encode([written])
        let prefsDictionary = NSDictionary(dictionary: [BundleIdentity.savedWorkspacesKey: encoded])
        #expect(prefsDictionary.write(to: prefsURL, atomically: true))

        // The value really is stored under the literal key, as Data.
        let onDisk = try #require(NSDictionary(contentsOf: prefsURL) as? [String: Any])
        #expect(onDisk["SavedWorkspaces"] is Data)

        // App side: WorkspaceStorageService reads the same key out of a
        // UserDefaults domain. Load the CLI's plist into a throwaway suite so
        // the read goes through the app's real code path, never the real suite.
        let scratchSuiteName = "com.mscontrol.bento.tests.appcli-contract.\(UUID().uuidString)"
        #expect(scratchSuiteName != BundleIdentity.defaultsSuiteName)
        let scratchDefaults = try #require(UserDefaults(suiteName: scratchSuiteName))
        defer { scratchDefaults.removePersistentDomain(forName: scratchSuiteName) }
        scratchDefaults.setPersistentDomain(onDisk, forName: scratchSuiteName)

        let loaded = WorkspaceStorageService(defaults: scratchDefaults).loadWorkspaces()

        #expect(loaded.count == 1)
        let readBack = try #require(loaded.first)
        #expect(readBack.id == written.id)
        #expect(readBack.name == written.name)
        #expect(readBack.windows.count == 1)
        #expect(readBack.windows.first?.bundleIdentifier == window.bundleIdentifier)

        // Nothing above may have touched the user's real workspace store.
        #expect(realSuite?.data(forKey: BundleIdentity.savedWorkspacesKey) == realStoreBefore)
    }

    // MARK: - Change signal

    @Test("External-change signal round-trips between poster and observer")
    func externalChangeSignalRoundTrips() {
        let received = DispatchSemaphore(value: 0)
        let observer = WorkspaceExternalChangeObserver {
            received.signal()
        }

        WorkspaceExternalChangeSignal.post()

        // Distributed notifications round-trip through notifyd, so delivery is
        // asynchronous even when poster and observer share a process. The wait
        // happens off the main thread (Swift Testing default), leaving the main
        // queue free for the observer's delivery. Generous timeout for CI load.
        #expect(received.wait(timeout: .now() + 15) == .success)
        withExtendedLifetime(observer) {}
    }
}
