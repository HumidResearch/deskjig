import Testing
@testable import DeskJigShared

struct SubsystemRegistryWildcardTests {
    @Test("Exact subsystem name matches")
    func exactSubsystemNameMatches() {
        #expect(SubsystemRegistry.matchesVerbose(.restorationSnapshot, verbose: ["restore.snapshot"]))
    }

    @Test("Top-level wildcard matches a nested subsystem")
    func topLevelWildcardMatchesNestedSubsystem() {
        #expect(SubsystemRegistry.matchesVerbose(.restorationExecutor, verbose: ["restore.*"]))
    }

    @Test("Sub-category wildcard matches its prefix subsystem")
    func subcategoryWildcardMatchesPrefixSubsystem() {
        #expect(SubsystemRegistry.matchesVerbose(.restorationSnapshot, verbose: ["restore.snapshot.*"]))
    }

    @Test("Bare wildcard matches every subsystem")
    func bareWildcardMatchesEverySubsystem() {
        #expect(SubsystemRegistry.matchesVerbose(.workspace, verbose: ["*"]))
    }

    @Test("Partial component wildcard does not match")
    func partialComponentWildcardDoesNotMatch() {
        #expect(!SubsystemRegistry.matchesVerbose(.restorationSnapshot, verbose: ["restore.snap.*"]))
    }
}
