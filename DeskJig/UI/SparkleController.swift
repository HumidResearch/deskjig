//  SparkleController.swift
//  DeskJig

import Sparkle
import SwiftUI
import DeskJigShared

enum SparkleProbeTrigger: String {
    case appLaunch = "app_launch"
    case settingsOpened = "settings_opened"
}

enum SparkleUpdateAvailability: Equatable {
    case unknown
    case checking
    case available(version: String, build: String)
    case none
    case error(message: String)
}

@MainActor
protocol SparkleUpdateStateSink: AnyObject {
    func sparkleDidStartUpdateCycle(checkType: SPUUpdateCheck)
    func sparkleDidFindUpdate(version: String, build: String)
    func sparkleDidNotFindUpdate()
    func sparkleDidFailUpdateCycle(message: String)
    func sparkleWillInstallUpdate(version: String, build: String)
    func sparkleDidFinishUpdateSession()
}

/// Interface to the Sparkle framework that checks for app updates
/// Exposes update availability for UI badges and supports silent informational probes.
@MainActor
final class SparkleController: ObservableObject {
    private let updaterController: SPUStandardUpdaterController

    // Keep strong references to delegates to prevent deallocation
    private let updaterDelegate: SparkleUpdateDelegate
    private let userDriverDelegate: SparkleUserDriverDelegate

    @Published var canCheckForUpdates = false
    @Published private(set) var updateAvailability: SparkleUpdateAvailability = .unknown

    private var lastSilentProbeDate: Date?
    private let silentProbeThrottleSeconds: TimeInterval = 30
    private var silentProbeInFlight = false

    private var isUpdateSessionInProgress: Bool {
        if case .checking = updateAvailability {
            return true
        }
        return false
    }

    init(appDelegate: AppDelegate?) {
        DeskJigLog.info(.app, "Initializing SparkleController with logging delegates")

        // Create delegate instances
        self.updaterDelegate = SparkleUpdateDelegate(appDelegate: appDelegate)
        self.userDriverDelegate = SparkleUserDriverDelegate()

        // Placeholder state must be resolved from the bundle BEFORE construction.
        // With `startingUpdater: true` the controller starts the updater inside
        // this initializer; against a placeholder configuration (unresolvable
        // host, or a missing/placeholder SUPublicEDKey) the start itself fails and
        // SPUStandardUpdaterController presents its own "The updater failed to
        // start" alert — an app-modal dialog raised before any of our per-path
        // guards can run.
        let isPlaceholderFeed = Self.bundleUpdateConfigurationIsPlaceholder()
        self.isPlaceholderFeed = isPlaceholderFeed

        // Initialize updater controller with delegates
        updaterController = SPUStandardUpdaterController(
            startingUpdater: !isPlaceholderFeed,
            updaterDelegate: updaterDelegate,
            userDriverDelegate: userDriverDelegate
        )

        updaterDelegate.stateSink = self
        userDriverDelegate.stateSink = self

        guard !isPlaceholderFeed else {
            // Never-started updater: leave `canCheckForUpdates` false rather than
            // observing an updater that has no session, and skip the automatic-check
            // configuration (which would touch the same unstarted updater).
            canCheckForUpdates = false
            DeskJigLog.info(.app, "SparkleController initialized with updater NOT started: placeholder Sparkle configuration (feed URL or SUPublicEDKey not set); all update paths suppressed")
            return
        }

        updaterController.updater
            .publisher(for: \.canCheckForUpdates)
            .receive(on: DispatchQueue.main)
            .assign(to: &$canCheckForUpdates)

        configureAlwaysOnAutomaticChecks()

        // Log the initial state
        DeskJigLog.info(.app, "SparkleController initialized", fields: [
            "feedURL": updaterController.updater.feedURL?.absoluteString ?? "none",
            "autoChecks": updaterController.updater.automaticallyChecksForUpdates,
            "interval": "\(updaterController.updater.updateCheckInterval)s",
            "lastCheck": String(describing: updaterController.updater.lastUpdateCheckDate)
        ])
    }

    /// Convenience initializer for when the AppDelegate is not available
    convenience init() {
        self.init(appDelegate: NSApplication.shared.delegate as? AppDelegate)
    }

    /// The literal committed in Info.plist until the maintainer generates the
    /// real EdDSA keypair. `.github/workflows/release.yml` refuses to build a
    /// release while this value is still present; this constant is the app-side
    /// half of the same guard.
    private static let publicEDKeyPlaceholder = "REPLACE_WITH_SPARKLE_PUBLIC_KEY"

    /// Reads `SUFeedURL` and `SUPublicEDKey` straight from the bundle, without an
    /// updater instance.
    ///
    /// Either half being unset makes an update check pointless — an
    /// `example.invalid` feed can reach no server, and a missing or placeholder
    /// public key means no downloaded update could ever be trusted. Both are
    /// resolved before `SPUStandardUpdaterController` exists so the decision can
    /// gate `startingUpdater:` itself.
    private static func bundleUpdateConfigurationIsPlaceholder() -> Bool {
        guard let rawFeed = Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String else {
            return true
        }
        let feed = rawFeed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !feed.isEmpty, let host = URL(string: feed)?.host else { return true }
        if host.hasSuffix("example.invalid") { return true }

        guard let rawKey = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String else {
            return true
        }
        let key = rawKey.trimmingCharacters(in: .whitespacesAndNewlines)
        return key.isEmpty || key == publicEDKeyPlaceholder
    }

    /// True while the Info.plist ships a placeholder feed URL or public key.
    /// Every check path stays suppressed behind this as a second layer, so a real
    /// feed in M2 restores full behavior with no further changes here.
    private let isPlaceholderFeed: Bool

    func checkForUpdates() {
        guard !isPlaceholderFeed else {
            DeskJigLog.info(.app, "Manual update check ignored: placeholder Sparkle configuration (feed URL or SUPublicEDKey not set)")
            return
        }
        DeskJigLog.info(.app, "Manual update check requested by user")
        updateAvailability = .checking
        updaterController.checkForUpdates(nil)
    }

    func probeForUpdates(trigger: SparkleProbeTrigger) {
        guard !isPlaceholderFeed else {
            DeskJigLog.info(.app, "Skipping silent probe: placeholder feed URL", fields: ["trigger": trigger.rawValue])
            return
        }
        if trigger == .settingsOpened,
           let lastSilentProbeDate,
           Date().timeIntervalSince(lastSilentProbeDate) < silentProbeThrottleSeconds {
            DeskJigLog.info(.app, "Skipping silent probe: throttled", fields: ["trigger": trigger.rawValue])
            return
        }

        if isUpdateSessionInProgress {
            // Recover local probe state if Sparkle is already checking via another trigger.
            silentProbeInFlight = false
            DeskJigLog.info(.app, "Skipping silent probe: Sparkle session already in progress", fields: ["trigger": trigger.rawValue])
            return
        }

        guard !silentProbeInFlight else {
            DeskJigLog.info(.app, "Skipping silent probe: probe already in flight", fields: ["trigger": trigger.rawValue])
            return
        }

        DeskJigLog.info(.app, "Silent update probe requested", fields: ["trigger": trigger.rawValue])
        silentProbeInFlight = true
        lastSilentProbeDate = Date()
        updateAvailability = .checking
        updaterController.updater.checkForUpdateInformation()
    }

    var shouldShowUpdateBadge: Bool {
        if case .available = updateAvailability {
            return true
        }
        return false
    }

    #if DEBUG
    /// Set update check interval to 1 minute for testing
    func setShortUpdateInterval() {
        updaterController.updater.updateCheckInterval = 60 // 1 minute
        DeskJigLog.info(.app, "Set update check interval to 60s for testing", fields: [
            "autoChecks": updaterController.updater.automaticallyChecksForUpdates,
            "lastCheck": String(describing: updaterController.updater.lastUpdateCheckDate)
        ])

        if !updaterController.updater.automaticallyChecksForUpdates {
            DeskJigLog.warn(.app, "Automatic checks are DISABLED. Enable them in Settings to test automatic updates.")
        }
    }

    /// Reset update check interval to default (24 hours)
    func resetUpdateInterval() {
        updaterController.updater.updateCheckInterval = 86400 // 24 hours
        DeskJigLog.info(.app, "Reset update check interval to 86400 seconds (24 hours)")
    }
    #endif

    private func configureAlwaysOnAutomaticChecks() {
        guard !isPlaceholderFeed else {
            UserDefaults.standard.set(false, forKey: "SUEnableAutomaticChecks")
            updaterController.updater.automaticallyChecksForUpdates = false
            DeskJigLog.info(.app, "Sparkle automatic checks disabled: placeholder Sparkle configuration (feed URL or SUPublicEDKey not set)")
            return
        }
        UserDefaults.standard.set(true, forKey: "SUEnableAutomaticChecks")
        updaterController.updater.automaticallyChecksForUpdates = true
        updaterController.updater.updateCheckInterval = 86400
        DeskJigLog.info(.app, "Sparkle always-on checks enabled (interval: 24h)")
    }
}

extension SparkleController: SparkleUpdateStateSink {
    func sparkleDidStartUpdateCycle(checkType: SPUUpdateCheck) {
        if checkType == .updateInformation || checkType == .updates {
            updateAvailability = .checking
        }
    }

    func sparkleDidFindUpdate(version: String, build: String) {
        updateAvailability = .available(version: version, build: build)
    }

    func sparkleDidNotFindUpdate() {
        updateAvailability = .none
    }

    func sparkleDidFailUpdateCycle(message: String) {
        updateAvailability = .error(message: message)
    }

    func sparkleWillInstallUpdate(version: String, build: String) {
        updateAvailability = .available(version: version, build: build)
    }

    func sparkleDidFinishUpdateSession() {
        silentProbeInFlight = false
    }
}
