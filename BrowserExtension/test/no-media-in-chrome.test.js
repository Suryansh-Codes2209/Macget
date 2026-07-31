// The guarantee this whole restructure exists to provide: the Chrome package
// contains no media-extraction code.
//
// The Chrome Web Store rejected v1.2 under the Prohibited Products policy for
// facilitating downloads of copyrighted media from YouTube. The remedy was to
// move every media path into media/, which is packaged for Firefox only. This
// test is what stops that from silently regressing — a stray `cp` in build.sh,
// or a well-meaning refactor that moves a helper back into shared/, fails here
// rather than in a review three weeks later.
//
// Runs against the ASSEMBLED output, not the sources, because the assembled
// output is what gets uploaded.

"use strict";

const test = require("node:test");
const assert = require("node:assert");
const fs = require("node:fs");
const path = require("node:path");

const BUILD_DIR = path.join(__dirname, "..", "build", "chromium");

// Patterns are deliberately specific. A bare /media/ would match the `@media`
// CSS queries in theme.css and the options page, and a guard that cries wolf
// gets disabled — which would be worse than not having one.
const FORBIDDEN = [
  { re: /\.m3u8/i, what: "HLS manifest extension" },
  { re: /\.mpd\b/i, what: "DASH manifest extension" },
  { re: /manifestURLs/, what: "sniffed-manifest payload field" },
  { re: /yt-dlp/i, what: "external media extractor" },
  { re: /extractor/i, what: "external media extractor" },
  { re: /\bwebRequest\b/, what: "webRequest permission or listener" },
  { re: /macget-media/, what: "media capture message/menu id" },
  { re: /macget-video-prefs/, what: "video overlay prefs message" },
  { re: /macget-page/, what: "send-page-video menu id" },
  { re: /sendVideo/, what: "popup Send video action" },
  { re: /showVideoButton/, what: "video overlay setting" },
  { re: /videoButtonCorner/, what: "video overlay setting" },
  { re: /videoButtonHiddenHosts/, what: "video overlay setting" },
  { re: /["']media["']/, what: 'a "media" capture kind' },
];

const TEXT_EXT = new Set([".js", ".json", ".html", ".css", ".txt", ".md"]);

function walk(dir) {
  const out = [];
  for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
    const full = path.join(dir, entry.name);
    if (entry.isDirectory()) out.push(...walk(full));
    else if (TEXT_EXT.has(path.extname(entry.name))) out.push(full);
  }
  return out;
}

test("the assembled Chrome package exists", () => {
  assert.ok(
    fs.existsSync(BUILD_DIR),
    `${BUILD_DIR} not found — run ./build.sh, which assembles it before running this test`
  );
});

test("the Chrome package contains no media-extraction code", () => {
  const files = walk(BUILD_DIR);
  assert.ok(files.length > 0, "no text files found in the Chrome package");

  const hits = [];
  for (const file of files) {
    const lines = fs.readFileSync(file, "utf8").split("\n");
    lines.forEach((line, i) => {
      for (const { re, what } of FORBIDDEN) {
        if (re.test(line)) {
          hits.push(`${path.relative(BUILD_DIR, file)}:${i + 1} — ${what}: ${line.trim()}`);
        }
      }
    });
  }

  assert.deepStrictEqual(
    hits,
    [],
    `media code reached the Chrome package:\n  ${hits.join("\n  ")}\n\n` +
      "This package cannot be uploaded to the Chrome Web Store. Move the offending " +
      "code into media/, which is packaged for Firefox only."
  );
});

test("the Chrome manifest does not request webRequest", () => {
  const manifest = JSON.parse(
    fs.readFileSync(path.join(BUILD_DIR, "manifest.json"), "utf8")
  );
  assert.ok(
    !(manifest.permissions || []).includes("webRequest"),
    "webRequest is what made stream sniffing possible; it must stay out of the Chrome build"
  );
});

test("the Chrome content script is the gesture reporter alone", () => {
  const manifest = JSON.parse(
    fs.readFileSync(path.join(BUILD_DIR, "manifest.json"), "utf8")
  );
  const scripts = (manifest.content_scripts || []).flatMap((entry) => entry.js || []);
  assert.deepStrictEqual(
    scripts,
    ["content.js"],
    "the Chrome build must inject no content script other than the gesture reporter"
  );
});
