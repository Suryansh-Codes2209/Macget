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
}
