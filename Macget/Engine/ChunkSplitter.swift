import Foundation

struct ChunkSplitDecision: Equatable {
    let originalIndex: Int
    let originalID: UUID
    let shrunken: Chunk
    let newChunk: Chunk
}

/// Pure split logic used by `DownloadCoordinator.fillIdleSlots` (via
/// `SlotFiller`) and by `adjustThreadCount`. Picks the non-complete chunk with
/// the most remaining bytes and halves its unfinished region. Returns nil when
/// no chunk has enough left to be worth splitting.
///
/// Selection is by bytes remaining, not *time* remaining. Those diverge — a fast
/// worker that started late can hold more bytes than a slow worker nearly done,
/// and then the wrong piece gets split. Tracking per-chunk speed to fix it would
/// put more state on the hot path; at the tail the two measures largely agree,
/// because the piece still holding bytes is usually the slow one. Revisit if
/// `DownloadInspection.splitCount` shows healthy workers being split.
enum ChunkSplitter {
    /// Minimum bytes remaining before a chunk is worth splitting.
    ///
    /// Distinct from `ChunkPlanner.minimumChunkBytes` (64 KB), which governs
    /// *planning*. Splitting cancels a live worker and reconnects, and a TLS
    /// handshake costs 100–300 ms — not worth spending to rescue 64 KB. At 1 MB,
    /// a slow worker at 200 KB/s is ~5 s of tail, comfortably worth a reconnect.
    /// The floor also bounds thrash: without it, every freed worker would split
    /// ever-smaller tails and churn connections through the last second.
    static let defaultMinimumSplitBytes: Int64 = 1024 * 1024

    static func nextSplit(
        chunks: [Chunk],
        minimumSplitBytes: Int64 = defaultMinimumSplitBytes
    ) -> ChunkSplitDecision? {
        // Each half must still clear the planner's floor, so the effective
        // minimum is whichever bound is tighter.
        let minBytes = max(2 * ChunkPlanner.minimumChunkBytes, minimumSplitBytes)
        let splittable = chunks
            .enumerated()
            .filter { !$0.element.isComplete && $0.element.remainingBytes >= minBytes }
            .max(by: { $0.element.remainingBytes < $1.element.remainingBytes })
        guard let (idx, chunk) = splittable else { return nil }

        let nextOffset = chunk.nextWriteOffset
        let oldEnd = chunk.endByte
        let mid = nextOffset + chunk.remainingBytes / 2 - 1

        let shrunken = Chunk(
            startByte: chunk.startByte,
            endByte: mid,
            bytesWritten: chunk.bytesWritten,
            attempts: chunk.attempts,
            lastError: chunk.lastError
        )
        let newChunk = Chunk(startByte: mid + 1, endByte: oldEnd)

        return ChunkSplitDecision(
            originalIndex: idx,
            originalID: chunk.id,
            shrunken: shrunken,
            newChunk: newChunk
        )
    }
}
