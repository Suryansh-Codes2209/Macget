import XCTest
@testable import Macget

final class AdaptiveConcurrencyTests: XCTestCase {

    // MARK: - didImprove decision

    func test_keepsProbingWithNoBaseline() {
        XCTAssertTrue(AdaptiveConcurrency.didImprove(speedBefore: 0, speedAfter: 0))
        XCTAssertTrue(AdaptiveConcurrency.didImprove(speedBefore: -1, speedAfter: 1000))
    }

    func test_keepsWhenSpeedImprovedPastThreshold() {
        // +20% > 15% threshold → keep.
        XCTAssertTrue(AdaptiveConcurrency.didImprove(speedBefore: 1000, speedAfter: 1200))
    }

    func test_dropsWhenGainBelowThreshold() {
        // +5% < 15% → not worth it.
        XCTAssertFalse(AdaptiveConcurrency.didImprove(speedBefore: 1000, speedAfter: 1050))
    }

    func test_dropsWhenSpeedRegressed() {
        XCTAssertFalse(AdaptiveConcurrency.didImprove(speedBefore: 1000, speedAfter: 800))
    }

    func test_customThreshold() {
        XCTAssertTrue(AdaptiveConcurrency.didImprove(speedBefore: 1000, speedAfter: 1100, threshold: 0.05))
        XCTAssertFalse(AdaptiveConcurrency.didImprove(speedBefore: 1000, speedAfter: 1100, threshold: 0.20))
    }
}

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
