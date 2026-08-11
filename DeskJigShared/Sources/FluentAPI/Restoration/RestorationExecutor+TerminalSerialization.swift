//  RestorationExecutor+TerminalSerialization.swift
//  DeskJigShared

import Foundation
import CoreGraphics
import AppKit

extension RestorationExecutor {

    // MARK: - Terminal.app Serialization

    /// Acquires the Terminal.app launch semaphore if `bundleId` is Terminal.app.
    /// Returns whether the semaphore was acquired (caller must signal on release).
    func acquireTerminalSerializationIfNeeded(bundleId: String) async -> Bool {
        guard bundleId == BundleRegistry.terminal else { return false }
        await terminalAppLaunchSemaphore.wait()
        return true
    }

    /// Releases the Terminal.app launch semaphore. Call only when
    /// `acquireTerminalSerializationIfNeeded` returned `true`.
    func releaseTerminalSerialization() {
        Task { [terminalAppLaunchSemaphore] in
            await terminalAppLaunchSemaphore.signal()
        }
    }
}
