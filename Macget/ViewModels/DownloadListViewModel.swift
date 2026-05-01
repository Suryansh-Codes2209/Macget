import Foundation
import Observation
import OSLog

enum StatusFilter: String, CaseIterable, Identifiable {
    case all
    case active
    case paused
    case completed
    case failed

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .all:       return "All"
        case .active:    return "Active"
        case .paused:    return "Paused"
        case .completed: return "Completed"
        case .failed:    return "Failed"
        }
    }
}

/// Combines a `Download` (terminal facts) with the latest `DownloadSnapshot`
/// (live progress/speed/eta) for display.
struct DownloadRowItem: Identifiable, Equatable {
    let id: UUID
    let filename: String
    let url: URL                   // source HTTP URL
    let destinationURL: URL        // resulting on-disk path
    let status: DownloadStatus
    let totalBytes: Int64?
    let bytesDownloaded: Int64
    let speedBytesPerSec: Double
    let etaSeconds: TimeInterval?
    let error: String?
    let createdAt: Date
    let threadCount: Int           // current active thread count (live, persisted)
    let supportsRange: Bool        // false → multi-thread is a no-op

    var fractionComplete: Double {
        guard let total = totalBytes, total > 0 else { return 0 }
        return min(1.0, Double(bytesDownloaded) / Double(total))
    }
}

@MainActor
@Observable
final class DownloadListViewModel {
    private(set) var rows: [DownloadRowItem] = []
    var selectedFilter: StatusFilter = .all
    var searchText: String = ""
    var totalSpeed: Double = 0

    private var downloadsByID: [UUID: Download] = [:]
    private var snapshotsByID: [UUID: DownloadSnapshot] = [:]
    private var insertionOrder: [UUID] = []

    private let engine: DownloadEngine
    private let log = Logger(subsystem: "com.macget", category: "DownloadListVM")
    private var listenerTask: Task<Void, Never>?

    init(engine: DownloadEngine) {
        self.engine = engine
    }

    func bootstrap() {
        listenerTask?.cancel()
        let stream = engine.events
        listenerTask = Task { [weak self] in
            guard let self else { return }
            await self.engine.loadPersistedAndResume()
            for await event in stream {
                await self.handle(event: event)
            }
        }
    }

    func teardown() {
        listenerTask?.cancel()
        listenerTask = nil
    }

    // MARK: - Engine event handling

    private func handle(event: EngineEvent) async {
        switch event {
        case .added(let d):
            downloadsByID[d.id] = d
            if !insertionOrder.contains(d.id) { insertionOrder.append(d.id) }
        case .stateChanged(let d):
            downloadsByID[d.id] = d
            if d.status.isTerminal {
                snapshotsByID.removeValue(forKey: d.id)
            }
        case .snapshot(let s):
            snapshotsByID[s.id] = s
        case .removed(let id):
            downloadsByID.removeValue(forKey: id)
            snapshotsByID.removeValue(forKey: id)
            insertionOrder.removeAll { $0 == id }
        case .settingsChanged:
            break
        }
        rebuildRows()
    }

    private func rebuildRows() {
        let items: [DownloadRowItem] = insertionOrder.compactMap { id in
            guard let d = downloadsByID[id] else { return nil }
            let snap = snapshotsByID[id]
            return DownloadRowItem(
                id: d.id,
                filename: d.filename,
                url: d.url,
                destinationURL: d.destinationURL,
                status: d.status,
                totalBytes: snap?.totalBytes ?? d.totalBytes,
                bytesDownloaded: snap?.bytesDownloaded ?? d.bytesDownloaded,
                speedBytesPerSec: snap?.speedBytesPerSec ?? 0,
                etaSeconds: snap?.etaSeconds,
                error: d.error,
                createdAt: d.createdAt,
                threadCount: d.threadCount,
                supportsRange: d.supportsRange
            )
        }
        rows = filtered(items)
        totalSpeed = items.filter { $0.status == .downloading }
                          .reduce(0) { $0 + $1.speedBytesPerSec }
    }

    private func filtered(_ items: [DownloadRowItem]) -> [DownloadRowItem] {
        let byFilter: [DownloadRowItem]
        switch selectedFilter {
        case .all:       byFilter = items
        case .active:    byFilter = items.filter { $0.status == .downloading || $0.status == .queued }
        case .paused:    byFilter = items.filter { $0.status == .paused }
        case .completed: byFilter = items.filter { $0.status == .completed }
        case .failed:    byFilter = items.filter { $0.status == .failed }
        }
        let q = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return byFilter }
        return byFilter.filter {
            $0.filename.lowercased().contains(q) || $0.url.absoluteString.lowercased().contains(q)
        }
    }

    func filterRefreshed() {
        rebuildRows()
    }

    // MARK: - Counts for sidebar

    func count(for filter: StatusFilter) -> Int {
        switch filter {
        case .all:       return downloadsByID.count
        case .active:    return downloadsByID.values.filter { $0.status == .downloading || $0.status == .queued }.count
        case .paused:    return downloadsByID.values.filter { $0.status == .paused }.count
        case .completed: return downloadsByID.values.filter { $0.status == .completed }.count
        case .failed:    return downloadsByID.values.filter { $0.status == .failed }.count
        }
    }

    // MARK: - Actions

    func pause(_ id: UUID) {
        Task { await engine.pause(id) }
    }

    func resume(_ id: UUID) {
        Task { await engine.resume(id) }
    }

    func cancel(_ id: UUID) {
        Task { await engine.cancel(id) }
    }

    func remove(_ id: UUID, deleteFile: Bool = false) {
        Task { await engine.remove(id, deleteFile: deleteFile) }
    }

    func pauseAll() { Task { await engine.pauseAll() } }
    func resumeAll() { Task { await engine.resumeAll() } }
    func clearCompleted() { Task { await engine.clearCompleted() } }

    func setThreads(_ id: UUID, _ count: Int) {
        Task { await engine.adjustThreads(id: id, newThreads: count) }
    }
}
