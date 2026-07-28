import Foundation
import OSLog

/// Coordinator-equivalent for a `kind == .torrent` download.
///
/// Structural twin of `MediaExtractionJob`: it drives an external process (here
/// the shared `aria2c` daemon, over JSON-RPC) and reports through the same
/// `onStateChange`/`onSnapshot` callbacks the engine wires for
/// `DownloadCoordinator`, so the list view renders torrent rows unchanged.
actor TorrentJob {
    private(set) var download: Download
    private let options: TorrentEngineOptions
    private let daemon: Aria2Daemon

    /// aria2's handle for this download. Reassigned when a magnet's metadata
    /// resolves — aria2 completes the metadata GID and spawns a new one for the
    /// real transfer, reported via `followedBy`.
    private var gid: String?
    private var client: Aria2RPCClient?
    private var pollTask: Task<Void, Never>?
    private let log = Logger(subsystem: "com.macget", category: "TorrentJob")

    /// Set while the user asked to pause/cancel, so a poll in flight doesn't
    /// clobber the resulting state.
    private var isStopping = false

    /// True between adding a magnet and following aria2's metadata handoff.
    ///
    /// A magnet's first GID downloads only the *metainfo* (a few hundred KB).
    /// That GID reaches `complete` with `completedLength == totalLength`, which
    /// looks exactly like a finished download — mark the row complete there and
    /// the real multi-gigabyte transfer never gets reported at all.
    private var isAwaitingMetadata = false

    let onStateChange: @Sendable (Download) async -> Void
    let onSnapshot: @Sendable (DownloadSnapshot) async -> Void

    /// Matches `DownloadCoordinator`'s publish cadence so the UI updates at one
    /// rate regardless of download kind.
    private static let pollInterval = Duration.milliseconds(250)

    init(
        download: Download,
        options: TorrentEngineOptions,
        daemon: Aria2Daemon = .shared,
        onStateChange: @escaping @Sendable (Download) async -> Void,
        onSnapshot: @escaping @Sendable (DownloadSnapshot) async -> Void
    ) {
        self.download = download
        self.options = options
        self.daemon = daemon
        self.onStateChange = onStateChange
        self.onSnapshot = onSnapshot
    }

    var currentDownload: Download { download }

    // MARK: - Lifecycle

    func start() async {
        guard pollTask == nil, !download.status.isTerminal else { return }
        // Torrents report one aggregate progress number, so a single synthetic
        // chunk carries it — same trick `MediaExtractionJob` uses.
        if download.chunks.isEmpty {
            download.chunks = [Chunk(startByte: 0, endByte: -1)]
        }
        isStopping = false

        do {
            let client = try await daemon.client(options: options)
            self.client = client
            let gid = try await add(using: client)
            self.gid = gid
            download.status = .downloading
            download.error = nil
            await onStateChange(download)
            startPolling()
        } catch {
            await fail(with: error)
        }
    }

    private func add(using client: Aria2RPCClient) async throws -> String {
        var options: [String: String] = ["dir": download.destinationFolder.path]
        // Honour an existing file selection across a resume.
        if let files = download.torrentFiles, !files.isEmpty {
            let selected = files.filter(\.selected).map { String($0.index) }
            // Selecting nothing would download nothing; treat it as "everything".
            if !selected.isEmpty, selected.count != files.count {
                options["select-file"] = selected.joined(separator: ",")
            }
        }

        if let data = download.torrentFileData {
            // A .torrent carries its own metainfo, so there's no metadata phase.
            isAwaitingMetadata = false
            return try await client.addTorrent(data, options: options)
        }
        isAwaitingMetadata = true
        return try await client.addURI(download.url.absoluteString, options: options)
    }

    private func startPolling() {
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let keepGoing = await self.poll()
                if !keepGoing { return }
                try? await Task.sleep(for: Self.pollInterval)
            }
        }
    }

    // MARK: - Polling

    /// One status poll. Returns false when the job has reached a terminal state
    /// and polling should stop.
    private func poll() async -> Bool {
        guard !isStopping, let client, let gid else { return false }

        let status: Aria2Status
        do {
            status = try await client.tellStatus(gid: gid)
        } catch {
            // A transport blip shouldn't kill a running torrent; a persistent
            // failure will surface when the daemon is gone.
            if case Aria2Error.rpc = error {
                await fail(with: error)
                return false
            }
            return true
        }

        // Magnet metadata resolved: aria2 finishes the metadata GID and hands off
        // to a new one. Follow it, otherwise progress freezes at 0 forever.
        if let next = status.followedBy.first {
            self.gid = next
            isAwaitingMetadata = false
            // The metadata GID's totals describe the metainfo, not the content.
            // Clear them so the child's real size replaces them cleanly.
            download.totalBytes = nil
            if let index = download.chunks.indices.first {
                download.chunks[index].bytesWritten = 0
            }
            log.info("Following metadata handoff \(gid, privacy: .public) → \(next, privacy: .public)")
            return true
        }

        // While only metainfo is moving, report an indeterminate "preparing"
        // state rather than the metainfo's own byte counts.
        if isAwaitingMetadata {
            if status.isError {
                await fail(with: Self.friendlyError(status.errorMessage))
                return false
            }
            await onSnapshot(
                DownloadSnapshot(
                    id: download.id,
                    status: .downloading,
                    bytesDownloaded: 0,
                    totalBytes: nil,
                    speedBytesPerSec: 0,
                    etaSeconds: nil,
                    phase: .preparing
                )
            )
            return true
        }

        await adoptMetadata(from: status)

        if status.isError {
            await fail(with: Self.friendlyError(status.errorMessage))
            return false
        }
        if status.isRemoved {
            return false
        }

        let downloaded = status.completedLength
        if let index = download.chunks.indices.first {
            download.chunks[index].bytesWritten = downloaded
        }
        download.uploadedBytes = status.uploadLength

        // "Complete" for a torrent means the *download* finished. aria2 keeps the
        // GID active while seeding, so MacGet reports completion but leaves the
        // job running until aria2 stops it at the ratio/time limit.
        let seeding = status.isComplete || (status.totalLength > 0 && downloaded >= status.totalLength)

        await onSnapshot(
            DownloadSnapshot(
                id: download.id,
                status: seeding ? .completed : .downloading,
                bytesDownloaded: downloaded,
                totalBytes: status.totalLength > 0 ? status.totalLength : nil,
                speedBytesPerSec: Double(status.downloadSpeed),
                etaSeconds: Self.eta(total: status.totalLength, done: downloaded, speed: status.downloadSpeed),
                uploadSpeedBytesPerSec: Double(status.uploadSpeed),
                uploadedBytes: status.uploadLength,
                seeders: status.numSeeders,
                peers: status.connections,
                isSeeding: seeding
            )
        )

        if seeding, download.status != .completed {
            download.status = .completed
            download.completedAt = Date()
            if download.totalBytes == nil, status.totalLength > 0 {
                download.totalBytes = status.totalLength
            }
            await onStateChange(download)
            // Keep polling: uploads continue until aria2 hits the seed limit, and
            // the row should keep showing the ratio climb.
        }
        return true
    }

    /// Copy torrent metadata onto the model the first time aria2 reports it, and
    /// **publish** the result.
    ///
    /// Publishing is the whole point: snapshots carry live progress, but the
    /// torrent's real name and file list are persisted model state. Without an
    /// `onStateChange` here the row keeps its provisional name forever and the
    /// file-selection sheet never populates.
    private func adoptMetadata(from status: Aria2Status) async {
        var changed = false

        if let hash = status.infoHash, download.torrentInfoHash != hash {
            download.torrentInfoHash = hash
            changed = true
        }
        if let name = status.name, !name.isEmpty, !download.userSpecifiedFilename {
            let sanitized = FilenameResolver.sanitize(name)
            if download.filename != sanitized {
                download.filename = sanitized
                changed = true
            }
        }
        if download.totalBytes != status.totalLength, status.totalLength > 0 {
            download.totalBytes = status.totalLength
            changed = true
        }
        if download.torrentFiles == nil, !status.files.isEmpty {
            download.torrentFiles = status.files.map {
                TorrentFileEntry(index: $0.index, path: $0.path, length: $0.length, selected: $0.selected)
            }
            changed = true
        }

        if changed {
            await onStateChange(download)
        }
    }

    /// Turn aria2's internal wording into something a user can act on.
    static func friendlyError(_ message: String?) -> Error {
        guard let message, !message.isEmpty else {
            return Aria2Error.rpc(code: -1, message: "torrent failed")
        }
        if message.contains("is already registered") {
            return Aria2Error.rpc(
                code: -1,
                message: "This torrent is already in the queue."
            )
        }
        return Aria2Error.rpc(code: -1, message: message)
    }

    static func eta(total: Int64, done: Int64, speed: Int64) -> TimeInterval? {
        // Below 1 KB/s the estimate is noise — same threshold as `SpeedMeter`.
        guard total > 0, speed > 1024, done < total else { return nil }
        return TimeInterval(total - done) / TimeInterval(speed)
    }

    // MARK: - Control

    func pause() async {
        isStopping = true
        pollTask?.cancel()
        pollTask = nil
        if let client, let gid {
            // Best-effort: a torrent aria2 has already dropped is fine to "fail"
            // to pause — MacGet's own state is the source of truth for the row.
            _ = try? await client.pause(gid: gid)
        }
        guard !download.status.isTerminal else { return }
        download.status = .paused
        await onStateChange(download)
    }

    func resume() async {
        guard download.status == .paused || download.status == .failed else { return }
        // aria2 keeps paused downloads in its queue, so unpause is enough — but
        // after a relaunch the GID is gone and we re-add instead.
        if let client, let gid, (try? await client.unpause(gid: gid)) != nil {
            isStopping = false
            download.status = .downloading
            download.error = nil
            await onStateChange(download)
            startPolling()
            return
        }
        await start()
    }

    func cancel() async {
        isStopping = true
        pollTask?.cancel()
        pollTask = nil
        if let client, let gid {
            _ = try? await client.forceRemove(gid: gid)
            try? await client.removeDownloadResult(gid: gid)
        }
        guard !download.status.isTerminal else { return }
        download.status = .cancelled
        await onStateChange(download)
    }

    /// Stop polling without changing state — used at app shutdown, where the
    /// daemon persists its own session and will resume on next launch.
    func suspendForShutdown() async {
        isStopping = true
        pollTask?.cancel()
        pollTask = nil
    }

    private func fail(with error: Error) async {
        pollTask?.cancel()
        pollTask = nil
        guard !download.status.isTerminal else { return }
        download.status = .failed
        download.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        log.error("Torrent \(self.download.id, privacy: .public) failed: \(self.download.error ?? "", privacy: .public)")
        await onStateChange(download)
    }
}
