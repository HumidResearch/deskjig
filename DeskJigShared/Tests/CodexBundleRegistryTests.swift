//  CodexBundleRegistryTests.swift
//  DeskJigSharedTests

import Testing
@testable import DeskJigShared

struct CodexBundleRegistryTests {

    @Test("Codex is registered as an IDE bundle")
    func codexIsIDE() {
        #expect(BundleRegistry.isIDE(OpenByPathBundleIdentifiers.codex))
        #expect(BundleRegistry.ides.contains(OpenByPathBundleIdentifiers.codex))
    }

    @Test("Codex is in OpenByPath supported bundles")
    func codexIsOpenByPathSupported() {
        #expect(OpenByPathBundleIdentifiers.supported.contains(OpenByPathBundleIdentifiers.codex))
    }
}
