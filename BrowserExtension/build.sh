#!/bin/sh
# Assembles the per-browser extension directories and zips them for distribution.
#
# The shared logic (background.js, options.html, options.js) lives in chromium/
# as the single source of truth. This script copies it into firefox/ so the two
# stay in sync, then produces loadable/zippable folders. Only the manifest.json
# differs between browsers.
set -e
cd "$(dirname "$0")"

SHARED="background.js options.html options.js"

echo "Syncing shared files into firefox/ ..."
for f in $SHARED; do
  cp "chromium/$f" "firefox/$f"
done
rm -rf firefox/icons
cp -R chromium/icons firefox/icons

mkdir -p dist
echo "Packaging chromium -> dist/macget-chromium.zip"
( cd chromium && zip -q -r -FS "../dist/macget-chromium.zip" . -x ".*" )

echo "Packaging firefox -> dist/macget-firefox.zip"
( cd firefox && zip -q -r -FS "../dist/macget-firefox.zip" . -x ".*" )

echo "Done. Load unpacked from chromium/ or firefox/, or distribute dist/*.zip."
