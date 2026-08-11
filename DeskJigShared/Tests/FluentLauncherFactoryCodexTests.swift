//  FluentLauncherFactoryCodexTests.swift
//  DeskJigSharedTests

import Testing
@testable import DeskJigShared

// CLI lane (old BentoTests-CLI.xctestplan): isolation-sensitive, run serially.
@Suite(.serialized)
struct FluentLauncherFactoryCodexTests {

    @Test("FluentLauncherFactory resolves Codex launcher")
    func resolvesCodexLauncher() {
        let launcher = FluentLauncherFactory.launcher(for: OpenByPathBundleIdentifiers.codex)
        let resolved = launcher as? FluentCodexLauncher

        #expect(resolved != nil)
        #expect(resolved?.bundleId == OpenByPathBundleIdentifiers.codex)
        #expect(resolved?.appName == "Codex")
    }
}
