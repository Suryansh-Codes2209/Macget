# Homebrew Tap Distribution Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let users install MacGet with `brew install --cask suryansh-codes2209/macget/macget`, landing a launchable app with no Gatekeeper dialog, and keep the cask current automatically on every release.

**Architecture:** A third-party Homebrew tap (`Suryansh-Codes2209/homebrew-macget`) holds a single cask that points at the existing GitHub Release DMG and strips the quarantine xattr in a `postflight` block. A template file in the Macget repo is the single source of the cask's text; `release.sh` renders it with the version and SHA it already computes, and `publish-cask.sh` verifies the SHA against GitHub's server-computed asset digest before committing to the tap.

**Tech Stack:** Homebrew Cask DSL (Ruby), bash 3.2 (macOS system bash), `gh` CLI, git.

**Spec:** `docs/superpowers/specs/2026-07-29-homebrew-tap-design.md`

## Global Constraints

- **Cask token is `macget`** (lowercase). The `name` stanza carries the human-facing `MacGet`. This follows the project rule in CLAUDE.md: anything a shell or filesystem reads is lowercase; anything a person reads as the product name is `MacGet`.
- **Tap repo:** GitHub `Suryansh-Codes2209/homebrew-macget`, **public**. Local checkout at `/Users/suryansh/Documents/Projects/Apple/homebrew-macget` — a sibling of the Macget repo, never inside it.
- **Release asset filename is exactly `macget.dmg`.** The Sparkle appcast's `<enclosure url>` depends on this exact name; renaming published assets breaks in-app updates for existing users.
- **Scripts must run under bash 3.2** (the macOS system bash). No `declare -A`, no `${var^^}`, no `readarray`. Expanding a possibly-empty array under `set -u` requires the `${arr[@]+"${arr[@]}"}` form — see the comment at `scripts/release.sh:92-97` for why this bit the project before.
- **Current release values** (for Task 1): version `1.3.0`, SHA-256 `f4f80a26a651cc6e6c7f6892d2190163b81e3f5a28f5c28a4d6b8a32388844df`.
- **Homepage:** `https://macget.suryansh.work/`. **Bundle ID:** `com.suryansh.Macget`.
- **No TDD harness for shell/Ruby here.** This repo's tests are XCTest for Swift only; do not add a bats or RSpec dependency. Verification is by executing the real commands, as specified in each task's steps.

---

### Task 1: Create the tap repository with a working cask

**Files:**
- Create: `/Users/suryansh/Documents/Projects/Apple/homebrew-macget/Casks/macget.rb`
- Create: `/Users/suryansh/Documents/Projects/Apple/homebrew-macget/README.md`
- Create: `/Users/suryansh/Documents/Projects/Apple/homebrew-macget/.gitignore`

**Interfaces:**
- Consumes: nothing (first task).
- Produces: the canonical cask text that Task 2's template must reproduce byte-for-byte apart from the `version` and `sha256` values. Produces the published tap that Task 3's `publish-cask.sh` pushes to.

**Note:** Step 7 creates a **public** GitHub repository — an outward-facing action. Confirm with the user before running it if they have not already approved this step in-session.

- [ ] **Step 1: Scaffold the local tap repo**

```bash
mkdir -p /Users/suryansh/Documents/Projects/Apple/homebrew-macget/Casks
cd /Users/suryansh/Documents/Projects/Apple/homebrew-macget
git init -b main
```

- [ ] **Step 2: Confirm the release asset digest before writing it into the cask**

Do not copy the SHA from this plan on faith — re-derive it. Run:

```bash
gh api repos/Suryansh-Codes2209/Macget/releases/tags/v1.3.0 \
  --jq '.assets[] | select(.name == "macget.dmg") | .digest'
```

Expected output:

```
sha256:f4f80a26a651cc6e6c7f6892d2190163b81e3f5a28f5c28a4d6b8a32388844df
```

If it differs, use the value the command returns and note the discrepancy — the asset was re-uploaded since this plan was written.

- [ ] **Step 3: Write the cask**

Create `Casks/macget.rb`:

```ruby
cask "macget" do
  version "1.3.0"
  sha256 "f4f80a26a651cc6e6c7f6892d2190163b81e3f5a28f5c28a4d6b8a32388844df"

  url "https://github.com/Suryansh-Codes2209/Macget/releases/download/v#{version}/macget.dmg",
      verified: "github.com/Suryansh-Codes2209/Macget/"
  name "MacGet"
  desc "Multi-threaded download manager with media, torrent, and book-catalog support"
  homepage "https://macget.suryansh.work/"

  livecheck do
    url :url
    strategy :github_latest
  end

  auto_updates true
  depends_on macos: :tahoe
  depends_on arch: :arm64

  app "Macget.app"

  postflight do
    system_command "/usr/bin/xattr",
                   args: ["-dr", "com.apple.quarantine", "#{appdir}/Macget.app"]
  end

  zap trash: [
    "~/Library/Application Support/BraveSoftware/Brave-Browser/NativeMessagingHosts/com.suryansh.macget.json",
    "~/Library/Application Support/Chromium/NativeMessagingHosts/com.suryansh.macget.json",
    "~/Library/Application Support/Google/Chrome Beta/NativeMessagingHosts/com.suryansh.macget.json",
    "~/Library/Application Support/Google/Chrome Canary/NativeMessagingHosts/com.suryansh.macget.json",
    "~/Library/Application Support/Google/Chrome/NativeMessagingHosts/com.suryansh.macget.json",
    "~/Library/Application Support/Macget",
    "~/Library/Application Support/Microsoft Edge/NativeMessagingHosts/com.suryansh.macget.json",
    "~/Library/Application Support/Mozilla/NativeMessagingHosts/com.suryansh.macget.json",
    "~/Library/Caches/com.suryansh.Macget",
    "~/Library/HTTPStorages/com.suryansh.Macget",
    "~/Library/Preferences/com.suryansh.Macget.plist",
    "~/Library/Saved Application State/com.suryansh.Macget.savedState",
  ]

  caveats <<~EOS
    MacGet requires macOS 26.4 or later on Apple silicon.

    This build is not notarized by Apple. The cask removes the quarantine
    attribute after install so MacGet launches without a Gatekeeper prompt.
  EOS
end
```

Why each non-obvious stanza is there:

- `auto_updates true` — MacGet self-updates via Sparkle. Without this, a bare `brew upgrade` would reinstall over an app that already updated itself and Homebrew's recorded version would drift from disk. With it, the argument-less sweep skips MacGet (`cask/cask.rb:433`); naming the cask explicitly still upgrades it, since `brew upgrade <cask>` always passes `greedy: true` (`cask/upgrade.rb:56,65`).
- `postflight` — the DMG is ad-hoc signed, not notarized, so Homebrew's quarantine attribute would make macOS refuse to open the installed app. `xattr -dr` exits 0 when the attribute is already absent (verified), so this is also safe under `--no-quarantine`.
- `depends_on arch: :arm64` — verified against the shipped binary; `lipo -archs` reports `arm64` only.
- `depends_on macos: :tahoe` — a bare recognized symbol inherits the `>=` comparator that `depends_on macos:` passes by default (`cask/dsl/depends_on.rb:108` → `MacOSRequirement.parse(args, comparator: ">=")`, taken at `requirements/macos_requirement.rb:40-41`). The string form `">= :tahoe"` is identical in meaning but `odeprecated` in Homebrew 6.x, which names this exact bare-symbol form as its replacement. Homebrew's macOS symbols are major-version only (`:tahoe` → `26`), so either form admits 26.0–26.3 even though MacGet needs 26.4. `LSMinimumSystemVersion` catches those at launch. This gap is accepted, which is why the caveats state 26.4 explicitly.

- [ ] **Step 4: Write the tap README**

Create `README.md`:

````markdown
# homebrew-macget

Homebrew tap for [MacGet](https://macget.suryansh.work/) — a multi-threaded
download manager for macOS.

## Install

```bash
brew install --cask suryansh-codes2209/macget/macget
```

The fully-qualified name auto-taps, so there is no separate `brew tap` step.

## Requirements

- macOS 26.4 (Tahoe) or later
- Apple silicon

## Notes

MacGet updates itself through Sparkle, so the cask is marked `auto_updates true`.
A bare `brew upgrade` (no cask named) will skip it for that reason. Naming it
explicitly still upgrades it: `brew upgrade macget` reinstalls the cask's
pinned version regardless.

MacGet is not currently notarized by Apple. The cask removes the quarantine
attribute after install so the app launches without a Gatekeeper prompt.

## Uninstall

```bash
brew uninstall --cask macget          # remove the app
brew uninstall --cask --zap macget    # also remove queue, settings, and caches
```
````

- [ ] **Step 5: Add a .gitignore**

Create `.gitignore`:

```
.DS_Store
```

- [ ] **Step 6: Verify the cask locally before publishing anything**

Tap the local directory by path — this works without a GitHub remote and is the
fastest way to catch a malformed stanza:

```bash
brew tap suryansh-codes2209/macget /Users/suryansh/Documents/Projects/Apple/homebrew-macget
brew audit --cask --online suryansh-codes2209/macget/macget
```

Expected: audit passes with no errors. `--online` is what actually fetches the URL
and checks the checksum, so do not omit it.

If audit reports style offenses, fix them in `Casks/macget.rb` and re-run. Do not
proceed to Step 7 with a failing audit.

- [ ] **Step 7: Create the GitHub repo and push**

```bash
cd /Users/suryansh/Documents/Projects/Apple/homebrew-macget
git add -A
git commit -m "Add macget cask 1.3.0"
gh repo create Suryansh-Codes2209/homebrew-macget \
  --public \
  --source=. \
  --remote=origin \
  --description "Homebrew tap for MacGet" \
  --push
```

- [ ] **Step 8: Verify a real end-to-end install**

Remove the path-based tap so the test exercises the published repo:

```bash
brew untap suryansh-codes2209/macget
brew install --cask suryansh-codes2209/macget/macget
```

Then confirm all four of these:

```bash
test -d /Applications/Macget.app && echo "app installed OK"
xattr -p com.apple.quarantine /Applications/Macget.app 2>&1   # expect: "No such xattr"
open -a /Applications/Macget.app                              # expect: launches, no Gatekeeper dialog
brew livecheck --cask suryansh-codes2209/macget/macget        # expect: reports 1.3.0, up to date
```

If MacGet was already installed from the DMG, `brew install` will report the app
already exists. Move it aside first (`mv /Applications/Macget.app ~/Desktop/`) so the
install path is genuinely exercised.

- [ ] **Step 9: Verify zap removes the right paths**

```bash
ls -d ~/Library/Application\ Support/Macget ~/Library/Preferences/com.suryansh.Macget.plist 2>&1
brew uninstall --cask --zap suryansh-codes2209/macget/macget
ls -d ~/Library/Application\ Support/Macget ~/Library/Preferences/com.suryansh.Macget.plist 2>&1
```

Expected: paths that existed before are gone after. If a path in the `zap` stanza
never existed, that is fine (zap ignores missing paths), but if MacGet creates a
path *not* in the stanza, add it to `Casks/macget.rb` and commit the fix.

**This step destroys the local download queue and settings.** Back up
`~/Library/Application Support/Macget` first if it holds real in-progress downloads.

- [ ] **Step 10: Reinstall so the machine is left in a working state**

```bash
brew install --cask suryansh-codes2209/macget/macget
```

- [ ] **Step 11: Commit any fixes from Steps 8–9**

```bash
cd /Users/suryansh/Documents/Projects/Apple/homebrew-macget
git add -A
git commit -m "Fix cask paths found during install verification"
git push
```

Skip if Steps 8–9 required no changes.

---

### Task 2: Extract the cask into a template and render it from release.sh

**Files:**
- Create: `scripts/macget.cask.tmpl`
- Modify: `scripts/release.sh` (add render step near the end, after the existing SHA-256 print at lines 152–153)

**Interfaces:**
- Consumes: the exact cask text from Task 1 Step 3.
- Produces: `dist/macget.rb` — a fully rendered cask. Task 3's `publish-cask.sh` reads `version` and `sha256` back out of this file and copies it into the tap.

- [ ] **Step 1: Create the template**

Create `scripts/macget.cask.tmpl` — identical to the cask from Task 1 Step 3, with
two placeholders substituted:

```ruby
cask "macget" do
  version "__VERSION__"
  sha256 "__SHA256__"

  url "https://github.com/Suryansh-Codes2209/Macget/releases/download/v#{version}/macget.dmg",
      verified: "github.com/Suryansh-Codes2209/Macget/"
  name "MacGet"
  desc "Multi-threaded download manager with media, torrent, and book-catalog support"
  homepage "https://macget.suryansh.work/"

  livecheck do
    url :url
    strategy :github_latest
  end

  auto_updates true
  depends_on macos: :tahoe
  depends_on arch: :arm64

  app "Macget.app"

  postflight do
    system_command "/usr/bin/xattr",
                   args: ["-dr", "com.apple.quarantine", "#{appdir}/Macget.app"]
  end

  zap trash: [
    "~/Library/Application Support/BraveSoftware/Brave-Browser/NativeMessagingHosts/com.suryansh.macget.json",
    "~/Library/Application Support/Chromium/NativeMessagingHosts/com.suryansh.macget.json",
    "~/Library/Application Support/Google/Chrome Beta/NativeMessagingHosts/com.suryansh.macget.json",
    "~/Library/Application Support/Google/Chrome Canary/NativeMessagingHosts/com.suryansh.macget.json",
    "~/Library/Application Support/Google/Chrome/NativeMessagingHosts/com.suryansh.macget.json",
    "~/Library/Application Support/Macget",
    "~/Library/Application Support/Microsoft Edge/NativeMessagingHosts/com.suryansh.macget.json",
    "~/Library/Application Support/Mozilla/NativeMessagingHosts/com.suryansh.macget.json",
    "~/Library/Caches/com.suryansh.Macget",
    "~/Library/HTTPStorages/com.suryansh.Macget",
    "~/Library/Preferences/com.suryansh.Macget.plist",
    "~/Library/Saved Application State/com.suryansh.Macget.savedState",
  ]

  caveats <<~EOS
    MacGet requires macOS 26.4 or later on Apple silicon.

    This build is not notarized by Apple. The cask removes the quarantine
    attribute after install so MacGet launches without a Gatekeeper prompt.
  EOS
end
```

Note `#{version}` and `#{appdir}` are Ruby interpolations evaluated by Homebrew at
install time, **not** template placeholders. Only `__VERSION__` and `__SHA256__` get
substituted. Do not use `sed` patterns that would touch `#{...}`.

- [ ] **Step 2: Add the render step to release.sh**

In `scripts/release.sh`, the existing tail is:

```bash
echo "==> SHA-256 of DMG:"
shasum -a 256 "$DMG_PATH"

echo "==> Done."
echo "Next steps:"
echo "  1. Create a GitHub Release and upload $DMG_PATH"
echo "  2. Run: Sparkle/bin/generate_appcast site/   (regenerates appcast.xml + signs DMGs)"
echo "  3. git -C site add appcast.xml && git -C site commit -m 'release' && git -C site push"
```

Replace it with:

```bash
DMG_SHA="$(shasum -a 256 "$DMG_PATH" | awk '{print $1}')"
echo "==> SHA-256 of DMG: $DMG_SHA"

echo "==> Rendering Homebrew cask…"
CASK_OUT="$DIST_DIR/macget.rb"
sed -e "s/__VERSION__/$VERSION/g" -e "s/__SHA256__/$DMG_SHA/g" \
  "$ROOT/scripts/macget.cask.tmpl" > "$CASK_OUT"
echo "    Wrote $CASK_OUT"

echo "==> Done."
echo "Next steps:"
echo "  1. Create a GitHub Release for v$VERSION and upload $DMG_PATH as 'macget.dmg'"
echo "     (the appcast enclosure URL depends on that exact asset name)"
echo "  2. Run: ./scripts/publish-cask.sh   (pushes the cask to the Homebrew tap)"
echo "  3. Run: Sparkle/bin/generate_appcast site/   (regenerates appcast.xml + signs DMGs)"
echo "  4. git -C site add appcast.xml && git -C site commit -m 'release' && git -C site push"
```

`VERSION` is already defined at line 126. `ROOT` is already defined at line 48.

- [ ] **Step 3: Verify the render without running a full release**

`release.sh` runs the whole test-and-build pipeline, which is far too slow to use as
a render test. Exercise the `sed` line directly with the known-good values:

```bash
cd /Users/suryansh/Documents/Projects/Apple/Macget
sed -e "s/__VERSION__/1.3.0/g" \
    -e "s/__SHA256__/f4f80a26a651cc6e6c7f6892d2190163b81e3f5a28f5c28a4d6b8a32388844df/g" \
    scripts/macget.cask.tmpl > /tmp/rendered-cask.rb
diff /tmp/rendered-cask.rb /Users/suryansh/Documents/Projects/Apple/homebrew-macget/Casks/macget.rb && \
  echo "RENDER MATCHES PUBLISHED CASK"
```

Expected: `diff` produces no output and the success line prints. This is the real
test of Task 2 — it proves the template reproduces the exact cask that Task 1
verified with `brew audit` and a live install. If `diff` shows differences, fix the
template (not the published cask) until they match.

- [ ] **Step 4: Commit**

```bash
git add scripts/macget.cask.tmpl scripts/release.sh
git commit -m "release: render a Homebrew cask alongside the DMG"
```

---

### Task 3: publish-cask.sh

**Files:**
- Create: `scripts/publish-cask.sh` (mode 755)

**Interfaces:**
- Consumes: `dist/macget.rb` produced by Task 2. Reads `version "X"` and `sha256 "Y"` out of it.
- Produces: a commit on `Suryansh-Codes2209/homebrew-macget` updating `Casks/macget.rb`. Task 4 wires `release.sh` to call this.

- [ ] **Step 1: Write the script**

Create `scripts/publish-cask.sh`:

```bash
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
# --cache makes the three lookups below (existence check, digest, and the
# asset listing in the error path) a single network round-trip: gh caches
# the raw response locally on the first call and replays it from the cache
# file for the identical requests that follow.
RELEASE_ARGS=(api --cache 60s "repos/$REPO/releases/tags/v$VERSION")

if ! RELEASE_ERR="$(gh "${RELEASE_ARGS[@]}" 2>&1 >/dev/null)"; then
  echo "ERROR: no GitHub Release tagged v$VERSION (or the GitHub API request failed):"
  echo "       $RELEASE_ERR"
  echo "       Create the release and upload $ROOT/dist/Macget-$VERSION.dmg as '$ASSET_NAME' first."
  exit 1
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

if [[ -n "$(git -C "$TAP_DIR" status --porcelain)" ]]; then
  echo "ERROR: $TAP_DIR has uncommitted changes. Commit or stash them first."
  exit 1
fi

git -C "$TAP_DIR" pull --ff-only

if [[ "$DRY_RUN" == "1" ]]; then
  echo "==> Dry run — diff against the tap's current cask:"
  # diff exits 1 for "differences found" (expected here) and 2 for "trouble"
  # (e.g. the tap's cask is missing). Only swallow 1 — let 2 abort the script
  # instead of being misreported as a clean, empty diff.
  #
  # Deliberately `[ ]`, not `[[ ]]`: on this machine's bash 3.2, `false || [[ ... ]]`
  # does not trip `set -e` even when the `[[ ]]` fails — confirmed by repeated
  # runs of `bash -euo pipefail -c 'false || [[ 1 -eq 2 ]]; echo leaked'`, which
  # prints "leaked" and exits 0. The POSIX `[ ]` form does not have this bug.
  diff -u "$TAP_DIR/Casks/macget.rb" "$CASK_SRC" || [ "$?" -eq 1 ]
  echo "==> Dry run complete. Nothing was changed."
  exit 0
fi

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
```

This is the script as it shipped, after review. Three hardening changes came out
of that review and are worth knowing about before editing:

- `${TAP_DIR}` at line 98 is braced deliberately. Unbraced, the `$TAP_DIR` abuts the
  U+2026 that follows it, bash 3.2 absorbs those bytes into the identifier, and
  `set -u` aborts *before* the `git clone` — silently disabling the whole
  clone-if-missing path on any UTF-8 locale.
- Line 119 uses POSIX `[ ]`, not `[[ ]]`. On bash 3.2 a failing `[[ ]]` as the
  right-hand side of `||` does not trip `set -e`, so the `[[ ]]` form would swallow
  diff's exit 2 exactly like the `|| true` it replaced.
- The `--cache 60s` on line 60 makes the three lookups one network round-trip, and
  each `gh` call checks its own exit status rather than `|| true`, so a transient
  API failure is not misreported as "no such asset".

Note the `${ASSET_DIGEST#sha256:}` prefix strip at line 87 — the API returns
`sha256:f4f8…`, but the cask stores the bare hex.

- [ ] **Step 2: Make it executable**

```bash
chmod +x scripts/publish-cask.sh
```

- [ ] **Step 3: Test the happy path with --dry-run**

The tap is already at 1.3.0 from Task 1, so a dry run against a freshly rendered
1.3.0 cask should verify cleanly and show an empty diff:

```bash
cd /Users/suryansh/Documents/Projects/Apple/Macget
mkdir -p dist
sed -e "s/__VERSION__/1.3.0/g" \
    -e "s/__SHA256__/f4f80a26a651cc6e6c7f6892d2190163b81e3f5a28f5c28a4d6b8a32388844df/g" \
    scripts/macget.cask.tmpl > dist/macget.rb
./scripts/publish-cask.sh --dry-run
```

Expected output includes:

```
==> Cask declares version 1.3.0, sha256 f4f80a26...
==> Checking release v1.3.0 for a 'macget.dmg' asset…
==> Digest matches the uploaded asset.
==> Dry run — diff against the tap's current cask:
==> Dry run complete. Nothing was changed.
```

with no diff lines between the last two. A diff here means the template and the
published cask have drifted — fix the template.

- [ ] **Step 4: Test the checksum-mismatch guard**

This is the guard that matters most; a broken one ships a cask that fails for every
user. Force a mismatch:

```bash
sed -i '' 's/^  sha256 ".*"$/  sha256 "0000000000000000000000000000000000000000000000000000000000000000"/' dist/macget.rb
./scripts/publish-cask.sh --dry-run; echo "exit=$?"
```

Expected: prints `ERROR: checksum mismatch — refusing to publish.` with both SHAs,
and `exit=1`. Confirm it aborts *before* the dry-run diff — a mismatch must stop the
script regardless of `--dry-run`.

- [ ] **Step 5: Test the missing-release guard**

```bash
sed -e "s/__VERSION__/99.0.0/g" -e "s/__SHA256__/deadbeef/g" \
  scripts/macget.cask.tmpl > dist/macget.rb
./scripts/publish-cask.sh --dry-run; echo "exit=$?"
```

Expected: `ERROR: no GitHub Release tagged v99.0.0.` and `exit=1`.

- [ ] **Step 6: Restore a valid dist/macget.rb**

```bash
sed -e "s/__VERSION__/1.3.0/g" \
    -e "s/__SHA256__/f4f80a26a651cc6e6c7f6892d2190163b81e3f5a28f5c28a4d6b8a32388844df/g" \
    scripts/macget.cask.tmpl > dist/macget.rb
```

- [ ] **Step 7: Commit**

`dist/` is already gitignored (`.gitignore:38`), so `dist/macget.rb` will not be
picked up. Add only the script:

```bash
git add scripts/publish-cask.sh
git commit -m "release: add publish-cask.sh to push the cask to the Homebrew tap"
```

---

### Task 4: Wire release.sh to publish-cask.sh, and document the install path

**Files:**
- Modify: `scripts/release.sh` (the "Next steps" block added in Task 2)
- Modify: `README.md` (install section)
- Modify: `frontend/app/install/page.tsx`
- Modify: `SETUP.md` (release checklist)
- Modify: `CLAUDE.md` (build/release commands section)

**Interfaces:**
- Consumes: `scripts/publish-cask.sh` from Task 3, and the rendered `dist/macget.rb` from Task 2.
- Produces: nothing consumed by later tasks. This is the final task.

- [ ] **Step 1: Auto-invoke publish-cask.sh from release.sh**

In `scripts/release.sh`, replace the "Next steps" block from Task 2 Step 2 with:

```bash
echo "==> Done."
echo
echo "Next: create a GitHub Release for v$VERSION and upload"
echo "      $DMG_PATH"
echo "      as an asset named exactly 'macget.dmg' (the Sparkle appcast enclosure"
echo "      URL depends on that name)."
echo
if ./scripts/publish-cask.sh; then
  echo "==> Homebrew cask published."
else
  echo "==> Cask not published yet — that's expected if the release isn't up."
  echo "    Once the asset is uploaded, run: ./scripts/publish-cask.sh"
fi
echo
echo "Then:"
echo "  1. Sparkle/bin/generate_appcast site/   (regenerates appcast.xml + signs DMGs)"
echo "  2. git -C site add appcast.xml && git -C site commit -m 'release' && git -C site push"
```

`publish-cask.sh` runs under `set -e` in the caller, so it must be inside the `if`
condition — a bare call would abort `release.sh` when the release is not yet
uploaded, which is the normal case.

- [ ] **Step 2: Verify release.sh's tail without a full build**

Extract and run just the new block with the real script, confirming it does not
abort on a not-yet-published release:

```bash
cd /Users/suryansh/Documents/Projects/Apple/Macget
sed -e "s/__VERSION__/99.0.0/g" -e "s/__SHA256__/deadbeef/g" \
  scripts/macget.cask.tmpl > dist/macget.rb
bash -c 'set -euo pipefail
if ./scripts/publish-cask.sh --dry-run; then echo "PUBLISHED"; else echo "SKIPPED CLEANLY"; fi'
echo "outer exit=$?"
```

`--dry-run` is used here purely as a safety belt. With a nonexistent version the
script exits at the missing-release check (`publish-cask.sh:62-67`), long before the
`--dry-run` branch at :109 is even reached — so this exercises exactly the same code
path `release.sh` will hit, while making it impossible for a mistake in the guard to
push a fabricated cask to the published tap.

Expected: prints `SKIPPED CLEANLY` and `outer exit=0`. If it prints nothing and
exits non-zero, the `if` guard is wrong and `release.sh` would abort mid-release.

Restore a valid rendered cask afterward:

```bash
sed -e "s/__VERSION__/1.3.0/g" \
    -e "s/__SHA256__/f4f80a26a651cc6e6c7f6892d2190163b81e3f5a28f5c28a4d6b8a32388844df/g" \
    scripts/macget.cask.tmpl > dist/macget.rb
```

- [ ] **Step 3: Add Homebrew to the README install section**

Read the current install section first:

```bash
grep -n "Install" -A 20 README.md | head -40
```

Add a Homebrew option **above** the existing DMG instructions, since it is now the
easier path. Match the surrounding heading level and prose style. Content:

````markdown
### Homebrew (recommended)

```bash
brew install --cask suryansh-codes2209/macget/macget
```

Requires macOS 26.4 or later on Apple silicon. The cask removes the quarantine
attribute after install, so there is no Gatekeeper prompt and no "Open Anyway" step.
````

Leave the existing DMG and "First launch on macOS" sections intact — they still
apply to anyone downloading the DMG directly. Per CLAUDE.md, keep the literal
`Macget` casing where those sections refer to the app bundle or quote the Gatekeeper
dialog verbatim; use `MacGet` in prose.

- [ ] **Step 4: Add Homebrew to the site install page**

`frontend/app/install/page.tsx:106` currently reads:

```
Download <code>{siteConfig.binary}.dmg</code> from the releases
```

Read the surrounding component to match its structure, then add a Homebrew step
before the DMG step. Do not hardcode the version — the command has no version in it,
so this stays correct across releases (consistent with commit `d9b187e`, which
removed hardcoded versions from site MDX prose).

- [ ] **Step 5: Verify the site builds and renders**

```bash
cd frontend
npm run build
```

Expected: build succeeds. Then verify the rendered page — per the project's site
verification practice, kill any existing `next start` first so you don't screenshot
a stale build:

```bash
pkill -f "next start" || true
npm run start &
sleep 5
curl -s http://localhost:3000/install | grep -c "brew install"
```

Expected: at least 1.

- [ ] **Step 6: Update the release checklist in SETUP.md**

Add `./scripts/publish-cask.sh` to the per-release steps, after uploading the DMG to
the GitHub Release and before regenerating the appcast. Read the existing checklist
first and match its formatting.

- [ ] **Step 7: Update CLAUDE.md**

In the "Build, run, test" section, under the release command, note the tap:

```markdown
# Release / signed / notarized DMG (one-time setup required — see scripts/release.sh header)
./scripts/release.sh

# Publish the Homebrew cask after the GitHub Release asset is uploaded
./scripts/publish-cask.sh
```

Then add a short subsection documenting the tap. Keep it to the facts a future
reader could not derive from the code:

```markdown
### Homebrew tap

MacGet is distributed through a third-party tap, `Suryansh-Codes2209/homebrew-macget`
(checked out as a sibling of this repo at `../homebrew-macget`), not through
`homebrew/cask` — the latter requires 225 stars / 90 forks / 90 watchers for a
self-submission.

`scripts/macget.cask.tmpl` is the single source of the cask text; `release.sh`
renders it to `dist/macget.rb` and `publish-cask.sh` verifies the SHA against
GitHub's server-computed asset digest before pushing. The cask strips the quarantine
xattr in a `postflight` block because the DMG is ad-hoc signed rather than notarized
— `homebrew/cask` forbids exactly that, so an upstream submission would need
notarization first, not just more stars.

The release asset must be named exactly `macget.dmg`. The Sparkle appcast's
`<enclosure url>` points at it, so renaming published assets breaks in-app updates
for existing users. `publish-cask.sh` fails loudly if the name is wrong.
```

- [ ] **Step 8: Commit**

```bash
git add scripts/release.sh README.md frontend/app/install/page.tsx SETUP.md CLAUDE.md
git commit -m "docs: document Homebrew install and wire cask publishing into release.sh"
```

- [ ] **Step 9: Final end-to-end verification**

```bash
brew update
brew info --cask suryansh-codes2209/macget/macget
./scripts/publish-cask.sh --dry-run
```

Expected: `brew info` reports version 1.3.0 and shows the caveats text; the dry run
verifies the digest and reports an empty diff.

---

## Deferred

Not in this plan, by design:

- **Submission to `homebrew/cask`.** Blocked on notability (225 stars / 90 forks / 90 watchers for a self-submission) *and* on the `postflight` quarantine strip, which upstream forbids. Revisit only after notarization.
- **Notarization.** Requires the $99 Apple Developer Program. When it happens, the `postflight` block and the second paragraph of `caveats` should be deleted from `scripts/macget.cask.tmpl`; nothing else in this design changes.
- **Intel or universal builds.** The cask declares `arch: :arm64` to match the current binary.
- **A GitHub Action in the tap repo.** `release.sh` calling `publish-cask.sh` covers the update path; a workflow would only help for releases cut outside `release.sh`.
