# Contributing to DeskJig

Thanks for your interest! DeskJig is mid-conversion from a commercial product to a fully local open-source app, so the contribution surface is still settling.

## Ground rules

- **Issues first** for anything non-trivial — the conversion roadmap may already cover (or delete) the code you're about to change.
- **Small PRs** — the codebase is under active surgery; large refactors will conflict.
- Match the surrounding code style; SwiftLint config is in `.swiftlint.yml` (warning-only policy — `bun run lint:swift`).
- Builds must stay green: `bun run build:bento-app` and `bun run build:bentoctl`, plus `bun scripts/cli-smoke-test.ts` where applicable.

## Legacy naming

You will see `Bento`, `Nexus`, `bentoctl`, and `com.mscontrol.bento` throughout — these are legacy names from the commercial era. Renames are tracked in dedicated issues; please don't submit drive-by mass renames.

## Reporting bugs

Include: macOS version, app version, what you expected vs what happened, and for workspace-restore issues the restore run ID (`restore_HHMMSS_xxxxxx`) from the logs.
