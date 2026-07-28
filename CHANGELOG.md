# Changelog

All notable changes to Macget. Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versions follow [SemVer](https://semver.org/).

## [Unreleased]

### Added
- **Book catalog browsing.** A new browser (⇧⌘B) searches and browses book catalogs and sends a chosen format straight to the download queue. **Project Gutenberg** (~75k public-domain titles) and the **Internet Archive** work out of the box; any OPDS feed — including a personal Calibre server — can be added under Settings › Catalogs.
  - Downloads are named `Title - Author.epub` rather than the catalog's own `2701.epub`.
  - DRM-wrapped, priced, and loan-only editions are shown but never fetched — the detail pane explains which of the three applies.
  - Generic OPDS support covers both wire formats: 1.2 (Atom XML) and 2.0 (JSON).
  - Standard Ebooks is included but off by default: all of its OPDS feeds return 401 to anonymous clients, since access is a Patrons Circle donor benefit. Patrons can switch it on.

- **BitTorrent downloads.** Magnet links and `.torrent` files download through the queue alongside everything else, several at once, sharing the same concurrency limit, pause/resume/cancel, and quiet-hours scheduling. Add them via ⌘N, drag-and-drop, or the `magnet:` handler.
  - **Off by default.** Enabling it shows a one-time explanation: BitTorrent uploads as well as downloads, opens a listening port, and makes your IP visible to the swarm.
  - **Seeding is bounded** — ratio 1.0 or 60 minutes by default, whichever comes first, both configurable in Settings › Torrents along with an upload cap, the listening port, and DHT.
  - Rows show download *and* upload rate, and a live share ratio while seeding.
  - Internet Archive items can be fetched as a single torrent covering every file in the item — much kinder to IA than pulling files over HTTP.
  - MacGet does not search for or index torrents.

### Notes
- Torrents use aria2 as the engine. It is **not** bundled: unlike the static `ffmpeg`/`yt-dlp` builds, aria2 links against five system libraries, so MacGet installs it via Homebrew on first use instead (which also means MacGet never redistributes GPL software).
- Project Gutenberg is read through Gutendex rather than Gutenberg's own OPDS feed, whose search results are one sub-feed per book rather than direct download links.
- The Internet Archive is read through its JSON search/metadata APIs because IA retired its OPDS BookServer — `bookserver.archive.org` no longer resolves.

## [1.2.0] — 2026-06-26

Media downloads, authenticated transfers, smarter organization, and live auto-updates.

### Added
- **Media (video/audio) downloads via yt-dlp.** A conservative host-based `MediaURLClassifier` routes known video/audio sites to the bundled yt-dlp + ffmpeg extractor; ordinary links still download as plain HTTP files. A format picker lets you choose quality/container.
- **Authenticated downloads.** Keychain-backed `CredentialStore` answers Basic/Digest/NTLM challenges; an auth prompt sheet captures username/password and persists it per host so authenticated downloads keep working across launches.
- **Auto-sort into category folders.** Optional `CategoryFolder` sorting drops finished files into per-type subfolders (Video, Audio, Image, Archive, …), matching the icon shown in the list.
- **Priority-aware scheduler.** A stable `DownloadScheduler` runs higher-priority downloads first while preserving insertion order on ties.
- **Sparkle auto-updates — now enabled.** The Sparkle SPM dependency is linked, Hardened Runtime is on, and `SUPublicEDKey` is set, so release builds verify (EdDSA) and install updates from the appcast. **Check for Updates…** is live in the menu bar.

### Fixed
- `FileTypeIcon` now classifies common video/audio extensions (e.g. `.mkv`, `.webm`) explicitly, so categorization is deterministic on a clean machine instead of depending on which media apps have registered the type.

## [1.1.0] — 2026-06-22

Engine throughput, reliability, correctness, and user-control improvements.

### Added
- **Adaptive concurrency (speed-aware up-scaling).** Downloads start at 4 connections and probe upward one at a time, keeping each added connection only when aggregate throughput improves ≥ 15%. Demotion (anti-leech) and the learned per-host cap always win, so probing never fights them.
- **Work-stealing chunking.** `ChunkPlanner` slices range-capable downloads into smaller pieces than workers (8 MB target, ≤ 64 pieces); finished workers immediately steal the next outstanding piece, eliminating the "one slow chunk holds up the download" long tail.
- **HTTP/3 (QUIC)** opted into per-request via `URLRequest.assumesHTTP3Capable` (falls back to HTTP/2 → HTTP/1.1).
- **Checksum verification.** SHA-256 / MD5 verified at finalize before the partial is promoted; sourced from a `#sha256=…` / `#md5=…` URL fragment or the Add sheet. Mismatch fails the download and keeps the partial.
- **`Retry-After` + jittered backoff.** 429/503 honor the server's `Retry-After` (delta-seconds or HTTP-date); other retries use capped full-jitter exponential backoff to avoid synchronized retry storms.
- **Auto-resume on network loss.** `NWPathMonitor` pauses active downloads ("Waiting for network…") and auto-resumes when connectivity returns, instead of burning retries through an outage.
- **If-Range changed-file fallback.** A server-side file change (validator mismatch) triggers one clean restart-from-scratch instead of a hard failure.
- **Bandwidth throttling.** Optional global download speed cap (token-bucket `RateLimiter`), configurable in Settings → Downloads.
- **Download priorities.** High / Normal / Low queue priority (context-menu), with a stable priority-aware scheduler.
- **Completion notifications**, configurable **request timeout** and **per-chunk retry count**, and **HTTP/HTTPS proxy** support — all in Settings → Network.
- **Continuous disk-space guard.** Re-checks free space mid-download and pauses cleanly if the volume fills up.
- **Smart file-type icons.** The list shows video / audio / image / archive / PDF / doc / code / app / disk icons (tinted by type) with a corner status badge.
- **RFC 5987 filenames** (`filename*=UTF-8''…`) and 255-byte NFC-safe filename truncation.
- **Copy Diagnostics** context action — per-chunk attempts/errors and live concurrency state.

### Changed
- Per-chunk retry count and hard cap are now driven by the configurable retry setting (was hardcoded 5 / 25).
- The engine owns its `URLSession` and rebuilds it when the proxy / timeout settings change.

### Tests
- New suites: `RetryBackoff`, `ChecksumVerifier`, `AdaptiveConcurrency` + `ChunkPlannerPieceSizing`, `RateLimiter`, `DownloadScheduler`, `FileTypeIcon`; extended `RangeProbe` (RFC 5987) and `FilenameResolver` (truncation).

[1.1.0]: https://github.com/Suryansh-Codes2209/Macget/releases/tag/v1.1.0

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
