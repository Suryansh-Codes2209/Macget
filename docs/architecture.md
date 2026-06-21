# MacGet architecture

This document explains how MacGet is put together — the object graph, the
download pipeline, the UI ↔ engine boundary, and resume semantics. It expands on
the summary in the project [`README.md`](../README.md); the day-to-day coding
conventions live in [`CLAUDE.md`](../CLAUDE.md).

> **Naming:** the human-facing brand is **MacGet**. Every technical identifier —
> target/scheme, bundle ID `com.suryansh.Macget`, project file `Macget.xcodeproj`,
> os.Logger subsystem `com.macget`, and on-disk paths — is lowercase **`Macget`**.
> Code in this doc uses the lowercase form because that's what the compiler sees.

The download engine is the heart of the app. Everything else is glue around it.

---

## Object graph

Constructed once in `MacgetApp.init`. `AppEnvironment`
(`Macget/App/AppEnvironment.swift`) is the dependency-injection container and owns
the long-lived collaborators:

| Component | Kind | Responsibility |
|---|---|---|
| `DownloadStore` | actor | Persists the queue as `~/Library/Application Support/Macget/queue.json`. Writes are debounced 500 ms; `flushIfNeeded()` is called explicitly at shutdown. |
| `DownloadEngine` | actor | Top-level engine. Owns all `Download` models and an `AsyncStream<EngineEvent>` the UI subscribes to. |
| `HostCapStore` | actor | Per-host parallelism memory persisted to `host_caps.json`. Learned caps ratchet downward only. |
| `UpdaterController` | class | Sparkle wrapper, gated by `#if canImport(Sparkle)` so the app builds before the SPM dependency is added. |
| `ClipboardWatcher` | `@MainActor` | Polls `NSPasteboard.general` at 1 Hz; fires a callback when a new http(s) URL appears. |
| `AppSettings` / `SettingsStore` | struct / loader | App preferences (`settings.json`, next to `queue.json`). `AppSettings` is `Codable` + `Sendable`. |

### Shutdown

`AppDelegate.applicationShouldTerminate` returns `.terminateLater` and
asynchronously calls `engine.suspendAllForShutdown()` + `store.flushIfNeeded()`
before allowing the process to exit. This must stay intact — partial-file state
and queue state desync if shutdown skips it.

---

## The download pipeline

`DownloadEngine` holds the queue and respects
`AppSettings.maxConcurrentDownloads`. For each running download it spawns a
`DownloadCoordinator` (also an actor) that owns the full lifecycle:

1. **Probe** — `RangeProbe.probe()` does a HEAD first, then falls back to
   `GET Range: bytes=0-0` (some servers 405 on HEAD). Records `totalBytes`,
   `Accept-Ranges`, `ETag`, `Last-Modified`.
2. **Disk-space check** — `DiskSpaceChecker` refuses the download if the total
   exceeds 95 % of free space at the destination.
3. **Plan chunks** — `ChunkPlanner.plan()` / `ChunkSplitter`. Threads are clamped
   to `1...20` **and** further clamped so each chunk is ≥ 64 KB
   (`minimumChunkBytes`). When the server doesn't support Range, it falls back to
   a single chunk.
4. **Allocate** — `FileWriter` (actor) opens the partial file
   `<destFolder>/.<filename>.macget-partial` and `truncate(atOffset:)`s it to the
   full size. APFS keeps the file sparse until written.
5. **Stream** — a `withThrowingTaskGroup` runs all incomplete chunks in parallel.
   Each chunk runs through `ChunkWorker` (one HTTP attempt, an
   `NSURLSession` delegate bridged into an `AsyncThrowingStream<Data>`, 64 KB
   buffered writes). The coordinator wraps each chunk in
   `processChunkWithRetries` (max 5 attempts, exponential backoff). Some
   `ChunkError` cases — `rangeRefused`, `wrongContentRange`, `chunkNotFound`,
   `writerUnavailable` — are non-retryable and fail fast.
6. **Finalize** — `FilenameResolver.uniqueURL` resolves "(2)", "(3)" suffixes if
   the destination collides, then `moveItem` promotes the `.macget-partial` file
   to its final name.

### Adaptive parallelism

Modern CDNs treat naive multi-connection downloads as leech behavior. The
coordinator adapts at runtime instead of trusting a fixed thread count:

- **Demotion.** When ≥ 4 chunk attempts fail without progress inside a 10-second
  window (the host is rejecting parallelism), the engine halves its worker count,
  cancels the lowest-progress chunks, and continues. It repeats until stable.
- **Per-host memory.** The learned cap is persisted via `HostCapStore`, so future
  downloads from that host start at the right level with no rediscovery cost.
  Caps only ratchet downward.
- **Stagger on spawn.** Workers spawn ~100 ms apart so anti-abuse middleboxes see
  a steady stream rather than a SYN burst.
- **App Nap defense.** A `ProcessInfo` activity is held while any download runs so
  macOS doesn't throttle CPU/network when the app is backgrounded.
- **Retry classification.** Permanent failures (401/403/404/410/451, range
  refusals, malformed responses) fail fast; transient errors (`-1005` mid-stream
  RSTs, `-1017` server-side stream kills, 5xx) retry with backoff under a hard
  global cap. See `RetryClassificationTests`.

### Progress reporting

A 250 ms publish loop in the coordinator emits `DownloadSnapshot` (live progress,
speed, ETA) to the engine. `SpeedMeter` (actor) keeps a 3-second rolling window
over `(date, totalBytes)` samples; ETA returns `nil` below 1 KB/s.

### Networking

`URLSessionFactory.shared` is a single process-wide `URLSession` with
`httpMaximumConnectionsPerHost = 20`, `waitsForConnectivity = true`,
`requestCachePolicy = .reloadIgnoringLocalCacheData`, and a
`Macget/<version> (macOS X.Y)` user agent. Use it everywhere — don't construct
ad-hoc sessions. `RequestHeaderPolicy` centralizes per-request headers (Range,
If-Range, etc.).

---

## UI ↔ engine boundary

The engine exposes `nonisolated let events: AsyncStream<EngineEvent>`.
`DownloadListViewModel` (`@MainActor @Observable`) drains it in `bootstrap()` and
merges `EngineEvent.added / .stateChanged / .snapshot / .removed /
.settingsChanged` into a `DownloadRowItem` array for the SwiftUI list. Snapshots
are merged *on top of* the persisted `Download` so live values (speed, ETA)
overlay terminal facts.

UI mutations always go through engine actor methods
(`pause / resume / cancel / remove / pauseAll / …`) — the UI never mutates a
`Download` directly. From the view side that's `Task { await engine.foo() }`.

---

## Resume semantics

`Download` persists `chunks: [Chunk]` with `bytesWritten` per chunk. On
`loadPersistedAndResume`:

- If `resumeOnLaunch` is true (the default), queued/downloading items are
  scheduled normally. The coordinator skips the probe + plan steps when
  `totalBytes` is already known and `chunks` is non-empty.
- If false, anything that was `downloading` is moved to `paused`.
- Workers send the recorded `etag` (or `lastModified`) as `If-Range`, so a file
  that changed server-side fails fast instead of corrupting the partial.

---

## Media downloads

`Macget/Engine/Media/` adds video/streaming support layered on top of the core
engine:

- `MediaToolLocator` / `MediaToolInstaller` find or install the bundled
  `yt-dlp` + `ffmpeg`/`ffprobe` (shipped under `Contents/Resources/bin` by the
  release build's "Embed Media Tools" phase).
- `YtDlpRunner` drives the tool; `MediaExtractionJob` turns a page URL into
  selectable `MediaFormat`s, surfaced through `MediaPickModel` / `MediaPickSheet`.

---

## Browser capture

`BrowserExtension/` (Chromium + Firefox) and `MacgetCaptureHost/` implement
native-messaging download capture. `NativeMessagingInstaller` registers the host;
`MacgetURLScheme` + `CaptureInbox` / `CaptureRequest` route captured URLs into the
add-download flow. `DownloadServicesProvider` exposes the macOS Services /
drag-and-drop entry points.

---

## Concurrency model

- `DownloadEngine`, `DownloadCoordinator`, `FileWriter`, `SpeedMeter`,
  `DownloadStore`, and `HostCapStore` are **actors**.
- View models are `@MainActor @Observable`.
- New persisted state on `Download` / `Chunk` / `AppSettings` must stay `Codable`
  **and** `Sendable`. The store does a naive read-modify-write of the whole queue
  file, so avoid adding very large fields.
- Threads/chunks are bounded to **1–20** at every layer (`Download.init` clamps,
  `ChunkPlanner` re-clamps, `AppSettings` clamps).

---

## Testing

XCTest under `MacgetTests/` covers the pure, high-stakes logic: `ChunkPlanner`,
`ChunkSplitter`, `SpeedMeter`, `FilenameResolver`, `RangeProbe`,
`RequestHeaderPolicy`, `HostCapStore`, retry classification, media extraction, and
unknown-size downloads. `MacgetUITests/` holds the XCUITest harness.

The engine has no live-network integration tests yet. When adding
network-touching tests, inject a stub `URLSession` rather than hitting the
network — `DownloadEngine`, `DownloadCoordinator`, and `ChunkWorker` all accept a
`session:` argument in their initializers.
