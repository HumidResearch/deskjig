#!/usr/bin/env bun
// appcast.ts
// DeskJig
//
// Builds the Sparkle appcast for a release by prepending one <item> to the
// previously published feed.
//
// Sparkle ships a `generate_appcast` tool, but it wants a directory holding
// *every* update archive ever shipped so it can regenerate the whole feed (and
// compute delta updates). DeskJig's archives live as GitHub Release assets, not
// in one directory, so this script does the one thing that is actually needed:
// take the already-signed DMG's signature and length, wrap them in an <item>,
// and merge that into the feed fetched from the previous release.
//
// Everything in the feed was written by this script, so the previous feed is
// parsed with a narrow regex rather than a full XML dependency.
//
// USAGE:
//   bun run scripts/appcast.ts \
//     --short-version 1.0.0 --build 1 \
//     --url https://github.com/HumidResearch/deskjig/releases/download/v1.0.0/DeskJig-1.0.0.dmg \
//     --signature "<edSignature>" --length 12345678 \
//     [--minimum-system-version 14.0] \
//     [--release-notes-file release_notes/v1.0.0.md] \
//     [--previous appcast-previous.xml] \
//     --output appcast.xml

import { existsSync, readFileSync, writeFileSync } from "node:fs";

const FEED_TITLE = "DeskJig";
const FEED_LINK = "https://github.com/HumidResearch/deskjig/releases/latest/download/appcast.xml";
const FEED_DESCRIPTION = "Updates for DeskJig, the macOS workspace manager.";
const SPARKLE_NS = "http://www.andymatuschak.org/xml-namespaces/sparkle";

const USAGE = `
Builds the Sparkle appcast for a release.

USAGE:
  bun run scripts/appcast.ts --short-version <x.y.z> --build <n> --url <dmg-url>
                             --signature <edSignature> --length <bytes>
                             --output <path> [OPTIONS]

OPTIONS:
  --minimum-system-version <x.y>  macOS floor for the item (default 14.0)
  --release-notes-file <path>     Markdown used as the item <description>
  --previous <path>               Previously published appcast.xml to merge in

PRECHECK MODE:
  bun run scripts/appcast.ts --precheck --short-version <x.y.z> --build <n>
                             [--previous <path>]
  Runs only the monotonic build-number gate (no feed is written). Exits
  non-zero if <n> is not greater than every other published item's build.
`;

interface Options {
  shortVersion: string;
  build: string;
  url: string;
  signature: string;
  length: string;
  minimumSystemVersion: string;
  releaseNotesFile?: string;
  previous?: string;
  output: string;
}

function fail(message: string): never {
  console.error(`appcast: ${message}`);
  process.exit(1);
}

/**
 * Shared `--flag value` scanner. Rejects flags outside `known`: a silently
 * swallowed typo (`--previou …`) would make the precheck pass vacuously or
 * make generation drop the previous feed — both are exactly the failures this
 * script exists to prevent.
 */
function collectFlagValues(argv: string[], known: ReadonlySet<string>): Map<string, string> {
  const values = new Map<string, string>();
  for (let i = 0; i < argv.length; i++) {
    const arg = argv[i]!;
    if (arg === "--help" || arg === "-h") {
      console.log(USAGE);
      process.exit(0);
    }
    if (!arg.startsWith("--")) fail(`unexpected argument: ${arg}`);
    const name = arg.slice(2);
    if (!known.has(name)) fail(`unknown option: ${arg}`);
    const next = argv[i + 1];
    if (next === undefined) fail(`${arg} requires a value`);
    values.set(name, next);
    i++;
  }
  return values;
}

function requireInteger(name: string, value: string): string {
  if (!/^\d+$/.test(value)) {
    fail(`--${name} must be a plain integer${name === "build" ? " (CFBundleVersion)" : ""}, got "${value}"`);
  }
  return value;
}

const GENERATE_FLAGS: ReadonlySet<string> = new Set([
  "short-version",
  "build",
  "url",
  "signature",
  "length",
  "minimum-system-version",
  "release-notes-file",
  "previous",
  "output",
]);

const PRECHECK_FLAGS: ReadonlySet<string> = new Set(["short-version", "build", "previous"]);

function parseArgs(argv: string[]): Options {
  const values = collectFlagValues(argv, GENERATE_FLAGS);

  const required = (name: string): string => {
    const value = values.get(name);
    if (value === undefined || value.trim() === "") fail(`--${name} is required`);
    return value.trim();
  };

  const build = requireInteger("build", required("build"));
  const length = requireInteger("length", required("length"));

  return {
    shortVersion: required("short-version"),
    build,
    url: required("url"),
    signature: required("signature"),
    length,
    minimumSystemVersion: values.get("minimum-system-version")?.trim() || "14.0",
    releaseNotesFile: values.get("release-notes-file")?.trim() || undefined,
    previous: values.get("previous")?.trim() || undefined,
    output: required("output"),
  };
}

/** Minimal XML text escaping — the values here are versions, URLs and signatures. */
function escapeXML(value: string): string {
  return value
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;");
}

/**
 * Splits a previously published feed into its <item> blocks.
 *
 * Returns an empty list for an absent or unparseable feed: the first release has
 * no predecessor, and a feed we cannot read is better replaced than merged into.
 */
function previousItems(xml: string | undefined): string[] {
  if (!xml) return [];
  const matches = xml.match(/[ \t]*<item>[\s\S]*?<\/item>/g);
  return matches ?? [];
}

function buildNumberOf(item: string): number | undefined {
  const element = item.match(/<sparkle:version>\s*(\d+)\s*<\/sparkle:version>/);
  if (element) return Number(element[1]);
  const attribute = item.match(/sparkle:version="(\d+)"/);
  if (attribute) return Number(attribute[1]);
  return undefined;
}

function shortVersionOf(item: string): string | undefined {
  const element = item.match(/<sparkle:shortVersionString>\s*([^<]+?)\s*<\/sparkle:shortVersionString>/);
  if (element) return element[1];
  const attribute = item.match(/sparkle:shortVersionString="([^"]+)"/);
  return attribute?.[1];
}

/**
 * Release notes become the item <description>. Markdown is passed through inside
 * CDATA: Sparkle renders the description as HTML, so plain prose reads fine and
 * anything richer is the maintainer's choice in release_notes/.
 */
function descriptionFor(options: Options): string {
  if (options.releaseNotesFile && existsSync(options.releaseNotesFile)) {
    const notes = readFileSync(options.releaseNotesFile, "utf8").trim();
    if (notes) {
      // A literal "]]>" would close the CDATA section early.
      return notes.replace(/]]>/g, "]]&gt;");
    }
  }
  return `DeskJig ${options.shortVersion}. See https://github.com/HumidResearch/deskjig/releases/tag/v${options.shortVersion} for details.`;
}

function renderItem(options: Options, pubDate: string): string {
  return [
    "    <item>",
    `      <title>${escapeXML(options.shortVersion)}</title>`,
    `      <pubDate>${pubDate}</pubDate>`,
    `      <sparkle:version>${escapeXML(options.build)}</sparkle:version>`,
    `      <sparkle:shortVersionString>${escapeXML(options.shortVersion)}</sparkle:shortVersionString>`,
    `      <sparkle:minimumSystemVersion>${escapeXML(options.minimumSystemVersion)}</sparkle:minimumSystemVersion>`,
    `      <link>https://github.com/HumidResearch/deskjig/releases/tag/v${escapeXML(options.shortVersion)}</link>`,
    `      <description><![CDATA[${descriptionFor(options)}]]></description>`,
    "      <enclosure",
    `        url="${escapeXML(options.url)}"`,
    `        sparkle:edSignature="${escapeXML(options.signature)}"`,
    `        length="${escapeXML(options.length)}"`,
    '        type="application/octet-stream"/>',
    "    </item>",
  ].join("\n");
}

/**
 * Splits the previous feed into the items to carry forward (everything except a
 * prior item for this same version — re-running a release replaces its own item
 * rather than duplicating it) and the highest build number among them.
 */
function mergePrevious(
  previousXML: string | undefined,
  shortVersion: string,
): { kept: string[]; highestPublishedBuild: number } {
  const kept: string[] = [];
  let highestPublishedBuild = 0;
  for (const item of previousItems(previousXML)) {
    if (shortVersionOf(item) === shortVersion) continue;
    const itemBuild = buildNumberOf(item);
    if (itemBuild !== undefined) highestPublishedBuild = Math.max(highestPublishedBuild, itemBuild);
    kept.push(item);
  }
  return { kept, highestPublishedBuild };
}

/**
 * The single most common way to ship a release that silently never installs:
 * CFBundleVersion did not move, so Sparkle sees the new build as "not newer".
 * Catch it here, where the fix is a one-line edit to Version.xcconfig.
 */
function assertBuildIsNewer(newBuild: number, highestPublishedBuild: number): void {
  if (highestPublishedBuild > 0 && newBuild <= highestPublishedBuild) {
    fail(
      `build number ${newBuild} is not greater than the highest already published (${highestPublishedBuild}). ` +
        "Sparkle compares CFBundleVersion, so this release could never install over the previous one. " +
        "Bump CURRENT_PROJECT_VERSION in Version.xcconfig and re-tag.",
    );
  }
}

/**
 * `--precheck` mode: run only the monotonic build-number gate, before anything
 * is built. The release workflow calls this in its gates phase so a stale
 * CURRENT_PROJECT_VERSION fails in seconds instead of after two notarizations
 * (the full check still runs again at generation time).
 */
function precheckMain(argv: string[]): void {
  const values = collectFlagValues(argv, PRECHECK_FLAGS);

  const shortVersion = values.get("short-version")?.trim();
  const build = values.get("build")?.trim();
  if (!shortVersion || !build) fail("--precheck requires --short-version and --build");
  requireInteger("build", build);
  const previous = values.get("previous")?.trim();

  const previousXML = previous && existsSync(previous) ? readFileSync(previous, "utf8") : undefined;
  const { highestPublishedBuild } = mergePrevious(previousXML, shortVersion);
  assertBuildIsNewer(Number(build), highestPublishedBuild);
  console.log(
    `appcast: precheck OK — build ${build} > highest published build (${highestPublishedBuild || "none yet"})`,
  );
}

function main(): void {
  const options = parseArgs(process.argv.slice(2));

  const previousXML = options.previous && existsSync(options.previous)
    ? readFileSync(options.previous, "utf8")
    : undefined;

  const { kept, highestPublishedBuild } = mergePrevious(previousXML, options.shortVersion);
  assertBuildIsNewer(Number(options.build), highestPublishedBuild);

  const pubDate = new Date().toUTCString();
  const items = [renderItem(options, pubDate), ...kept];

  const feed = [
    '<?xml version="1.0" encoding="utf-8"?>',
    `<rss version="2.0" xmlns:sparkle="${SPARKLE_NS}">`,
    "  <channel>",
    `    <title>${FEED_TITLE}</title>`,
    `    <link>${FEED_LINK}</link>`,
    `    <description>${FEED_DESCRIPTION}</description>`,
    "    <language>en</language>",
    ...items,
    "  </channel>",
    "</rss>",
    "",
  ].join("\n");

  writeFileSync(options.output, feed, "utf8");
  console.log(
    `appcast: wrote ${options.output} — ${options.shortVersion} (build ${options.build}) + ${kept.length} previous item(s)`,
  );
}

const rawArgv = process.argv.slice(2);
if (rawArgv.includes("--precheck")) {
  precheckMain(rawArgv.filter((arg) => arg !== "--precheck"));
} else {
  main();
}
