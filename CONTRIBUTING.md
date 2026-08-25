# Contributing to DeskJig

Thanks for your interest! DeskJig is mid-conversion from a commercial product to
a fully local open-source app, so the contribution surface is still settling.

## Prerequisites

- macOS 14 or later, with **Xcode** installed (`xcode-select -p` should point at
  a full Xcode, not just the Command Line Tools).
- [Bun](https://bun.sh) — the build/test scripts are Bun scripts.
- Optional: `brew install swiftlint` if you want to run the linter locally
  (`bun run lint:swift`). CI reports lint warnings but never fails on them.

## Build

```bash
bun install
bun run build:app     # DeskJig.app
bun run build:cli     # the deskjig CLI
```

The scripts wrap `xcodebuild`, write logs, and summarize errors; output lands
under `build/`. No Apple developer account is needed: the default build is
**ad-hoc signed** and runs fine locally (`--no-signing` also exists for
CI-style builds). Release signing/notarization is maintainer-only — see
[docs/RELEASING.md](docs/RELEASING.md).

> **Accessibility gotcha:** an ad-hoc-signed app gets a new code signature on
> every rebuild, so macOS re-prompts for the Accessibility permission after
> each rebuild. That is expected, not a bug.

## Tests

```bash
bun run test -- --plan headless   # what CI runs; pure-logic suites, works anywhere
bun run test -- --plan full       # every suite; needs a real GUI session with
                                  # the Accessibility permission granted
bun run test -- --plan cli        # suites exercising the bundled CLI binary
```

For PRs, a green **headless** plan plus the DeskJigShared package suites
(`swift test` inside `DeskJigShared/`, run by CI automatically) is what's
required. Run the full plan when your change touches real window management.

## Pull requests

- **Issues first** for anything non-trivial — the conversion roadmap may
  already cover (or delete) the code you're about to change.
- **Small PRs** — the codebase is under active surgery; large refactors will
  conflict.
- Fork the repo and open PRs from a topic branch (`fix/…`, `feat/…`).
- On your first PR, CI waits for a maintainer to approve the run — that's a
  standard first-time-contributor gate, not a snub.
- Required to merge: the DeskJigTests (headless) and DeskJigShared package
  checks green.
- Match the surrounding code style; SwiftLint config is in `.swiftlint.yml`
  (warning-only policy — `bun run lint:swift`).
- By submitting a pull request you agree that your contribution is licensed
  under the [Apache License 2.0](LICENSE), like the rest of the project.

## Legacy naming

You will see `Bento`, `Nexus`, `bentoctl`, and `com.mscontrol.bento`
throughout — these are legacy names from the commercial era, and some (like the
bundle id) are deliberately frozen for migration continuity — see
[docs/LEGACY_IDENTIFIERS.md](docs/LEGACY_IDENTIFIERS.md). Renames are tracked
in dedicated issues; please don't submit drive-by mass renames.

## Reporting bugs

Include: macOS version, app version (About window or `deskjig --version`),
monitor arrangement, what you expected vs what happened, and for
workspace-restore issues the restore run ID (`restore_HHMMSS_xxxxxx`) from the
logs (`bun run logs`, or `deskjig logs` if you installed the CLI).

Security issues: please use
[private vulnerability reporting](../../security/advisories/new) instead of a
public issue — see [SECURITY.md](SECURITY.md).
