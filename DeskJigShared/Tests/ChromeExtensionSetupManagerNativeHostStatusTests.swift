//  ChromeExtensionSetupManagerNativeHostStatusTests.swift
//  DeskJigSharedTests

import Foundation
import Testing
@testable import DeskJigShared

// Gated: exercises ChromeExtensionSetupManager.shared against real native-host
// manifest locations on the host. Absent from the Headless whitelist.
@Suite(.enabled(if: TestEnvironment.envTestsEnabled, TestEnvironment.gateReason))
struct ChromeExtensionSetupManagerNativeHostStatusTests {

    private let manager = ChromeExtensionSetupManager.shared

    /// Create a temp directory, run the body, and clean up afterwards.
    private func withTempDirectory<T>(_ body: (String) throws -> T) throws -> T {
        let dir = NSTemporaryDirectory() + "chrome-setup-tests-\(UUID().uuidString.prefix(8))"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        return try body(dir)
    }

    /// Write a native host manifest JSON pointing at `binaryPath`.
    private func writeManifest(in directory: String, binaryPath: String) throws -> String {
        let manifest: [String: Any] = [
            "name": ChromeExtensionConstants.nativeHostName,
            "description": "Test manifest",
            "path": binaryPath,
            "type": "stdio",
            "allowed_origins": [
                "chrome-extension://\(ChromeExtensionConstants.extensionId)/"
            ]
        ]
        let manifestPath = directory + "/\(ChromeExtensionConstants.nativeHostName).json"
        let data = try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: URL(fileURLWithPath: manifestPath))
        return manifestPath
    }

    // MARK: - checkNativeHostStatus

    @Test("Manifest path string matches but binary is missing -> .registeredButBinaryMissing")
    func matchingPathWithMissingBinaryIsNotRegistered() throws {
        try withTempDirectory { dir in
            let binaryPath = dir + "/DeskJig.app/Contents/MacOS/DeskJigNativeHost" // never created
            let manifestPath = try writeManifest(in: dir, binaryPath: binaryPath)

            let status = manager.checkNativeHostStatus(manifestPath: manifestPath, expectedBinaryPath: binaryPath)

            #expect(status == .registeredButBinaryMissing(path: binaryPath))
            #expect(status != .registered)
        }
    }

    @Test("Manifest path string matches and binary exists and is executable -> .registered")
    func matchingPathWithRealExecutableIsRegistered() throws {
        try withTempDirectory { dir in
            let binaryPath = dir + "/DeskJigNativeHost"
            FileManager.default.createFile(
                atPath: binaryPath,
                contents: Data("#!/bin/sh\nexit 0\n".utf8),
                attributes: [.posixPermissions: 0o755]
            )
            let manifestPath = try writeManifest(in: dir, binaryPath: binaryPath)

            let status = manager.checkNativeHostStatus(manifestPath: manifestPath, expectedBinaryPath: binaryPath)

            #expect(status == .registered)
        }
    }

    @Test("Binary present but not executable -> .registeredButBinaryMissing")
    func matchingPathWithNonExecutableFileIsBinaryMissing() throws {
        try withTempDirectory { dir in
            let binaryPath = dir + "/DeskJigNativeHost"
            FileManager.default.createFile(
                atPath: binaryPath,
                contents: Data("not a binary".utf8),
                attributes: [.posixPermissions: 0o644]
            )
            let manifestPath = try writeManifest(in: dir, binaryPath: binaryPath)

            let status = manager.checkNativeHostStatus(manifestPath: manifestPath, expectedBinaryPath: binaryPath)

            #expect(status == .registeredButBinaryMissing(path: binaryPath))
        }
    }

    @Test("Wrong path string still reported as .registeredButWrongPath before any binary check")
    func wrongPathStillWinsOverBinaryCheck() throws {
        try withTempDirectory { dir in
            let manifestPath = try writeManifest(in: dir, binaryPath: dir + "/elsewhere/DeskJigNativeHost")
            let expected = dir + "/DeskJigNativeHost"

            let status = manager.checkNativeHostStatus(manifestPath: manifestPath, expectedBinaryPath: expected)

            #expect(status == .registeredButWrongPath(currentPath: dir + "/elsewhere/DeskJigNativeHost", expectedPath: expected))
        }
    }

    @Test("Missing manifest -> .notRegistered")
    func missingManifestIsNotRegistered() throws {
        try withTempDirectory { dir in
            let status = manager.checkNativeHostStatus(
                manifestPath: dir + "/does-not-exist.json",
                expectedBinaryPath: dir + "/DeskJigNativeHost"
            )
            #expect(status == .notRegistered)
        }
    }

    // MARK: - setupStatus mapping

    @Test("Missing binary routes to re-registration, never .complete/.needsExtensionInstall")
    func setupStatusRoutesMissingBinaryToReregistration() {
        let missing = NativeHostStatus.registeredButBinaryMissing(path: "/gone/DeskJigNativeHost")

        // Not connected: previously (pre-#520) this state string-matched to .registered
        // and produced .needsExtensionInstall - the wrong fix for the user.
        #expect(manager.setupStatus(hostStatuses: [missing], isConnected: false) == .needsNativeHostRegistration)

        // Connected (edge case): still needs host re-registration, not .complete.
        #expect(manager.setupStatus(hostStatuses: [missing], isConnected: true) == .needsNativeHostRegistration)
    }

    @Test("Healthy registration mapping is unchanged")
    func setupStatusHealthyMappingUnchanged() {
        #expect(manager.setupStatus(hostStatuses: [.registered], isConnected: true) == .complete)
        #expect(manager.setupStatus(hostStatuses: [.registered], isConnected: false) == .needsExtensionInstall)
        #expect(manager.setupStatus(hostStatuses: [.notRegistered], isConnected: false) == .needsFullSetup)
        #expect(manager.setupStatus(hostStatuses: [.notRegistered], isConnected: true) == .needsNativeHostRegistration)
    }
}
