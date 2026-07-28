import Foundation
import OSLog

/// Lightweight progress sample emitted to the UI every ~250ms during downloads.
struct DownloadSnapshot: Sendable, Equatable {
    let id: UUID
    let status: DownloadStatus
    let bytesDownloaded: Int64
    let totalBytes: Int64?
    let speedBytesPerSec: Double
    let etaSeconds: TimeInterval?
    /// Media (yt-dlp) lifecycle phase; `nil` for normal HTTP downloads.
    var phase: MediaPhase? = nil
    /// Torrent-only live stats; `nil` for every other kind.
    var uploadSpeedBytesPerSec: Double? = nil
    var uploadedBytes: Int64? = nil
    var seeders: Int? = nil
    var peers: Int? = nil
    /// True once a torrent has finished downloading and is only seeding.
    var isSeeding: Bool = false

    /// Share ratio, or nil when nothing has been downloaded yet.
    var ratio: Double? {
        guard let uploadedBytes, bytesDownloaded > 0 else { return nil }
        return Double(uploadedBytes) / Double(bytesDownloaded)
    }
}

enum CoordinatorError: Error, LocalizedError {
    case unknownContentLength
    case insufficientDiskSpace(required: Int64, available: Int64)
    case finalizeFailed(String)
    case stalled

    var errorDescription: String? {
        switch self {
        case .unknownContentLength:
            return "Server did not report file size."
        case .insufficientDiskSpace(let r, let a):
            return "Not enough disk space. Need \(r) bytes, have \(a)."
        case .finalizeFailed(let s):
            return "Could not move file to destination: \(s)"
        case .stalled:
            return "Download stalled — no data received."
        }
    }
}

/// Owns the lifecycle of a single download: probe, plan, allocate, run workers,
/// finalize. Pause/resume/cancel are exposed as async methods.
actor DownloadCoordinator {
    private(set) var download: Download
    private let session: URLSession
    private let hostCapStore: HostCapStore
    /// Shared bandwidth limiter (nil = unlimited). Passed down to each worker.
    private let rateLimiter: RateLimiter?
    /// Guards the one-shot clean restart when the server file changed under us
    /// (validator mismatch) — see `handleRunError`.
    private var didRestartForValidatorChange = false
    private var writer: FileWriter?
    private var workerTask: Task<Void, Error>?
    private var publishTask: Task<Void, Never>?
    private let speedMeter = SpeedMeter()
    private let log = Logger(subsystem: "com.macget", category: "Coordinator")

    /// Active chunk workers, keyed by chunk UUID. New entries can be added
    /// mid-download via `adjustThreadCount` to scale parallelism live.
    private var inFlight: [UUID: Task<Void, Error>] = [:]
    private var joinContinuation: CheckedContinuation<Void, Error>?
    private var pendingFatalError: Error?

    /// Cap learned during this session from rapid connection-loss failures.
    /// Decreases monotonically — once we know a host is hostile, we don't
    /// re-test parallelism mid-download.
    private var demotedThreadCount: Int?
    /// Cap loaded from prior runs against this hostname (HostCapStore).
    private var perHostCap: Int?
    /// Sliding window of attempt failures with no progress; feeds the demotion
    /// detector.
    private var rapidFailures: [Date] = []
    /// Counts publish-loop ticks so the disk-space re-check runs every few
    /// seconds rather than on every 250ms snapshot.
    private var diskCheckCounter = 0
    /// Publish-loop ticks between mid-download disk-space re-checks (≈5s).
    private static let diskCheckEveryNTicks = 20

    /// Stall watchdog state. Detects a live-but-silent connection (zero bytes for
    /// `stallTimeoutSeconds`) and restarts the in-flight workers — distinct from the
    /// rapid-fail detector, which reacts to *failed attempts*, not silent progress.
    private var stallLastBytes: Int64 = -1
    private var stallLastProgressAt = Date()
    private var stallRestarts = 0
    /// Seconds of zero byte movement (while downloading) before a restart.
    private static let stallTimeoutSeconds: TimeInterval = 30
    /// Consecutive stall-restarts before giving up and failing the download.
    private static let maxStallRestarts = 3

    /// Adaptive concurrency: the download starts at `AdaptiveConcurrency.initialWorkers`
    /// and probes upward, keeping each added connection only when throughput
    /// improved. This ceiling grows during probing; `effectiveThreadCount()`
    /// mins it against the user/host/demotion caps so demotion always wins.
    private var adaptiveCeiling = Download.maxThreadCount
    /// Speed (B/s) sampled just before the most recent upward probe, compared
    /// against the post-probe speed to decide whether to keep climbing.
    private var probeBaselineSpeed: Double?
    /// Set once probing has settled (gain plateaued, ceiling reached, or the
    /// host was demoted) so we stop adding connections for this download.
    private var adaptiveProbeStopped = false
    /// Counts publish-loop ticks so the upscale probe runs ~every 3s (one
    /// SpeedMeter window) rather than on every snapshot.
    private var adaptiveProbeCounter = 0
    private static let adaptiveProbeEveryNTicks = 12

    /// When this many no-progress attempts land within the window, halve the
    /// effective worker count. Threshold and window picked so a fully-hostile
    /// host (every attempt fails) demotes within ~1s.
    private static let demoteThreshold = 4
    private static let rapidFailWindowSeconds: TimeInterval = 10
    /// Bytes-per-attempt below which the attempt counts as "no progress".
    private static let rapidFailProgressCutoff: Int64 = 16 * 1024
    /// Delay between consecutive worker spawns. Anti-abuse middleboxes pattern-
    /// match a burst of N TCP SYNs from one IP; staggering defeats that.
    private static let spawnStaggerNanos: UInt64 = 100_000_000  // 100 ms
    /// Internal retry attempts per worker spawn (configurable via settings).
    private let maxAttemptsPerChunk: Int
    /// Hard ceiling on total attempts per chunk before failing the download.
    /// ≈ internal retries × ~5 respawns from the orchestration loop.
    private let maxChunkAttempts: Int

    /// Retry backoff tuning. Base grows exponentially per attempt, capped so a
    /// flapping host doesn't stall for minutes. An explicit `Retry-After` is
    /// honored up to a higher ceiling (the server knows best).
    static let retryBaseDelay: TimeInterval = 1.0
    static let retryMaxDelay: TimeInterval = 30.0
    static let retryAfterMaxDelay: TimeInterval = 120.0

    /// Called whenever the persisted Download state should be saved.
    let onStateChange: @Sendable (Download) async -> Void
    /// Called every ~250ms while downloading.
    let onSnapshot: @Sendable (DownloadSnapshot) async -> Void
    /// Called when the download fails because the server demands credentials we
    /// don't have (or stored ones were rejected), so the engine can prompt.
    let onAuthRequired: (@Sendable () async -> Void)?

    init(
        download: Download,
        session: URLSession = URLSessionFactory.shared,
        hostCapStore: HostCapStore = HostCapStore.shared,
        rateLimiter: RateLimiter? = nil,
        maxAttemptsPerChunk: Int = 5,
        autoSortByType: Bool = false,
        onStateChange: @escaping @Sendable (Download) async -> Void,
        onSnapshot: @escaping @Sendable (DownloadSnapshot) async -> Void,
        onAuthRequired: (@Sendable () async -> Void)? = nil
    ) {
        self.download = download
        self.session = session
        self.hostCapStore = hostCapStore
        self.rateLimiter = rateLimiter
        self.maxAttemptsPerChunk = max(1, min(10, maxAttemptsPerChunk))
        self.maxChunkAttempts = max(1, min(10, maxAttemptsPerChunk)) * 5
        self.autoSortByType = autoSortByType
        self.onStateChange = onStateChange
        self.onSnapshot = onSnapshot
        self.onAuthRequired = onAuthRequired
    }

    /// When on, `complete()` files the result into a type-based subfolder.
    private let autoSortByType: Bool
    /// Credential for this host (Basic/Digest/NTLM), resolved at run start.
    private var resolvedCredential: URLCredential?

    var currentDownload: Download { download }

    /// Live diagnostics snapshot including the current concurrency state, which
    /// only the coordinator knows (effective workers, demotion, adaptive ceiling).
    func diagnosticsReport() -> String {
        DownloadDiagnostics.report(
            for: download,
            activeWorkers: inFlight.count,
            effectiveThreads: effectiveThreadCount(),
            demotedTo: demotedThreadCount,
            perHostCap: perHostCap,
            adaptiveCeiling: adaptiveCeiling
        )
    }

    // MARK: - Public lifecycle

    func start() {
        guard workerTask == nil else { return }
        guard !download.status.isTerminal else { return }
        workerTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.runDownload()
                // A no-size (unbounded) stream can't distinguish a user stop from a
                // real EOF, so a pause/cancel may surface as a normal return. Bail
                // here if we were cancelled rather than falsely marking it complete.
                try Task.checkCancellation()
                await self.complete()
            } catch is CancellationError {
                // Pause or cancel from outside; status already updated by caller.
            } catch {
                await self.handleRunError(error)
            }
        }
    }

    func pause() async {
        guard download.status == .downloading || download.status == .queued else { return }
        download.status = .paused
        await stopRunning()
        await onStateChange(download)
    }

    func cancelAndDiscard() async {
        download.status = .cancelled
        await stopRunning()
        try? FileManager.default.removeItem(at: download.partialFileURL)
        await onStateChange(download)
    }

    /// Stop workers but leave persisted state and partial file alone (used at app shutdown).
    func suspend() async {
        if download.status == .downloading {
            download.status = .paused
        }
        await stopRunning()
        await onStateChange(download)
    }

    private func stopRunning() async {
        publishTask?.cancel()
        publishTask = nil
        workerTask?.cancel()
        for task in inFlight.values { task.cancel() }
        if let workerTask {
            _ = await workerTask.result
        }
        workerTask = nil
        inFlight.removeAll()
        await writer?.close()
        writer = nil
    }

    // MARK: - Core orchestration

    private func runDownload() async throws {
        // Resolve any stored credential for this host (re-resolved each run, so a
        // credential entered after an auth-required prompt is picked up on resume).
        if let host = download.url.host {
            resolvedCredential = CredentialStore.shared.credential(forHost: host)
        }
        // 1. Probe (only if we don't already have totalBytes from a prior session).
        if download.totalBytes == nil || download.chunks.isEmpty {
            let probe = try await RangeProbe.probe(url: download.url, headers: download.requestHeaders, credential: resolvedCredential, session: session)
            download.totalBytes = probe.totalBytes
            download.supportsRange = probe.acceptsRanges
            download.etag = probe.etag
            download.lastModified = probe.lastModified

            // Prefer the server's filename over the URL guess (signed/CDN links
            // have junk paths), unless the user explicitly named the file. Then
            // backfill a missing extension from the MIME type. Must happen before
            // the writer opens — `partialFileURL` derives from `filename`.
            if !download.userSpecifiedFilename, let cd = probe.contentDispositionFilename {
                download.filename = FilenameResolver.sanitize(cd)
            }
            download.filename = FilenameResolver.ensuringExtension(download.filename, mimeType: probe.mimeType)
        }

        guard let total = download.totalBytes else {
            // Server never reported a size (no Content-Length / chunked transfer /
            // HEAD-blocked). Don't refuse — pull the whole body in one connection.
            try await runUnknownSizeStream()
            return
        }

        // 2. Disk space pre-check.
        if let available = DiskSpaceChecker.availableBytes(at: download.destinationFolder) {
            if total > Int64(Double(available) * 0.95) {
                throw CoordinatorError.insufficientDiskSpace(required: total, available: available)
            }
        }

        // 3. Load any cap previously learned for this host.
        if let host = download.url.host {
            perHostCap = await hostCapStore.cap(for: host)
            if let cap = perHostCap, cap < download.threadCount {
                Log.engine.info("Using learned host cap of \(cap) for \(host) (user requested \(self.download.threadCount)).")
            }
        }

        // Start conservative and probe upward (see checkAdaptiveConcurrency).
        // Bounded by the hard cap so a learned/host limit isn't exceeded.
        adaptiveCeiling = max(1, min(hardCapExcludingAdaptive(), AdaptiveConcurrency.initialWorkers))
        adaptiveProbeStopped = !download.supportsRange

        // 4. Plan chunks (only if not already planned by a previous run).
        //    Slice range-capable downloads into smaller pieces than workers so
        //    finished workers steal the next outstanding piece (work-stealing);
        //    a no-range server gets a single stream.
        if download.chunks.isEmpty {
            let plannedThreads = download.supportsRange ? hardCapExcludingAdaptive() : 1
            let pieceCap = download.supportsRange ? ChunkPlanner.defaultTargetPieceBytes : nil
            download.chunks = ChunkPlanner.plan(totalBytes: total, requestedThreads: plannedThreads, maxPieceBytes: pieceCap)
        }

        // 5. Open writer over preallocated sparse file.
        try FileManager.default.createDirectory(
            at: download.destinationFolder, withIntermediateDirectories: true
        )
        writer = try FileWriter(url: download.partialFileURL, totalBytes: total)

        // 6. Mark downloading and start the publish loop.
        download.status = .downloading
        download.error = nil
        await onStateChange(download)
        startPublishLoop()

        // 7. Orchestration loop. Spawns workers up to the effective cap, awaits
        //    them, repeats. Demotion mid-loop lowers the cap; cancelled workers
        //    drain, the next iteration spawns at the lower cap. Per-chunk byte
        //    progress is preserved across respawns via Chunk.bytesWritten.
        while !download.chunks.allSatisfy(\.isComplete) {
            try Task.checkCancellation()
            if let err = pendingFatalError {
                pendingFatalError = nil
                throw err
            }
            await fillWorkersUpToTarget()
            if inFlight.isEmpty {
                // Defensive: we have incomplete chunks but couldn't spawn any.
                // Shouldn't reach here — fillWorkersUpToTarget would have spawned
                // at least one for any incomplete chunk.
                throw ChunkError.unexpectedStatus(0)
            }
            try await waitForAllChunks()
        }
    }

    /// Download a resource whose size the server never reported. Streams a single
    /// connection with no `Range` header straight to EOF, appending sequentially.
    /// Not resumable — these servers don't support Range, so a re-run restarts
    /// from byte 0. `start()` calls `complete()` after this returns to finalize.
    private func runUnknownSizeStream() async throws {
        // Start clean: a leftover partial can't be range-resumed here.
        try? FileManager.default.removeItem(at: download.partialFileURL)

        // One synthetic chunk carries `bytesWritten` so progress/snapshots work.
        let chunk = Chunk(startByte: 0, endByte: -1)
        download.chunks = [chunk]
        download.supportsRange = false

        try FileManager.default.createDirectory(
            at: download.destinationFolder, withIntermediateDirectories: true
        )
        let writer = try FileWriter(url: download.partialFileURL, totalBytes: 0)
        self.writer = writer

        download.status = .downloading
        download.error = nil
        await onStateChange(download)
        startPublishLoop()

        let worker = ChunkWorker(
            chunk: chunk,
            url: download.url,
            etag: nil,
            lastModified: nil,
            writer: writer,
            session: session,
            headers: download.requestHeaders,
            unbounded: true,
            rateLimiter: rateLimiter,
            credential: resolvedCredential,
            report: { [weak self] id, bytes in
                await self?.reportBytes(chunkID: id, bytes: bytes)
            }
        )
        try await worker.run()

        // Clean EOF — what we wrote is the whole file. Record the now-known size
        // so finalize/snapshot show it and `fractionComplete` reads 100%.
        download.totalBytes = download.bytesDownloaded
    }

    /// User's `threadCount`, clamped by anything tighter we've learned (this
    /// session via `demotedThreadCount`, prior sessions via `perHostCap`) and by
    /// the adaptive probe's current ceiling.
    private func effectiveThreadCount() -> Int {
        min(hardCapExcludingAdaptive(), max(1, adaptiveCeiling))
    }

    /// The hard ceiling on parallelism — user request tightened by the learned
    /// per-host cap and any in-session demotion. Excludes the adaptive ceiling so
    /// the probe knows how high it's allowed to climb.
    private func hardCapExcludingAdaptive() -> Int {
        var cap = download.threadCount
        if let perHostCap { cap = min(cap, perHostCap) }
        if let demotedThreadCount { cap = min(cap, demotedThreadCount) }
        return max(1, cap)
    }

    /// Spawns workers (up to the effective target) for incomplete chunks that
    /// don't already have one. Staggers spawns by `spawnStaggerNanos` so anti-
    /// abuse middleboxes see a steady stream rather than a burst of N TCP SYNs
    /// from one IP.
    private func fillWorkersUpToTarget() async {
        let target = effectiveThreadCount()
        var spawnedThisCall = 0
        for chunk in download.chunks {
            if Task.isCancelled { return }
            if inFlight.count >= target { return }
            if chunk.isComplete { continue }
            if inFlight[chunk.id] != nil { continue }
            if spawnedThisCall > 0 {
                try? await Task.sleep(nanoseconds: Self.spawnStaggerNanos)
                if Task.isCancelled { return }
            }
            spawnWorker(chunkID: chunk.id)
            spawnedThisCall += 1
        }
    }

    private func processChunkWithRetries(chunkID: UUID) async throws {
        let maxAttempts = maxAttemptsPerChunk
        var attempt = 0
        while true {
            try Task.checkCancellation()
            attempt += 1
            // Server-supplied backoff (Retry-After) for this attempt, if any.
            var retryAfter: TimeInterval?
            let bytesBefore = chunkBytesWritten(chunkID)
            do {
                try await runChunkOnce(chunkID: chunkID)
                return
            } catch is CancellationError {
                throw CancellationError()
            } catch let err as ChunkError {
                // Some errors are non-retryable: server lied about Range support,
                // returned a wrong byte range, etc.
                switch err {
                case .rangeRefused, .wrongContentRange, .chunkNotFound, .writerUnavailable, .authRequired:
                    recordChunkError(chunkID: chunkID, error: err)
                    throw err
                case .unexpectedStatus(let code) where Self.isTerminalHTTPStatus(code):
                    recordChunkError(chunkID: chunkID, error: err)
                    throw err
                case .serverBusy(_, let ra):
                    // 429/503 — retryable; honor the server's Retry-After.
                    recordChunkError(chunkID: chunkID, error: err)
                    retryAfter = ra
                default:
                    recordChunkError(chunkID: chunkID, error: err)
                }
            } catch {
                if !Self.isRetryable(error) {
                    recordChunkError(chunkID: chunkID, error: error)
                    throw error
                }
                recordChunkError(chunkID: chunkID, error: error)
            }

            // No real progress this attempt? Likely server-side anti-leech —
            // feed the demotion detector.
            let bytesAfter = chunkBytesWritten(chunkID)
            if bytesAfter - bytesBefore < Self.rapidFailProgressCutoff {
                await noteRapidFailure()
            }

            if attempt >= maxAttempts {
                throw ChunkError.unexpectedStatus(0)
            }
            let delay = Self.retryDelaySeconds(
                attempt: attempt,
                retryAfter: retryAfter,
                random01: Double.random(in: 0..<1)
            )
            try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        }
    }

    /// Pure, testable backoff calculation. When the server gave an explicit
    /// `Retry-After`, honor it (clamped to `retryAfterMaxDelay`). Otherwise use
    /// exponential growth (`base · 2^(attempt-1)`), capped at `retryMaxDelay`,
    /// with "full jitter" in `[0.5, 1.0]·capped` to avoid synchronized retry
    /// storms across parallel chunks. `random01` is the jitter sample in `[0,1)`.
    static func retryDelaySeconds(attempt: Int, retryAfter: TimeInterval?, random01: Double) -> TimeInterval {
        if let ra = retryAfter, ra > 0 {
            return min(ra, retryAfterMaxDelay)
        }
        let exp = retryBaseDelay * pow(2.0, Double(max(0, attempt - 1)))
        let capped = min(exp, retryMaxDelay)
        let factor = 0.5 + 0.5 * min(max(random01, 0), 1)
        return capped * factor
    }

    private func chunkBytesWritten(_ id: UUID) -> Int64 {
        download.chunks.first(where: { $0.id == id })?.bytesWritten ?? 0
    }

    /// Records a no-progress attempt in the sliding window. When enough land
    /// within the window, halve the effective worker count and persist the
    /// new cap for the host so the next download starts at this level.
    private func noteRapidFailure() async {
        let now = Date()
        rapidFailures.removeAll { now.timeIntervalSince($0) > Self.rapidFailWindowSeconds }
        rapidFailures.append(now)
        guard rapidFailures.count >= Self.demoteThreshold else { return }

        let current = effectiveThreadCount()
        guard current > 1 else { return }
        let newTarget = max(1, current / 2)
        demotedThreadCount = newTarget
        rapidFailures.removeAll()
        Log.engine.warning("Anti-leech detected on \(self.download.url.host ?? "host"). Demoting workers \(current) → \(newTarget).")

        if let host = download.url.host {
            await hostCapStore.recordCap(newTarget, for: host)
        }

        cancelExcessWorkers(toRetain: newTarget)
    }

    /// Cancels the in-flight workers with the *least* progress — they're the
    /// most likely to be the ones being TCP-RSTed by the server. Survivors
    /// are the workers actually moving bytes.
    private func cancelExcessWorkers(toRetain: Int) {
        let excess = inFlight.count - toRetain
        guard excess > 0 else { return }
        let workersByProgress: [(UUID, Task<Void, Error>, Int64)] = inFlight.compactMap { id, task in
            guard let bw = download.chunks.first(where: { $0.id == id })?.bytesWritten else { return nil }
            return (id, task, bw)
        }.sorted { $0.2 < $1.2 }
        for (_, task, _) in workersByProgress.prefix(excess) {
            task.cancel()
        }
    }

    private func runChunkOnce(chunkID: UUID) async throws {
        guard let writer = self.writer else { throw ChunkError.writerUnavailable }
        guard let chunk = download.chunks.first(where: { $0.id == chunkID }) else {
            throw ChunkError.chunkNotFound
        }

        let worker = ChunkWorker(
            chunk: chunk,
            url: download.url,
            etag: download.etag,
            lastModified: download.lastModified,
            writer: writer,
            session: session,
            headers: download.requestHeaders,
            rateLimiter: rateLimiter,
            credential: resolvedCredential,
            report: { [weak self] id, bytes in
                await self?.reportBytes(chunkID: id, bytes: bytes)
            }
        )
        try await worker.run()
    }

    private func recordChunkError(chunkID: UUID, error: Error) {
        if let i = download.chunks.firstIndex(where: { $0.id == chunkID }) {
            download.chunks[i].attempts += 1
            download.chunks[i].lastError = error.localizedDescription
        }
    }

    private func reportBytes(chunkID: UUID, bytes: Int) async {
        guard let i = download.chunks.firstIndex(where: { $0.id == chunkID }) else { return }
        download.chunks[i].bytesWritten += Int64(bytes)
        await speedMeter.record(totalBytes: download.bytesDownloaded)
    }

    private func startPublishLoop() {
        publishTask?.cancel()
        diskCheckCounter = 0
        adaptiveProbeCounter = 0
        publishTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 250_000_000)
                if Task.isCancelled { break }
                await self?.publishSnapshot()
                await self?.checkDiskSpaceIfDue()
                await self?.checkAdaptiveConcurrency()
                await self?.checkStall()
            }
        }
    }

    /// Speed-aware upward scaling. Every ~3s (one SpeedMeter window) while still
    /// probing, compares current throughput to the speed measured before the last
    /// connection was added: if it improved, add one more and keep climbing; if
    /// not, settle here. Demotion or hitting the hard cap stops probing — the
    /// adaptive ceiling never overrides those (see `effectiveThreadCount`).
    private func checkAdaptiveConcurrency() async {
        guard download.status == .downloading, download.supportsRange else { return }
        guard !adaptiveProbeStopped else { return }

        adaptiveProbeCounter += 1
        guard adaptiveProbeCounter >= Self.adaptiveProbeEveryNTicks else { return }
        adaptiveProbeCounter = 0

        // Demotion always wins — once a host turns hostile, stop adding load.
        if demotedThreadCount != nil { adaptiveProbeStopped = true; return }
        let hardCap = hardCapExcludingAdaptive()
        if adaptiveCeiling >= hardCap { adaptiveProbeStopped = true; return }

        let speedNow = await speedMeter.currentSpeed()
        guard speedNow > 0 else { return }  // wait for a usable reading

        if let baseline = probeBaselineSpeed {
            if AdaptiveConcurrency.didImprove(speedBefore: baseline, speedAfter: speedNow) {
                adaptiveCeiling = min(hardCap, adaptiveCeiling + 1)
                probeBaselineSpeed = speedNow
                growWorkers()
                if adaptiveCeiling >= hardCap { adaptiveProbeStopped = true }
            } else {
                // The last added connection didn't pay off — settle and stop.
                adaptiveProbeStopped = true
            }
        } else {
            // Establish a baseline at the current ceiling, then add one to test.
            probeBaselineSpeed = speedNow
            adaptiveCeiling = min(hardCap, adaptiveCeiling + 1)
            growWorkers()
        }
    }

    /// Spawns workers up to the (just-raised) effective cap, one per outstanding
    /// piece. Called when the adaptive ceiling grows mid-download.
    private func growWorkers() {
        while inFlight.count < effectiveThreadCount(),
              let next = download.chunks.first(where: { !$0.isComplete && inFlight[$0.id] == nil }) {
            spawnWorker(chunkID: next.id)
        }
    }

    /// Periodically re-checks free space while downloading. The pre-flight check
    /// can't catch a volume filling up from another process during a long
    /// download; if the bytes still to fetch no longer fit, pause cleanly with a
    /// clear error (keeping the partial) instead of crashing on a write failure.
    private func checkDiskSpaceIfDue() async {
        guard download.status == .downloading else { return }
        diskCheckCounter += 1
        guard diskCheckCounter >= Self.diskCheckEveryNTicks else { return }
        diskCheckCounter = 0

        guard let total = download.totalBytes else { return }  // unknown size: nothing to compare
        let remaining = max(0, total - download.bytesDownloaded)
        guard remaining > 0 else { return }
        guard let available = DiskSpaceChecker.availableBytes(at: download.destinationFolder) else { return }

        if remaining > Int64(Double(available) * 0.98) {
            Log.engine.warning("Low disk for \(self.download.filename): need \(remaining) more bytes, \(available) free. Pausing.")
            download.error = CoordinatorError.insufficientDiskSpace(required: remaining, available: available).errorDescription
            await pause()
        }
    }

    /// Watchdog for a connection that's alive but delivering nothing. When bytes
    /// haven't moved for `stallTimeoutSeconds`, cancel the in-flight workers so the
    /// orchestration loop respawns them from their recorded offsets (the same drain-
    /// and-respawn path demotion uses). After `maxStallRestarts` with no recovery,
    /// fail cleanly via the orchestration loop (set `pendingFatalError`, cancel all).
    private func checkStall() async {
        guard download.status == .downloading, !download.chunks.isEmpty else { return }
        let now = Date()
        let bytes = download.bytesDownloaded
        if bytes > stallLastBytes {
            stallLastBytes = bytes
            stallLastProgressAt = now
            stallRestarts = 0
            return
        }
        guard now.timeIntervalSince(stallLastProgressAt) >= Self.stallTimeoutSeconds else { return }
        // Nothing in flight → orchestration is between waves; let it respawn. Just
        // re-arm the timer so we don't immediately fire again.
        guard !inFlight.isEmpty else { stallLastProgressAt = now; return }

        if stallRestarts >= Self.maxStallRestarts {
            Log.engine.warning("\(self.download.filename) stalled — giving up after \(Self.maxStallRestarts) restart(s).")
            if pendingFatalError == nil {
                pendingFatalError = CoordinatorError.stalled
                for task in inFlight.values { task.cancel() }
            }
            return
        }
        stallRestarts += 1
        stallLastProgressAt = now
        Log.engine.warning("\(self.download.filename) stalled \(Int(Self.stallTimeoutSeconds))s — restarting \(self.inFlight.count) worker(s) [\(self.stallRestarts)/\(Self.maxStallRestarts)].")
        for task in inFlight.values { task.cancel() }
    }

    private func publishSnapshot() async {
        let speed = await speedMeter.currentSpeed()
        let eta: TimeInterval?
        if let total = download.totalBytes {
            eta = await speedMeter.eta(totalBytes: total)
        } else {
            eta = nil
        }
        let snap = DownloadSnapshot(
            id: download.id,
            status: download.status,
            bytesDownloaded: download.bytesDownloaded,
            totalBytes: download.totalBytes,
            speedBytesPerSec: speed,
            etaSeconds: eta
        )
        await onSnapshot(snap)
    }

    private func complete() async {
        publishTask?.cancel()
        publishTask = nil
        await writer?.close()
        writer = nil

        // Integrity gate: verify the finished partial against an expected digest
        // before it's promoted to the final name. A mismatch fails the download
        // and leaves the (corrupt) partial in place for inspection rather than
        // handing the user a silently-wrong file.
        if let expected = download.expectedChecksum, let alg = download.checksumAlgorithm {
            do {
                try ChecksumVerifier.verify(
                    fileAt: download.partialFileURL,
                    expectedHex: expected,
                    algorithm: alg
                )
            } catch {
                await fail(with: error)
                return
            }
        }

        // Pick the destination folder: optionally a type-based subfolder. If the
        // subfolder can't be created, fall back to the root rather than failing.
        let targetFolder = categorizedDestinationFolder()
        // Resolve filename collision at the (possibly categorized) destination.
        let finalURL = FilenameResolver.uniqueURL(
            in: targetFolder,
            preferredName: download.filename
        )
        do {
            if FileManager.default.fileExists(atPath: finalURL.path) {
                try FileManager.default.removeItem(at: finalURL)
            }
            try FileManager.default.moveItem(at: download.partialFileURL, to: finalURL)
            // Keep destinationFolder/filename consistent so destinationURL (Open /
            // Reveal) points at the real location after categorization.
            download.destinationFolder = targetFolder
            download.filename = finalURL.lastPathComponent
        } catch {
            await fail(with: CoordinatorError.finalizeFailed(error.localizedDescription))
            return
        }
        download.status = .completed
        download.completedAt = Date()
        download.error = nil
        await publishSnapshot()
        await onStateChange(download)
    }

    /// The folder the completed file should land in: a type-based subfolder when
    /// auto-sort is on and the file has a known category, else the destination root.
    private func categorizedDestinationFolder() -> URL {
        guard autoSortByType, let sub = CategoryFolder.subfolder(for: download.filename) else {
            return download.destinationFolder
        }
        let folder = download.destinationFolder.appendingPathComponent(sub, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            return folder
        } catch {
            log.warning("Auto-sort: couldn't create \(sub, privacy: .public), using root: \(error.localizedDescription)")
            return download.destinationFolder
        }
    }

    /// Distinguish a user-initiated stop (which surfaces as `URLError.cancelled`
    /// once the URLSession task is cancelled) from a genuine failure. On a stop,
    /// the caller has already set `.paused`/`.cancelled`, so we leave it alone.
    private func handleRunError(_ error: Error) async {
        if Task.isCancelled || (error as? URLError)?.code == .cancelled {
            return
        }
        // The server's copy changed under us (If-Range validator no longer
        // matches → it answered 200 to our ranged request). The partial is now
        // stale; restart once from byte 0 with a fresh probe rather than failing.
        if !didRestartForValidatorChange, Self.isValidatorChange(error, download: download) {
            didRestartForValidatorChange = true
            Log.engine.warning("Source file changed for \(self.download.filename) (validator mismatch). Restarting from scratch.")
            await restartFromScratch()
            return
        }
        // Server needs credentials we don't have — fail, but ask the engine to
        // prompt so the user can supply them and resume.
        if Self.isAuthRequired(error) {
            await onAuthRequired?()
        }
        await fail(with: error)
    }

    /// True for a 401/407 surfaced from the probe or a chunk worker.
    static func isAuthRequired(_ error: Error) -> Bool {
        if let ce = error as? ChunkError, case .authRequired = ce { return true }
        if let pe = error as? RangeProbeError, case .authRequired = pe { return true }
        return false
    }

    /// A `rangeRefused` after we'd recorded a validator means the file changed
    /// server-side (not that the server lacks Range support — we only send
    /// `If-Range` when a validator exists).
    static func isValidatorChange(_ error: Error, download: Download) -> Bool {
        guard download.supportsRange, download.etag != nil || download.lastModified != nil else { return false }
        if let ce = error as? ChunkError, case .rangeRefused = ce { return true }
        return false
    }

    /// Discards the partial and all planning so a fresh run re-probes and
    /// re-downloads cleanly. Runs *inline* inside the existing worker task — it
    /// must NOT call `stopRunning()` (which awaits that same task and would
    /// deadlock), so it tears down workers/writer directly.
    private func restartFromScratch() async {
        publishTask?.cancel(); publishTask = nil
        for t in inFlight.values { t.cancel() }
        inFlight.removeAll()
        await writer?.close(); writer = nil
        pendingFatalError = nil

        try? FileManager.default.removeItem(at: download.partialFileURL)
        download.chunks = []
        download.totalBytes = nil
        download.etag = nil
        download.lastModified = nil
        await speedMeter.reset()

        do {
            try await runDownload()
            try Task.checkCancellation()
            await complete()
        } catch is CancellationError {
            // Paused/cancelled during the restart — caller already set status.
        } catch {
            await fail(with: error)
        }
    }

    private func fail(with error: Error) async {
        log.error("Download \(self.download.id) failed: \(error.localizedDescription)")
        publishTask?.cancel()
        publishTask = nil
        await writer?.close()
        writer = nil
        download.status = .failed
        download.error = error.localizedDescription
        await publishSnapshot()
        await onStateChange(download)
    }

    static func isRetryable(_ error: Error) -> Bool {
        let nsErr = error as NSError
        if nsErr.domain == NSURLErrorDomain {
            switch nsErr.code {
            case NSURLErrorTimedOut,
                 NSURLErrorCannotConnectToHost,
                 NSURLErrorNetworkConnectionLost,
                 NSURLErrorNotConnectedToInternet,
                 NSURLErrorDNSLookupFailed,
                 NSURLErrorResourceUnavailable,
                 NSURLErrorRequestBodyStreamExhausted,
                 NSURLErrorZeroByteResource,
                 // Server killed an in-flight response (e.g. Cloudflare Worker
                 // execution-time limit). Worth one more attempt.
                 NSURLErrorCannotParseResponse,
                 NSURLErrorBadServerResponse:
                return true
            default:
                return false
            }
        }
        return true
    }

    /// HTTP status codes that won't change on retry. 408 (timeout) and 429
    /// (rate limit) are intentionally excluded — those are transient.
    static func isTerminalHTTPStatus(_ code: Int) -> Bool {
        switch code {
        case 401, 403, 404, 410, 451:
            return true
        default:
            return false
        }
    }

    /// True when the error is permanent (server said no, definitively). Drives
    /// the chunkFinished decision: permanent → fail the download; transient →
    /// let the orchestration loop respawn the worker, possibly at lower cap.
    static func isPermanentChunkError(_ error: Error) -> Bool {
        if let ce = error as? ChunkError {
            switch ce {
            case .rangeRefused, .wrongContentRange, .chunkNotFound, .writerUnavailable, .authRequired:
                return true
            case .unexpectedStatus(let code):
                return isTerminalHTTPStatus(code)
            case .noHttpResponse, .serverBusy:
                return false
            }
        }
        let nsErr = error as NSError
        if nsErr.domain == NSURLErrorDomain {
            switch nsErr.code {
            case NSURLErrorBadURL, NSURLErrorUnsupportedURL:
                return true
            default:
                return !isRetryable(error)
            }
        }
        return false
    }

    // MARK: - Dynamic worker management

    private func spawnWorker(chunkID: UUID) {
        let task = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.processChunkWithRetries(chunkID: chunkID)
                await self.chunkFinished(chunkID: chunkID, error: nil)
            } catch {
                await self.chunkFinished(chunkID: chunkID, error: error)
                throw error
            }
        }
        inFlight[chunkID] = task
    }

    private func chunkFinished(chunkID: UUID, error: Error?) {
        inFlight.removeValue(forKey: chunkID)
        if let error, !(error is CancellationError) {
            let attempts = download.chunks.first(where: { $0.id == chunkID })?.attempts ?? 0
            // Permanent → fail the whole download. Hard attempt cap → also fail
            // (otherwise a hopelessly broken chunk would respawn forever).
            if Self.isPermanentChunkError(error) || attempts >= maxChunkAttempts {
                if pendingFatalError == nil {
                    pendingFatalError = error
                    for task in inFlight.values { task.cancel() }
                }
            }
            // Otherwise: transient. The orchestration loop respawns this chunk
            // on the next iteration, subject to the (possibly demoted) cap.
        }
        // Work-stealing: a cleanly-finished worker immediately grabs the next
        // outstanding piece instead of idling until the whole wave drains. Skip
        // when tearing down (fatal) — `checkJoinCondition` handles that path.
        if error == nil, pendingFatalError == nil {
            fillFreedSlot()
        }
        checkJoinCondition()
    }

    /// Spawns one worker for the next incomplete, unassigned piece if we're below
    /// the effective cap. Used for work-stealing as pieces complete.
    private func fillFreedSlot() {
        guard download.status == .downloading else { return }
        guard inFlight.count < effectiveThreadCount() else { return }
        guard let next = download.chunks.first(where: { !$0.isComplete && inFlight[$0.id] == nil }) else { return }
        spawnWorker(chunkID: next.id)
    }

    /// Resumes the orchestration loop's `waitForAllChunks` whenever inFlight
    /// drains. The loop then decides whether to spawn replacements (chunks
    /// still incomplete) or exit (all complete).
    private func checkJoinCondition() {
        guard let cont = joinContinuation else { return }
        guard inFlight.isEmpty else { return }
        joinContinuation = nil
        if let err = pendingFatalError {
            pendingFatalError = nil
            cont.resume(throwing: err)
        } else {
            cont.resume()
        }
    }

    private func waitForAllChunks() async throws {
        if inFlight.isEmpty {
            if let err = pendingFatalError {
                pendingFatalError = nil
                throw err
            }
            return
        }
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            self.joinContinuation = cont
        }
    }

    // MARK: - Dynamic threading (live adjust)

    /// Re-target the number of parallel chunks. When increasing, repeatedly halves
    /// the largest in-flight chunk (IDM's "in-half division rule"). When decreasing,
    /// drains naturally — extra workers finish their assigned ranges, no cancellation.
    func adjustThreadCount(_ target: Int) async {
        let clamped = max(1, min(Download.maxThreadCount, target))
        download.threadCount = clamped
        // The user took manual control — pin the adaptive ceiling to their choice
        // and stop probing so it doesn't override the explicit setting.
        adaptiveCeiling = clamped
        adaptiveProbeStopped = true
        await onStateChange(download)

        guard download.supportsRange else { return }

        // Prefer assigning idle workers to already-planned outstanding pieces
        // (work-stealing model) before resorting to splitting an in-flight chunk.
        growWorkers()

        while inFlight.count < clamped {
            guard let decision = ChunkSplitter.nextSplit(chunks: download.chunks) else { break }
            // Cancel the original chunk's worker. We replace its dict entry with a
            // fresh-UUID chunk so the cancelled task's chunkFinished only removes
            // its own dead entry, not the newly-spawned one.
            if let oldTask = inFlight.removeValue(forKey: decision.originalID) {
                oldTask.cancel()
            }
            download.chunks[decision.originalIndex] = decision.shrunken
            spawnWorker(chunkID: decision.shrunken.id)
            download.chunks.append(decision.newChunk)
            spawnWorker(chunkID: decision.newChunk.id)
        }
        await onStateChange(download)
    }
}
