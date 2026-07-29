# Homebrew distribution for MacGet

**Date:** 2026-07-29
**Status:** Approved, not yet implemented

## Goal

Let users install MacGet with one command:

```bash
brew install --cask suryansh-codes2209/macget/macget
```

The install must leave a launchable app — no Gatekeeper dialog, no manual `xattr`
incantation, no README detour.

## Why not homebrew/cask

Homebrew's [Package Acceptance Policy](https://docs.brew.sh/Package-Acceptance-Policy)
requires **225 stars, 90 forks, or 90 watchers** for a self-submission by the
repository owner (30 forks / 30 watchers / 75 stars if a third party submits it).
`Suryansh-Codes2209/Macget` currently has 1 star and 0 forks, so a PR to
`homebrew/cask` would be closed on sight.

Homebrew explicitly sanctions the alternative: "Software that does not meet the
official criteria can generally be maintained in a third-party tap." That is what
this design builds.

Two things would have to change before an upstream submission is worth attempting:
the notability thresholds above, and the `postflight` quarantine strip (see
"Gatekeeper" below), which `homebrew/cask` forbids.

## Gatekeeper

The shipped DMG is ad-hoc signed, not notarized:

```
$ spctl -a -t open --context context:primary-signature -v dist/Macget-1.3.0.dmg
dist/Macget-1.3.0.dmg: rejected
source=no usable signature
```

Homebrew Cask applies a quarantine attribute to everything it installs, so a naive
cask would drop MacGet into `/Applications` and then have macOS refuse to open it —
worse than the DMG path, because the user believes they installed it properly.

The cask strips quarantine in a `postflight` block. Two facts make this sound:

- `/usr/bin/xattr` on macOS 26.6 is a native Mach-O universal binary, not the old
  Python script that disappeared when Apple dropped Python 2. No runtime dependency.
- The app is *ad-hoc signed*, not unsigned. On Apple silicon an unsigned arm64
  binary will not execute regardless of quarantine state; an ad-hoc signature
  satisfies that requirement, so removing quarantine is genuinely sufficient.

This is a real Gatekeeper bypass, not a cosmetic one — users receive a binary whose
provenance macOS never verified. For a tap advertised from the project's own README
that is an acceptable trade. Notarization remains the actual fix; this makes the
interim state clean rather than confusing.

## Components

### 1. The tap repository

**GitHub:** `Suryansh-Codes2209/homebrew-macget`
**Local:** `/Users/suryansh/Documents/Projects/Apple/homebrew-macget` (sibling to `Macget`)

This cannot live inside the Macget repo: `brew tap user/name` resolves to a GitHub
repo named literally `homebrew-name`.

Contents:

```
Casks/macget.rb
README.md
```

The fully-qualified install form (`suryansh-codes2209/macget/macget`) auto-taps, so
users never run `brew tap` as a separate step.

### 2. `Casks/macget.rb`

```ruby
cask "macget" do
  version "1.3.0"
  sha256 "..."                      # rendered by release.sh

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
    "~/Library/Application Support/Macget",
    "~/Library/Caches/com.suryansh.Macget",
    "~/Library/HTTPStorages/com.suryansh.Macget",
    "~/Library/Preferences/com.suryansh.Macget.plist",
    "~/Library/Saved Application State/com.suryansh.Macget.savedState",
  ]
end
```

The cask token is `macget` (lowercase), consistent with the project's rule that
anything a shell or filesystem reads uses lowercase `Macget`/`macget`, while `name`
carries the human-facing `MacGet`.

Decisions embedded above:

**`auto_updates true`.** MacGet updates itself through Sparkle. Without this stanza
`brew upgrade` would reinstall over an app that had already self-updated, and
Homebrew's recorded version would drift from what is on disk. With it, Homebrew
defers to Sparkle and only touches the app under `brew upgrade --greedy`. Homebrew
is the *installer*, not the updater.

**The release asset stays named `macget.dmg`.** `release.sh` builds
`dist/Macget-<version>.dmg` locally, but the asset is uploaded to GitHub as
`macget.dmg`, and the Sparkle appcast's `<enclosure url>` for 1.3.0 points at that
exact URL. Renaming published assets to get a versioned filename would break in-app
updates for anyone still on 1.2.0. The cask interpolates the git tag (`v#{version}`),
which is already unique per release, so a versioned filename buys nothing.

Creating the GitHub Release stays manual — it is where release notes get written.
But `macget.dmg` stops being an unwritten convention: `publish-cask.sh` fails with an
explicit message if the release does not carry an asset by exactly that name, so a
slip is caught at release time rather than by the first user to run `brew install`.

**`macos: :tahoe` is coarser than the real floor.** A bare recognized symbol
inherits the `>=` comparator that `depends_on macos:` passes by default
(`cask/dsl/depends_on.rb:108`, taken at `requirements/macos_requirement.rb:40-41`),
so this means "26 or later" — the string form `">= :tahoe"` is identical in meaning
but `odeprecated` in Homebrew 6.x. Either way Homebrew's macOS symbols are
major-version only (`:tahoe` → `26`), while MacGet requires 26.4. A user on
26.0–26.3 can therefore install and then find the app will not launch;
`LSMinimumSystemVersion` catches it, but at launch rather than at install. Accepted
rather than fought — the cask caveats state 26.4.

**`arch: :arm64`.** Verified against the shipped binary
(`lipo -archs Macget.app/Contents/MacOS/Macget` → `arm64`). An Intel Mac gets a
clean refusal instead of a broken install.

### 3. Release automation

`release.sh` already computes the DMG's SHA-256 and reads the version from
`Info.plist`, so it holds both cask inputs. The constraint is ordering: the SHA
embedded in the cask must match the bytes actually served at the release URL, which
do not exist until the asset is uploaded.

Split across two scripts:

- **`scripts/release.sh`** — new final step renders `dist/macget.rb` from a template
  using the version and SHA it already has.
- **`scripts/publish-cask.sh`** (new) — confirms the release carries a `macget.dmg`
  asset, checks GitHub's server-computed digest for that asset against the SHA in
  `dist/macget.rb`, then writes `Casks/macget.rb` into the local tap checkout and
  commits and pushes.

`release.sh` invokes `publish-cask.sh` automatically when the release asset is
already live, and otherwise prints the command to run after uploading.

The digest comes from `gh api repos/:owner/:repo/releases/tags/v<version>`, which
returns `digest: "sha256:…"` per asset. That is computed by GitHub over the stored
bytes, so it verifies the upload rather than the local file — a botched or truncated
upload fails loudly at release time instead of shipping a cask whose `brew install`
dies on a checksum mismatch for every user. Using the API digest rather than
re-downloading keeps the check instant; the DMG is ~139 MB.

`publish-cask.sh` resolves the tap at `../homebrew-macget` relative to the repo root
and clones it if absent, so a fresh machine needs no manual setup. Pushing through a
local checkout rather than the GitHub contents API keeps the change inspectable with
`git diff` before it goes out.

## Error handling

| Condition | Behavior |
|---|---|
| Release asset not yet uploaded | `release.sh` writes `dist/macget.rb`, prints the `publish-cask.sh` command, exits 0 |
| Release exists but has no `macget.dmg` asset | `publish-cask.sh` aborts naming the assets it did find |
| GitHub asset digest ≠ cask SHA | `publish-cask.sh` aborts before touching the tap |
| Tap checkout missing | `publish-cask.sh` clones it from GitHub |
| Tap checkout dirty | `publish-cask.sh` aborts rather than committing unrelated work |
| `gh` absent or unauthenticated | `publish-cask.sh` aborts with the auth command |

## Testing

The cask is data, not code, so verification is by execution against a real Homebrew:

1. `brew audit --cask --online Casks/macget.rb` — catches malformed stanzas, dead
   URLs, checksum mismatches.
2. `brew install --cask ./Casks/macget.rb` on a clean machine (or after
   `brew uninstall --cask macget --zap`), then confirm:
   - `Macget.app` is in `/Applications`
   - `xattr -p com.apple.quarantine /Applications/Macget.app` reports no such xattr
   - the app launches with no Gatekeeper dialog
3. `brew uninstall --cask macget --zap` — confirm the `zap` paths are actually the
   ones MacGet creates, by checking `~/Library` before and after.
4. `brew livecheck --cask macget` — confirm it resolves the current release tag.

`publish-cask.sh` gets a `--dry-run` flag that renders and diffs the cask without
committing, so the render step is testable without cutting a release.

## Out of scope

- Submission to `homebrew/cask` (blocked on notability; revisit after notarization).
- A `brew formula` (MacGet is a GUI app; casks are the correct vehicle).
- Intel or universal builds.
