// SingleInstanceGuardSelectionTests.swift
// DeskJigTests

import Foundation
import Testing
@testable import DeskJig

/// Headless tests for SingleInstanceGuard's pure primary-selection logic.
/// The selection decides whether a freshly launched DeskJig instance should defer
/// to an already-running one when LaunchServices routes across multiple app bundles.
struct SingleInstanceGuardSelectionTests {
    private let ownPID: pid_t = 500
    private let ownLaunch = Date(timeIntervalSince1970: 1_000)

    private func candidate(
        pid: pid_t,
        path: String? = "/Applications/DeskJig.app",
        launchOffset: TimeInterval? = -60,
        isTerminated: Bool = false
    ) -> SingleInstanceGuard.InstanceCandidate {
        SingleInstanceGuard.InstanceCandidate(
            pid: pid,
            bundleURL: path.map { URL(fileURLWithPath: $0) },
            launchDate: launchOffset.map { ownLaunch.addingTimeInterval($0) },
            isTerminated: isTerminated
        )
    }

    @Test("No other instances → this process is primary")
    func noCandidates() {
        #expect(SingleInstanceGuard.selectPrimary(candidates: [], ownPID: ownPID, ownLaunchDate: ownLaunch) == nil)
    }

    @Test("Only own entry in the list → this process is primary")
    func onlySelf() {
        let own = candidate(pid: ownPID, launchOffset: 0)
        #expect(SingleInstanceGuard.selectPrimary(candidates: [own], ownPID: ownPID, ownLaunchDate: ownLaunch) == nil)
    }

    @Test("Earlier-launched instance wins and is returned as primary")
    func earlierInstanceWins() {
        let earlier = candidate(pid: 100, launchOffset: -60)
        let result = SingleInstanceGuard.selectPrimary(candidates: [earlier], ownPID: ownPID, ownLaunchDate: ownLaunch)
        #expect(result == earlier)
    }

    @Test("Later-launched instance does not demote this process")
    func laterInstanceLoses() {
        let later = candidate(pid: 100, launchOffset: 60)
        #expect(SingleInstanceGuard.selectPrimary(candidates: [later], ownPID: ownPID, ownLaunchDate: ownLaunch) == nil)
    }

    @Test("Terminated instances are ignored")
    func terminatedIgnored() {
        let dead = candidate(pid: 100, launchOffset: -60, isTerminated: true)
        #expect(SingleInstanceGuard.selectPrimary(candidates: [dead], ownPID: ownPID, ownLaunchDate: ownLaunch) == nil)
    }

    @Test("Earliest of several live instances is chosen")
    func earliestOfSeveral() {
        let older = candidate(pid: 100, launchOffset: -120)
        let newer = candidate(pid: 200, launchOffset: -30)
        let result = SingleInstanceGuard.selectPrimary(
            candidates: [newer, older],
            ownPID: ownPID,
            ownLaunchDate: ownLaunch
        )
        #expect(result == older)
    }

    @Test("Simultaneous launch: lower pid wins the primary role")
    func simultaneousLaunchTieBreak() {
        let peerLowerPid = candidate(pid: 100, launchOffset: 0)
        let peerHigherPid = candidate(pid: 900, launchOffset: 0)
        // Lower-pid peer outranks us; we defer to it.
        #expect(SingleInstanceGuard.selectPrimary(candidates: [peerLowerPid], ownPID: ownPID, ownLaunchDate: ownLaunch) == peerLowerPid)
        // Higher-pid peer defers to us; we stay primary.
        #expect(SingleInstanceGuard.selectPrimary(candidates: [peerHigherPid], ownPID: ownPID, ownLaunchDate: ownLaunch) == nil)
    }

    @Test("Candidate without a launch date is treated as long-running (we defer)")
    func unknownCandidateLaunchDateDefers() {
        let unknown = candidate(pid: 100, launchOffset: nil)
        let result = SingleInstanceGuard.selectPrimary(candidates: [unknown], ownPID: ownPID, ownLaunchDate: ownLaunch)
        #expect(result == unknown)
    }

    @Test("Unknown own launch date defers to any live instance")
    func unknownOwnLaunchDateDefers() {
        let other = candidate(pid: 100, launchOffset: 60)
        let result = SingleInstanceGuard.selectPrimary(candidates: [other], ownPID: ownPID, ownLaunchDate: nil)
        #expect(result == other)
    }

    @Test("Dual-bundle scenario: debug primary running, release copy launched by LaunchServices")
    func dualBundleScenario() {
        let debugPrimary = candidate(
            pid: 100,
            path: "/Users/dev/code/deskjig/build/DerivedData/Build/Products/Debug/DeskJig.app",
            launchOffset: -3_600
        )
        let result = SingleInstanceGuard.selectPrimary(
            candidates: [debugPrimary, candidate(pid: ownPID, launchOffset: 0)],
            ownPID: ownPID,
            ownLaunchDate: ownLaunch
        )
        #expect(result == debugPrimary)
    }
}
