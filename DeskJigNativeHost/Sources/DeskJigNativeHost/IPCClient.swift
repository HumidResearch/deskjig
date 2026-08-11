//  IPCClient.swift
//  DeskJigNativeHost

//  Unix domain socket client for communicating with DeskJig.app

import Foundation

/// Errors that can occur during IPC communication
enum IPCError: Error, LocalizedError {
    case socketCreationFailed
    case connectionFailed(String)
    case sendFailed(String)
    case receiveFailed(String)
    case notConnected
    case messageToLarge

    var errorDescription: String? {
        switch self {
        case .socketCreationFailed:
            return "Failed to create socket"
        case .connectionFailed(let reason):
            return "Connection failed: \(reason)"
        case .sendFailed(let reason):
            return "Send failed: \(reason)"
        case .receiveFailed(let reason):
            return "Receive failed: \(reason)"
        case .notConnected:
            return "Not connected to DeskJig.app"
        case .messageToLarge:
            return "Message too large"
        }
    }
}

/// Unix domain socket client for IPC with DeskJig.app
///
/// DeskJig.app listens on a Unix socket at:
/// `~/Library/Application Support/DeskJig/native-messaging.sock`
///
/// Protocol:
/// - 4-byte length prefix (little-endian UInt32)
/// - JSON message payload
final class IPCClient {

    // MARK: - Properties

    /// Default socket path
    ///
    /// PAIRED CONSTANT: this literal is duplicated by design — the native host is a
    /// standalone SPM executable and does not import DeskJigShared, so it cannot share
    /// a symbol across the process boundary. The app-side half lives in
    /// `DeskJigShared/Sources/Managers/Chrome/ChromeExtensionConstants.swift`
    /// (`socketPath`, mirrored by `NativeMessagingServer`). Change both or the bridge
    /// silently fails to connect.
    static var defaultSocketPath: String {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!
        return appSupport.appendingPathComponent("DeskJig/native-messaging.sock").path
    }

    private let socketPath: String
    private var socketFD: Int32 = -1
    private let sendLock = NSLock()

    var isConnected: Bool {
        socketFD >= 0
    }

    /// Expose socket file descriptor for use with select()
    var socketFileDescriptor: Int32 {
        socketFD
    }

    // MARK: - Initialization

    init(socketPath: String? = nil) {
        self.socketPath = socketPath ?? IPCClient.defaultSocketPath
    }

    deinit {
        disconnect()
    }

    // MARK: - Connection

    /// Connect to DeskJig.app's Unix socket
    func connect() throws {
        // Create socket
        socketFD = socket(AF_UNIX, SOCK_STREAM, 0)
        guard socketFD >= 0 else {
            throw IPCError.socketCreationFailed
        }

        // Convert a closed-peer write into EPIPE instead of letting SIGPIPE
        // terminate the native host before send() can propagate the error.
        var noSigPipe: Int32 = 1
        _ = setsockopt(
            socketFD,
            SOL_SOCKET,
            SO_NOSIGPIPE,
            &noSigPipe,
            socklen_t(MemoryLayout<Int32>.size)
        )

        // Set up socket address
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)

        // Copy path to sun_path (must be null-terminated and fit)
        let pathBytes = socketPath.utf8CString
        guard pathBytes.count <= MemoryLayout.size(ofValue: addr.sun_path) else {
            close(socketFD)
            socketFD = -1
            throw IPCError.connectionFailed("Socket path too long")
        }

        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: pathBytes.count) { dest in
                for (i, byte) in pathBytes.enumerated() {
                    dest[i] = byte
                }
            }
        }

        // Connect
        let result = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                Darwin.connect(socketFD, sockPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }

        if result < 0 {
            let errorMessage = String(cString: strerror(errno))
            close(socketFD)
            socketFD = -1
            throw IPCError.connectionFailed(errorMessage)
        }

        NativeMessagingProtocol.log("Connected to DeskJig.app at \(socketPath)")
    }

    /// Disconnect from DeskJig.app
    func disconnect() {
        sendLock.lock()
        defer { sendLock.unlock() }

        if socketFD >= 0 {
            close(socketFD)
            socketFD = -1
            NativeMessagingProtocol.log("Disconnected from DeskJig.app")
        }
    }

    // MARK: - Messaging

    /// Send a message to DeskJig.app
    /// - Parameter data: The message data to send
    func send(_ data: Data) throws {
        sendLock.lock()
        defer { sendLock.unlock() }

        guard isConnected else {
            throw IPCError.notConnected
        }

        let length = UInt32(data.count)
        guard length <= NativeMessagingProtocol.maxMessageSize else {
            throw IPCError.messageToLarge
        }

        // Send 4-byte length prefix (little-endian)
        let lengthBytes: [UInt8] = [
            UInt8(length & 0xFF),
            UInt8((length >> 8) & 0xFF),
            UInt8((length >> 16) & 0xFF),
            UInt8((length >> 24) & 0xFF)
        ]

        let fd = socketFD
        do {
            try Self.writeAll(Data(lengthBytes), to: fd)
            try Self.writeAll(data, to: fd)
        } catch {
            // Any failed framed write may have left the peer waiting for the
            // rest of the body. Make the stream fail hard so it is reconnected
            // instead of attempting another message on a desynchronized fd.
            shutdown(fd, SHUT_RDWR)
            throw error
        }
    }

    /// Fully drain a buffer to the socket. Stream sockets may legally accept
    /// fewer bytes than requested even in blocking mode.
    private static func writeAll(_ data: Data, to socket: Int32) throws {
        try data.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let sent = Darwin.send(
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
                throw IPCError.sendFailed(String(cString: strerror(errorNumber)))
            }
        }
    }

    /// Receive a message from DeskJig.app
    /// - Returns: The received message data
    func receive() throws -> Data {
        guard isConnected else {
            throw IPCError.notConnected
        }

        // Read 4-byte length prefix
        var lengthBytes = [UInt8](repeating: 0, count: 4)
        let lengthRead = recv(socketFD, &lengthBytes, 4, MSG_WAITALL)

        guard lengthRead == 4 else {
            throw IPCError.receiveFailed("Failed to read length prefix")
        }

        // Parse as little-endian UInt32
        let length = UInt32(lengthBytes[0]) |
                     (UInt32(lengthBytes[1]) << 8) |
                     (UInt32(lengthBytes[2]) << 16) |
                     (UInt32(lengthBytes[3]) << 24)

        guard length > 0 && length <= NativeMessagingProtocol.maxMessageSize else {
            throw IPCError.receiveFailed("Invalid message length: \(length)")
        }

        // Read message body
        var messageBytes = [UInt8](repeating: 0, count: Int(length))
        let messageRead = recv(socketFD, &messageBytes, Int(length), MSG_WAITALL)

        guard messageRead == Int(length) else {
            throw IPCError.receiveFailed("Failed to read message body")
        }

        return Data(messageBytes)
    }

    /// Send a message and wait for a response
    /// - Parameter data: The message to send
    /// - Returns: The response data
    func sendAndReceive(_ data: Data) throws -> Data {
        try send(data)
        return try receive()
    }
}
