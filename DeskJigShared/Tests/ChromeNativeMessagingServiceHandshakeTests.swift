//  ChromeNativeMessagingServiceHandshakeTests.swift
//  DeskJigSharedTests

import XCTest
@testable import DeskJigShared

final class ChromeNativeMessagingServiceHandshakeTests: XCTestCase {

    private var socketPath: String!

    override func setUp() {
        super.setUp()
        socketPath = NSTemporaryDirectory() + "cnms-handshake-tests-\(UUID().uuidString.prefix(8)).sock"
    }

    override func tearDown() {
        try? FileManager.default.removeItem(atPath: socketPath)
        super.tearDown()
    }

    // MARK: - Helpers

    /// Poll a condition without blocking the cooperative pool; generous timeout.
    private func waitFor(
        _ what: String,
        timeout: TimeInterval = 5.0,
        _ condition: @escaping () -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        return condition()
    }

    /// Raw unix-domain client speaking the length-prefixed framing.
    private final class RawClient: @unchecked Sendable {
        let fd: Int32

        init?(path: String) {
            fd = socket(AF_UNIX, SOCK_STREAM, 0)
            guard fd >= 0 else { return nil }
            var addr = sockaddr_un()
            addr.sun_family = sa_family_t(AF_UNIX)
            let bytes = path.utf8CString
            guard bytes.count <= MemoryLayout.size(ofValue: addr.sun_path) else {
                close(fd)
                return nil
            }
            withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
                ptr.withMemoryRebound(to: CChar.self, capacity: bytes.count) { dest in
                    for (index, byte) in bytes.enumerated() {
                        dest[index] = byte
                    }
                }
            }
            let result = withUnsafePointer(to: &addr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                    connect(fd, sockPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            guard result >= 0 else {
                close(fd)
                return nil
            }
        }

        func sendFramed(_ data: Data) -> Bool {
            var length = UInt32(data.count).littleEndian
            guard withUnsafeBytes(of: &length, { writeAll($0) }) else { return false }
            return data.withUnsafeBytes { writeAll($0) }
        }

        private func writeAll(_ buffer: UnsafeRawBufferPointer) -> Bool {
            var offset = 0
            while offset < buffer.count {
                let written = send(
                    fd,
                    buffer.baseAddress?.advanced(by: offset),
                    buffer.count - offset,
                    0
                )
                if written > 0 {
                    offset += written
                } else if written < 0 && errno == EINTR {
                    continue
                } else {
                    return false
                }
            }
            return true
        }

        func closeNow() {
            close(fd)
        }
    }

    /// Frame and send a JSON message the way background.js does.
    @discardableResult
    private func sendJSON(_ client: RawClient, _ message: [String: Any]) -> Bool {
        guard let data = try? JSONSerialization.data(withJSONObject: message) else { return false }
        return client.sendFramed(data)
    }

    private func handshakeMessage(
        type: String = "handshake",
        protocolVersion: Int,
        extensionVersion: String = "9.9.9",
        extensionId: String? = "test-extension-id"
    ) -> [String: Any] {
        var payload: [String: Any] = [
            "protocolVersion": protocolVersion,
            "extensionVersion": extensionVersion
        ]
        if let extensionId = extensionId {
            payload["extensionId"] = extensionId
        }
        let payloadString = String(
            data: (try? JSONSerialization.data(withJSONObject: payload)) ?? Data(),
            encoding: .utf8
        ) ?? "{}"
        return [
            "type": type,
            "payload": payloadString
        ]
    }

    // MARK: - Tests

    /// AC3 (#542): a connected client whose handshake carries a mismatched
    /// protocolVersion must surface the skew — the status exposes
    /// .protocolMismatch and the setup-status mapping reports .versionSkew,
    /// never a silent .complete/connected-and-healthy.
    func testMismatchedProtocolVersionHandshakeExposesSkew() async throws {
        let service = ChromeNativeMessagingService(socketPath: socketPath)
        try service.start()
        defer { service.stop() }

        guard let client = RawClient(path: socketPath) else {
            return XCTFail("client failed to connect")
        }
        defer { client.closeNow() }
        let connected = await waitFor("client connected") { service.isConnected }
        XCTAssertTrue(connected)

        let mismatchedVersion = ChromeNativeMessagingProtocol.version + 999
        XCTAssertTrue(sendJSON(client, handshakeMessage(protocolVersion: mismatchedVersion)))

        let skewed = await waitFor("handshake recorded as mismatch") {
            service.status.handshakeState.isVersionSkewed
        }
        XCTAssertTrue(skewed, "mismatched handshake must surface as version skew")

        let status = service.status
        XCTAssertTrue(status.isConnected)
        XCTAssertEqual(
            status.handshakeState,
            .protocolMismatch(
                extensionProtocolVersion: mismatchedVersion,
                appProtocolVersion: ChromeNativeMessagingProtocol.version
            )
        )
        XCTAssertEqual(status.extensionVersion, "9.9.9")
        XCTAssertEqual(status.protocolVersion, mismatchedVersion)
        XCTAssertEqual(status.extensionId, "test-extension-id")

        // The setup-status surface must report the skew, not .complete.
        let setupStatus = ChromeExtensionSetupManager.shared.setupStatus(
            hostStatuses: [.registered],
            isConnected: service.isConnected,
            handshakeState: status.handshakeState
        )
        XCTAssertEqual(setupStatus, .versionSkew)
        XCTAssertNotEqual(setupStatus, .complete)
    }

    /// A matching handshake records the extension version/ID and keeps the
    /// setup status .complete.
    func testMatchingHandshakeRecordsExtensionVersion() async throws {
        let service = ChromeNativeMessagingService(socketPath: socketPath)
        try service.start()
        defer { service.stop() }

        guard let client = RawClient(path: socketPath) else {
            return XCTFail("client failed to connect")
        }
        defer { client.closeNow() }
        let connected = await waitFor("client connected") { service.isConnected }
        XCTAssertTrue(connected)

        XCTAssertTrue(sendJSON(client, handshakeMessage(
            protocolVersion: ChromeNativeMessagingProtocol.version,
            extensionVersion: "1.1.0"
        )))

        let compatible = await waitFor("handshake recorded as compatible") {
            service.status.handshakeState == .compatible
        }
        XCTAssertTrue(compatible)

        let status = service.status
        XCTAssertEqual(status.extensionVersion, "1.1.0")
        XCTAssertEqual(status.protocolVersion, ChromeNativeMessagingProtocol.version)
        XCTAssertEqual(status.extensionId, "test-extension-id")

        let setupStatus = ChromeExtensionSetupManager.shared.setupStatus(
            hostStatuses: [.registered],
            isConnected: service.isConnected,
            handshakeState: status.handshakeState
        )
        XCTAssertEqual(setupStatus, .complete)
    }

    /// A handshake echoed inside a heartbeat payload (the reconnect path:
    /// DeskJig.app started after Chrome, so the connect-time handshake was
    /// missed) must be recorded exactly like a dedicated handshake message.
    func testHeartbeatPayloadCarriesHandshake() async throws {
        let service = ChromeNativeMessagingService(socketPath: socketPath)
        try service.start()
        defer { service.stop() }

        guard let client = RawClient(path: socketPath) else {
            return XCTFail("client failed to connect")
        }
        defer { client.closeNow() }
        let connected = await waitFor("client connected") { service.isConnected }
        XCTAssertTrue(connected)

        XCTAssertTrue(sendJSON(client, handshakeMessage(
            type: "heartbeat",
            protocolVersion: ChromeNativeMessagingProtocol.version,
            extensionVersion: "1.1.0"
        )))

        let compatible = await waitFor("heartbeat handshake recorded") {
            service.status.handshakeState == .compatible
        }
        XCTAssertTrue(compatible)
        XCTAssertEqual(service.status.extensionVersion, "1.1.0")
        XCTAssertNotNil(service.status.lastHeartbeat)
    }

    /// A legacy (pre-handshake) peer that connects and never sends a
    /// handshake must be classified as .legacyPeer once the grace window
    /// elapses — reported as skew, not left in .awaitingHandshake forever.
    func testLegacyPeerClassifiedAfterGraceWindow() async throws {
        let gracePeriod: TimeInterval = 0.5
        let service = ChromeNativeMessagingService(
            socketPath: socketPath,
            handshakeGracePeriod: gracePeriod
        )
        try service.start()
        defer { service.stop() }

        guard let client = RawClient(path: socketPath) else {
            return XCTFail("client failed to connect")
        }
        defer { client.closeNow() }
        let connected = await waitFor("client connected") { service.isConnected }
        XCTAssertTrue(connected)
        XCTAssertEqual(service.status.handshakeState, .awaitingHandshake)

        // Send nothing: after the grace window the peer must be legacy.
        let legacy = await waitFor("legacy classification", timeout: gracePeriod * 6) {
            service.status.handshakeState == .legacyPeer
        }
        XCTAssertTrue(legacy, "peer that never handshakes must be classified as legacy, not left pending")
        XCTAssertTrue(service.status.isConnected, "legacy classification must not drop the connection")
        XCTAssertNil(service.status.extensionVersion)

        let setupStatus = ChromeExtensionSetupManager.shared.setupStatus(
            hostStatuses: [.registered],
            isConnected: service.isConnected,
            handshakeState: service.status.handshakeState
        )
        XCTAssertEqual(setupStatus, .versionSkew)
    }

    /// A handshake that beats the grace window must cancel the legacy
    /// classification: the state stays .compatible after the window elapses.
    func testHandshakeBeforeGraceWindowPreventsLegacyClassification() async throws {
        let gracePeriod: TimeInterval = 0.5
        let service = ChromeNativeMessagingService(
            socketPath: socketPath,
            handshakeGracePeriod: gracePeriod
        )
        try service.start()
        defer { service.stop() }

        guard let client = RawClient(path: socketPath) else {
            return XCTFail("client failed to connect")
        }
        defer { client.closeNow() }
        let connected = await waitFor("client connected") { service.isConnected }
        XCTAssertTrue(connected)

        XCTAssertTrue(sendJSON(client, handshakeMessage(
            protocolVersion: ChromeNativeMessagingProtocol.version,
            extensionVersion: "1.1.0"
        )))
        let compatible = await waitFor("handshake recorded") {
            service.status.handshakeState == .compatible
        }
        XCTAssertTrue(compatible)

        // Let the grace window elapse; a stale grace task must not demote a
        // handshaken connection to legacy.
        try await Task.sleep(nanoseconds: UInt64(gracePeriod * 3 * 1_000_000_000))
        XCTAssertEqual(service.status.handshakeState, .compatible)
        XCTAssertEqual(service.status.extensionVersion, "1.1.0")
    }
}
