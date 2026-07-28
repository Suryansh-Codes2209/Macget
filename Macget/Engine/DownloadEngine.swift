import Foundation
import OSLog
import Network

/// Events emitted to the UI ViewModel.
enum EngineEvent: Sendable {
    case added(Download)
    case stateChanged(Download)
    case snapshot(DownloadSnapshot)
    case removed(UUID)
    case settingsChanged(AppSettings)
}

/// Top-level actor that owns all downloads. Schedules them respecting
/// `AppSettings.maxConcurrentDownloads`. Persists state changes to a `DownloadStore`.
actor DownloadEngine {
    private var downloads: [UUID: Download] = [:]
    private var coordinators: [UUID: DownloadCoordinator] = [:]
    /// Media (`kind == .media`) downloads run via yt-dlp instead of the chunked
    /// coordinator. Tracked separately but surfaced through the same events.
    private var extractors: [UUID: MediaExtractionJob] = [:]
    /// Torrents (`kind == .torrent`) run through the shared aria2 daemon. Held
    /// separately from coordinators/extractors but counted in the same
    /// `maxConcurrentDownloads` budget.
    private var torrents: [UUID: TorrentJob] = [:]
    private var insertionOrder: [UUID] = []
    private var settings: AppSettings

    private let store: DownloadStore
    /// Rebuilt when the proxy / request-timeout setting changes (only when the
    /// engine owns it — an injected session, e.g. in tests, is left alone).
    private var session: URLSession
    private let ownsSession: Bool
    /// Shared bandwidth limiter handed to every coordinator/worker.
    private let rateLimiter: RateLimiter
    private let log = Logger(subsystem: "com.macget", category: "Engine")

    /// Watches network reachability so a dropped connection pauses active
    /// downloads into a holding state and auto-resumes them when the network
    /// returns — instead of burning retries through an outage.
    private var pathMonitor: NWPathMonitor?
    private var networkPausedIDs: Set<UUID> = []
    private var lastPathSatisfied = true

    /// Quiet-hours scheduling. A periodic timer pauses active downloads when the
    /// window closes and resumes them when it reopens. Held separately from
    /// `networkPausedIDs` so an item paused by both stays paused until both clear.
    private var scheduleTimer: Task<Void, Never>?
    private var scheduledPausedIDs: Set<UUID> = []

    /// Held while at least one download is active. Prevents macOS App Nap from
    /// throttling CPU/network when the user switches focus or minimizes the
    /// window. Released once no coordinators are running.
    private var activityToken: NSObjectProtocol?

    private let eventsContinuation: AsyncStream<EngineEvent>.Continuation
    nonisolated let events: AsyncStream<EngineEvent>

    /// Invoked (on the main actor side) when a download needs credentials, so the
    /// app can prompt the user. Set once by `AppEnvironment`.
    private var authHandler: (@Sendable (UUID, String) async -> Void)?

    init(store: DownloadStore, settings: AppSettings, session: URLSession? = nil) {
        self.store = store
        self.settings = settings
        if let session {
            self.session = session
            self.ownsSession = false
        } else {
            self.session = URLSessionFactory.makeSession(
                requestTimeout: TimeInterval(settings.requestTimeoutSeconds),
                proxyHost: settings.proxyHost,
                proxyPort: settings.proxyPort
            )
            self.ownsSession = true
        }
        self.rateLimiter = RateLimiter(bytesPerSecond: settings.globalSpeedLimitBytesPerSec)
        var continuation: AsyncStream<EngineEvent>.Continuation!
        self.events = AsyncStream { c in continuation = c }
        self.eventsContinuation = continuation
    }

    // MARK: - Public API

    /// Load persisted downloads and (per settings) auto-resume the unfinished ones.
    func loadPersistedAndResume() async {
        startNetworkMonitoring()
        startScheduleTimer()
        let persisted = await store.load()
        for d in persisted {
            downloads[d.id] = d
            insertionOrder.append(d.id)
            eventsContinuation.yield(.added(d))
        }
        if settings.resumeOnLaunch {
            await scheduleNextDownloads()
        } else {
            // Mark anything that was running as paused.
            for (id, var d) in downloads where d.status == .downloading {
                d.status = .paused
                downloads[id] = d
                await store.upsert(d)
                eventsContinuation.yield(.stateChanged(d))
            }
        }
    }

    /// Register the credential-prompt handler. Called once at startup.
    func setAuthHandler(_ handler: @escaping @Sendable (UUID, String) async -> Void) {
        authHandler = handler
    }

    func updateSettings(_ newSettings: AppSettings) async {
        let oldMax = settings.maxConcurrentDownloads
        let sessionChanged = newSettings.requestTimeoutSeconds != settings.requestTimeoutSeconds
            || newSettings.proxyHost != settings.proxyHost
            || newSettings.proxyPort != settings.proxyPort
        settings = newSettings
        await rateLimiter.setLimit(newSettings.globalSpeedLimitBytesPerSec)
        if ownsSession, sessionChanged {
            session = URLSessionFactory.makeSession(
                requestTimeout: TimeInterval(newSettings.requestTimeoutSeconds),
                proxyHost: newSettings.proxyHost,
                proxyPort: newSettings.proxyPort
            )
            log.info("Rebuilt URLSession for new proxy/timeout settings (applies to new downloads).")
        }
        eventsContinuation.yield(.settingsChanged(newSettings))
        // Push seeding/bandwidth changes to a live aria2 daemon. Port changes are
        // launch-only and take effect the next time it starts.
        await Aria2Daemon.shared.applyOptions(newSettings.torrentOptions)
        // A schedule change (enabled/window) may open or close the window right now.
        await evaluateSchedule()
        if newSettings.maxConcurrentDownloads > oldMax {
            await scheduleNextDownloads()
        }
    }

    /// Add a brand-new download. Returns the assigned ID.
    @discardableResult
    func add(
        url: URL,
        destinationFolder: URL,
        filename: String? = nil,
        userSpecifiedFilename: Bool = false,
        threadCount: Int? = nil,
        startImmediately: Bool? = nil,
        requestHeaders: [String: String]? = nil,
        checksum: ChecksumSpec? = nil
    ) async -> UUID {
        let resolvedThreads = threadCount ?? settings.defaultThreadCount
        let dest = destinationFolder
        let resolvedName = filename ?? (url.lastPathComponent.isEmpty ? "download" : url.lastPathComponent)
        // Prefer an explicitly-supplied checksum (Add sheet); otherwise fall back
        // to a `#sha256=…`/`#md5=…` URL fragment. The fragment is client-side only
        // (never sent on the wire), so it's a safe sidecar for the digest.
        let checksum = checksum ?? ChecksumSpec.parse(fragment: url.fragment)
        let download = Download(
            url: url,
            destinationFolder: dest,
            filename: resolvedName,
            threadCount: resolvedThreads,
            userSpecifiedFilename: userSpecifiedFilename,
            requestHeaders: RequestHeaderPolicy.sanitizeInbound(requestHeaders),
            expectedChecksum: checksum?.hex,
            checksumAlgorithm: checksum?.algorithm
        )
        downloads[download.id] = download
        insertionOrder.append(download.id)
        await store.upsert(download)
        eventsContinuation.yield(.added(download))

        let auto = startImmediately ?? settings.startDownloadsAutomatically
        if auto {
            await scheduleNextDownloads()
        }
        return download.id
    }

    /// Add a media download (YouTube / video page) to be resolved by yt-dlp.
    /// `pageURL` is the watch page; `filename`/`totalBytes` are provisional until
    /// the extractor reports the real values.
    @discardableResult
    func addMedia(
        pageURL: URL,
        mediaURL: URL? = nil,
        destinationFolder: URL,
        title: String? = nil,
        formatSelector: String? = nil,
        requestHeaders: [String: String]? = nil,
        startImmediately: Bool? = nil
    ) async -> UUID {
        let provisionalName = title.map(FilenameResolver.sanitize)
            ?? (pageURL.host.map { "\($0) video" } ?? "video")
        let download = Download(
            url: mediaURL ?? pageURL,
            destinationFolder: destinationFolder,
            filename: provisionalName,
            requestHeaders: RequestHeaderPolicy.sanitizeInbound(requestHeaders),
            kind: .media,
            pageURL: pageURL,
            formatSelector: formatSelector
        )
        downloads[download.id] = download
        insertionOrder.append(download.id)
        await store.upsert(download)
        eventsContinuation.yield(.added(download))

        let auto = startImmediately ?? settings.startDownloadsAutomatically
        if auto {
            await scheduleNextDownloads()
        }
        return download.id
    }

    /// Add a torrent from a magnet URI or a `.torrent` file's bytes.
    ///
    /// `filename` is provisional — aria2 reports the real torrent name once BEP-9
    /// metadata arrives, and `TorrentJob` adopts it.
    @discardableResult
    func addTorrent(
        magnet: URL? = nil,
        torrentData: Data? = nil,
        destinationFolder: URL,
        suggestedName: String? = nil,
        startImmediately: Bool? = nil
    ) async -> UUID? {
        guard magnet != nil || torrentData != nil else { return nil }
        let link = magnet.flatMap(MagnetLink.parse)
        let name = suggestedName ?? link?.provisionalName ?? "Torrent"
        let download = Download(
            url: magnet ?? URL(string: "torrent:local")!,
            destinationFolder: destinationFolder,
            filename: FilenameResolver.sanitize(name),
            totalBytes: link?.exactLength,
            kind: .torrent,
            torrentInfoHash: link?.infoHash,
            torrentFileData: torrentData
        )
        downloads[download.id] = download
        insertionOrder.append(download.id)
        await store.upsert(download)
        eventsContinuation.yield(.added(download))

        let auto = startImmediately ?? settings.startDownloadsAutomatically
        if auto {
            await scheduleNextDownloads()
        }
        return download.id
    }

    /// Replace a torrent's file selection and restart it so aria2 picks up the
    /// new `--select-file`. Only meaningful before/while downloading.
    func updateTorrentFileSelection(_ id: UUID, selectedIndices: Set<Int>) async {
        guard var d = downloads[id], d.kind == .torrent, let files = d.torrentFiles else { return }
        d.torrentFiles = files.map { file in
            var copy = file
            copy.selected = selectedIndices.contains(file.index)
            return copy
        }
        downloads[id] = d
        await store.upsert(d)
        eventsContinuation.yield(.stateChanged(d))

        if let job = torrents[id] {
            await job.cancel()
            torrents.removeValue(forKey: id)
            var restarted = d
            restarted.status = .queued
            restarted.error = nil
            downloads[id] = restarted
            await store.upsert(restarted)
            eventsContinuation.yield(.stateChanged(restarted))
            await scheduleNextDownloads()
        }
    }

    func pause(_ id: UUID) async {
        if let coord = coordinators[id] {
            await coord.pause()
            // Coordinator's onStateChange will sync `downloads[id]`.
        } else if let job = extractors[id] {
            await job.pause()
        } else if let job = torrents[id] {
            await job.pause()
        } else if var d = downloads[id], d.status == .queued {
            d.status = .paused
            downloads[id] = d
            await store.upsert(d)
            eventsContinuation.yield(.stateChanged(d))
        }
        await scheduleNextDownloads()
    }

    func resume(_ id: UUID) async {
        guard let d = downloads[id] else { return }
        guard d.status == .paused || d.status == .failed else {
            // Already running / completed / cancelled
            return
        }
        var updated = d
        updated.status = .queued
        updated.error = nil
        downloads[id] = updated
        await store.upsert(updated)
        eventsContinuation.yield(.stateChanged(updated))
        await scheduleNextDownloads()
    }

    func cancel(_ id: UUID) async {
        if let coord = coordinators[id] {
            await coord.cancelAndDiscard()
        } else if let job = extractors[id] {
            await job.cancelAndDiscard()
        } else if let job = torrents[id] {
            await job.cancel()
        } else if var d = downloads[id] {
            d.status = .cancelled
            downloads[id] = d
            try? FileManager.default.removeItem(at: d.partialFileURL)
            await store.upsert(d)
            eventsContinuation.yield(.stateChanged(d))
        }
        coordinators.removeValue(forKey: id)
        extractors.removeValue(forKey: id)
        torrents.removeValue(forKey: id)
        updateActivityState()
        await scheduleNextDownloads()
    }

    /// Removes a download from the queue. If active, cancels first. Optionally deletes the file on disk.
    func remove(_ id: UUID, deleteFile: Bool = false) async {
        if coordinators[id] != nil || extractors[id] != nil || torrents[id] != nil {
            await cancel(id)
        }
        if let d = downloads[id] {
            if deleteFile {
                try? FileManager.default.removeItem(at: d.destinationURL)
            }
            try? FileManager.default.removeItem(at: d.partialFileURL)
        }
        downloads.removeValue(forKey: id)
        insertionOrder.removeAll { $0 == id }
        coordinators.removeValue(forKey: id)
        extractors.removeValue(forKey: id)
        torrents.removeValue(forKey: id)
        updateActivityState()
        await store.delete(id)
        eventsContinuation.yield(.removed(id))
        await scheduleNextDownloads()
    }

    func pauseAll() async {
        for id in coordinators.keys {
            await coordinators[id]?.pause()
        }
        for id in extractors.keys {
            await extractors[id]?.pause()
        }
        for id in torrents.keys {
            await torrents[id]?.pause()
        }
        for (id, var d) in downloads where d.status == .queued {
            d.status = .paused
            downloads[id] = d
            await store.upsert(d)
            eventsContinuation.yield(.stateChanged(d))
        }
    }

    func resumeAll() async {
        for (id, d) in downloads where d.status == .paused || d.status == .failed {
            var updated = d
            updated.status = .queued
            updated.error = nil
            downloads[id] = updated
            await store.upsert(updated)
            eventsContinuation.yield(.stateChanged(updated))
        }
        await scheduleNextDownloads()
    }

    func clearCompleted() async {
        let toRemove = downloads.values.filter { $0.status == .completed }.map(\.id)
        for id in toRemove {
            await remove(id, deleteFile: false)
        }
    }

    /// Called from AppDelegate on app termination.
    func suspendAllForShutdown() async {
        pathMonitor?.cancel()
        pathMonitor = nil
        scheduleTimer?.cancel()
        scheduleTimer = nil
        for id in coordinators.keys {
            await coordinators[id]?.suspend()
        }
        for id in extractors.keys {
            await extractors[id]?.suspend()
        }
        // Torrents stop polling, then aria2 is asked to exit cleanly — killing it
        // instead would lose its session file and in-flight piece state.
        for id in torrents.keys {
            await torrents[id]?.suspendForShutdown()
        }
        if !torrents.isEmpty {
            await Aria2Daemon.shared.shutdown()
        }
        if let token = activityToken {
            ProcessInfo.processInfo.endActivity(token)
            activityToken = nil
        }
    }

    func currentDownloads() -> [Download] {
        insertionOrder.compactMap { downloads[$0] }
    }

    /// Apply a user-chosen manual queue order. Unknown IDs are ignored and any
    /// existing IDs not in `orderedIDs` are appended (kept in their prior order),
    /// so a stale UI order can never drop downloads. Persists immediately and
    /// reschedules — a reorder can change which queued item takes a free slot.
    func reorder(_ orderedIDs: [UUID]) async {
        var seen = Set<UUID>()
        var newOrder: [UUID] = []
        for id in orderedIDs where downloads[id] != nil {
            if seen.insert(id).inserted { newOrder.append(id) }
        }
        for id in insertionOrder where !seen.contains(id) {
            newOrder.append(id)
        }
        insertionOrder = newOrder
        await store.replaceAllImmediately(currentDownloads())
        await scheduleNextDownloads()
    }

    // MARK: - Network reachability

    private func startNetworkMonitoring() {
        guard pathMonitor == nil else { return }
        let monitor = NWPathMonitor()
        pathMonitor = monitor
        monitor.pathUpdateHandler = { [weak self] path in
            let satisfied = path.status == .satisfied
            Task { await self?.handleNetworkPath(satisfied: satisfied) }
        }
        monitor.start(queue: DispatchQueue(label: "com.macget.network-monitor"))
    }

    private func handleNetworkPath(satisfied: Bool) async {
        guard satisfied != lastPathSatisfied else { return }
        lastPathSatisfied = satisfied

        if !satisfied {
            // Snapshot ids first — pausing mutates `coordinators` via its callback.
            let activeIDs = coordinators.keys.filter { downloads[$0]?.status == .downloading }
            guard !activeIDs.isEmpty else { return }
            log.warning("Network lost — pausing \(activeIDs.count) active download(s) until it returns.")
            for id in activeIDs {
                guard let coord = coordinators[id] else { continue }
                networkPausedIDs.insert(id)
                await coord.pause()
                if var d = downloads[id] {
                    d.error = "Waiting for network…"
                    downloads[id] = d
                    await store.upsert(d)
                    eventsContinuation.yield(.stateChanged(d))
                }
            }
        } else {
            let toResume = networkPausedIDs
            networkPausedIDs.removeAll()
            guard !toResume.isEmpty else { return }
            log.info("Network restored — resuming \(toResume.count) download(s).")
            for id in toResume {
                await resumeFromHold(id)
            }
        }
    }

    // MARK: - Quiet-hours scheduling

    /// Whether downloads are currently allowed to run, per the quiet-hours setting.
    private var scheduleWindowOpen: Bool {
        guard settings.scheduleEnabled else { return true }
        return DownloadWindow.isOpen(
            now: DownloadWindow.minutesNow(Date()),
            start: settings.scheduleStartMinutes,
            end: settings.scheduleEndMinutes
        )
    }

    private func startScheduleTimer() {
        guard scheduleTimer == nil else { return }
        scheduleTimer = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 30_000_000_000)   // 30s tick
                if Task.isCancelled { break }
                await self?.evaluateSchedule()
            }
        }
    }

    /// Pause active downloads when the window closes; resume scheduler-paused ones
    /// when it reopens. Only resumes IDs *we* paused, and only if no other hold
    /// (network) still applies — so a manually-paused item is never auto-resumed.
    private func evaluateSchedule() async {
        if scheduleWindowOpen {
            if !scheduledPausedIDs.isEmpty {
                let toResume = scheduledPausedIDs
                scheduledPausedIDs.removeAll()
                log.info("Quiet hours ended — resuming \(toResume.count) download(s).")
                for id in toResume { await resumeFromHold(id) }
            }
            // Pick up anything queued while the window was closed (e.g. at launch).
            await scheduleNextDownloads()
        } else {
            let activeIDs = coordinators.keys.filter { downloads[$0]?.status == .downloading }
                + extractors.keys.filter { downloads[$0]?.status == .downloading }
            guard !activeIDs.isEmpty else { return }
            log.info("Quiet hours started — pausing \(activeIDs.count) active download(s).")
            for id in activeIDs {
                scheduledPausedIDs.insert(id)
                if let coord = coordinators[id] {
                    await coord.pause()
                } else if let job = extractors[id] {
                    await job.pause()
                } else if let job = torrents[id] {
                    await job.pause()
                }
                if var d = downloads[id] {
                    d.error = "Outside scheduled hours"
                    downloads[id] = d
                    await store.upsert(d)
                    eventsContinuation.yield(.stateChanged(d))
                }
            }
        }
    }

    /// Resume an on-hold download only if no hold still blocks it and the schedule
    /// window is open. Shared by the network monitor and the quiet-hours scheduler.
    private func resumeFromHold(_ id: UUID) async {
        guard !networkPausedIDs.contains(id), !scheduledPausedIDs.contains(id) else { return }
        guard scheduleWindowOpen else { return }
        await resume(id)
    }

    /// A diagnostics report for one download. Prefers the live coordinator (which
    /// has up-to-the-moment chunk attempts and concurrency state); falls back to
    /// the persisted record for inactive downloads.
    func diagnostics(for id: UUID) async -> String? {
        if let coord = coordinators[id] {
            return await coord.diagnosticsReport()
        }
        guard let d = downloads[id] else { return nil }
        return DownloadDiagnostics.report(for: d)
    }

    /// Per-piece progress and concurrency state for one download, for the
    /// inspector's segment map. Same live-first, persisted-fallback shape as
    /// `diagnostics(for:)`.
    func inspection(for id: UUID) async -> DownloadInspection? {
        if let coord = coordinators[id] {
            return await coord.inspectionSnapshot()
        }
        guard let d = downloads[id] else { return nil }
        return DownloadInspection(persisted: d)
    }

    /// Change a download's queue priority. Re-runs the scheduler so a newly
    /// high-priority queued item can take a free slot.
    func setPriority(id: UUID, priority: DownloadPriority) async {
        guard var d = downloads[id], d.priority != priority else { return }
        d.priority = priority
        downloads[id] = d
        await store.upsert(d)
        eventsContinuation.yield(.stateChanged(d))
        await scheduleNextDownloads()
    }

    /// Live-adjust the parallel chunk count for one download. Increases re-split
    /// the largest in-flight chunk; decreases drain naturally as workers finish.
    func adjustThreads(id: UUID, newThreads: Int) async {
        let clamped = max(1, min(Download.maxThreadCount, newThreads))
        if var d = downloads[id] {
            d.threadCount = clamped
            downloads[id] = d
            await store.upsert(d)
            eventsContinuation.yield(.stateChanged(d))
        }
        if let coord = coordinators[id] {
            await coord.adjustThreadCount(clamped)
        }
    }

    // MARK: - Scheduling

    private func scheduleNextDownloads() async {
        // Honor quiet hours: don't start new work while the window is closed.
        guard scheduleWindowOpen else { return }
        let activeCount = coordinators.count + extractors.count + torrents.count
        let slots = max(0, settings.maxConcurrentDownloads - activeCount)
        guard slots > 0 else { return }

        // A download stays `.queued` until its coordinator gets past the probe and
        // reports `.downloading` — a network round-trip later. Status alone
        // therefore can't tell "waiting for a slot" from "already starting", and
        // anything that re-runs the scheduler in that window (a pause, a settings
        // change, a network blip, another download finishing) would start a
        // second job for the same id. Both then raced for the same partial file:
        // the winner moved it to the destination, the loser found nothing to move
        // and overwrote the record with a finalize error — a failed download with
        // the finished file sitting on disk. The live-job maps are the real
        // "already started" signal, so they gate the candidate list.
        let queued = insertionOrder.compactMap { id -> Download? in
            guard let d = downloads[id], d.status == .queued else { return nil }
            guard !hasLiveJob(id) else { return nil }
            return d
        }
        for d in DownloadScheduler.order(queued).prefix(slots) {
            switch d.kind {
            case .httpFile: startCoordinator(for: d)
            case .media:    startExtraction(for: d)
            case .torrent:  startTorrent(for: d)
            }
        }
    }

    /// Route a torrent to the shared aria2 daemon. Fails fast with an actionable
    /// message when aria2 isn't installed.
    private func startTorrent(for download: Download) {
        let id = download.id
        guard !hasLiveJob(id) else {
            Log.engine.error("Refusing to start a second job for \(download.filename, privacy: .public) — one is already running.")
            return
        }
        guard TorrentToolLocator.locate() != nil else {
            var d = download
            d.status = .failed
            d.error = Aria2Daemon.DaemonError.toolMissing.localizedDescription
            downloads[id] = d
            Task { await store.upsert(d) }
            eventsContinuation.yield(.stateChanged(d))
            return
        }
        let job = TorrentJob(
            download: download,
            options: settings.torrentOptions,
            onStateChange: { [weak self] updated in
                await self?.handleStateChange(updated)
            },
            onSnapshot: { [weak self] snap in
                await self?.handleSnapshot(snap)
            }
        )
        torrents[id] = job
        updateActivityState()
        Task {
            await job.start()
        }
    }

    /// Route a media download to the yt-dlp extractor. Fails fast with a helpful
    /// message if the tools aren't installed.
    private func startExtraction(for download: Download) {
        let id = download.id
        guard !hasLiveJob(id) else {
            Log.engine.error("Refusing to start a second job for \(download.filename, privacy: .public) — one is already running.")
            return
        }
        guard let tools = MediaToolLocator.locate() else {
            var d = download
            d.status = .failed
            d.error = MediaError.toolsUnavailable.localizedDescription
            downloads[id] = d
            Task { await store.upsert(d) }
            eventsContinuation.yield(.stateChanged(d))
            return
        }
        let job = MediaExtractionJob(
            download: download,
            tools: tools,
            options: settings.mediaOptions,
            autoSortByType: settings.autoSortByType,
            onStateChange: { [weak self] updated in
                await self?.handleStateChange(updated)
            },
            onSnapshot: { [weak self] snap in
                await self?.handleSnapshot(snap)
            }
        )
        extractors[id] = job
        updateActivityState()
        Task {
            await job.start()
        }
    }

    /// Whether some job already owns this download. One id must never have two,
    /// because they'd share a partial file path and fight over it.
    private func hasLiveJob(_ id: UUID) -> Bool {
        coordinators[id] != nil || extractors[id] != nil || torrents[id] != nil
    }

    private func startCoordinator(for download: Download) {
        let id = download.id
        guard !hasLiveJob(id) else {
            Log.engine.error("Refusing to start a second job for \(download.filename, privacy: .public) — one is already running.")
            return
        }
        let coord = DownloadCoordinator(
            download: download,
            session: session,
            rateLimiter: rateLimiter,
            maxAttemptsPerChunk: settings.maxRetriesPerChunk,
            autoSortByType: settings.autoSortByType,
            onStateChange: { [weak self] updated in
                await self?.handleStateChange(updated)
            },
            onSnapshot: { [weak self] snap in
                await self?.handleSnapshot(snap)
            },
            onAuthRequired: { [weak self, host = download.url.host ?? ""] in
                await self?.authHandler?(id, host)
            }
        )
        coordinators[id] = coord
        updateActivityState()
        Task {
            await coord.start()
        }
    }

    private func handleStateChange(_ updated: Download) async {
        Log.engine.info("DIAG handleStateChange: id=\(updated.id, privacy: .public) status=\(String(describing: updated.status), privacy: .public) kind=\(String(describing: updated.kind), privacy: .public) bytes=\(updated.bytesDownloaded) err=\(updated.error ?? "nil", privacy: .public)")
        let wasCompleted = downloads[updated.id]?.status == .completed
        downloads[updated.id] = updated
        await store.upsert(updated)
        eventsContinuation.yield(.stateChanged(updated))
        if updated.status == .completed, !wasCompleted, settings.completionNotificationsEnabled {
            let name = updated.filename
            Task { @MainActor in CompletionNotifier.downloadCompleted(filename: name) }
        }
        if updated.status.isTerminal || updated.status == .paused {
            coordinators.removeValue(forKey: updated.id)
            extractors.removeValue(forKey: updated.id)
            updateActivityState()
            await scheduleNextDownloads()
        }
    }

    /// Begin a `ProcessInfo` activity while any coordinator is running so
    /// macOS doesn't put us into App Nap (which throttles CPU and network
    /// when the app loses focus or is minimized). Release the token when
    /// no downloads are active so the system can save power normally.
    private func updateActivityState() {
        let active = !coordinators.isEmpty || !extractors.isEmpty
        if active && activityToken == nil {
            activityToken = ProcessInfo.processInfo.beginActivity(
                options: [.userInitiated, .automaticTerminationDisabled],
                reason: "Active download"
            )
        } else if !active, let token = activityToken {
            ProcessInfo.processInfo.endActivity(token)
            activityToken = nil
        }
    }

    private func handleSnapshot(_ snap: DownloadSnapshot) async {
        eventsContinuation.yield(.snapshot(snap))
    }
}
