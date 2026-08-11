//
//  GUIRestoreParityRunner.swift
//  DeskJig
//

import Foundation
import DeskJigShared

/// Runs one or more in-app workspace restores and writes a JSON report to a
/// caller-chosen path. Compiled in all configurations: DEBUG builds expose it
/// unconditionally via bento://restore; Release builds only reach it when the
/// hidden BentoAllowAppRestoreURL defaults flag is set (see AppDelegate).
@MainActor
final class GUIRestoreParityRunner {
    struct IterationResult: Codable {
        let workspace: String
        let runId: String
        let success: Bool
        let windowsRestored: Int
        let windowsFailed: Int
    }

    struct Report: Codable {
        let startedAt: String
        let finishedAt: String
        let appPid: Int32
        let appExecutable: String
        let iterations: [IterationResult]
        let notes: [String]
    }

    private let dateFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    func run(
        workspaceNames: [String],
        iterations: Int,
        sleepMs: Int,
        outputPath: String?,
        windowManager: WindowManager?
    ) async {
        let startedAt = Date()
        let outputURL = resolveOutputURL(path: outputPath)

        var reportIterations: [IterationResult] = []
        var notes: [String] = []

        guard let windowManager else {
            notes.append("WindowManager unavailable in AppDelegate")
            writeReport(
                Report(
                    startedAt: dateFormatter.string(from: startedAt),
                    finishedAt: dateFormatter.string(from: Date()),
                    appPid: ProcessInfo.processInfo.processIdentifier,
                    appExecutable: Bundle.main.executableURL?.path ?? ProcessInfo.processInfo.arguments.first ?? "unknown",
                    iterations: reportIterations,
                    notes: notes
                ),
                to: outputURL
            )
            return
        }

        windowManager.reloadWorkspaces()

        let availableWorkspaces = windowManager.savedWorkspaces
        let workspaceByName = Dictionary(
            availableWorkspaces.map { ($0.name, $0) },
            uniquingKeysWith: { first, _ in first }
        )

        var runnableWorkspaceNames: [String] = []
        for name in workspaceNames {
            if workspaceByName[name] != nil {
                runnableWorkspaceNames.append(name)
            } else {
                notes.append("Workspace not found: \(name)")
            }
        }

        guard !runnableWorkspaceNames.isEmpty else {
            notes.append("No workspace to run")
            writeReport(
                Report(
                    startedAt: dateFormatter.string(from: startedAt),
                    finishedAt: dateFormatter.string(from: Date()),
                    appPid: ProcessInfo.processInfo.processIdentifier,
                    appExecutable: Bundle.main.executableURL?.path ?? ProcessInfo.processInfo.arguments.first ?? "unknown",
                    iterations: reportIterations,
                    notes: notes
                ),
                to: outputURL
            )
            return
        }

        let safeIterations = max(1, iterations)
        let safeSleepMs = max(0, sleepMs)

        DeskJigLog.info(
            .restorationExecutor,
            "GUI parity restore runner start",
            fields: [
                "workspaces": runnableWorkspaceNames.joined(separator: ","),
                "iterations": safeIterations,
                "sleepMs": safeSleepMs,
                "output": outputURL.path
            ]
        )

        for index in 0..<safeIterations {
            let workspaceName = runnableWorkspaceNames[index % runnableWorkspaceNames.count]
            guard let workspace = workspaceByName[workspaceName] else {
                notes.append("Workspace became unavailable: \(workspaceName)")
                continue
            }

            DeskJigLog.info(.restorationExecutor, "GUI parity restore iteration \(index + 1)/\(safeIterations)", fields: ["workspace": workspaceName])
            let result = await windowManager.restoreWorkspace(workspace)
            let windowsFailed = result.windowsFailed + result.windowsSkipped

            reportIterations.append(
                IterationResult(
                    workspace: workspaceName,
                    runId: result.runId,
                    success: result.success,
                    windowsRestored: result.windowsRestored,
                    windowsFailed: windowsFailed
                )
            )

            if result.windowsSkipped > 0 {
                notes.append(
                    "runId=\(result.runId) workspace='\(workspaceName)' skipped=\(result.windowsSkipped)"
                )
            }

            if safeSleepMs > 0 && index < safeIterations - 1 {
                guard await Task.sleepUnlessCancelled(nanoseconds: UInt64(safeSleepMs) * 1_000_000) else { break }
            }
        }

        let finishedAt = Date()
        let report = Report(
            startedAt: dateFormatter.string(from: startedAt),
            finishedAt: dateFormatter.string(from: finishedAt),
            appPid: ProcessInfo.processInfo.processIdentifier,
            appExecutable: Bundle.main.executableURL?.path ?? ProcessInfo.processInfo.arguments.first ?? "unknown",
            iterations: reportIterations,
            notes: notes
        )

        writeReport(report, to: outputURL)
        DeskJigLog.info(.restorationExecutor, "GUI parity restore runner complete", fields: ["output": outputURL.path, "runs": reportIterations.count])
    }

    /// Directories a caller-supplied `output` report path may live under.
    /// bento://restore is openable by any local process, so the destination is
    /// restricted to scratch/log locations.
    ///
    /// Each root is kept in two spellings. The Foundation-canonical form
    /// (via `canonicalizedForOutputCheck`, which strips the `/private` alias:
    /// `/private/tmp` -> `/tmp`) matches candidate path *strings*, which go
    /// through the same canonicalization. The kernel-canonical `realpath`
    /// form (`/private/tmp`, `/private/var/folders/...`) matches what
    /// `F_GETPATH` reports for an opened vnode in `writeDataSecurely`.
    /// Without the second spelling, every write under /tmp or $TMPDIR failed
    /// the write-time re-check (fail-closed): the opened ancestor's real path
    /// is `/private/tmp/...` while the root had canonicalized to `/tmp`.
    private static let allowedOutputRoots: [URL] = {
        let bases = [
            URL(fileURLWithPath: "/private/tmp", isDirectory: true),
            URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true),
            BundleIdentity.logDirectoryURL
        ]
        var roots = bases.map(canonicalizedForOutputCheck)
        for base in bases {
            var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
            guard realpath(base.path, &buffer) != nil else { continue }
            let real = URL(fileURLWithPath: String(cString: buffer), isDirectory: true)
            if !roots.contains(where: { $0.pathComponents == real.pathComponents }) {
                roots.append(real)
            }
        }
        return roots
    }()

    private func resolveOutputURL(path: String?) -> URL {
        let timestamp = Int(Date().timeIntervalSince1970 * 1000)
        let defaultURL = URL(fileURLWithPath: "/tmp/deskjig-gui-restore-\(timestamp).json")

        guard let path, !path.isEmpty else { return defaultURL }

        let expanded = (path as NSString).expandingTildeInPath
        guard let validated = Self.validatedOutputURL(URL(fileURLWithPath: expanded)) else {
            DeskJigLog.warn(
                .restorationExecutor,
                "GUI parity report path outside allowed directories; using default",
                fields: ["requested": path, "fallback": defaultURL.path]
            )
            return defaultURL
        }
        return validated
    }

    /// Canonicalizes `candidate` and requires it to sit strictly inside one of
    /// `allowedOutputRoots`. This is a first-line, best-effort check for logging
    /// and default-fallback UX only; it is NOT the security boundary. Because it
    /// resolves a path *string* against the filesystem, an attacker can swap a
    /// parent-directory symlink between this check and the eventual write
    /// (TOCTOU). The authoritative check happens at write time in
    /// `writeDataSecurely`, which operates on opened directory vnodes.
    private static func validatedOutputURL(_ candidate: URL) -> URL? {
        // A NUL truncates the path when it crosses into C string APIs
        // (fileExists/open/mkdirat/...), so a path containing one never means
        // what the Swift-level checks validated. Reject before any filesystem
        // probe; writeDataSecurely re-checks per component as the backstop.
        guard !candidate.path.contains("\u{0}") else { return nil }
        let resolved = canonicalizedForOutputCheck(candidate)
        return isWithinAllowedRoot(resolved.pathComponents, allowEqual: false) ? resolved : nil
    }

    /// Component-wise prefix check against `allowedOutputRoots`. Component-wise
    /// so `/private/tmpevil` never matches `/private/tmp`. When `allowEqual` is
    /// false the path must sit strictly inside a root (a report file);
    /// when true the path may also equal a root (a directory that *is* a root).
    private static func isWithinAllowedRoot(_ components: [String], allowEqual: Bool) -> Bool {
        for root in allowedOutputRoots {
            let rootComponents = root.pathComponents
            let deepEnough = allowEqual
                ? components.count >= rootComponents.count
                : components.count > rootComponents.count
            if deepEnough, Array(components.prefix(rootComponents.count)) == rootComponents {
                return true
            }
        }
        return false
    }

    /// Standardizes the URL (collapsing `..` lexically before any comparison),
    /// then resolves symlinks via the deepest existing ancestor.
    /// `resolvingSymlinksInPath()` alone is not enough: it leaves existing
    /// intermediate symlinks unresolved when the leaf does not exist yet
    /// (the usual case for a report file), and its /private-prefix handling
    /// is existence-dependent. Resolving the deepest existing ancestor and
    /// re-appending the not-yet-created components (already `..`-free after
    /// standardization) closes both gaps.
    private static func canonicalizedForOutputCheck(_ url: URL) -> URL {
        let standardized = url.standardizedFileURL
        var existing = standardized
        var missingComponents: [String] = []
        while existing.pathComponents.count > 1,
              !FileManager.default.fileExists(atPath: existing.path) {
            missingComponents.append(existing.lastPathComponent)
            existing = existing.deletingLastPathComponent()
        }

        var resolved = existing.resolvingSymlinksInPath()
        for component in missingComponents.reversed() {
            resolved.appendPathComponent(component)
        }
        return resolved
    }

    private func writeReport(_ report: Report, to url: URL) {
        let data: Data
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            data = try encoder.encode(report)
        } catch {
            DeskJigLog.error(.restorationExecutor, "Failed encoding GUI parity report", fields: ["path": url.path, "error": error.localizedDescription])
            return
        }
        do {
            try Self.writeDataSecurely(data, to: url)
        } catch {
            DeskJigLog.error(.restorationExecutor, "Failed writing GUI parity report", fields: ["path": url.path, "error": "\(error)"])
        }
    }

    private enum SecureWriteError: Error, CustomStringConvertible {
        case invalidPath(String)
        case escapesAllowlist(String)
        case openFailed(path: String, errno: Int32)
        case writeFailed(errno: Int32)
        case shortWrite(written: Int, expected: Int)
        case renameFailed(from: String, to: String, errno: Int32)

        var description: String {
            switch self {
            case .invalidPath(let detail):
                return "invalid output path: \(detail)"
            case .escapesAllowlist(let real):
                return "resolved path escaped the allowlist at write time: \(real)"
            case .openFailed(let path, let code):
                return "open failed for '\(path)': \(String(cString: strerror(code))) (\(code))"
            case .writeFailed(let code):
                return "write failed: \(String(cString: strerror(code))) (\(code))"
            case .shortWrite(let written, let expected):
                return "short write: \(written) of \(expected) bytes"
            case .renameFailed(let from, let to, let code):
                return "rename '\(from)' -> '\(to)' failed: \(String(cString: strerror(code))) (\(code))"
            }
        }
    }

    /// Writes `data` to `url` in a way that is immune to parent-directory symlink
    /// TOCTOU races. Rather than trusting the path *string* (which the kernel
    /// re-resolves, following any freshly-planted symlink, on every syscall), we:
    ///   1. open the deepest existing ancestor directory and confirm its *real*
    ///      location via `F_GETPATH` on the opened vnode — a value an attacker
    ///      cannot alter by swapping a symlink after the `open`;
    ///   2. create and descend any missing intermediate components with
    ///      `O_NOFOLLOW`, so a symlink planted for a not-yet-existing component
    ///      is rejected rather than traversed;
    ///   3. re-confirm the final parent's real path sits inside the allowlist; and
    ///   4. write to a fresh temp file created with `openat(..., O_EXCL |
    ///      O_NOFOLLOW)` relative to that verified directory fd, then
    ///      `renameat` it over the leaf. `O_EXCL` refuses any pre-planted
    ///      leaf-name entry (symlink *or* hard link — `O_NOFOLLOW | O_TRUNC`
    ///      alone would truncate whatever inode a hard link points at), and
    ///      the rename replaces the directory *entry* atomically without ever
    ///      writing through an attacker-chosen inode. Because both syscalls
    ///      are anchored to the verified fd, a parent directory renamed out
    ///      of the allowlist after the check cannot redirect the write via
    ///      path re-resolution either.
    /// Every filesystem operation is anchored to a descriptor we opened and
    /// validated, never to a re-resolvable string, closing the gap the string
    /// allowlist check alone left open.
    private static func writeDataSecurely(_ data: Data, to url: URL) throws {
        var dirComponents = url.standardizedFileURL.pathComponents
        guard dirComponents.first == "/", dirComponents.count >= 2 else {
            throw SecureWriteError.invalidPath("not an absolute file path")
        }
        // NUL bytes truncate the component once it crosses into C string APIs
        // (fileExists/open/mkdirat/openat/renameat), so e.g. "..\0x" would pass
        // the Swift-level ".." checks yet act as ".." at the syscall. Reject
        // every component before the first filesystem call.
        guard !dirComponents.contains(where: { $0.contains("\u{0}") }) else {
            throw SecureWriteError.invalidPath("NUL byte in path component")
        }
        let leaf = dirComponents.removeLast()
        guard !leaf.isEmpty, leaf != "/", leaf != ".", leaf != "..",
              !leaf.contains("/"), !leaf.contains("\u{0}") else {
            throw SecureWriteError.invalidPath("unsafe leaf component '\(leaf)'")
        }

        // Split the directory portion into its deepest existing ancestor and the
        // trailing components that still need to be created.
        let fileManager = FileManager.default
        var existingCount = dirComponents.count
        var missing: [String] = []
        while existingCount > 1 {
            let path = NSString.path(withComponents: Array(dirComponents.prefix(existingCount)))
            if fileManager.fileExists(atPath: path) { break }
            missing.insert(dirComponents[existingCount - 1], at: 0)
            existingCount -= 1
        }
        let existingPath = NSString.path(withComponents: Array(dirComponents.prefix(existingCount)))

        // Open the existing ancestor. This may traverse legitimate symlinks
        // (e.g. /tmp -> /private/tmp); F_GETPATH below reports the real target
        // so any escape is caught regardless of how many symlinks were followed.
        var dirFd = open(existingPath, O_RDONLY | O_DIRECTORY)
        guard dirFd >= 0 else { throw SecureWriteError.openFailed(path: existingPath, errno: errno) }
        defer { close(dirFd) }

        let ancestorReal = try realPath(ofFd: dirFd)
        guard isWithinAllowedRoot(URL(fileURLWithPath: ancestorReal, isDirectory: true).pathComponents, allowEqual: true) else {
            throw SecureWriteError.escapesAllowlist(ancestorReal)
        }

        // Create and descend each missing component without following symlinks.
        for component in missing {
            guard component != ".", component != "..", !component.contains("/"),
                  !component.contains("\u{0}"), !component.isEmpty else {
                throw SecureWriteError.invalidPath("unsafe path component '\(component)'")
            }
            // Best-effort create; EEXIST is fine. A symlink planted here is not
            // traversed because the openat below uses O_NOFOLLOW.
            _ = mkdirat(dirFd, component, 0o755)
            let childFd = openat(dirFd, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
            guard childFd >= 0 else { throw SecureWriteError.openFailed(path: component, errno: errno) }
            close(dirFd)
            dirFd = childFd
        }

        // Defense in depth: re-confirm the final parent's real path is in bounds.
        let parentReal = try realPath(ofFd: dirFd)
        let fullComponents = URL(fileURLWithPath: parentReal, isDirectory: true)
            .appendingPathComponent(leaf).pathComponents
        guard isWithinAllowedRoot(fullComponents, allowEqual: false) else {
            throw SecureWriteError.escapesAllowlist(NSString.path(withComponents: [parentReal, leaf]))
        }

        try writeAtomicallyRelative(to: dirFd, leaf: leaf, data: data)
    }

    /// Writes `data` to `leaf` inside the already-verified directory `dirFd`
    /// via a temp file plus `renameat`, both relative to that fd:
    ///   - the temp is created `O_EXCL | O_NOFOLLOW` under an unpredictable
    ///     name, so a pre-planted hard link or symlink at the temp name is
    ///     refused (retrying with a fresh name on EEXIST);
    ///   - `renameat` then atomically replaces the leaf's directory *entry*.
    ///     Unlike `O_TRUNC` on the leaf itself, this never writes through an
    ///     existing inode, so a hard link pre-planted at the leaf name cannot
    ///     redirect the report's bytes into its target — the link's inode is
    ///     left untouched and the entry now points at our fresh file. The
    ///     poller also never observes a partially-written report.
    /// On any failure after the temp file exists it is unlinked (relative to
    /// `dirFd`) so no temp litter is left behind.
    private static func writeAtomicallyRelative(to dirFd: Int32, leaf: String, data: Data) throws {
        var tempFd: Int32 = -1
        var tempName = ""
        for _ in 0..<32 where tempFd < 0 {
            tempName = ".\(leaf).tmp.\(ProcessInfo.processInfo.processIdentifier)." +
                String(format: "%016llx", UInt64.random(in: .min ... .max))
            tempFd = openat(dirFd, tempName, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
            if tempFd < 0 && errno != EEXIST {
                throw SecureWriteError.openFailed(path: tempName, errno: errno)
            }
        }
        guard tempFd >= 0 else { throw SecureWriteError.openFailed(path: tempName, errno: EEXIST) }

        do {
            try writeAll(fd: tempFd, data: data)
            // Match the report's historical on-disk mode now that the bytes are
            // in place; best-effort, same-user readers only need 0o600 anyway.
            _ = fchmod(tempFd, 0o644)
            guard fsync(tempFd) == 0 else { throw SecureWriteError.writeFailed(errno: errno) }
            guard close(tempFd) == 0 else {
                tempFd = -1
                throw SecureWriteError.writeFailed(errno: errno)
            }
            tempFd = -1
            guard renameat(dirFd, tempName, dirFd, leaf) == 0 else {
                throw SecureWriteError.renameFailed(from: tempName, to: leaf, errno: errno)
            }
        } catch {
            if tempFd >= 0 { close(tempFd) }
            _ = unlinkat(dirFd, tempName, 0)
            throw error
        }
    }

    /// Canonical path of the vnode `fd` refers to. Immune to symlink swaps made
    /// after the descriptor was opened, which is what makes the write safe.
    private static func realPath(ofFd fd: Int32) throws -> String {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        guard fcntl(fd, F_GETPATH, &buffer) == 0 else {
            throw SecureWriteError.openFailed(path: "F_GETPATH", errno: errno)
        }
        return String(cString: buffer)
    }

    private static func writeAll(fd: Int32, data: Data) throws {
        guard !data.isEmpty else { return }
        try data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.baseAddress else { return }
            var offset = 0
            while offset < raw.count {
                let written = write(fd, base.advanced(by: offset), raw.count - offset)
                if written < 0 {
                    if errno == EINTR { continue }
                    throw SecureWriteError.writeFailed(errno: errno)
                }
                if written == 0 {
                    // A 0-byte write on a regular file should not happen; if it
                    // does, silently returning would leave a truncated report.
                    throw SecureWriteError.shortWrite(written: offset, expected: raw.count)
                }
                offset += written
            }
        }
    }
}
