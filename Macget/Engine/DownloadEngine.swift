import Foundation
import OSLog

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
    private var insertionOrder: [UUID] = []
    private var settings: AppSettings

    private let store: DownloadStore
    private let session: URLSession
    private let log = Logger(subsystem: "com.macget", category: "Engine")

    /// Held while at least one download is active. Prevents macOS App Nap from
    /// throttling CPU/network when the user switches focus or minimizes the
    /// window. Released once no coordinators are running.
    private var activityToken: NSObjectProtocol?

    private let eventsContinuation: AsyncStream<EngineEvent>.Continuation
    nonisolated let events: AsyncStream<EngineEvent>

    init(store: DownloadStore, settings: AppSettings, session: URLSession = URLSessionFactory.shared) {
        self.store = store
        self.settings = settings
        self.session = session
        var continuation: AsyncStream<EngineEvent>.Continuation!
        self.events = AsyncStream { c in continuation = c }
        self.eventsContinuation = continuation
    }

    // MARK: - Public API

    /// Load persisted downloads and (per settings) auto-resume the unfinished ones.
    func loadPersistedAndResume() async {
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

    func updateSettings(_ newSettings: AppSettings) async {
        let oldMax = settings.maxConcurrentDownloads
        settings = newSettings
        eventsContinuation.yield(.settingsChanged(newSettings))
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
        threadCount: Int? = nil,
        startImmediately: Bool? = nil
    ) async -> UUID {
        let resolvedThreads = threadCount ?? settings.defaultThreadCount
        let dest = destinationFolder
        let resolvedName = filename ?? (url.lastPathComponent.isEmpty ? "download" : url.lastPathComponent)
        let download = Download(
            url: url,
            destinationFolder: dest,
            filename: resolvedName,
            threadCount: resolvedThreads
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

    func pause(_ id: UUID) async {
        if let coord = coordinators[id] {
            await coord.pause()
            // Coordinator's onStateChange will sync `downloads[id]`.
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
        } else if var d = downloads[id] {
            d.status = .cancelled
            downloads[id] = d
            try? FileManager.default.removeItem(at: d.partialFileURL)
            await store.upsert(d)
            eventsContinuation.yield(.stateChanged(d))
        }
        coordinators.removeValue(forKey: id)
        updateActivityState()
        await scheduleNextDownloads()
    }

    /// Removes a download from the queue. If active, cancels first. Optionally deletes the file on disk.
    func remove(_ id: UUID, deleteFile: Bool = false) async {
        if coordinators[id] != nil {
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
        updateActivityState()
        await store.delete(id)
        eventsContinuation.yield(.removed(id))
        await scheduleNextDownloads()
    }

    func pauseAll() async {
        for id in coordinators.keys {
            await coordinators[id]?.pause()
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
        for id in coordinators.keys {
            await coordinators[id]?.suspend()
        }
        if let token = activityToken {
            ProcessInfo.processInfo.endActivity(token)
            activityToken = nil
        }
    }

    func currentDownloads() -> [Download] {
        insertionOrder.compactMap { downloads[$0] }
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
        let activeCount = coordinators.count
        let slots = max(0, settings.maxConcurrentDownloads - activeCount)
        guard slots > 0 else { return }

        let queued = insertionOrder.compactMap { id -> Download? in
            guard let d = downloads[id], d.status == .queued else { return nil }
            return d
        }
        for d in queued.prefix(slots) {
            startCoordinator(for: d)
        }
    }

    private func startCoordinator(for download: Download) {
        let id = download.id
        let coord = DownloadCoordinator(
            download: download,
            session: session,
            onStateChange: { [weak self] updated in
                await self?.handleStateChange(updated)
            },
            onSnapshot: { [weak self] snap in
                await self?.handleSnapshot(snap)
            }
        )
        coordinators[id] = coord
        updateActivityState()
        Task {
            await coord.start()
        }
    }

    private func handleStateChange(_ updated: Download) async {
        downloads[updated.id] = updated
        await store.upsert(updated)
        eventsContinuation.yield(.stateChanged(updated))
        if updated.status.isTerminal || updated.status == .paused {
            coordinators.removeValue(forKey: updated.id)
            updateActivityState()
            await scheduleNextDownloads()
        }
    }

    /// Begin a `ProcessInfo` activity while any coordinator is running so
    /// macOS doesn't put us into App Nap (which throttles CPU and network
    /// when the app loses focus or is minimized). Release the token when
    /// no downloads are active so the system can save power normally.
    private func updateActivityState() {
        if !coordinators.isEmpty && activityToken == nil {
            activityToken = ProcessInfo.processInfo.beginActivity(
                options: [.userInitiated, .automaticTerminationDisabled],
                reason: "Active download"
            )
        } else if coordinators.isEmpty, let token = activityToken {
            ProcessInfo.processInfo.endActivity(token)
            activityToken = nil
        }
    }

    private func handleSnapshot(_ snap: DownloadSnapshot) async {
        eventsContinuation.yield(.snapshot(snap))
    }
}
