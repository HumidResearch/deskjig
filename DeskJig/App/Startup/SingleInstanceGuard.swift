//
//  SingleInstanceGuard.swift
//  DeskJig
//
//  Graceful handoff when a second DeskJig instance launches.
//
//  With two app bundles on disk (e.g. a release copy in /Applications plus a
//  debug build in build products) sharing the bundle id, LaunchServices routes
//  a bare `open "bento://…"` to whichever bundle it prefers — usually the
//  /Applications copy — and launches it even though the other copy is already
//  running. The freshly launched duplicate then competes with the running
//  instance for the menu-bar item, the global hotkeys, the Chrome native
//  messaging port and the URL-event handler.
//
//  This guard detects the duplicate at startup, forwards any received bento://
//  URLs to the primary instance's exact bundle (bypassing LaunchServices'
//  default-handler choice) and exits cleanly. `AppDelegate` and `DeskJigApp`
//  both branch on `isSecondaryInstance` to skip normal startup.
//

import AppKit
import CocoaLumberjackSwift
import Foundation
import DeskJigShared

enum SingleInstanceGuard {
    /// Snapshot of a running app instance, decoupled from NSRunningApplication
    /// so primary-selection logic is testable headlessly.
    struct InstanceCandidate: Equatable, Sendable {
        let pid: pid_t
        let bundleURL: URL?
        let launchDate: Date?
        let isTerminated: Bool

        init(pid: pid_t, bundleURL: URL?, launchDate: Date?, isTerminated: Bool = false) {
            self.pid = pid
            self.bundleURL = bundleURL
            self.launchDate = launchDate
            self.isTerminated = isTerminated
        }
    }

    /// The already-running instance this launch defers to, if any.
    @MainActor private(set) static var primaryInstance: NSRunningApplication?

    /// True when another DeskJig instance was already running at launch and this
    /// instance is only alive to hand off URLs and exit.
    @MainActor static var isSecondaryInstance: Bool { primaryInstance != nil }

    /// How long the secondary instance waits for a launch URL before exiting.
    /// LaunchServices delivers the kAEGetURL event right after
    /// applicationDidFinishLaunching, so a short grace period is enough.
    private static let urlGracePeriod: TimeInterval = 2.0

    /// Safety net in case a forward's completion handler never fires.
    private static let forwardCompletionTimeout: TimeInterval = 5.0

    @MainActor private static var pendingForwards = 0
    @MainActor private static var handoffDeadlineTask: Task<Void, Never>?

    // MARK: - Detection (called from DeskJigApp.init, before any startup work)

    /// Detects an already-running DeskJig instance. No-op in test runs.
    @MainActor static func detectPrimaryInstance() {
        guard !RuntimeEnvironment.isRunningTests() else { return }
        guard let bundleID = Bundle.main.bundleIdentifier else { return }

        let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
        let candidates = running.map {
            InstanceCandidate(
                pid: $0.processIdentifier,
                bundleURL: $0.bundleURL,
                launchDate: $0.launchDate,
                isTerminated: $0.isTerminated
            )
        }
        let ownPID = ProcessInfo.processInfo.processIdentifier
        guard let primary = selectPrimary(
            candidates: candidates,
            ownPID: pid_t(ownPID),
            ownLaunchDate: NSRunningApplication.current.launchDate
        ) else { return }

        primaryInstance = running.first { $0.processIdentifier == primary.pid }
        DeskJigLog.warn(.app, "SingleInstanceGuard: another DeskJig instance is already running — entering URL-handoff mode", fields: [
            "ownPath": Bundle.main.bundleURL.path,
            "ownPid": ownPID,
            "primaryPath": primary.bundleURL?.path ?? "?",
            "primaryPid": primary.pid
        ])
    }

    /// Pure primary-selection logic: among `candidates`, returns the instance
    /// this process should defer to, or nil when this process is (or should
    /// become) the primary. The earliest-launched live instance wins; ties are
    /// broken by lower pid. Candidates without a launch date are treated as
    /// long-running (they predate us); if our own launch date is unknown we
    /// defer to any live candidate.
    static func selectPrimary(
        candidates: [InstanceCandidate],
        ownPID: pid_t,
        ownLaunchDate: Date?
    ) -> InstanceCandidate? {
        let others = candidates.filter { $0.pid != ownPID && !$0.isTerminated }
        guard !others.isEmpty else { return nil }

        let ownDate = ownLaunchDate ?? Date.distantFuture
        let winners = others.filter { other in
            let otherDate = other.launchDate ?? Date.distantPast
            if otherDate != ownDate { return otherDate < ownDate }
            return other.pid < ownPID  // simultaneous launch: lower pid wins
        }
        return winners.min { lhs, rhs in
            let lhsDate = lhs.launchDate ?? Date.distantPast
            let rhsDate = rhs.launchDate ?? Date.distantPast
            if lhsDate != rhsDate { return lhsDate < rhsDate }
            return lhs.pid < rhs.pid
        }
    }

    // MARK: - Secondary-instance behavior

    /// Called from applicationDidFinishLaunching in secondary mode: waits
    /// briefly for the launch URL (delivered by LaunchServices right after
    /// launch), then exits. If no URL arrives this was a plain duplicate
    /// launch, so surface the primary instead.
    @MainActor static func beginHandoffCountdown() {
        DeskJigLog.info(.app, "SingleInstanceGuard: waiting \(urlGracePeriod)s for a launch URL before exiting")
        scheduleExit(after: urlGracePeriod, activatePrimaryIfIdle: true)
    }

    /// Forwards a URL to the primary instance's exact bundle (bypassing
    /// LaunchServices' default-handler choice), then exits once delivered.
    @MainActor static func forwardToPrimary(_ url: URL) {
        guard let primary = primaryInstance, let primaryURL = primary.bundleURL else {
            DeskJigLog.error(.app, "SingleInstanceGuard: no primary bundle URL to forward to — exiting", fields: ["url": url.absoluteString])
            scheduleExit(after: 0)
            return
        }

        pendingForwards += 1
        DeskJigLog.info(.app, "SingleInstanceGuard: forwarding URL to primary instance", fields: [
            "primaryPath": primaryURL.path,
            "url": url.absoluteString
        ])
        // Safety net: don't hang forever if the completion handler never fires.
        scheduleExit(after: forwardCompletionTimeout)

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.open([url], withApplicationAt: primaryURL, configuration: configuration) { _, error in
            Task { @MainActor in
                if let error {
                    DeskJigLog.error(.app, "SingleInstanceGuard: URL forward failed", fields: ["error": error.localizedDescription, "url": url.absoluteString])
                } else {
                    DeskJigLog.info(.app, "SingleInstanceGuard: URL forwarded", fields: ["url": url.absoluteString])
                }
                pendingForwards -= 1
                if pendingForwards <= 0 {
                    // Brief linger so a multi-URL open can deliver the rest.
                    scheduleExit(after: 0.5)
                }
            }
        }
    }

    /// (Re)schedules the clean exit. Each call replaces any earlier deadline,
    /// so starting a forward extends the countdown and a completed forward
    /// shortens it; whichever deadline is current exits unconditionally.
    @MainActor private static func scheduleExit(after delay: TimeInterval, activatePrimaryIfIdle: Bool = false) {
        handoffDeadlineTask?.cancel()
        handoffDeadlineTask = Task { @MainActor in
            if delay > 0 {
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
            guard !Task.isCancelled else { return }
            if activatePrimaryIfIdle, pendingForwards == 0, let primary = primaryInstance {
                // Plain duplicate launch (no URL): the user tried to open
                // DeskJig, so bring the running instance forward instead.
                DeskJigLog.info(.app, "SingleInstanceGuard: no launch URL received — activating primary instance")
                primary.activate()
            }
            DeskJigLog.info(.app, "SingleInstanceGuard: handoff complete — exiting cleanly")
            DDLog.sharedInstance.flushLog()
            exit(0)
        }
    }
}
