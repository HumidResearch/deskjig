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

## Wave 4 tranche manifests (app: 208 source files → 169 ported, 39 excluded)

Scope of the count: everything under `Nexus/` (203 `.swift`) plus `BentoNativeHost/` (5 `.swift`). 39 files are cut, 169 are ported and partitioned into 8 disjoint tranches. Non-Swift app inputs (`Config/Info.plist`, `Nexus/Configs/*.xcconfig`, `Nexus/Nexus.entitlements`, `Nexus/Configurations/menu-*.json`, `Nexus/BentoLoadingIndicator.lottie`, `Nexus/Assets.xcassets`) ride with the tranche that owns their consumer; the app `.xcodeproj`, target settings, signing identity, and asset catalog wiring are integrator-owned.

**Excluded from the app target (never ported), 39:**

- `App/` (11): `GatewayURLProvider`, `GatewayLoggingConfiguration`, `GatewayLogClient`, `GatewaySentryForwarder`, `SentryLogger`, `BetterStackLogger`, `TelemetryPermissionController`, `NotificationService`, `CognitoAuthorizationClient`, `CLISessionBroker`, `CLISessionServer`.
- `App/Startup/` (2): `StartupTelemetryCoordinator`, `EarlyStartupCoordinator` (replaced inline in `AppDelegate.performStartupInitialization`).
- `UI/Authentication/` (9): all.
- `UI/Subscription/` (8 of 9): `SubscriptionManager`, `SubscriptionProvider`, `SubscriptionView`, `SubscriptionSuccessView`, `UnpaidUserView`, `ValidationFailedView`, `ValidationLoadingView`, `TrialLimitModal`. **`UpgradeBadge.swift` relocates** to `UI/SettingsComponents/` (tranche c) — 3 surviving consumers, and in `SettingsSidebar` it is already the *Sparkle update* badge.
- Other (7): `Model/LoginViewModel`, `Services/AuthenticationManagerAuthProvider` (directory disappears), `UI/LimitedSettingsView` (its `openLogsFolder()` at :433 is byte-identical to `SettingsScreen`'s at :1324 — verified, so the file drops with nothing to salvage), `UI/PSWorkspaceView` (orphaned), `UI/ViewModifiers/EmailVerificationRefreshModifier` (orphaned), `UI/SettingsUI/AddonsView` (Pro Tools store), `UI/SnapshotViewer/UsersDetailView` (Firestore user doc + admin panel).
- `CLIHelper/` (2): `BentoCLIBlessHelper`, `BentoCLIBlessHelperProtocol` — **M1 decision: no privileged-helper target.** This is a Wave-4 cut, not an e1 §2.27 edit; the helper (and its `-Info.plist` / `-Launchd.plist`) returns in M2.

| Tranche | Scope | Files |
|---|---|---:|
| a-app-core | `App/` survivors: `BentoApp`→`DeskJigApp`, `AppDelegate`, `LoggingController`, `AppURLHelper`, `SingleInstanceGuard`, `Debug/GUIRestoreParityRunner`; owns `Config/Info.plist` + `Configs/*.xcconfig` + entitlements edits | 6 |
| b-model | `Model/` survivors minus onboarding/permissions/chrome VMs, plus `Extensions/`; `WorkspaceViewModel` Sentry cut; `BentoCLIInstaller` de-privileged | 13 |
| c-settings-core | `SettingsScreen`, `SettingsSidebar`, `BentoContentView`→`DeskJigContentView`, `MenuBarView`, `QuickSwitchView(+Settings)`, Sparkle controller + 2 delegates, relocated `UpgradeBadge` | 10 |
| d-settings-rest | remaining `SettingsUI` + `SettingsComponents` + `ChromeExtension` (+ its VM) + `NotificationPresenter` + `URLHandoff` + `ViewModifiers` + `Animations+Transitions` | 40 |
| e-designsystem | `UI/DesignSystem` (DS* component library) | 33 |
| f-actionpanel-rootui | `UI/ActionPanel` (+`WorkspaceEditor`) + `UI/` root survivors + onboarding/permissions VMs and overlays | 40 |
| g-snapshotviewer | `UI/SnapshotViewer` minus `UsersDetailView` | 22 |
| h-nativehost | `BentoNativeHost/` → `DeskJigNativeHost/` package, executable product name kept `BentoNativeHost` | 5 |

**Wave-4 cross-tranche contracts:**

- **Auth wall collapse (a).** `BentoApp.swift:803-816` becomes `if windowManager.shouldShowPermissionsScreen { PermissionsView() } else { DeskJigContentView(…) }`. `PermissionsView` ships in f, `DeskJigContentView` in c — a builds against both.
- **`UpgradeBadge` relocation (c).** File moves out of `UI/Subscription/` into `UI/SettingsComponents/`; only the Sparkle update-available meaning survives. Consumers: `SettingsScreen:777`, `SettingsSidebar:268`, `BentoContentView:476` — all in c.
- **`TutorialProgressStore` (b, d, f).** Wave 1 replaced `TutorialSyncManager` with a local `TutorialProgressStore` in `DeskJigShared`. Consumers are `SimpleOnboardingViewModel:35/:50/:119` and `OnboardingTutorialViewModel:40/:55/:90` (f) and `ChromeExtensionSetupViewModel:211/:223` (d) — all lose the `for: userID` argument. Without this the onboarding-complete flag silently resets on every launch.
- **BSP cut (a, c, f).** App-side reference surface: `SettingsScreen` (feature toggle + status labels + excluded-apps section + coordinator reads, ~15 sites), `ActionPanel` (`MenuConfiguration.toggleBinaryPartition` case, `ActionPanelManager` enable/checkmark/title, `MenuActionDispatcher` handler, `ActionPanelContent` accent styling), `Configurations/menu-default.json:205-213`, and `LoggingController:184` (`"TopSnapToggle"` subsystem string).
- **Native-host socket path (h).** Wave 1 renamed the IPC socket to `~/Library/Application Support/DeskJig/native-messaging.sock` (`ChromeExtensionConstants.swift:37`, `NativeMessagingServer.swift:120`). `IPCClient.defaultSocketPath` must be renamed to match or the Chrome bridge dies silently.
- **App-side UI duplicates of shared types (d, f).** `UI/BlurBackdrop`, `UI/VisualEffect` (byte-identical to the package copy), `UI/Animations+Transitions/{Animations,BlurTransition}`, `UI/ViewModifiers/ViewModifiers` all exist in both the app and `DeskJigShared`. They compiled as separate modules in Bento; port as-is (write-first) and file the dedup rather than resolving it mid-port.

### Wave 4 tranche w4-b-model — flagged app-behavior change

**`DeskJigCLIInstaller` (`DeskJig/Model/DeskJigCLIInstaller.swift`, ported from `Nexus/Model/BentoCLIInstaller.swift`) drops the privileged install path entirely for M1.** The source app installed the `bentoctl` symlink at `/usr/local/bin` via an `SMJobBless`/XPC helper daemon (`BentoCLIBlessHelper` + `BentoCLIBlessHelperProtocol`, `com.mscontrol.bento.bentoctl-helper`), with an `osascript "with administrator privileges"` fallback. None of that is ported: `CLIHelper/` does not exist in the M1 tree, there is no `SMJobBless` target, and tranche a drops the helper's mach-lookup entitlement. Every `SMAppService`/`NSXPCConnection`/`AppleScriptRunner`-administrator-privileges call path is removed, not stubbed.

In its place, `install()` attempts a direct, non-privileged `FileManager.createSymbolicLink` from the bundled `deskjig` binary to `/usr/local/bin/deskjig`. That succeeds when `/usr/local/bin` is user-writable (the common case on a fresh Mac) and fails cleanly otherwise — the failure path returns `InstallResult.manualCommand`, a copy-paste `sudo mkdir -p ... && sudo ln -sf ...` string the UI (tranche c, `SettingsScreen`) must surface instead of reporting silent success. **Tranche c needs to render `manualCommand` when present** — if it only checks `error`, the user sees a failure with no recovery path.

Also note for the integrator: the install target changed from `/usr/local/bin/bentoctl` to `/usr/local/bin/deskjig` (Wave 3's CLI product name). `BundleIdentity.legacyCLIInstallPath` (`DeskJigShared`) still holds the old `/usr/local/bin/bentoctl` path for a possible compat symlink, but no compat symlink is created anywhere in M1 — left as an explicit Wave 4/5 decision (see the Wave 3 addendum above), not invented here.

## Wave 4 integration addendum — checkpoint D (app compiles)

All eight tranche branches (`w4-a-app-core` … `w4-h-nativehost`) merged into `wave-4/app`. Only one merge conflict, in this file (two tranches appended sections); both were kept. `xcodebuild -workspace DeskJig.xcworkspace -scheme DeskJig -configuration Debug -destination platform=macOS,arch=arm64 CODE_SIGNING_ALLOWED=NO build` is **green, including from a deleted `build/DerivedData`**. The app was deliberately **not launched** on the integration host: `DeskJig.app` still carries `com.mscontrol.bento`, so launching it would collide with the developer's running Bento through `SingleInstanceGuard`. Rung E happens on another host.

### Assets

`Nexus/Assets.xcassets` → `DeskJig/Assets.xcassets`, byte-identical payloads, minus three sets and with three renames.

| Action | Set | Note |
|---|---|---|
| dropped | `stripeLogo.imageset` | only consumer was the excluded `SubscriptionView` |
| dropped | `Account Providers/{apple,github,google}.imageset` | only consumers were the excluded auth views |
| dropped | `loginButtonBackgroundColor.colorset` | verified: **zero** references anywhere in the reference tree, not just in ported code |
| renamed | `Bento Logotype.imageset` → `DeskJig Logotype.imageset` | payload `.svg` renamed, `Contents.json` filename updated |
| renamed | `BentoAnimation.dataset` → `DeskJigAnimation.dataset` | payload `BentoAnimation-fixed.json` → `DeskJigAnimation-fixed.json`, `Contents.json` updated |
| renamed | `bentoGridIcon.imageset` → `deskjigGridIcon.imageset` | payload `.png` renamed, `Contents.json` updated |
| renamed | `Nexus/bentoMotion 3.mp4` → `DeskJig/deskjig-motion.mp4` | referenced, not dropped: `LottieSplashView.swift:39` loads it by name; that string was updated |

`BentoLoadingIndicator.lottie` was already renamed to `DeskJigLoadingIndicator.lottie` by tranche f — **verified against the load site**: `DeskJigLoadingIndicator.swift:41` does `DotLottieFile.named("DeskJigLoadingIndicator")`, which matches. `AppIcon.appiconset` keeps its name (the name is API, the artwork is a Wave-5/M2 design task).

Everything else in the catalog rode across unchanged, including sets nothing references today (`brandBlue`, `brandLightGray`, `brandMidGray`, `textFieldBackground`, `textFieldBorder`, `screenshots/*`, several `icons/*`) — they were equally unreferenced in Bento, so this is not new dead weight and the port is not the place to prune it.

**One brand string survives inside an asset payload:** `DeskJigAnimation-fixed.json` names its internal Lottie composition `bentoMotion 2`. It is not a load key — nothing looks it up — and rewriting an animation payload is riskier than leaving it, so it was left byte-identical. Add it to the legacy-identifier register rather than to a build step.

### Info.plist, xcconfigs, entitlements

- Tranche a had already applied the e1 §2.29 cuts (AppEnvironment, all three BetterStack keys, the Google URL type, COGNITO_*, KEY_GATEWAY_BASE_URL, all four Stripe lookups, USE_GATEWAY_LOGS, the font keys). Integration **verified them against the built bundle**, not just the source file — see the checkpoint-D evidence below.
- The plist moved `Config/Info.plist` → `DeskJig/Info.plist` and the (now empty) root `Config/` directory is gone. It sits inside the synchronized root group, so it is listed in the target's membership-exception set; `EXCLUDED_RESOURCE_FILE_NAMES = Info.plist` in both xcconfigs is the second belt.
- **Sparkle feed is a deliberate placeholder.** `SUFeedURL = https://example.invalid/appcast.xml`, `SUPublicEDKey` empty. `.invalid` is reserved by RFC 6761 and can never resolve, so a check can reach no server, and an empty key means nothing could be trusted if it did. Both keys are *present* rather than omitted so `SPUStandardUpdaterController` initialises against a well-formed URL. `SUEnableAutomaticChecks` was considered and rejected: `SparkleController.swift:156` sets `updater.automaticallyChecksForUpdates` in code, and Sparkle complains when that property is also pinned in Info.plist. **Rung-E watch item:** nothing here has been exercised at runtime — if Sparkle's periodic check surfaces a visible network-failure alert on launch, that is the place to fix it, not at compile time. Real feed + real EdDSA key are an M2 decision.
- xcconfigs: e1 §2.30 cuts already applied by tranche a (the leaked CloudFront comment block, `KEY_GATEWAY_BASE_URL`, `APP_ENVIRONMENT`); only `EXCLUDED_RESOURCE_FILE_NAMES` remains in each. **`ReleaseCandidate.xcconfig` deleted** and no ReleaseCandidate configuration exists in the new project — Debug and Release only.
- `DeskJig/DeskJig.entitlements` keeps `keychain-access-groups = $(AppIdentifierPrefix)com.mscontrol.bento` (frozen with the bundle id) and drops the `com.apple.security.temporary-exception.mach-lookup.global-name` entry for `com.mscontrol.bento.bentoctl-helper` — there is no bless helper in M1.

### Project shape (`DeskJig.xcodeproj`, objectVersion 77)

At the repository root, alongside `DeskJig/`, mirroring how `Nexus.xcodeproj` sits alongside `Nexus/`.

- **One target**, `DeskJig` → `DeskJig.app`. `PRODUCT_BUNDLE_IDENTIFIER = com.mscontrol.bento` (frozen), `PRODUCT_NAME = DeskJig`, `INFOPLIST_KEY_CFBundleDisplayName = DeskJig`, `LSUIElement YES`, `ENABLE_HARDENED_RUNTIME YES`, `ENABLE_APP_SANDBOX NO`, `AUTOMATION_APPLE_EVENTS YES`, `MACOSX_DEPLOYMENT_TARGET 14.0`, `CODE_SIGN_STYLE Automatic` with **no `DEVELOPMENT_TEAM`** so ad-hoc/unsigned builds work on any machine. `MARKETING_VERSION` reset to `0.1.0`, `CURRENT_PROJECT_VERSION` to `1`.
- `INFOPLIST_KEY_NSAppleEventsUsageDescription` is intentionally **not** set as a build setting: the reference set both, and the build setting wins over the file, which would have resurrected Bento's wording. The DeskJig string in `Info.plist` is now the one that ships.
- One `PBXFileSystemSynchronizedRootGroup` (`DeskJig`), one exception set (`Configs/Debug.xcconfig`, `Configs/Release.xcconfig`, `Info.plist`). No per-file references — directory renames stay one-line edits.
- Package dependencies: `DeskJigShared` (workspace group, no `package =` key), `KeyboardShortcuts` 2.3.0+, `Sparkle` 2.8.0+, `swift-collections` 1.3.0+ (`Collections`), `lottie-ios` 4.5.2+ — same requirements as the reference — plus the `DeskJigNativeHost` local package. **No Firebase, Sentry, AppAuth or GoogleSignIn**, and none of their transitive pins.
- Cross-project dependency on the `deskjig` target in `DeskJigCLI.xcodeproj`, plus **one** copy phase embedding the CLI with `CodeSignOnCopy`. No helper target, no `Library/LaunchServices` phase, no `Library/LaunchDaemons` phase.
- No test target — Wave 5.
- Shared scheme `DeskJig.xcscheme` committed (build/run/profile; empty `Testables`, to be filled in Wave 5). It keeps the reference's `SHOW_FULL_URLS=1` launch env and the disabled `--reset-defaults` argument, and drops the hardcoded `WorkspaceIntegrationTests` skip along with the test plans.
- Workspace order is now app project, package, CLI project.

**`DeskJig.xcworkspace/xcshareddata/swiftpm/Package.resolved` is new and load-bearing.** Without it, xcodebuild wrote the app's resolved graph into `DeskJigShared/Package.resolved`, and `swift build --package-path DeskJigShared` (checkpoint A) promptly pruned the four app-only pins back out — the two rungs rewrote the same file on every alternation. With the workspace-level file present, Xcode uses it and the package's own resolved file stays untouched. Verified both ways.

### The `Contents/MacOS/deskjig` collision — a real bug, found at checkpoint D

The reference embeds `bentoctl` at `Contents/MacOS/`, and that is what this integration originally reproduced. **It silently destroyed the app.** macOS volumes are case-insensitive by default, so `Contents/MacOS/deskjig` and the app's own main executable `Contents/MacOS/DeskJig` are one and the same path: the copy phase overwrote the 40 KB app stub with the 27 MB CLI, and the first build produced a `DeskJig.app` with **no app executable at all**. Bento never met this because `bentoctl` and `Bento` differ in more than case.

Fixes, all in this branch:

- The copy phase now targets `$(TARGET_BUILD_DIR)/$(CONTENTS_FOLDER_PATH)/Helpers`. Still one phase, still `CodeSignOnCopy`.
- `DeskJigCLIInstaller.bundledCLIPath()` looks in `Contents/Helpers/` first, no longer probes the executable's own directory, and **rejects any candidate that resolves to the app's own executable**. Without that guard the installer would have pointed `/usr/local/bin/deskjig` at `DeskJig.app`. `manualInstallCommand()`'s fallback path was updated to match.
- This is a deviation from the reference bundle layout and from the Wave-4 brief, forced by the rename. Anything downstream that assumes `Contents/MacOS/deskjig` — packaging scripts, a ported `cli-smoke-test`, docs — needs the same update. `Contents/Helpers/` is a standard, notarization-safe location for a bundled non-launchable tool.

### Seam fixes applied during the build loop

| Site | Fix |
|---|---|
| `WorkspaceViewModel.swift:147` | dropped `screenIndicatorManager.setOverlayWindowManager(…)`. Wave 1 removed that setter together with its only two readers (`toggleGrid()`, `isGridVisible()`, both dead), so the call was already a no-op; the app-side call was cut rather than the package cleanup reverted. |
| `DeskJigApp.swift:59/124/160`, `AppDelegate.swift:269` | dropped the `ActionPanelManager.isDisabled` gate at all four sites. e1 §2.1/§2.4 expected the property to survive as a constant `false`; tranche f removed it outright, which is the better cut — the panel is enabled from construction. Two of the sites were only logging it. |
| `SimpleOnboardingOverlay.swift` | restored `PlayerContainerView` (23 lines). It sat below the duplicate Discord onboarding UI that e1 §2.22 deletes and went with it, but `LoopingVideoPlayer` — which drives all six onboarding videos — is its only user. |
| `DesignSystemSectionView.swift:128` | `.dsButton(variant: .community)` → `.green`. Tranche e renamed the variant while tranche d kept the old call site. |
| `MenuBarView.swift` | deleted the "Test Crash", "Test Non-Fatal Error" and "Test Workspace Restoration Failure" debug items — each existed solely to push a synthetic event into Crashlytics or Sentry (e1 §2.2), and nothing local replaces them. "Reset Tutorial & Logout" → "Reset Tutorial", calling the `resetTutorialProgress()` that tranche a already ported. |
| `ChromeExtensionConstants.swift:42` | `Contents/MacOS/DeskJigNativeHost` → `Contents/MacOS/BentoNativeHost`. Wave 1 renamed the constant; tranche h deliberately froze the executable **product** name at `BentoNativeHost` because the Chrome native-messaging manifest hardcodes it. The constant was naming a binary that is never built. |

### Checkpoint D evidence (static — nothing was launched)

- Clean build: `rm -rf build/DerivedData` then rebuild → `BUILD SUCCEEDED`, 0 errors, 0 source warnings (the single logged warning is `appintentsmetadataprocessor` reporting no AppIntents dependency).
- `DeskJig.app/Contents/MacOS/DeskJig` is a 40 KB `Mach-O 64-bit executable arm64` stub over `DeskJig.debug.dylib`; `DeskJig.app/Contents/Helpers/deskjig` is byte-identical to the `deskjig` CLI product.
- In-bundle `Contents/Info.plist`: `CFBundleIdentifier com.mscontrol.bento`, `CFBundleExecutable/Name/DisplayName DeskJig`, `LSUIElement true`, the `bento` URL scheme is the only URL type, `UTExportedTypeDeclarations[0].UTTypeIdentifier == com.nexus.windowsnapshot`, `BentoWorktreeName` present. `AppEnvironment`, `BetterStack*`, `KEY_GATEWAY_BASE_URL`, `USE_GATEWAY_LOGS`, all four Stripe lookups and `ATSApplicationFontsPath` are all absent, and a case-insensitive grep for google/cognito/stripe/betterstack/gateway over the whole plist returns zero.
- `otool -L` over the app stub, the debug dylib and the embedded CLI: the only non-system links are `Sparkle.framework` and `libswiftCompatibilitySpan.dylib`. Zero references to Firebase, Sentry, GoogleSignIn, AppAuth, GTMAppAuth, Crashlytics, GoogleUtilities, nanopb, leveldb, abseil or grpc, and `nm -u` finds no undefined symbols matching those either. `Contents/Frameworks/` contains only Sparkle.

### Open items for the coordinator

1. **`BentoNativeHost` is built but never embedded.** The app target links the executable product, exactly as the reference did, and Xcode does not copy it into `Contents/MacOS/`. `ChromeExtensionConstants.nativeHostBinaryPath` therefore points at a path that does not exist in the built bundle, so the Chrome bridge cannot install its manifest. This reproduces reference behaviour, so it is likely handled by packaging outside the Xcode build in Bento — worth confirming before assuming DeskJig needs a second copy phase. Not fixed here, because adding one would have meant a second copy phase against an explicit "one copy phase" instruction.
2. **Sparkle placeholder feed is untested at runtime** (see above) — a rung-E watch item, not a compile-time one.
3. **`AppIcon.appiconset` still ships Bento's artwork** under a neutral name. Cosmetic, needs a designer, not a porter.
4. **`bentoMotion 2` inside `DeskJigAnimation-fixed.json`** — register entry, not a code change.
5. The app-side/package duplicate views flagged by tranche d/f (`BlurBackdrop`, `VisualEffect`, `Animations`, `BlurTransition`, `ViewModifiers`) were left duplicated as instructed; they compile cleanly as separate modules. Dedup is a follow-up ticket.
