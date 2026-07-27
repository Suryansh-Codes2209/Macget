<p align="center">
  <img src="Macget/Resources/Branding/macget-icon.svg" width="160" alt="MacGet"/>
</p>

<h1 align="center">MacGet</h1>

<p align="center">
  <strong>A native macOS download manager that doesn't fight your network.</strong>
</p>

<p align="center">
  Multi-threaded HTTP-Range downloads with an adaptive engine that detects anti-leech CDNs, learns per-host limits, and stays out of App Nap so your downloads keep moving when you switch apps.
</p>

<p align="center">
  <a href="https://github.com/Suryansh-Codes2209/Macget/actions/workflows/ci.yml"><img src="https://github.com/Suryansh-Codes2209/Macget/actions/workflows/ci.yml/badge.svg" alt="CI"/></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-blue.svg" alt="MIT License"/></a>
  <img src="https://img.shields.io/badge/macOS-26.4%2B-black?logo=apple" alt="macOS 26.4+"/>
  <img src="https://img.shields.io/badge/swift-5.9-orange?logo=swift" alt="Swift 5.9"/>
  <img src="https://img.shields.io/badge/UI-SwiftUI-blueviolet" alt="SwiftUI"/>
</p>

> **Note:** MacGet is **not affiliated with or endorsed by** Tonec Inc. or Internet Download Manager. It's an independent free alternative.

---

## Why another download manager?

Most "multi-threaded" download managers naively open as many TCP connections as you let them. Modern CDNs treat that as leech behavior — they TCP-RST connections after a few bytes, throttle your IP, or 403 your requests. The result: more threads = slower downloads, sometimes failures.

MacGet's engine **discovers each host's true capacity at runtime** and adapts:

- **Adaptive demotion.** When ≥4 chunk attempts fail without progress in a 10-second window (i.e., the host is rejecting parallelism), the engine halves its worker count, cancels the lowest-progress chunks, and continues. Repeats until stable.
- **Per-host parallelism memory.** The learned cap is persisted to `~/Library/Application Support/Macget/host_caps.json`. Future downloads from that host start at the right level — no rediscovery cost.
- **Stagger on spawn.** Workers spawn 100 ms apart so anti-abuse middleboxes see a steady stream rather than a SYN burst from one IP.
- **App Nap defense.** A `ProcessInfo` activity is held while any download is running, so macOS doesn't throttle CPU/network when you switch apps or minimize the window.
- **Smart retry classification.** Permanent failures (401/403/404/410/451, range refusals, malformed responses) fail fast. Transient errors (-1005 mid-stream RSTs, -1017 server-side stream kills, 5xx) retry with exponential backoff inside a hard global cap.

---

## Features

- **Up to 16 parallel HTTP-Range chunks per file** (industry-standard cap; aria2 uses the same).
- **Pause / resume / cancel** with state that survives app restarts.
- **Persistent queue** — close the app, reopen, in-flight downloads continue.
- **Drag-and-drop, clipboard watch, NSServices** — paste a URL or drop a file from anywhere.
- **Live thread adjustment** while a download is running (subject to host caps).
- **Built-in book catalogs (OPDS)** — browse and search Project Gutenberg, Standard Ebooks, and the Internet Archive from inside the app, then send a book straight to the queue. Add any other OPDS feed, including your own Calibre server.
- **Auto-updates via Sparkle** — enabled and signature-verified ([details](#updates)).
- **Native SwiftUI** with proper `@Observable` view models and an actor-based engine.
- **MIT licensed.** No ads, no telemetry, no payments.

---

## Install

### From a release DMG (when v1 ships)

1. Download `Macget.dmg` from the [Releases page](https://github.com/Suryansh-Codes2209/Macget/releases/latest).
2. Open the DMG, drag Macget to Applications.
3. Launch from Applications.

**Minimum macOS:** 26.4 Tahoe.

#### First launch on macOS

Macget is currently distributed **free and un-notarized** (no paid Apple Developer
account). On first launch macOS Gatekeeper will say *"Macget can't be opened because
Apple cannot check it for malicious software."* This is expected — to open it:

1. Click **Done** on the warning.
2. Open **System Settings → Privacy & Security**, scroll down, and click **Open Anyway** next to Macget.
3. Confirm once more — Macget opens normally from then on.

Power-user one-liner instead of the steps above:

```bash
xattr -dr com.apple.quarantine /Applications/Macget.app
```

Auto-updates (via Sparkle) install smoothly after this one-time step.

### From source

```bash
git clone https://github.com/Suryansh-Codes2209/Macget.git
cd Macget
open Macget.xcodeproj
```

Then in Xcode: **⌘R** to run, **⌘U** to test. The `.xcodeproj` is committed and Sparkle is gated behind `#if canImport(Sparkle)`, so the app builds and runs without any extra setup.

To enable auto-updates (optional): **File → Add Package Dependencies… →** `https://github.com/sparkle-project/Sparkle` (≥ 2.6.0).

---

## Updates

After the first install you don't re-download MacGet from this page — it keeps
itself current with [Sparkle](https://sparkle-project.org), the standard
auto-update framework for apps distributed outside the Mac App Store.

- **Automatic.** On launch MacGet quietly checks its [appcast feed](https://suryansh-codes2209.github.io/Macget/appcast.xml) on a schedule. When a newer version is published it offers to download and install it.
- **Manual.** Any time, choose **MacGet → Check for Updates…** from the menu bar.
- **Verified.** Every update is signed with an EdDSA key; MacGet checks the signature before installing, so a tampered or corrupt download is rejected. This is independent of Apple notarization — updates are trustworthy even on the free, un-notarized build.

> Sparkle is gated behind `#if canImport(Sparkle)`. Auto-updates are active in
> release builds that bundle the Sparkle SPM dependency; a from-source build
> without it falls back to a **Check for Updates…** menu item that explains the
> dependency is missing.

**Maintainers — publishing an update:** cut a release (see
[Release a DMG](#release-a-dmg-scriptsreleasesh)), then regenerate the signed feed
with `Sparkle/bin/generate_appcast site/` and push `site/`. GitHub Pages serves
`site/appcast.xml` at the `SUFeedURL` above. The EdDSA **private** signing key
lives only in your login Keychain (*"Private key for signing Sparkle updates"*) —
[back it up offline](SETUP.md#4-optional-enable-sparkle-auto-updates), or you can
never sign another update for existing installs.

---

## Architecture

The download engine is the heart of the app; everything else is glue. Top-level flow for one download:

```
Probe (HEAD → GET Range:0-0 fallback) → Disk-space check → Plan chunks
       → Open sparse partial file → Spawn workers (staggered)
       → Stream over URLSession → 64 KB writes through FileWriter actor
       → Demote on rapid failures → Finalize → Move into place
```

Key types (under `Macget/Engine/`):

| Type | Role |
|---|---|
| `DownloadEngine` | Top-level actor. Owns all coordinators, schedules per `maxConcurrentDownloads`, emits an `AsyncStream<EngineEvent>` to the UI. |
| `DownloadCoordinator` | Per-download actor. Probes, plans, spawns workers, runs the orchestration loop, demotes on rapid failures. |
| `ChunkWorker` | One HTTP-Range request, one attempt. Streams data via an `AsyncThrowingStream` bridge over `URLSessionDataDelegate`. |
| `ChunkPlanner` / `ChunkSplitter` | Static planning: split bytes into ≥ 64 KB chunks, clamped to `Download.maxThreadCount`. |
| `FileWriter` | Actor wrapping a `FileHandle`. Serializes positional writes so concurrent chunks don't race. |
| `RangeProbe` | HEAD then ranged-GET fallback. Records `Content-Length`, `Accept-Ranges`, `ETag`, `Last-Modified`. |
| `SpeedMeter` | 3-second rolling-window throughput + ETA. |
| `HostCapStore` | Persistent per-host parallelism memory. Caps ratchet downward only. |
| `URLSessionFactory.shared` | Single process-wide `URLSession` — `responsiveData` QoS, extended background idle mode, `httpMaximumConnectionsPerHost = 16`. |

For deeper detail, read [`docs/architecture.md`](docs/architecture.md) — the full engine walkthrough, object graph, and resume semantics. [`CLAUDE.md`](CLAUDE.md) holds the day-to-day conventions for contributors.

---

## Project layout

```
Macget/
├── Macget/                       ← Swift sources
│   ├── App/                      ← AppDelegate, AppEnvironment
│   ├── Models/                   ← Download, Chunk, Status, Settings
│   ├── Persistence/              ← DownloadStore (queue.json), HostCapStore (host_caps.json)
│   ├── Engine/                   ← ★ multi-threaded download engine
│   ├── Services/                 ← Clipboard watcher, filename resolver, disk check
│   │   └── Catalog/              ← OPDS parser/client, catalog list (catalogs.json)
│   ├── Updater/                  ← Sparkle wrapper (gated)
│   ├── ViewModels/               ← @MainActor @Observable
│   ├── Views/                    ← SwiftUI
│   ├── Resources/                ← Info.plist, entitlements, Assets.xcassets, Branding/
│   └── Supporting/               ← os.Logger
├── MacgetTests/                  ← XCTest suites (46 tests)
├── MacgetUITests/                ← XCUITest harness
├── scripts/release.sh            ← build → DMG → notarize → staple
├── site/index.html               ← landing page (deploy via GitHub Pages)
├── .github/workflows/ci.yml      ← CI: build + test on push/PR
├── CHANGELOG.md
├── CLAUDE.md                     ← architecture + conventions
└── Macget.xcodeproj
```

---

## Build, test, release

### Develop

```bash
# Build
xcodebuild -project Macget.xcodeproj -scheme Macget -configuration Debug build

# Run all tests
xcodebuild test -project Macget.xcodeproj -scheme Macget -destination 'platform=macOS'

# Run one test class or method
xcodebuild test -project Macget.xcodeproj -scheme Macget -destination 'platform=macOS' \
    -only-testing:MacgetTests/ChunkPlannerTests
```

### Release a DMG (`scripts/release.sh`)

**Free, no Apple account:** run `./scripts/release.sh --no-notarize`. It builds an
ad-hoc-signed DMG (bundling yt-dlp + ffmpeg), skipping the Developer ID and
notarization steps. Sparkle auto-updates still work; users do the one-time
Gatekeeper "Open Anyway" from [First launch on macOS](#first-launch-on-macos).
This needs only `brew install create-dmg` and the Sparkle key (step 4 below).

**Notarized (frictionless install)** requires a paid Apple Developer account —
one-time setup:

1. Enroll in the [Apple Developer Program](https://developer.apple.com/programs/) ($99/yr) and install a **Developer ID Application** certificate in your Keychain.
2. Save notarization credentials:
   ```bash
   xcrun notarytool store-credentials "macget-notary" \
       --apple-id "you@example.com" \
       --team-id "YOUR-TEAM-ID" \
       --password "<app-specific password from appleid.apple.com>"
   ```
3. `brew install create-dmg`
4. Add the **Sparkle** SPM dependency in Xcode and run `bin/generate_keys`. Copy the printed public key into `Macget/Resources/Info.plist`'s `SUPublicEDKey`. **Back up the private key offline.**

Per release:

1. Bump **Marketing Version** + **Current Project Version** in Xcode's target settings.
2. Add an entry to [`CHANGELOG.md`](CHANGELOG.md).
3. Run `./scripts/release.sh` from the repo root.
4. Create a GitHub Release with the produced `dist/*.dmg` attached.
5. Run `Sparkle/bin/generate_appcast site/` and push `site/` to GitHub Pages.

The CI workflow at `.github/workflows/ci.yml` runs build + tests on every push/PR.

---

## Contributing

Issues and PRs welcome. The `Engine/` directory is the high-stakes code — please include unit tests for any change there, and mirror the actor / `@Sendable` conventions described in [`CLAUDE.md`](CLAUDE.md).

---

## License

MIT. See [LICENSE](LICENSE).
