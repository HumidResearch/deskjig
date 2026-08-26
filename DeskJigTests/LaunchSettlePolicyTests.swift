// LaunchSettlePolicyTests.swift
// DeskJigTests

import Testing
import Foundation
import DeskJigShared
@testable import DeskJig

struct LaunchSettlePolicyTests {
    private let policy = LaunchSettlePolicy()

    @Test("Apps launched by this restore always settle")
    func launchedByRestoreAlwaysSettles() {
        #expect(policy.needsSettle(launchedByThisRestore: true, isFinishedLaunching: true))
        #expect(policy.needsSettle(launchedByThisRestore: true, isFinishedLaunching: false))
        #expect(policy.needsSettle(launchedByThisRestore: true, isFinishedLaunching: nil))
    }

    @Test("Mid-launch apps settle when another restore launched them")
    func midLaunchAppSettles() {
        #expect(policy.needsSettle(launchedByThisRestore: false, isFinishedLaunching: false))
    }

    @Test("Finished apps do not settle")
    func finishedAppDoesNotSettle() {
        #expect(!policy.needsSettle(launchedByThisRestore: false, isFinishedLaunching: true))
    }

    @Test("Absent apps do not settle")
    func absentAppDoesNotSettle() {
        #expect(!policy.needsSettle(launchedByThisRestore: false, isFinishedLaunching: nil))
    }

    @Test("Restoration configs retain launch settle defaults")
    func restorationConfigLaunchSettleDefaults() {
        let config = GenericWindowRestorationConfig(
            useWindowLocks: false,
            lockTimeout: .seconds(1)
        )
        let slowStartConfig = GenericWindowRestorationConfig.forSlowStartApp(
            useWindowLocks: false,
            lockTimeout: .seconds(1)
        )

        #expect(config.launchSettleDelay == .milliseconds(500))
        #expect(slowStartConfig.launchSettleDelay > .zero)
    }
}
