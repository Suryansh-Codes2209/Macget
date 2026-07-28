import Foundation
import Observation

/// Drives the inspector panel: samples throughput into rolling windows and pulls
/// per-piece state for whichever download is selected.
///
/// Pull rather than push. `DownloadSnapshot` is broadcast for every active
/// download several times a second, and a segment array can be
/// `ChunkPlanner.maxPieces` entries — putting it on that channel would ship a
/// few hundred structs per tick for downloads nobody is looking at. Here exactly
/// one download is inspected at a time, and only while the panel is open.
@MainActor
@Observable
final class InspectorModel {
    /// Per-piece state for the selected download, or nil when nothing is
    /// selected / the engine no longer knows about it.
    private(set) var inspection: DownloadInspection?

    /// Throughput of the selected download.
    private(set) var selectedSeries = SpeedSeries()

    /// Combined throughput of everything active — what the panel shows when
    /// there's no selection.
    private(set) var totalSeries = SpeedSeries()

    /// Whether the panel is on screen. Polling only runs while it is.
    var isPresented = false {
        didSet {
            guard isPresented != oldValue else { return }
            isPresented ? start() : stop()
        }
    }

    /// Matches the coordinator's publish loop, so the chart advances in step with
    /// the numbers in the list rather than beating against them.
    static let sampleInterval: Duration = .milliseconds(250)

    private let engine: DownloadEngine
    private let list: DownloadListViewModel
    private var targetID: UUID?
    private var pollTask: Task<Void, Never>?

    init(engine: DownloadEngine, list: DownloadListViewModel) {
        self.engine = engine
        self.list = list
    }

    /// Point the panel at a download. Switching targets clears the per-download
    /// window — carrying the previous file's curve over would misattribute it.
    func setTarget(_ id: UUID?) {
        guard id != targetID else { return }
        targetID = id
        selectedSeries.reset()
        inspection = nil
        if isPresented { Task { await tick() } }
    }

    var hasTarget: Bool { targetID != nil }

    /// The selected download's row, for the header and stats.
    var targetRow: DownloadRowItem? {
        guard let targetID else { return nil }
        return list.rows.first { $0.id == targetID }
    }

    /// Active downloads, newest speed first — the panel's no-selection list.
    var activeRows: [DownloadRowItem] {
        list.rows
            .filter { $0.status == .downloading }
            .sorted { $0.speedBytesPerSec > $1.speedBytesPerSec }
    }

    private func start() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                // Held only for the duration of a tick, and the loop ends if the
                // model goes away — otherwise a dead panel would sleep forever.
                guard let self else { return }
                await self.tick()
                try? await Task.sleep(for: Self.sampleInterval)
            }
        }
    }

    private func stop() {
        pollTask?.cancel()
        pollTask = nil
    }

    private func tick() async {
        totalSeries.append(list.totalSpeed)

        guard let targetID else {
            inspection = nil
            return
        }
        selectedSeries.append(targetRow?.speedBytesPerSec ?? 0)
        inspection = await engine.inspection(for: targetID)
    }
}
