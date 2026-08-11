//  NativeMessagingServer.swift
//  DeskJigShared

import Foundation

// MARK: - Server Delegate

/// Delegate protocol for handling native messaging events.
///
/// Delivery contract: all three callbacks are invoked synchronously on the
/// server's client-handling thread, in per-connection order —
/// `serverDidAcceptConnection` strictly before the first `didReceiveMessage`
/// of that connection, and `serverDidDisconnect` strictly after its last one
/// (and before the next connection's accept). A peer that sends its first
/// message immediately after `connect()` therefore can never have that
/// message processed ahead of the accept callback (#542 handshake race).
/// Callbacks are NOT delivered on the main thread; implementations must hop
/// themselves if needed, and must not block (message handling for the
/// connection stalls while a callback runs).
public protocol NativeMessagingServerDelegate: AnyObject {
    /// Called when a client connects, before any message from that client
    func serverDidAcceptConnection(_ server: NativeMessagingServer)

    /// Called when a message is received from DeskJigNativeHost
    func server(_ server: NativeMessagingServer, didReceiveMessage data: Data) -> Data?

    /// Called when the client disconnects, after its last message
    func serverDidDisconnect(_ server: NativeMessagingServer, error: Error?)
}

// MARK: - Server Implementation

/// Unix domain socket server that listens for connections from DeskJigNativeHost.
///
/// Thread-safety design (see #505):
/// - `serverSocket`, `clientSocket`, `isRunning`, `acceptLoopActive` and
///   `loopGeneration` are only ever read or written while holding `stateLock`.
/// - While the accept loop is active it is the sole owner of fd `close()`:
///   `stop()` never closes an fd the loop might still be blocked on. Instead it
///   sets `isRunning = false`, `shutdown()`s the client fd (which interrupts a
///   blocked `recv` without invalidating the fd number, so the kernel cannot
///   recycle it under the loop) and wakes a blocked `accept()` with a throwaway
///   self-connection (on macOS, `shutdown()` on a listening socket fails with
///   ENOTCONN and does not interrupt `accept`). The loop then observes
///   `isRunning == false` and closes its own fds on exit. Only when no loop is
///   active (never started for this generation, or already exited) does
///   `stop()` close the fds directly.
/// - Every fd this class creates or accepts gets `SO_NOSIGPIPE`: the teardown
///   design relies on a racing `send()` failing fast with EPIPE after
///   `shutdown()`, and on Darwin that `send()` would otherwise raise SIGPIPE
///   and kill the process.
/// - If the accept-loop wake fails (e.g. transient fd exhaustion), `stop()`
///   logs, keeps the socket file on disk (unlinking it would leave the blocked
///   `accept()` unreachable) and records the failure; `start()` retries the
///   wake while waiting for the old loop to wind down, so a transient wake
///   failure can never permanently strand the loop or wedge future `start()`s.
/// - Every `close()` of a *published* client fd clears `clientSocket` under
///   `stateLock` first and performs the `close()` while holding `sendLock`.
///   `sendToClient` acquires `sendLock` for the whole send and only then reads
///   `clientSocket` under `stateLock`, so the fd it writes to cannot be closed
///   (and recycled by the kernel) mid-send. `sendLock` also serializes message
///   framing between the reply path on `queue` and external `sendToClient`
///   callers.
/// - No blocking syscall (accept/recv/send) is ever made while holding
///   `stateLock`. Lock ordering: `sendLock` before `stateLock`, never the
///   reverse.
/// - Delegate callbacks (accept, message, disconnect) are all delivered
///   synchronously on the accept-loop thread, with no lock held, so they
///   observe a total per-connection order. Dispatching accept/disconnect
///   asynchronously (the pre-#542-fix design) let a fast peer's first
///   message be processed before the accept callback, whose connection-state
///   reset then clobbered state derived from that message.
public final class NativeMessagingServer: @unchecked Sendable {

    // MARK: - Properties

    public weak var delegate: NativeMessagingServerDelegate?

    private let socketPath: String

    /// Guards all socket-lifecycle state below. An `NSCondition` so `start()`
    /// can wait for a previous generation's accept loop to finish winding down
    /// before creating fresh sockets.
    private let stateLock = NSCondition()

    /// Serializes sends on the client socket and guards `close()` of any
    /// published client fd. Acquired BEFORE `stateLock` when both are needed.
    private let sendLock = NSLock()

    // The six fields below are guarded by `stateLock`.
    private var serverSocket: Int32 = -1
    private var clientSocket: Int32 = -1
    private var isRunning = false
    /// True while the accept loop owns the fds (from loop entry to loop exit).
    private var acceptLoopActive = false
    /// Incremented on every `start()`; lets a queued accept-loop closure detect
    /// that its run was cancelled (stopped or superseded) before it began.
    private var loopGeneration = 0
    /// Set when `stop()` could not wake a blocked `accept()`; `start()` retries
    /// the wake while waiting for the old loop to wind down. Cleared when a
    /// retry succeeds or the loop exits.
    private var acceptWakeFailed = false

    private let queue = DispatchQueue(label: "com.deskjig.native-messaging-server")

    /// Whether a client is currently connected
    public var isClientConnected: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        // Also require isRunning: after stop() the loop clears clientSocket
        // at wind-down, so the fd alone can read stale-true briefly.
        return clientSocket >= 0 && isRunning
    }

    // MARK: - Initialization

    /// Initialize with default socket path
    public init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        self.socketPath = appSupport.appendingPathComponent("DeskJig/native-messaging.sock").path
    }

    /// Initialize with custom socket path (for testing)
    public init(socketPath: String) {
        self.socketPath = socketPath
    }

    deinit {
        stop()
    }

    // MARK: - Server Lifecycle

    /// Start the server and begin listening for connections
    public func start() throws {
        stateLock.lock()
        defer { stateLock.unlock() }

        guard !isRunning else { return }

        // If a previous stop() is still winding down, wait for its accept loop
        // to exit and release the old fds before creating new ones. If that
        // stop()'s wake of a blocked accept() failed (transient, e.g. fd
        // exhaustion), retry it here: a failed wake must never permanently
        // strand the old loop — and with it every future start().
        let deadline = Date().addingTimeInterval(5.0)
        while acceptLoopActive {
            if acceptWakeFailed && wakeBlockedAccept() {
                acceptWakeFailed = false
            }
            _ = stateLock.wait(until: min(Date().addingTimeInterval(0.25), deadline))
            if acceptLoopActive && Date() >= deadline {
                throw NativeMessagingServerError.listenFailed("previous accept loop did not shut down in time")
            }
        }
        guard !isRunning else { return }

        let fd = try makeListeningSocket()

        serverSocket = fd
        isRunning = true
        loopGeneration += 1
        DeskJigLog.info(.chrome, "NativeMessagingServer: Native messaging server started at \(self.socketPath)")

        // Start accepting connections
        acceptConnections(generation: loopGeneration)
    }

    /// Create, bind and listen the unix-domain server socket.
    /// Returns the fd; it stays local to the caller until published under `stateLock`.
    private func makeListeningSocket() throws -> Int32 {
        // Ensure the directory exists
        let directory = (socketPath as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)

        // Remove existing socket file if present
        if FileManager.default.fileExists(atPath: socketPath) {
            try FileManager.default.removeItem(atPath: socketPath)
        }

        // Create socket
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw NativeMessagingServerError.socketCreationFailed
        }
        suppressSIGPIPE(on: fd)

        // Bind to path
        guard var addr = makeSocketAddress() else {
            close(fd)
            throw NativeMessagingServerError.pathTooLong
        }

        let bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                Darwin.bind(fd, sockPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }

        guard bindResult >= 0 else {
            let errorMsg = String(cString: strerror(errno))
            close(fd)
            throw NativeMessagingServerError.bindFailed(errorMsg)
        }

        // Listen for connections (backlog of 1 - we only expect one client)
        guard listen(fd, 1) >= 0 else {
            let errorMsg = String(cString: strerror(errno))
            close(fd)
            throw NativeMessagingServerError.listenFailed(errorMsg)
        }

        return fd
    }

    /// Stop the server. Safe to call from any thread (including `deinit`) and idempotent.
    public func stop() {
        stateLock.lock()
        let wasRunning = isRunning
        isRunning = false

        var wakeFailed = false
        if acceptLoopActive {
            // The accept loop owns the fds and closes them on exit. Never
            // close() here: the loop may be blocked in recv()/accept() on
            // these exact fds and close() would let the kernel recycle the fd
            // number under it. shutdown() interrupts a blocked recv() while
            // keeping the fd number reserved.
            if clientSocket >= 0 {
                shutdown(clientSocket, SHUT_RDWR)
            }
            if serverSocket >= 0 {
                wakeFailed = !wakeBlockedAccept()
                acceptWakeFailed = wakeFailed
            }
        } else {
            // No loop is (or ever will be) using these fds: either start()
            // never spawned one for this generation (the queued closure bails
            // out on isRunning == false / stale generation without touching
            // them) or the loop already exited and cleared them. Close
            // whatever is left directly.
            if clientSocket >= 0 {
                close(clientSocket)
                clientSocket = -1
            }
            if serverSocket >= 0 {
                close(serverSocket)
                serverSocket = -1
            }
        }

        // Clean up socket file, but only on the stop() that actually
        // transitioned running -> stopped (after wakeBlockedAccept, which
        // needs the file). A redundant stop() (e.g. deinit after an explicit
        // stop) must not delete a socket file that a newer start() has since
        // bound at the same path. Done under the lock so it cannot race a
        // concurrent start() either. If the wake FAILED, keep the file too:
        // unlinking it would leave the blocked accept() unreachable, with no
        // way for the retry in start() to ever connect.
        if wasRunning && !wakeFailed {
            try? FileManager.default.removeItem(atPath: socketPath)
        }
        stateLock.unlock()

        if wasRunning {
            DeskJigLog.info(.chrome, "NativeMessagingServer: Native messaging server stopped")
        }
    }

    /// Interrupt an `accept()` blocked on `serverSocket`. On macOS,
    /// `shutdown()` on a listening socket fails with ENOTCONN and does NOT
    /// wake a blocked `accept()`, so connect to ourselves instead: the accept
    /// loop wakes, observes `isRunning == false`, closes the throwaway
    /// connection and exits. Called with `stateLock` held; the dummy socket is
    /// non-blocking so this cannot stall `stop()`.
    ///
    /// Returns whether the wake connection was made. On failure the caller
    /// must NOT unlink the socket path (the blocked loop would become
    /// unreachable forever); `stop()` records the failure so `start()` retries
    /// the wake while waiting for the loop to wind down.
    private func wakeBlockedAccept() -> Bool {
        // Bounded retry: a transient failure (e.g. fd exhaustion during
        // teardown) must not silently strand the accept loop.
        let maxAttempts = 3
        for attempt in 1...maxAttempts where attemptAcceptWake(attempt: attempt, of: maxAttempts) {
            return true
        }
        DeskJigLog.error(.chrome, "NativeMessagingServer: could not wake blocked accept() after \(maxAttempts) attempts; deferring retry to next start()")
        return false
    }

    /// One self-connection attempt for `wakeBlockedAccept()`; logs the failing
    /// step at error level.
    private func attemptAcceptWake(attempt: Int, of maxAttempts: Int) -> Bool {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            logWakeFailure("socket()", attempt: attempt, of: maxAttempts)
            return false
        }
        defer { close(fd) }
        suppressSIGPIPE(on: fd)

        let flags = fcntl(fd, F_GETFL, 0)
        guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) >= 0 else {
            logWakeFailure("fcntl()", attempt: attempt, of: maxAttempts)
            return false
        }

        guard var addr = makeSocketAddress() else {
            DeskJigLog.error(.chrome, "NativeMessagingServer: accept wake attempt \(attempt)/\(maxAttempts) failed: socket path too long")
            return false
        }
        let result = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                Darwin.connect(fd, sockPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        // A non-blocking connect that is merely in progress has still queued
        // the connection, which is enough to wake accept().
        guard result == 0 || errno == EINPROGRESS else {
            logWakeFailure("connect()", attempt: attempt, of: maxAttempts)
            return false
        }
        return true
    }

    private func logWakeFailure(_ step: String, attempt: Int, of maxAttempts: Int) {
        let errorMsg = String(cString: strerror(errno))
        DeskJigLog.error(.chrome, "NativeMessagingServer: accept wake attempt \(attempt)/\(maxAttempts) failed: \(step): \(errorMsg)")
    }

    /// Suppress SIGPIPE on `fd`. The teardown design relies on a racing
    /// `send()` failing fast with EPIPE after `shutdown()`; on Darwin that
    /// `send()` would otherwise raise SIGPIPE and terminate the process.
    private func suppressSIGPIPE(on fd: Int32) {
        var enabled: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout<Int32>.size))
    }

    /// Build a `sockaddr_un` for `socketPath`, or nil if the path doesn't fit.
    private func makeSocketAddress() -> sockaddr_un? {
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)

        let pathBytes = socketPath.utf8CString
        guard pathBytes.count <= MemoryLayout.size(ofValue: addr.sun_path) else {
            return nil
        }

        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: pathBytes.count) { dest in
                for (i, byte) in pathBytes.enumerated() {
                    dest[i] = byte
                }
            }
        }

        return addr
    }

    // MARK: - Connection Handling

    private func acceptConnections(generation: Int) {
        queue.async { [weak self] in
            guard let self = self else { return }

            self.stateLock.lock()
            guard self.isRunning, self.loopGeneration == generation else {
                // stop() ran (or a newer start() superseded this run) before
                // the closure was scheduled; the fds were already handled.
                self.stateLock.unlock()
                return
            }
            self.acceptLoopActive = true
            self.stateLock.unlock()

            self.runAcceptLoop()
            self.finishAcceptLoop()
        }
    }

    private func runAcceptLoop() {
        while true {
            // Re-check lifecycle state under the lock before each blocking accept
            stateLock.lock()
            let serverFd = isRunning ? serverSocket : -1
            stateLock.unlock()
            guard serverFd >= 0 else { return }

            DeskJigLog.debug(.chrome, "NativeMessagingServer: Waiting for connection...")

            // Accept incoming connection (blocking; serverFd stays valid
            // because only this thread closes it while the loop is active)
            var clientAddr = sockaddr_un()
            var clientAddrLen = socklen_t(MemoryLayout<sockaddr_un>.size)

            let newClient = withUnsafeMutablePointer(to: &clientAddr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                    Darwin.accept(serverFd, sockPtr, &clientAddrLen)
                }
            }

            guard newClient >= 0 else {
                let acceptErrno = errno
                stateLock.lock()
                let running = isRunning
                stateLock.unlock()
                guard running else { return }
                DeskJigLog.error(.chrome, "NativeMessagingServer: Accept failed: \(String(cString: strerror(acceptErrno)))")
                continue
            }

            // Suppress SIGPIPE BEFORE publishing: once the fd is visible, a
            // racing sendToClient relies on EPIPE-after-shutdown, not process
            // death.
            suppressSIGPIPE(on: newClient)

            // Publish the new client, unless stop() ran while we were blocked
            // in accept() (the wake-up self-connection lands here too).
            stateLock.lock()
            guard isRunning else {
                stateLock.unlock()
                close(newClient) // never published; no other thread can hold it
                return
            }
            clientSocket = newClient
            stateLock.unlock()

            DeskJigLog.info(.chrome, "NativeMessagingServer: Client connected")

            // Deliver the accept callback synchronously, BEFORE entering the
            // message loop: didReceiveMessage is delivered synchronously from
            // handleClient, so an async-dispatched accept could run AFTER the
            // connection's first message (a current extension handshakes
            // immediately on connect), letting the accept-time status reset
            // clobber an already-recorded handshake (#542).
            delegate?.serverDidAcceptConnection(self)

            // Handle messages from this client (returns when it disconnects)
            handleClient(newClient)
        }
    }

    /// Loop exit: release ownership of the fds. Fields are cleared under
    /// `stateLock` before closing, and the close of a published client fd
    /// happens under `sendLock`; then any `start()` waiting for the wind-down
    /// is woken.
    private func finishAcceptLoop() {
        sendLock.lock()
        stateLock.lock()
        let clientFd = clientSocket
        let serverFd = serverSocket
        clientSocket = -1
        serverSocket = -1
        acceptLoopActive = false
        acceptWakeFailed = false // loop exited; no wake retry needed anymore
        stateLock.broadcast()
        stateLock.unlock()
        if clientFd >= 0 { // defensive: handleClient normally closed it already
            close(clientFd)
        }
        if serverFd >= 0 {
            close(serverFd)
        }
        sendLock.unlock()
    }

    private func handleClient(_ socket: Int32) {
        while true {
            // Re-check lifecycle state under the lock before the blocking
            // length recv: stop() may have shut the socket down, and this fd
            // may no longer be the published client. The body recv below is
            // NOT re-guarded; it stays safe because this thread has exclusive
            // close ownership of the fd and stop() interrupts blocked reads
            // via shutdown(), never close().
            stateLock.lock()
            let active = isRunning && clientSocket == socket
            stateLock.unlock()
            guard active else { break }

            // Read message length (4 bytes, little-endian)
            var lengthBytes = [UInt8](repeating: 0, count: 4)
            let lengthRead = recv(socket, &lengthBytes, 4, MSG_WAITALL)

            guard lengthRead == 4 else {
                if lengthRead == 0 {
                    DeskJigLog.info(.chrome, "NativeMessagingServer: Client disconnected")
                } else {
                    DeskJigLog.error(.chrome, "NativeMessagingServer: Failed to read message length: \(lengthRead)")
                }
                break
            }

            let length = UInt32(lengthBytes[0]) |
                         (UInt32(lengthBytes[1]) << 8) |
                         (UInt32(lengthBytes[2]) << 16) |
                         (UInt32(lengthBytes[3]) << 24)

            guard length > 0 && length <= 1024 * 1024 else {
                DeskJigLog.error(.chrome, "NativeMessagingServer: Invalid message length: \(length)")
                break
            }

            // Read message body
            var messageBytes = [UInt8](repeating: 0, count: Int(length))
            let messageRead = recv(socket, &messageBytes, Int(length), MSG_WAITALL)

            guard messageRead == Int(length) else {
                DeskJigLog.error(.chrome, "NativeMessagingServer: Failed to read message body")
                break
            }

            let messageData = Data(messageBytes)
            // Process message and get response
            if let responseData = delegate?.server(self, didReceiveMessage: messageData) {
                sendLock.lock()
                do {
                    try sendResponse(responseData, to: socket)
                    sendLock.unlock()
                } catch {
                    sendLock.unlock()
                    DeskJigLog.error(.chrome, "NativeMessagingServer: Failed to send response: \(error.localizedDescription)")
                    break
                }
            }
        }

        // This thread accepted the fd and owns closing it. First shut it down
        // so a sendToClient currently blocked in send() on it fails fast and
        // cannot stall the sendLock acquisition below.
        shutdown(socket, SHUT_RDWR)

        // Clear the published field under stateLock BEFORE closing, and close
        // under sendLock, so sendToClient can never observe a closed
        // (kernel-recyclable) fd.
        sendLock.lock()
        stateLock.lock()
        let wasCurrent = clientSocket == socket
        let notifyDisconnect = wasCurrent && isRunning
        if wasCurrent {
            clientSocket = -1
        }
        stateLock.unlock()
        close(socket)
        sendLock.unlock()

        if notifyDisconnect {
            // Synchronous for the same reason as the accept callback: an
            // async-dispatched disconnect reset could land after the NEXT
            // connection's accept/handshake and clobber its fresh state
            // (mirror image of the accept-vs-first-message race).
            delegate?.serverDidDisconnect(self, error: nil)
        }
    }

    /// Send a length-prefixed message on `socket`.
    /// Callers must hold `sendLock` (serializes framing and guards fd close).
    private func sendResponse(_ data: Data, to socket: Int32) throws {
        let length = UInt32(data.count)

        // Send length prefix (little-endian)
        let lengthBytes: [UInt8] = [
            UInt8(length & 0xFF),
            UInt8((length >> 8) & 0xFF),
            UInt8((length >> 16) & 0xFF),
            UInt8((length >> 24) & 0xFF)
        ]

        try Self.writeAll(Data(lengthBytes), to: socket)
        try Self.writeAll(data, to: socket)

    }

    /// Write every byte in `data`, retrying interrupted syscalls and treating
    /// zero-byte writes or any other send error as a hard failure.
    ///
    /// The injectable operation keeps the short-write regression test
    /// deterministic; production callers always use the default Darwin send.
    static func writeAll(
        _ data: Data,
        to socket: Int32,
        using sendBytes: (Int32, UnsafeRawPointer?, Int, Int32) -> Int = {
            Darwin.send($0, $1, $2, $3)
        }
    ) throws {
        try data.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let sent = sendBytes(
                    socket,
                    buffer.baseAddress?.advanced(by: offset),
                    buffer.count - offset,
                    0
                )

                if sent > 0 {
                    offset += sent
                    continue
                }
                if sent < 0 && errno == EINTR {
                    continue
                }

                let errorNumber = sent == 0 ? EPIPE : errno
                throw NativeMessagingServerError.sendFailed(
                    String(cString: strerror(errorNumber))
                )
            }
        }
    }

    // MARK: - Sending Messages

    /// Send a message to the connected client (DeskJigNativeHost).
    /// Thread-safe: may be called from any thread or executor.
    public func sendToClient(_ data: Data) throws {
        // Take sendLock FIRST, then read the current client under stateLock:
        // any close of a published client fd happens under sendLock (after
        // clearing the field), so the fd read here cannot be closed or
        // recycled for the duration of the send. stop() only shutdown()s it,
        // which makes send() fail fast instead of touching a stale fd.
        sendLock.lock()
        defer { sendLock.unlock() }

        stateLock.lock()
        let fd = isRunning ? clientSocket : -1
        stateLock.unlock()

        guard fd >= 0 else {
            throw NativeMessagingServerError.noClientConnected
        }

        do {
            try sendResponse(data, to: fd)
        } catch {
            // A failed length-prefixed write leaves the stream unusable. Make
            // the connection fail hard so the receive loop closes it and the
            // native host reconnects instead of consuming a truncated frame.
            shutdown(fd, SHUT_RDWR)
            throw error
        }
    }
}

// MARK: - Errors

public enum NativeMessagingServerError: Error, LocalizedError {
    case socketCreationFailed
    case pathTooLong
    case bindFailed(String)
    case listenFailed(String)
    case noClientConnected
    case sendFailed(String)

    public var errorDescription: String? {
        switch self {
        case .socketCreationFailed:
            return "Failed to create socket"
        case .pathTooLong:
            return "Socket path too long"
        case .bindFailed(let reason):
            return "Failed to bind socket: \(reason)"
        case .listenFailed(let reason):
            return "Failed to listen on socket: \(reason)"
        case .noClientConnected:
            return "No client connected"
        case .sendFailed(let reason):
            return "Failed to send message: \(reason)"
        }
    }
}
