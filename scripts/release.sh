#!/usr/bin/env bash
# Macget release script.
#
# One-time setup:
#   1. Enroll in the Apple Developer Program ($99/yr).
#   2. Install a "Developer ID Application" certificate in Keychain.
#   3. xcrun notarytool store-credentials "macget-notary" \
#         --apple-id "you@example.com" \
#         --team-id "YOUR-TEAM-ID" \
#         --password "<app-specific-password-from-appleid.apple.com>"
#   4. brew install create-dmg
#   5. Add the Sparkle SPM dependency in Xcode and run `bin/generate_keys`.
#      Copy the printed public key into Info.plist's SUPublicEDKey.
#      Back up the printed private key OFFLINE.
#
# Per release:
#   - Bump version in Xcode (Marketing Version + Current Project Version).
#   - Update CHANGELOG.md.
#   - Run this script from the repo root: ./scripts/release.sh
#
# No Apple Developer account? Run `./scripts/release.sh --no-notarize` for a free,
# ad-hoc-signed DMG (skips the Developer ID + notarization steps above). Sparkle
# auto-updates still work; users do a one-time Gatekeeper "Open Anyway" on install.
#   - Upload the DMG in dist/ to the GitHub Release.
#   - Run `Sparkle/bin/generate_appcast site/` to update the appcast.
#   - Push site/ to GitHub Pages.
set -euo pipefail

# ---- configurable ----
SCHEME="Macget"
PROJECT="Macget.xcodeproj"
NOTARY_PROFILE="macget-notary"
DIST_DIR="dist"
# ----------------------

# `--no-notarize` builds a free, ad-hoc-signed DMG without an Apple Developer
# account. Sparkle auto-updates still work (their EdDSA signing is independent of
# Apple), but users will hit a Gatekeeper warning on first launch — see the
# "First launch on macOS" section in README.md for the Open-Anyway steps.
NOTARIZE=1
for arg in "$@"; do
  case "$arg" in
    --no-notarize) NOTARIZE=0 ;;
    *) echo "Unknown argument: $arg"; exit 1 ;;
  esac
done

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

if [[ ! -d "$PROJECT" ]]; then
  echo "ERROR: $PROJECT not found in $ROOT."
  exit 1
fi

# Pre-flight: tests must pass before we ship.
echo "==> Running unit tests…"
xcodebuild test \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -destination 'platform=macOS' \
  -only-testing:MacgetTests \
  -quiet

mkdir -p "$DIST_DIR"
rm -rf "$DIST_DIR"/*

# Fetch the media tools so the "Embed Media Tools" build phase bundles them into
# the .app (yt-dlp + ffmpeg + ffprobe → Contents/Resources/bin), making "Download
# videos" work from the DMG with no `brew install`.
echo "==> Fetching media tools (yt-dlp + ffmpeg) to bundle…"
sh "${ROOT}/scripts/fetch-media-tools.sh"

echo "==> Building Release with Xcode…"
BUILD_DIR="$(mktemp -d)"
# In free mode, force ad-hoc signing so the build doesn't require a Developer ID cert.
SIGN_ARGS=()
if [[ "$NOTARIZE" == "0" ]]; then
  SIGN_ARGS=(CODE_SIGN_IDENTITY="-" CODE_SIGN_STYLE=Manual CODE_SIGNING_REQUIRED=NO)
fi
xcodebuild \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -configuration Release \
  -derivedDataPath "$BUILD_DIR" \
  "${SIGN_ARGS[@]}" \
  clean build

APP_BUILD_PATH="$BUILD_DIR/Build/Products/Release/${SCHEME}.app"
if [[ ! -d "$APP_BUILD_PATH" ]]; then
  echo "ERROR: Built .app not found at $APP_BUILD_PATH"
  exit 1
fi

echo "==> Verifying code signature…"
if [[ "$NOTARIZE" == "1" ]]; then
  codesign --verify --deep --strict --verbose=2 "$APP_BUILD_PATH"
else
  # Ad-hoc signatures are valid but not Developer-ID; don't fail the build over it.
  codesign --verify --deep --verbose=2 "$APP_BUILD_PATH" || \
    echo "   (ad-hoc signature — expected without an Apple Developer ID)"
fi

echo "==> Building DMG…"
if ! command -v create-dmg >/dev/null; then
  echo "ERROR: create-dmg not installed. Run: brew install create-dmg"
  exit 1
fi
( cd "$DIST_DIR" && create-dmg "$APP_BUILD_PATH" . )

DMG_PATH="$(ls "$DIST_DIR"/*.dmg | head -n1)"
echo "==> Built DMG: $DMG_PATH"

if [[ "$NOTARIZE" == "1" ]]; then
  echo "==> Submitting to Apple for notarization (this may take 1-10 minutes)…"
  xcrun notarytool submit "$DMG_PATH" --keychain-profile "$NOTARY_PROFILE" --wait

  echo "==> Stapling notarization ticket…"
  xcrun stapler staple "$DMG_PATH"

  echo "==> Verifying Gatekeeper acceptance…"
  spctl -a -t open --context context:primary-signature -v "$DMG_PATH"
  xcrun stapler validate "$DMG_PATH"
else
  echo "==> Skipping notarization (free mode). DMG is ad-hoc signed only."
  echo "    Gatekeeper will warn on first launch; ship the README 'First launch on"
  echo "    macOS' steps with your download link."
fi

echo "==> SHA-256 of DMG:"
shasum -a 256 "$DMG_PATH"

echo "==> Done."
echo "Next steps:"
echo "  1. Create a GitHub Release and upload $DMG_PATH"
echo "  2. Run: Sparkle/bin/generate_appcast site/   (regenerates appcast.xml + signs DMGs)"
echo "  3. git -C site add appcast.xml && git -C site commit -m 'release' && git -C site push"
