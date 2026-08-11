//  WorkspaceJSONDateCoding.swift
//  DeskJigCLI

import Foundation

/// Tolerant date decoding for workspace JSON files produced by different DeskJigCLI code paths.
///
/// Some CLI commands (e.g. `--create-test-workspaces`) historically wrote dates using the
/// JSONEncoder default (secondsSinceReferenceDate numeric), while the import/restore commands
/// decoded with `.iso8601` only. This strategy accepts both so that:
///   - Newly-created workspace JSON (now encoded as ISO8601 strings, see
///     `WorkspaceJSONDateCoding.encodingStrategy`) round-trips correctly.
///   - Previously-exported workspace JSON files (numeric secondsSince2001 dates) still import
///     without any manual transformation.
enum WorkspaceJSONDateCoding {
    /// Encoding strategy used by all DeskJigCLI commands that write workspace JSON to a file.
    static let encodingStrategy: JSONEncoder.DateEncodingStrategy = .iso8601

    /// Decoding strategy used by all DeskJigCLI commands that read workspace JSON from a file.
    /// Tries ISO8601 (with and without fractional seconds) first, then falls back to a numeric
    /// secondsSinceReferenceDate value for backward compatibility with older exports.
    static let decodingStrategy: JSONDecoder.DateDecodingStrategy = .custom { decoder in
        let container = try decoder.singleValueContainer()

        if let string = try? container.decode(String.self) {
            let withFractionalSeconds = ISO8601DateFormatter()
            withFractionalSeconds.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = withFractionalSeconds.date(from: string) {
                return date
            }

            let standard = ISO8601DateFormatter()
            if let date = standard.date(from: string) {
                return date
            }

            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Expected date string to be ISO8601-formatted, got: \(string)"
            )
        }

        if let seconds = try? container.decode(Double.self) {
            return Date(timeIntervalSinceReferenceDate: seconds)
        }

        throw DecodingError.dataCorruptedError(
            in: container,
            debugDescription: "Expected an ISO8601 date string or a secondsSinceReferenceDate numeric value"
        )
    }
}
