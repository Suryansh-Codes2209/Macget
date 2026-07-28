# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project

Macget is a SwiftUI/macOS multi-threaded download manager. Single Xcode project at the repo root; sources are committed Swift files (the `.xcodeproj` is also committed). No Swift Package Manager build — Xcode/`xcodebuild` only.

## Build, run, test

```bash
# Build (Debug)
xcodebuild -project Macget.xcodeproj -scheme Macget -configuration Debug build

# Run all tests
xcodebuild test -project Macget.xcodeproj -scheme Macget -destination 'platform=macOS'

# Run a single test (class or method)
xcodebuild test -project Macget.xcodeproj -scheme Macget -destination 'platform=macOS' \
    -only-testing:MacgetTests/ChunkPlannerTests
xcodebuild test -project Macget.xcodeproj -scheme Macget -destination 'platform=macOS' \
    -only-testing:MacgetTests/ChunkPlannerTests/test_evenSplit

# Release / signed / notarized DMG (one-time setup required — see scripts/release.sh header)
./scripts/release.sh
```

Interactive dev: open `Macget.xcodeproj` in Xcode and ⌘R / ⌘U.

## Naming & docs caveats

- **Two casings, by design.** Every *technical identifier* — code, Xcode target/scheme, project file (`Macget.xcodeproj`), bundle ID (`com.suryansh.Macget`), os.Logger subsystem (`com.macget`), produced artifacts (`Macget.app`, `Macget-<version>.dmg`), and on-disk paths — uses lowercase **`Macget`**. The *human-facing brand* — README headings/tagline, the marketing site under `frontend/`, `site/index.html`, and the SVG wordmark — is **`MacGet`** (capital G). Rule of thumb: anything a compiler, shell, or the filesystem reads is `Macget`; anything a person reads as the product name is `MacGet`. The README's Install/First-launch section intentionally keeps `Macget` because it refers to the literal app bundle and the verbatim macOS Gatekeeper dialog. (`scripts/release.sh` already uses the correct `Macget` `SCHEME`/`PROJECT` — the old "release.sh will fail" note is obsolete.)
- The app's Finder display name is currently the bundle name `Macget`. To make the launched app and Gatekeeper read `MacGet`, set `CFBundleDisplayName` = `MacGet` in `Info.plist` (not yet done — it changes the Gatekeeper string and DMG label, so weigh it before a release).
- Build setup is just "open `Macget.xcodeproj` and ⌘R" — the `.xcodeproj` is committed with all source references. `SETUP.md` is a lean contributor/release guide; the old "create a fresh project + symlink folders" workflow is gone.
- Architecture is documented in [`docs/architecture.md`](docs/architecture.md) (linked from the README) and summarized in the Architecture section below.
- Minimum macOS is **26.4 (Tahoe)** — set in both `MACOSX_DEPLOYMENT_TARGET` and `Info.plist`'s `LSMinimumSystemVersion`. Don't lower without confirming the codebase doesn't depend on Tahoe-only APIs.

## Architecture

The download engine is the heart of the app. Everything else is glue around it.

### Object graph (constructed once in `MacgetApp.init`)

`AppEnvironment` (`Macget/App/AppEnvironment.swift`) is the DI container. It owns:

- `DownloadStore` — actor; persists the queue as `~/Library/Application Support/Macget/queue.json`. Writes are debounced 500ms; `flushIfNeeded()` is called explicitly at app shutdown.
- `DownloadEngine` — top-level actor; owns all `Download` models and an `AsyncStream<EngineEvent>` that the UI subscribes to.
- `UpdaterController` — Sparkle wrapper, gated by `#if canImport(Sparkle)` so the app still builds before the SPM dep is added.
- `ClipboardWatcher` — `@MainActor`; polls `NSPasteboard.general` 1Hz, fires a callback when a new http(s) URL appears.
- `AppSettings` (struct) loaded/saved by `SettingsStore` (`settings.json` next to `queue.json`).

`AppDelegate.applicationShouldTerminate` returns `.terminateLater` and asynchronously calls `engine.suspendAllForShutdown()` + `store.flushIfNeeded()` before allowing the process to exit. Don't break this — partial-file state and queue state will desync if shutdown skips it.

### The download pipeline (one file)

`DownloadEngine` (actor) holds the queue and respects `AppSettings.maxConcurrentDownloads`. For each running download it spawns a `DownloadCoordinator` (also an actor) that owns the lifecycle:

1. **Probe** — `RangeProbe.probe()` does HEAD first, falls back to `GET Range: bytes=0-0` (some servers 405 on HEAD). Records `totalBytes`, `Accept-Ranges`, `ETag`, `Last-Modified`.
2. **Disk-space check** — refuses if total > 95% of free space at the destination.
3. **Plan chunks** — `ChunkPlanner.plan()`. Threads clamped to `1...20` AND further clamped so each chunk is ≥ 64KB (`minimumChunkBytes`). When the server doesn't support Range, falls back to one chunk.
4. **Allocate** — `FileWriter` (actor) opens the partial file `<destFolder>/.<filename>.macget-partial` and `truncate(atOffset:)`s to the full size. APFS keeps it sparse.
5. **Stream** — `withThrowingTaskGroup` runs all incomplete chunks in parallel. Each chunk runs through `ChunkWorker` (one HTTP attempt, NSURLSession delegate bridging into `AsyncThrowingStream<Data>`, 64KB buffered writes). The Coordinator wraps each chunk in `processChunkWithRetries` (max 5 attempts, exponential backoff). Some `ChunkError` cases (`rangeRefused`, `wrongContentRange`, `chunkNotFound`, `writerUnavailable`) are non-retryable.
6. **Finalize** — `FilenameResolver.uniqueURL` resolves "(2)", "(3)" suffixes if the destination collides, then `moveItem` from `.macget-partial` to the final name.

A 250ms publish loop in the Coordinator emits `DownloadSnapshot` (live progress/speed/ETA) to the engine. `SpeedMeter` (actor) is a 3-second rolling window over `(date, totalBytes)` samples; ETA returns nil below 1 KB/s.

`URLSessionFactory.shared` is a single process-wide `URLSession` with `httpMaximumConnectionsPerHost = 20`, `waitsForConnectivity = true`, `requestCachePolicy = .reloadIgnoringLocalCacheData`, and a `Macget/<version> (macOS X.Y)` UA. Use it everywhere — don't construct ad-hoc sessions.

### UI ↔ engine boundary

The engine exposes `nonisolated let events: AsyncStream<EngineEvent>`. `DownloadListViewModel` (`@MainActor @Observable`) drains it in `bootstrap()` and merges `EngineEvent.added/.stateChanged/.snapshot/.removed/.settingsChanged` into a `DownloadRowItem` array for the SwiftUI list. Snapshots are merged on top of the persisted `Download` so live values (speed, ETA) overlay terminal facts.

UI mutations always go through engine actor methods (`pause/resume/cancel/remove/pauseAll/...`) — never mutate `Download` from the UI side.

### Resume semantics

`Download` persists `chunks: [Chunk]` with `bytesWritten` per chunk. On `loadPersistedAndResume`:

- If `resumeOnLaunch` is true (default), queued/downloading items are scheduled normally. The Coordinator skips the probe + plan steps when `totalBytes` is already known and `chunks` is non-empty.
- If false, anything that was `downloading` is moved to `paused`.
- Workers send the recorded `etag` (or `lastModified`) as `If-Range` so a changed file fails-fast instead of corrupting the partial.

### BitTorrent (`Macget/Engine/Torrent/`)

The third `DownloadKind`. `TorrentJob` is the structural twin of `MediaExtractionJob` — it drives an external process and reports through the same `onStateChange`/`onSnapshot` callbacks, so the list view renders torrent rows with no restructuring. Progress rides on a single synthetic `Chunk`, exactly as media does.

- **aria2 is not bundled.** Unlike the static `ffmpeg`/`yt-dlp` builds in `Vendor/bin`, aria2 links against `openssl@3`, `libssh2`, `c-ares`, `sqlite`, and `gettext`, so vendoring it would mean re-pathing and notarizing five dylibs. `TorrentToolLocator` finds a system copy and `TorrentToolInstaller` installs one via Homebrew on demand. Side benefit: MacGet never redistributes aria2, so its GPL carries no obligation here.
- **One daemon for all torrents.** `Aria2Daemon` is a singleton actor: lazy start on the first torrent, `aria2.shutdown` when the last goes inactive and at app termination (wired into `suspendAllForShutdown`). RPC binds to **loopback only** on an ephemeral port with a fresh 256-bit secret per launch.
- **MacGet owns the queue, not aria2.** `--save-session`/`--input-file` are deliberately absent: `queue.json` is the source of truth and MacGet re-adds torrents itself, so letting aria2 restore its own session would register each info hash twice and aria2 fails the duplicate outright. Resume comes from `--continue=true` plus the `.aria2` control file, with `--bt-save-metadata` so a resumed magnet needn't re-fetch metadata.
- **Magnets have a metadata phase.** The first GID downloads only the metainfo (a few hundred KB) and reaches `complete` with `completedLength == totalLength` — indistinguishable from a finished download. `isAwaitingMetadata` suppresses completion and byte reporting until `followedBy` hands off to the real GID; the metainfo totals are then cleared so the child's real size replaces them. Getting this wrong marks a 6 GB torrent "Completed" at 500 KB.
- **Ports are ranges, not single values** (`6881-6890`). A single value makes aria2 fail with "Errors occurred while binding port" whenever another client holds it.
- Torrents are gated behind `AppSettings.torrentsEnabled` (off by default) and a first-run acknowledgement — unlike media extraction, which is switched on silently. BitTorrent uploads on the user's connection, so it always asks.

### Book catalogs

`Macget/Services/Catalog/` is a self-contained subsystem that adds **no engine work** — a book acquisition link is an ordinary HTTPS URL, so downloading one is just `engine.add(kind: .httpFile)`.

**Three backends, one model.** Everything produces a `CatalogFeed`, and `CatalogService` dispatches on `CatalogSource.kind` so `BookBrowserModel` never branches. Two of the three exist because the obvious OPDS endpoints don't work — verified against the live services, not assumed:

- **`.gutendex`** → Project Gutenberg. Its *own* OPDS search returns **navigation** entries (one `/ebooks/<id>.opds` sub-feed per result), so getting a download link would cost a request per book — and those per-book feeds were returning 504s. `search.opds2` is a 404. Gutendex returns every format's direct URL inline, which is what a grid needs.
- **`.archiveOrg`** → Internet Archive. **IA retired its OPDS BookServer; `bookserver.archive.org` no longer resolves at all.** Replaced by `advancedsearch.php?output=json` (browse/search) plus `metadata/<id>/files` (per-item file list). File lists are fetched lazily on selection — resolving them for a 50-result page would mean 50 extra requests. `CatalogService.resolveAcquisitions` is that hook, and is a no-op for the other kinds.
- **`.opds`** → everything else, including user-added Calibre servers. `OPDSParser` is pure and synchronous so every branch is fixture-testable; it handles OPDS 1.2 (Atom XML, via a streaming `XMLParser` delegate with namespace processing *off* — matched by stripped local name so `dc:language`/`dcterms:language`/`language` all work) and OPDS 2.0 (JSON). `OPDSClient` sends an explicit `Accept` header because several catalogs content-negotiate to HTML otherwise, and resolves relative hrefs against the *final* (post-redirect) URL.

Standard Ebooks ships as a built-in but **disabled**: every one of its OPDS feeds (`/feeds/opds`, `/all`, `/new-releases`) returns 401 to anonymous clients — access is a Patrons Circle donor benefit. Hence `CatalogStore` tracks *both* explicitly-enabled and explicitly-disabled built-in IDs, so a built-in's shipped default applies until the user expresses a preference.

Other invariants:

- `AcquisitionLink.isDownloadable` is the single gate: direct-download rel, no price, http(s), recognized format. DRM fulfilment documents are parsed and displayed but never fetched — the href is a license token, not a book. This matters most on archive.org, which lists `LCP Encrypted EPUB` / `ACS Encrypted PDF` right beside the free files.
- `URLSessionFactory.metadata` (not `.shared`) backs all catalog requests. `.shared` sets `waitsForConnectivity = true` and `timeoutIntervalForResource = .infinity` — correct for a multi-gigabyte download, but it makes a dead catalog URL spin forever behind a UI spinner.
- `AppEnvironment.addBook` deliberately bypasses `add(url:)`/`MediaURLClassifier`: a catalog acquisition link is already a known book file, and MacGet names it `Title - Author.epub` because catalogs routinely serve `2701.epub`.

## Conventions

- Use `Log.app/engine/ui/net` from `Supporting/Logger+MacGet.swift` (subsystem `com.macget`). Don't `print`.
- New persisted state on `Download`/`Chunk`/`AppSettings`: keep the type `Codable` and `Sendable`. The store does naive read-modify-write of the whole queue file — be aware when adding very large fields.
- Engine, Coordinator, FileWriter, SpeedMeter, DownloadStore are all actors. Mutating them from the UI goes through `Task { await engine.foo() }`. ViewModels are `@MainActor @Observable`.
- Threads/chunks are bounded to **1–20** (`Download.init` clamps; `ChunkPlanner` re-clamps; `AppSettings` clamps).
- App Sandbox is **OFF** intentionally (entitlements file). The app is not destined for the Mac App Store. Hardened Runtime + Disable Library Validation are required for Sparkle.
- Never commit notarization or Sparkle signing material: `sparkle_eddsa_priv.key`, `*.eddsa`, `.notarize.env`, `*.p12`, `*.cer` (already in `.gitignore`).

## Tests

XCTest under `MacgetTests/` (unit tests for `ChunkPlanner`, `SpeedMeter`, `FilenameResolver`) and `MacgetUITests/` (XCUITest harness). The engine itself has no integration tests yet; if adding network-touching tests, prefer injecting a stub `URLSession` over hitting the live network — `DownloadEngine`/`DownloadCoordinator`/`ChunkWorker` all accept `session:` in their initializers.
