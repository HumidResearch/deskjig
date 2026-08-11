# DeskJig

DeskJig is a macOS workspace manager: it saves the full arrangement of your working windows — apps, positions, monitors, Chrome profiles and tabs, terminal and tmux sessions — as named workspaces, and restores them on demand. Like a woodworker's jig, it holds everything in exactly the right position so you can get back to work instantly.

> **Status: under active conversion to open source.** DeskJig was previously a commercial product (Bento). The account, subscription, and cloud-sync systems are being removed in favor of a fully local, no-server app. Expect scaffolding, legacy names (`Bento`, `bentoctl`, `com.mscontrol.bento`), and rough edges while the conversion lands. Nothing in this app requires a server or an account.

## Features

- **Workspaces** — capture every window on every monitor as a named layout; restore with one action.
- **Quick Switch** — jump between workspaces; windows are unhidden, un-minimized, repositioned, and raised in the right z-order.
- **Chrome-aware** — restores windows to the right Chrome profile with the right tabs.
- **Terminal-aware** — reattaches terminal windows to their tmux sessions and working directories.
- **Snap layouts** — BSP-style tiling with edge snapping and drag interactions.
- **`bentoctl` CLI** — inspect windows/apps/displays, trigger restores, and script window management (rename to `deskjig` pending).

## Building

Requires Xcode (macOS 15+ toolchain) and [Bun](https://bun.sh).

```bash
bun install
bun run build:bento-app     # the app
bun run build:bentoctl      # the CLI
```

Build output lands under `build/`; the build scripts wrap `xcodebuild` and summarize errors.

## Testing

```bash
bun scripts/cli-smoke-test.ts   # read-only CLI smoke suite (requires built binaries)
```

Unit tests live in `BentoTests/` (Swift Testing) and run via the Xcode test plans in `TestPlans/`.

## License

[Apache-2.0](LICENSE). Font note: DeskJig uses the system font stack; no proprietary fonts are bundled.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md). Bug reports are welcome as GitHub issues — please include macOS version, app version, and (for restore issues) the restore run ID shown in the app's logs.
