#!/usr/bin/env bun
/**
 * CLI smoke-test suite (#461) — the merge gate for `deskjig` CLI work.
 *
 * Exercises the CLI against the CURRENTLY LOGGED-IN USER'S REAL STATE (not
 * mocks):
 *
 *   0. AX gate: Accessibility permissions granted + one AX-requiring command
 *      (`window query`) works. Most other commands run with
 *      requireAccessibility:false, so without this the suite would pass on a
 *      machine where AX is completely broken.
 *   1. app<->CLI contract: DeskJig.app is running (`app status`) AND the bundle
 *      that receives bento:// URLs is that running bundle — so a dead app, or
 *      a second bundle shadowing the running one (#565), cannot false-pass.
 *   2. workspace list --format json (store readable; >= 1 workspace, valid JSON)
 *   3. workspace info on the first workspace
 *   4. diagnostics: dump-windows, display list, app list
 *   5. logs/run-IDs: list run IDs + show the latest trace
 *   6. (OPT-IN, --restore) restore a workspace and verify completion via the
 *      run's trace files in the log directory. --mode cli restores in the
 *      deskjig process (its own AX grant); --mode app triggers an IN-APP
 *      restore via `deskjig app restore --wait` (#465) — the user's real
 *      permission context.
 *
 * DeskJig is local-only: there is no account, no `auth` command surface and no
 * ~/.bento/cli-session.json. The old suite's step 1 asserted that `auth status`
 * was served by the live app; the local equivalent is step 1 above plus the
 * store readability half of step 2 — together they prove the app and the CLI
 * agree on the shared workspace store and on URL routing.
 *
 * The DEFAULT run is READ-ONLY (steps 0-5). Step 6 moves real windows on the
 * user's machine and only runs when explicitly requested with --restore.
 *
 * Golden outputs: `--capture-golden <dir>` snapshots each JSON payload;
 * `--golden <dir>` diffs the current output SHAPES (key paths + type unions,
 * not values) against the snapshots and fails on regressions (missing keys /
 * disappeared non-null types). New keys/types are additive and only warn.
 *
 * EXIT CODES (distinct, for machine consumption):
 *   0  all required checks passed
 *   1  generic check failure
 *   2  usage error (bad flags)
 *   3  environment not ready (missing binaries, AX permissions not granted)
 *   4  restore failed (command envelope error, failed windows, short restore)
 *   5  restore timed out waiting for trace completion
 *   6  restore run ID could not be discovered
 * Restore-specific codes (4-6) take precedence over 1 when both occur.
 *
 * Usage:
 *   bun scripts/cli-smoke-test.ts                          # read-only steps 0-5
 *   bun scripts/cli-smoke-test.ts --capture-golden /tmp/golden
 *   bun scripts/cli-smoke-test.ts --golden /tmp/golden
 *   bun scripts/cli-smoke-test.ts --restore                # restore first workspace
 *   bun scripts/cli-smoke-test.ts --restore "My Workspace" --mode cli
 *   bun scripts/cli-smoke-test.ts --restore "My Workspace" --mode app
 *   bun scripts/cli-smoke-test.ts --format json
 */

import { copyFileSync, existsSync, mkdirSync, readdirSync, readFileSync, statSync, writeFileSync } from "node:fs";
import { homedir } from "node:os";
import { join, resolve } from "node:path";
import { spawnSync } from "node:child_process";

// ---------------------------------------------------------------------------
// Exit codes
// ---------------------------------------------------------------------------

const EXIT_PASS = 0;
const EXIT_CHECK_FAILURE = 1;
const EXIT_USAGE = 2;
const EXIT_ENVIRONMENT = 3;
const EXIT_RESTORE_FAILED = 4;
const EXIT_RESTORE_TIMEOUT = 5;
const EXIT_RESTORE_NO_RUN_ID = 6;

// ---------------------------------------------------------------------------
// Frozen legacy identifiers (see docs/LEGACY_IDENTIFIERS.md). These values are
// inherited from the app's commercial predecessor and MUST match
// BundleIdentity.swift byte for byte — they are not brand strings.
// ---------------------------------------------------------------------------

/** BundleIdentity.logDirectoryName — ~/Library/Logs/<this>. */
const LOG_DIRECTORY_NAME = "Bento";
/** BundleIdentity.restoreTraceDirectoryName. */
const RESTORE_TRACE_DIRECTORY_NAME = "restore-trace";
/** Worktree log-isolation env var read by the app and the CLI. */
const WORKTREE_NAME_ENV = "BENTO_WORKTREE_NAME";
/** Binary-path override honored by the gated package tests (docs/PORT_PLAN.md). */
const BINARY_OVERRIDE_ENV = "DESKJIG_BENTOCTL";

// ---------------------------------------------------------------------------
// Types
// ---------------------------------------------------------------------------

type Status = "PASS" | "FAIL" | "SKIP";

interface CheckResult {
  id: string;
  title: string;
  status: Status;
  required: boolean;
  durationMs: number;
  binary?: string;
  detail: string;
}

interface RunResult {
  exitCode: number;
  stdout: string;
  stderr: string;
  durationMs: number;
  timedOut: boolean;
}

interface Options {
  deskjigPath?: string;
  restore: boolean;
  restoreWorkspace?: string;
  mode: "cli" | "app";
  captureGoldenDir?: string;
  goldenDir?: string;
  outputDir?: string;
  format: "text" | "json";
  restoreTimeoutSec: number;
  verbose: boolean;
}

// ---------------------------------------------------------------------------
// Argument parsing
// ---------------------------------------------------------------------------

function printHelp(): void {
  console.log(`
DeskJig CLI smoke-test suite (#461)

Merge gate for CLI work. Runs the CLI against the currently logged-in user's
real state. Default run is READ-ONLY.

USAGE:
  bun scripts/cli-smoke-test.ts [OPTIONS]

OPTIONS:
      --deskjig <path>          Override deskjig binary location
                                (also honored: ${BINARY_OVERRIDE_ENV}=<path>)
      --restore [name]          OPT-IN: restore a workspace (default: first listed)
                                and verify completion via its trace files.
                                MOVES REAL WINDOWS.
      --mode <cli|app>          Restore mode (default: cli).
                                cli = deskjig workspace restore (CLI-process context)
                                app = deskjig app restore --wait (#465) — in-app
                                      restore in the running DeskJig app's context
      --restore-timeout <sec>   Restore completion timeout (default: 180)
      --output-dir <dir>        Where restore evidence (trace + summary) is copied
                                (default: /tmp/deskjig-cli-smoke/<timestamp>)
      --capture-golden <dir>    Write each JSON output to <dir> as golden snapshots
      --golden <dir>            Diff current output shapes (keys/type unions) against <dir>
      --format <text|json>      Report format (default: text)
      --verbose                 Echo every command before running it
  -h, --help                    Show this help

EXIT CODES:
  0  all required checks passed
  1  generic check failure
  2  usage error (bad flags)
  3  environment not ready (missing binaries, AX permissions not granted)
  4  restore failed (envelope error, failed windows, short restore)
  5  restore timed out waiting for trace completion
  6  restore run ID could not be discovered
`);
}

function parseArgs(argv: string[]): Options {
  const opts: Options = {
    restore: false,
    mode: "cli",
    format: "text",
    restoreTimeoutSec: 180,
    verbose: false,
  };

  const requireValue = (flag: string, value: string | undefined): string => {
    if (value === undefined || value.startsWith("--")) {
      console.error(`Error: ${flag} requires a value`);
      process.exit(EXIT_USAGE);
    }
    return value;
  };

  for (let i = 0; i < argv.length; i++) {
    const arg = argv[i];
    switch (arg) {
      case "--help":
      case "-h":
        printHelp();
        process.exit(0);
      case "--deskjig":
      // Undocumented alias kept so pre-rename invocations (scripts, CI jobs,
      // muscle memory) keep working; `--deskjig` is the supported spelling.
      case "--bentoctl":
        opts.deskjigPath = requireValue(arg, argv[++i]);
        break;
      case "--restore": {
        opts.restore = true;
        const next = argv[i + 1];
        if (next !== undefined && !next.startsWith("--")) {
          opts.restoreWorkspace = next;
          i++;
        }
        break;
      }
      case "--mode": {
        const value = requireValue(arg, argv[++i]);
        if (value !== "cli" && value !== "app") {
          console.error("Error: --mode must be cli or app");
          process.exit(EXIT_USAGE);
        }
        opts.mode = value;
        break;
      }
      case "--restore-timeout":
        opts.restoreTimeoutSec = Number(requireValue(arg, argv[++i]));
        if (!Number.isFinite(opts.restoreTimeoutSec) || opts.restoreTimeoutSec <= 0) {
          console.error("Error: --restore-timeout must be a positive number of seconds");
          process.exit(EXIT_USAGE);
        }
        break;
      case "--output-dir":
        opts.outputDir = resolve(requireValue(arg, argv[++i]));
        break;
      case "--capture-golden":
        opts.captureGoldenDir = resolve(requireValue(arg, argv[++i]));
        break;
      case "--golden":
        opts.goldenDir = resolve(requireValue(arg, argv[++i]));
        break;
      case "--format": {
        const value = requireValue(arg, argv[++i]);
        if (value !== "text" && value !== "json") {
          console.error("Error: --format must be text or json");
          process.exit(EXIT_USAGE);
        }
        opts.format = value;
        break;
      }
      case "--verbose":
        opts.verbose = true;
        break;
      default:
        console.error(`Unknown argument: ${arg}`);
        console.error("Use --help for usage information");
        process.exit(EXIT_USAGE);
    }
  }

  if (opts.captureGoldenDir && opts.goldenDir) {
    console.error("Error: use either --capture-golden or --golden, not both");
    process.exit(EXIT_USAGE);
  }

  return opts;
}

// ---------------------------------------------------------------------------
// Binary location
//
// Candidates, newest mtime wins:
//   build/*/Build/Products/{Debug,Release}/deskjig                  (CLI product)
//   build/*/Build/Products/{Debug,Release}/DeskJig.app/Contents/Helpers/deskjig
// The embedded copy lives in Contents/Helpers/, NOT Contents/MacOS/: on a
// case-insensitive volume `Contents/MacOS/deskjig` IS the app's own
// `Contents/MacOS/DeskJig` stub, and the copy phase destroys the app
// (docs/PORT_PLAN.md, Wave 4). An installed /Applications bundle is the last
// resort so a machine with no build products can still be smoke-tested.
// ---------------------------------------------------------------------------

const repoRoot = resolve(import.meta.dir, "..");
const EMBEDDED_CLI_SUBPATH = join("Contents", "Helpers", "deskjig");

type BinarySource = "override" | "build-products" | "embedded" | "installed";

interface LocatedBinary {
  path: string;
  configuration: "Debug" | "Release" | "unknown";
  source: BinarySource;
}

function isExecutableFile(path: string): boolean {
  try {
    const stat = statSync(path);
    return stat.isFile() && (stat.mode & 0o111) !== 0;
  } catch {
    return false;
  }
}

function configurationOf(path: string): "Debug" | "Release" | "unknown" {
  return /\/Release\//.test(path) ? "Release" : /\/Debug\//.test(path) ? "Debug" : "unknown";
}

function locateBinary(name: "deskjig", override?: string): LocatedBinary | undefined {
  const explicit = override ?? (process.env[BINARY_OVERRIDE_ENV] || undefined);
  if (explicit) {
    const resolved = resolve(explicit);
    if (!existsSync(resolved)) {
      console.error(`Error: ${name} override not found: ${resolved}`);
      process.exit(EXIT_USAGE);
    }
    return { path: resolved, configuration: configurationOf(resolved), source: "override" };
  }

  let best: { path: string; mtime: number; source: BinarySource } | undefined;
  const consider = (candidate: string, source: BinarySource) => {
    if (!isExecutableFile(candidate)) return;
    const mtime = statSync(candidate).mtimeMs;
    if (!best || mtime > best.mtime) best = { path: candidate, mtime, source };
  };

  const buildRoot = join(repoRoot, "build");
  if (existsSync(buildRoot)) {
    for (const entry of readdirSync(buildRoot)) {
      for (const configuration of ["Debug", "Release"] as const) {
        const products = join(buildRoot, entry, "Build", "Products", configuration);
        consider(join(products, name), "build-products");
        consider(join(products, "DeskJig.app", EMBEDDED_CLI_SUBPATH), "embedded");
      }
    }
  }

  if (!best) consider(join("/Applications", "DeskJig.app", EMBEDDED_CLI_SUBPATH), "installed");

  return best ? { path: best.path, configuration: configurationOf(best.path), source: best.source } : undefined;
}

// ---------------------------------------------------------------------------
// Command execution
// ---------------------------------------------------------------------------

let verboseEcho = false;

function run(binary: string, args: string[], timeoutMs = 30_000): RunResult {
  if (verboseEcho) console.error(`$ ${binary} ${args.join(" ")}`);
  const started = performance.now();
  const result = spawnSync(binary, args, { encoding: "utf-8", timeout: timeoutMs });
  const durationMs = performance.now() - started;
  const timedOut = result.error != null && (result.error as NodeJS.ErrnoException).code === "ETIMEDOUT";
  return {
    exitCode: result.status ?? (result.error ? -1 : 0),
    stdout: result.stdout ?? "",
    stderr: result.stderr ?? "",
    durationMs,
    timedOut,
  };
}

/**
 * Parse JSON output, tolerating stray log lines (e.g. "[INFO] ...") before
 * the payload. Tries the whole (trimmed) text first, then every '{' / '['
 * position in order until one parses to the end of the output — never blindly
 * slices at the first bracket.
 */
function parseJsonOutput(text: string): unknown {
  const trimmed = text.trim();
  try {
    return JSON.parse(trimmed);
  } catch {
    // Fall through to candidate scanning.
  }
  let attempts = 0;
  for (let i = 0; i < trimmed.length && attempts < 100; i++) {
    const ch = trimmed[i];
    if (ch !== "{" && ch !== "[") continue;
    attempts++;
    try {
      return JSON.parse(trimmed.slice(i));
    } catch {
      // Not a valid payload start; try the next candidate.
    }
  }
  throw new Error("no parseable JSON payload found in output");
}

// ---------------------------------------------------------------------------
// Capability probing: parse deskjig's --help subcommand listings
// ---------------------------------------------------------------------------

/**
 * Extract subcommand names from an ArgumentParser help text. Subcommand rows
 * are indented with exactly two spaces; wrapped description lines are
 * indented further, so `/^  (\S+)/` matches only real subcommand rows.
 */
function parseSubcommandListing(helpText: string): Set<string> {
  const names = new Set<string>();
  let inSubcommands = false;
  for (const line of helpText.split("\n")) {
    if (/^SUBCOMMANDS:/.test(line)) {
      inSubcommands = true;
      continue;
    }
    if (!inSubcommands) continue;
    if (/^\S/.test(line)) break; // next top-level section (OPTIONS:, etc.)
    const match = line.match(/^  (\S+)/);
    if (match && match[1] !== "See") names.add(match[1]);
  }
  return names;
}

const subcommandCache = new Map<string, Set<string> | undefined>();

function subcommandsOf(binary: string, groupPath: string[]): Set<string> | undefined {
  const key = `${binary}::${groupPath.join(" ")}`;
  if (subcommandCache.has(key)) return subcommandCache.get(key);
  const result = run(binary, [...groupPath, "--help"], 15_000);
  const listing = result.exitCode === 0 ? parseSubcommandListing(result.stdout) : undefined;
  subcommandCache.set(key, listing);
  return listing;
}

/**
 * True iff deskjig's ACTUAL command surface includes the given subcommand
 * path (e.g. ["debug", "dump-windows"]), determined from its help listings —
 * NOT from the exit code of a failed invocation. This keeps the fallback
 * honest: a usage regression in a ported command exits 64 like a missing
 * command would, but the help listing still advertises it, so the failure
 * surfaces instead of silently falling back.
 */
function deskjigSupports(binary: string, path: string[]): boolean {
  const root = subcommandsOf(binary, []);
  if (!root?.has(path[0])) return false;
  if (path.length > 1) {
    const group = subcommandsOf(binary, [path[0]]);
    if (!group?.has(path[1])) return false;
  }
  return true;
}

// ---------------------------------------------------------------------------
// Golden output shapes (key paths -> type unions, null-aware)
// ---------------------------------------------------------------------------

type Shape = Map<string, Set<string>>;

/**
 * Collect the shape of a JSON value as key-path -> union of observed types.
 * Array elements are merged under the pseudo-key "[]", so mixed-type arrays
 * contribute every element type to the union instead of collapsing.
 */
function collectShape(value: unknown, prefix: string, out: Shape): void {
  const key = prefix || "$";
  let types = out.get(key);
  if (!types) {
    types = new Set();
    out.set(key, types);
  }
  if (Array.isArray(value)) {
    types.add("array");
    for (const element of value) collectShape(element, `${prefix}[]`, out);
    return;
  }
  if (value !== null && typeof value === "object") {
    types.add("object");
    for (const [childKey, child] of Object.entries(value as Record<string, unknown>)) {
      collectShape(child, prefix ? `${prefix}.${childKey}` : childKey, out);
    }
    return;
  }
  types.add(value === null ? "null" : typeof value);
}

/** Volatile envelope keys whose values (and presence) may vary run to run. */
const VOLATILE_SHAPE_KEYS = new Set(["durationMs", "totalDurationMs"]);

interface ShapeDiff {
  missing: string[]; // key paths with non-null golden types, absent now — regression
  typeChanged: string[]; // key paths whose golden non-null types disappeared — regression
  added: string[]; // key paths new in current output — additive, warn only
  optionalMissing: string[]; // golden null-only paths absent now — warn only
}

function diffShapes(golden: unknown, current: unknown): ShapeDiff {
  const goldenShape: Shape = new Map();
  const currentShape: Shape = new Map();
  collectShape(golden, "", goldenShape);
  collectShape(current, "", currentShape);

  const isVolatile = (path: string) => {
    const leaf = path.split(".").pop() ?? path;
    return VOLATILE_SHAPE_KEYS.has(leaf.replace("[]", ""));
  };

  const diff: ShapeDiff = { missing: [], typeChanged: [], added: [], optionalMissing: [] };
  for (const [path, goldenTypes] of goldenShape) {
    if (isVolatile(path)) continue;
    const nonNull = [...goldenTypes].filter((t) => t !== "null");
    const currentTypes = currentShape.get(path);
    if (!currentTypes) {
      if (nonNull.length === 0) diff.optionalMissing.push(path);
      else diff.missing.push(path);
      continue;
    }
    const lost = nonNull.filter((t) => !currentTypes.has(t));
    if (lost.length > 0) {
      diff.typeChanged.push(
        `${path} (lost: ${lost.join("|")}; golden: ${[...goldenTypes].join("|")}, now: ${[...currentTypes].join("|")})`,
      );
    }
  }
  for (const path of currentShape.keys()) {
    if (isVolatile(path)) continue;
    if (!goldenShape.has(path)) diff.added.push(path);
  }
  return diff;
}

// ---------------------------------------------------------------------------
// Suite state
// ---------------------------------------------------------------------------

const checks: CheckResult[] = [];
const warnings: string[] = [];

function record(check: CheckResult): CheckResult {
  checks.push(check);
  return check;
}

function warn(message: string): void {
  if (!warnings.includes(message)) warnings.push(message);
}

function handleGolden(opts: Options, checkId: string, payload: unknown): void {
  if (opts.captureGoldenDir) {
    mkdirSync(opts.captureGoldenDir, { recursive: true });
    writeFileSync(join(opts.captureGoldenDir, `${checkId}.json`), `${JSON.stringify(payload, null, 2)}\n`);
    return;
  }
  if (!opts.goldenDir) return;

  const goldenFile = join(opts.goldenDir, `${checkId}.json`);
  const started = performance.now();
  if (!existsSync(goldenFile)) {
    record({
      id: `golden:${checkId}`,
      title: `Golden shape: ${checkId}`,
      status: "FAIL",
      required: true,
      durationMs: performance.now() - started,
      detail: `Missing golden file ${goldenFile} — recapture with --capture-golden`,
    });
    return;
  }

  let golden: unknown;
  try {
    golden = JSON.parse(readFileSync(goldenFile, "utf-8"));
  } catch (error) {
    record({
      id: `golden:${checkId}`,
      title: `Golden shape: ${checkId}`,
      status: "FAIL",
      required: true,
      durationMs: performance.now() - started,
      detail: `Golden file unreadable: ${(error as Error).message}`,
    });
    return;
  }

  const diff = diffShapes(golden, payload);
  const regressions = [...diff.missing.map((p) => `missing key: ${p}`), ...diff.typeChanged.map((p) => `type regression: ${p}`)];
  if (diff.added.length > 0) warn(`golden:${checkId}: new keys (additive, ok): ${diff.added.join(", ")}`);
  if (diff.optionalMissing.length > 0) warn(`golden:${checkId}: null-only golden keys absent (ok): ${diff.optionalMissing.join(", ")}`);
  record({
    id: `golden:${checkId}`,
    title: `Golden shape: ${checkId}`,
    status: regressions.length === 0 ? "PASS" : "FAIL",
    required: true,
    durationMs: performance.now() - started,
    detail:
      regressions.length === 0
        ? `Shape matches golden${diff.added.length > 0 ? ` (+${diff.added.length} new key(s))` : ""}`
        : regressions.join("; "),
  });
}

// ---------------------------------------------------------------------------
// deskjig command execution (capability-checked)
// ---------------------------------------------------------------------------

interface Binaries {
  deskjig: LocatedBinary;
}

interface ProbeSpec {
  /** Subcommand path used for the capability check, e.g. ["debug", "dump-windows"]. */
  capabilityPath: string[];
  /** deskjig argv. */
  deskjigArgs: string[];
}

interface ProbeOutcome {
  result: RunResult;
  binaryLabel: string;
}

function runProbe(binaries: Binaries, spec: ProbeSpec, timeoutMs = 30_000): ProbeOutcome | { error: string } {
  if (!deskjigSupports(binaries.deskjig.path, spec.capabilityPath)) {
    return {
      error: `deskjig does not have '${spec.capabilityPath.join(" ")}' in its command surface. Rebuild the deskjig scheme (docs/PORT_PLAN.md, checkpoint C)`,
    };
  }
  const result = run(binaries.deskjig.path, spec.deskjigArgs, timeoutMs);
  return { result, binaryLabel: "deskjig" };
}

// ---------------------------------------------------------------------------
// Step 0: Accessibility gate
// ---------------------------------------------------------------------------

function failDetail(result: RunResult): string {
  const err = result.stderr.trim() || result.stdout.trim();
  const firstLines = err.split("\n").slice(0, 3).join(" | ");
  return `exit ${result.exitCode}${result.timedOut ? " (timed out)" : ""}: ${firstLines || "(no output)"}`;
}

const AX_CONTEXT_NOT_READY =
  "Accessibility not granted in THIS execution context — grants are per-context; run the suite from a login/SSH shell";

/**
 * Returns false ONLY when the environment is not ready (permissions parsed
 * and explicitly NOT granted, or permissions exits 6 -> exit 3). A permissions
 * command that otherwise crashes, times out, or emits unparseable JSON is a
 * broken command — a regular check FAIL (exit 1), not an environment failure.
 */
function checkAccessibilityGate(binaries: Binaries, opts: Options): boolean {
  const permissions = run(binaries.deskjig.path, ["permissions", "--format", "json"]);
  const permBase = {
    id: "ax-permissions",
    title: "AX gate: Accessibility permissions granted",
    required: true,
    durationMs: permissions.durationMs,
    binary: "deskjig",
  };
  let granted = false;
  let commandBroken = false;
  if (permissions.exitCode === 6) {
    record({ ...permBase, status: "SKIP", detail: `SKIP(env): ${AX_CONTEXT_NOT_READY} (${failDetail(permissions)})` });
  } else if (permissions.exitCode !== 0 || permissions.timedOut) {
    commandBroken = true;
    record({ ...permBase, status: "FAIL", detail: `permissions command broken (code failure, not environment): ${failDetail(permissions)}` });
  } else {
    try {
      const payload = parseJsonOutput(permissions.stdout) as { success?: boolean; data?: { granted?: boolean } };
      if (typeof payload?.data?.granted !== "boolean") {
        commandBroken = true;
        record({ ...permBase, status: "FAIL", detail: "permissions output has no boolean data.granted (code failure, not environment)" });
      } else {
        granted = payload.data.granted;
        handleGolden(opts, "permissions", payload);
        record({
          ...permBase,
          status: granted ? "PASS" : "SKIP",
          detail: granted ? "Accessibility permissions granted" : `SKIP(env): ${AX_CONTEXT_NOT_READY}`,
        });
      }
    } catch (error) {
      commandBroken = true;
      record({ ...permBase, status: "FAIL", detail: `permissions output is not parseable JSON (code failure, not environment): ${(error as Error).message}` });
    }
  }

  if (!granted) {
    record({
      id: "window-query",
      title: "AX gate: AX-requiring command works (window query)",
      status: "SKIP",
      required: true,
      durationMs: 0,
      detail: commandBroken ? "Skipped: permissions check is broken" : `SKIP(env): ${AX_CONTEXT_NOT_READY}`,
    });
    // Broken command -> continue the suite and exit 1; exit 6 or a parsed
    // granted:false is an environment failure (exit 3).
    return commandBroken;
  }

  // One command that actually exercises the Accessibility API
  // (requireAccessibility: true), so the gate proves AX works end to end.
  const query = run(binaries.deskjig.path, ["window", "query", "--format", "json"]);
  const queryBase = {
    id: "window-query",
    title: "AX gate: AX-requiring command works (window query)",
    required: true,
    durationMs: query.durationMs,
    binary: "deskjig",
  };
  if (query.exitCode !== 0 || query.timedOut) {
    record({ ...queryBase, status: "FAIL", detail: failDetail(query) });
    return true; // permissions ARE granted; this is a code failure, not environment
  }
  try {
    const payload = parseJsonOutput(query.stdout) as { success?: boolean; data?: unknown[] };
    const windows = Array.isArray(payload?.data) ? payload.data : [];
    if (!payload?.success || windows.length === 0) {
      record({ ...queryBase, status: "FAIL", detail: "AX window query returned no windows on a live machine" });
      return true;
    }
    handleGolden(opts, "window-query", payload);
    record({ ...queryBase, status: "PASS", detail: `${windows.length} window(s) via AX` });
  } catch (error) {
    record({ ...queryBase, status: "FAIL", detail: `Invalid JSON: ${(error as Error).message}` });
  }
  return true;
}

// ---------------------------------------------------------------------------
// Step 1: app<->CLI contract (replaces the removed cloud auth check)
//
// DeskJig has no account and no CLI session file, so "is this CLI talking to
// the live app?" is answered locally: the app must be running, and the bundle
// LaunchServices would hand bento:// URLs to must be that same running bundle.
// A second bundle with the same id (dev build next to an installed copy, #565)
// otherwise silently swallows `deskjig app restore` triggers.
// ---------------------------------------------------------------------------

interface AppStatusEnvelope {
  success?: boolean;
  message?: string;
  data?: {
    running?: boolean;
    instances?: Array<{ pid?: number; bundlePath?: string; version?: string | null }>;
    resolvedAppPath?: string | null;
  };
}

function checkAppContract(binaries: Binaries, opts: Options): void {
  const result = run(binaries.deskjig.path, ["app", "status", "--format", "json"]);
  const base = { id: "app-status", title: "Contract: DeskJig.app is running", required: true, durationMs: result.durationMs, binary: "deskjig" };
  const routingBase = { id: "app-url-routing", title: "Contract: bento:// URLs route to the running bundle", required: true, binary: "deskjig" };
  const skipRouting = (reason: string) => record({ ...routingBase, status: "SKIP", durationMs: 0, detail: reason });

  if (result.exitCode !== 0 || result.timedOut) {
    record({ ...base, status: "FAIL", detail: failDetail(result) });
    skipRouting("Skipped: app status failed");
    return;
  }

  let payload: AppStatusEnvelope;
  try {
    payload = parseJsonOutput(result.stdout) as AppStatusEnvelope;
  } catch (error) {
    record({ ...base, status: "FAIL", detail: `Invalid JSON: ${(error as Error).message}` });
    skipRouting("Skipped: app status output unparseable");
    return;
  }

  const instances = Array.isArray(payload.data?.instances) ? payload.data.instances : [];
  if (payload.success !== true || payload.data?.running !== true || instances.length === 0) {
    record({
      ...base,
      status: "FAIL",
      detail:
        `DeskJig.app is not running (running=${payload.data?.running ?? "?"}, instances=${instances.length})` +
        ` — a dead app must not smoke-pass; launch it and re-run`,
    });
    skipRouting("Skipped: no running DeskJig.app");
    return;
  }

  handleGolden(opts, "app-status", payload);
  const first = instances[0];
  record({
    ...base,
    status: "PASS",
    detail: `pid ${first?.pid ?? "?"} version ${first?.version ?? "unknown"} at ${first?.bundlePath ?? "?"}`,
  });

  if (instances.length > 1) {
    warn(
      `Multiple running DeskJig instances detected (pids ${instances.map((i) => i?.pid ?? "?").join(", ")}) — multi-instance is suspicious for verification; make sure the URL-routed bundle is the build under test`,
    );
  }

  // Routing assertion: `app restore` opens bento://restore at the RESOLVED
  // bundle. If that is not one of the running bundles, an in-app restore would
  // launch a different copy and the suite would verify the wrong build.
  const started = performance.now();
  const resolvedAppPath = payload.data?.resolvedAppPath ?? undefined;
  if (!resolvedAppPath) {
    record({
      ...routingBase,
      status: "FAIL",
      durationMs: performance.now() - started,
      detail: "app status resolved no DeskJig.app bundle for bento:// URLs",
    });
    return;
  }
  const runningPaths = instances.map((instance) => instance?.bundlePath).filter((path): path is string => typeof path === "string");
  if (!runningPaths.includes(resolvedAppPath)) {
    record({
      ...routingBase,
      status: "FAIL",
      durationMs: performance.now() - started,
      detail: `bento:// URLs resolve to ${resolvedAppPath}, which is not a running bundle (running: ${runningPaths.join(", ") || "none"}) — in-app triggers would hit the wrong copy (#565)`,
    });
    return;
  }
  record({
    ...routingBase,
    status: "PASS",
    durationMs: performance.now() - started,
    detail: `bento:// → ${resolvedAppPath} (running)`,
  });
}

// ---------------------------------------------------------------------------
// Steps 2-3: workspaces
//
// `workspace list` is both halves of the store contract: it must succeed and
// parse (the app and the CLI share one SavedWorkspaces store), and it must
// report at least one workspace for the rest of the suite to mean anything.
// One invocation, two recorded checks.
// ---------------------------------------------------------------------------

function checkWorkspaceList(binaries: Binaries, opts: Options): string | undefined {
  const result = run(binaries.deskjig.path, ["workspace", "list", "--format", "json"]);
  const storeBase = { id: "workspace-store", title: "Contract: shared workspace store readable via CLI", required: true, durationMs: result.durationMs, binary: "deskjig" };
  const base = { id: "workspace-list", title: "Workspaces: list parses, >= 1 workspace", required: true, durationMs: 0, binary: "deskjig" };
  if (result.exitCode !== 0 || result.timedOut) {
    record({ ...storeBase, status: "FAIL", detail: failDetail(result) });
    record({ ...base, status: "SKIP", detail: "Skipped: workspace list command failed" });
    return undefined;
  }
  let payload: { success?: boolean; data?: Array<{ name?: string }> };
  try {
    payload = parseJsonOutput(result.stdout) as { success?: boolean; data?: Array<{ name?: string }> };
  } catch (error) {
    record({ ...storeBase, status: "FAIL", detail: `Invalid JSON: ${(error as Error).message}` });
    record({ ...base, status: "SKIP", detail: "Skipped: workspace list output unparseable" });
    return undefined;
  }
  const workspaces = Array.isArray(payload?.data) ? payload.data : [];
  if (payload?.success !== true || !Array.isArray(payload?.data)) {
    record({ ...storeBase, status: "FAIL", detail: `Store envelope is not a success payload with an array (success=${payload?.success ?? "?"})` });
    record({ ...base, status: "SKIP", detail: "Skipped: store contract failed" });
    return undefined;
  }
  record({ ...storeBase, status: "PASS", detail: "workspace store read through the CLI's shared-defaults path" });

  if (workspaces.length === 0) {
    record({ ...base, status: "FAIL", detail: "No saved workspaces found — the suite needs at least one real workspace" });
    return undefined;
  }
  handleGolden(opts, "workspace-list", payload);
  const first = workspaces[0]?.name;
  record({ ...base, status: "PASS", detail: `${workspaces.length} workspace(s); first: "${first}"` });
  return first;
}

function checkWorkspaceInfo(binaries: Binaries, opts: Options, workspaceName: string | undefined): void {
  const base = { id: "workspace-info", title: "Workspaces: info on first workspace", required: true, binary: "deskjig" };
  if (!workspaceName) {
    record({ ...base, status: "SKIP", durationMs: 0, detail: "No workspace available (workspace-list failed)" });
    return;
  }
  const result = run(binaries.deskjig.path, ["workspace", "info", workspaceName, "--format", "json"]);
  if (result.exitCode !== 0 || result.timedOut) {
    record({ ...base, status: "FAIL", durationMs: result.durationMs, detail: failDetail(result) });
    return;
  }
  try {
    const payload = parseJsonOutput(result.stdout) as { success?: boolean; data?: { name?: string; windows?: unknown[] } };
    if (!payload?.success || payload?.data?.name !== workspaceName) {
      record({ ...base, status: "FAIL", durationMs: result.durationMs, detail: `Unexpected payload for "${workspaceName}"` });
      return;
    }
    handleGolden(opts, "workspace-info", payload);
    const windowCount = Array.isArray(payload.data.windows) ? payload.data.windows.length : 0;
    record({ ...base, status: "PASS", durationMs: result.durationMs, detail: `"${workspaceName}": ${windowCount} window(s) in detail payload` });
  } catch (error) {
    record({ ...base, status: "FAIL", durationMs: result.durationMs, detail: `Invalid JSON: ${(error as Error).message}` });
  }
}

// ---------------------------------------------------------------------------
// Step 4: diagnostics
// ---------------------------------------------------------------------------

function checkJsonProbe(
  binaries: Binaries,
  opts: Options,
  params: {
    id: string;
    title: string;
    spec: ProbeSpec;
    validate: (payload: unknown) => string | { fail: string };
  },
): void {
  const outcome = runProbe(binaries, params.spec);
  if ("error" in outcome) {
    record({ id: params.id, title: params.title, status: "FAIL", required: true, durationMs: 0, detail: outcome.error });
    return;
  }
  const base = { id: params.id, title: params.title, required: true, durationMs: outcome.result.durationMs, binary: outcome.binaryLabel };
  if (outcome.result.exitCode !== 0 || outcome.result.timedOut) {
    record({ ...base, status: "FAIL", detail: failDetail(outcome.result) });
    return;
  }
  try {
    const payload = parseJsonOutput(outcome.result.stdout);
    const verdict = params.validate(payload);
    if (typeof verdict !== "string") {
      record({ ...base, status: "FAIL", detail: verdict.fail });
      return;
    }
    handleGolden(opts, params.id, payload);
    record({ ...base, status: "PASS", detail: verdict });
  } catch (error) {
    record({ ...base, status: "FAIL", detail: `Invalid JSON: ${(error as Error).message}` });
  }
}

function checkDiagnostics(binaries: Binaries, opts: Options): void {
  checkJsonProbe(binaries, opts, {
    id: "dump-windows",
    title: "Diagnostics: dump-windows",
    spec: {
      capabilityPath: ["debug", "dump-windows"],
      deskjigArgs: ["debug", "dump-windows", "--format", "json"],
    },
    validate: (payload) => {
      const windows = Array.isArray(payload) ? payload : (payload as { data?: unknown[] })?.data;
      if (!Array.isArray(windows)) return { fail: "Expected an array of windows" };
      if (windows.length === 0) return { fail: "Zero windows reported — expected at least one on a live machine" };
      return `${windows.length} window(s) dumped`;
    },
  });

  checkJsonProbe(binaries, opts, {
    id: "display-list",
    title: "Diagnostics: display list",
    spec: {
      capabilityPath: ["display", "list"],
      deskjigArgs: ["display", "list", "--format", "json"],
    },
    validate: (payload) => {
      const displays = (payload as { data?: unknown[] })?.data ?? (Array.isArray(payload) ? payload : undefined);
      if (!Array.isArray(displays) || displays.length === 0) return { fail: "Expected >= 1 connected display" };
      return `${displays.length} display(s)`;
    },
  });

  checkJsonProbe(binaries, opts, {
    id: "app-list",
    title: "Diagnostics: app list",
    spec: {
      capabilityPath: ["app", "list"],
      deskjigArgs: ["app", "list", "--format", "json"],
    },
    validate: (payload) => {
      const apps = (payload as { data?: unknown[] })?.data ?? (Array.isArray(payload) ? payload : undefined);
      if (!Array.isArray(apps) || apps.length === 0) return { fail: "Expected >= 1 running app" };
      return `${apps.length} running app(s)`;
    },
  });
}

// ---------------------------------------------------------------------------
// Step 5: logs / run IDs
// ---------------------------------------------------------------------------

function checkLogs(binaries: Binaries, opts: Options): void {
  const skipShow = (reason: string) =>
    record({ id: "show-run-id", title: "Logs: show latest trace", status: "SKIP", required: true, durationMs: 0, detail: reason });

  const listing = runProbe(binaries, {
    capabilityPath: ["logs", "run-ids"],
    deskjigArgs: ["logs", "run-ids", "--lines", "500", "--format", "json"],
  });
  if ("error" in listing) {
    record({ id: "run-ids", title: "Logs: list restoration run IDs", status: "FAIL", required: true, durationMs: 0, detail: listing.error });
    skipShow("No run-ID listing available");
    return;
  }
  const base = { id: "run-ids", title: "Logs: list restoration run IDs", required: true, durationMs: listing.result.durationMs, binary: listing.binaryLabel };
  if (listing.result.exitCode !== 0 || listing.result.timedOut) {
    record({ ...base, status: "FAIL", detail: failDetail(listing.result) });
    skipShow("No run-ID listing available");
    return;
  }

  let ids: string[];
  try {
    const payload = parseJsonOutput(listing.result.stdout);
    const entries = (Array.isArray(payload) ? payload : (payload as { data?: unknown[] })?.data) as Array<{ runId?: string }> | undefined;
    if (!Array.isArray(entries)) {
      record({ ...base, status: "FAIL", detail: "Expected an array of run-ID entries" });
      skipShow("No run-ID listing available");
      return;
    }
    ids = entries.map((entry) => entry?.runId).filter((id): id is string => typeof id === "string");
    handleGolden(opts, "run-ids", payload);
  } catch (error) {
    record({ ...base, status: "FAIL", detail: `Invalid JSON: ${(error as Error).message}` });
    skipShow("No run-ID listing available");
    return;
  }
  record({ ...base, status: "PASS", detail: `${ids.length} run ID(s) found` });

  if (ids.length === 0) {
    skipShow("No run IDs in logs yet (no restoration has ever run on this machine)");
    return;
  }

  const latest = ids[0];
  const show = runProbe(binaries, {
    capabilityPath: ["logs", "show"],
    deskjigArgs: ["logs", "show", latest, "--lines", "50"],
  });
  if ("error" in show) {
    record({ id: "show-run-id", title: "Logs: show latest trace", status: "FAIL", required: true, durationMs: 0, detail: show.error });
    return;
  }
  const showBase = { id: "show-run-id", title: "Logs: show latest trace", required: true, durationMs: show.result.durationMs, binary: show.binaryLabel };
  if (show.result.exitCode !== 0 || show.result.timedOut) {
    record({ ...showBase, status: "FAIL", detail: failDetail(show.result) });
    return;
  }
  if (!show.result.stdout.includes(latest)) {
    record({ ...showBase, status: "FAIL", detail: `Trace output does not mention run ID ${latest}` });
    return;
  }
  const lineCount = show.result.stdout.trim().split("\n").length;
  record({ ...showBase, status: "PASS", detail: `Trace for ${latest}: ${lineCount} line(s)` });
}

// ---------------------------------------------------------------------------
// Step 6: opt-in restore verification
// ---------------------------------------------------------------------------

const RUN_ID_REGEX = /restore_\d{1,6}_[a-z0-9]{6}/g;
const NDJSON_RUN_ID_REGEX = /^(restore_\d{1,6}_[a-z0-9]{6})\.ndjson$/;
const QUIESCENCE_MS = 5_000;

/** Set by checkRestore to pick the suite's exit code (4/5/6). */
let restoreExitCode: number | undefined;

/**
 * Candidate restore-trace directories. Worktree-isolated binaries
 * (BENTO_WORKTREE_NAME) log under Logs/Bento/worktrees/<name>/, so the suite
 * must not blindly assert the default path.
 */
function candidateTraceDirs(binaries: Binaries): string[] {
  const logRoot = join(homedir(), "Library", "Logs", LOG_DIRECTORY_NAME);
  const dirs: string[] = [];

  const worktreeName = process.env[WORKTREE_NAME_ENV];
  if (worktreeName) {
    dirs.push(join(logRoot, "worktrees", worktreeName, RESTORE_TRACE_DIRECTORY_NAME));
    warn(
      `${WORKTREE_NAME_ENV}=${worktreeName} is set: logs/traces go under Logs/${LOG_DIRECTORY_NAME}/worktrees/${worktreeName}/ — polling that path first`,
    );
  }

  const worktreeMatch = binaries.deskjig.path.match(/\/\.claude\/worktrees\/([^/]+)\//);
  if (worktreeMatch) {
    dirs.push(join(logRoot, "worktrees", worktreeMatch[1], RESTORE_TRACE_DIRECTORY_NAME));
    warn(
      `deskjig was built from worktree "${worktreeMatch[1]}" — if it runs with worktree log isolation, traces land under Logs/${LOG_DIRECTORY_NAME}/worktrees/${worktreeMatch[1]}/; polling both paths`,
    );
  }

  dirs.push(join(logRoot, RESTORE_TRACE_DIRECTORY_NAME));
  return [...new Set(dirs)];
}

interface TraceFiles {
  ndjson?: string;
  summary?: string;
}

function findTraceFiles(traceDirs: string[], runId: string): TraceFiles {
  const found: TraceFiles = {};
  for (const dir of traceDirs) {
    const ndjson = join(dir, `${runId}.ndjson`);
    const summary = join(dir, `${runId}-summary.json`);
    if (!found.ndjson && existsSync(ndjson)) found.ndjson = ndjson;
    if (!found.summary && existsSync(summary)) found.summary = summary;
  }
  return found;
}

/**
 * Newest run ID whose .ndjson trace appeared after the trigger timestamp.
 * This is the reliable discovery path for app-context restores too, where
 * run-ID log listings are a known blind spot.
 */
function discoverRunIdFromTraces(traceDirs: string[], triggerEpochMs: number): string | undefined {
  let best: { runId: string; mtime: number } | undefined;
  for (const dir of traceDirs) {
    if (!existsSync(dir)) continue;
    for (const entry of readdirSync(dir)) {
      const match = entry.match(NDJSON_RUN_ID_REGEX);
      if (!match) continue;
      const mtime = statSync(join(dir, entry)).mtimeMs;
      if (mtime < triggerEpochMs - 1_000) continue;
      if (!best || mtime > best.mtime) best = { runId: match[1], mtime };
    }
  }
  return best?.runId;
}

/** Copy the run's trace + summary into the output dir (retention keeps only 10). */
function preserveEvidence(traceDirs: string[], runId: string, outputDir: string): string[] {
  const preserved: string[] = [];
  try {
    mkdirSync(outputDir, { recursive: true });
  } catch {
    return preserved;
  }
  for (const dir of traceDirs) {
    if (!existsSync(dir)) continue;
    for (const entry of readdirSync(dir)) {
      if (!entry.startsWith(runId)) continue;
      try {
        copyFileSync(join(dir, entry), join(outputDir, entry));
        preserved.push(join(outputDir, entry));
      } catch {
        // Evidence preservation is best-effort; the verdict does not depend on it.
      }
    }
  }
  return preserved;
}

async function sleep(ms: number): Promise<void> {
  await new Promise((resolvePromise) => setTimeout(resolvePromise, ms));
}

/**
 * Strictly parse a summary count: only a value actually bearing a
 * non-negative integer counts. Blank strings, null, undefined, and garbage
 * return undefined — note `Number("")` and `Number(null)` are 0, which must
 * NOT pass as a real count.
 */
function parseCount(value: unknown): number | undefined {
  if (typeof value === "number" && Number.isInteger(value) && value >= 0) return value;
  if (typeof value === "string" && /^\d+$/.test(value.trim())) return Number(value.trim());
  return undefined;
}

async function checkRestore(binaries: Binaries, opts: Options, firstWorkspace: string | undefined): Promise<void> {
  const isApp = opts.mode === "app";
  const base = {
    id: "restore",
    title: `Restore: workspace restore completes (trace-verified, --mode ${opts.mode})`,
    required: true,
    binary: "deskjig",
  };

  const workspaceName = opts.restoreWorkspace ?? firstWorkspace;
  if (!workspaceName) {
    record({ ...base, status: "FAIL", durationMs: 0, detail: "No workspace available to restore" });
    restoreExitCode = EXIT_RESTORE_FAILED;
    return;
  }

  if (isApp && !deskjigSupports(binaries.deskjig.path, ["app", "restore"])) {
    record({
      ...base,
      status: "FAIL",
      durationMs: 0,
      detail: "deskjig's command surface has no `app restore` (#465) — rebuild the deskjig scheme",
    });
    restoreExitCode = EXIT_ENVIRONMENT;
    return;
  }

  if (binaries.deskjig.configuration === "Release") {
    warn("deskjig is a Release build: restore traces are unconditional only in Debug builds — trace-based verification may time out. Use a Debug build for the smoke suite.");
  }
  if (isApp) {
    warn(
      "--mode app: the restore runs inside the RUNNING DeskJig.app — it must be a Debug build, or a Release build with `defaults write com.mscontrol.bento BentoAllowAppRestoreURL -bool true`, or the trigger is silently rejected and the wait times out.",
    );
  }

  const traceDirs = candidateTraceDirs(binaries);
  const outputDir = opts.outputDir ?? join("/tmp", "deskjig-cli-smoke", new Date().toISOString().replace(/[:.]/g, "-"));

  const started = performance.now();
  const triggerEpochMs = Date.now();
  // --mode app delegates the wait to `deskjig app restore --wait` (in-app
  // context); give the spawn a margin beyond the CLI's own timeout so the
  // CLI's timeout envelope is observed instead of a spawn kill.
  const triggerArgs = isApp
    ? ["app", "restore", workspaceName, "--wait", "--timeout", String(opts.restoreTimeoutSec), "--format", "json"]
    : ["workspace", "restore", workspaceName, "--format", "json"];
  const restore = run(binaries.deskjig.path, triggerArgs, opts.restoreTimeoutSec * 1000 + (isApp ? 30_000 : 0));

  if (restore.timedOut) {
    record({ ...base, status: "FAIL", durationMs: performance.now() - started, detail: `Restore command timed out after ${opts.restoreTimeoutSec}s` });
    restoreExitCode = EXIT_RESTORE_TIMEOUT;
    return;
  }

  // Parse the restore command's JSON envelope IMMEDIATELY — its own verdict
  // (exitCode / success / data.failed) is authoritative for the trigger.
  let envelopeFailure: string | undefined;
  let envelopeRunId: string | undefined;
  let envelopeTimedOut = false;
  try {
    const envelope = parseJsonOutput(restore.stdout) as {
      success?: boolean;
      exitCode?: number;
      message?: string;
      error?: string;
      data?: { failed?: number; restored?: number; runId?: string };
    };
    if (typeof envelope?.data?.runId === "string") envelopeRunId = envelope.data.runId;
    if (envelope?.exitCode !== 0 || envelope?.success !== true) {
      envelopeFailure = `Restore envelope reports failure (success=${envelope?.success}, exitCode=${envelope?.exitCode}, message="${envelope?.message ?? envelope?.error ?? ""}")`;
      envelopeTimedOut = /timed out/i.test(envelope?.error ?? "");
    } else if (typeof envelope?.data?.failed === "number" && envelope.data.failed > 0) {
      envelopeFailure = `Restore envelope reports ${envelope.data.failed} failed window(s)`;
    }
  } catch (error) {
    envelopeFailure = `Restore output is not a parseable JSON envelope (${(error as Error).message})`;
  }
  if (restore.exitCode !== 0 && !envelopeFailure) {
    envelopeFailure = failDetail(restore);
  }

  // Locate the run ID: envelope, stdout/stderr scrape, then fresh .ndjson
  // trace files (newest with mtime after the trigger).
  let runId = envelopeRunId ?? [...`${restore.stdout}\n${restore.stderr}`.matchAll(RUN_ID_REGEX)].map((m) => m[0]).pop();
  if (!runId) {
    const discoveryDeadline = performance.now() + 30_000;
    while (!runId && performance.now() < discoveryDeadline) {
      runId = discoverRunIdFromTraces(traceDirs, triggerEpochMs);
      if (!runId) await sleep(2_000);
    }
  }

  if (!runId) {
    record({
      ...base,
      status: "FAIL",
      durationMs: performance.now() - started,
      detail:
        (envelopeFailure ? `${envelopeFailure}; additionally: ` : "") +
        `no run ID found in restore output or in fresh trace files under ${traceDirs.join(", ")}`,
    });
    restoreExitCode = envelopeFailure ? (envelopeTimedOut ? EXIT_RESTORE_TIMEOUT : EXIT_RESTORE_FAILED) : EXIT_RESTORE_NO_RUN_ID;
    return;
  }

  if (envelopeFailure) {
    const preserved = preserveEvidence(traceDirs, runId, outputDir);
    record({
      ...base,
      status: "FAIL",
      durationMs: performance.now() - started,
      detail: `${envelopeFailure} (runId=${runId}${preserved.length > 0 ? `; evidence: ${outputDir}` : ""})`,
    });
    restoreExitCode = envelopeTimedOut ? EXIT_RESTORE_TIMEOUT : EXIT_RESTORE_FAILED;
    return;
  }

  // Completion = {runId}-summary.json exists AND the .ndjson has been
  // quiescent for ~5s (retries append to the same base trace file). The
  // verdict comes ONLY from a successfully parsed summary — an unparsed or
  // missing summary is NEVER treated as success.
  const deadline = performance.now() + opts.restoreTimeoutSec * 1000;
  let verdict: { status: Status; detail: string; exit?: number } | undefined;
  while (performance.now() < deadline) {
    const files = findTraceFiles(traceDirs, runId);
    if (files.summary && files.ndjson) {
      const ndjsonAge = Date.now() - statSync(files.ndjson).mtimeMs;
      if (ndjsonAge < QUIESCENCE_MS) {
        await sleep(Math.min(QUIESCENCE_MS - ndjsonAge + 250, QUIESCENCE_MS));
        continue;
      }
      let summary: Record<string, string>;
      try {
        summary = JSON.parse(readFileSync(files.summary, "utf-8")) as Record<string, string>;
      } catch {
        await sleep(1_000); // mid-write; retry — never default an unparsed summary to success
        continue;
      }
      const failed = parseCount(summary.failed);
      const restored = parseCount(summary.restored);
      const windowCount = parseCount(summary.windowCount);
      const counts = `restored=${summary.restored ?? "?"} failed=${summary.failed ?? "?"} skipped=${summary.skipped ?? "?"} windowCount=${summary.windowCount ?? "?"} totalMs=${summary.totalMs ?? "?"}`;
      if (failed === undefined || restored === undefined || windowCount === undefined) {
        const invalid = [
          failed === undefined ? "failed" : undefined,
          restored === undefined ? "restored" : undefined,
          windowCount === undefined ? "windowCount" : undefined,
        ]
          .filter(Boolean)
          .join(", ");
        verdict = {
          status: "FAIL",
          detail: `Summary for ${runId} has missing/malformed count(s): ${invalid} (${counts}) — a malformed summary is never a pass`,
          exit: EXIT_RESTORE_FAILED,
        };
      } else if (failed > 0) {
        verdict = { status: "FAIL", detail: `runId=${runId}: ${failed} window(s) failed (${counts})`, exit: EXIT_RESTORE_FAILED };
      } else if (restored < windowCount) {
        verdict = { status: "FAIL", detail: `runId=${runId}: short restore, restored ${restored} of ${windowCount} window(s) (${counts})`, exit: EXIT_RESTORE_FAILED };
      } else {
        verdict = { status: "PASS", detail: `runId=${runId} workspace="${summary.workspace ?? workspaceName}" ${counts}` };
      }
      break;
    }
    await sleep(2_000);
  }

  // Preserve evidence BEFORE exiting, whatever the verdict — trace retention
  // keeps only the last 10 runs and rotates evidence away.
  const preserved = preserveEvidence(traceDirs, runId, outputDir);
  const evidenceNote = preserved.length > 0 ? `; evidence: ${outputDir} (${preserved.length} file(s))` : "; no trace files found to preserve";

  if (!verdict) {
    record({
      ...base,
      status: "FAIL",
      durationMs: performance.now() - started,
      detail:
        `Timed out after ${opts.restoreTimeoutSec}s waiting for ${runId}-summary.json + quiescent trace under ` +
        `${traceDirs.join(", ")}${binaries.deskjig.configuration === "Release" ? " (Release builds do not write traces unconditionally)" : ""}${evidenceNote}`,
    });
    restoreExitCode = EXIT_RESTORE_TIMEOUT;
    return;
  }

  record({ ...base, status: verdict.status, durationMs: performance.now() - started, detail: `${verdict.detail}${evidenceNote}` });
  if (verdict.exit !== undefined) restoreExitCode = verdict.exit;
}

// ---------------------------------------------------------------------------
// Reporting
// ---------------------------------------------------------------------------

function describeBinary(binary: LocatedBinary): string {
  return `${binary.path} [${binary.configuration}, ${binary.source}]`;
}

function reportText(binaries: Binaries, opts: Options, totalMs: number, failedCount: number, exitCode: number): void {
  console.log("");
  console.log("DeskJig CLI smoke-test suite (#461)");
  console.log(`  deskjig: ${describeBinary(binaries.deskjig)}`);
  console.log(`  mode:    ${opts.restore ? `read-only + restore (--mode ${opts.mode})` : "read-only (steps 0-5; use --restore to opt in to step 6)"}`);
  if (opts.captureGoldenDir) console.log(`  golden:  capturing to ${opts.captureGoldenDir}`);
  if (opts.goldenDir) console.log(`  golden:  comparing against ${opts.goldenDir}`);
  console.log("");

  const idWidth = Math.max(...checks.map((c) => c.id.length), 8);
  for (const check of checks) {
    const time = `${check.durationMs.toFixed(0)}ms`.padStart(8);
    const binary = check.binary ? ` [${check.binary}]` : "";
    console.log(`  ${check.status.padEnd(4)} ${check.id.padEnd(idWidth)} ${time}  ${check.detail}${binary}`);
  }

  for (const warning of warnings) {
    console.log(`\n  WARN ${warning}`);
  }

  const passed = checks.filter((c) => c.status === "PASS").length;
  const skipped = checks.filter((c) => c.status === "SKIP").length;
  console.log("");
  console.log(`  ${passed} passed, ${failedCount} failed, ${skipped} skipped in ${(totalMs / 1000).toFixed(1)}s`);
  console.log(`  RESULT: ${exitCode === EXIT_PASS ? "PASS" : "FAIL"} (exit ${exitCode})`);
  console.log("");
}

function reportJson(binaries: Binaries, opts: Options, totalMs: number, failedCount: number, exitCode: number): void {
  console.log(
    JSON.stringify(
      {
        suite: "cli-smoke-test",
        ok: exitCode === EXIT_PASS,
        exitCode,
        binaries: {
          deskjig: {
            path: binaries.deskjig.path,
            configuration: binaries.deskjig.configuration,
            source: binaries.deskjig.source,
          },
        },
        restoreRequested: opts.restore,
        restoreMode: opts.restore ? opts.mode : null,
        goldenCaptureDir: opts.captureGoldenDir ?? null,
        goldenCompareDir: opts.goldenDir ?? null,
        totalMs: Math.round(totalMs),
        checks,
        warnings,
        summary: {
          passed: checks.filter((c) => c.status === "PASS").length,
          failed: failedCount,
          skipped: checks.filter((c) => c.status === "SKIP").length,
        },
      },
      null,
      2,
    ),
  );
}

// ---------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------

async function main(): Promise<void> {
  const opts = parseArgs(process.argv.slice(2));
  verboseEcho = opts.verbose;

  const deskjig = locateBinary("deskjig", opts.deskjigPath);
  if (!deskjig) {
    console.error("Error: deskjig binary not found (environment not ready).");
    console.error(`Looked for executables matching: ${join(repoRoot, "build/*/Build/Products/{Debug,Release}/deskjig")}`);
    console.error(`               and the embedded copy: build/*/Build/Products/{Debug,Release}/DeskJig.app/${EMBEDDED_CLI_SUBPATH}`);
    console.error(`               and the installed copy: /Applications/DeskJig.app/${EMBEDDED_CLI_SUBPATH}`);
    console.error(`Build the deskjig scheme (docs/PORT_PLAN.md, checkpoint C), pass --deskjig <path>, or set ${BINARY_OVERRIDE_ENV}=<path>`);
    process.exit(EXIT_ENVIRONMENT);
  }
  const binaries: Binaries = { deskjig };

  if (deskjig.configuration === "Release" && !opts.restore) {
    warn("deskjig is a Release build: restore traces are unconditional only in Debug builds — use a Debug build before running --restore.");
  }
  if (process.env[WORKTREE_NAME_ENV] && !opts.restore) {
    warn(`${WORKTREE_NAME_ENV}=${process.env[WORKTREE_NAME_ENV]} is set: log/trace paths move under Logs/${LOG_DIRECTORY_NAME}/worktrees/ for worktree-isolated runs.`);
  }

  if (opts.captureGoldenDir) {
    mkdirSync(opts.captureGoldenDir, { recursive: true });
    writeFileSync(
      join(opts.captureGoldenDir, "_meta.json"),
      `${JSON.stringify({ capturedAt: new Date().toISOString(), deskjig: deskjig.path }, null, 2)}\n`,
    );
  }

  const started = performance.now();

  // Step 0: Accessibility gate. Not granted = environment failure (exit 3),
  // distinct from code failures — nothing else is trustworthy without AX.
  const axReady = checkAccessibilityGate(binaries, opts);
  if (!axReady) {
    for (const diagnostic of [
      { id: "dump-windows", title: "Diagnostics: dump-windows" },
      { id: "display-list", title: "Diagnostics: display list" },
      { id: "app-list", title: "Diagnostics: app list" },
    ]) {
      record({ ...diagnostic, status: "SKIP", required: true, durationMs: 0, detail: `SKIP(env): ${AX_CONTEXT_NOT_READY}` });
    }
    if (opts.restore) {
      record({
        id: "restore",
        title: `Restore: workspace restore completes (trace-verified, --mode ${opts.mode})`,
        status: "SKIP",
        required: true,
        durationMs: 0,
        detail: `SKIP(env): ${AX_CONTEXT_NOT_READY}`,
      });
    }
    const totalMs = performance.now() - started;
    const failedCount = checks.filter((c) => c.status === "FAIL" && c.required).length;
    if (opts.format === "json") reportJson(binaries, opts, totalMs, failedCount, EXIT_ENVIRONMENT);
    else reportText(binaries, opts, totalMs, failedCount, EXIT_ENVIRONMENT);
    process.exit(EXIT_ENVIRONMENT);
  }

  // Step 1: app<->CLI contract (live app + URL routing)
  checkAppContract(binaries, opts);

  // Steps 2-3: workspaces
  const firstWorkspace = checkWorkspaceList(binaries, opts);
  checkWorkspaceInfo(binaries, opts, firstWorkspace);

  // Step 4: diagnostics
  checkDiagnostics(binaries, opts);

  // Step 5: logs / run IDs
  checkLogs(binaries, opts);

  // Step 6: restore (opt-in only — moves real windows)
  if (opts.restore) {
    await checkRestore(binaries, opts, firstWorkspace);
  }

  const totalMs = performance.now() - started;
  const failedCount = checks.filter((c) => c.status === "FAIL" && c.required).length;
  const exitCode = restoreExitCode ?? (failedCount > 0 ? EXIT_CHECK_FAILURE : EXIT_PASS);

  if (opts.format === "json") reportJson(binaries, opts, totalMs, failedCount, exitCode);
  else reportText(binaries, opts, totalMs, failedCount, exitCode);

  process.exit(exitCode);
}

await main();
