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

/// The sidebar's second, orthogonal axis.
///
/// Kind is deliberately *not* another `StatusFilter` case: mixing the two into
/// one enum would make them mutually exclusive, and "show me only the torrents
/// that are still running" is the exact question a queue of thirty finished HTTP
/// downloads makes worth asking.
enum KindFilter: String, CaseIterable, Identifiable {
    case all
    case files
    case media
    case torrents

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .all:      return "All Types"
        case .files:    return "Files"
        case .media:    return "Media"
        case .torrents: return "Torrents"
        }
    }

    func matches(_ kind: DownloadKind) -> Bool {
        switch self {
        case .all:      return true
        case .files:    return kind == .httpFile
        case .media:    return kind == .media
        case .torrents: return kind == .torrent
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
    /// Files inside a multi-file torrent, once aria2 has resolved metadata.
    let torrentFiles: [TorrentFileEntry]?

    var fractionComplete: Double {
        guard let total = totalBytes, total > 0 else { return 0 }
        return min(1.0, Double(bytesDownloaded) / Double(total))
    }

    var isTorrent: Bool { kind == .torrent }

    /// The file a user means when they say "open this download".
    ///
    /// A finished torrent lands as a *folder*, so `destinationURL` points at a
    /// directory and opening it merely raises a Finder window. The payload
    /// dwarfs its companions — a 1.98 GB `.mp4` beside a 128 KB poster `.jpg` —
    /// so the largest file is the one worth opening.
    ///
    /// Falls back to `destinationURL` when the guess can't be made (not a
    /// torrent, metadata not yet fetched) or when the chosen file isn't on disk:
    /// files the user deselected are legitimately absent, and a dead menu item
    /// is worse than revealing the folder.
    var primaryFileURL: URL {
        guard kind == .torrent,
              let largest = torrentFiles?.max(by: { $0.length < $1.length })
        else { return destinationURL }
        let candidate = Self.resolve(largest.path, under: destinationURL)
        return FileManager.default.fileExists(atPath: candidate.path) ? candidate : destinationURL
    }

    /// aria2 reports absolute paths, but resolve defensively against the
    /// download's own folder in case a relative one ever arrives.
    static func resolve(_ path: String, under folder: URL) -> URL {
        path.hasPrefix("/") ? URL(fileURLWithPath: path) : folder.appendingPathComponent(path)
    }

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
    var selectedKind: KindFilter = .all
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

    /// Start draining `engine.events`. Safe to call repeatedly — and it *is*
    /// called repeatedly, from `ContentView`'s `.task`, which re-runs whenever
    /// the content view is recreated (closing the window and reopening it from
    /// the Dock is enough, since the app outlives its last window).
    ///
    /// The guard is load-bearing: `engine.events` is one `AsyncStream`, and an
    /// `AsyncStream` supports exactly one consumer. Cancelling the listener and
    /// re-iterating the same stream yields *nothing* forever, so a second
    /// bootstrap used to leave the list permanently deaf to the engine —
    /// downloads kept running and persisting while the UI silently stopped
    /// showing new rows. If a `teardown()` is ever wired up, this needs a fresh
    /// stream from the engine, not just a new task.
    func bootstrap() {
        guard listenerTask == nil else { return }
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
                isSeeding: snap?.isSeeding ?? false,
                torrentFiles: d.torrentFiles
            )
        }
        rows = filtered(items)
        totalSpeed = items.filter { $0.status == .downloading }
                          .reduce(0) { $0 + $1.speedBytesPerSec }
    }

    private func filtered(_ items: [DownloadRowItem]) -> [DownloadRowItem] {
        let items = selectedKind == .all ? items : items.filter { selectedKind.matches($0.kind) }
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

    /// Counts on each axis deliberately ignore the *other* axis. Counting within
    /// the other selection makes the numbers shift as the user clicks around,
    /// which reads as a bug rather than as a feature.
    func count(for kind: KindFilter) -> Int {
        guard kind != .all else { return downloadsByID.count }
        return downloadsByID.values.filter { kind.matches($0.kind) }.count
    }

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

    /// Apply a new file selection to a multi-file torrent. The engine restarts it
    /// so aria2 picks up the new `--select-file`.
    func updateTorrentFileSelection(_ id: UUID, selectedIndices: Set<Int>) {
        Task { await engine.updateTorrentFileSelection(id, selectedIndices: selectedIndices) }
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
