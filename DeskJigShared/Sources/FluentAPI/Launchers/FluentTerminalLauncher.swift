//  FluentTerminalLauncher.swift
//  DeskJigShared

import Foundation
import AppKit

public struct FluentTerminalLauncher: FluentAppLauncher {
    public let bundleId: String
    public let appName: String

    /// Ensures only one task performs the initial Terminal.app launch with
    /// `-ApplePersistenceIgnoreState`. Without this, concurrent tasks both
    /// see `isTerminalRunning == false` and race to launch, causing the
    /// second launch to restore old sessions.
    /// Stores the PID of the Terminal.app process we launched, so the flag
    /// auto-resets when Terminal is killed between restore runs.
    private static let terminalInitialLaunchLock = NSLock()
    private static var terminalLaunchedPID: pid_t = 0
    private static var terminalQuitKeepsWindowsDisabled = false

    /// Synchronous helper to atomically check Terminal.app state and claim the
    /// initial launch slot. Keeps the NSLock out of async context.
    private static func claimInitialLaunch() -> (shouldDoInitialLaunch: Bool, isTerminalRunning: Bool) {
        terminalInitialLaunchLock.lock()
        defer { terminalInitialLaunchLock.unlock() }
        let isRunning = NSWorkspace.shared.runningApplications.contains {
            $0.bundleIdentifier == OpenByPathBundleIdentifiers.terminal
        }
        if isRunning {
            // Terminal already running — clear sentinel so next kill/restart works.
            terminalLaunchedPID = 0
            return (shouldDoInitialLaunch: false, isTerminalRunning: true)
        } else if terminalLaunchedPID != -1 {
            // Terminal not running and no other task is currently launching.
            // Claim the launch with sentinel value -1.
            terminalLaunchedPID = -1
            return (shouldDoInitialLaunch: true, isTerminalRunning: false)
        }
        // terminalLaunchedPID == -1 means another task is launching right now.
        return (shouldDoInitialLaunch: false, isTerminalRunning: false)
    }

    /// Atomically claims the one-time `NSQuitAlwaysKeepsWindows` disable under
    /// the same lock as `claimInitialLaunch()`. Returns `true` only for the
    /// first caller across all concurrent restore tasks, so the `defaults
    /// write` runs at most once regardless of how many terminal windows are
    /// launching in parallel.
    private static func claimQuitKeepsWindowsDisable() -> Bool {
        terminalInitialLaunchLock.lock()
        defer { terminalInitialLaunchLock.unlock() }
        if terminalQuitKeepsWindowsDisabled {
            return false
        }
        terminalQuitKeepsWindowsDisabled = true
        return true
    }

    public init(bundleId: String, appName: String) {
        self.bundleId = bundleId
        self.appName = appName
    }

    /// Create a launcher for Terminal.app
    public static func terminal() -> FluentTerminalLauncher {
        FluentTerminalLauncher(
            bundleId: "com.apple.Terminal",
            appName: "Terminal"
        )
    }

    /// Create a launcher for iTerm
    public static func iTerm() -> FluentTerminalLauncher {
        FluentTerminalLauncher(
            bundleId: "com.googlecode.iterm2",
            appName: "iTerm"
        )
    }
    
    public func launch(
        directory: String?,
        title: String?,
        task: RestorationTaskContext
    ) async throws -> ExpLaunchResult {
        let startTime = Date()

        DeskJigLog.debug(.restorationTrace, "Launching \(appName)", fields: [
            "taskId": task.taskId,
            "taskType": task.taskType.rawValue,
            "app": appName,
            "method": "appleScript",
            "directory": directory ?? "none"
        ], runId: task.runId)

        // iTerm2 retains the command-file approach because it uses profiles.
        if bundleId == OpenByPathBundleIdentifiers.iterm2 {
            let windowTitle = title ?? directory.map { ($0 as NSString).lastPathComponent } ?? "Terminal"
            let directoryURL = directory.map { URL(fileURLWithPath: $0) } ?? FileManager.default.homeDirectoryForCurrentUser
            let commandFile = try TerminalCommandFile.create(forDirectory: directoryURL, titleToken: windowTitle)
            
            // Clean up command file after a delay
            DispatchQueue.global().asyncAfter(deadline: .now() + 5) {
                try? FileManager.default.removeItem(at: commandFile)
            }
            
            return await launchITerm(commandFile: commandFile, startTime: startTime, task: task)
        }

        // For Terminal.app, use new AppleScript method
        return await launchWithAppleScript(startTime: startTime, task: task, directory: directory, title: title)
    }

    private func launchWithAppleScript(
        startTime: Date,
        task: RestorationTaskContext,
        directory: String?,
        title: String?
    ) async -> ExpLaunchResult {
        // Force Terminal to discard old sessions on launch (bypassing "Open with windows from last session")
        if Self.claimQuitKeepsWindowsDisable() {
            _ = try? await LauncherUtils.runProcessAsync(
                executable: URL(fileURLWithPath: "/usr/bin/defaults"),
                arguments: ["write", "com.apple.Terminal", "NSQuitAlwaysKeepsWindows", "-bool", "false"]
            )
        }

        let safeDir = directory ?? "~"
        let safeTitle = title ?? "Terminal"

        let isTerminalRunning = NSWorkspace.shared.runningApplications.contains {
            $0.bundleIdentifier == OpenByPathBundleIdentifiers.terminal
        }
        if !isTerminalRunning {
            await launchTerminalIgnoringRestoredWindows(task: task)
        }
        
        // Reuse the existing window when possible and force it visible.
        let script = """
        tell application "Terminal"
            activate
            
            set targetTab to missing value
            
            -- Force reuse of window 1 if it exists (ignore busy status)
            if (count of windows) > 0 then
                try
                    set targetTab to selected tab of window 1
                end try
            end if
            
            if targetTab is missing value then
                set targetTab to do script "cd \(LauncherUtils.escapeAppleScript(safeDir)); clear"
            else
                -- Reuse existing tab
                set targetTab to do script "cd \(LauncherUtils.escapeAppleScript(safeDir)); clear" in targetTab
            end if
            
            set custom title of targetTab to "\(LauncherUtils.escapeAppleScript(safeTitle))"
            
            -- Ensure window is visible and frontmost
            set w to window 1
            set index of w to 1
            set visible of w to true
            activate
            
            return "ok"
        end tell
        """
        
        let result = await AppleScriptRunner.runOsascriptAsync(
            script,
            timeout: nil,
            environment: LauncherUtils.cleanEnvironment()
        )
        let durationMs = Int(result.duration * 1000)

        if result.exitCode == -1 {
            let durationMs = Int(Date().timeIntervalSince(startTime) * 1000)
            DeskJigLog.debug(.restorationTrace, "\(appName) AppleScript launch error: \(result.errorOutput)", fields: [
                "taskId": task.taskId,
                "taskType": task.taskType.rawValue,
                "durationMs": "\(durationMs)"
            ], runId: task.runId)
            return ExpLaunchResult(
                success: false,
                launchDurationMs: durationMs,
                method: .appleScript,
                notes: ["error=\(result.errorOutput)"]
            )
        }

        DeskJigLog.debug(.restorationTrace, "\(appName) launch via AppleScript \(result.exitCode == 0 ? "completed" : "failed")", fields: [
            "taskId": task.taskId,
            "taskType": task.taskType.rawValue,
            "durationMs": "\(durationMs)",
            "exitCode": "\(result.exitCode)",
            "scriptLength": "\(script.count)"
        ], runId: task.runId)

        return ExpLaunchResult(
            success: result.exitCode == 0,
            launchDurationMs: durationMs,
            method: .appleScript,
            notes: directory != nil ? ["directory=\(directory!)"] : []
        )
    }

    private func launchITerm(
        commandFile: URL,
        startTime: Date,
        task: RestorationTaskContext
    ) async -> ExpLaunchResult {
        let escapedPath = LauncherUtils.escapeAppleScript(commandFile.path)
        let scriptLines = [
            "set commandPath to quoted form of POSIX path of (POSIX file \"\(escapedPath)\")",
            "tell application id \"\(bundleId)\"",
            "activate",
            "create window with default profile command commandPath",
            "end tell"
        ]

        let script = scriptLines.joined(separator: "\n")
        let result = await AppleScriptRunner.runOsascriptAsync(
            script,
            timeout: nil,
            environment: LauncherUtils.cleanEnvironment()
        )
        let durationMs = Int(result.duration * 1000)

        if result.exitCode == -1 {
            let durationMs = Int(Date().timeIntervalSince(startTime) * 1000)
            DeskJigLog.debug(.restorationTrace, "\(appName) launch error: \(result.errorOutput)", fields: [
                "taskId": task.taskId,
                "taskType": task.taskType.rawValue,
                "durationMs": "\(durationMs)",
                "method": "appleScript"
            ], runId: task.runId)

            return ExpLaunchResult(
                success: false,
                launchDurationMs: durationMs,
                method: .appleScript,
                notes: ["error=\(result.errorOutput)"]
            )
        }

        DeskJigLog.debug(.restorationTrace, "\(appName) launch \(result.exitCode == 0 ? "completed" : "failed")", fields: [
            "taskId": task.taskId,
            "taskType": task.taskType.rawValue,
            "durationMs": "\(durationMs)",
            "exitCode": "\(result.exitCode)",
            "method": "appleScript"
        ], runId: task.runId)

        return ExpLaunchResult(
            success: result.exitCode == 0,
            launchDurationMs: durationMs,
            method: .appleScript,
            notes: ["commandFile=\(commandFile.lastPathComponent)"]
        )
    }

    /// Launches the terminal attached to a tmux session on the DeskJig socket.
    public func launchWithTmuxSession(
        sessionName: String,
        workingDirectory: String?,
        task: RestorationTaskContext,
        tmuxManagedIndex: Int? = nil
    ) async throws -> ExpLaunchResult {
        let startTime = Date()

        DeskJigLog.debug(.restorationTrace, "Launching \(appName)", fields: [
            "taskId": task.taskId,
            "taskType": task.taskType.rawValue,
            "app": appName,
            "method": "tmux",
            "directory": workingDirectory ?? "none"
        ], runId: task.runId)

        let tmuxSocketPath = TmuxCommandService.deskJigSocketPath
        let tmuxCommandService = TmuxCommandService()
        guard let resolvedTmuxBinary = await tmuxCommandService.binaryPath else {
            let durationMs = Int(Date().timeIntervalSince(startTime) * 1000)
            return ExpLaunchResult(
                success: false,
                launchDurationMs: durationMs,
                method: .appleScript,
                notes: ["tmux binary unavailable", "method=tmux"]
            )
        }

        let dir = workingDirectory ?? "~"
        let expandedDir = (dir as NSString).expandingTildeInPath
        let managedTitle: String
        if let idx = tmuxManagedIndex {
            managedTitle = BundleRegistry.managedTmuxWindowTitle(bundleId: bundleId, index: idx)
        } else {
            managedTitle = BundleRegistry.managedTmuxWindowTitle
        }
        let tmuxRun = "exec \(LauncherUtils.shellQuote(resolvedTmuxBinary)) -S \(LauncherUtils.shellQuote(tmuxSocketPath)) new-session -A -s \(LauncherUtils.shellQuote(sessionName)) -c \(LauncherUtils.shellQuote(expandedDir))"

        let launchResult: (exitCode: Int32, durationMs: Int, stderr: String, stdout: String, method: ExpLaunchMethod)
        switch bundleId {
        case BundleRegistry.iterm2:
            // Guard: if the tmux session already has a client, a previous launch succeeded.
            // Skip creating a new window to prevent duplicates from retry/fallback paths.
            // `create window with default profile command` is not idempotent — each call
            // creates a new iTerm window, unlike the old `write text` approach.
            if let existingClients = try? await tmuxCommandService.listClients(),
               existingClients.contains(where: { $0.sessionName == sessionName }) {
                DeskJigLog.debug(.restorationTrace, "\(appName) tmux session already has client — skipping window creation", fields: [
                    "taskId": task.taskId,
                    "taskType": task.taskType.rawValue,
                    "sessionName": sessionName,
                    "title": managedTitle
                ], runId: task.runId)
                return ExpLaunchResult(
                    success: true,
                    launchDurationMs: Int(Date().timeIntervalSince(startTime) * 1000),
                    method: .appleScript,
                    notes: ["tmux session already attached — skipped duplicate window creation"]
                )
            }

            // Use `create window with default profile command` to make tmux the initial
            // process for the new window. This eliminates the `write text` targeting bug
            // where the newWindow reference could resolve to an existing window's session,
            // causing both windows to attach to the same tmux session.
            //
            // iTerm's `command` parameter runs the string as a raw process (not through a
            // shell), so we wrap in `$SHELL -c "..."` to support shell syntax (`;`, `exec`).
            //
            // `exec` replaces the shell with tmux, so the window stays alive as long as the
            // tmux session runs. Sessions are pre-created by ensureSessionsForWorkspace(),
            // so `new-session -A` always attaches.
            //
            // Title is set via OSC 0 escape (printf) before exec; setPaneTitle in
            // RestorationExecutor propagates the managed title to CGWindowList via tmux.
            let titleEsc = "printf '\\033]0;\(managedTitle)\\007'"
            let iTermCmd = "\(titleEsc); \(tmuxRun)"
            let userShell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
            let shellCmd = "\(userShell) -c \(LauncherUtils.shellQuote(iTermCmd))"
            let script = """
            tell application id "\(bundleId)"
                activate
                create window with default profile command "\(LauncherUtils.escapeAppleScript(shellCmd))"
            end tell
            """
            let result = await AppleScriptRunner.runOsascriptAsync(
                script,
                timeout: nil,
                environment: LauncherUtils.cleanEnvironment()
            )
            if result.exitCode == -1 {
                // osascript could not be spawned at all — short-circuit like the
                // pre-consolidation throw path instead of flowing into verification.
                let durationMs = Int(Date().timeIntervalSince(startTime) * 1000)
                return ExpLaunchResult(
                    success: false,
                    launchDurationMs: durationMs,
                    method: .appleScript,
                    notes: ["error=\(result.errorOutput)", "method=tmux"]
                )
            }
            launchResult = (
                result.exitCode,
                Int(result.duration * 1000),
                result.errorOutput.trimmingCharacters(in: .whitespacesAndNewlines),
                result.trimmedOutput,
                .appleScript
            )
        default:
            // Use a lock to ensure only ONE task performs the initial clean
            // launch of Terminal.app with -ApplePersistenceIgnoreState.
            // Without this, concurrent tasks both see isTerminalRunning==false
            // and race to launch, causing the second to restore old sessions.
            let (shouldDoInitialLaunch, isTerminalRunning) = Self.claimInitialLaunch()

            DeskJigLog.debug(.restorationTrace, "Terminal.app tmux pre-launch state", fields: [
                "taskId": task.taskId,
                "taskType": task.taskType.rawValue,
                "isTerminalRunning": "\(isTerminalRunning)",
                "shouldDoInitialLaunch": "\(shouldDoInitialLaunch)",
                "sessionName": sessionName,
                "workingDirectory": expandedDir,
                "managedTitle": managedTitle
            ], runId: task.runId)

            if Self.claimQuitKeepsWindowsDisable() {
                _ = try? await LauncherUtils.runProcessAsync(
                    executable: URL(fileURLWithPath: "/usr/bin/defaults"),
                    arguments: ["write", "com.apple.Terminal", "NSQuitAlwaysKeepsWindows", "-bool", "false"]
                )
            }

            if shouldDoInitialLaunch {
                await launchTerminalIgnoringRestoredWindows(task: task)
            }

            let commandFile: URL
            do {
                commandFile = try TerminalCommandFile.create(
                    forDirectory: URL(fileURLWithPath: expandedDir),
                    titleToken: managedTitle,
                    launchCommand: tmuxRun
                )
            } catch {
                let durationMs = Int(Date().timeIntervalSince(startTime) * 1000)
                return ExpLaunchResult(
                    success: false,
                    launchDurationMs: durationMs,
                    method: .cli,
                    notes: ["error=\(error.localizedDescription)", "method=tmux", "bootstrap=command-file"]
                )
            }

            DispatchQueue.global().asyncAfter(deadline: .now() + 5) {
                try? FileManager.default.removeItem(at: commandFile)
            }

            let terminalAppPath = NSWorkspace.shared.urlForApplication(
                withBundleIdentifier: bundleId
            )?.path ?? "/System/Applications/Utilities/Terminal.app"

            do {
                let (exitCode, duration, stderr, stdout) = try await LauncherUtils.runProcessAsyncCapturingAll(
                    executable: URL(fileURLWithPath: "/usr/bin/open"),
                    arguments: ["-a", terminalAppPath, commandFile.path]
                )
                launchResult = (exitCode, Int(duration * 1000), stderr, stdout, .cli)

                if shouldDoInitialLaunch {
                    // The initial launch with -ApplePersistenceIgnoreState created a
                    // blank default window. Close it now that the command file window
                    // is opening.
                    await closeBlankDefaultTerminalWindow(task: task)
                }
            } catch {
                let durationMs = Int(Date().timeIntervalSince(startTime) * 1000)
                return ExpLaunchResult(
                    success: false,
                    launchDurationMs: durationMs,
                    method: .cli,
                    notes: ["error=\(error.localizedDescription)", "method=tmux", "bootstrap=command-file"]
                )
            }
        }

        let verification = await TmuxLaunchVerifier.waitForClientAttachment(
            sessionName: sessionName,
            expectedTitle: managedTitle,
            commandService: tmuxCommandService
        )

        var traceData: [String: String] = [
            "durationMs": "\(launchResult.durationMs)",
            "exitCode": "\(launchResult.exitCode)",
            "sessionName": sessionName,
            "title": managedTitle,
            "method": "tmux",
            "launchMethod": launchResult.method.rawValue,
            "attachedClientCount": "\(verification.attachedClientCount)",
            "verificationSuccess": "\(verification.success)"
        ]
        if !launchResult.stderr.isEmpty {
            traceData["stderr"] = String(launchResult.stderr.prefix(500))
        }
        let scriptResult = launchResult.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        if !scriptResult.isEmpty {
            traceData["scriptResult"] = scriptResult
        }
        if let paneTitle = verification.paneTitle, !paneTitle.isEmpty {
            traceData["paneTitle"] = paneTitle
        }

        var deskJigFields: [String: any Sendable] = [
            "taskId": task.taskId,
            "taskType": task.taskType.rawValue
        ]
        for (key, value) in traceData {
            deskJigFields[key] = value
        }
        DeskJigLog.debug(
            .restorationTrace,
            "\(appName) tmux launch \((launchResult.exitCode == 0 && verification.success) ? "completed" : "failed")",
            fields: deskJigFields,
            runId: task.runId
        )

        return ExpLaunchResult(
            success: launchResult.exitCode == 0 && verification.success,
            launchDurationMs: launchResult.durationMs,
            method: launchResult.method,
            notes: [
                "tmux session=\(sessionName)",
                "directory=\(dir)",
                "title=\(managedTitle)",
                "clientDetected=\(verification.success)",
                "attachedClientCount=\(verification.attachedClientCount)"
            ]
        )
    }

    private func launchTerminalIgnoringRestoredWindows(
        task: RestorationTaskContext
    ) async {
        let terminalAppPath = NSWorkspace.shared.urlForApplication(
            withBundleIdentifier: bundleId
        )?.path ?? "/System/Applications/Utilities/Terminal.app"

        do {
            // Delete the temp savedState directory that macOS creates when
            // -ApplePersistenceIgnoreState is used. On subsequent launches
            // with the flag, Terminal reads from this temp location and
            // restores windows saved during the PREVIOUS flagged run.
            // Use TMPDIR env var (user-level) since NSTemporaryDirectory()
            // may return a sandboxed path for DeskJig.app.
            let userTmpDir = ProcessInfo.processInfo.environment["TMPDIR"]
                ?? NSTemporaryDirectory()
            let tempSavedState = URL(fileURLWithPath: userTmpDir)
                .appendingPathComponent("com.apple.Terminal.savedState")
            let tempStateExists = FileManager.default.fileExists(atPath: tempSavedState.path)
            if tempStateExists {
                do {
                    try FileManager.default.removeItem(at: tempSavedState)
                    DeskJigLog.debug(.restorationTrace, "Terminal.app temp savedState deleted", fields: [
                        "taskId": task.taskId,
                        "path": tempSavedState.path
                    ], runId: task.runId)
                } catch {
                    DeskJigLog.debug(.restorationTrace, "Terminal.app temp savedState delete FAILED", fields: [
                        "taskId": task.taskId,
                        "path": tempSavedState.path,
                        "error": error.localizedDescription
                    ], runId: task.runId)
                }
            } else {
                DeskJigLog.debug(.restorationTrace, "Terminal.app temp savedState not found (clean)", fields: [
                    "taskId": task.taskId,
                    "path": tempSavedState.path
                ], runId: task.runId)
            }

            // Launch via `open -a` which registers with Launch Services properly,
            // avoiding a dual-process issue that occurs with direct binary launch.
            // The temp savedState deletion above is the key fix — without it,
            // Terminal restores old windows from the previous flagged run.
            let (exitCode, duration, stderr, stdout) = try await LauncherUtils.runProcessAsyncCapturingAll(
                executable: URL(fileURLWithPath: "/usr/bin/open"),
                arguments: ["-a", terminalAppPath, "--args", "-ApplePersistenceIgnoreState", "YES"]
            )

            DeskJigLog.debug(.restorationTrace, "Terminal.app launched with ApplePersistenceIgnoreState", fields: [
                "taskId": task.taskId,
                "taskType": task.taskType.rawValue,
                "exitCode": "\(exitCode)",
                "durationMs": "\(Int(duration * 1000))",
                "stderr": stderr.isEmpty ? "none" : String(stderr.prefix(300)),
                "stdout": stdout.isEmpty ? "none" : String(stdout.prefix(300))
            ], runId: task.runId)
            await Task.sleepUnlessCancelled(nanoseconds: 700_000_000)
        } catch {
            DeskJigLog.debug(.restorationTrace, "Terminal.app ApplePersistenceIgnoreState launch failed", fields: [
                "taskId": task.taskId,
                "taskType": task.taskType.rawValue,
                "error": error.localizedDescription
            ], runId: task.runId)
        }
    }

    /// Closes the blank default Terminal window created by `-ApplePersistenceIgnoreState`.
    /// Only targets windows with no custom title and at most one process (the login shell).
    private func closeBlankDefaultTerminalWindow(task: RestorationTaskContext) async {
        guard await Task.sleepUnlessCancelled(nanoseconds: 500_000_000) else { return }

        let script = """
        tell application "Terminal"
            repeat with w in windows
                try
                    set tabProcs to processes of selected tab of w
                    set tabTitle to custom title of selected tab of w
                    if tabTitle is "" or tabTitle is missing value then
                        if (count of tabProcs) \u{2264} 1 then
                            close w
                            exit repeat
                        end if
                    end if
                end try
            end repeat
        end tell
        """
        let result = await AppleScriptRunner.runOsascriptAsync(
            script,
            timeout: nil,
            environment: LauncherUtils.cleanEnvironment()
        )
        if result.exitCode == -1 {
            // osascript could not be spawned — log the failure like the
            // pre-consolidation catch branch did.
            DeskJigLog.debug(.restorationTrace, "Terminal.app blank window cleanup failed", fields: [
                "taskId": task.taskId,
                "error": result.errorOutput
            ], runId: task.runId)
            return
        }
        DeskJigLog.debug(.restorationTrace, "Terminal.app blank default window cleanup", fields: [
            "taskId": task.taskId,
            "exitCode": "\(result.exitCode)"
        ], runId: task.runId)
    }

    static func closeExtraWindowsIfIdle(
        bundleId: String,
        expectedTitles: [String],
        runId: String
    ) -> Int? {
        let trimmedTitles = expectedTitles
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !trimmedTitles.isEmpty else { return nil }

        let expectedList = LauncherUtils.appleScriptList(trimmedTitles)
        let script: String

        switch bundleId {
        case OpenByPathBundleIdentifiers.terminal:
            script = """
            set expectedTitles to \(expectedList)
            tell application "Terminal"
                set closedCount to 0
                -- Track seen titles to prevent duplicates
                set seenTitles to {}
                
                set allWindows to every window
                
                repeat with w in allWindows
                    set shouldKeep to false
                    set foundTitle to ""
                    
                    -- Check if window matches any expected title
                    repeat with t in tabs of w
                        set tabTitle to ""
                        try
                            set tabTitle to custom title of t
                        end try
                        if tabTitle is "" then
                            set tabTitle to name of t
                        end if
                        
                        repeat with expectedTitle in expectedTitles
                            if tabTitle contains expectedTitle then
                                set shouldKeep to true
                                set foundTitle to expectedTitle
                            end if
                        end repeat
                    end repeat
                    
                    if shouldKeep is true then
                        -- Check if we already kept a window for this title
                        set isDuplicate to false
                        repeat with seen in seenTitles
                            if seen as string is equal to foundTitle then
                                set isDuplicate to true
                            end if
                        end repeat
                        
                        if isDuplicate is true then
                            -- This is a duplicate! Close it unless it's busy
                            set shouldKeep to false
                        else
                            -- Mark as seen
                            set end of seenTitles to foundTitle
                        end if
                    end if
                    
                    if shouldKeep is false then
                        set isBusy to false
                        repeat with t in tabs of w
                            try
                                if busy of t is true then set isBusy to true
                            end try
                        end repeat
                        if isBusy is false then
                            close w
                            set closedCount to closedCount + 1
                        end if
                    end if
                end repeat
                return closedCount
            end tell
            """

        case OpenByPathBundleIdentifiers.iterm2:
            // iTerm2 hierarchy: windows > tabs > sessions.
            // Iterate through tabs to reach sessions (not `sessions of w` directly).
            script = """
            set expectedTitles to \(expectedList)
            tell application "iTerm2"
                set closedCount to 0
                set seenTitles to {}
                repeat with w in windows
                    set shouldKeep to false
                    set foundTitle to ""
                    repeat with t in tabs of w
                        repeat with s in sessions of t
                            set sessionTitle to name of s
                            repeat with expectedTitle in expectedTitles
                                if sessionTitle contains expectedTitle then
                                    set shouldKeep to true
                                    if foundTitle is "" then
                                        set foundTitle to expectedTitle
                                    end if
                                end if
                            end repeat
                        end repeat
                    end repeat
                    if shouldKeep is true then
                        set isDuplicate to false
                        repeat with seen in seenTitles
                            if seen as string is equal to foundTitle then
                                set isDuplicate to true
                            end if
                        end repeat
                        if isDuplicate is true then
                            set shouldKeep to false
                        else
                            set end of seenTitles to foundTitle
                        end if
                    end if
                    if shouldKeep is false then
                        set sessionBusy to false
                        repeat with t in tabs of w
                            repeat with s in sessions of t
                                try
                                    if is processing of s is true then set sessionBusy to true
                                on error
                                    try
                                        if is at shell prompt of s is false then set sessionBusy to true
                                    on error
                                        set sessionBusy to true
                                    end try
                                end try
                            end repeat
                        end repeat
                        if sessionBusy is false then
                            close w
                            set closedCount to closedCount + 1
                        end if
                    end if
                end repeat
                return closedCount
            end tell
            """

        default:
            return nil
        }

        DeskJigLog.debug(.restorationTrace, "Terminal cleanup attempt", fields: [
            "bundleId": bundleId,
            "expectedTitles": "\(trimmedTitles.count)"
        ], runId: runId)

        let result = AppleScriptRunner.runOsascript(script, timeout: 4.0)
        if result.timedOut {
            DeskJigLog.debug(.restorationTrace, "Terminal cleanup timed out", fields: [
                "bundleId": bundleId
            ], runId: runId)
            return nil
        }
        if result.exitCode != 0 {
            DeskJigLog.debug(.restorationTrace, "Terminal cleanup failed", fields: [
                "bundleId": bundleId,
                "stderr": result.errorOutput
            ], runId: runId)
            return nil
        }

        let closedCount = Int(result.trimmedOutput)
        if let closedCount {
            DeskJigLog.debug(.restorationTrace, "Terminal cleanup complete", fields: [
                "bundleId": bundleId,
                "closed": "\(closedCount)"
            ], runId: runId)
        }
        return closedCount
    }

    public func matchWindow(
        in snapshot: SystemSnapshot,
        directory: String?,
        title: String?,
        task: RestorationTaskContext,
        trustDeskJigTitle: Bool
    ) -> ExpWindowMatch? {
        let terminalWindows = snapshot.windows(forBundleID: bundleId)

        guard !terminalWindows.isEmpty else {
            DeskJigLog.debug(.restorationTrace, "No \(appName) windows found", fields: [
                "taskId": task.taskId,
                "taskType": task.taskType.rawValue
            ], runId: task.runId)
            return nil
        }

        // Strategy 1: Exact legacy title-token match with directory verification
        if let expectedTitle = title, expectedTitle.hasPrefix("\(BundleIdentity.terminalTitleTokenPrefix):") {
            let matchingTitleWindows = terminalWindows.filter { $0.title == expectedTitle }

            if !matchingTitleWindows.isEmpty {
                // If directory specified, verify working directory matches
                // Prefer freshWorkingDirectory (from supplementation) over documentPath
                if let dir = directory {
                    let normalizedDir = Self.normalizePath(dir)
                    if let window = matchingTitleWindows.first(where: {
                        guard let workingDir = $0.freshWorkingDirectory ?? $0.documentPath else { return false }
                        return Self.normalizePath(workingDir) == normalizedDir
                    }) {
                        let matchedPath = window.freshWorkingDirectory ?? window.documentPath ?? dir
                        let source = window.freshWorkingDirectory != nil ? "freshWorkingDirectory" : "documentPath"
                        DeskJigLog.debug(.restorationTrace, "Matched \(appName) window", fields: [
                            "taskId": task.taskId,
                            "taskType": task.taskType.rawValue,
                            "app": appName,
                            "windowId": Int(window.windowId),
                            "confidence": "exact",
                            "method": "deskJigTitle+\(source)",
                            "title": expectedTitle,
                            "path": matchedPath
                        ], runId: task.runId)
                        return ExpWindowMatch(window: window, confidence: .exact, method: .bentoTitle, matchedValue: expectedTitle)
                    }
                    // Title match but wrong directory
                    let window = matchingTitleWindows.first!
                    let actualDir = window.freshWorkingDirectory ?? window.documentPath ?? "unknown"

                    // An exact legacy title token remains authoritative when restored CWD data is missing or lagging.
                    DeskJigLog.debug(.restorationTrace, "Trusting exact legacy title-token match despite directory mismatch/missing", fields: [
                        "taskId": task.taskId,
                        "taskType": task.taskType.rawValue,
                        "windowId": Int(window.windowId),
                        "pid": window.pid,
                        "title": expectedTitle,
                        "expectedDir": dir,
                        "actualDir": actualDir,
                        "reason": "exact title match found"
                    ], runId: task.runId)
                    return ExpWindowMatch(window: window, confidence: .high, method: .bentoTitle, matchedValue: expectedTitle)
                }

                // No directory to verify, use title match
                if let window = matchingTitleWindows.first {
                    DeskJigLog.debug(.restorationTrace, "Matched \(appName) window", fields: [
                        "taskId": task.taskId,
                        "taskType": task.taskType.rawValue,
                        "app": appName,
                        "windowId": Int(window.windowId),
                        "confidence": "exact",
                        "method": "deskJigTitle",
                        "title": expectedTitle
                    ], runId: task.runId)
                    return ExpWindowMatch(window: window, confidence: .exact, method: .bentoTitle, matchedValue: expectedTitle)
                }
            }

            let containsTitleWindows = terminalWindows.filter {
                $0.title?.localizedCaseInsensitiveContains(expectedTitle) == true
            }

            if !containsTitleWindows.isEmpty {
                if let dir = directory {
                    let normalizedDir = Self.normalizePath(dir)
                    if let window = containsTitleWindows.first(where: {
                        guard let workingDir = $0.freshWorkingDirectory ?? $0.documentPath else { return false }
                        return Self.normalizePath(workingDir) == normalizedDir
                    }) {
                        let matchedPath = window.freshWorkingDirectory ?? window.documentPath ?? dir
                        let source = window.freshWorkingDirectory != nil ? "freshWorkingDirectory" : "documentPath"
                        DeskJigLog.debug(.restorationTrace, "Matched \(appName) window", fields: [
                            "taskId": task.taskId,
                            "taskType": task.taskType.rawValue,
                            "app": appName,
                            "windowId": Int(window.windowId),
                            "confidence": "high",
                            "method": "deskJigTitleContains+\(source)",
                            "title": expectedTitle,
                            "path": matchedPath
                        ], runId: task.runId)
                        return ExpWindowMatch(window: window, confidence: .high, method: .bentoTitle, matchedValue: expectedTitle)
                    }

                    if trustDeskJigTitle {
                        let window = containsTitleWindows.first!
                        DeskJigLog.debug(.restorationTrace, "WARNING: Trusting legacy token in title despite directory mismatch", fields: [
                            "taskId": task.taskId,
                            "taskType": task.taskType.rawValue,
                            "windowId": Int(window.windowId),
                            "pid": window.pid,
                            "title": window.title ?? "nil",
                            "expectedDir": dir,
                            "actualDir": window.freshWorkingDirectory ?? window.documentPath ?? "unknown",
                            "reason": "trustDeskJigTitle=true (token in title)"
                        ], runId: task.runId)
                        return ExpWindowMatch(window: window, confidence: .high, method: .bentoTitle, matchedValue: expectedTitle)
                    }
                } else if let window = containsTitleWindows.first {
                    DeskJigLog.debug(.restorationTrace, "Matched \(appName) window", fields: [
                        "taskId": task.taskId,
                        "taskType": task.taskType.rawValue,
                        "app": appName,
                        "windowId": Int(window.windowId),
                        "confidence": "high",
                        "method": "deskJigTitleContains",
                        "title": expectedTitle
                    ], runId: task.runId)
                    return ExpWindowMatch(window: window, confidence: .high, method: .bentoTitle, matchedValue: expectedTitle)
                }
            }

            if trustDeskJigTitle, let dir = directory {
                let normalizedDir = Self.normalizePath(dir)
                let dirMatches = terminalWindows.filter {
                    guard let workingDir = $0.freshWorkingDirectory ?? $0.documentPath else { return false }
                    return Self.normalizePath(workingDir) == normalizedDir
                }
                if dirMatches.count == 1, let window = dirMatches.first {
                    let matchedPath = window.freshWorkingDirectory ?? window.documentPath ?? dir
                    let source = window.freshWorkingDirectory != nil ? "freshWorkingDirectory" : "documentPath"
                    DeskJigLog.debug(.restorationTrace, "Matched \(appName) window", fields: [
                        "taskId": task.taskId,
                        "taskType": task.taskType.rawValue,
                        "app": appName,
                        "windowId": Int(window.windowId),
                        "confidence": "medium",
                        "method": "deskJigFallback+\(source)",
                        "path": matchedPath
                    ], runId: task.runId)
                    return ExpWindowMatch(window: window, confidence: .medium, method: .documentPath, matchedValue: matchedPath)
                }
            }

            // If a legacy title token is expected but not found, don't fall back to loose matching.
            DeskJigLog.debug(.restorationTrace, "No \(appName) window with legacy title token '\(expectedTitle)' found", fields: [
                "taskId": task.taskId,
                "taskType": task.taskType.rawValue
            ], runId: task.runId)
            return nil
        }

        // Strategy 2: Match by working directory (prefer supplemented data)
        if let dir = directory {
            let normalizedDir = Self.normalizePath(dir)
            if let window = terminalWindows.first(where: {
                guard let workingDir = $0.freshWorkingDirectory ?? $0.documentPath else { return false }
                return Self.normalizePath(workingDir) == normalizedDir
            }) {
                let matchedPath = window.freshWorkingDirectory ?? window.documentPath ?? dir
                let source = window.freshWorkingDirectory != nil ? "freshWorkingDirectory" : "documentPath"
                DeskJigLog.debug(.restorationTrace, "Matched \(appName) window", fields: [
                    "taskId": task.taskId,
                    "taskType": task.taskType.rawValue,
                    "app": appName,
                    "windowId": Int(window.windowId),
                    "confidence": "exact",
                    "method": source,
                    "path": matchedPath
                ], runId: task.runId)
                return ExpWindowMatch(window: window, confidence: .exact, method: .documentPath, matchedValue: matchedPath)
            }

            // Strategy 3: Title contains directory basename
            let dirBasename = (dir as NSString).lastPathComponent
            if let window = terminalWindows.first(where: {
                $0.title?.contains(dirBasename) == true
            }) {
                DeskJigLog.debug(.restorationTrace, "Matched \(appName) window", fields: [
                    "taskId": task.taskId,
                    "taskType": task.taskType.rawValue,
                    "app": appName,
                    "windowId": Int(window.windowId),
                    "confidence": "high",
                    "method": "titlePattern",
                    "pattern": dirBasename
                ], runId: task.runId)
                return ExpWindowMatch(window: window, confidence: .high, method: .titlePattern, matchedValue: window.title)
            }
        }

        // No match found - don't fall back to any window
        // This prevents incorrectly reusing windows when restoring multiple terminals
        return nil
    }

    /// Normalize a path for comparison (expand tilde, resolve symlinks)
    private static func normalizePath(_ path: String) -> String {
        PathNormalization.standardize(path)
    }
}
