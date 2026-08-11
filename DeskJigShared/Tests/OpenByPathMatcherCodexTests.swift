//  OpenByPathMatcherCodexTests.swift
//  DeskJigSharedTests

import Testing
@testable import DeskJigShared

// CLI lane (old BentoTests-CLI.xctestplan): isolation-sensitive, run serially.
@Suite(.serialized)
struct OpenByPathMatcherCodexTests {

    @Test("OpenByPath matcher treats Codex app title as generic IDE title")
    func codexGenericTitle() {
        #expect(OpenByPathMatcher.isGenericIDETitle("Codex", bundleID: OpenByPathBundleIdentifiers.codex))
        #expect(!OpenByPathMatcher.isGenericIDETitle("my-project — Codex", bundleID: OpenByPathBundleIdentifiers.codex))
    }
}
