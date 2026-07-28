import Foundation

enum ChunkPlanner {
    /// Minimum bytes per chunk. Splitting smaller wastes overhead.
    static let minimumChunkBytes: Int64 = 64 * 1024

    /// Upper bound on piece count when slicing into smaller-than-a-worker pieces
    /// for work-stealing.
    ///
    /// The cap is what decides how coarse a *large* file gets: below ~2 GB the
    /// 8 MB target lands under it and piece size is constant, above that the cap
    /// binds and piece size grows as `total / maxPieces`. At 64 a 40 GB download
    /// was 64 × 640 MB — with only ~8 workers there was almost nothing left to
    /// steal, and the final piece could be 640 MB of tail. 256 brings the same
    /// file to 256 × 160 MB.
    ///
    /// The ceiling exists because `DownloadStore` rewrites the whole queue file
    /// on every save: 256 chunks is ~33 KB of JSON per in-flight download, which
    /// a debounced 500 ms write absorbs comfortably. Completed downloads collapse
    /// to one summary chunk (see `DownloadCoordinator.complete`) so the file
    /// doesn't accumulate this per finished item.
    static let maxPieces = 256

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
