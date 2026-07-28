import XCTest
@testable import Macget

final class ChunkSplitterTests: XCTestCase {

    func test_returnsNilForEmptyChunks() {
        XCTAssertNil(ChunkSplitter.nextSplit(chunks: []))
    }

    func test_returnsNilWhenAllComplete() {
        let total: Int64 = 1024 * 1024
        var c = Chunk(startByte: 0, endByte: total - 1)
        c.bytesWritten = total
        XCTAssertNil(ChunkSplitter.nextSplit(chunks: [c]))
    }

    func test_returnsNilWhenChunkTooSmallToSplit() {
        let small = Chunk(startByte: 0, endByte: ChunkPlanner.minimumChunkBytes - 1)
        XCTAssertNil(ChunkSplitter.nextSplit(chunks: [small]))

        // 128 KB clears the planner's floor but not the split floor: halving it
        // would cancel a live connection to rescue 64 KB, and the reconnect
        // costs more than the tail is worth.
        let planFloor = Chunk(startByte: 0, endByte: 2 * ChunkPlanner.minimumChunkBytes - 1)
        XCTAssertNil(ChunkSplitter.nextSplit(chunks: [planFloor]))
    }

    func test_defaultFloorIsTheSplitFloorNotThePlanningFloor() {
        let justUnder = Chunk(startByte: 0, endByte: ChunkSplitter.defaultMinimumSplitBytes - 2)
        XCTAssertNil(ChunkSplitter.nextSplit(chunks: [justUnder]))

        let atFloor = Chunk(startByte: 0, endByte: ChunkSplitter.defaultMinimumSplitBytes - 1)
        XCTAssertNotNil(ChunkSplitter.nextSplit(chunks: [atFloor]))
    }

    func test_explicitFloorIsHonored() {
        let chunk = Chunk(startByte: 0, endByte: 4 * 1024 * 1024 - 1)  // 4 MB
        XCTAssertNotNil(ChunkSplitter.nextSplit(chunks: [chunk], minimumSplitBytes: 1024 * 1024))
        XCTAssertNil(ChunkSplitter.nextSplit(chunks: [chunk], minimumSplitBytes: 8 * 1024 * 1024))
    }

    func test_plannerFloorStillBindsWhenExplicitFloorIsLower() {
        // A caller asking for a 1-byte floor must not get sub-64KB halves — the
        // planner's minimum is a hard lower bound on either side of the split.
        let tiny = Chunk(startByte: 0, endByte: ChunkPlanner.minimumChunkBytes - 1)
        XCTAssertNil(ChunkSplitter.nextSplit(chunks: [tiny], minimumSplitBytes: 1))
    }

    func test_splitFloorMeasuresRemainingNotTotal() {
        // A 100 MB piece that's all but done has nothing worth splitting left.
        var nearlyDone = Chunk(startByte: 0, endByte: 100 * 1024 * 1024 - 1)
        nearlyDone.bytesWritten = 100 * 1024 * 1024 - 1024
        XCTAssertNil(ChunkSplitter.nextSplit(chunks: [nearlyDone]))
    }

    func test_picksLargestRemainingChunk() {
        // Three chunks: small, large, medium. Should split the large one.
        let small  = Chunk(startByte: 0,           endByte: 200_000)
        let large  = Chunk(startByte: 1_000_000,   endByte: 10_000_000)
        let medium = Chunk(startByte: 20_000_000,  endByte: 22_000_000)

        let decision = ChunkSplitter.nextSplit(chunks: [small, large, medium])
        XCTAssertNotNil(decision)
        XCTAssertEqual(decision?.originalIndex, 1)
        XCTAssertEqual(decision?.originalID, large.id)
    }

    func test_splitProducesContiguousNonOverlappingHalves() {
        let total: Int64 = 10_000_000
        let chunk = Chunk(startByte: 0, endByte: total - 1)
        let decision = ChunkSplitter.nextSplit(chunks: [chunk])!

        // Shrunken half sits at [0, mid]
        XCTAssertEqual(decision.shrunken.startByte, 0)
        // New half sits at [mid+1, oldEnd]
        XCTAssertEqual(decision.newChunk.endByte, total - 1)
        // No gap, no overlap
        XCTAssertEqual(decision.newChunk.startByte, decision.shrunken.endByte + 1)
        // Both halves cover the original range exactly
        let coverage = decision.shrunken.totalBytes + decision.newChunk.totalBytes
        XCTAssertEqual(coverage, total)
    }

    func test_splitPreservesAlreadyDownloadedBytes() {
        // Chunk that's 50% downloaded. Split should keep bytesWritten on the
        // shrunken half; the new half starts fresh.
        let total: Int64 = 10_000_000
        var chunk = Chunk(startByte: 0, endByte: total - 1)
        chunk.bytesWritten = 5_000_000
        chunk.attempts = 2
        chunk.lastError = "transient"

        let decision = ChunkSplitter.nextSplit(chunks: [chunk])!

        XCTAssertEqual(decision.shrunken.bytesWritten, 5_000_000)
        XCTAssertEqual(decision.shrunken.attempts, 2)
        XCTAssertEqual(decision.shrunken.lastError, "transient")
        XCTAssertEqual(decision.newChunk.bytesWritten, 0)
        XCTAssertEqual(decision.newChunk.attempts, 0)
        XCTAssertNil(decision.newChunk.lastError)
    }

    func test_midComputedFromRemainingNotTotal() {
        // Chunk that is partially downloaded. Split should halve only the
        // UNFINISHED region — not the whole chunk.
        let total: Int64 = 10_000_000
        var chunk = Chunk(startByte: 0, endByte: total - 1)
        chunk.bytesWritten = 4_000_000
        // remainingBytes = 6_000_000, half = 3_000_000.
        // mid = nextOffset(=4_000_000) + 3_000_000 - 1 = 6_999_999

        let decision = ChunkSplitter.nextSplit(chunks: [chunk])!
        XCTAssertEqual(decision.shrunken.endByte, 6_999_999)
        XCTAssertEqual(decision.newChunk.startByte, 7_000_000)
        XCTAssertEqual(decision.newChunk.endByte, total - 1)

        // Each half's remaining is roughly remaining/2.
        XCTAssertEqual(decision.shrunken.remainingBytes, 3_000_000)
        XCTAssertEqual(decision.newChunk.remainingBytes, 3_000_000)
    }

    func test_repeatedSplittingTilesSpaceExactly() {
        // Start with one 8 MB chunk; split it 4 times in a row (5 chunks total).
        // Final chunks must tile [0, 8M-1] exactly.
        let total: Int64 = 8 * 1024 * 1024
        var chunks: [Chunk] = [Chunk(startByte: 0, endByte: total - 1)]

        for _ in 0..<4 {
            guard let decision = ChunkSplitter.nextSplit(chunks: chunks) else {
                XCTFail("split should succeed"); return
            }
            chunks[decision.originalIndex] = decision.shrunken
            chunks.append(decision.newChunk)
        }

        XCTAssertEqual(chunks.count, 5)
        let sorted = chunks.sorted { $0.startByte < $1.startByte }
        XCTAssertEqual(sorted.first?.startByte, 0)
        XCTAssertEqual(sorted.last?.endByte, total - 1)
        for i in 1..<sorted.count {
            XCTAssertEqual(
                sorted[i].startByte, sorted[i - 1].endByte + 1,
                "Halves must tile contiguously, no gap or overlap"
            )
        }
        let coverage = sorted.reduce(Int64(0)) { $0 + $1.totalBytes }
        XCTAssertEqual(coverage, total)
    }

    func test_newChunkUsesFreshUUID() {
        // The shrunken chunk MUST get a new UUID so the cancelled worker's
        // chunkFinished callback doesn't accidentally remove the new entry.
        let chunk = Chunk(startByte: 0, endByte: 10_000_000)
        let decision = ChunkSplitter.nextSplit(chunks: [chunk])!
        XCTAssertNotEqual(decision.shrunken.id, chunk.id)
        XCTAssertNotEqual(decision.newChunk.id, chunk.id)
        XCTAssertNotEqual(decision.shrunken.id, decision.newChunk.id)
    }
}
