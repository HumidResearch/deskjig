//  ChromeNativeMessagingServiceTimeoutTests.swift
//  DeskJigSharedTests
//
//  Tests for the sendRequest timeout (#518, upstream): a connected client that
//  accepts a request but never replies must fail the await with
//  ChromeNativeMessagingError.timeout instead of parking the continuation
//  forever, and a reply that beats the deadline must win cleanly (no
//  double-resume of the continuation when the timeout window later elapses).
//
//  Uses a real Unix-socket client speaking the length-prefixed framing, like
//  NativeMessagingServerLifecycleTests, so the full send/receive path runs.

import XCTest
@testable import DeskJigShared

final class ChromeNativeMessagingServiceTimeoutTests: XCTestCase {

    private var socketPath: String!

    override func setUpWithError() throws {
        try super.setUpWithError()
        // Gated: real socket I/O with wall-clock timeout assertions — flaky off a
        // quiescent machine. Absent from the Headless whitelist.
        try XCTSkipUnless(TestEnvironment.envTestsEnabled, TestEnvironment.gateReasonText)
        socketPath = NSTemporaryDirectory() + "cnms-timeout-tests-\(UUID().uuidString.prefix(8)).sock"
    }

    override func tearDown() {
        // `socketPath` stays nil when the gate in `setUpWithError()` skips the
        // test before assigning it, so unwrap defensively rather than forcing.
        if let socketPath {
            try? FileManager.default.removeItem(atPath: socketPath)
        }
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

        func recvFramed(maxLength: Int = 1024 * 1024) -> Data? {
            var lengthBytes = [UInt8](repeating: 0, count: 4)
            guard recv(fd, &lengthBytes, 4, MSG_WAITALL) == 4 else { return nil }
            let length = UInt32(lengthBytes[0]) |
                         (UInt32(lengthBytes[1]) << 8) |
                         (UInt32(lengthBytes[2]) << 16) |
                         (UInt32(lengthBytes[3]) << 24)
            guard length <= maxLength else { return nil }
            var body = [UInt8](repeating: 0, count: Int(length))
            guard recv(fd, &body, Int(length), MSG_WAITALL) == Int(length) else { return nil }
            return Data(body)
        }

        func closeNow() {
            close(fd)
        }
    }

    private final class LockedBox<Value>: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Value

        init(_ value: Value) {
            self.value = value
        }

        func withValue<Result>(_ body: (inout Value) -> Result) -> Result {
            lock.lock()
            defer { lock.unlock() }
            return body(&value)
        }
    }

    /// Reads request frames off the client socket and replies to each with a
    /// well-formed `response` message carrying `payloadJSON`, until the socket
    /// closes. Mirrors what DeskJigNativeHost does for a healthy extension.
    private func startResponder(client: RawClient, payloadJSON: String) {
        DispatchQueue.global().async {
            while let frame = client.recvFramed() {
                guard let request = try? JSONSerialization.jsonObject(with: frame) as? [String: Any],
                      let requestId = request["requestId"] as? String else {
                    continue
                }
                let response: [String: Any] = [
                    "type": "response",
                    "requestId": requestId,
                    "payload": payloadJSON
                ]
                guard let responseData = try? JSONSerialization.data(withJSONObject: response),
                      client.sendFramed(responseData) else {
                    return
                }
            }
        }
    }

    // MARK: - Tests

    /// A connected client that accepts the request but never replies: the
    /// await must fail with .timeout within ~2x the configured timeout, not
    /// hang forever. The expectation wait is the hard ceiling.
    func testRequestTimesOutWhenExtensionNeverReplies() async throws {
        let requestTimeout: TimeInterval = 1.0
        let service = ChromeNativeMessagingService(socketPath: socketPath, requestTimeout: requestTimeout)
        try service.start()
        defer { service.stop() }

        guard let client = RawClient(path: socketPath) else {
            return XCTFail("client failed to connect")
        }
        defer { client.closeNow() }
        let connected = await waitFor("client connected") { service.isConnected }
        XCTAssertTrue(connected)

        // Drain the request frame so the send fully succeeds, then go silent.
        DispatchQueue.global().async {
            _ = client.recvFramed()
        }

        let completed = expectation(description: "getAllTabs completes instead of hanging")
        let outcome = LockedBox<Result<[ChromeRealTimeTab], Error>?>(nil)
        let start = Date()
        Task {
            do {
                let tabs = try await service.getAllTabs(forceRefresh: true)
                outcome.withValue { $0 = .success(tabs) }
            } catch {
                outcome.withValue { $0 = .failure(error) }
            }
            completed.fulfill()
        }

        // Hard ceiling: 2x the configured timeout. A missing/broken timeout
        // parks the continuation forever and fails here.
        await fulfillment(of: [completed], timeout: requestTimeout * 2)
        let elapsed = Date().timeIntervalSince(start)

        switch outcome.withValue({ $0 }) {
        case .failure(let error as ChromeNativeMessagingError):
            guard case .timeout = error else {
                return XCTFail("expected .timeout, got \(error)")
            }
        case let other:
            XCTFail("expected .timeout failure, got \(String(describing: other))")
        }
        XCTAssertGreaterThanOrEqual(elapsed, requestTimeout * 0.5, "timeout must not fire prematurely")
        XCTAssertLessThan(elapsed, requestTimeout * 2, "timeout must fire within ~2x the deadline")
    }

    /// A reply that beats the deadline wins: the decoded result is returned,
    /// no timeout fires, and letting the timeout window elapse afterwards must
    /// not double-resume the continuation (a double resume traps, so simply
    /// surviving the window — and completing a second round-trip — is the
    /// assertion).
    func testReplyBeforeDeadlineReturnsResultWithoutSpuriousTimeout() async throws {
        let requestTimeout: TimeInterval = 0.5
        let service = ChromeNativeMessagingService(socketPath: socketPath, requestTimeout: requestTimeout)
        try service.start()
        defer { service.stop() }

        guard let client = RawClient(path: socketPath) else {
            return XCTFail("client failed to connect")
        }
        defer { client.closeNow() }
        let connected = await waitFor("client connected") { service.isConnected }
        XCTAssertTrue(connected)

        let tabJSON = """
        [{"id":7,"windowId":1,"index":0,"url":"https://example.com","title":"Example","active":true,"pinned":false}]
        """
        startResponder(client: client, payloadJSON: tabJSON)

        let tabs = try await service.getAllTabs(forceRefresh: true)
        XCTAssertEqual(tabs.count, 1)
        XCTAssertEqual(tabs.first?.id, 7)
        XCTAssertEqual(tabs.first?.url, "https://example.com")

        // Let the original timeout window elapse; a stale (uncancelled or
        // unguarded) timeout task double-resuming would trap here.
        try await Task.sleep(nanoseconds: UInt64(requestTimeout * 2 * 1_000_000_000))
        XCTAssertTrue(service.isConnected, "connection must remain healthy after the timeout window")

        // A second round-trip proves the request pipeline is still intact.
        let tabsAgain = try await service.getAllTabs(forceRefresh: true)
        XCTAssertEqual(tabsAgain.first?.id, 7)
    }
}
