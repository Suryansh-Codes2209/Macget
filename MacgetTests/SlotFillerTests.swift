import XCTest
@testable import Macget

final class SlotFillerTests: XCTestCase {

    private func chunk(_ start: Int64, _ end: Int64, written: Int64 = 0) -> Chunk {
        var c = Chunk(startByte: start, endByte: end)
        c.bytesWritten = written
        return c
    }

    func test_noneWhenAtCap() {
        let a = chunk(0, 10_000_000)
        let action = SlotFiller.nextAction(chunks: [a], assigned: [a.id], cap: 1)
        XCTAssertEqual(action, .none)
    }

    func test_spawnsOnUnassignedPiece() {
        let a = chunk(0, 10_000_000)
        let b = chunk(10_000_001, 20_000_000)
        let action = SlotFiller.nextAction(chunks: [a, b], assigned: [a.id], cap: 4)
        XCTAssertEqual(action, .spawn(b.id))
    }

    func test_prefersStealingOverSplitting() {
        // A huge assigned piece is a tempting split target, but an idle piece is
        // free to take — stealing costs no reconnect, so it must win.
        let big = chunk(0, 100_000_000)
        let idle = chunk(100_000_001, 110_000_000)
        let action = SlotFiller.nextAction(chunks: [big, idle], assigned: [big.id], cap: 4)
        XCTAssertEqual(action, .spawn(idle.id))
    }

    func test_skipsCompletePieces() {
        let done = chunk(0, 10_000_000, written: 10_000_001)
        let pending = chunk(10_000_001, 20_000_000)
        let action = SlotFiller.nextAction(chunks: [done, pending], assigned: [], cap: 4)
        XCTAssertEqual(action, .spawn(pending.id))
    }

    func test_splitsWhenEverythingIsAssigned() {
        // The endgame: one big piece still in flight, a worker just freed up.
        let a = chunk(0, 100_000_000)
        let action = SlotFiller.nextAction(chunks: [a], assigned: [a.id], cap: 4)
        guard case .split(let decision) = action else {
            return XCTFail("expected a split, got \(action)")
        }
        XCTAssertEqual(decision.originalID, a.id)
    }

    func test_doesNotSplitBelowMinimumSplitBytes() {
        // Under the floor a reconnect costs more than the tail it would rescue.
        let small = chunk(0, ChunkSplitter.defaultMinimumSplitBytes - 2)
        let action = SlotFiller.nextAction(chunks: [small], assigned: [small.id], cap: 4)
        XCTAssertEqual(action, .none)
    }

    func test_splitsExactlyAtMinimumSplitBytes() {
        let atFloor = chunk(0, ChunkSplitter.defaultMinimumSplitBytes - 1)
        let action = SlotFiller.nextAction(chunks: [atFloor], assigned: [atFloor.id], cap: 4)
        guard case .split = action else {
            return XCTFail("expected a split at exactly the floor, got \(action)")
        }
    }

    func test_respectsPieceCeiling() {
        // At the ceiling, splitting must stop even though the piece is large —
        // otherwise a long tail grows queue.json without bound.
        let big = chunk(0, 100_000_000)
        let action = SlotFiller.nextAction(
            chunks: [big], assigned: [big.id], cap: 4, maxPieces: 1
        )
        XCTAssertEqual(action, .none)
    }

    func test_splittingConvergesAndTilesExactly() {
        // Drive the loop the coordinator runs: repeatedly split with one free
        // slot. It must terminate, and coverage must stay exact.
        let total: Int64 = 64 * 1024 * 1024
        var chunks = [chunk(0, total - 1)]
        var assigned = Set(chunks.map(\.id))
        var iterations = 0

        while case .split(let d) = SlotFiller.nextAction(
            chunks: chunks, assigned: assigned, cap: 64
        ) {
            chunks[d.originalIndex] = d.shrunken
            chunks.append(d.newChunk)
            assigned.remove(d.originalID)
            assigned.insert(d.shrunken.id)
            assigned.insert(d.newChunk.id)
            iterations += 1
            XCTAssertLessThan(iterations, 500, "splitting must converge")
        }

        let sorted = chunks.sorted { $0.startByte < $1.startByte }
        XCTAssertEqual(sorted.first?.startByte, 0)
        XCTAssertEqual(sorted.last?.endByte, total - 1)
        for i in 1..<sorted.count {
            XCTAssertEqual(sorted[i].startByte, sorted[i - 1].endByte + 1)
        }
        XCTAssertEqual(sorted.reduce(Int64(0)) { $0 + $1.totalBytes }, total)
    }

    func test_splitNeverOvershootsTheCap() {
        // A split retires one worker and starts two, so it nets +1. Starting one
        // slot below the cap must land exactly on it, never above.
        let a = chunk(0, 100_000_000)
        let b = chunk(100_000_001, 200_000_000)
        var assigned: Set<UUID> = [a.id, b.id]
        var chunks = [a, b]

        guard case .split(let d) = SlotFiller.nextAction(
            chunks: chunks, assigned: assigned, cap: 3
        ) else { return XCTFail("expected a split") }

        chunks[d.originalIndex] = d.shrunken
        chunks.append(d.newChunk)
        assigned.remove(d.originalID)
        assigned.insert(d.shrunken.id)
        assigned.insert(d.newChunk.id)

        XCTAssertEqual(assigned.count, 3)
        XCTAssertEqual(
            SlotFiller.nextAction(chunks: chunks, assigned: assigned, cap: 3), .none
        )
    }
}
