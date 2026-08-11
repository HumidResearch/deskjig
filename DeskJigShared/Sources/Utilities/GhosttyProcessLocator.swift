//
//  GhosttyProcessLocator.swift
//  DeskJigShared
//
//  Shared helper for locating Ghostty process IDs.
//

import Foundation

public enum GhosttyProcessLocator {
    /// Get Ghostty process IDs using `ps`, which is more reliable than `pgrep` for bundle paths.
    public static func findPIDs() -> [pid_t] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-axo", "pid,comm"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return []
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard let output = String(data: data, encoding: .utf8) else {
            return []
        }

        return output.split(separator: "\n").compactMap { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let parts = trimmed.split(separator: " ", maxSplits: 1)
            guard parts.count == 2,
                  let pid = pid_t(parts[0]),
                  parts[1].lowercased().contains("ghostty") else {
                return nil
            }
            return pid
        }
    }
}
