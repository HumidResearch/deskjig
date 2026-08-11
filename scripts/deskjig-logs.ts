#!/usr/bin/env bun
// deskjig-logs.ts
// DeskJig

import { promises as fs } from "node:fs";
import { join, basename } from "node:path";
import { homedir } from "node:os";
import { spawnSync } from "node:child_process";

type SearchFilters = {
  queries: string[];
  regexes: RegExp[];
  subsystems: string[];
};

function printHelp(): void {
  console.log(`
DeskJig Runtime Logs

View runtime logs from the DeskJig app (CocoaLumberjack DDFileLogger output).

USAGE:
  bun run logs -- [OPTIONS]

OPTIONS:
  -l, --lines <number>   Number of lines to show (default: 100)
  -f, --follow           Follow log file (tail -f behavior)
  -q, --query <text>     Add a case-insensitive substring filter (repeatable)
  -x, --regex <pattern>  Add a case-insensitive regex filter (repeatable)
  -s, --subsystem <id>   Filter to a log subsystem such as restore.executor (repeatable)
  -r, --recent <number>  Search the N most recent log files (default: 3 with filters, 1 otherwise)
  -t, --timestamp        Prefix each output line with a timestamp
  --run-id <uuid>        Show logs for a specific RESTORE-DEBUG run id
  --list                 List all available log files
  -h, --help             Show this help message

EXAMPLES:
  bun run logs                         # Show last 100 lines
  bun run logs -- --lines 50           # Show last 50 lines
  bun run logs -- --follow             # Stream live logs
  bun run logs -- --query "DW-Restore" # Filter for restoration logs
  bun run logs -- --query "RTSUMMARY" --recent 3
  bun run logs -- --subsystem restore.positioning --query "set-frame"
  bun run logs -- --regex "RT:\\[.*\\]\\[POSITION\\]" --regex "displayID=1"
  bun run logs -- --query "isMainThread" # Check thread diagnostics
  bun run logs -- --run-id <uuid>      # Show a single restore run slice
  bun run logs -- --list               # List all log files
`);
}

function detectWorktree(): { isWorktree: boolean; name: string | null } {
  try {
    const result = spawnSync("git", ["rev-parse", "--is-inside-work-tree"], { encoding: "utf-8" });
    if (result.status !== 0) return { isWorktree: false, name: null };

    const gitPath = join(process.cwd(), ".git");
    const stat = require("node:fs").statSync(gitPath);
    if (stat.isDirectory()) return { isWorktree: false, name: null };

    return { isWorktree: true, name: basename(process.cwd()) };
  } catch {
    return { isWorktree: false, name: null };
  }
}

async function getLogsDirectory(): Promise<string> {
  const customPath = process.env.BENTO_LOG_PATH?.trim();
  if (customPath) return customPath;

  const defaultBase = join(homedir(), "Library/Logs/Bento");
  const worktreeInfo = detectWorktree();
  if (worktreeInfo.isWorktree && worktreeInfo.name) {
    return join(defaultBase, "worktrees", worktreeInfo.name);
  }

  return defaultBase;
}

async function listLogFiles(logsDir: string): Promise<string[]> {
  try {
    const files = await fs.readdir(logsDir);
    const logFiles = files.filter((f) => f.endsWith(".log"));
    const withStats = await Promise.all(
      logFiles.map(async (file) => {
        try {
          const stat = await fs.stat(join(logsDir, file));
          return { file, mtimeMs: stat.mtimeMs };
        } catch {
          return { file, mtimeMs: 0 };
        }
      })
    );

    return withStats
      .sort((left, right) => right.mtimeMs - left.mtimeMs)
      .map(({ file }) => file);
  } catch {
    return [];
  }
}

async function getLatestLogFile(logsDir: string): Promise<string | undefined> {
  const files = await listLogFiles(logsDir);
  return files[0];
}

function matchesFilters(line: string, filters: SearchFilters): boolean {
  const lowerLine = line.toLowerCase();

  for (const query of filters.queries) {
    if (!lowerLine.includes(query.toLowerCase())) {
      return false;
    }
  }

  for (const subsystem of filters.subsystems) {
    if (!lowerLine.includes(subsystem.toLowerCase())) {
      return false;
    }
  }

  for (const regex of filters.regexes) {
    if (!regex.test(line)) {
      return false;
    }
  }

  return true;
}

async function readMatchingLines(
  filePath: string,
  numLines: number,
  filters: SearchFilters,
  needle?: string
): Promise<string[]> {
  try {
    const content = await fs.readFile(filePath, "utf-8");
    let lines = content.split("\n").filter((line) => line.trim() !== "");

    if (needle) {
      const lowerNeedle = needle.toLowerCase();
      lines = lines.filter((line) => line.toLowerCase().includes(lowerNeedle));
    }

    if (filters.queries.length || filters.regexes.length || filters.subsystems.length) {
      lines = lines.filter((line) => matchesFilters(line, filters));
    }

    return lines.slice(-numLines).reverse();
  } catch (error) {
    console.error(`Error reading log file: ${error}`);
    return [];
  }
}

async function readLastLinesAcrossFiles(
  logsDir: string,
  files: string[],
  numLines: number,
  filters: SearchFilters
): Promise<string[]> {
  const collected: string[] = [];

  for (const file of files) {
    const filePath = join(logsDir, file);
    const lines = await readMatchingLines(filePath, Number.MAX_SAFE_INTEGER, filters);
    for (const line of lines) {
      collected.push(`${file}: ${line}`);
      if (collected.length >= numLines) {
        return collected;
      }
    }
  }

  return collected;
}

async function followLog(
  filePath: string,
  filters: SearchFilters,
  includeTimestamp: boolean
): Promise<void> {
  console.log(`Following: ${filePath}`);
  console.log("Press Ctrl+C to stop\n");

  let lastSize = 0;
  try {
    const stat = await fs.stat(filePath);
    lastSize = stat.size;
  } catch {
    // File might not exist yet
  }

  // Poll for changes every 500ms
  setInterval(async () => {
    try {
      const stat = await fs.stat(filePath);
      if (stat.size > lastSize) {
        const content = await fs.readFile(filePath, "utf-8");
        const newContent = content.slice(lastSize);
        lastSize = stat.size;

        const lines = newContent.split("\n").filter((line) => line.trim() !== "");
        for (const line of lines) {
          if (matchesFilters(line, filters)) {
            const prefix = includeTimestamp ? `[${new Date().toISOString()}] ` : "";
            console.log(`${prefix}${line}`);
          }
        }
      }
    } catch {
      // File might be rotated, try to find new one
    }
  }, 500);
}

async function readRunSlice(
  logsDir: string,
  runId: string,
  filters: SearchFilters
): Promise<string[]> {
  try {
    // Search across the last 5 log files for the run ID
    const files = await listLogFiles(logsDir);
    const filesToCheck = files.slice(0, 5);
    
    for (const file of filesToCheck) {
      const filePath = join(logsDir, file);
      const content = await fs.readFile(filePath, "utf-8");
      const lines = content.split("\n").filter((line) => line.trim() !== "");
      
      // Look for any line containing the run ID to identify if this file contains the run
      // The token format might vary slightly, so checking for the ID itself is robust
      if (content.includes(runId)) {
        console.log(`Found run ID "${runId}" in ${file}`);
        let slice = lines.filter((line) => line.includes(runId));
        if (filters.queries.length || filters.regexes.length || filters.subsystems.length) {
          slice = slice.filter((line) => matchesFilters(line, filters));
        }

        if (slice.length > 0) {
          return slice.reverse();
        }
      }
    }

    return [];
  } catch (error) {
    console.error(`Error searching log files: ${error}`);
    return [];
  }
}

// Parse arguments
const argv = process.argv.slice(2);
let numLines = 100;
let follow = false;
const queries: string[] = [];
const regexSources: string[] = [];
const subsystemFilters: string[] = [];
let listFiles = false;
let includeTimestamp = false;
let runId: string | undefined;
let recentFiles: number | undefined;

for (let i = 0; i < argv.length; i++) {
  const arg = argv[i];

  if (arg === "--help" || arg === "-h") {
    printHelp();
    process.exit(0);
  }

  if (arg === "--lines" || arg === "-l") {
    numLines = parseInt(argv[++i], 10);
    if (isNaN(numLines) || numLines < 1) {
      console.error("Error: --lines must be a positive integer");
      process.exit(1);
    }
    continue;
  }

  if (arg === "--follow" || arg === "-f") {
    follow = true;
    continue;
  }

  if (arg === "--timestamp" || arg === "-t") {
    includeTimestamp = true;
    continue;
  }

  if (arg === "--query" || arg === "-q") {
    const value = argv[++i];
    if (!value) {
      console.error("Error: --query requires a value");
      process.exit(1);
    }
    queries.push(value);
    continue;
  }

  if (arg === "--regex" || arg === "-x") {
    const value = argv[++i];
    if (!value) {
      console.error("Error: --regex requires a value");
      process.exit(1);
    }
    regexSources.push(value);
    continue;
  }

  if (arg === "--subsystem" || arg === "-s") {
    const value = argv[++i];
    if (!value) {
      console.error("Error: --subsystem requires a value");
      process.exit(1);
    }
    subsystemFilters.push(
      ...value
        .split(",")
        .map((token) => token.trim())
        .filter(Boolean)
    );
    continue;
  }

  if (arg === "--run-id") {
    runId = argv[++i];
    if (!runId) {
      console.error("Error: --run-id requires a value");
      process.exit(1);
    }
    continue;
  }

  if (arg === "--recent" || arg === "-r") {
    recentFiles = parseInt(argv[++i], 10);
    if (isNaN(recentFiles) || recentFiles < 1) {
      console.error("Error: --recent must be a positive integer");
      process.exit(1);
    }
    continue;
  }

  if (arg === "--list") {
    listFiles = true;
    continue;
  }
}

// Main
const logsDir = await getLogsDirectory();
const regexes: RegExp[] = [];
for (const source of regexSources) {
  try {
    regexes.push(new RegExp(source, "i"));
  } catch (error) {
    console.error(`Error: invalid regex "${source}": ${error}`);
    process.exit(1);
  }
}

const filters: SearchFilters = {
  queries,
  regexes,
  subsystems: subsystemFilters
};
const hasSearchFilters = queries.length > 0 || regexes.length > 0 || subsystemFilters.length > 0;
const effectiveRecentFiles = recentFiles ?? (hasSearchFilters ? 3 : 1);

if (listFiles) {
  const files = await listLogFiles(logsDir);
  if (files.length === 0) {
    console.log(`No log files found in ${logsDir}`);
  } else {
    console.log(`Log files in ${logsDir}:\n`);
    for (const file of files) {
      const stat = await fs.stat(join(logsDir, file));
      const size = (stat.size / 1024).toFixed(1);
      const mtime = new Date(stat.mtimeMs).toLocaleString();
      console.log(`  ${file} (${size} KB, ${mtime})`);
    }
  }
  process.exit(0);
}

const latestFile = await getLatestLogFile(logsDir);
if (!latestFile) {
  console.error(`No log files found in ${logsDir}`);
  console.error("Make sure the DeskJig app has been run at least once.");
  process.exit(1);
}

const logPath = join(logsDir, latestFile);
if (hasSearchFilters && effectiveRecentFiles > 1) {
  console.log(`Searching ${Math.min(effectiveRecentFiles, (await listLogFiles(logsDir)).length)} recent log files in ${logsDir}\n`);
} else {
  console.log(`Log file: ${logPath}\n`);
}

if (follow) {
  if (runId) {
    console.error("Error: --run-id cannot be used with --follow");
    process.exit(1);
  }
  await followLog(logPath, filters, includeTimestamp);
} else {
  const candidateFiles = hasSearchFilters && effectiveRecentFiles > 1
    ? (await listLogFiles(logsDir)).slice(0, effectiveRecentFiles)
    : [latestFile];
  const lines = runId
    ? await readRunSlice(logsDir, runId, filters)
    : await readLastLinesAcrossFiles(logsDir, candidateFiles, numLines, filters);
  if (lines.length === 0) {
    if (runId) {
      console.log(`No lines matching run id "${runId}"`);
    } else {
      const descriptions: string[] = [];
      if (queries.length > 0) descriptions.push(queries.map((q) => `"${q}"`).join(", "));
      if (regexSources.length > 0) descriptions.push(regexSources.map((r) => `/${r}/i`).join(", "));
      if (subsystemFilters.length > 0) descriptions.push(`subsystem=${subsystemFilters.join(",")}`);
      console.log(descriptions.length > 0 ? `No lines matching ${descriptions.join(" + ")}` : "No log entries found");
    }
  } else {
    for (const line of lines) {
      const prefix = includeTimestamp ? `[${new Date().toISOString()}] ` : "";
      console.log(`${prefix}${line}`);
    }
  }
}
