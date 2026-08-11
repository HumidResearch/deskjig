//  ChromeExtensionStatusService.swift
//  DeskJigShared

import Foundation

/// Service for checking Chrome extension status and per-profile connectivity
public final class ChromeExtensionStatusService: Sendable {

    /// Extension status including global connection and per-profile connectivity
    public struct ExtensionStatus: Sendable {
        /// Whether the native messaging service is connected (any profile)
        public let isConnected: Bool
        /// Detailed connection status from the native messaging service
        public let connectionStatus: ChromeNativeMessagingStatus?
        /// Profile names that have accessible windows via native messaging
        public let connectedProfiles: [String]
        /// Total number of Chrome windows accessible via native messaging
        public let windowCount: Int

        public init(
            isConnected: Bool,
            connectionStatus: ChromeNativeMessagingStatus?,
            connectedProfiles: [String],
            windowCount: Int
        ) {
            self.isConnected = isConnected
            self.connectionStatus = connectionStatus
            self.connectedProfiles = connectedProfiles
            self.windowCount = windowCount
        }
    }

    /// Get current extension status including per-profile connectivity
    /// - Returns: ExtensionStatus with global connection state and per-profile info
    public static func getStatus() async -> ExtensionStatus {
        guard let service = ChromeNativeMessagingServiceHolder.shared else {
            return ExtensionStatus(
                isConnected: false,
                connectionStatus: nil,
                connectedProfiles: [],
                windowCount: 0
            )
        }

        let status = service.status
        let connectedProfiles: [String] = []
        var windowCount = 0

        if service.isConnected {
            // Query windows to get window count
            // Note: Native messaging doesn't report profile info directly.
            // The extension runs in the context of a profile, but chrome.windows API
            // returns ALL windows across all profiles. Profile detection requires
            // AX window title parsing (e.g., "PageTitle - Google Chrome - ProfileName").
            do {
                let api = ChromeNativeMessagingAPI(service: service)
                let windows = try await api.allWindows()
                windowCount = windows.count
                // Per-profile connectivity cannot be determined from native messaging alone
                // Leave connectedProfiles empty - use AX title parsing for profile detection
            } catch {
                // Connection exists but query failed - leave window count at 0
            }
        }

        return ExtensionStatus(
            isConnected: service.isConnected,
            connectionStatus: status,
            connectedProfiles: connectedProfiles,
            windowCount: windowCount
        )
    }

    /// Check if native messaging is available for Chrome operations
    /// Note: Native messaging is profile-agnostic - when connected, it can access
    /// windows from ALL profiles. Per-profile extension installation detection
    /// is not possible through native messaging.
    /// - Parameter profileDisplayName: Ignored - native messaging works across all profiles
    /// - Returns: True if native messaging is connected (regardless of profile)
    public static func isProfileConnected(_ profileDisplayName: String) async -> Bool {
        let status = await getStatus()
        return status.isConnected
    }

    /// Format extension status for logging
    /// - Parameter status: The extension status to format
    /// - Returns: A dictionary suitable for logging
    public static func formatForLogging(_ status: ExtensionStatus) -> [String: String] {
        return [
            "globalConnected": "\(status.isConnected)",
            "connectionStatus": status.connectionStatus.map { "\($0)" } ?? "nil",
            "connectedProfiles": status.connectedProfiles.isEmpty ? "none" : status.connectedProfiles.joined(separator: ", "),
            "windowCount": "\(status.windowCount)"
        ]
    }
}
