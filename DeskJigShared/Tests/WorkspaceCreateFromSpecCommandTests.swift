//  WorkspaceCreateFromSpecCommandTests.swift
//  DeskJigSharedTests

import Foundation
import Testing
@testable import DeskJigShared

// CLI lane (old BentoTests-CLI.xctestplan): isolation-sensitive, run serially.
// Gated: spawns the `bentoctl` executable, which the SwiftPM lane does not build
// (upstream it was co-located with the app-hosted test bundle). Set
// DESKJIG_BENTOCTL to the binary path when running with DESKJIG_ENV_TESTS=1.
@Suite(.serialized, .enabled(if: TestEnvironment.envTestsEnabled, TestEnvironment.gateReason))
struct WorkspaceCreateFromSpecCommandTests {
    @Test("create-from-spec saves a workspace from file and exposes it via workspace info")
    func createFromFileAndReadBackInfo() throws {
        let context = try TestContext()
        let workspaceName = "Spec File Workspace"
        let spec = context.specJSON(
            name: workspaceName,
            replaceExisting: false,
            windows: [
                .init(bundleId: "com.mitchellh.ghostty", appName: nil, title: nil, openPath: context.projectPath, screen: 0, layout: .preset("left-half")),
                .init(bundleId: nil, appName: "cursor", title: nil, openPath: context.projectPath, screen: 0, layout: .preset("right-half"))
            ]
        )
        try spec.write(to: context.specFileURL, atomically: true, encoding: .utf8)

        let create = try DeskJigCLIInvocationTestSupport.run(
            ["workspace", "create-from-spec", "--file", context.specFileURL.path, "--format", "json"],
            environment: context.environment
        )
        #expect(create.status == 0)
        #expect(try context.workspaceNames(forCacheKey: context.scopedCacheKey) == [workspaceName])
        #expect(try context.workspaceNames(forCacheKey: "SavedWorkspaces").isEmpty)

        let info = try DeskJigCLIInvocationTestSupport.run(
            ["workspace", "info", workspaceName, "--format", "json"],
            environment: context.environment
        )
        #expect(info.status == 0)

        let payload = try context.parseJSON(info.stdout)
        let data = try #require(payload["data"] as? [String: Any])
        #expect(data["name"] as? String == workspaceName)
        #expect(data["windowCount"] as? Int == 2)
    }

    @Test("create-from-spec accepts stdin input")
    func createFromStdin() throws {
        let context = try TestContext()
        let workspaceName = "Spec Stdin Workspace"
        let spec = context.specJSON(
            name: workspaceName,
            replaceExisting: false,
            windows: [
                .init(bundleId: nil, appName: "terminal", title: nil, openPath: context.projectPath, screen: 0, layout: .preset("top-half"))
            ]
        )

        let result = try DeskJigCLIInvocationTestSupport.run(
            ["workspace", "create-from-spec", "--stdin", "--format", "json"],
            input: spec,
            environment: context.environment
        )
        #expect(result.status == 0)

        let info = try DeskJigCLIInvocationTestSupport.run(
            ["workspace", "info", workspaceName, "--format", "json"],
            environment: context.environment
        )
        #expect(info.status == 0)
        #expect(try context.workspaceNames(forCacheKey: context.scopedCacheKey) == [workspaceName])
    }

    @Test("create-from-spec rejects duplicate names unless replaceExisting is true")
    func duplicateNameFailsWithoutReplaceExisting() throws {
        let context = try TestContext()
        let workspaceName = "Spec Duplicate Workspace"
        let spec = context.specJSON(
            name: workspaceName,
            replaceExisting: false,
            windows: [
                .init(bundleId: nil, appName: "ghostty", title: nil, openPath: context.projectPath, screen: 0, layout: .preset("left-half"))
            ]
        )

        let first = try DeskJigCLIInvocationTestSupport.run(
            ["workspace", "create-from-spec", "--stdin", "--format", "json"],
            input: spec,
            environment: context.environment
        )
        #expect(first.status == 0)

        let duplicate = try DeskJigCLIInvocationTestSupport.run(
            ["workspace", "create-from-spec", "--stdin", "--format", "json"],
            input: spec,
            environment: context.environment
        )
        #expect(duplicate.status != 0)
        // Error text is embedded in the JSON envelope's `error` field on stdout;
        // assert against `merged` so the check survives regardless of stream.
        #expect(duplicate.merged.contains("already exists"))
    }

    @Test("create-from-spec replaceExisting preserves workspace identity and updates windows")
    func replaceExistingPreservesIdentity() throws {
        let context = try TestContext()
        let workspaceName = "Spec Replace Workspace"
        let initialSpec = context.specJSON(
            name: workspaceName,
            replaceExisting: false,
            windows: [
                .init(bundleId: nil, appName: "ghostty", title: nil, openPath: context.projectPath, screen: 0, layout: .preset("left-half"))
            ]
        )
        let updatedSpec = context.specJSON(
            name: workspaceName,
            replaceExisting: true,
            windows: [
                .init(bundleId: nil, appName: "ghostty", title: nil, openPath: context.projectPath, screen: 0, layout: .preset("left-half")),
                .init(bundleId: "com.apple.Terminal", appName: "Terminal", title: nil, openPath: context.projectPath, screen: 0, layout: .preset("right-half"))
            ]
        )

        let first = try DeskJigCLIInvocationTestSupport.run(
            ["workspace", "create-from-spec", "--stdin", "--format", "json"],
            input: initialSpec,
            environment: context.environment
        )
        #expect(first.status == 0)
        let initialInfo = try DeskJigCLIInvocationTestSupport.run(
            ["workspace", "info", workspaceName, "--format", "json"],
            environment: context.environment
        )
        let initialPayload = try context.parseJSON(initialInfo.stdout)
        let initialData = try #require(initialPayload["data"] as? [String: Any])
        let initialID = try #require(initialData["id"] as? String)

        let replace = try DeskJigCLIInvocationTestSupport.run(
            ["workspace", "create-from-spec", "--stdin", "--format", "json"],
            input: updatedSpec,
            environment: context.environment
        )
        #expect(replace.status == 0)

        let finalInfo = try DeskJigCLIInvocationTestSupport.run(
            ["workspace", "info", workspaceName, "--format", "json"],
            environment: context.environment
        )
        let finalPayload = try context.parseJSON(finalInfo.stdout)
        let finalData = try #require(finalPayload["data"] as? [String: Any])
        #expect(finalData["id"] as? String == initialID)
        #expect(finalData["windowCount"] as? Int == 2)
    }

    // Upstream skip carried forward: BentoTests-Full.xctestplan listed this test in
    // `skippedTests`. SwiftPM has no test-plan concept, so the skip becomes inline.
    @Test(
        "create-from-spec supports preset and explicit percentage layouts",
        .disabled("skipped upstream via BentoTests-Full.xctestplan skippedTests")
    )
    func presetAndExplicitLayoutsRoundTrip() throws {
        let context = try TestContext()
        let workspaceName = "Spec Layout Workspace"
        let spec = context.specJSON(
            name: workspaceName,
            replaceExisting: false,
            windows: [
                .init(bundleId: nil, appName: "ghostty", title: nil, openPath: context.projectPath, screen: 0, layout: .preset("top-left-quarter")),
                .init(bundleId: nil, appName: "kitty", title: nil, openPath: context.projectPath, screen: 0, layout: .frame(xPercent: 0.25, yPercent: 0.5, widthPercent: 0.5, heightPercent: 0.25))
            ]
        )

        let create = try DeskJigCLIInvocationTestSupport.run(
            ["workspace", "create-from-spec", "--stdin", "--format", "json"],
            input: spec,
            environment: context.environment
        )
        #expect(create.status == 0)

        let info = try DeskJigCLIInvocationTestSupport.run(
            ["workspace", "info", workspaceName, "--format", "json"],
            environment: context.environment
        )
        let payload = try context.parseJSON(info.stdout)
        let data = try #require(payload["data"] as? [String: Any])
        let windows = try #require(data["windows"] as? [[String: Any]])
        let firstFrame = try #require(windows.first?["relativeFrame"] as? [String: Any])
        let secondFrame = try #require(windows.last?["relativeFrame"] as? [String: Any])
        #expect(firstFrame["xPercent"] as? Double == 0.0)
        #expect(firstFrame["yPercent"] as? Double == 0.0)
        #expect(firstFrame["widthPercent"] as? Double == 0.5)
        #expect(firstFrame["heightPercent"] as? Double == 0.5)
        #expect(secondFrame["xPercent"] as? Double == 0.25)
        #expect(secondFrame["yPercent"] as? Double == 0.5)
        #expect(secondFrame["widthPercent"] as? Double == 0.5)
        #expect(secondFrame["heightPercent"] as? Double == 0.25)
    }

    @Test("create-from-spec validates conflicting bundleId and appName")
    func conflictingBundleAndAppNameFails() throws {
        let context = try TestContext()
        let spec = context.specJSON(
            name: "Conflicting App Spec",
            replaceExisting: false,
            windows: [
                .init(bundleId: "com.apple.Terminal", appName: "Xcode", title: nil, openPath: context.projectPath, screen: 0, layout: .preset("left-half"))
            ]
        )

        let result = try DeskJigCLIInvocationTestSupport.run(
            ["workspace", "create-from-spec", "--stdin", "--format", "json"],
            input: spec,
            environment: context.environment
        )
        #expect(result.status != 0)
        #expect(result.merged.contains("does not match"))
    }

    @Test("create-from-spec posts the external-change signal a running app reloads on")
    func createFromSpecPostsExternalChangeSignal() throws {
        let context = try TestContext()
        let spec = context.specJSON(
            name: "Spec Signal Workspace",
            replaceExisting: false,
            windows: [
                .init(bundleId: nil, appName: "ghostty", title: nil, openPath: context.projectPath, screen: 0, layout: .preset("left-half"))
            ]
        )

        let received = DispatchSemaphore(value: 0)
        let observer = WorkspaceExternalChangeObserver {
            received.signal()
        }

        let create = try DeskJigCLIInvocationTestSupport.run(
            ["workspace", "create-from-spec", "--stdin", "--format", "json"],
            input: spec,
            environment: context.environment
        )
        #expect(create.status == 0)

        // The signal crosses the process boundary via notifyd, so delivery is
        // asynchronous relative to the child's exit; DeskJig.app relies on it to
        // reload its in-memory workspace list without a relaunch (#655). Any
        // store write posts the signal, so parallel-suite cross-talk can only
        // satisfy the wait early, never fail it. Generous timeout for CI load.
        #expect(received.wait(timeout: .now() + 15) == .success)
        withExtendedLifetime(observer) {}
    }

    @Test("quick-switch workspace override includes workspace_id from per-user cache")
    func quickSwitchWorkspaceOverrideIncludesWorkspaceID() throws {
        let context = try TestContext()
        let workspaceName = "Quick Switch Shared Layout"
        let spec = context.specJSON(
            name: workspaceName,
            replaceExisting: false,
            windows: [
                .init(bundleId: nil, appName: "ghostty", title: nil, openPath: context.projectPath, screen: 0, layout: .preset("left-half"))
            ]
        )

        let create = try DeskJigCLIInvocationTestSupport.run(
            ["workspace", "create-from-spec", "--stdin", "--format", "json"],
            input: spec,
            environment: context.environment
        )
        #expect(create.status == 0)

        let info = try DeskJigCLIInvocationTestSupport.run(
            ["workspace", "info", workspaceName, "--format", "json"],
            environment: context.environment
        )
        let payload = try context.parseJSON(info.stdout)
        let data = try #require(payload["data"] as? [String: Any])
        let workspaceID = try #require(data["id"] as? String)

        let quickSwitch = try DeskJigCLIInvocationTestSupport.run(
            ["workspace", "quick-switch", "--workspace", workspaceName, "--directory", context.projectPath],
            environment: context.environment.merging(["BENTOCTL_CAPTURE_OPEN_URL_STDOUT": "1"]) { _, new in new }
        )
        #expect(quickSwitch.status == 0)
        // The captured open-URL is printed to stdout; assert on `merged` so a
        // stray stderr byte under suite load can't mask a correct URL.
        #expect(quickSwitch.merged.contains("workspace=\(workspaceName.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? workspaceName)"))
        #expect(quickSwitch.merged.contains("workspace_id=\(workspaceID)"))
    }
}

private extension WorkspaceCreateFromSpecCommandTests {
    struct TestContext {
        let userID = "test-user-id"
        let rootURL: URL
        let prefsURL: URL
        let specFileURL: URL
        let projectURL: URL

        init() throws {
            rootURL = FileManager.default.temporaryDirectory.appendingPathComponent("deskjig-create-spec-\(UUID().uuidString)")
            prefsURL = rootURL.appendingPathComponent("prefs/com.mscontrol.bento.plist")
            specFileURL = rootURL.appendingPathComponent("workspace-spec.json")
            projectURL = rootURL.appendingPathComponent("project", isDirectory: true)
            try FileManager.default.createDirectory(at: projectURL, withIntermediateDirectories: true)
        }

        var projectPath: String { projectURL.path }

        var scopedCacheKey: String { "\(userID).SavedWorkspaces" }

        var environment: [String: String] {
            [
                "BENTOCLI_PREFS_PATH_OVERRIDE": prefsURL.path,
                "BENTOCLI_USER_ID_OVERRIDE": userID
            ]
        }

        func parseJSON(_ string: String) throws -> [String: Any] {
            let data = try #require(string.data(using: .utf8))
            return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        }

        func workspaceNames(forCacheKey cacheKey: String) throws -> [String] {
            guard let prefs = NSDictionary(contentsOf: prefsURL) as? [String: Any],
                  let rawData = prefs[cacheKey] as? Data else {
                return []
            }

            let workspaces = try JSONDecoder().decode([Workspace].self, from: rawData)
            return workspaces.map(\.name)
        }

        func specJSON(
            name: String,
            replaceExisting: Bool,
            windows: [WindowInput]
        ) -> String {
            let payload: [String: Any] = [
                "name": name,
                "icon": "🧪",
                "replaceExisting": replaceExisting,
                "windows": windows.map(\.jsonObject)
            ]
            let data = try! JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
            return String(decoding: data, as: UTF8.self)
        }
    }

    struct WindowInput {
        enum Layout {
            case preset(String)
            case frame(xPercent: Double, yPercent: Double, widthPercent: Double, heightPercent: Double)
        }

        let bundleId: String?
        let appName: String?
        let title: String?
        let openPath: String?
        let screen: Int
        let layout: Layout

        var jsonObject: [String: Any] {
            var object: [String: Any] = [
                "screen": screen
            ]
            if let bundleId { object["bundleId"] = bundleId }
            if let appName { object["appName"] = appName }
            if let title { object["title"] = title }
            if let openPath { object["openPath"] = openPath }
            switch layout {
            case .preset(let preset):
                object["layout"] = preset
            case .frame(let xPercent, let yPercent, let widthPercent, let heightPercent):
                object["layout"] = [
                    "xPercent": xPercent,
                    "yPercent": yPercent,
                    "widthPercent": widthPercent,
                    "heightPercent": heightPercent
                ]
            }
            return object
        }
    }
}
