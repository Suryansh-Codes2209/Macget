#!/bin/sh
# Fetches the media tools (yt-dlp + ffmpeg + ffprobe) the "Download videos"
# feature shells out to, into Vendor/bin/. The "Embed Media Tools" Xcode build
# phase then copies + codesigns them into Macget.app/Contents/Resources/bin so
# they ride along in the DMG — no `brew install` needed by end users.
#
# Universal (arm64 + x86_64) binaries are produced via `lipo` so one DMG runs on
# both Apple Silicon and Intel. Binaries are NOT committed (see .gitignore); run
# this once before building a release (release.sh does it automatically).
set -e
cd "$(dirname "$0")/.."
BIN="Vendor/bin"
mkdir -p "$BIN"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# Pinned versions — bump intentionally.
YTDLP_VERSION="2026.06.09"
FFMPEG_TAG="b6.1.1"
FF_BASE="https://github.com/eugeneware/ffmpeg-static/releases/download/${FFMPEG_TAG}"

echo "==> yt-dlp ${YTDLP_VERSION} (universal)…"
curl -L --fail --retry 3 -o "$BIN/yt-dlp" \
  "https://github.com/yt-dlp/yt-dlp/releases/download/${YTDLP_VERSION}/yt-dlp_macos"

# Download both arches of a tool and lipo them into a universal binary.
fetch_universal() {
  tool="$1"   # ffmpeg | ffprobe
  echo "==> ${tool} (${FFMPEG_TAG}, arm64+x86_64 → universal)…"
  curl -L --fail --retry 3 -o "$TMP/${tool}-arm64" "${FF_BASE}/${tool}-darwin-arm64"
  curl -L --fail --retry 3 -o "$TMP/${tool}-x64"   "${FF_BASE}/${tool}-darwin-x64"
  lipo -create "$TMP/${tool}-arm64" "$TMP/${tool}-x64" -output "$BIN/${tool}"
}

fetch_universal ffmpeg
fetch_universal ffprobe

chmod +x "$BIN/yt-dlp" "$BIN/ffmpeg" "$BIN/ffprobe"

echo
echo "Fetched into $BIN:"
for f in yt-dlp ffmpeg ffprobe; do
  printf "  %-8s %s\n" "$f" "$(lipo -archs "$BIN/$f" 2>/dev/null || echo 'universal n/a') $(du -h "$BIN/$f" | cut -f1)"
done
echo "Done. Build the app (or run scripts/release.sh) to embed them."
