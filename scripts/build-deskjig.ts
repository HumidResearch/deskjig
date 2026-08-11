#!/usr/bin/env bun
// build-deskjig.ts
// DeskJig

import { spawn } from "node:child_process";
import { createWriteStream, existsSync, mkdirSync } from "node:fs";
import { dirname, join } from "node:path";

type Target = "app" | "cli";
type BuildConfiguration = "Debug" | "Release";

function printHelp(): void {
  console.log(`
DeskJig Build (macOS)

Builds the DeskJig app or the deskjig CLI using the DeskJig workspace.

This command is non-interactive and exits when the build completes.

USAGE:
  bun run scripts/build-deskjig.ts --target <app|cli> [OPTIONS]

OPTIONS:
  -t, --target <app|cli>     What to build (required)
      --debug                Use Debug configuration (default)
      --release              Use Release configuration
  -c, --configuration <name> Explicit configuration (Debug|Release)
      --derived-data <path>  Override DerivedData path
      --no-signing           Disable code signing (sets CODE_SIGNING_ALLOWED=NO)
      --log-file <path>      Write full build output to this file
  -h, --help                 Show this help message

EXAMPLES:
  bun run build:app
  bun run build:app -- --release
  bun run build:cli -- --debug
  bun run build:cli -- --configuration Release

NOTES:
  - Full output is teed to the log file; on failure, tail that file for details.
`);
}

function parseTarget(value: string | undefined): Target {
  if (value === "app" || value === "cli") return value;
  console.error("Error: --target must be one of: app, cli");
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

function destinationForHostArch(): string | undefined {
  if (process.platform !== "darwin") return undefined;
  if (process.arch === "arm64") return "platform=macOS,arch=arm64";
  if (process.arch === "x64") return "platform=macOS,arch=x86_64";
  return "platform=macOS";
}

const argv = process.argv.slice(2);
let target: Target | undefined;
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

  if (arg === "--target" || arg === "-t") {
    target = parseTarget(argv[i + 1]);
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

if (!target) {
  console.error("Error: --target is required");
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

const scheme = target === "app" ? "DeskJig" : "deskjig";
const defaultDerivedDataPath =
  target === "app"
    ? join(repoRoot, "build", "DerivedData")
    : join(repoRoot, "build", "deskjig");

const resolvedDerivedDataPath = derivedDataPath ?? defaultDerivedDataPath;
mkdirSync(resolvedDerivedDataPath, { recursive: true });

// Both build logs live under the (gitignored) build/ directory so a build never
// leaves untracked files at the repo root.
const defaultLogFile = join(repoRoot, "build", `deskjig-build.${target}.log`);

const resolvedLogFilePath = logFilePath ?? defaultLogFile;
mkdirSync(dirname(resolvedLogFilePath), { recursive: true });
const logStream = createWriteStream(resolvedLogFilePath, { flags: "w" });

const destination = destinationForHostArch();

const args: string[] = [
  "-workspace",
  workspacePath,
  "-scheme",
  scheme,
  "-configuration",
  configuration,
  "-derivedDataPath",
  resolvedDerivedDataPath,
];

if (destination) {
  args.push("-destination", destination);
}

args.push("build");

const buildSettings: string[] = [];
if (disableSigning) {
  buildSettings.push("CODE_SIGNING_ALLOWED=NO", "CODE_SIGNING_REQUIRED=NO");
}

logStream.write(`Command line invocation:\n    xcodebuild ${[...args, ...buildSettings].join(" ")}\n\n`);

const xcodebuild = spawn("xcodebuild", [...args, ...buildSettings], {
  stdio: ["inherit", "pipe", "pipe"],
});

// Tee: everything xcodebuild prints goes to the console and to the log file.
const forward = (chunk: Buffer, isErr: boolean) => {
  logStream.write(chunk);
  if (isErr) process.stderr.write(chunk);
  else process.stdout.write(chunk);
};

xcodebuild.stdout?.on("data", (chunk: Buffer) => forward(chunk, false));
xcodebuild.stderr?.on("data", (chunk: Buffer) => forward(chunk, true));

xcodebuild.on("error", (error) => {
  console.error("Failed to start xcodebuild:", error.message);
  process.exit(1);
});

xcodebuild.on("close", (code) => {
  logStream.end();

  if (code !== 0) {
    console.error(`\nBuild failed (${scheme}, ${configuration}) with exit code ${code ?? 1}.`);
    console.error(`Full log: ${resolvedLogFilePath}`);
    console.error(`View errors: grep -n "error:" ${resolvedLogFilePath} | tail -50`);
    process.exit(code ?? 1);
  }

  console.log(`\nBuild succeeded (${scheme}, ${configuration}).`);
  console.log(`Full log: ${resolvedLogFilePath}`);
});
