//  NativeMessagingProtocol.swift
//  DeskJigNativeHost

import Foundation

/// Chrome Native Messaging Protocol handler
///
/// Protocol format:
/// - First 4 bytes: message length as little-endian UInt32
/// - Remaining bytes: JSON message payload
///
/// Messages are read from stdin and written to stdout.
enum NativeMessagingProtocol {

    /// Maximum allowed message size (1MB - Chrome's limit)
    static let maxMessageSize: UInt32 = 1024 * 1024

    // MARK: - Reading

    /// Read a single message from stdin
    /// - Returns: The message data, or nil if stdin is closed or an error occurred
    static func readMessage() -> Data? {
        // Read 4-byte length prefix
        var lengthBytes = [UInt8](repeating: 0, count: 4)
        let bytesRead = fread(&lengthBytes, 1, 4, stdin)

        guard bytesRead == 4 else {
            // stdin closed or error
            return nil
        }

        // Parse as little-endian UInt32
        let length = UInt32(lengthBytes[0]) |
                     (UInt32(lengthBytes[1]) << 8) |
                     (UInt32(lengthBytes[2]) << 16) |
                     (UInt32(lengthBytes[3]) << 24)

        guard length > 0 && length <= maxMessageSize else {
            log("Invalid message length: \(length)")
            return nil
        }

        // Read message body
        var messageBytes = [UInt8](repeating: 0, count: Int(length))
        let messageRead = fread(&messageBytes, 1, Int(length), stdin)

        guard messageRead == Int(length) else {
            log("Failed to read full message: got \(messageRead) of \(length) bytes")
            return nil
        }

        return Data(messageBytes)
    }

    // MARK: - Writing

    /// Write a message to stdout
    /// - Parameter data: The message data to write
    static func writeMessage(_ data: Data) {
        let length = UInt32(data.count)

        guard length <= maxMessageSize else {
            log("Message too large to send: \(length) bytes")
            return
        }

        // Write 4-byte length prefix (little-endian)
        var lengthBytes: [UInt8] = [
            UInt8(length & 0xFF),
            UInt8((length >> 8) & 0xFF),
            UInt8((length >> 16) & 0xFF),
            UInt8((length >> 24) & 0xFF)
        ]

        fwrite(&lengthBytes, 1, 4, stdout)

        // Write message body
        _ = data.withUnsafeBytes { buffer in
            fwrite(buffer.baseAddress, 1, data.count, stdout)
        }

        // Flush to ensure Chrome receives the message immediately
        fflush(stdout)
    }

    /// Write a JSON-encodable message to stdout
    /// - Parameter message: The message to encode and write
    static func writeMessage<T: Encodable>(_ message: T) {
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(message)
            writeMessage(data)
        } catch {
            log("Failed to encode message: \(error)")
        }
    }

    // MARK: - Logging

    /// Log to stderr (doesn't interfere with native messaging on stdout)
    static func log(_ message: String) {
        let timestamp = ISO8601DateFormatter().string(from: Date())
        fputs("[\(timestamp)] DeskJigNativeHost: \(message)\n", stderr)
    }
}
