#!/bin/sh
# Assembles the per-browser extension directories and zips them for distribution.
#
# Everything except manifest.json lives in chromium/ as the single source of
# truth. This script copies it into firefox/ so the two stay in sync, then
# produces loadable/zippable folders. Only the manifest.json differs between
# browsers (Chrome takes a single service_worker; Firefox takes a scripts array,
# which is how heuristics.js gets loaded there).
set -e
cd "$(dirname "$0")"

# The pure logic has tests; don't package a build that fails them.
if command -v node >/dev/null 2>&1; then
  echo "Running heuristics tests ..."
  node --test "test/*.test.js" >/dev/null
else
  echo "node not found — skipping tests"
fi

SHARED="heuristics.js background.js content.js popup.html popup.js options.html options.js theme.css"

echo "Syncing shared files into firefox/ ..."
for f in $SHARED; do
  cp "chromium/$f" "firefox/$f"
done
rm -rf firefox/icons
cp -R chromium/icons firefox/icons

mkdir -p dist
DIST="$(pwd)/dist"

# The Chrome Web Store REJECTS a manifest that contains a `key` field — it only
# pins the unpacked dev ID. Strip it from the store package (chromium/ keeps it
# so local "Load unpacked" still resolves to the same dev ID for native messaging).
echo "Packaging chromium -> dist/macget-chromium.zip (key field stripped for the Web Store)"
STORE_TMP="$(mktemp -d)"
cp -R chromium/. "$STORE_TMP/"
sed '/^[[:space:]]*"key"[[:space:]]*:/d' chromium/manifest.json > "$STORE_TMP/manifest.json"
( cd "$STORE_TMP" && zip -q -r -FS "$DIST/macget-chromium.zip" . -x ".*" )
rm -rf "$STORE_TMP"

echo "Packaging firefox -> dist/macget-firefox.zip"
( cd firefox && zip -q -r -FS "$DIST/macget-firefox.zip" . -x ".*" )

echo "Done. Upload dist/macget-chromium.zip to the Web Store; load unpacked from chromium/ for dev."
