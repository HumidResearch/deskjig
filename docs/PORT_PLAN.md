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

### Wave 2 integration addendum (checkpoint B)

`swift test --package-path DeskJigShared` runs **256 tests in 46 suites, green**, stable across repeated runs.

**Tranche delivery.** As in Wave 1, tranches landed short: `w2-a-restoration` produced no commits at all and `w2-b-workspace` produced one uncommitted file, leaving 44 of the 58 Headless-whitelist suites unported. `w2-c-chrome-ax` (14 files) and `w2-d-launchers-cli` (12 files) delivered in full. The integrator ported the recoverable remainder directly from the reference `BentoTests` bundle rather than reopening the tranches. The transform is mechanical: `NexusShared` → `DeskJigShared`, `BentoLog` → `DeskJigLog`, and app-target imports (`@testable import Bento`) redirected at the package module. Whitelist coverage is now **41 of 58 suites**; the 17 absent are itemized below and every one has a reason.

**The environment gate.** The old app-hosted bundle expressed the safe/unsafe split with Xcode test plans: `BentoTests-Headless.xctestplan` whitelisted what CI could run unattended, and everything outside it needed a logged-in session with Accessibility permission, running apps, a window server, Chrome, or tmux. SwiftPM has no test-plan concept, so the whitelist is carried into source. `Tests/TestEnvironment.swift` exposes `envTestsEnabled` (`DESKJIG_ENV_TESTS=1`); whitelisted suites run by default and every other suite carries `.enabled(if: TestEnvironment.envTestsEnabled, ...)` (XCTest suites use `try XCTSkipUnless` in `setUpWithError`). **The gated suites drive real windows and applications on the host — never run them on a machine whose desktop session matters.**

Six gated suites:

| Suite | Why gated |
|---|---|
| `FluentAPIIntegrationTests` | Drives real windows/apps ("REAL SYSTEM"); keeps its `.serialized` trait |
| `ChromeExtensionSetupManagerNativeHostStatusTests` | Exercises `ChromeExtensionSetupManager.shared` against real native-host manifest locations |
| `ChromeNativeMessagingServiceTimeoutTests` | Real socket I/O with wall-clock timeout assertions; flaky off a quiescent machine |
| `WindowLookupWindowDictionaryTests` | Queries the live `CGWindowList`; `candidatesChecked` is machine-dependent |
| `CLIAppAliasCodexTests` | Spawns the `bentoctl` executable (see below) |
| `WorkspaceCreateFromSpecCommandTests` | Spawns the `bentoctl` executable (see below) |

The last two are a **discrepancy against the old CLI plan**, not a port defect. `BentoTests-CLI.xctestplan` ran its five suites headlessly because `bentoctl` sat next to the app-hosted test bundle at `Contents/MacOS/bentoctl`. The SwiftPM lane has no host app and does not build `bentoctl` (that is Wave 3), so both suites failed with *"The file `bentoctl` doesn't exist"* — an environment dependency, so they move to the gated set. `bentoctlURL()` now honors a `DESKJIG_BENTOCTL` path override so the gate stays satisfiable. The other three CLI-plan suites (`FluentLauncherFactoryCodexTests`, `OpenByPathMatcherCodexTests`, `FluentXcodeLauncherMatcherTests`) are pure logic and stay ungated. All five keep `.serialized`, matching the isolation the separate CLI lane implied.

`WorkspaceCreateFromSpecCommandTests/presetAndExplicitLayoutsRoundTrip` stays disabled: `BentoTests-Full.xctestplan` listed it in `skippedTests`, and with no test plans that skip becomes an inline `.disabled(...)`.

**Test deletions — API this port never carries** (per the Wave 1 exclusions above):

- Auth: `AuthenticationManagerSignupNotificationTests`, `LoginViewModelTests`
- Cloud sync: `WorkspaceSyncManagerMergeTests`
- BSP/snapping: `BinaryPartitionLayoutCoordinatorTests` (with its nested `BinaryPartitionSnappingHandoffTests` and `BinaryPartitionLayoutCoordinatorLiveWindowManagerTests`), `WindowSnappingFeatureControlTests`, `EdgeSnapZoneResolverTests`
- `BentoLogTests`: the `LogSubsystem.windowBSP` assertions and `testTraceFileWriterCapturesBspLogs`, which covered BSP trace routing removed from `TraceFileWriter` in t1

**Deferred to Wave 4 — app-target (`Nexus/`) code, not package code.** These are not deletions; they belong to the app target's own test lane and should be revived there: `AgentHookInstallerTests` (`AgentHookInstaller` lives in `Nexus/Model/BentoCLIInstaller.swift`), `AppDelegateQuickSwitchChromeInjectionTests`, `BentoTests` (`LoggingController`, `TelemetryPermissionController`), `LoggingConfigurationVerboseSinkTests`, `InlineScreenSelectionStateTests`, `QuickSwitchViewModelTests`, `SingleInstanceGuardSelectionTests`, `WorkspaceDraftViewModelTests`, `WorkspaceLaunchSourcePolicyTests`, and the single `urlHandoffScreenGeometryUsesPrimaryDisplayAnchor` test inside `WorkspaceDisplayTopologyTests` (`URLHandoffScreenGeometry` lives in `Nexus/App/AppDelegate.swift`).

**Seam fixes.** Tranches C and D both shipped `MockAXWindowEnumerator` — C in the shared `Tests/MockAXWindowService.swift`, D inline in `TerminalSupplementationServiceInjectionTests.swift`. The two copies were byte-identical; the inline one is gone and the shared file is the single copy, matching the upstream layout. All four tranches added an identical `testTarget` stanza to `Package.swift`, which merged to one copy without conflict.

**No `Sources/` changes were needed** — every failure traced to the test port or the environment, none to Wave 1 source behavior.

### Wave 3 integration addendum (checkpoint C)

`xcodebuild -workspace DeskJig.xcworkspace -scheme deskjig -configuration Debug -derivedDataPath build/deskjig -destination platform=macOS,arch=arm64 CODE_SIGNING_ALLOWED=NO build` is **green from clean**, and the built `deskjig` runs `--help` and `--version` at exit 0.

**Tranche delivery.** All three tranches (`w3-a-commands` 19 files, `w3-b-core-exec` 10, `w3-c-core-handlers` 9) delivered in full and were disjoint under `DeskJigCLI/Sources/` — the first wave to merge with no conflicts and nothing for the integrator to port. The command tree is `workspace, url-handoff, window, app, chrome, display, debug, logs, open, permissions, install, notify`; there is no `auth` subcommand and no auth handler, as planned.

**Structure created (integrator-owned, per the ground rules):**

- `DeskJigCLI/DeskJigCLI.xcodeproj` — `objectVersion = 77`, one command-line-tool target `deskjig` (product `deskjig`), and **one** `PBXFileSystemSynchronizedRootGroup` at `Sources/` with zero per-file references, so new source files need no project edit.
- `DeskJig.xcworkspace` — members are `group:DeskJigShared` and `DeskJigCLI/DeskJigCLI.xcodeproj`. The target consumes `DeskJigShared` through an `XCSwiftPackageProductDependency` carrying **no `package` key**, resolved by the workspace group; this is exactly how the source repo wired `NexusShared`. The app project joins in Wave 4. `swift-argument-parser` (upToNextMajor 1.4.0) is the project's own remote package reference, as before.
- `DeskJigCLI/DeskJigCLI.xcodeproj/xcshareddata/xcschemes/deskjig.xcscheme` — **committed**, closing the documented fresh-clone fragility: the source repo relied on Xcode autocreating the scheme, so `xcodebuild -scheme` failed on a clean checkout until the project had been opened in the IDE once.
- `DeskJigCLI/DeskJigCLI.entitlements` — ported byte-for-byte (`app-sandbox` false, `automation.apple-events` true, `network.client` true). See the flag below.

**Deliberate deviations from the reference project settings:**

| Setting | Reference | Here | Why |
|---|---|---|---|
| `DEVELOPMENT_TEAM` | `7P9UN8DHNA` hardcoded in all four configs | absent | A fresh clone must build with no Apple Developer account. `CODE_SIGN_STYLE = Automatic` plus ad-hoc signing covers the local loop; `DeskJigCLI/DeskJigCLI.xcconfig` carries an optional `#include? "Local.xcconfig"` so a developer can set their own team in a gitignored file. Wave 4 needs a stable identity for the app (TCC grant persistence), not for the CLI. |
| `MACOSX_DEPLOYMENT_TARGET` | 15.6 | 14.0 | Matches `DeskJigShared`'s `.macOS(.v14)` platform; the reference target was stricter than its own package for no stated reason. |
| `SWIFT_STRICT_CONCURRENCY` | unset (Xcode default) | `targeted` | Makes the CLI target agree with the package's `-strict-concurrency=targeted`; the reference left the two lanes on different settings. |
| `EXCLUDED_SOURCE_FILE_NAMES` | `bentoctl/main.swift` | absent | No longer needed — see the seam fix. |
| `PRODUCT_BUNDLE_IDENTIFIER` | `com.mscontrol.bentoctl` | unchanged | Frozen legacy value (LEGACY_IDENTIFIERS.md). |

**Seam fix (one, and the only build error in the whole integration).** `DeskJigCLI/Sources/main.swift` — a comment-only placeholder reading "Entry point is provided by `@main` on DeskJigCommand" — was deleted. Any file named `main.swift` makes its module top-level-code, which is illegal alongside `@main`: `error: 'main' attribute cannot be used in a module that contains top-level code`. The reference kept the file on disk and neutralized it with `EXCLUDED_SOURCE_FILE_NAMES` because its synchronized group spanned two source roots (`BentoCLI/Core` plus `../bentoctl`) and the file disambiguated which root owned the entry point. The ported layout is a single `Sources/` root, so the file had no job left. No other cross-tranche seam needed touching — no renamed-symbol drift, no package-API drift, no import fixes.

**`--version` prints `unknown`, by inheritance, and needs a Wave 4/5 decision.** `DeskJigVersion.current` resolves `CFBundleShortVersionString` first, then a `version.json` walked up from the executable, then falls back to the literal `"unknown"`. A command-line tool has no Info.plist unless one is embedded, and the DeskJig repo has no root `version.json` (the source repo did: `{"marketing": "1.1.8-rc.3", "xcode": "1.1.8", "build": 106, ...}`). Both inputs are release-infrastructure artifacts and picking DeskJig's opening version number is not an integrator call, so the fallback stands for now. Fixing it is either a root `version.json` or `GENERATE_INFOPLIST_FILE` + `CREATE_INFOPLIST_SECTION_IN_BINARY` + `MARKETING_VERSION` on the tool target.

**Binary name and compat.** The product is `deskjig`; `install` creates `/usr/local/bin/deskjig` only. LEGACY_IDENTIFIERS.md states DeskJig "ships `deskjig` and maintains a `bentoctl` compat symlink" — that second symlink does not exist in the ported `InstallCommand`. Left alone deliberately: `install` resolves a bundled binary inside `DeskJig.app` and cannot be exercised until Wave 4 ships the app bundle, so the compat symlink is a Wave 4/5 item, tracked here so it is not lost.

**CLI↔app data contract is already live (checkpoint G preview).** `deskjig workspace list --format json` exits 0 against the legacy `UserDefaults(suiteName: "com.mscontrol.bento")` / `SavedWorkspaces` store and reads existing Bento workspaces unchanged — no migration, exactly as the register intends. It needs no Accessibility grant (it is a pure defaults read), so it is not a checkpoint-H-style AX exercise.
