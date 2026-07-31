#!/bin/sh
# Assembles the per-browser extension packages.
#
#   shared/   media-free core. Ships to every browser.
#   media/    video overlay + extraction. FIREFOX ONLY — never copied to Chrome.
#   targets/  the one file that genuinely differs per browser: manifest.json.
#
# Output:
#   build/chromium/   loadable unpacked (keeps the `key`, so the dev ID is stable)
#   build/firefox/    loadable unpacked
#   dist/*.zip        packages for the stores
#
# The Chrome package must contain NO media-extraction code. That is enforced by
# test/no-media-in-chrome.test.js, which runs against the assembled output below
# and fails the build on any hit — not by anyone remembering to check.
# See docs/superpowers/specs/2026-07-31-chrome-safe-extension-split-design.md.
set -e
cd "$(dirname "$0")"

if ! command -v node >/dev/null 2>&1; then
  echo "error: node is required (the build guard runs under node --test)" >&2
  exit 1
fi

echo "Running logic tests ..."
node --test test/heuristics.test.js >/dev/null

# ---- assemble ---------------------------------------------------------------

# Replace the <!--MEDIA-SECTION--> marker line: with a fragment's contents when
# one is given, with nothing when it is not.
#
# Note the direction — this INSERTS into a media-free base rather than CUTTING
# from a full one. If the substitution ever breaks, Chrome stays clean and
# Firefox loses a UI section. The failure mode points the safe way.
splice() { # splice <src> <fragment|""> <dest>
  awk -v frag="$2" '
    /<!--MEDIA-SECTION-->/ {
      if (frag != "") { while ((getline line < frag) > 0) print line; close(frag) }
      next
    }
    { print }
  ' "$1" > "$3"
}

CORE_JS="heuristics.js background.js content.js popup.js options.js theme.css"

rm -rf build
mkdir -p build/chromium build/firefox dist
DIST="$(pwd)/dist"

echo "Assembling build/chromium (media-free) ..."
for f in $CORE_JS; do cp "shared/$f" "build/chromium/$f"; done
cp -R shared/icons build/chromium/icons
cp targets/chromium/manifest.json build/chromium/manifest.json
splice shared/popup.html   "" build/chromium/popup.html
splice shared/options.html "" build/chromium/options.html

echo "Assembling build/firefox (full) ..."
for f in $CORE_JS; do cp "shared/$f" "build/firefox/$f"; done
cp -R shared/icons build/firefox/icons
cp targets/firefox/manifest.json build/firefox/manifest.json
cp media/media.js media/content-video.js media/media-ui.js build/firefox/
splice shared/popup.html   media/popup-media.html   build/firefox/popup.html
splice shared/options.html media/options-media.html build/firefox/options.html

# ---- verify -----------------------------------------------------------------

echo "Verifying the Chrome package contains no media code ..."
node --test test/no-media-in-chrome.test.js >/dev/null

# ---- package ----------------------------------------------------------------

# The Chrome Web Store REJECTS a manifest containing a `key` field — it only
# pins the unpacked dev ID. Strip it from the store zip; build/chromium/ keeps
# it so "Load unpacked" still resolves to the same ID for native messaging.
echo "Packaging dist/macget-chromium.zip (key field stripped for the Web Store) ..."
STORE_TMP="$(mktemp -d)"
cp -R build/chromium/. "$STORE_TMP/"
sed '/^[[:space:]]*"key"[[:space:]]*:/d' build/chromium/manifest.json > "$STORE_TMP/manifest.json"
( cd "$STORE_TMP" && zip -q -r -FS "$DIST/macget-chromium.zip" . -x ".*" )
rm -rf "$STORE_TMP"

echo "Packaging dist/macget-firefox.zip ..."
( cd build/firefox && zip -q -r -FS "$DIST/macget-firefox.zip" . -x ".*" )

echo
echo "Done."
echo "  Chrome dev : load unpacked from build/chromium/"
echo "  Firefox dev: load temporary add-on from build/firefox/manifest.json"
echo "  Store zips : dist/"
