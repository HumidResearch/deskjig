//
//  DeskJigCLIInstaller.swift
//  DeskJig
//
//  Install and verify the bundled deskjig CLI.
//

import Foundation
import DeskJigShared

enum DeskJigCLIInstaller {
    struct Status: Equatable {
        let installPath: String
        let bundledPath: String?
        let symlinkTarget: String?
        let isInstalled: Bool
        let isSymlink: Bool
        let isUpToDate: Bool
        let isExecutable: Bool
    }

    struct InstallResult {
        let status: Status
        let message: String?
        let error: String?
        /// Copy-paste shell command that finishes the job when DeskJig cannot do it
        /// itself. DeskJig ships no privileged helper, so when `/usr/local/bin` is not
        /// user-writable the UI must show this instead of failing silently.
        let manualCommand: String?

        init(
            status: Status,
            message: String? = nil,
            error: String? = nil,
            manualCommand: String? = nil
        ) {
            self.status = status
            self.message = message
            self.error = error
            self.manualCommand = manualCommand
        }
    }

    private enum InstallError: LocalizedError {
        case bundledMissing
        case requiresApplicationsFolder
        case notWritable(path: String, underlying: String)

        var errorDescription: String? {
            switch self {
            case .bundledMissing:
                return "Bundled deskjig not found. Please reinstall DeskJig."
            case .requiresApplicationsFolder:
                return "DeskJig must be located in /Applications to install the CLI."
            case .notWritable(let path, let underlying):
                return "DeskJig could not write to \(path) (\(underlying)). "
                    + "Run the command below in Terminal to finish installing."
            }
        }
    }

    static let installPath = "/usr/local/bin/deskjig"

    private static var installDirectory: String {
        URL(fileURLWithPath: installPath).deletingLastPathComponent().path
    }

    static func status() -> Status {
        let fileManager = FileManager.default
        let bundledPath = bundledCLIPath()
        let installPath = Self.installPath

        let installURL = URL(fileURLWithPath: installPath)
        let installDir = installURL.deletingLastPathComponent()

        var symlinkTarget: String?
        var isSymlink = false

        if fileManager.fileExists(atPath: installPath) {
            if let destination = try? fileManager.destinationOfSymbolicLink(atPath: installPath) {
                isSymlink = true
                let resolved = URL(fileURLWithPath: destination, relativeTo: installDir)
                    .standardizedFileURL
                    .path
                symlinkTarget = resolved
            } else {
                symlinkTarget = installPath
            }
        }

        let isExecutable = fileManager.isExecutableFile(atPath: installPath)
        let isInstalled = fileManager.fileExists(atPath: installPath) && isExecutable
        let isUpToDate: Bool = {
            guard isInstalled, let bundledPath else { return false }
            let resolvedBundled = URL(fileURLWithPath: bundledPath).resolvingSymlinksInPath().path
            let resolvedTarget = (symlinkTarget ?? installPath)
            return resolvedTarget == resolvedBundled
        }()

        return Status(
            installPath: installPath,
            bundledPath: bundledPath,
            symlinkTarget: symlinkTarget,
            isInstalled: isInstalled,
            isSymlink: isSymlink,
            isUpToDate: isUpToDate,
            isExecutable: isExecutable
        )
    }

    /// Installs the CLI symlink without elevated privileges.
    ///
    /// DeskJig has no SMJobBless helper and requests no administrator authorization.
    /// When the install directory is not writable by the current user the attempt
    /// fails cleanly and the result carries `manualCommand`, which the UI must show
    /// so the user can finish in Terminal.
    static func install() async -> InstallResult {
        let bundledPath = bundledCLIPath()

        do {
            let appPath = Bundle.main.bundleURL.resolvingSymlinksInPath().standardizedFileURL.path
            #if DEBUG
            let debugLocation = isDebugBuildLocation()
            #else
            let debugLocation = false
            #endif
            DeskJigLog.info(.cli, "deskjig install requested", fields: ["appPath": appPath, "debugLocation": debugLocation])

            guard let bundledPath,
                  FileManager.default.isExecutableFile(atPath: bundledPath) else {
                throw InstallError.bundledMissing
            }

            guard isInstalledInApplicationsFolder() else {
                throw InstallError.requiresApplicationsFolder
            }

            try createSymlink(sourcePath: bundledPath, destinationPath: installPath)

            let newStatus = status()
            if newStatus.isInstalled && newStatus.isUpToDate {
                return InstallResult(
                    status: newStatus,
                    message: "deskjig installed at \(installPath)"
                )
            }

            return InstallResult(
                status: newStatus,
                error: "Installation completed, but verification failed. Please try again.",
                manualCommand: manualInstallCommand(sourcePath: bundledPath)
            )
        } catch {
            let newStatus = status()
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            DeskJigLog.error(.cli, "deskjig install failed", fields: ["error": message])

            // Only a permissions failure is fixable from Terminal; a missing bundled
            // binary or a misplaced app bundle is not.
            let manualCommand: String? = {
                guard case InstallError.notWritable = error else { return nil }
                return manualInstallCommand(sourcePath: bundledPath)
            }()

            return InstallResult(
                status: newStatus,
                error: message,
                manualCommand: manualCommand
            )
        }
    }

    static func resetInstall() async -> InstallResult {
        let currentStatus = status()
        guard currentStatus.isInstalled else {
            return InstallResult(status: currentStatus, message: "deskjig is not installed.")
        }

        guard currentStatus.isSymlink else {
            return InstallResult(
                status: currentStatus,
                error: "Refusing to remove non-symlink at \(installPath)."
            )
        }

        do {
            try removeSymlink(at: installPath)
            return InstallResult(status: status(), message: "Removed deskjig symlink.")
        } catch {
            let newStatus = status()
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            DeskJigLog.error(.cli, "deskjig reset failed", fields: ["error": message])
            return InstallResult(
                status: newStatus,
                error: message,
                manualCommand: manualRemoveCommand()
            )
        }
    }

    // MARK: - Non-privileged filesystem operations

    /// Best-effort symlink creation. Throws `.notWritable` when the destination
    /// directory is not writable by the current user.
    private static func createSymlink(sourcePath: String, destinationPath: String) throws {
        let fileManager = FileManager.default
        let destinationDir = URL(fileURLWithPath: destinationPath).deletingLastPathComponent()

        do {
            if !fileManager.fileExists(atPath: destinationDir.path) {
                try fileManager.createDirectory(at: destinationDir, withIntermediateDirectories: true)
            }

            // Replace whatever is there so a re-install repoints at the current bundle.
            // `fileExists` is false for a dangling symlink, so probe the link itself too.
            if fileManager.fileExists(atPath: destinationPath)
                || (try? fileManager.destinationOfSymbolicLink(atPath: destinationPath)) != nil {
                try fileManager.removeItem(atPath: destinationPath)
            }

            try fileManager.createSymbolicLink(atPath: destinationPath, withDestinationPath: sourcePath)
            DeskJigLog.info(.cli, "deskjig symlink created", fields: ["source": sourcePath, "destination": destinationPath])
        } catch {
            throw InstallError.notWritable(path: destinationPath, underlying: error.localizedDescription)
        }
    }

    private static func removeSymlink(at destinationPath: String) throws {
        do {
            try FileManager.default.removeItem(atPath: destinationPath)
            DeskJigLog.info(.cli, "deskjig symlink removed", fields: ["destination": destinationPath])
        } catch {
            throw InstallError.notWritable(path: destinationPath, underlying: error.localizedDescription)
        }
    }

    // MARK: - Manual fallback commands

    /// Command that installs the symlink with elevated privileges, for the user to
    /// run in Terminal when DeskJig cannot write to `installDirectory` itself.
    static func manualInstallCommand(sourcePath: String? = nil) -> String {
        let source = sourcePath ?? bundledCLIPath() ?? "/Applications/DeskJig.app/Contents/Helpers/deskjig"
        return "sudo mkdir -p \(shellQuoted(installDirectory)) && "
            + "sudo ln -sf \(shellQuoted(source)) \(shellQuoted(installPath))"
    }

    static func manualRemoveCommand() -> String {
        "sudo rm -f \(shellQuoted(installPath))"
    }

    private static func shellQuoted(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    // MARK: - Bundle discovery

    /// Locates the `deskjig` binary shipped inside `DeskJig.app`.
    ///
    /// The app embeds it at `Contents/Helpers/deskjig`, **not** at
    /// `Contents/MacOS/deskjig` the way Bento shipped `bentoctl`. macOS volumes
    /// are case-insensitive by default, so `Contents/MacOS/deskjig` and the app's
    /// own main executable `Contents/MacOS/DeskJig` are the same path: copying the
    /// CLI there overwrites the app binary, and looking it up there would resolve
    /// to the app itself. `Contents/Helpers/` sidesteps both.
    private static func bundledCLIPath() -> String? {
        let appExecutable = Bundle.main.executableURL?
            .resolvingSymlinksInPath()
            .standardizedFileURL
            .path

        let candidates: [URL?] = [
            Bundle.main.bundleURL
                .appendingPathComponent("Contents/Helpers/deskjig"),
            Bundle.main.resourceURL?
                .appendingPathComponent("deskjig"),
            // Sibling of the .app: how a DerivedData build products directory
            // lays the two out before either is installed.
            Bundle.main.bundleURL
                .deletingLastPathComponent()
                .appendingPathComponent("deskjig")
        ]

        for candidate in candidates.compactMap({ $0 }) {
            guard FileManager.default.isExecutableFile(atPath: candidate.path) else { continue }
            // Never hand back the app's own executable (see the case-insensitivity
            // note above) — symlinking /usr/local/bin/deskjig at DeskJig.app would
            // be worse than reporting "not bundled".
            let resolved = candidate.resolvingSymlinksInPath().standardizedFileURL.path
            if let appExecutable, resolved == appExecutable { continue }
            return candidate.path
        }

        return nil
    }

    private static func isInstalledInApplicationsFolder() -> Bool {
        let appURL = Bundle.main.bundleURL.resolvingSymlinksInPath().standardizedFileURL

        #if DEBUG
        if isDebugBuildLocation() {
            return true
        }
        #endif

        let applicationsURL = FileManager.default.urls(for: .applicationDirectory, in: .localDomainMask).first?
            .resolvingSymlinksInPath()
            .standardizedFileURL

        if let applicationsURL {
            return appURL.path.hasPrefix(applicationsURL.path + "/")
        }

        return appURL.path.hasPrefix("/Applications/") || appURL.path.hasPrefix("/System/Volumes/Data/Applications/")
    }

    #if DEBUG
    private static func isDebugBuildLocation() -> Bool {
        let appURL = Bundle.main.bundleURL.resolvingSymlinksInPath().standardizedFileURL
        let path = appURL.path
        return path.contains("/DerivedData/") || path.contains("/Build/Products/")
    }
    #endif

}

enum AgentHookInstaller {
    struct Paths: Equatable {
        let claudeSettingsPath: String
        let codexConfigPath: String
        let claudeHookScriptPath: String
        let codexHookScriptPath: String
        let claudeSkillPath: String
        let codexSkillPath: String

        static var `default`: Paths {
            let home = NSHomeDirectory()
            return Paths(
                claudeSettingsPath: "\(home)/.claude/settings.json",
                codexConfigPath: "\(home)/.codex/config.toml",
                claudeHookScriptPath: "\(home)/.claude/hooks/stop-url-handoff.sh",
                codexHookScriptPath: "\(home)/.codex/hooks/notify-url-handoff.sh",
                claudeSkillPath: "\(home)/.claude/skills/bento-quick-switch/SKILL.md",
                codexSkillPath: "\(home)/.agents/skills/bento-quick-switch/SKILL.md"
            )
        }
    }

    struct IntegrationStatus: Equatable {
        let installPath: String
        let isInstalled: Bool
        let isUpToDate: Bool
        let error: String?

        var hasError: Bool { error != nil }
    }

    struct Status: Equatable {
        let claudeHook: IntegrationStatus
        let claudeSkill: IntegrationStatus
        let codexHook: IntegrationStatus
        let codexSkill: IntegrationStatus
    }

    struct InstallResult: Equatable {
        let status: IntegrationStatus
        let message: String?
        let error: String?
    }

    private enum InstallerError: LocalizedError {
        case invalidRootJSON
        case invalidHooksValue
        case invalidStopHooks
        case invalidCodexManagedBlock
        case unterminatedNotifyArray

        var errorDescription: String? {
            switch self {
            case .invalidRootJSON:
                return "Claude settings JSON must be an object at the root."
            case .invalidHooksValue:
                return "Claude settings has an invalid hooks value."
            case .invalidStopHooks:
                return "Claude Stop hooks must be an array."
            case .invalidCodexManagedBlock:
                return "Codex config contains an invalid DeskJig managed block."
            case .unterminatedNotifyArray:
                return "Codex config has an unterminated top-level notify array."
            }
        }
    }

    private static let claudeManagedMarker = "bento-managed:claude-stop"
    private static let claudeLegacyManagedMarker = "bento-managed:claude-notification"
    private static let codexManagedMarker = "bento-managed:codex-notify"
    private static let claudeStopEventName = "Stop"
    private static let sharedURLGuidanceComment =
        "Guidance: route intent explicitly. Active testing/review => deskjig workspace quick-switch --approve. Show-only webpage/docs context => deskjig url-handoff --mode make-room. Keep --subtext concrete (project + what changed + what to check), avoid generic \"needs your attention\", and pass plain URL tokens with no markdown wrappers or trailing punctuation."
    private static let claudeManagedCommand =
        "bash ~/.claude/hooks/stop-url-handoff.sh # \(claudeManagedMarker) \(sharedURLGuidanceComment)"
    private static let codexManagedCommand =
        "bash ~/.codex/hooks/notify-url-handoff.sh \"$1\" # \(codexManagedMarker) \(sharedURLGuidanceComment)"
    private static let codexManagedBlockBegin = "# BEGIN BENTO CODEX NOTIFY"
    private static let codexManagedBlockEnd = "# END BENTO CODEX NOTIFY"

    // MARK: - Hook Script & Skill Content

    static let claudeHookScriptContent = #"""
    #!/bin/bash
    # bento-managed:claude-stop — Claude Code stop hook fallback.
    #
    # Reads Stop payload JSON from stdin, extracts URLs and intent hints from
    # the assistant's last message, then routes to:
    # - workspace quick-switch (active testing/review)
    # - url-handoff make-room (show this page context)
    #
    # Uses jq when available; falls back to quick-switch if jq is missing.
    set -euo pipefail

    PAYLOAD=$(cat)

    # ── JSON helpers ────────────────────────────────────────────────────
    if command -v jq &>/dev/null; then
      field() { echo "$PAYLOAD" | jq -r ".$1 // empty" 2>/dev/null; }
    else
      # No jq — do a minimal quick-switch (no URL extraction)
      CWD=$(echo "$PAYLOAD" | grep -o '"cwd":"[^"]*"' | head -1 | sed 's/"cwd":"//;s/"$//' || true)
      CWD="${CWD:-$(pwd)}"
      PROJECT=$(basename "$CWD")
      deskjig workspace quick-switch --approve \
        --subtext "${PROJECT:-project}: Review the latest Claude output and code changes." \
        --requester-bundle-id com.anthropic.claudefordesktop \
        --requester-app Claude \
        "$CWD" || true
      exit 0
    fi

    # ── Extract fields ──────────────────────────────────────────────────
    CWD=$(field cwd)
    CWD="${CWD:-$(pwd)}"
    PROJECT=$(basename "$CWD")
    PROJECT="${PROJECT:-project}"

    # Gather text from all payload fields that might contain URLs
    TEXTS=""
    for f in last_assistant_message summary reason title prompt task goal; do
      val=$(field "$f")
      [[ -n "$val" ]] && TEXTS+="$val"$'\n'
    done

    # ── URL extraction ──────────────────────────────────────────────────
    URLS=()
    while IFS= read -r candidate; do
      [[ -z "$candidate" ]] && continue
      # Deduplicate
      for existing in "${URLS[@]+"${URLS[@]}"}"; do
        [[ "$existing" == "$candidate" ]] && continue 2
      done
      URLS+=("$candidate")
    done < <(
      printf '%s\n' "$TEXTS" \
        | grep -oE '(https?://|file://)[^[:space:]]+' \
        | sed -E 's/(\\n|\\r)+$//' \
        | sed "s/[].,)>}'\"\`*_-]*$//"
    )

    # Prefer localhost / file:// URLs
    URL=""
    for u in "${URLS[@]+"${URLS[@]}"}"; do
      if [[ "$u" == *localhost* || "$u" == file://* ]]; then
        URL="$u"
        break
      fi
    done
    [[ -z "$URL" && ${#URLS[@]} -gt 0 ]] && URL="${URLS[0]}"

    # ── Build subtext ───────────────────────────────────────────────────
    REASON=""
    for f in last_assistant_message summary reason title prompt task goal; do
      [[ -n "$REASON" ]] && break
      TEXT=$(field "$f")
      [[ -z "$TEXT" ]] && continue

      # Strip URLs, markdown links, formatting chars, then trim
      CLEANED=$(printf '%s' "$TEXT" \
        | sed -E 's|https?://[^ ]+||g; s|file://[^ ]+||g' \
        | sed -E 's|\[[^]]*\]\([^)]*\)||g' \
        | sed -E 's|[`*_#>]+| |g' \
        | tr -s ' ' \
        | sed 's/^[[:space:][:punct:]-]*//;s/[[:space:][:punct:]-]*$//')
      [[ -z "$CLEANED" ]] && continue

      # Skip well-known generic phrases
      LOWER=$(printf '%s' "$CLEANED" | tr '[:upper:]' '[:lower:]')
      case "$LOWER" in
        "claude needs your attention"*|"needs your attention"|\
        "ready for you to test this workspace"|\
        "let me know when i should check"*)
          continue ;;
      esac

      REASON="$CLEANED"
    done

    # Fallback reason based on URL content
    if [[ -z "$REASON" ]]; then
      URL_LOWER=$(printf '%s' "$URL" | tr '[:upper:]' '[:lower:]')
      if [[ "$URL_LOWER" == *localhost* ]]; then
        REASON="Review local app changes on localhost."
      elif [[ "$URL_LOWER" == *docs* || "$URL_LOWER" == *documentation* ]]; then
        REASON="Review requested documentation."
      elif [[ -n "$URL" ]]; then
        REASON="Review requested webpage."
      else
        REASON="Review the latest Claude output and code changes."
      fi
    fi

    SUBTEXT="${PROJECT}: ${REASON}"
    [[ ${#SUBTEXT} -gt 180 ]] && SUBTEXT="${SUBTEXT:0:177}..."

    LOWER_REASON=$(printf '%s' "$REASON" | tr '[:upper:]' '[:lower:]')
    USE_URL_HANDOFF="false"
    if [[ -n "$URL" ]]; then
      case "$LOWER_REASON" in
        *test*|*verify*|*review*|*manual*|*build*|*debug*|*workspace*|*switch*|*qa*|*regression*)
          USE_URL_HANDOFF="false" ;;
        *)
          USE_URL_HANDOFF="true" ;;
      esac
    fi

    if [[ "$USE_URL_HANDOFF" == "true" ]]; then
      TOAST_MESSAGE="Claude Code wants your attention"
      if [[ -n "$REASON" ]]; then
        TOAST_MESSAGE="Claude Code wants your attention: ${REASON}"
      fi
      [[ ${#TOAST_MESSAGE} -gt 96 ]] && TOAST_MESSAGE="${TOAST_MESSAGE:0:95}…"

      deskjig url-handoff \
        --url "$URL" \
        --mode make-room \
        --toast-message "$TOAST_MESSAGE" \
        --toast-subtext "$SUBTEXT" \
        --requester-bundle-id com.anthropic.claudefordesktop \
        --requester-app "Claude Code" \
        --cwd "$CWD" || true
      exit 0
    fi

    # ── Fire quick-switch (active review/testing) ───────────────────────
    ARGS=(deskjig workspace quick-switch --approve
      --subtext "$SUBTEXT"
      --requester-bundle-id com.anthropic.claudefordesktop
      --requester-app Claude)
    [[ -n "$URL" ]] && ARGS+=(--url "$URL")
    ARGS+=("$CWD")

    "${ARGS[@]}" || true
    """#

    static let codexHookScriptContent = #"""
    #!/bin/bash
    # bento-managed:codex-notify — Codex completion hook fallback.
    #
    # Receives Codex hook JSON payload as argv[1], extracts URLs + intent
    # hints, then routes to:
    # - workspace quick-switch (active testing/review)
    # - url-handoff make-room (show this page context)
    #
    # Uses jq when available; falls back to quick-switch if jq is missing.
    set -euo pipefail

    PAYLOAD="${1:-}"

    # ── JSON helpers ────────────────────────────────────────────────────
    if [[ -n "$PAYLOAD" ]] && command -v jq &>/dev/null; then
      field() { echo "$PAYLOAD" | jq -r ".[\"$1\"] // empty" 2>/dev/null; }
    else
      # No jq or empty payload — do a minimal quick-switch (no URL extraction)
      CWD=""
      if [[ -n "$PAYLOAD" ]]; then
        CWD=$(echo "$PAYLOAD" | grep -o '"cwd":"[^"]*"' | head -1 | sed 's/"cwd":"//;s/"$//' || true)
      fi
      CWD="${CWD:-$(pwd)}"
      PROJECT=$(basename "$CWD")
      deskjig workspace quick-switch --approve \
        --subtext "${PROJECT:-project}: Review the latest Codex output and code changes." \
        --requester-bundle-id com.openai.codex \
        --requester-app Codex \
        "$CWD" || true
      exit 0
    fi

    # ── Extract fields ──────────────────────────────────────────────────
    CWD=$(field cwd)
    CWD="${CWD:-$(pwd)}"
    PROJECT=$(basename "$CWD")
    PROJECT="${PROJECT:-project}"

    # Gather text from all payload fields that might contain URLs
    TEXTS=""
    for f in last-assistant-message input-messages; do
      val=$(field "$f")
      [[ -n "$val" ]] && TEXTS+="$val"$'\n'
    done

    # ── URL extraction ──────────────────────────────────────────────────
    URLS=()
    while IFS= read -r candidate; do
      [[ -z "$candidate" ]] && continue
      # Deduplicate
      for existing in "${URLS[@]+"${URLS[@]}"}"; do
        [[ "$existing" == "$candidate" ]] && continue 2
      done
      URLS+=("$candidate")
    done < <(
      printf '%s\n' "$TEXTS" \
        | grep -oE '(https?://|file://)[^[:space:]]+' \
        | sed -E 's/(\\n|\\r)+$//' \
        | sed "s/[].,)>}'\"\`*_-]*$//"
    )

    # Prefer localhost / file:// URLs
    URL=""
    for u in "${URLS[@]+"${URLS[@]}"}"; do
      if [[ "$u" == *localhost* || "$u" == file://* ]]; then
        URL="$u"
        break
      fi
    done
    [[ -z "$URL" && ${#URLS[@]} -gt 0 ]] && URL="${URLS[0]}"

    # ── Build subtext ───────────────────────────────────────────────────
    REASON=""
    for f in last-assistant-message; do
      [[ -n "$REASON" ]] && break
      TEXT=$(field "$f")
      [[ -z "$TEXT" ]] && continue

      # Strip URLs, markdown links, formatting chars, then trim
      CLEANED=$(printf '%s' "$TEXT" \
        | sed -E 's|https?://[^ ]+||g; s|file://[^ ]+||g' \
        | sed -E 's|\[[^]]*\]\([^)]*\)||g' \
        | sed -E 's|[`*_#>]+| |g' \
        | tr -s ' ' \
        | sed 's/^[[:space:][:punct:]-]*//;s/[[:space:][:punct:]-]*$//')
      [[ -z "$CLEANED" ]] && continue

      # Skip well-known generic phrases
      LOWER=$(printf '%s' "$CLEANED" | tr '[:upper:]' '[:lower:]')
      case "$LOWER" in
        "codex needs your attention"*|"needs your attention"|\
        "ready for you to test this workspace"|\
        "let me know when i should check"*)
          continue ;;
      esac

      REASON="$CLEANED"
    done

    # Fallback reason based on URL content
    if [[ -z "$REASON" ]]; then
      URL_LOWER=$(printf '%s' "$URL" | tr '[:upper:]' '[:lower:]')
      if [[ "$URL_LOWER" == *localhost* ]]; then
        REASON="Review local app changes on localhost."
      elif [[ "$URL_LOWER" == *docs* || "$URL_LOWER" == *documentation* ]]; then
        REASON="Review requested documentation."
      elif [[ -n "$URL" ]]; then
        REASON="Review requested webpage."
      else
        REASON="Review the latest Codex output and code changes."
      fi
    fi

    SUBTEXT="${PROJECT}: ${REASON}"
    [[ ${#SUBTEXT} -gt 180 ]] && SUBTEXT="${SUBTEXT:0:177}..."

    LOWER_REASON=$(printf '%s' "$REASON" | tr '[:upper:]' '[:lower:]')
    USE_URL_HANDOFF="false"
    if [[ -n "$URL" ]]; then
      case "$LOWER_REASON" in
        *test*|*verify*|*review*|*manual*|*build*|*debug*|*workspace*|*switch*|*qa*|*regression*)
          USE_URL_HANDOFF="false" ;;
        *)
          USE_URL_HANDOFF="true" ;;
      esac
    fi

    if [[ "$USE_URL_HANDOFF" == "true" ]]; then
      TOAST_MESSAGE="Codex wants your attention"
      if [[ -n "$REASON" ]]; then
        TOAST_MESSAGE="Codex wants your attention: ${REASON}"
      fi
      [[ ${#TOAST_MESSAGE} -gt 96 ]] && TOAST_MESSAGE="${TOAST_MESSAGE:0:95}…"

      deskjig url-handoff \
        --url "$URL" \
        --mode make-room \
        --toast-message "$TOAST_MESSAGE" \
        --toast-subtext "$SUBTEXT" \
        --requester-bundle-id com.openai.codex \
        --requester-app Codex \
        --cwd "$CWD" || true
      exit 0
    fi

    # ── Fire quick-switch (active review/testing) ───────────────────────
    ARGS=(deskjig workspace quick-switch --approve
      --subtext "$SUBTEXT"
      --requester-bundle-id com.openai.codex
      --requester-app Codex)
    [[ -n "$URL" ]] && ARGS+=(--url "$URL")
    ARGS+=("$CWD")

    "${ARGS[@]}" || true
    """#

    private static let claudeSkillContent = """
    ---
    name: bento-quick-switch
    description: >-
      Route attention correctly: use workspace quick-switch when the user should
      actively test/review code in their workspace; use URL handoff when you only
      need to show a webpage or docs reference. Always include concrete subtext.
    user-invocable: false
    ---

    # DeskJig Quick-Switch

    Use one of two actions:
    - `workspace quick-switch` when the user should actively test, review code, or make a decision in their workspace.
    - `url-handoff` when you only need to show a webpage/docs/preview in Chrome.

    Use quick-switch by default when unsure.

    ```bash
    deskjig workspace quick-switch --approve \\
      --subtext "<project>: <what to review>" \\
      --requester-bundle-id com.anthropic.claudefordesktop \\
      --requester-app Claude \\
      "$(pwd)"
    ```

    ## Parameters

    - `--approve`: **Required.** Always request approval before switching.
    - `--subtext`: Concrete review request — project name + what changed + what to check.
      Format: `"<repo>: <what happened or what to review>"`.
    - `--url <url>`: URL to open in Chrome after workspace restore. If the workspace
      already has a Chrome window, the URL is added as a new tab and focused. If the
      workspace has no Chrome window, the URL is ignored unless `--force-chrome` is set.
    - `--force-chrome`: Create a new Chrome window if the workspace has none. Requires
      `--url`. The new window opens centered (70% width, 80% height) on the workspace's
      primary screen.
    - `--requester-bundle-id`: App bundle ID for icon resolution.
    - `--requester-app`: App display name for the notification headline.
    - Last positional argument: working directory (use `$(pwd)`).

    ## Quick-Switch With URL

    Use this when the user should actively validate behavior, review code changes,
    or run manual tests and you also want to open a related URL.

    ```bash
    # Dev server running
    deskjig workspace quick-switch --approve \\
      --subtext "nexus: localhost:3000 ready for testing" \\
      --url http://localhost:3000 --force-chrome \\
      --requester-bundle-id com.anthropic.claudefordesktop \\
      --requester-app Claude "$(pwd)"

    # Code review + docs reference
    deskjig workspace quick-switch --approve \\
      --subtext "nexus: See relevant API docs for this change" \\
      --url https://docs.example.com/api \\
      --requester-bundle-id com.anthropic.claudefordesktop \\
      --requester-app Claude "$(pwd)"

    # GitHub PR list
    deskjig workspace quick-switch --approve \\
      --subtext "guidebook: GitHub PR page ready to review" \\
      --url https://github.com/armynante/guidebook/pulls --force-chrome \\
      --requester-bundle-id com.anthropic.claudefordesktop \\
      --requester-app Claude "$(pwd)"

    # Decision checkpoint needing user input
    deskjig workspace quick-switch --approve \\
      --subtext "nexus: Need your decision on restore strategy A vs B" \\
      --requester-bundle-id com.anthropic.claudefordesktop \\
      --requester-app Claude "$(pwd)"
    ```

    ## URL Handoff (Show-Only)

    Use this when you want to show a webpage without forcing a workspace switch.
    This is the right tool for "take a look at this page" moments.
    Always use `--mode make-room` so DeskJig uses the animated slide preview path.

    ```bash
    deskjig url-handoff --url https://github.com/armynante/guidebook/pulls --mode make-room \\
      --toast-message "Claude Code wants your attention: PR context" \\
      --toast-subtext "I opened the page I referenced. Close Preview Window to restore layout."
    ```

    ## Decision Gate (Run Before Final Response)

    1) Should the user actively test/review code, run checks, or make a decision in their workspace?
    - Yes -> run `workspace quick-switch --approve` (include `--url` when relevant).

    2) Is this only to show a webpage/docs/preview context?
    - Yes -> run `url-handoff --mode make-room`.

    3) Did the user ask to switch workspaces explicitly?
    - Yes -> quick-switch.

    ## Trigger Examples

    - Task complete — switch user back to review changes
    - Build finished or failed
    - Dev server running (always include `--url` + `--force-chrome`)
    - Deployed preview ready (always include `--url`)
    - GitHub review URL in response (PR list/PR/issue/compare)
    - API/SDK docs URL included *and user should test in workspace*
    - Hit a blocker — need user input

    ## Workspace Targeting

    - Always pass the active directory (`$(pwd)` or explicit path).
    - This lets DeskJig resolve the correct workspace override (`workspaceOverrideName`).
    - If mapping looks wrong, verify with `deskjig --format json workspace quick-switch list`.

    ## Hook Behavior

    - Hooks are fallback automation when explicit commands were not run.
    - Hook routing should match this policy:
      - active test/review -> quick-switch
      - show-only URL context -> url-handoff
    - Explicit skill decisions take priority over hooks.

    ## When NOT to trigger

    - Asking a clarifying question (user sees it inline)
    - Between steps of a multi-step task
    - When the user is actively in the conversation
    """

    private static let codexSkillContent: String = {
        let base = claudeSkillContent
            .replacingOccurrences(of: "com.anthropic.claudefordesktop", with: "com.openai.codex")
            .replacingOccurrences(of: "--requester-app Claude", with: "--requester-app Codex")
        return base + """

        ## Hook vs Shell

        Codex has a completion hook (`~/.codex/config.toml`) that fires automatically
        when Codex finishes a turn. The hook now routes based on intent:
        - active testing/review -> `workspace quick-switch`
        - show-only URL context -> `url-handoff`

        Treat this hook as fallback automation. The skill's decision gate still
        determines whether to run explicit quick-switch or explicit url-handoff.

        For full control over `--subtext` and `--url`, you can also run deskjig
        directly in your shell instead of relying on the automatic hook.
        """
    }()

    static func status(paths: Paths = .default) -> Status {
        Status(
            claudeHook: claudeHookStatus(paths: paths),
            claudeSkill: claudeSkillStatus(paths: paths),
            codexHook: codexHookStatus(paths: paths),
            codexSkill: codexSkillStatus(paths: paths)
        )
    }

    static func installClaudeHook(paths: Paths = .default) async -> InstallResult {
        do {
            // 1. Write the hook script
            try writeAtomically(data: Data(claudeHookScriptContent.utf8), to: paths.claudeHookScriptPath, createBackup: false)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: paths.claudeHookScriptPath)

            // 2. Write settings.json with managed Stop hook
            let contents = try readTextIfPresent(at: paths.claudeSettingsPath)
            var root = try parseClaudeRoot(contents: contents)
            try installClaudeManagedHook(into: &root)
            let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
            try writeAtomically(data: data + Data([0x0A]), to: paths.claudeSettingsPath, createBackup: true)

            let newStatus = claudeHookStatus(paths: paths)
            return InstallResult(
                status: newStatus,
                message: "Installed Claude Code stop hook at \(paths.claudeSettingsPath)",
                error: nil
            )
        } catch {
            let status = claudeHookStatus(paths: paths)
            return InstallResult(
                status: status,
                message: nil,
                error: error.localizedDescription
            )
        }
    }

    static func installClaudeSkill(paths: Paths = .default) async -> InstallResult {
        do {
            try writeAtomically(data: Data(claudeSkillContent.utf8), to: paths.claudeSkillPath, createBackup: false)

            let newStatus = claudeSkillStatus(paths: paths)
            return InstallResult(
                status: newStatus,
                message: "Installed Claude Code skill at \(paths.claudeSkillPath)",
                error: nil
            )
        } catch {
            let status = claudeSkillStatus(paths: paths)
            return InstallResult(
                status: status,
                message: nil,
                error: error.localizedDescription
            )
        }
    }

    static func removeClaudeHook(paths: Paths = .default) async -> InstallResult {
        do {
            // 1. Remove managed hook from settings.json
            try stripClaudeManagedHooksFromSettings(at: paths.claudeSettingsPath)

            // 2. Delete hook script file
            removeFileIfExists(at: paths.claudeHookScriptPath)

            let newStatus = claudeHookStatus(paths: paths)
            return InstallResult(
                status: newStatus,
                message: "Removed Claude Code stop hook",
                error: nil
            )
        } catch {
            let status = claudeHookStatus(paths: paths)
            return InstallResult(
                status: status,
                message: nil,
                error: error.localizedDescription
            )
        }
    }

    static func removeClaudeSkill(paths: Paths = .default) async -> InstallResult {
        removeFileIfExists(at: paths.claudeSkillPath)
        removeParentDirectoryIfEmpty(at: paths.claudeSkillPath)

        let newStatus = claudeSkillStatus(paths: paths)
        return InstallResult(
            status: newStatus,
            message: "Removed Claude Code skill",
            error: nil
        )
    }

    static func installCodexHook(paths: Paths = .default) async -> InstallResult {
        do {
            // 1. Write the hook script
            try writeAtomically(data: Data(codexHookScriptContent.utf8), to: paths.codexHookScriptPath, createBackup: false)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: paths.codexHookScriptPath)

            // 2. Write config.toml with managed notify block
            let contents = try readTextIfPresent(at: paths.codexConfigPath) ?? ""
            let rewritten = try rewriteCodexConfig(contents)
            try writeAtomically(data: Data(rewritten.utf8), to: paths.codexConfigPath, createBackup: true)

            let newStatus = codexHookStatus(paths: paths)
            return InstallResult(
                status: newStatus,
                message: "Installed Codex notify hook at \(paths.codexConfigPath)",
                error: nil
            )
        } catch {
            let status = codexHookStatus(paths: paths)
            return InstallResult(
                status: status,
                message: nil,
                error: error.localizedDescription
            )
        }
    }

    static func installCodexSkill(paths: Paths = .default) async -> InstallResult {
        do {
            try writeAtomically(data: Data(codexSkillContent.utf8), to: paths.codexSkillPath, createBackup: false)

            let newStatus = codexSkillStatus(paths: paths)
            return InstallResult(
                status: newStatus,
                message: "Installed Codex skill at \(paths.codexSkillPath)",
                error: nil
            )
        } catch {
            let status = codexSkillStatus(paths: paths)
            return InstallResult(
                status: status,
                message: nil,
                error: error.localizedDescription
            )
        }
    }

    static func removeCodexHook(paths: Paths = .default) async -> InstallResult {
        do {
            // 1. Remove managed notify block from config.toml
            if let contents = try readTextIfPresent(at: paths.codexConfigPath) {
                let withoutManaged = try stripManagedCodexBlock(in: contents)
                let cleaned = try stripTopLevelNotifyAssignment(in: withoutManaged)
                let trimmed = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.isEmpty {
                    removeFileIfExists(at: paths.codexConfigPath)
                } else {
                    try writeAtomically(data: Data((trimmed + "\n").utf8), to: paths.codexConfigPath, createBackup: true)
                }
            }

            // 2. Delete hook script file
            removeFileIfExists(at: paths.codexHookScriptPath)

            let newStatus = codexHookStatus(paths: paths)
            return InstallResult(
                status: newStatus,
                message: "Removed Codex notify hook",
                error: nil
            )
        } catch {
            let status = codexHookStatus(paths: paths)
            return InstallResult(
                status: status,
                message: nil,
                error: error.localizedDescription
            )
        }
    }

    static func removeCodexSkill(paths: Paths = .default) async -> InstallResult {
        removeFileIfExists(at: paths.codexSkillPath)
        removeParentDirectoryIfEmpty(at: paths.codexSkillPath)

        let newStatus = codexSkillStatus(paths: paths)
        return InstallResult(
            status: newStatus,
            message: "Removed Codex skill",
            error: nil
        )
    }

    /// Convenience: install both Codex hook and skill.
    static func installCodex(paths: Paths = .default) async -> InstallResult {
        let hookResult = await installCodexHook(paths: paths)
        guard hookResult.error == nil else { return hookResult }
        return await installCodexSkill(paths: paths)
    }

    /// Convenience: remove both Codex hook and skill.
    static func removeCodex(paths: Paths = .default) async -> InstallResult {
        let hookResult = await removeCodexHook(paths: paths)
        guard hookResult.error == nil else { return hookResult }
        return await removeCodexSkill(paths: paths)
    }

    // MARK: - Claude

    private static func claudeHookStatus(paths: Paths) -> IntegrationStatus {
        do {
            guard let contents = try readTextIfPresent(at: paths.claudeSettingsPath), !contents.isEmpty else {
                return IntegrationStatus(installPath: paths.claudeSettingsPath, isInstalled: false, isUpToDate: false, error: nil)
            }
            let root = try parseClaudeRoot(contents: contents)
            let (hasManaged, commandUpToDate) = inspectClaudeManagedHook(in: root)
            let scriptUpToDate = (try? readTextIfPresent(at: paths.claudeHookScriptPath)) == claudeHookScriptContent
            return IntegrationStatus(
                installPath: paths.claudeSettingsPath,
                isInstalled: hasManaged,
                isUpToDate: commandUpToDate && scriptUpToDate,
                error: nil
            )
        } catch {
            return IntegrationStatus(
                installPath: paths.claudeSettingsPath,
                isInstalled: false,
                isUpToDate: false,
                error: error.localizedDescription
            )
        }
    }

    private static func claudeSkillStatus(paths: Paths) -> IntegrationStatus {
        let skillUpToDate = (try? readTextIfPresent(at: paths.claudeSkillPath)) == claudeSkillContent
        return IntegrationStatus(
            installPath: paths.claudeSkillPath,
            isInstalled: skillUpToDate,
            isUpToDate: skillUpToDate,
            error: nil
        )
    }

    private static func parseClaudeRoot(contents: String?) throws -> [String: Any] {
        guard let contents, !contents.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return [:]
        }
        let data = Data(contents.utf8)
        let object = try JSONSerialization.jsonObject(with: data)
        guard let dict = object as? [String: Any] else {
            throw InstallerError.invalidRootJSON
        }
        return dict
    }

    private static func inspectClaudeManagedHook(in root: [String: Any]) -> (hasManaged: Bool, isUpToDate: Bool) {
        guard let hooks = root["hooks"] as? [String: Any] else {
            return (false, false)
        }

        var foundManaged = false
        var foundCurrent = false

        for (eventName, eventValue) in hooks {
            guard let eventEntries = eventValue as? [Any] else { continue }
            for entryAny in eventEntries {
                guard let entry = entryAny as? [String: Any] else { continue }
                guard let hookEntries = entry["hooks"] as? [Any] else { continue }
                let matcher = entry["matcher"] as? String
                for hookAny in hookEntries {
                    guard let hook = hookAny as? [String: Any] else { continue }
                    guard
                        let type = hook["type"] as? String,
                        type == "command",
                        let command = hook["command"] as? String,
                        isClaudeManagedCommand(command)
                    else { continue }
                    foundManaged = true
                    if command == claudeManagedCommand, eventName == claudeStopEventName, matcher == nil {
                        foundCurrent = true
                    }
                }
            }
        }

        return (foundManaged, foundCurrent)
    }

    private static func installClaudeManagedHook(into root: inout [String: Any]) throws {
        var hooks = root["hooks"] as? [String: Any] ?? [:]
        if root["hooks"] != nil, !(root["hooks"] is [String: Any]) {
            throw InstallerError.invalidHooksValue
        }

        for (eventName, eventValue) in hooks {
            guard let eventEntries = eventValue as? [Any] else {
                throw InstallerError.invalidHooksValue
            }

            var cleanedEntries: [Any] = []
            cleanedEntries.reserveCapacity(eventEntries.count)

            for entryAny in eventEntries {
                guard var entry = entryAny as? [String: Any] else {
                    cleanedEntries.append(entryAny)
                    continue
                }
                guard var entryHooks = entry["hooks"] as? [Any] else {
                    cleanedEntries.append(entryAny)
                    continue
                }

                entryHooks.removeAll { hookAny in
                    guard let hook = hookAny as? [String: Any] else { return false }
                    guard let type = hook["type"] as? String, type == "command" else { return false }
                    guard let command = hook["command"] as? String else { return false }
                    return isClaudeManagedCommand(command)
                }

                if entryHooks.isEmpty {
                    continue
                }
                entry["hooks"] = entryHooks
                cleanedEntries.append(entry)
            }

            if cleanedEntries.isEmpty {
                hooks.removeValue(forKey: eventName)
            } else {
                hooks[eventName] = cleanedEntries
            }
        }

        var stopEntries = hooks[claudeStopEventName] as? [Any] ?? []
        if hooks[claudeStopEventName] != nil, !(hooks[claudeStopEventName] is [Any]) {
            throw InstallerError.invalidStopHooks
        }

        let managedEntry: [String: Any] = [
            "hooks": [[
                "type": "command",
                "command": claudeManagedCommand
            ]]
        ]
        stopEntries.append(managedEntry)
        hooks[claudeStopEventName] = stopEntries
        root["hooks"] = hooks
    }

    private static func isClaudeManagedCommand(_ command: String) -> Bool {
        command.contains(claudeManagedMarker)
            || command.contains(claudeLegacyManagedMarker)
            || command.contains("stop-url-handoff.sh")
    }

    // MARK: - Codex

    private static func codexHookStatus(paths: Paths) -> IntegrationStatus {
        do {
            guard let contents = try readTextIfPresent(at: paths.codexConfigPath), !contents.isEmpty else {
                return IntegrationStatus(installPath: paths.codexConfigPath, isInstalled: false, isUpToDate: false, error: nil)
            }
            let (hasManaged, tomlUpToDate) = inspectCodexManagedBlock(in: contents)
            let scriptUpToDate = (try? readTextIfPresent(at: paths.codexHookScriptPath)) == codexHookScriptContent
            return IntegrationStatus(
                installPath: paths.codexConfigPath,
                isInstalled: hasManaged,
                isUpToDate: tomlUpToDate && scriptUpToDate,
                error: nil
            )
        } catch {
            return IntegrationStatus(
                installPath: paths.codexConfigPath,
                isInstalled: false,
                isUpToDate: false,
                error: error.localizedDescription
            )
        }
    }

    private static func codexSkillStatus(paths: Paths) -> IntegrationStatus {
        let skillUpToDate = (try? readTextIfPresent(at: paths.codexSkillPath)) == codexSkillContent
        return IntegrationStatus(
            installPath: paths.codexSkillPath,
            isInstalled: skillUpToDate,
            isUpToDate: skillUpToDate,
            error: nil
        )
    }

    private static func inspectCodexManagedBlock(in contents: String) -> (hasManaged: Bool, isUpToDate: Bool) {
        guard let beginRange = contents.range(of: codexManagedBlockBegin) else {
            return (false, false)
        }
        guard let endRange = contents.range(of: codexManagedBlockEnd, range: beginRange.upperBound..<contents.endIndex) else {
            return (true, false)
        }

        let block = String(contents[beginRange.lowerBound..<endRange.upperBound])
        let expected = managedCodexNotifyBlock()
        return (true, block == expected)
    }

    private static func rewriteCodexConfig(_ rawContents: String) throws -> String {
        let withoutManaged = try stripManagedCodexBlock(in: rawContents)
        let cleaned = try stripTopLevelNotifyAssignment(in: withoutManaged)
        let body = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        let managed = managedCodexNotifyBlock()
        if body.isEmpty {
            return managed + "\n"
        }
        return managed + "\n\n" + body + "\n"
    }

    private static func stripManagedCodexBlock(in contents: String) throws -> String {
        guard let beginRange = contents.range(of: codexManagedBlockBegin) else {
            return contents
        }
        guard let endRange = contents.range(of: codexManagedBlockEnd, range: beginRange.upperBound..<contents.endIndex) else {
            throw InstallerError.invalidCodexManagedBlock
        }

        var updated = contents
        updated.removeSubrange(beginRange.lowerBound..<endRange.upperBound)
        return updated
    }

    private static func stripTopLevelNotifyAssignment(in contents: String) throws -> String {
        let lines = contents.components(separatedBy: .newlines)
        var output: [String] = []
        output.reserveCapacity(lines.count)

        var lineIndex = 0
        while lineIndex < lines.count {
            let line = lines[lineIndex]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.range(of: #"^notify\s*="#, options: .regularExpression) != nil else {
                output.append(line)
                lineIndex += 1
                continue
            }

            guard let equalsIndex = trimmed.firstIndex(of: "=") else {
                output.append(line)
                lineIndex += 1
                continue
            }

            let rhs = trimmed[trimmed.index(after: equalsIndex)...].trimmingCharacters(in: .whitespaces)
            if rhs.hasPrefix("[") {
                var bracketBalance = rhs.reduce(0) { balance, character in
                    if character == "[" { return balance + 1 }
                    if character == "]" { return balance - 1 }
                    return balance
                }
                lineIndex += 1
                while bracketBalance > 0 && lineIndex < lines.count {
                    bracketBalance += lines[lineIndex].reduce(0) { balance, character in
                        if character == "[" { return balance + 1 }
                        if character == "]" { return balance - 1 }
                        return balance
                    }
                    lineIndex += 1
                }
                if bracketBalance > 0 {
                    throw InstallerError.unterminatedNotifyArray
                }
                continue
            }

            lineIndex += 1
        }

        return output.joined(separator: "\n")
    }

    private static func managedCodexNotifyBlock() -> String {
        // Codex appends the JSON payload as a single extra arg after the TOML
        // array, so the exec becomes: sh -lc '<cmd>' '_' '<json>'.
        // In sh -c, the word after the command string is $0, the next is $1.
        // The literal '_' placeholder occupies $0 so the JSON payload lands
        // in $1 where the script expects it.
        """
        \(codexManagedBlockBegin)
        notify = ['sh', '-lc', '\(codexManagedCommand)', '_']
        \(codexManagedBlockEnd)
        """
    }

    // MARK: - Removal helpers

    private static func stripClaudeManagedHooksFromSettings(at path: String) throws {
        guard let contents = try readTextIfPresent(at: path), !contents.isEmpty else { return }
        var root = try parseClaudeRoot(contents: contents)
        guard var hooks = root["hooks"] as? [String: Any] else { return }

        if root["hooks"] != nil, !(root["hooks"] is [String: Any]) {
            throw InstallerError.invalidHooksValue
        }

        for (eventName, eventValue) in hooks {
            guard let eventEntries = eventValue as? [Any] else {
                throw InstallerError.invalidHooksValue
            }

            var cleanedEntries: [Any] = []
            for entryAny in eventEntries {
                guard var entry = entryAny as? [String: Any] else {
                    cleanedEntries.append(entryAny)
                    continue
                }
                guard var entryHooks = entry["hooks"] as? [Any] else {
                    cleanedEntries.append(entryAny)
                    continue
                }
                entryHooks.removeAll { hookAny in
                    guard let hook = hookAny as? [String: Any] else { return false }
                    guard let type = hook["type"] as? String, type == "command" else { return false }
                    guard let command = hook["command"] as? String else { return false }
                    return isClaudeManagedCommand(command)
                }
                if entryHooks.isEmpty { continue }
                entry["hooks"] = entryHooks
                cleanedEntries.append(entry)
            }

            if cleanedEntries.isEmpty {
                hooks.removeValue(forKey: eventName)
            } else {
                hooks[eventName] = cleanedEntries
            }
        }

        if hooks.isEmpty {
            root.removeValue(forKey: "hooks")
        } else {
            root["hooks"] = hooks
        }

        let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
        try writeAtomically(data: data + Data([0x0A]), to: path, createBackup: true)
    }

    private static func removeFileIfExists(at path: String) {
        let fm = FileManager.default
        if fm.fileExists(atPath: path) {
            try? fm.removeItem(atPath: path)
        }
    }

    private static func removeParentDirectoryIfEmpty(at path: String) {
        let fm = FileManager.default
        let parent = URL(fileURLWithPath: path).deletingLastPathComponent().path
        if let children = try? fm.contentsOfDirectory(atPath: parent), children.isEmpty {
            try? fm.removeItem(atPath: parent)
        }
    }

    // MARK: - File IO

    private static func readTextIfPresent(at path: String) throws -> String? {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: path) else {
            return nil
        }
        return try String(contentsOfFile: path, encoding: .utf8)
    }

    private static func writeAtomically(data: Data, to path: String, createBackup: Bool) throws {
        let fileManager = FileManager.default
        let destinationURL = URL(fileURLWithPath: path)
        let parentURL = destinationURL.deletingLastPathComponent()

        if !fileManager.fileExists(atPath: parentURL.path) {
            try fileManager.createDirectory(at: parentURL, withIntermediateDirectories: true)
        }

        let destinationExists = fileManager.fileExists(atPath: path)
        if createBackup, destinationExists {
            let backupURL = URL(fileURLWithPath: path + ".bak")
            if fileManager.fileExists(atPath: backupURL.path) {
                try fileManager.removeItem(at: backupURL)
            }
            try fileManager.copyItem(at: destinationURL, to: backupURL)
        }

        let tempURL = parentURL.appendingPathComponent(".tmp.\(UUID().uuidString)")
        try data.write(to: tempURL, options: .atomic)
        if destinationExists {
            _ = try fileManager.replaceItemAt(destinationURL, withItemAt: tempURL)
        } else {
            try fileManager.moveItem(at: tempURL, to: destinationURL)
        }
    }
}
