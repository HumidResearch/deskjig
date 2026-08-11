// AgentHookInstallerTests.swift
// DeskJigTests

import Foundation
import Testing
@testable import DeskJig

struct AgentHookInstallerTests {
    @Test("Claude hook install creates managed hook and is idempotent")
    func claudeHookInstallIsIdempotent() async throws {
        let tempRoot = try makeTempDirectory(name: "agent-hook-claude-idempotent")
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let paths = makePaths(root: tempRoot)

        let first = await AgentHookInstaller.installClaudeHook(paths: paths)
        #expect(first.error == nil)
        #expect(first.status.isInstalled)
        #expect(first.status.isUpToDate)

        let second = await AgentHookInstaller.installClaudeHook(paths: paths)
        #expect(second.error == nil)
        #expect(second.status.isInstalled)
        #expect(second.status.isUpToDate)

        // Settings.json checks
        let contents = try String(contentsOfFile: paths.claudeSettingsPath, encoding: .utf8)
        #expect(occurrenceCount(of: "bento-managed:claude-stop", in: contents) == 1)
        #expect(contents.contains("\"Stop\""))
        #expect(contents.contains("stop-url-handoff.sh"))

        // Script file checks
        let script = try String(contentsOfFile: paths.claudeHookScriptPath, encoding: .utf8)
        #expect(script.contains("deskjig workspace quick-switch"))
        #expect(script.contains("deskjig url-handoff"))
        #expect(script.contains("USE_URL_HANDOFF"))
        #expect(script.contains("--url"))
        let attrs = try FileManager.default.attributesOfItem(atPath: paths.claudeHookScriptPath)
        #expect(((attrs[.posixPermissions] as? Int) ?? 0) & 0o111 != 0)
    }

    @Test("Claude hook install preserves existing notification hooks and adds Stop hook")
    func claudeHookInstallMergesExistingHooks() async throws {
        let tempRoot = try makeTempDirectory(name: "agent-hook-claude-merge")
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let paths = makePaths(root: tempRoot)

        let initialJSON = """
        {
          "hooks": {
            "Notification": [
              {
                "matcher": "idle_prompt",
                "hooks": [
                  {
                    "type": "command",
                    "command": "echo user-hook"
                  }
                ]
              }
            ]
          }
        }
        """
        try writeText(initialJSON, to: paths.claudeSettingsPath)

        let result = await AgentHookInstaller.installClaudeHook(paths: paths)
        #expect(result.error == nil)
        let contents = try String(contentsOfFile: paths.claudeSettingsPath, encoding: .utf8)
        #expect(contents.contains("echo user-hook"))
        #expect(contents.contains("\"Notification\""))
        #expect(contents.contains("\"Stop\""))
        #expect(contents.contains("bento-managed:claude-stop"))
    }

    @Test("Claude hook install replaces legacy Notification marker with Stop hook")
    func claudeHookInstallMigratesLegacyNotificationMarker() async throws {
        let tempRoot = try makeTempDirectory(name: "agent-hook-claude-legacy-marker")
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let paths = makePaths(root: tempRoot)

        let initialJSON = """
        {
          "hooks": {
            "Notification": [
              {
                "matcher": "permission_prompt|elicitation_dialog",
                "hooks": [
                  {
                    "type": "command",
                    "command": "bentoctl workspace quick-switch --approve --subtext \\"Claude needs your attention.\\" --requester-app \\"Claude\\" \\"$PWD\\" # bento-managed:claude-notification URL guidance: for docs or localhost ports (e.g. http://localhost:3000), pass --url and explain why in --subtext."
                  }
                ]
              }
            ]
          }
        }
        """
        try writeText(initialJSON, to: paths.claudeSettingsPath)

        let result = await AgentHookInstaller.installClaudeHook(paths: paths)
        #expect(result.error == nil)
        let contents = try String(contentsOfFile: paths.claudeSettingsPath, encoding: .utf8)
        #expect(!contents.contains("bento-managed:claude-notification"))
        #expect(contents.contains("bento-managed:claude-stop"))
        #expect(contents.contains("\"Stop\""))
    }

    @Test("Claude parse failure leaves file unchanged")
    func claudeParseFailureDoesNotMutateFile() async throws {
        let tempRoot = try makeTempDirectory(name: "agent-hook-claude-parse-fail")
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let paths = makePaths(root: tempRoot)

        let invalid = "{ invalid json"
        try writeText(invalid, to: paths.claudeSettingsPath)

        let result = await AgentHookInstaller.installClaudeHook(paths: paths)
        #expect(result.error != nil)
        let after = try String(contentsOfFile: paths.claudeSettingsPath, encoding: .utf8)
        #expect(after == invalid)
    }

    @Test("Codex install creates managed notify block and preserves unrelated config")
    func codexInstallPreservesOtherFields() async throws {
        let tempRoot = try makeTempDirectory(name: "agent-hook-codex-merge")
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let paths = makePaths(root: tempRoot)

        let existing = """
        model = "gpt-5"
        sandbox_mode = "danger-full-access"

        [profiles.default]
        approval_policy = "never"
        """
        try writeText(existing, to: paths.codexConfigPath)

        let result = await AgentHookInstaller.installCodex(paths: paths)
        #expect(result.error == nil)
        #expect(result.status.isInstalled)
        #expect(result.status.isUpToDate)

        let contents = try String(contentsOfFile: paths.codexConfigPath, encoding: .utf8)
        #expect(contents.contains("BEGIN BENTO CODEX NOTIFY"))
        #expect(contents.contains("bento-managed:codex-notify"))
        #expect(contents.contains("model = \"gpt-5\""))
        #expect(contents.contains("[profiles.default]"))

        // Hook script checks
        let script = try String(contentsOfFile: paths.codexHookScriptPath, encoding: .utf8)
        #expect(script.contains("deskjig workspace quick-switch"))
        #expect(script.contains("deskjig url-handoff"))
        #expect(script.contains("USE_URL_HANDOFF"))
        #expect(script.contains("--url"))
        #expect(script.contains("com.openai.codex"))
        let attrs = try FileManager.default.attributesOfItem(atPath: paths.codexHookScriptPath)
        #expect(((attrs[.posixPermissions] as? Int) ?? 0) & 0o111 != 0)

        // Skill file checks
        let skill = try String(contentsOfFile: paths.codexSkillPath, encoding: .utf8)
        #expect(skill.contains("bento-quick-switch"))
        #expect(skill.contains("com.openai.codex"))
    }

    @Test("Codex install replaces existing notify and is idempotent")
    func codexInstallReplacesNotifyAndIsIdempotent() async throws {
        let tempRoot = try makeTempDirectory(name: "agent-hook-codex-idempotent")
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let paths = makePaths(root: tempRoot)

        let existing = """
        notify = ["sh", "-lc", "echo old"]
        model = "gpt-5"
        """
        try writeText(existing, to: paths.codexConfigPath)

        let first = await AgentHookInstaller.installCodex(paths: paths)
        #expect(first.error == nil)
        let second = await AgentHookInstaller.installCodex(paths: paths)
        #expect(second.error == nil)

        let contents = try String(contentsOfFile: paths.codexConfigPath, encoding: .utf8)
        #expect(occurrenceCount(of: "BEGIN BENTO CODEX NOTIFY", in: contents) == 1)
        #expect(!contents.contains("echo old"))
    }

    @Test("Codex malformed notify array leaves file unchanged")
    func codexMalformedNotifyArrayDoesNotMutateFile() async throws {
        let tempRoot = try makeTempDirectory(name: "agent-hook-codex-parse-fail")
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let paths = makePaths(root: tempRoot)

        let malformed = """
        notify = [
          "sh",
          "-lc"
        """
        try writeText(malformed, to: paths.codexConfigPath)

        let result = await AgentHookInstaller.installCodex(paths: paths)
        #expect(result.error != nil)
        let after = try String(contentsOfFile: paths.codexConfigPath, encoding: .utf8)
        #expect(after == malformed)
    }

    @Test("Claude hook status reports not up-to-date when script content is outdated")
    func claudeHookStatusDetectsOutdatedScript() async throws {
        let tempRoot = try makeTempDirectory(name: "agent-hook-claude-outdated-script")
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let paths = makePaths(root: tempRoot)

        let first = await AgentHookInstaller.installClaudeHook(paths: paths)
        #expect(first.error == nil)
        #expect(first.status.isUpToDate)

        // Tamper with script file
        try "#!/bin/bash\necho outdated".write(toFile: paths.claudeHookScriptPath, atomically: true, encoding: .utf8)

        let status = AgentHookInstaller.status(paths: paths)
        #expect(status.claudeHook.isInstalled)
        #expect(!status.claudeHook.isUpToDate)

        // Re-install restores up-to-date
        let reinstall = await AgentHookInstaller.installClaudeHook(paths: paths)
        #expect(reinstall.error == nil)
        #expect(reinstall.status.isUpToDate)
    }

    @Test("Claude skill status reports not up-to-date when skill content is outdated")
    func claudeSkillStatusDetectsOutdatedSkill() async throws {
        let tempRoot = try makeTempDirectory(name: "agent-hook-claude-outdated-skill")
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let paths = makePaths(root: tempRoot)

        let first = await AgentHookInstaller.installClaudeSkill(paths: paths)
        #expect(first.error == nil)
        #expect(first.status.isUpToDate)

        // Tamper with skill file
        try "# outdated skill".write(toFile: paths.claudeSkillPath, atomically: true, encoding: .utf8)

        let status = AgentHookInstaller.status(paths: paths)
        #expect(status.claudeSkill.isInstalled == false)
        #expect(!status.claudeSkill.isUpToDate)
    }

    @Test("Codex install writes bento-quick-switch skill")
    func codexInstallWritesSkill() async throws {
        let tempRoot = try makeTempDirectory(name: "agent-hook-codex-skill")
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let paths = makePaths(root: tempRoot)

        let result = await AgentHookInstaller.installCodex(paths: paths)
        #expect(result.error == nil)
        #expect(result.status.isInstalled)
        #expect(result.status.isUpToDate)

        let skill = try String(contentsOfFile: paths.codexSkillPath, encoding: .utf8)
        #expect(skill.contains("bento-quick-switch"))
        #expect(skill.contains("deskjig workspace quick-switch"))
        #expect(skill.contains("com.openai.codex"))
        #expect(skill.contains("--requester-app Codex"))
        #expect(skill.contains("Decision Gate"))
        #expect(skill.contains("deskjig url-handoff"))
        #expect(skill.contains("GitHub PR list"))
        #expect(!skill.contains("deskjig notify"))
    }

    @Test("Claude skill install writes skill file")
    func claudeSkillInstallWritesSkill() async throws {
        let tempRoot = try makeTempDirectory(name: "agent-hook-claude-skill-install")
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let paths = makePaths(root: tempRoot)

        let result = await AgentHookInstaller.installClaudeSkill(paths: paths)
        #expect(result.error == nil)
        #expect(result.status.isInstalled)
        #expect(result.status.isUpToDate)

        // Skill file exists
        let skill = try String(contentsOfFile: paths.claudeSkillPath, encoding: .utf8)
        #expect(skill.contains("bento-quick-switch"))
        #expect(skill.contains("workspaceOverrideName"))
        #expect(skill.contains("Hook Behavior"))
        #expect(skill.contains("URL Handoff (Show-Only)"))
        #expect(!skill.contains("deskjig notify"))
    }

    @Test("Claude hook install cleans up orphaned hooks referencing stop-url-handoff.sh without marker")
    func claudeHookInstallCleansUpOrphanedHooks() async throws {
        let tempRoot = try makeTempDirectory(name: "agent-hook-claude-orphan-cleanup")
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let paths = makePaths(root: tempRoot)

        // Manually add an unmarked hook referencing the script
        let orphanJSON = """
        {
          "hooks": {
            "Stop": [
              {
                "hooks": [
                  {
                    "type": "command",
                    "command": "bash ~/.claude/hooks/stop-url-handoff.sh"
                  }
                ]
              }
            ]
          }
        }
        """
        try writeText(orphanJSON, to: paths.claudeSettingsPath)

        let result = await AgentHookInstaller.installClaudeHook(paths: paths)
        #expect(result.error == nil)

        let contents = try String(contentsOfFile: paths.claudeSettingsPath, encoding: .utf8)
        // Should have exactly one managed command
        #expect(occurrenceCount(of: "bento-managed:claude-stop", in: contents) == 1)
        // The orphaned one (without marker) should be gone
        #expect(occurrenceCount(of: "stop-url-handoff.sh", in: contents) == 1)
    }

    // MARK: - Removal tests

    @Test("Claude hook remove deletes hook artifacts only")
    func claudeHookRemoveDeletesHookArtifacts() async throws {
        let tempRoot = try makeTempDirectory(name: "agent-hook-claude-hook-remove")
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let paths = makePaths(root: tempRoot)

        // Install hook
        let installResult = await AgentHookInstaller.installClaudeHook(paths: paths)
        #expect(installResult.error == nil)

        // Remove hook
        let removeResult = await AgentHookInstaller.removeClaudeHook(paths: paths)
        #expect(removeResult.error == nil)

        // Hook script gone
        #expect(!FileManager.default.fileExists(atPath: paths.claudeHookScriptPath))

        // Settings.json should have no managed hooks
        if FileManager.default.fileExists(atPath: paths.claudeSettingsPath) {
            let contents = try String(contentsOfFile: paths.claudeSettingsPath, encoding: .utf8)
            #expect(!contents.contains("bento-managed:claude-stop"))
            #expect(!contents.contains("stop-url-handoff.sh"))
        }
    }

    @Test("Claude skill remove deletes skill file only")
    func claudeSkillRemoveDeletesSkillFile() async throws {
        let tempRoot = try makeTempDirectory(name: "agent-hook-claude-skill-remove")
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let paths = makePaths(root: tempRoot)

        // Install skill
        let installResult = await AgentHookInstaller.installClaudeSkill(paths: paths)
        #expect(installResult.error == nil)

        // Remove skill
        let removeResult = await AgentHookInstaller.removeClaudeSkill(paths: paths)
        #expect(removeResult.error == nil)

        // Skill file gone
        #expect(!FileManager.default.fileExists(atPath: paths.claudeSkillPath))
    }

    @Test("Claude hook remove preserves user hooks")
    func claudeHookRemovePreservesUserHooks() async throws {
        let tempRoot = try makeTempDirectory(name: "agent-hook-claude-remove-preserves")
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let paths = makePaths(root: tempRoot)

        // Add user hooks first
        let initialJSON = """
        {
          "hooks": {
            "Notification": [
              {
                "matcher": "idle_prompt",
                "hooks": [
                  {
                    "type": "command",
                    "command": "echo user-hook"
                  }
                ]
              }
            ]
          }
        }
        """
        try writeText(initialJSON, to: paths.claudeSettingsPath)

        // Install DeskJig hook
        let installResult = await AgentHookInstaller.installClaudeHook(paths: paths)
        #expect(installResult.error == nil)

        // Verify both exist
        let afterInstall = try String(contentsOfFile: paths.claudeSettingsPath, encoding: .utf8)
        #expect(afterInstall.contains("echo user-hook"))
        #expect(afterInstall.contains("bento-managed:claude-stop"))

        // Remove
        let removeResult = await AgentHookInstaller.removeClaudeHook(paths: paths)
        #expect(removeResult.error == nil)

        // User hook survives
        let afterRemove = try String(contentsOfFile: paths.claudeSettingsPath, encoding: .utf8)
        #expect(afterRemove.contains("echo user-hook"))
        #expect(afterRemove.contains("\"Notification\""))
        #expect(!afterRemove.contains("bento-managed:claude-stop"))
    }

    @Test("Codex remove deletes all artifacts")
    func codexRemoveDeletesAllArtifacts() async throws {
        let tempRoot = try makeTempDirectory(name: "agent-hook-codex-remove")
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let paths = makePaths(root: tempRoot)

        // Install
        let installResult = await AgentHookInstaller.installCodex(paths: paths)
        #expect(installResult.error == nil)
        #expect(installResult.status.isInstalled)

        // Verify artifacts exist
        #expect(FileManager.default.fileExists(atPath: paths.codexConfigPath))
        #expect(FileManager.default.fileExists(atPath: paths.codexSkillPath))
        #expect(FileManager.default.fileExists(atPath: paths.codexHookScriptPath))

        // Remove
        let removeResult = await AgentHookInstaller.removeCodex(paths: paths)
        #expect(removeResult.error == nil)

        // Skill file gone
        #expect(!FileManager.default.fileExists(atPath: paths.codexSkillPath))

        // Hook script gone
        #expect(!FileManager.default.fileExists(atPath: paths.codexHookScriptPath))

        // Config.toml should have no managed block (may be empty/deleted)
        if FileManager.default.fileExists(atPath: paths.codexConfigPath) {
            let contents = try String(contentsOfFile: paths.codexConfigPath, encoding: .utf8)
            #expect(!contents.contains("BEGIN BENTO CODEX NOTIFY"))
            #expect(!contents.contains("bento-managed:codex-notify"))
        }
    }

    @Test("Codex remove preserves unrelated config")
    func codexRemovePreservesOtherConfig() async throws {
        let tempRoot = try makeTempDirectory(name: "agent-hook-codex-remove-preserves")
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let paths = makePaths(root: tempRoot)

        // Add existing config
        let existing = """
        model = "gpt-5"
        sandbox_mode = "danger-full-access"
        """
        try writeText(existing, to: paths.codexConfigPath)

        // Install
        let installResult = await AgentHookInstaller.installCodex(paths: paths)
        #expect(installResult.error == nil)

        // Remove
        let removeResult = await AgentHookInstaller.removeCodex(paths: paths)
        #expect(removeResult.error == nil)

        // Other config survives
        let contents = try String(contentsOfFile: paths.codexConfigPath, encoding: .utf8)
        #expect(contents.contains("model = \"gpt-5\""))
        #expect(contents.contains("sandbox_mode"))
        #expect(!contents.contains("BEGIN BENTO CODEX NOTIFY"))
    }

    // MARK: - Independence tests

    @Test("Hook and skill can be installed simultaneously and report independently")
    func hookAndSkillInstalledSimultaneously() async throws {
        let tempRoot = try makeTempDirectory(name: "agent-hook-claude-both")
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let paths = makePaths(root: tempRoot)

        // Install both
        let hookResult = await AgentHookInstaller.installClaudeHook(paths: paths)
        #expect(hookResult.error == nil)
        #expect(hookResult.status.isInstalled)

        let skillResult = await AgentHookInstaller.installClaudeSkill(paths: paths)
        #expect(skillResult.error == nil)
        #expect(skillResult.status.isInstalled)

        // Both report installed
        let status = AgentHookInstaller.status(paths: paths)
        #expect(status.claudeHook.isInstalled)
        #expect(status.claudeHook.isUpToDate)
        #expect(status.claudeSkill.isInstalled)
        #expect(status.claudeSkill.isUpToDate)

        // Remove hook — skill still installed
        let removeHook = await AgentHookInstaller.removeClaudeHook(paths: paths)
        #expect(removeHook.error == nil)
        let afterHookRemove = AgentHookInstaller.status(paths: paths)
        #expect(!afterHookRemove.claudeHook.isInstalled)
        #expect(afterHookRemove.claudeSkill.isInstalled)

        // Remove skill — both gone
        let removeSkill = await AgentHookInstaller.removeClaudeSkill(paths: paths)
        #expect(removeSkill.error == nil)
        let afterBothRemove = AgentHookInstaller.status(paths: paths)
        #expect(!afterBothRemove.claudeHook.isInstalled)
        #expect(!afterBothRemove.claudeSkill.isInstalled)
    }

    @Test("Codex hook install writes script file and is executable")
    func codexHookInstallWritesScript() async throws {
        let tempRoot = try makeTempDirectory(name: "agent-hook-codex-hook-script")
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let paths = makePaths(root: tempRoot)

        let result = await AgentHookInstaller.installCodexHook(paths: paths)
        #expect(result.error == nil)
        #expect(result.status.isInstalled)
        #expect(result.status.isUpToDate)

        // Script file checks
        let script = try String(contentsOfFile: paths.codexHookScriptPath, encoding: .utf8)
        #expect(script.contains("deskjig workspace quick-switch"))
        #expect(script.contains("--url"))
        #expect(script.contains("com.openai.codex"))
        #expect(script.contains("PAYLOAD=\"${1:-}\""))
        let attrs = try FileManager.default.attributesOfItem(atPath: paths.codexHookScriptPath)
        #expect(((attrs[.posixPermissions] as? Int) ?? 0) & 0o111 != 0)

        // Config.toml updated — must have '_' placeholder so JSON lands in $1
        let contents = try String(contentsOfFile: paths.codexConfigPath, encoding: .utf8)
        #expect(contents.contains("notify-url-handoff.sh"))
        #expect(contents.contains("\"$1\""))
        #expect(contents.contains("'_'"))
    }

    @Test("Codex hook install only — skill file not created")
    func codexHookInstallOnly() async throws {
        let tempRoot = try makeTempDirectory(name: "agent-hook-codex-hook-only")
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let paths = makePaths(root: tempRoot)

        let result = await AgentHookInstaller.installCodexHook(paths: paths)
        #expect(result.error == nil)
        #expect(result.status.isInstalled)

        // Skill NOT created
        #expect(!FileManager.default.fileExists(atPath: paths.codexSkillPath))
    }

    @Test("Codex skill install only — config.toml not touched")
    func codexSkillInstallOnly() async throws {
        let tempRoot = try makeTempDirectory(name: "agent-hook-codex-skill-only")
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let paths = makePaths(root: tempRoot)

        let result = await AgentHookInstaller.installCodexSkill(paths: paths)
        #expect(result.error == nil)
        #expect(result.status.isInstalled)

        // Config.toml NOT created
        #expect(!FileManager.default.fileExists(atPath: paths.codexConfigPath))

        // Skill file exists
        let skill = try String(contentsOfFile: paths.codexSkillPath, encoding: .utf8)
        #expect(skill.contains("bento-quick-switch"))
        #expect(skill.contains("Hook vs Shell"))
    }

    @Test("Codex hook remove preserves skill")
    func codexHookRemovePreservesSkill() async throws {
        let tempRoot = try makeTempDirectory(name: "agent-hook-codex-hook-remove-preserves-skill")
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let paths = makePaths(root: tempRoot)

        // Install both
        let installResult = await AgentHookInstaller.installCodex(paths: paths)
        #expect(installResult.error == nil)

        // Remove hook only
        let removeResult = await AgentHookInstaller.removeCodexHook(paths: paths)
        #expect(removeResult.error == nil)
        #expect(!removeResult.status.isInstalled)

        // Hook script gone
        #expect(!FileManager.default.fileExists(atPath: paths.codexHookScriptPath))

        // Skill still exists
        #expect(FileManager.default.fileExists(atPath: paths.codexSkillPath))

        let status = AgentHookInstaller.status(paths: paths)
        #expect(!status.codexHook.isInstalled)
        #expect(status.codexSkill.isInstalled)
    }

    @Test("Codex skill remove preserves hook")
    func codexSkillRemovePreservesHook() async throws {
        let tempRoot = try makeTempDirectory(name: "agent-hook-codex-skill-remove-preserves-hook")
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let paths = makePaths(root: tempRoot)

        // Install both
        let installResult = await AgentHookInstaller.installCodex(paths: paths)
        #expect(installResult.error == nil)

        // Remove skill only
        let removeResult = await AgentHookInstaller.removeCodexSkill(paths: paths)
        #expect(removeResult.error == nil)
        #expect(!removeResult.status.isInstalled)

        // Skill gone
        #expect(!FileManager.default.fileExists(atPath: paths.codexSkillPath))

        // Hook still installed
        let status = AgentHookInstaller.status(paths: paths)
        #expect(status.codexHook.isInstalled)
        #expect(!status.codexSkill.isInstalled)

        // Config.toml managed block intact
        let contents = try String(contentsOfFile: paths.codexConfigPath, encoding: .utf8)
        #expect(contents.contains("BEGIN BENTO CODEX NOTIFY"))
    }

    @Test("Codex hook status reports not up-to-date when script content is outdated")
    func codexHookStatusDetectsOutdatedScript() async throws {
        let tempRoot = try makeTempDirectory(name: "agent-hook-codex-outdated-script")
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let paths = makePaths(root: tempRoot)

        let first = await AgentHookInstaller.installCodexHook(paths: paths)
        #expect(first.error == nil)
        #expect(first.status.isUpToDate)

        // Tamper with script file
        try "#!/bin/bash\necho outdated".write(toFile: paths.codexHookScriptPath, atomically: true, encoding: .utf8)

        let status = AgentHookInstaller.status(paths: paths)
        #expect(status.codexHook.isInstalled)
        #expect(!status.codexHook.isUpToDate)

        // Re-install restores up-to-date
        let reinstall = await AgentHookInstaller.installCodexHook(paths: paths)
        #expect(reinstall.error == nil)
        #expect(reinstall.status.isUpToDate)
    }

    @Test("Codex install does not affect Claude integrations")
    func codexInstallDoesNotAffectClaude() async throws {
        let tempRoot = try makeTempDirectory(name: "agent-hook-codex-independence")
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let paths = makePaths(root: tempRoot)

        // Install both Claude integrations
        let hookResult = await AgentHookInstaller.installClaudeHook(paths: paths)
        #expect(hookResult.error == nil)
        let skillResult = await AgentHookInstaller.installClaudeSkill(paths: paths)
        #expect(skillResult.error == nil)

        // Install and remove Codex
        let codexResult = await AgentHookInstaller.installCodex(paths: paths)
        #expect(codexResult.error == nil)
        let codexRemove = await AgentHookInstaller.removeCodex(paths: paths)
        #expect(codexRemove.error == nil)

        // Claude integrations unchanged
        let status = AgentHookInstaller.status(paths: paths)
        #expect(status.claudeHook.isInstalled)
        #expect(status.claudeSkill.isInstalled)
        #expect(!status.codexHook.isInstalled)
        #expect(!status.codexSkill.isInstalled)
    }

    // MARK: - Helpers

    private func makePaths(root: URL) -> AgentHookInstaller.Paths {
        AgentHookInstaller.Paths(
            claudeSettingsPath: root.appendingPathComponent(".claude/settings.json").path,
            codexConfigPath: root.appendingPathComponent(".codex/config.toml").path,
            claudeHookScriptPath: root.appendingPathComponent(".claude/hooks/stop-url-handoff.sh").path,
            codexHookScriptPath: root.appendingPathComponent(".codex/hooks/notify-url-handoff.sh").path,
            claudeSkillPath: root.appendingPathComponent(".claude/skills/bento-quick-switch/SKILL.md").path,
            codexSkillPath: root.appendingPathComponent(".agents/skills/bento-quick-switch/SKILL.md").path
        )
    }

    private func makeTempDirectory(name: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(name + "-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func writeText(_ value: String, to path: String) throws {
        let url = URL(fileURLWithPath: path)
        let parent = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        try value.write(to: url, atomically: true, encoding: .utf8)
    }

    private func occurrenceCount(of needle: String, in haystack: String) -> Int {
        haystack.components(separatedBy: needle).count - 1
    }
}
