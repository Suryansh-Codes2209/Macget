import Foundation

enum ChunkPlanner {
    /// Minimum bytes per chunk. Splitting smaller wastes overhead.
    static let minimumChunkBytes: Int64 = 64 * 1024

    /// Returns a list of `Chunk` covering exactly `[0, totalBytes - 1]`.
    /// `requestedThreads` is clamped: at least 1, at most `Download.maxThreadCount`,
    /// and at most `totalBytes / minimumChunkBytes` so each chunk is ≥ 64KB.
    static func plan(totalBytes: Int64, requestedThreads: Int) -> [Chunk] {
        precondition(totalBytes >= 0, "totalBytes must be non-negative")
        if totalBytes == 0 {
            return [Chunk(startByte: 0, endByte: -1)]
        }

        let maxByMinSize = max(1, totalBytes / minimumChunkBytes)
        let effective = min(Int64(max(1, min(Download.maxThreadCount, requestedThreads))), maxByMinSize)
        let k = Int(effective)

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
