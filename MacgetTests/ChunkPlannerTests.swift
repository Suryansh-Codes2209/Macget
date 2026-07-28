import XCTest
@testable import Macget

final class ChunkPlannerTests: XCTestCase {

    func test_singleChunkWhenOneThreadRequested() {
        let chunks = ChunkPlanner.plan(totalBytes: 10_000_000, requestedThreads: 1)
        XCTAssertEqual(chunks.count, 1)
        XCTAssertEqual(chunks[0].startByte, 0)
        XCTAssertEqual(chunks[0].endByte, 9_999_999)
        XCTAssertEqual(chunks[0].totalBytes, 10_000_000)
    }

    func test_evenSplit() {
        // 1 MB / 4 threads = 256 KB each
        let total: Int64 = 1024 * 1024
        let chunks = ChunkPlanner.plan(totalBytes: total, requestedThreads: 4)
        XCTAssertEqual(chunks.count, 4)
        XCTAssertEqual(chunks[0].startByte, 0)
        XCTAssertEqual(chunks[3].endByte, total - 1)
        let coverage = chunks.reduce(Int64(0)) { $0 + $1.totalBytes }
        XCTAssertEqual(coverage, total)
    }

    func test_tailChunkAbsorbsRemainder() {
        // 1_000_001 / 4 = 250_000 r 1 → tail chunk is 250_001 bytes.
        // (Inputs scaled above ChunkPlanner.minimumChunkBytes so the per-thread
        //  min-chunk clamp doesn't reduce the chunk count.)
        let total: Int64 = 1_000_001
        let chunks = ChunkPlanner.plan(totalBytes: total, requestedThreads: 4)
        XCTAssertEqual(chunks.count, 4)
        XCTAssertEqual(chunks[0].totalBytes, 250_000)
        XCTAssertEqual(chunks[3].totalBytes, 250_001)
        let coverage = chunks.reduce(Int64(0)) { $0 + $1.totalBytes }
        XCTAssertEqual(coverage, total)
    }

    func test_threadsClampedToMinimumChunkSize() {
        // 100 KB / 20 requested threads → only 100KB/64KB = 1 chunk allowed.
        let chunks = ChunkPlanner.plan(totalBytes: 100 * 1024, requestedThreads: 20)
        XCTAssertEqual(chunks.count, 1)
    }

    func test_threadsClampedToMaxThreadCount() {
        // Asking for 50 threads with a 100 MB file should give Download.maxThreadCount.
        let chunks = ChunkPlanner.plan(totalBytes: 100 * 1024 * 1024, requestedThreads: 50)
        XCTAssertEqual(chunks.count, Download.maxThreadCount)
    }

    func test_zeroBytesReturnsEmptyChunk() {
        let chunks = ChunkPlanner.plan(totalBytes: 0, requestedThreads: 5)
        XCTAssertEqual(chunks.count, 1)
        XCTAssertEqual(chunks[0].totalBytes, 0)
    }

    func test_chunksAreContiguous() {
        let chunks = ChunkPlanner.plan(totalBytes: 12_345_678, requestedThreads: 7)
        for i in 1..<chunks.count {
            XCTAssertEqual(chunks[i].startByte, chunks[i - 1].endByte + 1,
                           "Chunks must cover the file with no gaps or overlaps")
        }
    }

    // MARK: - Work-stealing pieces

    func test_workStealingSlicesFinerThanThreads() {
        // 200 MB at the 8 MB target: 25 pieces for 8 workers, so a worker that
        // finishes early always has something left to steal.
        let chunks = ChunkPlanner.plan(
            totalBytes: 200 * 1024 * 1024,
            requestedThreads: 8,
            maxPieceBytes: ChunkPlanner.defaultTargetPieceBytes
        )
        XCTAssertEqual(chunks.count, 25)
    }

    func test_largeFileIsCappedAtMaxPieces() {
        // A 40 GB file wants 5,000 pieces at the 8 MB target; the cap decides.
        // Regression guard for the old cap of 64, which left 640 MB pieces.
        let total: Int64 = 40 * 1024 * 1024 * 1024
        let chunks = ChunkPlanner.plan(
            totalBytes: total,
            requestedThreads: 8,
            maxPieceBytes: ChunkPlanner.defaultTargetPieceBytes
        )
        XCTAssertEqual(chunks.count, ChunkPlanner.maxPieces)
        XCTAssertLessThanOrEqual(chunks[0].totalBytes, 200 * 1024 * 1024,
                                 "Pieces this large defeat work-stealing on a big file")
    }

    func test_workStealingPiecesStayContiguousAndCoverTheFile() {
        let total: Int64 = 40 * 1024 * 1024 * 1024 + 12_345
        let chunks = ChunkPlanner.plan(
            totalBytes: total,
            requestedThreads: 8,
            maxPieceBytes: ChunkPlanner.defaultTargetPieceBytes
        )
        XCTAssertEqual(chunks[0].startByte, 0)
        XCTAssertEqual(chunks.last?.endByte, total - 1)
        XCTAssertEqual(chunks.reduce(Int64(0)) { $0 + $1.totalBytes }, total)
        for i in 1..<chunks.count {
            XCTAssertEqual(chunks[i].startByte, chunks[i - 1].endByte + 1)
        }
    }

    func test_pieceCountNeverDropsBelowThreadCount() {
        // A small file with the piece target on still needs one piece per worker,
        // or the extra connections have nothing to do.
        let chunks = ChunkPlanner.plan(
            totalBytes: 4 * 1024 * 1024,
            requestedThreads: 8,
            maxPieceBytes: ChunkPlanner.defaultTargetPieceBytes
        )
        XCTAssertEqual(chunks.count, 8)
    }
}

/// Piece-sizing behaviour of the work-stealing cap. Moved here from
/// `AdaptiveConcurrencyTests` when the adaptive probe was removed — these always
/// exercised `ChunkPlanner`, not the probe that used to live beside them.
final class ChunkPlannerPieceSizingTests: XCTestCase {

    func test_pieceCapProducesMorePiecesThanWorkers() {
        // 100 MB, 4 "threads", 8 MB pieces → ~13 pieces (not 4).
        let total: Int64 = 100 * 1024 * 1024
        let chunks = ChunkPlanner.plan(totalBytes: total, requestedThreads: 4, maxPieceBytes: 8 * 1024 * 1024)
        XCTAssertGreaterThan(chunks.count, 4)
        XCTAssertLessThanOrEqual(chunks.count, ChunkPlanner.maxPieces)
    }

    func test_pieceCapCoversRangeContiguously() {
        let total: Int64 = 73 * 1024 * 1024 + 17
        let chunks = ChunkPlanner.plan(totalBytes: total, requestedThreads: 8, maxPieceBytes: 8 * 1024 * 1024)
        XCTAssertEqual(chunks.first?.startByte, 0)
        XCTAssertEqual(chunks.last?.endByte, total - 1)
        for i in 1..<chunks.count {
            XCTAssertEqual(chunks[i].startByte, chunks[i - 1].endByte + 1)
        }
        XCTAssertEqual(chunks.reduce(Int64(0)) { $0 + $1.totalBytes }, total)
    }

    func test_pieceCountNeverExceedsMaxPieces() {
        // 10 GB at 8 MB pieces would be ~1280 pieces → capped.
        let total: Int64 = 10 * 1024 * 1024 * 1024
        let chunks = ChunkPlanner.plan(totalBytes: total, requestedThreads: 8, maxPieceBytes: 8 * 1024 * 1024)
        XCTAssertEqual(chunks.count, ChunkPlanner.maxPieces)
    }

    func test_pieceCapNeverGoesBelowRequestedThreads() {
        // Small file: piece-size math yields 1, but we still want >= threads pieces.
        let total: Int64 = 20 * 1024 * 1024
        let chunks = ChunkPlanner.plan(totalBytes: total, requestedThreads: 8, maxPieceBytes: 8 * 1024 * 1024)
        XCTAssertGreaterThanOrEqual(chunks.count, 8)
    }

    func test_nilCapMatchesLegacyBehavior() {
        let total: Int64 = 100 * 1024 * 1024
        let legacy = ChunkPlanner.plan(totalBytes: total, requestedThreads: 6)
        let explicitNil = ChunkPlanner.plan(totalBytes: total, requestedThreads: 6, maxPieceBytes: nil)
        XCTAssertEqual(legacy.count, 6)
        XCTAssertEqual(explicitNil.count, 6)
    }

    func test_pieceCapStillRespectsMinimumChunkSize() {
        // 100 KB with a tiny piece cap must not create sub-64KB pieces.
        let chunks = ChunkPlanner.plan(totalBytes: 100 * 1024, requestedThreads: 8, maxPieceBytes: 1024)
        for c in chunks where chunks.count > 1 {
            XCTAssertGreaterThanOrEqual(c.totalBytes, ChunkPlanner.minimumChunkBytes / 2)
        }
        XCTAssertLessThanOrEqual(chunks.count, Int(100 * 1024 / ChunkPlanner.minimumChunkBytes) + 1)
    }
}
