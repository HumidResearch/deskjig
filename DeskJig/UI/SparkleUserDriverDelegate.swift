//  SparkleUserDriverDelegate.swift
//  DeskJig
//
//  Provides comprehensive logging for Sparkle user driver interactions.

import Foundation
import Sparkle
import DeskJigShared

/// Delegate for Sparkle user driver that logs all user interaction events
/// This captures when updates are shown to users and how they interact with update dialogs
final class SparkleUserDriverDelegate: NSObject, SPUStandardUserDriverDelegate {
    weak var stateSink: SparkleUpdateStateSink?

    // MARK: - Initialization

    override init() {
        super.init()
        DeskJigLog.info(.app, "SparkleUserDriverDelegate initialized")
    }

    // MARK: - Update Presentation

    func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool, forUpdate updateItem: SUAppcastItem, state: SPUUserUpdateState) {
        let handler = handleShowingUpdate ? "standard driver" : "custom delegate"
        let initiator = state.userInitiated ? "user-initiated" : "automatic"

        DeskJigLog.info(.app, "Sparkle UI update will be shown to user", fields: [
            "version": updateItem.displayVersionString,
            "build": updateItem.versionString,
            "handler": handler,
            "checkType": initiator,
            "stage": updateStageString(state.stage)
        ])

        Task { @MainActor in
            stateSink?.sparkleDidFindUpdate(version: updateItem.displayVersionString, build: updateItem.versionString)
        }
    }

    func standardUserDriverDidReceiveUserAttention(forUpdate updateItem: SUAppcastItem) {
        DeskJigLog.info(.app, "Sparkle UI update received user attention", fields: ["version": updateItem.displayVersionString])
    }

    func standardUserDriverWillFinishUpdateSession() {
        DeskJigLog.info(.app, "Sparkle UI update session finishing")

        Task { @MainActor in
            stateSink?.sparkleDidFinishUpdateSession()
        }
    }

    func standardUserDriverShouldHandleShowingScheduledUpdate(_ updateItem: SUAppcastItem, andInImmediateFocus immediateFocus: Bool) -> Bool {
        DeskJigLog.info(.app, "Sparkle UI scheduled update ready to show", fields: [
            "version": updateItem.displayVersionString,
            "immediateFocus": immediateFocus
        ])

        // Return false to let the standard driver handle showing the update
        return false
    }

    // MARK: - Helper Methods

    private func updateStageString(_ stage: SPUUserUpdateStage) -> String {
        switch stage {
        case .notDownloaded:
            return "not_downloaded"
        case .downloaded:
            return "downloaded"
        case .installing:
            return "installing"
        @unknown default:
            return "unknown"
        }
    }
}
