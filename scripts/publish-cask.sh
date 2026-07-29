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
#
# Exit codes:
#   0  published (or, with --dry-run, verified and diffed) successfully
#   1  publish failed — checksum mismatch, missing asset, dirty/missing tap,
#      gh not installed/authenticated, or any other error. Read the message
#      printed above the exit; re-running without fixing the cause will fail
#      the same way.
#   2  no GitHub Release exists yet for the version in dist/macget.rb (or the
#      API request for it failed). This is the expected, non-error state
#      right after `release.sh` runs and before the release is published —
#      callers (release.sh) treat this one specially and just tell the
#      maintainer to re-run once the release is up.
#
# Note on the `--cache 60s` below: if you upload the release asset and
# immediately re-run this script, `gh` may still be serving the cached
# "no such asset" response for up to 60 seconds. That's self-resolving —
# wait a minute and re-run — not a real failure.
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
# --cache makes the three lookups below (existence check, digest, and the
# asset listing in the error path) a single network round-trip: gh caches
# the raw response locally on the first call and replays it from the cache
# file for the identical requests that follow.
RELEASE_ARGS=(api --cache 60s "repos/$REPO/releases/tags/v$VERSION")

if ! RELEASE_ERR="$(gh "${RELEASE_ARGS[@]}" 2>&1 >/dev/null)"; then
  echo "ERROR: no GitHub Release tagged v$VERSION (or the GitHub API request failed):"
  echo "       $RELEASE_ERR"
  echo "       Create the release and upload $ROOT/dist/${ASSET_NAME} first."
  exit 2
fi

if ! ASSET_DIGEST="$(gh "${RELEASE_ARGS[@]}" \
  --jq ".assets[] | select(.name == \"$ASSET_NAME\") | .digest" 2>&1)"; then
  echo "ERROR: the GitHub API request for release v$VERSION's assets failed:"
  echo "$ASSET_DIGEST" | sed 's/^/       /'
  exit 1
fi

if [[ -z "$ASSET_DIGEST" ]]; then
  echo "ERROR: release v$VERSION has no asset named '$ASSET_NAME'. Found:"
  if ! ASSET_LIST="$(gh "${RELEASE_ARGS[@]}" --jq '.assets[] | "   - " + .name' 2>&1)"; then
    echo "       (could not list the release's assets: $ASSET_LIST)"
  else
    echo "$ASSET_LIST"
  fi
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
  echo "==> Tap checkout not found; cloning to ${TAP_DIR}…"
  git clone "https://github.com/$TAP_REPO.git" "$TAP_DIR"
fi

if [[ "$DRY_RUN" == "1" ]]; then
  # `--dry-run` must actually be read-only: `git fetch` only updates the
  # remote-tracking ref (refs/remotes/origin/*), never the tap's checked-out
  # branch or working tree, so it can't fast-forward anything. Diffing straight
  # out of that ref with `git show` — instead of `git pull --ff-only` plus a
  # working-tree diff — means the "Nothing was changed" message printed below
  # is actually true rather than aspirational.
  echo "==> Dry run — fetching the tap's latest ref (read-only)…"
  git -C "$TAP_DIR" fetch origin
  TAP_DEFAULT_REF="$(git -C "$TAP_DIR" symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null || echo "origin/main")"
  echo "==> Dry run — diff against ${TAP_DEFAULT_REF}'s current cask:"
  # diff exits 1 for "differences found" (expected here) and 2 for "trouble"
  # (e.g. the tap's cask is missing). Only swallow 1 — let 2 abort the script
  # instead of being misreported as a clean, empty diff.
  #
  # Deliberately `[ ]`, not `[[ ]]`: on this machine's bash 3.2, `false || [[ ... ]]`
  # does not trip `set -e` even when the `[[ ]]` fails — confirmed by repeated
  # runs of `bash -euo pipefail -c 'false || [[ 1 -eq 2 ]]; echo leaked'`, which
  # prints "leaked" and exits 0. The POSIX `[ ]` form does not have this bug.
  diff -u <(git -C "$TAP_DIR" show "${TAP_DEFAULT_REF}:Casks/macget.rb") "$CASK_SRC" || [ "$?" -eq 1 ]
  echo "==> Dry run complete. Nothing was changed."
  exit 0
fi

if [[ -n "$(git -C "$TAP_DIR" status --porcelain)" ]]; then
  echo "ERROR: $TAP_DIR has uncommitted changes. Commit or stash them first."
  exit 1
fi

git -C "$TAP_DIR" pull --ff-only

cp "$CASK_SRC" "$TAP_DIR/Casks/macget.rb"

# git diff --quiet: 0 = no differences, 1 = differences found, anything else
# is a git failure we must not mistake for "nothing changed" — the cp above
# already landed on disk, so silently reporting success here would be a false
# positive.
set +e
git -C "$TAP_DIR" diff --quiet -- Casks/macget.rb
DIFF_STATUS=$?
set -e
case "$DIFF_STATUS" in
  0)
    echo "==> Tap is already at $VERSION. Nothing to do."
    exit 0
    ;;
  1)
    ;;
  *)
    echo "ERROR: 'git diff' against $TAP_DIR failed (exit $DIFF_STATUS)."
    echo "       Refusing to guess whether Casks/macget.rb actually changed."
    exit 1
    ;;
esac

git -C "$TAP_DIR" add Casks/macget.rb
git -C "$TAP_DIR" commit -m "Update macget to $VERSION"
git -C "$TAP_DIR" push
echo "==> Published macget $VERSION to $TAP_REPO."
