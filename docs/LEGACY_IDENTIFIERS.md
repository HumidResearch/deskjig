# Legacy Identifier Register

DeskJig deliberately retains these identifiers from its commercial predecessor ("Bento", internal name "Nexus") so that existing installs upgrade seamlessly: macOS permission grants (TCC), saved workspaces, running tmux sessions, and the auto-update chain are all keyed to them. Renaming any of these is a breaking migration and needs an explicit decision + migration path.

| Identifier | Where | Why it stays |
|---|---|---|
| `com.mscontrol.bento` (app bundle id) | project build settings, entitlements, defaults suite | Anchors Accessibility/Screen-Recording/AppleEvents TCC grants, the `UserDefaults` domain holding saved workspaces, URL-scheme registration, and Sparkle update identity. |
| `com.mscontrol.bento.bentoctl-helper` | privileged-helper label (SMJobBless), mach-lookup entitlement | Must match any already-installed helper at `/Library/PrivilegedHelperTools/…`. (Helper not in M1; register kept for its return.) |
| `com.mscontrol.bentoctl` | CLI bundle id | CLI identity continuity. |
| `bento://` URL scheme | Info.plist, URL handlers, CLI `app open-url` | Registered with LaunchServices on existing installs; scripts and saved automations use it. |
| `UserDefaults(suiteName: "com.mscontrol.bento")` + `SavedWorkspaces` key | shared manager factory (app + CLI) | THE app↔CLI data contract: both sides read/write this suite so CLI-created workspaces appear in the app and vice versa. Existing Bento workspaces load from here unchanged. |
| `com.mscontrol.bento.workspaces-changed-externally` | DistributedNotificationCenter name | App↔CLI change signal; a mixed-version pair must still hear each other. |
| `~/Library/Logs/Bento/` (+ `restore-trace/`) | app + CLI + diagnostics scripts | All logging/diagnostics tooling agrees on this directory; split-brain logging is the failure mode. Rename-later once app+CLI always ship in lockstep. |
| `/tmp/bento-tmux-<uid>.sock` | tmux command service | The live tmux server socket — renaming orphans users' running sessions on first launch. |
| `bento:<dir>:<idx>` terminal window-title token (+ persisted `bentoTitle` strategy raw value) | terminal launchers, window matching, saved snapshots | Titles live on already-open terminal windows and in saved snapshot data; renaming breaks matching existing windows on the first restore after upgrade. |
| `com.nexus.windowsnapshot` UTI | Info.plist exported type | Existing `.windowsnapshot` files keep their type binding. |
| `/usr/local/bin/bentoctl` | CLI install path | Existing PATH usage and user scripts. DeskJig ships `deskjig` and maintains a `bentoctl` compat symlink. |
| `BentoAllowAppRestoreURL` defaults key | release-build restore-URL gate | Documented user-facing key on existing installs. |
| Keychain access group `$(AppIdentifierPrefix)com.mscontrol.bento` | entitlements | Keeps stored items readable. |
| `BENTO_*` environment variables | logging/debug/tooling | Read as-is for now; plan is `DESKJIG_*` with `BENTO_*` fallback (rename-later). |
| `com.bento.native` native-messaging host id | Chrome extension pairing | Only if the extension ships; a renamed host id breaks every installed copy of the published extension. New listing = new id + re-pair flow, together. |

Everything not on this list renames to DeskJig at port time.

**Dropped, not carried:** the upstream `keychain-access-groups` entitlement
(`$(AppIdentifierPrefix)com.mscontrol.bento`) existed only for account/auth credential storage,
which DeskJig does not port. Nothing in the codebase touches the keychain, and carrying the
entitlement forces development-certificate signing (ad-hoc builds fail with "requires a
provisioning profile"). Removed in Wave 4.
