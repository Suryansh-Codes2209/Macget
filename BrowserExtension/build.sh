#!/bin/sh
# Assembles the per-browser extension directories and zips them for distribution.
#
# The shared logic (background.js, options.html, options.js) lives in chromium/
# as the single source of truth. This script copies it into firefox/ so the two
# stay in sync, then produces loadable/zippable folders. Only the manifest.json
# differs between browsers.
set -e
cd "$(dirname "$0")"

SHARED="background.js content.js options.html options.js"

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
