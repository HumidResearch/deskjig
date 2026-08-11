//  NativeMessagingServerLifecycleTests.swift
//  DeskJigSharedTests

import XCTest
@testable import DeskJigShared

final class NativeMessagingServerLifecycleTests: XCTestCase {

    private var socketPath: String!

    override func setUp() {
        super.setUp()
        socketPath = NSTemporaryDirectory() + "nms-tests-\(UUID().uuidString.prefix(8)).sock"
    }

    override func tearDown() {
        try? FileManager.default.removeItem(atPath: socketPath)
        super.tearDown()
    }

    // MARK: - Helpers

    /// Poll a condition instead of sleeping a fixed interval; generous timeout.
    private func waitFor(
        _ what: String,
        timeout: TimeInterval = 5.0,
        _ condition: () -> Bool
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            usleep(5_000)
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

    private final class EchoDelegate: NativeMessagingServerDelegate {
        func serverDidAcceptConnection(_ server: NativeMessagingServer) {}
        func server(_ server: NativeMessagingServer, didReceiveMessage data: Data) -> Data? {
            var response = Data("echo:".utf8)
            response.append(data)
            return response
        }
        func serverDidDisconnect(_ server: NativeMessagingServer, error: Error?) {}
    }

    private final class PassThroughDelegate: NativeMessagingServerDelegate {
        func serverDidAcceptConnection(_ server: NativeMessagingServer) {}
        func server(_ server: NativeMessagingServer, didReceiveMessage data: Data) -> Data? { data }
        func serverDidDisconnect(_ server: NativeMessagingServer, error: Error?) {}
    }

    private func makePayload(kind: String, index: Int, size: Int = 64 * 1024) -> Data {
        var payload = Data("\(kind)-\(index):".utf8)
        payload.append(Data(repeating: UInt8(index & 0xFF), count: size - payload.count))
        return payload
    }

    private static func readExactly(_ count: Int, from fd: Int32) -> Data? {
        var bytes = [UInt8](repeating: 0, count: count)
        var offset = 0
        while offset < count {
            let received = bytes.withUnsafeMutableBytes { buffer in
                recv(fd, buffer.baseAddress?.advanced(by: offset), count - offset, 0)
            }
            if received > 0 {
                offset += received
            } else if received < 0 && errno == EINTR {
                continue
            } else {
                return nil
            }
        }
        return Data(bytes)
    }

    // MARK: - Tests

    /// start()/stop() churn: every start must wait out the previous loop's
    /// wind-down, and every stop must remove the socket file exactly once.
    func testStartStopChurn() throws {
        let server = NativeMessagingServer(socketPath: socketPath)
        for iteration in 0..<25 {
            try server.start()
            server.stop()
            XCTAssertFalse(
                FileManager.default.fileExists(atPath: socketPath),
                "socket file should be removed after stop (iteration \(iteration))"
            )
        }
    }

    /// Message framing is unchanged: server push and request/response echo.
    func testFramedEchoRoundTrip() throws {
        let server = NativeMessagingServer(socketPath: socketPath)
        let delegate = EchoDelegate()
        server.delegate = delegate
        try server.start()
        defer { server.stop() }

        guard let client = RawClient(path: socketPath) else {
            return XCTFail("client failed to connect")
        }
        defer { client.closeNow() }
        XCTAssertTrue(waitFor("client connected") { server.isClientConnected })

        try server.sendToClient(Data("hello-from-server".utf8))
        XCTAssertEqual(client.recvFramed(), Data("hello-from-server".utf8))

        XCTAssertTrue(client.sendFramed(Data("ping".utf8)))
        XCTAssertEqual(client.recvFramed(), Data("echo:ping".utf8))
    }

    /// Concurrent pushes from arbitrary callers and request responses from the
    /// server queue share one socket. Every length prefix and body must remain
    /// an indivisible frame even when the large writes overlap.
    func testConcurrentPushesAndResponsesPreserveFrameBoundaries() throws {
        let server = NativeMessagingServer(socketPath: socketPath)
        let delegate = PassThroughDelegate()
        server.delegate = delegate
        defer { withExtendedLifetime(delegate) {} }
        try server.start()
        defer { server.stop() }

        guard let client = RawClient(path: socketPath) else {
            return XCTFail("client failed to connect")
        }
        defer { client.closeNow() }
        XCTAssertTrue(waitFor("client connected") { server.isClientConnected })

        let responses = (0..<12).map { makePayload(kind: "response", index: $0) }
        let pushes = (0..<12).map { makePayload(kind: "push", index: $0) }
        let expected = responses + pushes
        let received = LockedBox<[Data]>([])
        let failures = LockedBox<[String]>([])

        let readerGroup = DispatchGroup()
        readerGroup.enter()
        DispatchQueue.global().async {
            defer { readerGroup.leave() }
            for index in expected.indices {
                guard let frame = client.recvFramed() else {
                    failures.withValue { $0.append("failed to read frame \(index)") }
                    return
                }
                received.withValue { $0.append(frame) }
            }
        }

        let writerGroup = DispatchGroup()
        DispatchQueue.global().async(group: writerGroup) {
            for (index, payload) in responses.enumerated() {
                guard client.sendFramed(payload) else {
                    failures.withValue { $0.append("failed to send request \(index)") }
                    return
                }
            }
        }
        for (index, payload) in pushes.enumerated() {
            DispatchQueue.global().async(group: writerGroup) {
                do {
                    try server.sendToClient(payload)
                } catch {
                    failures.withValue { $0.append("push \(index) failed: \(error)") }
                }
            }
        }

        XCTAssertEqual(writerGroup.wait(timeout: .now() + 20), .success, "writers must not deadlock")
        let readerResult = readerGroup.wait(timeout: .now() + 20)
        if readerResult != .success {
            shutdown(client.fd, SHUT_RDWR)
            _ = readerGroup.wait(timeout: .now() + 5)
        }
        XCTAssertEqual(readerResult, .success, "reader must receive every complete frame")

        let capturedFailures = failures.withValue { $0 }
        let capturedFrames = received.withValue { $0 }
        XCTAssertTrue(capturedFailures.isEmpty, capturedFailures.joined(separator: "; "))
        XCTAssertEqual(capturedFrames.count, expected.count)
        XCTAssertEqual(Set(capturedFrames), Set(expected))
    }

    /// Force every underlying send after the first EINTR to accept at most 97
    /// bytes. The write-all helper must retry and deliver the full large body.
    func testWriteAllRetriesInterruptedAndShortWrites() throws {
        var sockets = [Int32](repeating: -1, count: 2)
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &sockets), 0)
        guard sockets.allSatisfy({ $0 >= 0 }) else { return }
        defer {
            close(sockets[0])
            close(sockets[1])
        }

        let payload = makePayload(kind: "short-write", index: 1, size: 256 * 1024)
        let received = LockedBox<Data?>(nil)
        let readerGroup = DispatchGroup()
        readerGroup.enter()
        DispatchQueue.global().async {
            defer { readerGroup.leave() }
            received.withValue { $0 = Self.readExactly(payload.count, from: sockets[1]) }
        }

        var sendCalls = 0
        try NativeMessagingServer.writeAll(payload, to: sockets[0]) { fd, buffer, count, flags in
            sendCalls += 1
            if sendCalls == 1 {
                errno = EINTR
                return -1
            }
            return Darwin.send(fd, buffer, min(count, 97), flags)
        }

        XCTAssertEqual(readerGroup.wait(timeout: .now() + 10), .success)
        XCTAssertGreaterThan(sendCalls, payload.count / 97)
        XCTAssertEqual(received.withValue { $0 }, payload)
    }

    /// After a natural client disconnect, isClientConnected flips false and
    /// sendToClient throws noClientConnected.
    func testSendAfterDisconnectThrows() throws {
        let server = NativeMessagingServer(socketPath: socketPath)
        try server.start()
        defer { server.stop() }

        guard let client = RawClient(path: socketPath) else {
            return XCTFail("client failed to connect")
        }
        XCTAssertTrue(waitFor("client connected") { server.isClientConnected })
        client.closeNow()
        XCTAssertTrue(waitFor("client disconnected") { !server.isClientConnected })
        XCTAssertThrowsError(try server.sendToClient(Data("x".utf8)))
    }

    /// The teardown race from #505: stop() while the accept loop is blocked
    /// in recv() on a live client must return promptly (shutdown-to-interrupt,
    /// never close of an in-use fd) and fully release the fds so a fresh
    /// start() on the same path succeeds.
    func testStopWhileBlockedInRecvThenRestart() throws {
        let server = NativeMessagingServer(socketPath: socketPath)
        try server.start()

        guard let client = RawClient(path: socketPath) else {
            return XCTFail("client failed to connect")
        }
        defer { client.closeNow() }
        XCTAssertTrue(waitFor("client connected") { server.isClientConnected })
        usleep(100_000) // make blocked-in-recv() the likely stop() interleaving

        let stopStart = Date()
        server.stop()
        XCTAssertLessThan(Date().timeIntervalSince(stopStart), 2.0, "stop() must not hang on a blocked recv()")

        // start() waits for the previous loop to wind down and release its
        // fds; success proves the loop observed the shutdown and exited.
        try server.start()
        defer { server.stop() }
        guard let client2 = RawClient(path: socketPath) else {
            return XCTFail("reconnect after restart failed")
        }
        defer { client2.closeNow() }
        XCTAssertTrue(waitFor("reconnected after restart") { server.isClientConnected })
    }

    /// stop() while the accept loop is blocked in accept() (no client): the
    /// self-connection wake-up must unblock it (macOS shutdown() does not
    /// interrupt accept() on a listening socket).
    func testStopWhileBlockedInAcceptThenRestart() throws {
        let server = NativeMessagingServer(socketPath: socketPath)
        try server.start()
        usleep(100_000) // make blocked-in-accept() the likely stop() interleaving

        let stopStart = Date()
        server.stop()
        XCTAssertLessThan(Date().timeIntervalSince(stopStart), 2.0, "stop() must not hang on a blocked accept()")

        try server.start() // proves the loop exited and released the fds
        server.stop()
    }

    /// The everyday race from #505: concurrent isClientConnected/sendToClient
    /// from arbitrary threads while the server is stopped and restarted
    /// mid-hammer. Must not crash, deadlock, or use a stale fd; sends around
    /// the stop may throw noClientConnected, which is fine.
    func testConcurrentSendersSurviveStopStartChurn() throws {
        let server = NativeMessagingServer(socketPath: socketPath)
        let delegate = EchoDelegate()
        server.delegate = delegate
        try server.start()

        guard let client = RawClient(path: socketPath) else {
            return XCTFail("client failed to connect")
        }
        XCTAssertTrue(waitFor("client connected") { server.isClientConnected })

        // Drain pushes so send() never wedges on a full socket buffer.
        let drainQueue = DispatchQueue(label: "test-drain", attributes: .concurrent)
        let drainGroup = DispatchGroup()
        func drain(_ fd: Int32) {
            drainQueue.async(group: drainGroup) {
                var buffer = [UInt8](repeating: 0, count: 4096)
                while recv(fd, &buffer, buffer.count, 0) > 0 {}
            }
        }
        drain(client.fd)

        let hammerGroup = DispatchGroup()
        let payload = Data("hammer-payload".utf8)
        for _ in 0..<8 {
            DispatchQueue.global().async(group: hammerGroup) {
                for _ in 0..<300 {
                    _ = server.isClientConnected
                    _ = try? server.sendToClient(payload)
                }
            }
        }

        usleep(20_000)
        server.stop()
        try server.start()
        guard let client2 = RawClient(path: socketPath) else {
            return XCTFail("reconnect during hammer failed")
        }
        drain(client2.fd)

        XCTAssertEqual(hammerGroup.wait(timeout: .now() + 30), .success, "hammer threads must not deadlock")
        server.stop()

        // Unblock and join the drain tasks BEFORE close(): closing an fd a
        // recv() may still be blocked on is exactly the use-after-close class
        // the production change eliminates.
        shutdown(client.fd, SHUT_RDWR)
        shutdown(client2.fd, SHUT_RDWR)
        XCTAssertEqual(drainGroup.wait(timeout: .now() + 5), .success, "drain tasks must exit before their fds close")
        client.closeNow()
        client2.closeNow()
    }

    /// SIGPIPE regression (#582 review blocker): a sender blocked in send()
    /// on a full socket buffer while stop() shuts the socket down must fail
    /// fast with EPIPE — not raise SIGPIPE and kill the process. Verifies
    /// SO_NOSIGPIPE is set on the accepted client fd; without it this test
    /// crashes the test host.
    func testStopWhileSenderBlockedInSendDoesNotRaiseSIGPIPE() throws {
        let server = NativeMessagingServer(socketPath: socketPath)
        try server.start()

        guard let client = RawClient(path: socketPath) else {
            return XCTFail("client failed to connect")
        }
        defer { client.closeNow() }
        XCTAssertTrue(waitFor("client connected") { server.isClientConnected })

        // The client never recv()s, so pushes accumulate until the socket
        // buffer fills and sendToClient blocks inside send().
        let senderDone = DispatchGroup()
        let payload = Data(repeating: 0xAB, count: 64 * 1024)
        DispatchQueue.global().async(group: senderDone) {
            for _ in 0..<64 {
                do { try server.sendToClient(payload) } catch { return }
            }
        }

        usleep(300_000) // make blocked-in-send() the likely stop() interleaving
        server.stop()

        // Had SIGPIPE fired, the process would already be dead; the sender
        // unwinding (EPIPE from the interrupted send, then noClientConnected)
        // is the pass condition.
        XCTAssertEqual(senderDone.wait(timeout: .now() + 10), .success, "sender must unwind after stop()")
    }

    /// stop() is idempotent and safe before start() and after a prior stop()
    /// (deinit also calls stop(), so the double-call path runs in production).
    func testStopIsIdempotent() throws {
        let server = NativeMessagingServer(socketPath: socketPath)
        server.stop() // before start: no-op
        try server.start()
        server.stop()
        server.stop() // after stop: no-op

        // A redundant stop() must NOT delete a socket file bound by a newer
        // start() at the same path (regression guard for the wake-up path).
        try server.start()
        defer { server.stop() }
        XCTAssertTrue(FileManager.default.fileExists(atPath: socketPath))
    }
}
