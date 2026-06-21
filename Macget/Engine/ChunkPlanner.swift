import Foundation

enum ChunkPlanner {
    /// Minimum bytes per chunk. Splitting smaller wastes overhead.
    static let minimumChunkBytes: Int64 = 64 * 1024

    /// Upper bound on piece count when slicing into smaller-than-a-worker pieces
    /// for work-stealing. Keeps `queue.json` small (the store rewrites the whole
    /// file) and orchestration cheap.
    static let maxPieces = 64

    /// Default target piece size when work-stealing is enabled. Finer than one
    /// piece-per-worker so a fast worker can pick up the next outstanding piece
    /// instead of stalling on one slow connection's huge region.
    static let defaultTargetPieceBytes: Int64 = 8 * 1024 * 1024  // 8 MB

    /// Returns a list of `Chunk` covering exactly `[0, totalBytes - 1]`.
    ///
    /// Without `maxPieceBytes` the file is split into `requestedThreads` pieces
    /// (clamped to `1...Download.maxThreadCount` and to `totalBytes / 64KB`).
    ///
    /// With `maxPieceBytes`, the file is sliced into *more, smaller* pieces (up
    /// to `maxPieces`, each ≥ 64KB) so finished workers steal the next pending
    /// piece — this keeps every connection saturated to the end and removes the
    /// "one slow chunk holds up the whole download" long tail. The worker count
    /// is bounded separately by the coordinator, independent of piece count.
    static func plan(totalBytes: Int64, requestedThreads: Int, maxPieceBytes: Int64? = nil) -> [Chunk] {
        precondition(totalBytes >= 0, "totalBytes must be non-negative")
        if totalBytes == 0 {
            return [Chunk(startByte: 0, endByte: -1)]
        }

        let maxByMinSize = max(1, totalBytes / minimumChunkBytes)
        let threadClamped = Int64(max(1, min(Download.maxThreadCount, requestedThreads)))

        var pieceCount = threadClamped
        if let cap = maxPieceBytes, cap > 0 {
            let byPieceSize = max(1, totalBytes / cap)
            pieceCount = min(max(threadClamped, byPieceSize), Int64(maxPieces))
        }
        let k = Int(min(pieceCount, maxByMinSize))

        let chunkSize = totalBytes / Int64(k)
        var chunks: [Chunk] = []
        chunks.reserveCapacity(k)
        for i in 0..<k {
            let start = Int64(i) * chunkSize
            let end: Int64 = (i == k - 1) ? (totalBytes - 1) : (start + chunkSize - 1)
            chunks.append(Chunk(startByte: start, endByte: end))
        }
        return chunks
    }
}
