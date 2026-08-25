# Architecture overview

A one-page map for finding where a change belongs. For the conversion roadmap
see [PORT_PLAN.md](PORT_PLAN.md); for identifiers that must never be renamed
see [LEGACY_IDENTIFIERS.md](LEGACY_IDENTIFIERS.md).

## Components

| Component | What it is | Where |
|---|---|---|
| **DeskJig** (app) | The macOS menu-bar app: UI, window management, workspace capture/restore, Sparkle updates | `DeskJig/`, project `DeskJig.xcodeproj`, workspace `DeskJig.xcworkspace` |
| **DeskJigCLI** | The `deskjig` command-line tool shipped inside the app bundle (`Contents/Helpers/deskjig`) | `DeskJigCLI/` (own Xcode project, embedded by the app project) |
| **DeskJigNativeHost** | Chrome native-messaging host used for browser tab/window integration | `DeskJigNativeHost/` |
| **DeskJigShared** | SwiftPM package with the shared logic layer (managers, models, resolvers) used by all of the above | `DeskJigShared/` (`Sources/`, `Tests/`) |

Most pure-logic changes belong in **DeskJigShared**; the app target is mostly
UI and system glue. `Version.xcconfig` at the repo root is the single source of
truth for version numbers (see [RELEASING.md](RELEASING.md)).

## Build & scripts

Bun scripts in `scripts/` wrap `xcodebuild` (`bun run build:app`,
`bun run build:cli`, `bun run test`, `bun run logs`). Output lands in `build/`.

## Tests and what CI runs

| Suite | Plan / command | CI workflow |
|---|---|---|
| DeskJigShared package suites | `swift test` in `DeskJigShared/` | `deskjig-package.yml` (every PR — the fast lane) |
| App-hosted pure-logic suites | `TestPlans/DeskJigTests-Headless.xctestplan` — `bun run test -- --plan headless` | `deskjig-tests.yml` (every PR) |
| Real-system integration suites | `TestPlans/DeskJigTests-Full.xctestplan` — needs a GUI session with Accessibility granted | not in CI; run locally |
| CLI suites | `TestPlans/DeskJigTests-CLI.xctestplan` | not in CI; run locally |
| Lint | `bun run lint:swift` | `swiftlint.yml` (report-only, never fails a PR) |

Releases (`release.yml`) are tag-triggered and maintainer-only:
build → sign → notarize → DMG → Sparkle appcast → GitHub Release
([RELEASING.md](RELEASING.md)).
