//  DeskJigCLIInvocationTestSupport.swift
//  DeskJigSharedTests

import Foundation

enum DeskJigCLIInvocationTestSupport {
    private final class BundleToken {}

    /// Result of a `bentoctl` invocation, with stdout and stderr kept separate.
    ///
    /// Keep JSON parsing on `stdout` only: bentoctl prints its JSON envelope (and
    /// any error text, embedded in the envelope's `error` field) to stdout, then
    /// `fflush(stdout)` + `Foundation.exit()`. Any stray byte on stderr (framework
    /// noise under parallel suite load, verbose logging, etc.) previously got
    /// concatenated onto stdout and made `JSONSerialization` fail with
    /// "Garbage at end". Use `merged` only for `.contains()` assertions on
    /// human-readable text, never for JSON parsing.
    struct Result {
        let status: Int32
        let stdout: String
        let stderr: String

        /// stdout and stderr joined with a newline (matches the historical merge
        /// behavior). Safe for substring assertions; never JSON-parse this.
        var merged: String {
            stdout + (stdout.isEmpty || stderr.isEmpty ? "" : "\n") + stderr
        }
    }

    /// Locate the `bentoctl` executable under test.
    ///
    /// Upstream this resolved relative to the app-hosted XCTest bundle, where
    /// `bentoctl` sat next to the host app at `Contents/MacOS/bentoctl`. The
    /// SwiftPM test bundle has no host app, and `bentoctl` is built by a separate
    /// Xcode project outside this package — so the suites that spawn it are gated
    /// (see `TestEnvironment`) and take the path from `DESKJIG_BENTOCTL` when set.
    /// The bundle-relative layout is kept as the fallback for the app-hosted lane.
    static func bentoctlURL() -> URL {
        if let override = ProcessInfo.processInfo.environment["DESKJIG_BENTOCTL"], !override.isEmpty {
            return URL(fileURLWithPath: override)
        }
        let testBundleURL = Bundle(for: BundleToken.self).bundleURL
        return testBundleURL
            .deletingLastPathComponent()   // PlugIns
            .deletingLastPathComponent()   // Contents
            .appendingPathComponent("MacOS")
            .appendingPathComponent("bentoctl")
    }

    static func run(
        _ arguments: [String],
        input: String? = nil,
        environment: [String: String] = [:]
    ) throws -> Result {
        let process = Process()
        process.executableURL = bentoctlURL()
        process.arguments = arguments
        if !environment.isEmpty {
            process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }
        }

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        if let input {
            let stdin = Pipe()
            process.standardInput = stdin
            try process.run()
            if let data = input.data(using: .utf8) {
                stdin.fileHandleForWriting.write(data)
            }
            stdin.fileHandleForWriting.closeFile()
        } else {
            try process.run()
        }
        process.waitUntilExit()

        let outData = stdout.fileHandleForReading.readDataToEndOfFile()
        let errData = stderr.fileHandleForReading.readDataToEndOfFile()

        let out = String(data: outData, encoding: .utf8) ?? ""
        let err = String(data: errData, encoding: .utf8) ?? ""

        return Result(status: process.terminationStatus, stdout: out, stderr: err)
    }
}
