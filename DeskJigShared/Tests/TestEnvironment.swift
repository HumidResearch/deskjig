//  TestEnvironment.swift
//  DeskJigSharedTests

import Foundation
import Testing

/// Opt-in gate for suites that need a real GUI/AX/system environment.
///
/// The old app-hosted `BentoTests` bundle expressed this split with Xcode test
/// plans: `BentoTests-Headless.xctestplan` whitelisted the suites that were safe
/// to run unattended in CI, and everything absent from that whitelist needed a
/// logged-in session with Accessibility permission, running apps, a window
/// server, Chrome, or tmux. SwiftPM has no test-plan concept, so the whitelist
/// is carried forward in-source: whitelisted suites run by default, and every
/// other suite is `.enabled(if: TestEnvironment.envTestsEnabled, ...)`.
///
/// Running the gated suites drives real windows and applications on the host
/// machine, so they never run by default — set `DESKJIG_ENV_TESTS=1` explicitly,
/// and only on a machine whose desktop session you are willing to disturb.
public enum TestEnvironment {
    /// `true` only when `DESKJIG_ENV_TESTS=1` is set in the environment.
    public static var envTestsEnabled: Bool {
        ProcessInfo.processInfo.environment["DESKJIG_ENV_TESTS"] == "1"
    }

    /// Shared reason attached to every gated suite. Typed as `Comment` so it can
    /// be passed straight to `.enabled(if:_:)`.
    public static let gateReason: Comment = "needs GUI/AX/system environment — set DESKJIG_ENV_TESTS=1"

    /// Same reason as a plain `String`, for `XCTSkipUnless` in XCTest-based suites.
    public static let gateReasonText = "needs GUI/AX/system environment — set DESKJIG_ENV_TESTS=1"
}
