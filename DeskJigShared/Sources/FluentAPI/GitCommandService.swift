//  GitCommandService.swift
//  DeskJigShared

import Foundation

// MARK: - Models

/// Information about a git worktree.
public struct WorktreeInfo: Sendable, Identifiable, Hashable {
    public var id: String { path }
    public let path: String
    public let headCommit: String
    public let branch: String?        // nil = detached HEAD
    public let isMain: Bool
    public let isLocked: Bool
    public let isPrunable: Bool

    public init(
        path: String,
        headCommit: String,
        branch: String?,
        isMain: Bool,
        isLocked: Bool = false,
        isPrunable: Bool = false
    ) {
        self.path = path
        self.headCommit = headCommit
        self.branch = branch
        self.isMain = isMain
        self.isLocked = isLocked
        self.isPrunable = isPrunable
    }
}

/// Errors from git command execution.
public enum GitError: Error, LocalizedError {
    case notAvailable
    case timeout(command: String)
    case commandFailed(command: String, exitCode: Int32, stderr: String)
    case notAGitRepository(path: String)
    case branchAlreadyExists(name: String)
    case worktreePathExists(path: String)
    case hasUncommittedChanges(path: String)

    public var errorDescription: String? {
        switch self {
        case .notAvailable:
            return "git is not installed or not found in PATH"
        case .timeout(let command):
            return "git command timed out: \(command)"
        case .commandFailed(let command, let exitCode, let stderr):
            return "git command failed (exit \(exitCode)): \(command)\(stderr.isEmpty ? "" : " - \(stderr)")"
        case .notAGitRepository(let path):
            return "Not a git repository: \(path)"
        case .branchAlreadyExists(let name):
            return "Branch already exists: \(name)"
        case .worktreePathExists(let path):
            return "Worktree path already exists: \(path)"
        case .hasUncommittedChanges(let path):
            return "Uncommitted changes in: \(path)"
        }
    }
}

// MARK: - Git Command Service

/// Actor wrapping all git CLI calls via `Process()`.
///
/// Follows the same pattern as `TmuxCommandService`:
/// - Auto-detects git binary location (Homebrew first, then CLT check)
/// - Uses `Process()` with cleaned environment
/// - 10-second timeout per command
/// - All operations are synchronous on the actor thread (git commands are fast)
public actor GitCommandService {

    // MARK: - Properties

    private var resolvedBinaryPath: String?
    private var availabilityChecked = false

    /// Common git binary locations to search (Homebrew first to avoid CLT dialog)
    private static let binarySearchPaths = [
        "/opt/homebrew/bin/git",
        "/usr/local/bin/git"
    ]

    /// Timeout for each git command in seconds
    private let commandTimeout: TimeInterval = 10.0

    // MARK: - Initialization

    public init() {}

    // MARK: - Availability

    /// Whether git is installed and available on the system.
    public var isAvailable: Bool {
        get async {
            if !availabilityChecked {
                resolvedBinaryPath = Self.findGitBinary()
                availabilityChecked = true
            }
            return resolvedBinaryPath != nil
        }
    }

    // MARK: - Worktree Operations

    /// Lists all worktrees for a repository.
    ///
    /// Runs `git worktree prune` first to clean stale entries, then
    /// `git worktree list --porcelain` to enumerate.
    ///
    /// - Parameter repoPath: Path to the git repository (or any worktree of it)
    /// - Returns: Array of worktree information
    public func listWorktrees(repoPath: String) async throws -> [WorktreeInfo] {
        // Prune stale worktrees first (best-effort: listing still works without it,
        // but a failed prune is worth surfacing since stale entries linger).
        do {
            try runGit(["worktree", "prune"], workingDirectory: repoPath)
        } catch {
            DeskJigLog.warn(.workspace, "git worktree prune failed before listing", fields: [
                "repoPath": repoPath,
                "error": error.localizedDescription
            ])
        }

        let output = try runGitWithOutput(
            ["worktree", "list", "--porcelain"],
            workingDirectory: repoPath
        )

        return parseWorktreeListOutput(output)
    }

    /// Creates a new worktree with a new branch.
    ///
    /// - Parameters:
    ///   - repoPath: Path to the git repository
    ///   - worktreePath: Where to create the worktree directory
    ///   - branchName: Name for the new branch
    ///   - baseBranch: Branch to base the new branch on (e.g., "main")
    /// - Returns: Information about the created worktree
    public func createWorktree(
        repoPath: String,
        worktreePath: String,
        branchName: String,
        baseBranch: String
    ) async throws -> WorktreeInfo {
        let expandedPath = (worktreePath as NSString).expandingTildeInPath

        do {
            try runGit(
                ["worktree", "add", "-b", branchName, expandedPath, baseBranch],
                workingDirectory: repoPath
            )
        } catch let error as GitError {
            if case .commandFailed(_, _, let stderr) = error {
                if stderr.contains("already exists") && stderr.contains("branch") {
                    throw GitError.branchAlreadyExists(name: branchName)
                }
                if stderr.contains("already exists") || stderr.contains("is a worktree") {
                    throw GitError.worktreePathExists(path: expandedPath)
                }
                if stderr.contains("already used by worktree") || stderr.contains("already checked out") {
                    throw GitError.branchAlreadyExists(name: branchName)
                }
            }
            throw error
        }

        // Return info about the newly created worktree
        let worktrees = try await listWorktrees(repoPath: repoPath)
        let normalizedPath = URL(fileURLWithPath: expandedPath).standardizedFileURL.path
        if let created = worktrees.first(where: {
            URL(fileURLWithPath: $0.path).standardizedFileURL.path == normalizedPath
        }) {
            return created
        }

        // Fallback: construct manually
        return WorktreeInfo(
            path: expandedPath,
            headCommit: "",
            branch: branchName,
            isMain: false
        )
    }

    /// Removes a worktree.
    ///
    /// - Parameters:
    ///   - repoPath: Path to the git repository
    ///   - worktreePath: Path of the worktree to remove
    ///   - force: Force removal even with uncommitted changes
    public func removeWorktree(repoPath: String, worktreePath: String, force: Bool = false) async throws {
        var args = ["worktree", "remove"]
        if force { args.append("--force") }
        args.append(worktreePath)
        try runGit(args, workingDirectory: repoPath)
    }

    // MARK: - Branch Operations

    /// Lists local branch names.
    ///
    /// - Parameter repoPath: Path to the git repository
    /// - Returns: Array of branch names
    public func listBranches(repoPath: String) async throws -> [String] {
        let output = try runGitWithOutput(
            ["branch", "--list", "--format=%(refname:short)"],
            workingDirectory: repoPath
        )
        return output.components(separatedBy: "\n").filter { !$0.isEmpty }
    }

    /// Deletes a local branch.
    ///
    /// - Parameters:
    ///   - repoPath: Path to the git repository
    ///   - branchName: Name of the branch to delete
    ///   - force: Force delete (git branch -D) vs safe delete (git branch -d)
    public func deleteBranch(repoPath: String, branchName: String, force: Bool = false) async throws {
        try runGit(
            ["branch", force ? "-D" : "-d", branchName],
            workingDirectory: repoPath
        )
    }

    // MARK: - Repository Introspection

    /// Returns the repository root path.
    ///
    /// - Parameter path: A path inside the repository
    /// - Returns: The absolute path to the repository root
    public func repoRoot(at path: String) async throws -> String {
        try runGitWithOutput(
            ["rev-parse", "--show-toplevel"],
            workingDirectory: path
        )
    }

    /// Checks if a path is inside a worktree (not the main repo).
    ///
    /// Compares `--git-dir` vs `--git-common-dir` — they differ in worktrees.
    ///
    /// - Parameter path: Path to check
    /// - Returns: `true` if the path is a worktree
    public func isWorktree(at path: String) async -> Bool {
        let gitDir: String
        let commonDir: String
        do {
            gitDir = try runGitWithOutput(
                ["rev-parse", "--git-dir"],
                workingDirectory: path
            )
            commonDir = try runGitWithOutput(
                ["rev-parse", "--git-common-dir"],
                workingDirectory: path
            )
        } catch {
            // "not a git repository" is the expected negative for arbitrary paths;
            // anything else (git missing, timeout) would silently report
            // "not a worktree" and is worth a log line.
            if !Self.isNotARepositoryError(error) {
                DeskJigLog.warn(.workspace, "isWorktree git query failed", fields: [
                    "path": path,
                    "error": error.localizedDescription
                ])
            }
            return false
        }

        // Normalize both paths for comparison
        let normalizedGitDir = URL(fileURLWithPath: gitDir, relativeTo: URL(fileURLWithPath: path))
            .standardizedFileURL.path
        let normalizedCommonDir = URL(fileURLWithPath: commonDir, relativeTo: URL(fileURLWithPath: path))
            .standardizedFileURL.path

        return normalizedGitDir != normalizedCommonDir
    }

    /// Returns the main worktree path from a worktree.
    ///
    /// - Parameter path: Path inside a worktree
    /// - Returns: Path to the main repository
    public func mainWorktreePath(at path: String) async throws -> String {
        let commonDir = try runGitWithOutput(
            ["rev-parse", "--git-common-dir"],
            workingDirectory: path
        )

        // --git-common-dir returns the .git directory of the main repo
        // For a worktree, this is something like /path/to/main-repo/.git
        let commonURL = URL(fileURLWithPath: commonDir, relativeTo: URL(fileURLWithPath: path))
            .standardizedFileURL

        // If the common dir ends with .git, the parent is the repo root
        if commonURL.lastPathComponent == ".git" {
            return commonURL.deletingLastPathComponent().path
        }

        // Fallback: use rev-parse --show-toplevel on the common dir parent
        return try runGitWithOutput(
            ["rev-parse", "--show-toplevel"],
            workingDirectory: commonURL.deletingLastPathComponent().path
        )
    }

    /// Checks for uncommitted changes in a repository.
    ///
    /// - Parameter path: Path to the repository or worktree
    /// - Returns: `true` if there are uncommitted changes
    public func hasUncommittedChanges(at path: String) async -> Bool {
        do {
            let output = try runGitWithOutput(
                ["status", "--porcelain"],
                workingDirectory: path
            )
            return !output.isEmpty
        } catch {
            // Callers pass known repo/worktree paths, and a silent `false` here
            // feeds "safe to archive" UI decisions — log any failure.
            DeskJigLog.warn(.workspace, "git status query failed; reporting no uncommitted changes", fields: [
                "path": path,
                "error": error.localizedDescription
            ])
            return false
        }
    }

    /// Validates a branch name using git's own validation.
    ///
    /// - Parameter name: The branch name to validate
    /// - Returns: `true` if the name is valid
    public func validateBranchName(_ name: String) async -> Bool {
        do {
            try runGit(["check-ref-format", "--branch", name], workingDirectory: nil)
            return true
        } catch {
            return false
        }
    }

    // MARK: - Private Helpers

    /// Whether an error is git's expected "not a git repository" failure.
    private static func isNotARepositoryError(_ error: Error) -> Bool {
        if case GitError.commandFailed(_, _, let stderr) = error {
            return stderr.localizedCaseInsensitiveContains("not a git repository")
        }
        return false
    }

    /// Finds the git binary on the system.
    ///
    /// Checks Homebrew paths first (never triggers CLT dialog), then
    /// verifies CLT installation before using `/usr/bin/git`.
    private static func findGitBinary() -> String? {
        // 1. Check Homebrew paths (never triggers CLT dialog)
        for path in binarySearchPaths {
            if FileManager.default.isExecutableFile(atPath: path) {
                return path
            }
        }

        // 2. Check if CLT installed BEFORE touching /usr/bin/git
        //    xcode-select -p does NOT trigger the CLT install dialog
        let xcodeSelect = Process()
        xcodeSelect.executableURL = URL(fileURLWithPath: "/usr/bin/xcode-select")
        xcodeSelect.arguments = ["-p"]
        xcodeSelect.standardOutput = Pipe()
        xcodeSelect.standardError = Pipe()

        do {
            try xcodeSelect.run()
            xcodeSelect.waitUntilExit()
            if xcodeSelect.terminationStatus == 0 {
                let systemGit = "/usr/bin/git"
                if FileManager.default.isExecutableFile(atPath: systemGit) {
                    return systemGit
                }
            }
        } catch {
            // xcode-select not available
        }

        // 3. Fallback: try `which git` via shell
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        process.arguments = ["git"]
        process.environment = gitEnvironment()

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()

        do {
            try process.run()
            process.waitUntilExit()
            if process.terminationStatus == 0 {
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                let path = String(data: data, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if let path, !path.isEmpty, FileManager.default.isExecutableFile(atPath: path) {
                    return path
                }
            }
        } catch {
            // which not found or failed
        }

        return nil
    }

    /// Environment for git commands.
    /// Reuses TmuxCommandService.cleanedEnvironment() and adds GIT_TERMINAL_PROMPT=0.
    private static func gitEnvironment() -> [String: String] {
        var env = TmuxCommandService.cleanedEnvironment()
        env["GIT_TERMINAL_PROMPT"] = "0"
        return env
    }

    /// Runs a git command, discarding output.
    @discardableResult
    private func runGit(_ arguments: [String], workingDirectory: String?) throws -> Int32 {
        guard let binary = resolvedBinaryPath ?? Self.findGitBinary() else {
            throw GitError.notAvailable
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = arguments
        process.environment = Self.gitEnvironment()
        if let workingDirectory {
            process.currentDirectoryURL = URL(fileURLWithPath: workingDirectory)
        }
        process.standardOutput = Pipe()
        let stderrPipe = Pipe()
        process.standardError = stderrPipe

        try process.run()

        // Safety timeout
        let processRef = process
        let timeoutItem = DispatchWorkItem { processRef.terminate() }
        DispatchQueue.global().asyncAfter(deadline: .now() + commandTimeout, execute: timeoutItem)

        process.waitUntilExit()
        timeoutItem.cancel()

        if process.terminationReason == .uncaughtSignal {
            throw GitError.timeout(command: arguments.joined(separator: " "))
        }

        let exitCode = process.terminationStatus
        if exitCode != 0 {
            let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            let stderr = String(data: stderrData, encoding: .utf8) ?? ""
            throw GitError.commandFailed(
                command: arguments.joined(separator: " "),
                exitCode: exitCode,
                stderr: stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }

        return exitCode
    }

    /// Runs a git command and returns stdout.
    private func runGitWithOutput(_ arguments: [String], workingDirectory: String) throws -> String {
        guard let binary = resolvedBinaryPath ?? Self.findGitBinary() else {
            throw GitError.notAvailable
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = arguments
        process.environment = Self.gitEnvironment()
        process.currentDirectoryURL = URL(fileURLWithPath: workingDirectory)

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        try process.run()

        // Safety timeout
        let processRef = process
        let timeoutItem = DispatchWorkItem { processRef.terminate() }
        DispatchQueue.global().asyncAfter(deadline: .now() + commandTimeout, execute: timeoutItem)

        process.waitUntilExit()
        timeoutItem.cancel()

        if process.terminationReason == .uncaughtSignal {
            throw GitError.timeout(command: arguments.joined(separator: " "))
        }

        let exitCode = process.terminationStatus
        if exitCode != 0 {
            let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            let stderr = String(data: stderrData, encoding: .utf8) ?? ""
            throw GitError.commandFailed(
                command: arguments.joined(separator: " "),
                exitCode: exitCode,
                stderr: stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }

        // Drain stderr unconditionally after waitUntilExit()
        _ = stderrPipe.fileHandleForReading.readDataToEndOfFile()

        let data = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        return output
    }

    /// Parses `git worktree list --porcelain` output into WorktreeInfo array.
    ///
    /// Format is blocks separated by blank lines:
    /// ```
    /// worktree /path/to/main
    /// HEAD abc123...
    /// branch refs/heads/main
    ///
    /// worktree /path/to/feature
    /// HEAD def456...
    /// branch refs/heads/feature
    /// ```
    private func parseWorktreeListOutput(_ output: String) -> [WorktreeInfo] {
        let blocks = output.components(separatedBy: "\n\n").filter { !$0.isEmpty }
        var isFirst = true

        return blocks.compactMap { block -> WorktreeInfo? in
            let lines = block.components(separatedBy: "\n")
            var path: String?
            var headCommit: String = ""
            var branch: String?
            var isLocked = false
            var isPrunable = false

            for line in lines {
                if line.hasPrefix("worktree ") {
                    path = String(line.dropFirst("worktree ".count))
                } else if line.hasPrefix("HEAD ") {
                    headCommit = String(line.dropFirst("HEAD ".count))
                } else if line.hasPrefix("branch ") {
                    let refPath = String(line.dropFirst("branch ".count))
                    branch = (refPath as NSString).lastPathComponent
                } else if line == "detached" {
                    branch = nil
                } else if line.hasPrefix("locked") {
                    isLocked = true
                } else if line.hasPrefix("prunable") {
                    isPrunable = true
                }
            }

            guard let worktreePath = path else { return nil }

            let isMain = isFirst
            isFirst = false

            return WorktreeInfo(
                path: worktreePath,
                headCommit: headCommit,
                branch: branch,
                isMain: isMain,
                isLocked: isLocked,
                isPrunable: isPrunable
            )
        }
    }
}
