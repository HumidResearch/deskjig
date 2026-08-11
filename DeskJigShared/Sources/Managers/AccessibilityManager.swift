//
//  AccessibilityManager.swift
//  DeskJigShared
//
//  Created by Marco Freedom on 02.09.2025.
//

import Foundation
import ApplicationServices
import Cocoa
import ScreenCaptureKit

public class AccessibilityManager: ObservableObject {
    @Published public var hasAccessibilityPermissions = false
    
    public init() {
        checkAccessibilityPermissions()
    }
    
    /// Opens System Settings to a specific preference pane
    public func openSystemSettings(to page: SettingsPane) {
        guard let url = page.url else {
            DeskJigLog.error(.window, "Failed to open System Settings, URL is invalid.")
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            NSWorkspace.shared.open(url)
        }
    }
}

// MARK: - Accessibility Functions

extension AccessibilityManager {
    
    public func checkAccessibilityPermissions() {
        let isTrusted = AXIsProcessTrusted()
        if isTrusted != hasAccessibilityPermissions {
            hasAccessibilityPermissions = isTrusted
        }
    }
    
    /// Check if accessibility permissions are available. If not, this will prompt for permission.
    public func requestAccessibilityPermissions() {
        // Show native macOS permission dialog
        // On macOS 10.14+, this reliably shows the system dialog prompting the user
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        let accessEnabled = AXIsProcessTrustedWithOptions(options as CFDictionary)
        hasAccessibilityPermissions = accessEnabled
        // Note: Removed automatic System Settings opening - native dialog is sufficient
        // and opening both simultaneously confuses users (see issue #336)
    }
}
