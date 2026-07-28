import Foundation
import Observation
import OSLog
import AppKit

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
    let priority: DownloadPriority
    let phase: MediaPhase?         // media lifecycle phase; nil for HTTP downloads
    let kind: DownloadKind
    // Torrent-only live stats; nil/zero for every other kind.
    let uploadSpeedBytesPerSec: Double
    let uploadedBytes: Int64?
    let seeders: Int?
    let peers: Int?
    /// True once a torrent has finished downloading and is only uploading.
    let isSeeding: Bool

    var fractionComplete: Double {
        guard let total = totalBytes, total > 0 else { return 0 }
        return min(1.0, Double(bytesDownloaded) / Double(total))
    }

    var isTorrent: Bool { kind == .torrent }

    /// Share ratio for a torrent row, or nil before anything is downloaded.
    var ratio: Double? {
        guard let uploadedBytes, bytesDownloaded > 0 else { return nil }
        return Double(uploadedBytes) / Double(bytesDownloaded)
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
                supportsRange: d.supportsRange,
                priority: d.priority,
                phase: snap?.phase,
                kind: d.kind,
                uploadSpeedBytesPerSec: snap?.uploadSpeedBytesPerSec ?? 0,
                uploadedBytes: snap?.uploadedBytes ?? d.uploadedBytes,
                seeders: snap?.seeders,
                peers: snap?.peers,
                isSeeding: snap?.isSeeding ?? false
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

    // MARK: - Session stats

    /// Completed downloads currently tracked (resets when "Clear Completed" runs).
    var completedCount: Int {
        downloadsByID.values.filter { $0.status == .completed }.count
    }

    /// Total bytes across completed downloads this session.
    var completedBytes: Int64 {
        downloadsByID.values
            .filter { $0.status == .completed }
            .reduce(0) { $0 + ($1.totalBytes ?? $1.bytesDownloaded) }
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

    func setPriority(_ id: UUID, _ priority: DownloadPriority) {
        Task { await engine.setPriority(id: id, priority: priority) }
    }

    /// Where to move the selected downloads within the manual queue order.
    enum QueueMove { case top, bottom, up, down }

    /// Reorder the manual queue. Applies the change to the local order optimistically
    /// (so the table updates immediately) and persists it via the engine. Note this
    /// reorders the insertion-order tiebreak — the scheduler still runs higher
    /// priorities first, so a move is honored within a priority band.
    func move(_ ids: Set<UUID>, _ target: QueueMove) {
        guard !ids.isEmpty else { return }
        let moving = insertionOrder.filter { ids.contains($0) }
        guard !moving.isEmpty else { return }
        switch target {
        case .top:
            insertionOrder = moving + insertionOrder.filter { !ids.contains($0) }
        case .bottom:
            insertionOrder = insertionOrder.filter { !ids.contains($0) } + moving
        case .up:
            if let id = moving.first, let idx = insertionOrder.firstIndex(of: id), idx > 0 {
                insertionOrder.swapAt(idx, idx - 1)
            }
        case .down:
            if let id = moving.first, let idx = insertionOrder.firstIndex(of: id), idx < insertionOrder.count - 1 {
                insertionOrder.swapAt(idx, idx + 1)
            }
        }
        rebuildRows()
        let order = insertionOrder
        Task { await engine.reorder(order) }
    }

    /// Copies a per-download diagnostics report (chunks, attempts, errors, live
    /// concurrency state) to the clipboard for troubleshooting.
    func copyDiagnostics(_ id: UUID) {
        Task { [weak self] in
            guard let self, let report = await self.engine.diagnostics(for: id) else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(report, forType: .string)
        }
    }
}
