# DeskJig Port Plan

DeskJig is a clean-room port of a previously commercial macOS workspace manager ("Bento"). Server-dependent code (accounts, subscriptions, cloud sync, remote telemetry) is **never ported** — the app is fully local from the first commit. This document is the canonical wave/tranche plan; tickets reference it.

## Ground rules

- **Trande-based porting, agentic renames.** No mass regex/sed sweeps. Each tranche agent reads every file it ports, renames paths/symbols/strings with judgment (Bento/Nexus → DeskJig), removes server references per the cut manifest, and cleans up as it goes (provably dead code, stale comments, known warts).
- **Every wave lands a checkpoint** before the next opens. Cross-cutting files (Package.swift, project files, workspace, schemes) are owned by the wave's integrator step, not parallelized.
- **Not ported at all:** account/auth/subscription/telemetry subsystems; the binary-space-partition (BSP) tiling engine (frame-based restore positioning stays); the old marketing site; dead `NexusWindow*` project stubs; historical release notes.
- **Legacy identifiers** (bundle id, URL scheme, storage paths/keys, terminal title token) are deliberately retained for continuity with existing installs — see [LEGACY_IDENTIFIERS.md](LEGACY_IDENTIFIERS.md). Everything user-visible gets the DeskJig name.

## Checkpoint ladder

| # | Checkpoint | Command | Signing | GUI/AX |
|---|---|---|---|---|
| A | shared package compiles | `swift build --package-path DeskJigShared` | none | no |
| B | package tests green | `swift test --package-path DeskJigShared` | none | no |
| C | CLI compiles + `--help` runs | `xcodebuild -scheme deskjig … build` | ad-hoc | no |
| D | app compiles | `xcodebuild -scheme DeskJig … build` | ad-hoc | no |
| E | app launches (menu-bar icon, permissions screen) | `open DeskJig.app` | stable dev identity | GUI |
| F | app-hosted headless test plan green | test runner `--plan headless --no-signing` | ad-hoc | no |
| G | CLI↔app contract (workspace list JSON; shared defaults suite + change signal) | `deskjig workspace list --format json` | stable | GUI, no AX |
| H | read-only CLI smoke suite | ported smoke script, steps 0–5 | stable | GUI+AX |

A/B/C/F run in CI; E/G/H are local. Test-runner notes that MUST survive the port: translate test-plan JSON to `-only-testing:` flags (Xcode 26 silently ignores plan selection for Swift Testing), `-parallel-testing-enabled NO`, keep trailing `()` on Swift Testing identifiers, and treat zero-tests-ran as failure.

## Waves

- **Wave 0 — repo + plan (this commit).** Docs skeleton, this plan, legacy-identifier register, tickets.
- **Wave 1 — `DeskJigShared` package → checkpoint A.** Port the shared package (managers, Fluent restoration API, launchers, Chrome/tmux integration, models, UI components, logging) minus the server cut and minus BSP, as ~8–10 tranches by subdirectory (the restoration subsystem splits ~3 ways). Rename the module and the `BentoLog` logging namespace at port time; centralize legacy bundle-identity strings into one `BundleIdentity` type; add a `LogRedaction` utility at the file-log sink (the old redaction lived in the removed remote logger and was a no-op in Debug — the rewrite must not inherit that).
- **Wave 2 — package tests → checkpoint B.** New `Tests/` target; port the ~60 package-scoped test files (the app-hosted bundle keeps only the ~12 app-importing files). This makes `swift test` the inner dev loop.
- **Wave 3 — `deskjig` CLI → checkpoint C.** Port the command layer + handler core (minus auth commands/handlers), flattened into one directory, with a committed shared scheme (the source repo relied on scheme autocreation).
- **Wave 4 — app target → checkpoints D→E.** Port the app minus excluded surfaces; collapse the login wall to permissions-else-content; no privileged-helper target in M1; remove BSP feature UI; first launch = menu-bar icon → permissions screen with zero network. Stable dev signing identity from here so the Accessibility grant persists across rebuilds.
- **Wave 5 — app tests + tooling + CI → checkpoints F/G/H.** App-hosted test bundle, ported test runner + test plans, CI (package build+test job, headless plan job, SwiftLint report-only), ported smoke script, and an explicit app↔CLI contract test (shared defaults suite + external-change notification).

## M1 acceptance

A workspace created in the original Bento app (including Chrome windows on specific profiles and tmux-backed terminal windows) loads and restores correctly in a locally-built DeskJig — same defaults suite, no migration step. Then `main` gets its first push.

## M2 (post-M1)

Signed Developer ID build + notarization, Sparkle feed (new key + GitHub-hosted appcast), release workflow with fork-guards, placeholder download site updated by the release workflow, privileged CLI-install helper, Chrome-extension decision (the AppleScript path may make the extension optional), env-var rename (`DESKJIG_*` with legacy fallback).

## Wave 1 tranche manifests (package: 231 source files → 200 ported + 3 new, 31 excluded)

**Excluded from the package (never ported):** `Authentication/` (8); `Managers/{AuthenticationManager, DatabaseManager, WorkspaceSyncManager, TutorialSyncManager}` (TutorialSyncManager is mined for a new local `TutorialProgressStore`); `Utilities/SentryErrorHandler`; `FluentAPI/{UserAPIClient, UserNamespace, UserAdminNamespace, UserModels}`; `Models/AccountProvider`; `UI/ViewStyles/LoginTextFieldStyle` (auth-dead); **BSP/snapping set (12):** `Managers/{BinaryPartitionLayoutCoordinator, BinaryPartitionLayoutCoordinator+Testing, BinaryPartitionTree, GridSnappingManager, WindowSnappingFeatureControl}`, `UI/{EdgeSnapZoneResolver, GridOverlayView, TopSnapToggle, TopSnapZoneBar, LayoutZoneView, LayoutZoneWindow}`, `Models/DynamicWorkspaceZone`. Referencers needing BSP cut-edits: TraceFileWriter (t1), AXSubroleFiltering + ManagedWindowLifecycleProbe (t3), WindowManager + WindowLayoutManager + OverlayWindowManager (t4), FluentWorkspaceRestorer (t7b). `TilingLayoutManager` (preset layouts) and `DragDropManager` are NOT BSP — ported.

| Tranche | Branch | Scope | Files |
|---|---|---|---|
| t1-foundation | `tranche/w1-t1-foundation` | Logging + Utilities + Extensions + Branding + Protocols + root; creates `BundleIdentity`, `LogRedaction`; `BentoLog`→`DeskJigLog` | 28+2 |
| t2-models | `tranche/w1-t2-models` | Models + DirectoryWorkspace; serialization contract frozen | 31 |
| t3-managers-core | `tranche/w1-t3-managers-core` | AX/window/display core managers | 12 |
| t4-managers-workspace | `tranche/w1-t4-managers-workspace` | Workspace/window managers; UserDefaults-only storage collapse; new `TutorialProgressStore` | 13+1 |
| t5-chrome | `tranche/w1-t5-chrome` | Chrome managers + native messaging + fluent Chrome services | 12 |
| t6a-fluent-window | `tranche/w1-t6a-fluent-window` | Fluent window/app handle core | 12 |
| t6b-fluent-services | `tranche/w1-t6b-fluent-services` | Fluent registries/services/queue/capture; `FluentServices` user-client cut | 18 |
| t7a-executor | `tranche/w1-t7a-executor` | RestorationExecutor + extensions + plan builder | 14 |
| t7b-restorer | `tranche/w1-t7b-restorer` | FluentWorkspaceRestorer, snapshot, locks, telemetry types | 15 |
| t7c-matchers | `tranche/w1-t7c-matchers` | Matchers, positioning, portability, z-order | 14 |
| t8-launchers-tmux | `tranche/w1-t8-launchers-tmux` | Launchers + tmux services; title-token + socket contracts frozen | 15 |
| t9-ui | `tranche/w1-t9-ui` | Shared UI minus snapping/auth; `BentoButtonStyle`→`DeskJigButtonStyle` | 16 |

Cross-tranche contracts fixed up front: `BundleIdentity` API (legacy identifier constants — values never change); `DeskJigLog` / `DeskJigButtonStyle` / `TmuxCommandService.listManagedSessions()` renames; persisted coding keys frozen (`windowsByBentoTitle`, `bentoTitle` raw value, workspace JSON); `BENTO_*` env names kept (rename is issue #13). Integrator owns `DeskJigShared/Package.swift` (deps: CocoaLumberjack, GRDB only; Swift 5 language mode + targeted strict concurrency, macOS 14) and merges tranche branches, looping `swift build --package-path DeskJigShared` to checkpoint A.

### Wave 1 integration addendum (checkpoint A)

Four tranche branches — `t1-foundation`, `t3-managers-core`, `t4-managers-workspace`, `t9-ui` — landed **empty**: their agents read the reference sources and never wrote a file. The integrator ported all four in the integration branch rather than reopening the tranches, following the rules above. Two deviations from the tranche manifests, both deliberate:

- **`Extensions/Notification.swift` not ported.** Its entire contents (`showPasswordReset`, `subscriptionSuccess`, `passwordResetCode`) belong to the cut auth/subscription surfaces. t1 therefore lands 27 ported files + 2 new (`BundleIdentity`, `LogRedaction`), not 28+2.
- **`Managers/AXSubroleFiltering.swift` and `Managers/ManagedWindowLifecycleProbe.swift` not ported.** The manifest lists them as BSP *referencers* needing cut-edits, but each file is in its entirety an `extension BinaryPartitionLayoutCoordinator` — with BSP excluded there is nothing left to port, so both are dropped rather than reduced to empty stubs. t3 lands 10 files, not 12.

Commercial fonts are gone with the rest of the bundled assets: `Branding+Fonts.swift` drops the `PPNeueCorp` and `BerkeleyMono` name tables (and `AppFontFamily.berkeleyMono`), leaving the system-font path. Expected UI impact: brand mono styles render in the system monospaced face, and display styles in SF — the type scale, line heights and tracking are unchanged. The removed `Font.brand(size:style:)` / `NSFont.brand*Font` helpers force-unwrapped `NSFont(name:)` and would have trapped at runtime without the licensed fonts installed; no caller in the package used them.
