import Foundation

/// One work-stealing piece, flattened for display.
///
/// `Chunk` is persisted state with mutable bookkeeping (attempts, last error);
/// this is the read-only projection the inspector's segment map draws. Keeping
/// them separate means the UI never holds a `Chunk` it might be tempted to write
/// back — piece state belongs to the coordinator.
struct SegmentInfo: Sendable, Equatable, Identifiable {
    let id: UUID
    let startByte: Int64
    let endByte: Int64
    let bytesWritten: Int64
    /// True when a worker currently owns this piece. Drives the "in flight"
    /// treatment, which is the whole point of the map — it shows work-stealing
    /// moving across the file rather than one bar creeping right.
    let isActive: Bool
    let attempts: Int

    /// Inclusive range, so a 1-byte piece is `start == end`. A piece from an
    /// unknown-size download has `endByte == -1` and no meaningful size.
    var totalBytes: Int64 { max(0, endByte - startByte + 1) }

    var isComplete: Bool { totalBytes > 0 && bytesWritten >= totalBytes }

    var fractionComplete: Double {
        guard totalBytes > 0 else { return 0 }
        return min(1, Double(bytesWritten) / Double(totalBytes))
    }

    init(chunk: Chunk, isActive: Bool) {
        self.id = chunk.id
        self.startByte = chunk.startByte
        self.endByte = chunk.endByte
        self.bytesWritten = chunk.bytesWritten
        self.isActive = isActive
        self.attempts = chunk.attempts
    }
}

/// Everything the inspector panel shows that isn't already in `DownloadSnapshot`.
///
/// Pulled on demand rather than pushed through `EngineEvent`: the segment array
/// can be `ChunkPlanner.maxPieces` entries, and shipping that for every active
/// download four times a second when at most one is on screen is waste. The
/// inspector asks only for the download it's displaying.
struct DownloadInspection: Sendable, Equatable {
    let id: UUID
    let totalBytes: Int64?
    let bytesDownloaded: Int64
    let supportsRange: Bool
    let segments: [SegmentInfo]

    /// Workers with a piece in hand right now. Zero for anything not running.
    let activeWorkers: Int
    /// What `effectiveThreadCount()` resolves to — the min of everything below.
    let effectiveThreads: Int
    /// What the user asked for.
    let requestedThreads: Int
    /// How high the adaptive probe has climbed, or nil when not running.
    let adaptiveCeiling: Int?
    /// Cap learned for this host in a previous session, if any.
    let perHostCap: Int?
    /// In-session anti-leech demotion, if it fired.
    let demotedTo: Int?
    /// False when this was rebuilt from the persisted record because no
    /// coordinator is live (paused, queued, completed).
    let isLive: Bool

    var completedSegments: Int { segments.filter(\.isComplete).count }

    /// Piece size to display. Pieces are equal apart from the last one absorbing
    /// the remainder, so the first is representative.
    var nominalSegmentBytes: Int64? {
        segments.first.map(\.totalBytes).flatMap { $0 > 0 ? $0 : nil }
    }

    /// Projection for a download with no live coordinator. Nothing is in flight,
    /// so every piece renders as done or pending.
    init(persisted d: Download) {
        self.id = d.id
        self.totalBytes = d.totalBytes
        self.bytesDownloaded = d.bytesDownloaded
        self.supportsRange = d.supportsRange
        self.segments = d.chunks.map { SegmentInfo(chunk: $0, isActive: false) }
        self.activeWorkers = 0
        self.effectiveThreads = d.threadCount
        self.requestedThreads = d.threadCount
        self.adaptiveCeiling = nil
        self.perHostCap = nil
        self.demotedTo = nil
        self.isLive = false
    }

    init(
        id: UUID,
        totalBytes: Int64?,
        bytesDownloaded: Int64,
        supportsRange: Bool,
        segments: [SegmentInfo],
        activeWorkers: Int,
        effectiveThreads: Int,
        requestedThreads: Int,
        adaptiveCeiling: Int?,
        perHostCap: Int?,
        demotedTo: Int?,
        isLive: Bool
    ) {
        self.id = id
        self.totalBytes = totalBytes
        self.bytesDownloaded = bytesDownloaded
        self.supportsRange = supportsRange
        self.segments = segments
        self.activeWorkers = activeWorkers
        self.effectiveThreads = effectiveThreads
        self.requestedThreads = requestedThreads
        self.adaptiveCeiling = adaptiveCeiling
        self.perHostCap = perHostCap
        self.demotedTo = demotedTo
        self.isLive = isLive
    }
}
