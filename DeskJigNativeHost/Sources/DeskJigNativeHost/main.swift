//  main.swift
//  DeskJigNativeHost

//  Native messaging host for Chrome extension integration.
//
//  This CLI is launched by Chrome when the DeskJig extension connects.
//  It bridges messages between Chrome (via stdin/stdout) and DeskJig.app (via Unix socket).
//
//  Message flow:
//  Chrome Extension ←→ DeskJigNativeHost (this CLI) ←→ DeskJig.app
//       stdin/stdout           Unix domain socket
//
//  NOTE: the shipped executable is still named `BentoNativeHost` — the Chrome
//  native-messaging manifest (`com.bento.native.json`) hardcodes that binary path
//  and the host id `com.bento.native`. Both are frozen legacy identifiers.

import Foundation

// MARK: - Message Types

/// Message received from Chrome extension
struct ChromeMessage: Codable {
    let type: String
    let requestId: String?
    let payload: String?  // JSON string for complex payloads
}

/// Response sent back to Chrome extension
struct HostResponse: Codable {
    let type: String
    let requestId: String?
    let success: Bool
    let data: String?     // JSON string for response data
    let error: String?
}

// MARK: - Main Entry Point

func main() {
    NativeMessagingProtocol.log("Starting DeskJigNativeHost")

    // Try to connect to DeskJig.app
    let ipcClient = IPCClient()
    var isConnectedToDeskJig = false

    do {
        try ipcClient.connect()
        isConnectedToDeskJig = true
    } catch {
        NativeMessagingProtocol.log("Warning: Could not connect to DeskJig.app: \(error.localizedDescription)")
        NativeMessagingProtocol.log("Will forward messages when connection is available")
    }

    // Send initial connection status to Chrome.
    // WIRE FORMAT: the `connected` key is read by the extension (background.js
    // `case 'status'`) — frozen, do not rebrand.
    let statusResponse = HostResponse(
        type: "status",
        requestId: nil,
        success: true,
        data: "{\"connected\": \(isConnectedToDeskJig)}",
        error: nil
    )
    NativeMessagingProtocol.writeMessage(statusResponse)

    // Main message loop using select() to monitor both stdin and socket
    NativeMessagingProtocol.log("Entering message loop (bidirectional)")

    let stdinFd: Int32 = STDIN_FILENO
    var running = true

    while running {
        // Set up file descriptor sets for select()
        var readSet = fd_set()
        fdZero(&readSet)

        // Always monitor stdin
        fdSet(stdinFd, &readSet)

        // Monitor socket if connected
        let socketFd = ipcClient.socketFileDescriptor
        var maxFd = stdinFd
        if socketFd >= 0 && isConnectedToDeskJig {
            fdSet(socketFd, &readSet)
            maxFd = max(maxFd, socketFd)
        }

        // Wait for data on either stdin or socket (with 1 second timeout to check connection)
        var timeout = timeval(tv_sec: 1, tv_usec: 0)
        let result = select(maxFd + 1, &readSet, nil, nil, &timeout)

        if result < 0 {
            // select() error
            if errno == EINTR { continue }  // Interrupted, retry
            NativeMessagingProtocol.log("select() error: \(String(cString: strerror(errno)))")
            break
        }

        if result == 0 {
            // Timeout - check if we need to reconnect
            if !isConnectedToDeskJig && ipcClient.socketFileDescriptor < 0 {
                do {
                    try ipcClient.connect()
                    isConnectedToDeskJig = true
                    NativeMessagingProtocol.log("Reconnected to DeskJig.app")
                } catch {
                    // Still not connected, will retry next loop
                }
            }
            continue
        }

        // Check for data from stdin (Chrome)
        if fdIsSet(stdinFd, &readSet) {
            if let messageData = NativeMessagingProtocol.readMessage() {
                handleMessage(messageData, ipcClient: ipcClient, isConnectedToDeskJig: &isConnectedToDeskJig)
            } else {
                // stdin closed
                NativeMessagingProtocol.log("stdin closed")
                running = false
            }
        }

        // Check for data from socket (DeskJig.app)
        if socketFd >= 0 && isConnectedToDeskJig && fdIsSet(socketFd, &readSet) {
            do {
                let socketData = try ipcClient.receive()
                // Forward message from DeskJig.app to Chrome
                NativeMessagingProtocol.writeMessage(socketData)
                NativeMessagingProtocol.log("Forwarded message from DeskJig.app to Chrome")
            } catch {
                NativeMessagingProtocol.log("Socket read error: \(error.localizedDescription)")
                isConnectedToDeskJig = false
                ipcClient.disconnect()
            }
        }
    }

    // Clean up
    NativeMessagingProtocol.log("Shutting down")
    ipcClient.disconnect()
}

// MARK: - fd_set helpers for select() (Darwin/macOS compatible)

private func fdZero(_ set: inout fd_set) {
    // Darwin's fd_set uses fds_bits as Int32 array
    withUnsafeMutableBytes(of: &set) { ptr in
        ptr.initializeMemory(as: UInt8.self, repeating: 0)
    }
}

private func fdSet(_ fd: Int32, _ set: inout fd_set) {
    // Darwin uses Int32 for fds_bits elements
    let bits = __DARWIN_NFDBITS  // Usually 32 on Darwin
    let intOffset = Int(fd) / bits
    let bitOffset = Int(fd) % bits

    withUnsafeMutablePointer(to: &set) { setPtr in
        setPtr.withMemoryRebound(to: Int32.self, capacity: Int(__DARWIN_FD_SETSIZE) / bits) { bitsPtr in
            bitsPtr[intOffset] |= Int32(1 << bitOffset)
        }
    }
}

private func fdIsSet(_ fd: Int32, _ set: inout fd_set) -> Bool {
    let bits = __DARWIN_NFDBITS
    let intOffset = Int(fd) / bits
    let bitOffset = Int(fd) % bits

    return withUnsafePointer(to: &set) { setPtr in
        setPtr.withMemoryRebound(to: Int32.self, capacity: Int(__DARWIN_FD_SETSIZE) / bits) { bitsPtr in
            (bitsPtr[intOffset] & Int32(1 << bitOffset)) != 0
        }
    }
}

// Darwin constants
private let __DARWIN_NFDBITS = 32  // Number of bits per Int32
private let __DARWIN_FD_SETSIZE: Int32 = 1024

// MARK: - Message Handling

func handleMessage(_ data: Data, ipcClient: IPCClient, isConnectedToDeskJig: inout Bool) {
    // Parse the message from Chrome
    guard let message = try? JSONDecoder().decode(ChromeMessage.self, from: data) else {
        NativeMessagingProtocol.log("Failed to parse message from Chrome")
        sendError(requestId: nil, error: "Invalid message format")
        return
    }

    NativeMessagingProtocol.log("Received message: type=\(message.type), requestId=\(message.requestId ?? "nil")")

    // Handle special messages locally
    switch message.type {
    case "ping":
        // Heartbeat from extension
        let response = HostResponse(
            type: "pong",
            requestId: message.requestId,
            success: true,
            data: nil,
            error: nil
        )
        NativeMessagingProtocol.writeMessage(response)
        return

    case "getStatus":
        // Return connection status.
        // WIRE FORMAT: `connectedToBento` crosses the boundary to the Chrome
        // extension — frozen legacy key, do not rebrand.
        let response = HostResponse(
            type: "status",
            requestId: message.requestId,
            success: true,
            data: "{\"connectedToBento\": \(isConnectedToDeskJig)}",
            error: nil
        )
        NativeMessagingProtocol.writeMessage(response)
        return

    case "reconnect":
        // Try to reconnect to DeskJig.app
        if !isConnectedToDeskJig {
            do {
                try ipcClient.connect()
                isConnectedToDeskJig = true
                let response = HostResponse(
                    type: "reconnected",
                    requestId: message.requestId,
                    success: true,
                    data: nil,
                    error: nil
                )
                NativeMessagingProtocol.writeMessage(response)
            } catch {
                sendError(requestId: message.requestId, error: error.localizedDescription)
            }
        } else {
            let response = HostResponse(
                type: "reconnected",
                requestId: message.requestId,
                success: true,
                data: "{\"alreadyConnected\": true}",
                error: nil
            )
            NativeMessagingProtocol.writeMessage(response)
        }
        return

    case "response", "error":
        // These are responses to commands that DeskJig.app sent to Chrome
        // Forward them without expecting a reply (they ARE the reply)
        if isConnectedToDeskJig {
            do {
                try ipcClient.send(data)
                NativeMessagingProtocol.log("Forwarded \(message.type) to DeskJig.app")
            } catch {
                NativeMessagingProtocol.log("Failed to forward \(message.type): \(error.localizedDescription)")
            }
        }
        return

    default:
        break
    }

    // Forward all other messages to DeskJig.app
    if !isConnectedToDeskJig {
        // Try to connect if not connected
        do {
            try ipcClient.connect()
            isConnectedToDeskJig = true
        } catch {
            sendError(requestId: message.requestId, error: "Not connected to DeskJig.app: \(error.localizedDescription)")
            return
        }
    }

    // Forward to DeskJig.app and relay response
    do {
        let responseData = try ipcClient.sendAndReceive(data)

        // Write the response directly to Chrome (it's already in the right format)
        NativeMessagingProtocol.writeMessage(responseData)
    } catch {
        NativeMessagingProtocol.log("IPC error: \(error.localizedDescription)")

        // Mark as disconnected and try to reconnect next time
        if case IPCError.notConnected = error {
            isConnectedToDeskJig = false
        } else if case IPCError.sendFailed = error {
            isConnectedToDeskJig = false
            ipcClient.disconnect()
        } else if case IPCError.receiveFailed = error {
            isConnectedToDeskJig = false
            ipcClient.disconnect()
        }

        sendError(requestId: message.requestId, error: error.localizedDescription)
    }
}

func sendError(requestId: String?, error: String) {
    let response = HostResponse(
        type: "error",
        requestId: requestId,
        success: false,
        data: nil,
        error: error
    )
    NativeMessagingProtocol.writeMessage(response)
}

// MARK: - Run

main()
