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
#   - Create a GitHub Release and upload dist/macget.dmg as an asset named
#     exactly "macget.dmg" (the Sparkle appcast enclosure URL and the Homebrew
#     cask both depend on that exact name).
#   - Run `./scripts/publish-cask.sh` to push the Homebrew cask to the tap.
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

# xcodebuild needs a full Xcode, not Command Line Tools. Auto-point at Xcode.app
# if the active developer dir is CLT.
if ! xcodebuild -version >/dev/null 2>&1; then
  if [[ -d "/Applications/Xcode.app/Contents/Developer" ]]; then
    export DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"
  fi
fi
if ! xcodebuild -version >/dev/null 2>&1; then
  echo "ERROR: xcodebuild requires full Xcode. Either:"
  echo "  sudo xcode-select -s /Applications/Xcode.app/Contents/Developer   (permanent)"
  echo "  or run: DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer $0 $*"
  exit 1
fi

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
#
# Expanded below as `${SIGN_ARGS[@]+"${SIGN_ARGS[@]}"}`, not `"${SIGN_ARGS[@]}"`.
# macOS ships bash 3.2, where expanding an *empty* array under `set -u` is an
# "unbound variable" error — so the plain form aborts the notarized path (the
# only path that leaves this array empty) before xcodebuild ever runs. Bash 4.4+
# fixed that, which is why it looks fine everywhere but the machine that matters.
SIGN_ARGS=()
if [[ "$NOTARIZE" == "0" ]]; then
  SIGN_ARGS=(CODE_SIGN_IDENTITY="-" CODE_SIGN_STYLE=Manual CODE_SIGNING_REQUIRED=NO)
fi
xcodebuild \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -configuration Release \
  -derivedDataPath "$BUILD_DIR" \
  ${SIGN_ARGS[@]+"${SIGN_ARGS[@]}"} \
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
# Use hdiutil (built into macOS) — no extra dependency, and unambiguous CLI.
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP_BUILD_PATH/Contents/Info.plist" 2>/dev/null || echo "0.0.0")"
DMG_PATH="$DIST_DIR/Macget-$VERSION.dmg"
STAGE="$(mktemp -d)"
cp -R "$APP_BUILD_PATH" "$STAGE/"
ln -s /Applications "$STAGE/Applications"   # drag-to-install target
rm -f "$DMG_PATH"
hdiutil create -volname "Macget" -srcfolder "$STAGE" -ov -format UDZO "$DMG_PATH"
rm -rf "$STAGE"
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

# The GitHub Release asset must be named exactly "macget.dmg" (see the header
# comment), but gh/the GitHub web UI both use the uploaded file's own basename —
# neither can rename on upload. So produce that exact file here rather than
# leaving the copy as an unwritten manual step. Keep the versioned filename too:
# publish-cask.sh's error messages reference it, and it's a useful local archive
# name. Copy happens after notarization/stapling (stapling rewrites the DMG's
# bytes), so the canonical copy and the SHA below describe the same content.
CANONICAL_DMG="$DIST_DIR/macget.dmg"
cp "$DMG_PATH" "$CANONICAL_DMG"
echo "==> Copied to $CANONICAL_DMG (the exact name to upload as a release asset)"

# Hash the canonical file — the one that actually gets uploaded — so the SHA
# in the rendered cask is verifiably describing dist/macget.dmg, not just
# incidentally identical to it.
DMG_SHA="$(shasum -a 256 "$CANONICAL_DMG" | awk '{print $1}')"
echo "==> SHA-256 of DMG: $DMG_SHA"

echo "==> Rendering Homebrew cask…"
CASK_OUT="$DIST_DIR/macget.rb"
sed -e "s/__VERSION__/$VERSION/g" -e "s/__SHA256__/$DMG_SHA/g" \
  "$ROOT/scripts/macget.cask.tmpl" > "$CASK_OUT"
echo "    Wrote $CASK_OUT"

echo "==> Done."
echo
echo "Next: create a GitHub Release for v$VERSION and upload"
echo "      ${CANONICAL_DMG}"
echo "      as an asset named exactly 'macget.dmg' (the Sparkle appcast enclosure"
echo "      URL and the Homebrew cask both depend on that name)."
echo
# `publish-cask.sh` uses a distinct exit code (2) for "no release yet" — the
# expected state right after this script runs — versus 1 for an actual publish
# failure (checksum mismatch, dirty tap, etc.), which needs different advice.
# `|| PUBLISH_STATUS=$?` is what lets us keep going: under `set -e`, letting
# the command fail on its own would abort the script right here, before we
# get a chance to branch on which failure it was. Assigning inside the `||`
# only runs when the command fails, and reading `$?` at that point still
# reports its real exit code, not the assignment's.
PUBLISH_STATUS=0
./scripts/publish-cask.sh || PUBLISH_STATUS=$?
if [[ "$PUBLISH_STATUS" == "0" ]]; then
  echo "==> Homebrew cask published."
elif [[ "$PUBLISH_STATUS" == "2" ]]; then
  echo "==> Cask not published yet — that's expected if the release isn't up."
  echo "    Once the asset is uploaded, run: ./scripts/publish-cask.sh"
else
  echo "==> Homebrew cask publish FAILED (exit $PUBLISH_STATUS). Read the error above —"
  echo "    re-running ./scripts/publish-cask.sh won't help until it's fixed."
fi
echo
echo "Then:"
echo "  1. Sparkle/bin/generate_appcast site/   (regenerates appcast.xml + signs DMGs)"
echo "  2. git -C site add appcast.xml && git -C site commit -m 'release' && git -C site push"
