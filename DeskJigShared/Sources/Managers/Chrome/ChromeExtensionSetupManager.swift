//  ChromeExtensionSetupManager.swift
//  DeskJigShared

import Foundation

/// Overall setup status for Chrome extension integration
public enum ChromeExtensionSetupStatus: Equatable {
    /// Everything is configured and working
    case complete
    /// Extension is connected but native host not registered (unusual state)
    case needsNativeHostRegistration
    /// Native host registered but extension not connected
    case needsExtensionInstall
    /// Neither configured - full setup required
    case needsFullSetup
    /// No Chromium-based browser installed
    case noBrowserInstalled
    /// Extension is connected but its native-messaging protocol version skews
    /// from the app's (mismatched handshake, or a legacy extension that never
    /// sent one) — the extension or the app needs an update (#542)
    case versionSkew
}

/// Status of native host registration for a specific browser
public enum NativeHostStatus: Equatable {
    case notRegistered
    case registeredButWrongPath(currentPath: String, expectedPath: String)
    case registeredButWrongExtensionId(currentIds: [String])
    case registeredButInvalid(reason: String)
    /// Manifest path matches the expected string, but no executable exists at that path
    /// (e.g. dev builds missing DeskJigNativeHost, or a stale App Translocation path).
    case registeredButBinaryMissing(path: String)
    case registered
}

/// Errors that can occur during setup
public enum ChromeExtensionSetupError: Error, LocalizedError {
    case noBrowserInstalled
    case failedToCreateDirectory(path: String, error: Error)
    case failedToWriteManifest(path: String, error: Error)
    case manifestEncodingFailed
    case browserNotInstalled(browser: ChromeBrowser)

    public var errorDescription: String? {
        switch self {
        case .noBrowserInstalled:
            return "No supported browser is installed"
        case .failedToCreateDirectory(let path, let error):
            return "Failed to create directory at \(path): \(error.localizedDescription)"
        case .failedToWriteManifest(let path, let error):
            return "Failed to write manifest to \(path): \(error.localizedDescription)"
        case .manifestEncodingFailed:
            return "Failed to encode native host manifest"
        case .browserNotInstalled(let browser):
            return "\(browser.rawValue) is not installed"
        }
    }
}

/// Manager for Chrome extension setup and detection
public final class ChromeExtensionSetupManager: @unchecked Sendable {

    /// Shared instance
    public static let shared = ChromeExtensionSetupManager()

    private init() {}

    // MARK: - Detection

    /// Check the overall setup status
    /// - Parameter messagingService: Optional native messaging service to check connection
    /// - Returns: Current setup status
    public func checkSetupStatus(messagingService: ChromeNativeMessagingServiceProtocol? = nil) -> ChromeExtensionSetupStatus {
        // Check if any browser is installed
        let installedBrowsers = ChromeBrowser.installedBrowsers
        guard !installedBrowsers.isEmpty else {
            return .noBrowserInstalled
        }

        // Check native host registration for at least one browser
        let hostStatuses = installedBrowsers.map { checkNativeHostStatus(for: $0) }

        // Check extension connection
        let isConnected = messagingService?.isConnected ?? false

        return setupStatus(
            hostStatuses: hostStatuses,
            isConnected: isConnected,
            handshakeState: messagingService?.status.handshakeState
        )
    }

    /// Map per-browser host statuses plus the connection state to an overall setup status.
    /// Split out from `checkSetupStatus(messagingService:)` so tests can exercise the
    /// mapping without depending on the machine's installed browsers or real manifests.
    func setupStatus(
        hostStatuses: [NativeHostStatus],
        isConnected: Bool,
        handshakeState: ChromeExtensionHandshakeState? = nil
    ) -> ChromeExtensionSetupStatus {
        let hasRegisteredHost = hostStatuses.contains(.registered)
        let hasBinaryMissingHost = hostStatuses.contains { status in
            if case .registeredButBinaryMissing = status { return true }
            return false
        }

        // A connected extension whose protocol version skews from the app's
        // (or a legacy extension that never handshakes) must not report
        // `.complete` — surface the skew so the user knows to update (#542).
        if isConnected, let handshakeState, handshakeState.isVersionSkewed {
            return .versionSkew
        }

        // Determine overall status
        switch (hasRegisteredHost, isConnected) {
        case (true, true):
            return .complete
        case (true, false):
            return .needsExtensionInstall
        case (false, true):
            // Extension connected but no host registered - unusual, maybe manual setup
            return .needsNativeHostRegistration
        case (false, false):
            // A manifest that points at a missing binary needs re-registration,
            // not a from-scratch setup.
            return hasBinaryMissingHost ? .needsNativeHostRegistration : .needsFullSetup
        }
    }

    /// Check native host registration status for a specific browser
    /// - Parameter browser: The browser to check
    /// - Returns: Registration status
    public func checkNativeHostStatus(for browser: ChromeBrowser) -> NativeHostStatus {
        checkNativeHostStatus(
            manifestPath: ChromeExtensionConstants.nativeHostManifestPath(for: browser),
            expectedBinaryPath: ChromeExtensionConstants.nativeHostBinaryPath
        )
    }

    /// Check native host registration status against explicit paths.
    /// Split out from `checkNativeHostStatus(for:)` so tests can point it at
    /// temp manifest/binary locations instead of the real Chrome directories.
    /// - Parameters:
    ///   - manifestPath: Path to the native messaging host manifest JSON
    ///   - expectedBinaryPath: Path where the native host binary is expected to live
    /// - Returns: Registration status
    func checkNativeHostStatus(manifestPath: String, expectedBinaryPath: String) -> NativeHostStatus {
        // Check if manifest exists
        guard FileManager.default.fileExists(atPath: manifestPath) else {
            return .notRegistered
        }

        // Read and parse manifest
        guard let data = FileManager.default.contents(atPath: manifestPath),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .registeredButInvalid(reason: "Cannot read or parse manifest file")
        }

        // Validate path
        guard let path = json["path"] as? String else {
            return .registeredButInvalid(reason: "Missing 'path' field")
        }

        if path != expectedBinaryPath {
            return .registeredButWrongPath(currentPath: path, expectedPath: expectedBinaryPath)
        }

        // Validate that the referenced binary actually exists and is executable.
        // A string-matching manifest is worthless if Chrome can't launch the host
        // (e.g. dev builds without DeskJigNativeHost, or a manifest re-registered from
        // an ephemeral App Translocation path that has since vanished).
        if !FileManager.default.isExecutableFile(atPath: path) {
            DeskJigLog.warn(.chrome, "ChromeExtensionSetup: Native host manifest points at a missing or non-executable binary", fields: ["path": path])
            if path.contains("/AppTranslocation/") {
                DeskJigLog.warn(
                    .chrome,
                    "ChromeExtensionSetup: Native host path is inside an App Translocation directory; re-registration from a stable install location is required",
                    fields: ["path": path]
                )
            }
            return .registeredButBinaryMissing(path: path)
        }

        // Validate allowed_origins
        guard let origins = json["allowed_origins"] as? [String] else {
            return .registeredButInvalid(reason: "Missing 'allowed_origins' field")
        }

        let expectedOrigin = "chrome-extension://\(ChromeExtensionConstants.extensionId)/"
        if !origins.contains(expectedOrigin) {
            // Extract extension IDs from origins
            let currentIds = origins.compactMap { origin -> String? in
                guard origin.hasPrefix("chrome-extension://"),
                      origin.hasSuffix("/") else { return nil }
                let start = origin.index(origin.startIndex, offsetBy: 19)
                let end = origin.index(origin.endIndex, offsetBy: -1)
                return String(origin[start..<end])
            }
            return .registeredButWrongExtensionId(currentIds: currentIds)
        }

        return .registered
    }

    // MARK: - Registration

    /// Register the native host for a browser
    /// - Parameter browser: The browser to register for
    /// - Throws: ChromeExtensionSetupError if registration fails
    public func registerNativeHost(for browser: ChromeBrowser) throws {
        guard browser.isInstalled else {
            throw ChromeExtensionSetupError.browserNotInstalled(browser: browser)
        }

        let hostsDir = ChromeExtensionConstants.nativeMessagingHostsDirectory(for: browser)
        let manifestPath = ChromeExtensionConstants.nativeHostManifestPath(for: browser)

        // Create directory if needed
        if !FileManager.default.fileExists(atPath: hostsDir) {
            do {
                try FileManager.default.createDirectory(atPath: hostsDir, withIntermediateDirectories: true)
                DeskJigLog.info(.chrome, "ChromeExtensionSetup: Created native messaging hosts directory: \(hostsDir)")
            } catch {
                throw ChromeExtensionSetupError.failedToCreateDirectory(path: hostsDir, error: error)
            }
        }

        // Generate manifest
        let manifest = generateNativeHostManifest()

        guard let manifestData = try? JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys]) else {
            throw ChromeExtensionSetupError.manifestEncodingFailed
        }

        // Write manifest
        do {
            try manifestData.write(to: URL(fileURLWithPath: manifestPath))
            DeskJigLog.info(.chrome, "ChromeExtensionSetup: Registered native host at: \(manifestPath)")
        } catch {
            throw ChromeExtensionSetupError.failedToWriteManifest(path: manifestPath, error: error)
        }
    }

    /// Register native host for all installed browsers
    /// - Returns: Results for each browser (browser -> success/error)
    @discardableResult
    public func registerNativeHostForAllBrowsers() -> [ChromeBrowser: Result<Void, ChromeExtensionSetupError>] {
        var results: [ChromeBrowser: Result<Void, ChromeExtensionSetupError>] = [:]

        for browser in ChromeBrowser.installedBrowsers {
            do {
                try registerNativeHost(for: browser)
                results[browser] = .success(())
            } catch let error as ChromeExtensionSetupError {
                results[browser] = .failure(error)
            } catch {
                results[browser] = .failure(.failedToWriteManifest(
                    path: ChromeExtensionConstants.nativeHostManifestPath(for: browser),
                    error: error
                ))
            }
        }

        return results
    }

    /// Unregister native host for a browser
    /// - Parameter browser: The browser to unregister from
    public func unregisterNativeHost(for browser: ChromeBrowser) {
        let manifestPath = ChromeExtensionConstants.nativeHostManifestPath(for: browser)
        try? FileManager.default.removeItem(atPath: manifestPath)
        DeskJigLog.info(.chrome, "ChromeExtensionSetup: Unregistered native host for \(browser.rawValue)")
    }

    // MARK: - Helpers

    /// Generate the native host manifest dictionary
    private func generateNativeHostManifest() -> [String: Any] {
        [
            "name": ChromeExtensionConstants.nativeHostName,
            "description": "DeskJig Native Messaging Host - Connects Chrome to DeskJig.app for window management",
            "path": ChromeExtensionConstants.nativeHostBinaryPath,
            "type": "stdio",
            "allowed_origins": [
                "chrome-extension://\(ChromeExtensionConstants.extensionId)/"
            ]
        ]
    }

    /// Update the development extension ID and re-register
    /// - Parameter extensionId: New extension ID
    public func updateDevelopmentExtensionId(_ extensionId: String) {
        ChromeExtensionConstants.developmentExtensionId = extensionId
        // Re-register for all browsers
        registerNativeHostForAllBrowsers()
        DeskJigLog.info(.chrome, "ChromeExtensionSetup: Updated development extension ID to: \(extensionId)")
    }

    /// Get human-readable summary of setup status
    public func statusSummary(messagingService: ChromeNativeMessagingServiceProtocol? = nil) -> String {
        let status = checkSetupStatus(messagingService: messagingService)
        let installedBrowsers = ChromeBrowser.installedBrowsers

        var lines: [String] = []
        lines.append("Chrome Extension Setup Status")
        lines.append("  Overall: \(statusDescription(status))")
        lines.append("  Installed Browsers: \(installedBrowsers.map { $0.rawValue }.joined(separator: ", "))")

        for browser in installedBrowsers {
            let hostStatus = checkNativeHostStatus(for: browser)
            lines.append("  \(browser.rawValue): \(hostStatusDescription(hostStatus))")
        }

        if let service = messagingService {
            lines.append("  Extension Connected: \(service.isConnected)")
            let status = service.status
            if let version = status.extensionVersion {
                let protocolVersion = status.protocolVersion.map(String.init) ?? "?"
                lines.append("  Extension Version: \(version) (protocol v\(protocolVersion))")
            }
            lines.append("  Handshake: \(handshakeStateDescription(status.handshakeState))")
        }

        return lines.joined(separator: "\n")
    }

    private func statusDescription(_ status: ChromeExtensionSetupStatus) -> String {
        switch status {
        case .complete: return "Complete"
        case .needsNativeHostRegistration: return "Needs Native Host Registration"
        case .needsExtensionInstall: return "Needs Extension Install"
        case .needsFullSetup: return "Needs Full Setup"
        case .noBrowserInstalled: return "No Browser Installed"
        case .versionSkew: return "Version Skew (extension/app update needed)"
        }
    }

    private func handshakeStateDescription(_ state: ChromeExtensionHandshakeState) -> String {
        switch state {
        case .awaitingHandshake: return "Awaiting Handshake"
        case .compatible: return "Compatible"
        case .protocolMismatch(let extensionVersion, let appVersion):
            return "Protocol Mismatch (extension v\(extensionVersion), app v\(appVersion))"
        case .legacyPeer: return "Legacy Extension (no handshake support)"
        }
    }

    private func hostStatusDescription(_ status: NativeHostStatus) -> String {
        switch status {
        case .notRegistered: return "Not Registered"
        case .registered: return "Registered"
        case .registeredButWrongPath(let current, _): return "Wrong Path: \(current)"
        case .registeredButWrongExtensionId(let ids): return "Wrong Extension ID: \(ids.joined(separator: ", "))"
        case .registeredButInvalid(let reason): return "Invalid: \(reason)"
        case .registeredButBinaryMissing(let path): return "Binary Missing: \(path)"
        }
    }
}
