//  PermissionsViewModel.swift
//  DeskJig
//
//  Created by Paulo Fierro on 30/9/25.
//

import SwiftUI
import DeskJigShared
import Combine
import ApplicationServices

@MainActor @Observable
final class PermissionsViewModel {
    var isCheckingPermissions = false
    var hasPermissionsLocally = false
    private var pollingCancellable: AnyCancellable?
    private var permissionCheckTimer: Timer?
}

// MARK: - Permission Functions

extension PermissionsViewModel {

    func requestPermission(using windowManager: WindowManager) {
        DeskJigLog.info(.permissions, "Requesting permissions")
        isCheckingPermissions = true
        windowManager.requestAccessibilityPermissions()
        checkPermissions(using: windowManager)
    }

    func checkPermissions(using windowManager: WindowManager) {
        DeskJigLog.info(.permissions, "Checking permissions")
        isCheckingPermissions = true

        MainActor.async(after: .seconds(0.5)) {
            windowManager.checkAccessibilityPermissions()
            DeskJigLog.info(.permissions, "Has permissions: \(windowManager.hasAccessibilityPermissions.description)")
            self.isCheckingPermissions = false
        }
    }

    func startPolling(using windowManager: WindowManager) {
        DeskJigLog.info(.permissions, "Starting permission polling")

        // Poll every 0.5 seconds
        pollingCancellable = Timer.publish(every: 0.5, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                guard let self = self else { return }

                // Check permission status locally without updating WindowManager
                // This prevents automatic advancement
                let isTrusted = AXIsProcessTrusted()
                self.hasPermissionsLocally = isTrusted

                // Stop polling if permissions are granted
                if isTrusted {
                    DeskJigLog.info(.permissions, "Permissions granted (locally detected), stopping polling")
                    self.stopPolling()
                }
            }
    }

    func advanceAfterPermissionGranted(using windowManager: WindowManager) {
        DeskJigLog.info(.permissions, "User clicked Next, updating WindowManager to advance")
        DeskJigLog.info(.permissions, "Permissions set - [accessibility: true]")

        windowManager.checkAccessibilityPermissions()
    }

    func stopPolling() {
        DeskJigLog.info(.permissions, "Stopping permission polling")
        pollingCancellable?.cancel()
        pollingCancellable = nil
    }
}
