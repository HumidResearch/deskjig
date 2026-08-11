//  CLIAppAliasCodexTests.swift
//  DeskJigSharedTests

import Foundation
import Testing

// CLI lane (old BentoTests-CLI.xctestplan): isolation-sensitive, run serially.
// Gated: spawns the `bentoctl` executable, which the SwiftPM lane does not build
// (upstream it was co-located with the app-hosted test bundle). Set
// DESKJIG_BENTOCTL to the binary path when running with DESKJIG_ENV_TESTS=1.
@Suite(.serialized, .enabled(if: TestEnvironment.envTestsEnabled, TestEnvironment.gateReason))
struct CLIAppAliasCodexTests {

    @Test("CLI help includes codex app alias")
    func codexAliasListedInHelp() throws {
        let result = try DeskJigCLIInvocationTestSupport.run(["--help"])
        // Help text is a human-readable substring assertion; use `merged` so it
        // passes whether ArgumentParser writes help to stdout or stderr.
        #expect(result.merged.localizedCaseInsensitiveContains("codex"))
        #expect(result.merged.contains("open codex") || result.merged.contains(" codex "))
    }
}
