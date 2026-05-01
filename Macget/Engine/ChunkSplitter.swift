import Foundation

struct ChunkSplitDecision: Equatable {
    let originalIndex: Int
    let originalID: UUID
    let shrunken: Chunk
    let newChunk: Chunk
}

/// Pure split logic used by `DownloadCoordinator.adjustThreadCount`. Picks the
/// non-complete chunk with the most remaining bytes and halves its unfinished
/// region. Returns nil when no chunk is large enough to split (each half must
/// be at least `ChunkPlanner.minimumChunkBytes`).
enum ChunkSplitter {
    static func nextSplit(chunks: [Chunk]) -> ChunkSplitDecision? {
        let minBytes = ChunkPlanner.minimumChunkBytes
        let splittable = chunks
            .enumerated()
            .filter { !$0.element.isComplete && $0.element.remainingBytes >= 2 * minBytes }
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
