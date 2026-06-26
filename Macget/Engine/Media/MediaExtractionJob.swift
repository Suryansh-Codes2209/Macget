import Foundation
import OSLog

/// Coordinator-equivalent for a `kind == .media` download. Drives `YtDlpRunner`
/// and reports through the same `onStateChange`/`onSnapshot` callbacks the engine
/// wires for `DownloadCoordinator`, so the UI renders media rows with no changes.
actor MediaExtractionJob {
    private(set) var download: Download
    private var tools: MediaTools
    private var runner: YtDlpRunner
    /// Subtitle/metadata/thumbnail extras applied to the yt-dlp run.
    private let options: MediaDownloadOptions
    /// When on, the finished file is filed into a type-based subfolder (Movies/Music).
    private let autoSortByType: Bool
    private var task: Task<Void, Never>?
    private var publishTask: Task<Void, Never>?
    /// Per-download temp subdirectory yt-dlp writes into; moved out + removed on
    /// success, cleaned up on cancel/fail/pause.
    private var tempDir: URL?
    private var lastSpeed: Double = 0
    private var lastEta: Double?
    /// Coarse phase surfaced to the UI. Starts in `.preparing` (covers the Deno
    /// fetch + signature solving), flips to `.downloading` on the first progress
    /// line, and to `.merging` when yt-dlp starts post-processing.
    private var currentPhase: MediaPhase = .preparing
    private let log = Logger(subsystem: "com.macget", category: "MediaExtraction")

    let onStateChange: @Sendable (Download) async -> Void
    let onSnapshot: @Sendable (DownloadSnapshot) async -> Void

    init(
        download: Download,
        tools: MediaTools,
        options: MediaDownloadOptions = .none,
        autoSortByType: Bool = false,
        onStateChange: @escaping @Sendable (Download) async -> Void,
        onSnapshot: @escaping @Sendable (DownloadSnapshot) async -> Void
    ) {
        self.download = download
        self.tools = tools
        self.options = options
        self.autoSortByType = autoSortByType
        self.runner = YtDlpRunner(tools: tools)
        self.onStateChange = onStateChange
        self.onSnapshot = onSnapshot
    }

    var currentDownload: Download { download }

    // MARK: - Lifecycle

    func start() {
        guard task == nil, !download.status.isTerminal else { return }
        task = Task { [weak self] in
            await self?.run()
        }
    }

    func pause() async {
        guard download.status == .downloading || download.status == .queued else { return }
        download.status = .paused
        await stop()
        await onStateChange(download)
    }

    func cancelAndDiscard() async {
        download.status = .cancelled
        await stop()
        await onStateChange(download)
    }

    /// App-shutdown: stop the process, mark paused, leave state for next launch.
    func suspend() async {
        if download.status == .downloading { download.status = .paused }
        await stop()
        await onStateChange(download)
    }

    private func stop() async {
        publishTask?.cancel()
        publishTask = nil
        await runner.cancel()
        task?.cancel()
        task = nil
        cleanupTempDir()
    }

    // MARK: - Core

    private func run() async {
        download.status = .downloading
        download.error = nil
        download.supportsRange = false
        // One synthetic chunk carries bytesWritten so `bytesDownloaded` works.
        if download.chunks.isEmpty {
            download.chunks = [Chunk(startByte: 0, endByte: -1)]
        }
        await onStateChange(download)
        startPublishLoop()

        // YouTube needs a JS runtime (Deno) to unscramble formats. It's fetched on
        // first use; if that fails we still try — non-YouTube sites don't need it.
        if tools.deno == nil, Self.needsJSRuntime(download.pageURL ?? download.url) {
            do {
                let deno = try await MediaToolInstaller.shared.ensureDeno()
                tools = MediaTools(ytDlp: tools.ytDlp, ffmpegDir: tools.ffmpegDir, deno: deno, source: tools.source)
                runner = YtDlpRunner(tools: tools)
            } catch is CancellationError {
                return
            } catch {
                log.warning("Deno install failed, proceeding without: \(error.localizedDescription)")
            }
        }

        do {
            let selector = download.formatSelector ?? Self.defaultSelector
            log.info("Media download starting selector=\(selector, privacy: .public)")
            // Download into a fresh temp subdirectory so yt-dlp never sees an
            // existing file (which it would silently skip, emitting no progress).
            // Then move the result into the destination with a collision-resolved
            // name, mirroring the HTTP path's `FilenameResolver.uniqueURL`.
            let tmp = download.destinationFolder.appendingPathComponent(".macget-media-\(download.id.uuidString)", isDirectory: true)
            tempDir = tmp
            let producedURL = try await runner.download(
                pageURL: download.pageURL ?? download.url,
                formatSelector: selector,
                destinationFolder: tmp,
                headers: download.requestHeaders,
                options: options,
                onProgress: { [weak self] update in
                    await self?.applyProgress(update)
                },
                onPhase: { [weak self] phase in
                    await self?.setPhase(phase)
                }
            )
            let targetFolder = categorizedDestinationFolder(for: producedURL.lastPathComponent)
            let finalURL = FilenameResolver.uniqueURL(
                in: targetFolder,
                preferredName: producedURL.lastPathComponent
            )
            try FileManager.default.moveItem(at: producedURL, to: finalURL)
            download.destinationFolder = targetFolder
            cleanupTempDir()
            await finish(finalURL: finalURL)
        } catch is CancellationError {
            // Pause/cancel from outside already set the status.
            cleanupTempDir()
        } catch {
            cleanupTempDir()
            await fail(with: error)
        }
    }

    /// Type-based subfolder for the finished media file when auto-sort is on, else
    /// the destination root. Falls back to root if the subfolder can't be created.
    private func categorizedDestinationFolder(for filename: String) -> URL {
        guard autoSortByType, let sub = CategoryFolder.subfolder(for: filename) else {
            return download.destinationFolder
        }
        let folder = download.destinationFolder.appendingPathComponent(sub, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            return folder
        } catch {
            log.warning("Auto-sort: couldn't create \(sub, privacy: .public), using root.")
            return download.destinationFolder
        }
    }

    /// Best-effort removal of the per-download temp subdirectory.
    private func cleanupTempDir() {
        guard let tempDir else { return }
        try? FileManager.default.removeItem(at: tempDir)
        self.tempDir = nil
    }

    /// yt-dlp's `bestvideo+bestaudio` muxed, falling back to a progressive stream.
    static let defaultSelector = "bestvideo*+bestaudio/best"

    /// Sites whose extraction requires running player JavaScript (Deno). YouTube
    /// is the one that hard-fails without it; gate the 130MB fetch to it.
    static func needsJSRuntime(_ url: URL) -> Bool {
        let host = (url.host ?? "").lowercased()
        return host.contains("youtube.com") || host.contains("youtu.be") || host.contains("youtube-nocookie.com")
    }

    private func applyProgress(_ update: YtDlpRunner.ProgressUpdate) async {
        currentPhase = .downloading
        download.totalBytes = update.total
        if let i = download.chunks.indices.first {
            download.chunks[i].bytesWritten = update.downloaded
        }
        lastSpeed = update.speed ?? 0
        lastEta = update.eta
    }

    private func setPhase(_ phase: MediaPhase) {
        currentPhase = phase
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
        let snap = DownloadSnapshot(
            id: download.id,
            status: download.status,
            bytesDownloaded: download.bytesDownloaded,
            totalBytes: download.totalBytes,
            speedBytesPerSec: lastSpeed,
            etaSeconds: lastEta,
            phase: currentPhase
        )
        await onSnapshot(snap)
    }

    private func finish(finalURL: URL) async {
        log.info("Media download finished: \(finalURL.lastPathComponent, privacy: .public)")
        publishTask?.cancel()
        publishTask = nil
        download.filename = finalURL.lastPathComponent
        if let size = (try? FileManager.default.attributesOfItem(atPath: finalURL.path))?[.size] as? Int64 {
            download.totalBytes = size
            if let i = download.chunks.indices.first { download.chunks[i].bytesWritten = size }
        }
        download.status = .completed
        download.completedAt = Date()
        download.error = nil
        await publishSnapshot()
        await onStateChange(download)
    }

    private func fail(with error: Error) async {
        log.error("Media extraction \(self.download.id) failed: \(error.localizedDescription)")
        publishTask?.cancel()
        publishTask = nil
        download.status = .failed
        download.error = error.localizedDescription
        await publishSnapshot()
        await onStateChange(download)
    }
}
