#!/usr/bin/env bash
# Publish the rendered Homebrew cask to the MacGet tap.
#
# Reads dist/macget.rb (written by release.sh), verifies its sha256 against the
# digest GitHub computed for the uploaded release asset, then commits and pushes
# Casks/macget.rb to the tap repo.
#
# Usage:
#   ./scripts/publish-cask.sh              # verify and push
#   ./scripts/publish-cask.sh --dry-run    # verify and diff, change nothing
set -euo pipefail

REPO="Suryansh-Codes2209/Macget"
TAP_REPO="Suryansh-Codes2209/homebrew-macget"
ASSET_NAME="macget.dmg"

DRY_RUN=0
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=1 ;;
    *) echo "Unknown argument: $arg"; exit 1 ;;
  esac
done

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

TAP_DIR="$(cd "$ROOT/.." && pwd)/homebrew-macget"
CASK_SRC="$ROOT/dist/macget.rb"

if ! command -v gh >/dev/null 2>&1; then
  echo "ERROR: the 'gh' CLI is required. Install it with: brew install gh"
  exit 1
fi
if ! gh auth status >/dev/null 2>&1; then
  echo "ERROR: gh is not authenticated. Run: gh auth login"
  exit 1
fi

if [[ ! -f "$CASK_SRC" ]]; then
  echo "ERROR: $CASK_SRC not found. Run ./scripts/release.sh first."
  exit 1
fi

# Pull the version and sha back out of the rendered cask so this script has a
# single source of truth and can't drift from what release.sh produced.
VERSION="$(sed -n 's/^  version "\(.*\)"$/\1/p' "$CASK_SRC")"
CASK_SHA="$(sed -n 's/^  sha256 "\(.*\)"$/\1/p' "$CASK_SRC")"
if [[ -z "$VERSION" || -z "$CASK_SHA" ]]; then
  echo "ERROR: could not parse version/sha256 out of $CASK_SRC"
  exit 1
fi
echo "==> Cask declares version $VERSION, sha256 $CASK_SHA"

echo "==> Checking release v$VERSION for a '$ASSET_NAME' asset…"
if ! gh api "repos/$REPO/releases/tags/v$VERSION" >/dev/null 2>&1; then
  echo "ERROR: no GitHub Release tagged v$VERSION."
  echo "       Create it and upload $ROOT/dist/Macget-$VERSION.dmg as '$ASSET_NAME' first."
  exit 1
fi

ASSET_DIGEST="$(gh api "repos/$REPO/releases/tags/v$VERSION" \
  --jq ".assets[] | select(.name == \"$ASSET_NAME\") | .digest" 2>/dev/null || true)"

if [[ -z "$ASSET_DIGEST" ]]; then
  echo "ERROR: release v$VERSION has no asset named '$ASSET_NAME'. Found:"
  gh api "repos/$REPO/releases/tags/v$VERSION" --jq '.assets[] | "   - " + .name'
  echo "       The Sparkle appcast depends on that exact name — rename the asset."
  exit 1
fi

REMOTE_SHA="${ASSET_DIGEST#sha256:}"
if [[ "$REMOTE_SHA" != "$CASK_SHA" ]]; then
  echo "ERROR: checksum mismatch — refusing to publish."
  echo "       cask:   $CASK_SHA"
  echo "       GitHub: $REMOTE_SHA"
  echo "       The uploaded asset is not the DMG this cask was rendered for."
  exit 1
fi
echo "==> Digest matches the uploaded asset."

if [[ ! -d "$TAP_DIR/.git" ]]; then
  echo "==> Tap checkout not found; cloning to $TAP_DIR…"
  git clone "https://github.com/$TAP_REPO.git" "$TAP_DIR"
fi

if [[ -n "$(git -C "$TAP_DIR" status --porcelain)" ]]; then
  echo "ERROR: $TAP_DIR has uncommitted changes. Commit or stash them first."
  exit 1
fi

git -C "$TAP_DIR" pull --ff-only

if [[ "$DRY_RUN" == "1" ]]; then
  echo "==> Dry run — diff against the tap's current cask:"
  diff -u "$TAP_DIR/Casks/macget.rb" "$CASK_SRC" || true
  echo "==> Dry run complete. Nothing was changed."
  exit 0
fi

cp "$CASK_SRC" "$TAP_DIR/Casks/macget.rb"
if [[ -z "$(git -C "$TAP_DIR" status --porcelain)" ]]; then
  echo "==> Tap is already at $VERSION. Nothing to do."
  exit 0
fi

git -C "$TAP_DIR" add Casks/macget.rb
git -C "$TAP_DIR" commit -m "Update macget to $VERSION"
git -C "$TAP_DIR" push
echo "==> Published macget $VERSION to $TAP_REPO."
