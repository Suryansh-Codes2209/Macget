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

### Book catalogs (OPDS)

`Macget/Services/Catalog/` is a self-contained subsystem that adds **no engine work** — an OPDS acquisition link is an ordinary HTTPS URL, so downloading a book is just `engine.add(kind: .httpFile)`.

- `OPDSParser` — pure and synchronous, so every branch is testable against fixtures. Handles both OPDS 1.2 (Atom XML, via a streaming `XMLParser` delegate with namespace processing *off* — element names are matched by stripped local name so `dc:language`/`dcterms:language`/`language` all work) and OPDS 2.0 (JSON). Both paths exist because Gutenberg is retiring its XML feeds in 2027.
- `OPDSClient` — actor; owns networking only, plus a per-catalog search-template cache (discovering one costs an extra OpenSearch fetch). Sends an explicit `Accept` header: several catalogs content-negotiate and will serve HTML to a client that doesn't ask for OPDS. Resolves relative hrefs against the *final* (post-redirect) URL.
- `CatalogStore` — persists only *user-added* catalogs and *disabled* built-in IDs to `catalogs.json`. Built-ins come from `CatalogSource.builtIns` at load time, so fixing a built-in's feed URL reaches existing installs instead of being pinned by a stale file.
- `AcquisitionLink.isDownloadable` is the single gate: direct-download rel, no price, http(s), recognized format. DRM fulfilment documents (`application/vnd.adobe.adept+xml`, LCP) are parsed and displayed but never fetched — the href is a license token, not a book.

`AppEnvironment.addBook` deliberately bypasses `add(url:)`/`MediaURLClassifier`: a catalog acquisition link is already a known book file, and MacGet names it `Title - Author.epub` because catalogs routinely serve `2701.epub`.

## Conventions

- Use `Log.app/engine/ui/net` from `Supporting/Logger+MacGet.swift` (subsystem `com.macget`). Don't `print`.
- New persisted state on `Download`/`Chunk`/`AppSettings`: keep the type `Codable` and `Sendable`. The store does naive read-modify-write of the whole queue file — be aware when adding very large fields.
- Engine, Coordinator, FileWriter, SpeedMeter, DownloadStore are all actors. Mutating them from the UI goes through `Task { await engine.foo() }`. ViewModels are `@MainActor @Observable`.
- Threads/chunks are bounded to **1–20** (`Download.init` clamps; `ChunkPlanner` re-clamps; `AppSettings` clamps).
- App Sandbox is **OFF** intentionally (entitlements file). The app is not destined for the Mac App Store. Hardened Runtime + Disable Library Validation are required for Sparkle.
- Never commit notarization or Sparkle signing material: `sparkle_eddsa_priv.key`, `*.eddsa`, `.notarize.env`, `*.p12`, `*.cer` (already in `.gitignore`).

## Tests

XCTest under `MacgetTests/` (unit tests for `ChunkPlanner`, `SpeedMeter`, `FilenameResolver`) and `MacgetUITests/` (XCUITest harness). The engine itself has no integration tests yet; if adding network-touching tests, prefer injecting a stub `URLSession` over hitting the live network — `DownloadEngine`/`DownloadCoordinator`/`ChunkWorker` all accept `session:` in their initializers.
