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
}

enum CoordinatorError: Error, LocalizedError {
    case unknownContentLength
    case insufficientDiskSpace(required: Int64, available: Int64)
    case finalizeFailed(String)

    var errorDescription: String? {
        switch self {
        case .unknownContentLength:
            return "Server did not report file size."
        case .insufficientDiskSpace(let r, let a):
            return "Not enough disk space. Need \(r) bytes, have \(a)."
        case .finalizeFailed(let s):
            return "Could not move file to destination: \(s)"
        }
    }
}

/// Owns the lifecycle of a single download: probe, plan, allocate, run workers,
/// finalize. Pause/resume/cancel are exposed as async methods.
actor DownloadCoordinator {
    private(set) var download: Download
    private let session: URLSession
    private let hostCapStore: HostCapStore
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
    /// Hard ceiling on total attempts per chunk before failing the download.
    /// = 5 internal retries × ~5 respawns from the orchestration loop.
    private static let maxChunkAttempts = 25

    /// Called whenever the persisted Download state should be saved.
    let onStateChange: @Sendable (Download) async -> Void
    /// Called every ~250ms while downloading.
    let onSnapshot: @Sendable (DownloadSnapshot) async -> Void

    init(
        download: Download,
        session: URLSession = URLSessionFactory.shared,
        hostCapStore: HostCapStore = HostCapStore.shared,
        onStateChange: @escaping @Sendable (Download) async -> Void,
        onSnapshot: @escaping @Sendable (DownloadSnapshot) async -> Void
    ) {
        self.download = download
        self.session = session
        self.hostCapStore = hostCapStore
        self.onStateChange = onStateChange
        self.onSnapshot = onSnapshot
    }

    var currentDownload: Download { download }

    // MARK: - Public lifecycle

    func start() {
        guard workerTask == nil else { return }
        guard !download.status.isTerminal else { return }
        workerTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.runDownload()
                await self.complete()
            } catch is CancellationError {
                // Pause or cancel from outside; status already updated by caller.
            } catch {
                await self.fail(with: error)
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
        // 1. Probe (only if we don't already have totalBytes from a prior session).
        if download.totalBytes == nil || download.chunks.isEmpty {
            let probe = try await RangeProbe.probe(url: download.url, session: session)
            download.totalBytes = probe.totalBytes
            download.supportsRange = probe.acceptsRanges
            download.etag = probe.etag
            download.lastModified = probe.lastModified
        }

        guard let total = download.totalBytes else {
            throw CoordinatorError.unknownContentLength
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

        // 4. Plan chunks (only if not already planned by a previous run).
        //    Honor the effective cap so we don't preallocate more chunks than
        //    we'll ever run in parallel against a known-hostile host.
        if download.chunks.isEmpty {
            let plannedThreads = download.supportsRange ? effectiveThreadCount() : 1
            download.chunks = ChunkPlanner.plan(totalBytes: total, requestedThreads: plannedThreads)
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

    /// User's `threadCount`, clamped by anything tighter we've learned (this
    /// session via `demotedThreadCount`, prior sessions via `perHostCap`).
    private func effectiveThreadCount() -> Int {
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
        let maxAttempts = 5
        var attempt = 0
        while true {
            try Task.checkCancellation()
            attempt += 1
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
                case .rangeRefused, .wrongContentRange, .chunkNotFound, .writerUnavailable:
                    recordChunkError(chunkID: chunkID, error: err)
                    throw err
                case .unexpectedStatus(let code) where Self.isTerminalHTTPStatus(code):
                    recordChunkError(chunkID: chunkID, error: err)
                    throw err
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
            let backoff = UInt64(pow(2.0, Double(attempt - 1))) * 1_000_000_000
            try await Task.sleep(nanoseconds: backoff)
        }
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
        publishTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 250_000_000)
                if Task.isCancelled { break }
                await self?.publishSnapshot()
            }
        }
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

        // Resolve filename collision at destination.
        let finalURL = FilenameResolver.uniqueURL(
            in: download.destinationFolder,
            preferredName: download.filename
        )
        do {
            if FileManager.default.fileExists(atPath: finalURL.path) {
                try FileManager.default.removeItem(at: finalURL)
            }
            try FileManager.default.moveItem(at: download.partialFileURL, to: finalURL)
            if finalURL != download.destinationURL {
                download.filename = finalURL.lastPathComponent
            }
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
            case .rangeRefused, .wrongContentRange, .chunkNotFound, .writerUnavailable:
                return true
            case .unexpectedStatus(let code):
                return isTerminalHTTPStatus(code)
            case .noHttpResponse:
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
            if Self.isPermanentChunkError(error) || attempts >= Self.maxChunkAttempts {
                if pendingFatalError == nil {
                    pendingFatalError = error
                    for task in inFlight.values { task.cancel() }
                }
            }
            // Otherwise: transient. The orchestration loop respawns this chunk
            // on the next iteration, subject to the (possibly demoted) cap.
        }
        checkJoinCondition()
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
        await onStateChange(download)

        guard download.supportsRange else { return }

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
