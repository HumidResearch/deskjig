//  SparkleUpdateDelegate.swift
//  DeskJig
//
//  Provides comprehensive logging for the Sparkle update lifecycle.

import Foundation
import Sparkle
import DeskJigShared

/// Delegate for Sparkle updater that provides comprehensive logging of the update lifecycle
/// All events are logged to DeskJigLog (local file logs)
final class SparkleUpdateDelegate: NSObject, SPUUpdaterDelegate {

    // MARK: - Properties

    private let appDelegate: AppDelegate?
    weak var stateSink: SparkleUpdateStateSink?

    // MARK: - Initialization

    init(appDelegate: AppDelegate?) {
        self.appDelegate = appDelegate
        super.init()
        DeskJigLog.info(.app, "SparkleUpdateDelegate initialized")
    }

    // MARK: - Channel Support (Beta Updates)

    /// Returns the allowed update channels based on user preference.
    /// - Returns: A set of channel names that this updater can access.
    ///   Empty set = default channel only. Adding "beta" allows access to release candidates.
    /// Note: DeskJig ships no UI for this preference; it is set manually with
    /// `defaults write com.mscontrol.bento UpdatePermissions.BetaChannel -bool true`.
    /// This method just reads the preference directly.
    func allowedChannels(for updater: SPUUpdater) -> Set<String> {
        let betaEnabled = UserDefaults.standard.bool(forKey: "UpdatePermissions.BetaChannel")

        if betaEnabled {
            DeskJigLog.info(.app, "Sparkle allowed channels: [default, beta]")
            return ["beta"]
        } else {
            DeskJigLog.info(.app, "Sparkle allowed channels: [default]")
            return []
        }
    }

    // MARK: - Update Check Lifecycle

    func updater(_ updater: SPUUpdater, mayPerform updateCheck: SPUUpdateCheck) throws {
        let checkType = updateCheckTypeString(updateCheck)
        DeskJigLog.info(.app, "Sparkle update check permission requested", fields: ["type": checkType])
        Task { @MainActor in
            stateSink?.sparkleDidStartUpdateCycle(checkType: updateCheck)
        }

        // Allow the check to proceed
    }

    func updater(_ updater: SPUUpdater, didFinishLoading appcast: SUAppcast) {
        DeskJigLog.info(.app, "Sparkle appcast loaded", fields: ["items": appcast.items.count])

        for (index, item) in appcast.items.enumerated() {
            DeskJigLog.info(.app, "Sparkle appcast item", fields: ["index": index + 1, "version": item.displayVersionString, "build": item.versionString])
        }
    }

    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        let currentVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
        let currentBuild = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "unknown"
        let targetVersion = item.displayVersionString
        let targetBuild = item.versionString

        DeskJigLog.info(.app, "Sparkle valid update found", fields: [
            "current": "\(currentVersion) (\(currentBuild))",
            "target": "\(targetVersion) (\(targetBuild))",
            "releaseDate": item.date?.description ?? "unknown",
            "downloadURL": item.fileURL?.absoluteString ?? "unknown"
        ])

        Task { @MainActor in
            stateSink?.sparkleDidFindUpdate(version: targetVersion, build: targetBuild)
        }
    }

    func updaterDidNotFindUpdate(_ updater: SPUUpdater, error: Error) {
        let currentVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"

        var fields: [String: any Sendable] = [
            "currentVersion": currentVersion,
            "error": error.localizedDescription
        ]
        if let nsError = error as NSError?,
           let latestItem = nsError.userInfo[SPULatestAppcastItemFoundKey] as? SUAppcastItem {
            fields["latestAvailable"] = latestItem.displayVersionString
        }
        DeskJigLog.info(.app, "Sparkle no update found", fields: fields)

        Task { @MainActor in
            stateSink?.sparkleDidNotFindUpdate()
        }
    }

    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: Error?) {
        let checkType = updateCheckTypeString(updateCheck)

        if let error = error {
            var errorFields: [String: any Sendable] = [
                "checkType": checkType,
                "error": error.localizedDescription
            ]
            if let nsError = error as NSError? {
                errorFields["domain"] = nsError.domain
                errorFields["code"] = nsError.code
                if let underlyingError = nsError.userInfo[NSUnderlyingErrorKey] as? NSError {
                    errorFields["underlyingError"] = underlyingError.localizedDescription
                    errorFields["underlyingDomain"] = underlyingError.domain
                }
            }
            DeskJigLog.error(.app, "Sparkle update cycle finished with error", fields: errorFields)

            let nsError = error as NSError
            if nsError.userInfo[SPUNoUpdateFoundReasonKey] == nil {
                Task { @MainActor in
                    stateSink?.sparkleDidFailUpdateCycle(message: error.localizedDescription)
                }
            }
        } else {
            DeskJigLog.info(.app, "Sparkle update cycle finished successfully", fields: ["checkType": checkType])
        }

        Task { @MainActor in
            stateSink?.sparkleDidFinishUpdateSession()
        }
    }

    // MARK: - Download Events

    func updater(_ updater: SPUUpdater, willDownloadUpdate item: SUAppcastItem, with request: NSMutableURLRequest) {
        DeskJigLog.info(.app, "Sparkle download starting", fields: [
            "version": item.displayVersionString,
            "build": item.versionString,
            "url": request.url?.absoluteString ?? "unknown",
            "fileSize": formatBytes(item.contentLength)
        ])
    }

    func updater(_ updater: SPUUpdater, didDownloadUpdate item: SUAppcastItem) {
        DeskJigLog.info(.app, "Sparkle download completed", fields: ["version": item.displayVersionString, "build": item.versionString])
    }

    func updater(_ updater: SPUUpdater, failedToDownloadUpdate item: SUAppcastItem, error: Error) {
        var dlFields: [String: any Sendable] = [
            "version": item.displayVersionString,
            "build": item.versionString,
            "error": error.localizedDescription
        ]
        if let nsError = error as NSError? {
            dlFields["domain"] = nsError.domain
            dlFields["code"] = nsError.code
        }
        DeskJigLog.error(.app, "Sparkle download failed", fields: dlFields)
    }

    func updater(_ updater: SPUUpdater, userDidCancelDownload item: SUAppcastItem) {
        DeskJigLog.info(.app, "Sparkle user cancelled download", fields: ["version": item.displayVersionString])
    }

    // MARK: - Extraction Events

    func updater(_ updater: SPUUpdater, willExtractUpdate item: SUAppcastItem) {
        DeskJigLog.info(.app, "Sparkle starting extraction", fields: ["version": item.displayVersionString])
    }

    func updater(_ updater: SPUUpdater, didExtractUpdate item: SUAppcastItem) {
        DeskJigLog.info(.app, "Sparkle extraction completed", fields: ["version": item.displayVersionString])
    }

    // MARK: - Installation Events

    func updater(_ updater: SPUUpdater, willInstallUpdate item: SUAppcastItem) {
        DeskJigLog.info(.app, "Sparkle starting installation", fields: ["version": item.displayVersionString, "build": item.versionString])

        Task { @MainActor in
            stateSink?.sparkleWillInstallUpdate(version: item.displayVersionString, build: item.versionString)
        }
    }

    func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        var abortFields: [String: any Sendable] = ["error": error.localizedDescription]
        if let nsError = error as NSError? {
            abortFields["domain"] = nsError.domain
            abortFields["code"] = nsError.code
            if let noUpdateReason = nsError.userInfo["SUNoUpdateFoundReason"] as? Int {
                abortFields["noUpdateReason"] = noUpdateReason
            }
            if let underlyingError = nsError.userInfo[NSUnderlyingErrorKey] as? NSError {
                abortFields["underlyingError"] = underlyingError.localizedDescription
                abortFields["underlyingDomain"] = underlyingError.domain
            }
        }
        DeskJigLog.error(.app, "Sparkle update aborted", fields: abortFields)

        Task { @MainActor in
            stateSink?.sparkleDidFailUpdateCycle(message: error.localizedDescription)
        }
    }

    // MARK: - User Interaction

    func updater(_ updater: SPUUpdater, userDidMake choice: SPUUserUpdateChoice, forUpdate updateItem: SUAppcastItem, state: SPUUserUpdateState) {
        let choiceString = userUpdateChoiceString(choice)
        let stateString = userUpdateStateString(state)

        DeskJigLog.info(.app, "Sparkle user made choice", fields: ["choice": choiceString, "version": updateItem.displayVersionString, "state": stateString])
    }

    // MARK: - Scheduling

    func updater(_ updater: SPUUpdater, willScheduleUpdateCheckAfterDelay delay: TimeInterval) {
        let delayMinutes = Int(delay / 60)
        DeskJigLog.info(.app, "Sparkle next auto check scheduled", fields: ["delayMinutes": delayMinutes])
    }

    func updaterWillNotScheduleUpdateCheck(_ updater: SPUUpdater) {
        DeskJigLog.info(.app, "Sparkle automatic update checks will not be scheduled")
    }

    // MARK: - Helper Methods

    private func updateCheckTypeString(_ updateCheck: SPUUpdateCheck) -> String {
        switch updateCheck {
        case .updates:
            return "updates"
        case .updatesInBackground:
            return "background"
        case .updateInformation:
            return "information"
        @unknown default:
            return "unknown"
        }
    }

    private func userUpdateChoiceString(_ choice: SPUUserUpdateChoice) -> String {
        switch choice {
        case .install:
            return "install"
        case .skip:
            return "skip"
        case .dismiss:
            return "dismiss"
        @unknown default:
            return "unknown"
        }
    }

    private func userUpdateStateString(_ state: SPUUserUpdateState) -> String {
        if state.userInitiated {
            return "user-initiated"
        } else {
            return "automatic"
        }
    }

    private func formatBytes(_ bytes: UInt64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: Int64(bytes))
    }
}
