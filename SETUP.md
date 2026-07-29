# MacGet — setup & release guide

Getting MacGet building locally takes two steps: install Xcode, open the project.
Everything else on this page is for *releasing* a signed/notarized build and is
optional until you ship.

> Naming note: the brand is **MacGet**, but the Xcode scheme, project file, and
> bundle ID are all lowercase **`Macget`** (`Macget.xcodeproj`,
> `com.suryansh.Macget`). That's intentional — use the lowercase form in commands.

---

## 1. Prerequisites

- **macOS 26.4 (Tahoe) or newer** — the deployment target. Older macOS can't run
  the app.
- **Full Xcode** (not just Command Line Tools). Install from the Mac App Store,
  open it once, accept the license, and let it install components.

Verify you're pointed at full Xcode (`xcodebuild` needs it):

```bash
xcodebuild -version
# If this errors, point the toolchain at Xcode.app:
sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
```

---

## 2. Build & run from source

The `.xcodeproj` is committed with all source references — there is **no**
project-creation or folder-dragging step. Just clone and open:

```bash
git clone https://github.com/Suryansh-Codes2209/Macget.git
cd Macget
open Macget.xcodeproj
```

In Xcode:

- **⌘R** — build and run. The window opens; click **+**, paste a test URL such as
  `https://speed.hetzner.de/100MB.bin`, and watch it download across parallel
  chunks.
- **⌘U** — run the unit tests.

Sparkle is gated behind `#if canImport(Sparkle)`, so the app builds and runs with
no extra dependencies.

### From the command line

```bash
# Build (Debug)
xcodebuild -project Macget.xcodeproj -scheme Macget -configuration Debug build

# Run all tests
xcodebuild test -project Macget.xcodeproj -scheme Macget -destination 'platform=macOS'

# Run one test class or method
xcodebuild test -project Macget.xcodeproj -scheme Macget -destination 'platform=macOS' \
    -only-testing:MacgetTests/ChunkPlannerTests
```

---

## 3. Signing notes (development)

The App Sandbox is **off** by design (see `Macget/Resources/Macget.entitlements`)
— MacGet is not destined for the Mac App Store. For Sparkle, the target uses
**Hardened Runtime** with **Disable Library Validation**.

For local development, "Sign to Run Locally" is enough. You only need a Developer
ID team to ship a notarized build (next section).

---

## 4. (Optional) Enable Sparkle auto-updates

Skip until you're preparing a release.

1. In Xcode: **File → Add Package Dependencies…** and add
   `https://github.com/sparkle-project/Sparkle` (Up to Next Major, ≥ `2.6.0`),
   target = **Macget**.
2. Generate signing keys once and back up the **private** key offline (it lives in
   your login Keychain):
   ```bash
   # path is under the resolved Sparkle artifact in DerivedData
   cd ~/Library/Developer/Xcode/DerivedData/Macget-*/SourcePackages/artifacts/sparkle/Sparkle/bin
   ./generate_keys
   ```
3. Copy the printed **public** key into `Macget/Resources/Info.plist` under
   `SUPublicEDKey`.
4. Confirm `SUFeedURL` in `Info.plist` points at your appcast (the repo ships
   `https://suryansh-codes2209.github.io/Macget/appcast.xml` — change it if you
   fork).

> **Never commit** the private key, `*.eddsa`, `.notarize.env`, `*.p12`, or
> `*.cer`. They're already in `.gitignore`.

---

## 5. (Optional) Release a DMG

### Free, no Apple account

Produces an ad-hoc-signed DMG. Sparkle auto-updates still work; users do a
one-time Gatekeeper "Open Anyway" (documented in the README's *First launch*
section).

```bash
brew install create-dmg        # one-time
./scripts/release.sh --no-notarize
```

### Notarized (frictionless install)

Requires a paid [Apple Developer Program](https://developer.apple.com/programs/)
membership ($99/yr) and a **Developer ID Application** certificate in your
Keychain. Store notarization credentials once:

```bash
xcrun notarytool store-credentials "macget-notary" \
    --apple-id "you@example.com" \
    --team-id "YOUR-TEAM-ID" \
    --password "<app-specific password from appleid.apple.com>"
```

Then, per release:

1. Bump **Marketing Version** + **Current Project Version** in the target settings.
2. Add an entry to [`CHANGELOG.md`](CHANGELOG.md).
3. Run `./scripts/release.sh` from the repo root (runs tests → builds → DMG →
   notarize → staple).
4. Create a GitHub Release and attach `dist/macget.dmg` as an asset named
   exactly `macget.dmg` — the Sparkle appcast enclosure and the Homebrew
   cask URL both depend on that exact name.
5. Run `./scripts/publish-cask.sh` to push the Homebrew cask to the tap.
6. Run `Sparkle/bin/generate_appcast site/` and push `site/` to GitHub Pages.

---

## Troubleshooting

| Symptom | Fix |
|---|---|
| `xcodebuild` can't find a project / build fails immediately | You're on Command Line Tools, not full Xcode. See step 1. |
| App opens but won't reach the network | App Sandbox must stay **off** — don't add the sandbox capability. |
| "Unidentified developer" on launch | Normal for un-notarized builds. Right-click the app → **Open**, or follow the README's *First launch* steps. |
| `@testable import Macget` fails in tests | In the test target's **Build Phases**, ensure **Host Application** is set to Macget. |
