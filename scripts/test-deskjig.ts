#!/usr/bin/env bun
// test-deskjig.ts
// DeskJig

import { spawn } from "node:child_process";
import { createWriteStream, existsSync, mkdirSync, readFileSync } from "node:fs";
import { dirname, join } from "node:path";

type TestPlan = "full" | "headless" | "cli";
type BuildConfiguration = "Debug" | "Release";

const PLAN_NAMES: Record<TestPlan, string> = {
  full: "DeskJigTests-Full",
  headless: "DeskJigTests-Headless",
  cli: "DeskJigTests-CLI",
};

function trimLongLine(line: string, maxLen: number = 500): string {
  if (line.length <= maxLen) return line;
  return line.slice(0, maxLen) + "…";
}

function printHelp(): void {
  console.log(`
DeskJig Tests (macOS)

Runs the DeskJigTests XCTest/Swift Testing suite via the DeskJig scheme.

This command is non-interactive and exits when the test run completes:
exit 0 when every test passes, non-zero on any failure.

USAGE:
  bun run scripts/test-deskjig.ts [OPTIONS]

OPTIONS:
  -p, --plan <full|headless|cli>  Test plan to run (default: full)
                                    full     - every suite (needs a GUI/AX-capable session
                                               for the real-system integration suites)
                                    headless - pure-logic suites; safe on CI runners with
                                               no Accessibility grant
                                    cli      - suites exercising the bundled CLI binary
                                               (isolated so CLI churn can't red the
                                               whole gate)
      --debug                     Use Debug configuration (default)
      --release                   Use Release configuration
  -c, --configuration <name>      Explicit configuration (Debug|Release)
      --derived-data <path>       Override DerivedData path (default: build/DerivedData,
                                  shared with build:app for incremental builds)
      --no-signing                Disable code signing (sets CODE_SIGNING_ALLOWED=NO)
      --log-file <path>           Write full test output to this file
  -h, --help                      Show this help message

EXAMPLES:
  bun run test
  bun run test -- --plan headless
  bun run test -- --plan cli --no-signing

NOTES:
  - On success, this prints a pass/fail summary line suitable for pasting into a PR.
  - On failure, this prints the failing tests and exits non-zero.
`);
}

function parsePlan(value: string | undefined): TestPlan {
  if (value === "full" || value === "headless" || value === "cli") return value;
  console.error("Error: --plan must be one of: full, headless, cli");
  process.exit(1);
}

function parseConfiguration(value: string | undefined): BuildConfiguration {
  if (!value) return "Debug";
  const normalized = value.trim().toLowerCase();
  if (normalized === "debug") return "Debug";
  if (normalized === "release") return "Release";
  console.error("Error: --configuration must be Debug or Release");
  process.exit(1);
}

function destinationForHostArch(): string {
  if (process.arch === "arm64") return "platform=macOS,arch=arm64";
  if (process.arch === "x64") return "platform=macOS,arch=x86_64";
  return "platform=macOS";
}

const argv = process.argv.slice(2);
let plan: TestPlan = "full";
let configuration: BuildConfiguration = "Debug";
let derivedDataPath: string | undefined;
let disableSigning = false;
let logFilePath: string | undefined;

for (let i = 0; i < argv.length; i++) {
  const arg = argv[i];

  if (arg === "--help" || arg === "-h") {
    printHelp();
    process.exit(0);
  }

  if (arg === "--plan" || arg === "-p") {
    plan = parsePlan(argv[i + 1]);
    i++;
    continue;
  }

  if (arg === "--debug") {
    configuration = "Debug";
    continue;
  }

  if (arg === "--release") {
    configuration = "Release";
    continue;
  }

  if (arg === "--configuration" || arg === "-c") {
    configuration = parseConfiguration(argv[i + 1]);
    i++;
    continue;
  }

  if (arg === "--derived-data") {
    const nextArg = argv[i + 1];
    if (!nextArg) {
      console.error("Error: --derived-data requires a value");
      process.exit(1);
    }
    derivedDataPath = nextArg;
    i++;
    continue;
  }

  if (arg === "--no-signing") {
    disableSigning = true;
    continue;
  }

  if (arg === "--log-file") {
    const nextArg = argv[i + 1];
    if (!nextArg) {
      console.error("Error: --log-file requires a value");
      process.exit(1);
    }
    logFilePath = nextArg;
    i++;
    continue;
  }

  console.error(`Unknown argument: ${arg}`);
  console.error("Use --help for usage information");
  process.exit(1);
}

const repoRoot = process.cwd();
const workspacePath = join(repoRoot, "DeskJig.xcworkspace");
if (!existsSync(workspacePath)) {
  console.error(`Error: Expected workspace at ${workspacePath}`);
  console.error("Run this from the repo root (the folder containing DeskJig.xcworkspace).");
  process.exit(1);
}

const planName = PLAN_NAMES[plan];
const planPath = join(repoRoot, "TestPlans", `${planName}.xctestplan`);
if (!existsSync(planPath)) {
  console.error(`Error: Expected test plan at ${planPath}`);
  process.exit(1);
}

// Share DerivedData with build:app so test runs reuse the app build.
const resolvedDerivedDataPath = derivedDataPath ?? join(repoRoot, "build", "DerivedData");
mkdirSync(resolvedDerivedDataPath, { recursive: true });

const resolvedLogFilePath = logFilePath ?? join(repoRoot, "build", `deskjig-tests.${plan}.log`);
mkdirSync(dirname(resolvedLogFilePath), { recursive: true });
const logStream = createWriteStream(resolvedLogFilePath, { flags: "w" });

// Xcode 26 gap (verified empirically on 26.6/17F113): `xcodebuild test -testPlan …`
// ignores a plan's selectedTests/skippedTests entries for Swift Testing suites —
// selected ST suites silently don't run, skipped ST suites run anyway (XCTest
// classes are honored; Xcode's own runner honors both). `-only-testing:` /
// `-skip-testing:` DO work for Swift Testing, so the plan files stay the single
// source of truth for lane membership and we translate their entries into
// command-line filters here. Caveat (also verified): -only-testing takes
// precedence over -skip-testing, so a lane plan should use selectedTests OR
// skippedTests, never both — excluding one test from an otherwise-selected
// suite means enumerating the suite's other test functions.
interface TestPlanTarget {
  target?: { name?: string };
  selectedTests?: string[];
  skippedTests?: string[];
}

function selectionFlagsFromPlan(path: string): string[] {
  const parsed = JSON.parse(readFileSync(path, "utf-8")) as { testTargets?: TestPlanTarget[] };
  const flags: string[] = [];
  for (const testTarget of parsed.testTargets ?? []) {
    const targetName = testTarget.target?.name;
    if (!targetName) continue;
    // "Suite" or "Suite/testFunction()" → "Target/Suite[/testFunction()]". Keep the
    // entry verbatim: Swift Testing function identifiers only match WITH the trailing
    // parentheses (verified: without them the filter silently matches nothing and
    // xcodebuild still reports TEST SUCCEEDED).
    const toFlag = (prefix: string) => (entry: string) => `${prefix}:${targetName}/${entry}`;
    flags.push(...(testTarget.selectedTests ?? []).map(toFlag("-only-testing")));
    flags.push(...(testTarget.skippedTests ?? []).map(toFlag("-skip-testing")));
  }
  return flags;
}

const args: string[] = [
  "test",
  "-workspace",
  workspacePath,
  "-scheme",
  "DeskJig",
  "-configuration",
  configuration,
  "-derivedDataPath",
  resolvedDerivedDataPath,
  "-destination",
  destinationForHostArch(),
  "-testPlan",
  planName,
  // Clone-level parallel testing duplicates work under xcodebuild: Swift Testing
  // suites are not distributed across runner clones — each clone runs ALL of them
  // (verified: every ST case executed twice, on two test-host pids), and the
  // concurrent duplicate runs race on shared state (workspace storage, tmux
  // naming). Swift Testing still runs its own in-process parallelism.
  "-parallel-testing-enabled",
  "NO",
  ...selectionFlagsFromPlan(planPath),
];

const buildSettings: string[] = [];
if (disableSigning) {
  buildSettings.push("CODE_SIGNING_ALLOWED=NO", "CODE_SIGNING_REQUIRED=NO");
}

logStream.write(`Command line invocation:\n    xcodebuild ${[...args, ...buildSettings].join(" ")}\n\n`);

console.log(`Running DeskJigTests (plan: ${planName}, ${configuration})…`);

const xcodebuild = spawn("xcodebuild", [...args, ...buildSettings], {
  stdio: ["inherit", "pipe", "pipe"],
});

const lastLines: string[] = [];
const errorLines: string[] = [];
const failureLines: string[] = [];
// xcodebuild's unified test output can print the same Swift Testing case twice
// (live event + end-of-run replay), so counts are per unique test identifier.
const passedTests = new Set<string>();
const failedTests = new Set<string>();
const skippedTests = new Set<string>();
let sawTestSucceeded = false;
let sawTestFailed = false;
let pendingStdout = "";
let pendingStderr = "";

const pushRing = (ring: string[], line: string, max: number) => {
  ring.push(line);
  if (ring.length > max) ring.shift();
};

const looksLikeError = (line: string): boolean => {
  const lower = line.toLowerCase();
  return (
    lower.includes(" error:") ||
    lower.startsWith("error:") ||
    lower.includes("fatal error:") ||
    lower.includes("** build failed **") ||
    lower.includes("clang: error") ||
    lower.includes("swiftc: error") ||
    lower.includes("command phasescriptexecution failed") ||
    lower.includes("linker command failed") ||
    lower.includes("returned non-zero exit code")
  );
};

// Per-test outcome lines, all xcodebuild output modes:
//   Test case 'Suite/testFunction()' passed on 'My Mac - DeskJig (123)' (0.001 seconds)  (parallel, unified)
//   Test Case '-[DeskJigTests.ClassName testMethod]' passed (0.001 seconds).             (serial, XCTest)
//   ✔ Test "Display Name" passed after 0.001 seconds.                                    (serial, Swift Testing)
//   ✘ Test testFunction() failed after 0.001 seconds with 2 issues.                      (serial, Swift Testing)
//   ✔ Test "Name" with 3 test cases passed after 0.001 seconds.                          (serial, parameterized)
//
// None of these can be anchored to line start (#695): the test host's own
// app/os_log output races with the test runner's writes on the same pipe, so an
// outcome line is intermittently glued to the tail of a truncated log line
// ("…thread=com.apple.root.user-init✔ Test \"…\" passed after 0.001 seconds.").
// Which lines get glued varies run-to-run with thread timing, so an anchored
// parser undercounts by a random ±1–5 on identical content. xcodebuild also
// prefixes some Swift Testing lines with U+200B, which likewise defeats `^`.
// The Swift Testing pattern instead requires the outcome symbol (or true line
// start) immediately before "Test", and all patterns match anywhere in the
// line — globally, in case two outcome writes fuse into one physical line.
const outcomePatterns: RegExp[] = [
  /Test case '(?<id>[^']+)' (?<outcome>passed|failed|skipped) on '/gu,
  /Test Case '(?<id>-\[[^\]]+\])' (?<outcome>passed|failed|skipped) \(/gu,
  // "run with" excludes the whole-run footer ("✔ Test run with 444 tests in 63
  // suites passed…"); "[Cc]ase " excludes per-case lines of parameterized tests
  // and the XCTest formats handled above. A parameterized test's aggregate line
  // carries "with N test cases" between name and outcome; it is dropped so the
  // id stays the plain test name.
  /(?<=^|[✔✘⏭◇]️? )Test (?!run with|[Cc]ase )(?<id>.+?)(?: with \d+ test cases)? (?<outcome>passed|failed|skipped) after [\d.]+ seconds/gu,
];

const matchOutcomes = (line: string): { id: string; outcome: string }[] => {
  const results: { id: string; outcome: string }[] = [];
  for (const pattern of outcomePatterns) {
    pattern.lastIndex = 0;
    for (const match of line.matchAll(pattern)) {
      if (match.groups) results.push({ id: match.groups.id, outcome: match.groups.outcome });
    }
  }
  return results;
};

// Runner-reported totals, used to cross-check the per-line count (#695). Swift
// Testing prints one "Test run with N tests in M suites passed…" footer; XCTest
// prints the bundle total on the "Executed N tests…" line that follows its
// "Test Suite 'All tests'/'Selected tests'" summary line.
let swiftTestingRunTotal: number | null = null;
let xctestBundleTotal: number | null = null;
let awaitingXCTestBundleTotal = false;

const trackRunnerTotals = (line: string): void => {
  const swiftTestingRun = /Test run with (\d+) tests? in \d+ suites?/u.exec(line);
  if (swiftTestingRun) {
    swiftTestingRunTotal = Number(swiftTestingRun[1]);
    return;
  }
  if (/Test Suite '(All tests|Selected tests)' (passed|failed)/u.test(line)) {
    awaitingXCTestBundleTotal = true;
    return;
  }
  if (awaitingXCTestBundleTotal) {
    const executed = /^\s*Executed (\d+) tests?, with /u.exec(line);
    if (executed) {
      xctestBundleTotal = Number(executed[1]);
      awaitingXCTestBundleTotal = false;
    }
  }
};

// Other per-test failure signals worth surfacing verbatim.
const looksLikeTestFailure = (line: string): boolean => {
  return (
    /Restarting after unexpected exit, crash, or test timeout/.test(line) ||
    /Fatal error:/.test(line)
  );
};

const consumeLines = (text: string, pending: string): string => {
  const combined = pending + text;
  const parts = combined.split(/\r?\n/);
  const nextPending = parts.pop() ?? "";

  for (const raw of parts) {
    const line = raw.trimEnd();
    if (!line) continue;
    const clipped = trimLongLine(line);
    pushRing(lastLines, clipped, 200);
    // Match on the unclipped line: a glued outcome line (#695, see
    // outcomePatterns) can exceed the clip length with the outcome at its tail.
    const caseMatches = matchOutcomes(line);
    if (caseMatches.length > 0) {
      for (const caseMatch of caseMatches) {
        if (caseMatch.outcome === "passed") passedTests.add(caseMatch.id);
        else if (caseMatch.outcome === "failed") failedTests.add(caseMatch.id);
        else skippedTests.add(caseMatch.id);
      }
      continue;
    }
    trackRunnerTotals(line);
    if (looksLikeError(clipped)) pushRing(errorLines, clipped, 50);
    if (looksLikeTestFailure(clipped)) pushRing(failureLines, clipped.trim(), 100);
    if (clipped.includes("** TEST SUCCEEDED **")) sawTestSucceeded = true;
    if (clipped.includes("** TEST FAILED **")) sawTestFailed = true;
  }

  return nextPending;
};

const finalizePending = (pending: string) => {
  const line = pending.trimEnd();
  if (!line) return;
  consumeLines(line + "\n", "");
};

const forward = (chunk: Buffer, isErr: boolean) => {
  logStream.write(chunk);
  if (isErr) process.stderr.write(chunk);
  else process.stdout.write(chunk);

  const text = chunk.toString("utf8");
  if (isErr) pendingStderr = consumeLines(text, pendingStderr);
  else pendingStdout = consumeLines(text, pendingStdout);
};

xcodebuild.stdout?.on("data", (chunk: Buffer) => forward(chunk, false));
xcodebuild.stderr?.on("data", (chunk: Buffer) => forward(chunk, true));

xcodebuild.on("error", (error) => {
  console.error("Failed to start xcodebuild:", error.message);
  process.exit(1);
});

xcodebuild.on("close", (code) => {
  logStream.end();
  finalizePending(pendingStdout);
  finalizePending(pendingStderr);

  const skippedSuffix = skippedTests.size > 0 ? `, ${skippedTests.size} skipped` : "";
  const summaryLine = `DeskJigTests summary (plan: ${planName}, ${configuration}): ${passedTests.size} passed, ${failedTests.size} failed${skippedSuffix}`;

  // Cross-check the per-line count against the runner-reported totals (#695).
  // A mismatch means outcome lines were lost to output interleaving and the
  // summary count is not comparable across runs. Advisory only — it never
  // changes the exit code (XCTest folds skipped tests into "Executed N tests",
  // so unusual skip patterns could trip it spuriously).
  let crossCheckLine: string | null = null;
  if (swiftTestingRunTotal !== null || xctestBundleTotal !== null) {
    const expectedTotal = (swiftTestingRunTotal ?? 0) + (xctestBundleTotal ?? 0);
    const countedTotal = passedTests.size + failedTests.size + skippedTests.size;
    const breakdown = `Swift Testing ${swiftTestingRunTotal ?? 0} + XCTest ${xctestBundleTotal ?? 0}`;
    crossCheckLine =
      expectedTotal === countedTotal
        ? `DeskJigTests count cross-check (plan: ${planName}): runner reported ${expectedTotal} (${breakdown}) == parsed ${countedTotal} ✓`
        : `⚠️ DeskJigTests count cross-check MISMATCH (plan: ${planName}): runner reported ${expectedTotal} (${breakdown}) but parsed ${countedTotal} — outcome lines may have been lost to output interleaving (#695); do not compare this count across runs.`;
  }

  // A selection filter that matches nothing still yields ** TEST SUCCEEDED ** —
  // running zero tests is never a pass.
  if (code === 0 && sawTestSucceeded && passedTests.size === 0 && failedTests.size === 0) {
    console.error(`\nTests FAILED (plan: ${planName}, ${configuration}): xcodebuild succeeded but ran zero tests — check the plan's selectedTests identifiers.`);
    console.error(`Full log: ${resolvedLogFilePath}`);
    process.exit(1);
  }

  if (code !== 0 || sawTestFailed || !sawTestSucceeded || failedTests.size > 0) {
    console.error(`\nTests FAILED (plan: ${planName}, ${configuration}) with exit code ${code ?? 1}.`);

    if (failedTests.size > 0) {
      console.error("\n--- Failing tests ---");
      for (const testId of [...failedTests].sort()) console.error(`  ✘ ${testId}`);
    }
    if (failureLines.length > 0) {
      console.error("\n--- Crash/timeout signals ---");
      for (const line of failureLines) console.error(line);
    }
    if (errorLines.length > 0) {
      console.error("\n--- Error summary (recent) ---");
      for (const line of errorLines) console.error(line);
    }
    if (failedTests.size === 0 && failureLines.length === 0 && errorLines.length === 0 && lastLines.length > 0) {
      console.error("\n--- Last output (recent) ---");
      for (const line of lastLines.slice(-50)) console.error(line);
    }

    console.error(`\n${summaryLine}`);
    if (crossCheckLine) console.error(crossCheckLine);
    console.error(`Full log: ${resolvedLogFilePath}`);
    process.exit(code === 0 ? 1 : (code ?? 1));
  }

  console.log(`\nTests PASSED (plan: ${planName}, ${configuration}).`);
  console.log(summaryLine);
  if (crossCheckLine) console.log(crossCheckLine);
  console.log(`\nFull log: ${resolvedLogFilePath}`);
});
