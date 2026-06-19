# Changelog

All notable changes to Macget. Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versions follow [SemVer](https://semver.org/).

## [1.0.0] — Unreleased

First public release.

### Added
- **Multi-threaded download engine.** Actor-based: `DownloadEngine` schedules per `maxConcurrentDownloads`; `DownloadCoordinator` owns one download's lifecycle (probe → plan → spawn → finalize); `ChunkWorker` performs one HTTP-Range request per attempt; `FileWriter` actor serializes positional writes into a sparse partial file.
- **Adaptive parallelism.** When ≥ 4 chunk attempts in a 10-second window land with < 16 KB of progress, the engine halves its effective worker count, cancels the lowest-progress chunks, and continues. Repeats until stable.
- **Per-host parallelism memory** (`HostCapStore`). Learned caps persist to `~/Library/Application Support/Macget/host_caps.json` and ratchet downward only.
- **Staggered worker spawn** (100 ms) so anti-abuse middleboxes see a steady stream rather than a burst of TCP SYNs from one IP.
- **App Nap defense.** `ProcessInfo.beginActivity` is held while any download is running; URLSession is configured with `networkServiceType = .responsiveData` and `shouldUseExtendedBackgroundIdleMode = true`. Per-task priority set to `URLSessionTask.highPriority`.
- **Smart retry classification.** Permanent errors (401/403/404/410/451, range refusals, malformed URLs) fail fast; transient errors (`-1005` network connection lost, `-1017` cannot parse response, `-1011` bad server response, 5xx, 408, 429) retry with exponential backoff. Hard global cap of 25 attempts per chunk.
- **Pause / resume across launches.** Queue persists to `~/Library/Application Support/Macget/queue.json`; chunks resume from `nextWriteOffset` on relaunch. `If-Range` validators (ETag / Last-Modified) protect against silent file changes.
- **Live thread adjustment** (1–16) with `ChunkSplitter` for adding workers mid-flight.
- **Range probe** with HEAD then `GET Range: bytes=0-0` fallback (some servers 405 on HEAD).
- **Filename collision handling**: appends `(2)`, `(3)`, … when the destination is taken.
- **Disk-space pre-check** (refuses if file > 95 % of free space at destination).
- **Native SwiftUI** UI with `@MainActor @Observable` view models.
- **NSServices, drag-and-drop, clipboard watch, `macget://` URL scheme** for adding downloads from anywhere.
- **Sparkle wrapper** behind `#if canImport(Sparkle)` so the app builds without the dependency until you add it.
- **46 unit tests** across `ChunkPlanner`, `ChunkSplitter`, `SpeedMeter`, `FilenameResolver`, `RetryClassification`, and `HostCapStore`.

### Configuration
- Default thread count: **8** per download.
- Maximum thread count: **16** per download (industry standard; matches aria2's hardcoded ceiling).
- Default max concurrent downloads: **3**.
- Minimum macOS: **26.4 Tahoe**.

### Known limitations
- Per-host caps only ratchet downward. If a host loosens its limits, you'll need to delete `~/Library/Application Support/Macget/host_caps.json` to rediscover. A "Forget host limits" UI action is on the roadmap.
- Bandwidth competition with other apps is fundamental TCP fairness — Macget signals high QoS but cannot override the OS / network layer.

[1.0.0]: https://github.com/Suryansh-Codes2209/Macget/releases/tag/v1.0.0
