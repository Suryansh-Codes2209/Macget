import XCTest
@testable import Macget

/// Everything the menu bar item displays, derived from the list view model's
/// rows. Kept as a pure value type so the interesting decisions — what counts as
/// active, what the ring shows, when the menu truncates — are testable without
/// an `NSStatusItem`.
final class StatusBarModelTests: XCTestCase {

    private func row(
        _ name: String,
        status: DownloadStatus,
        done: Int64 = 0,
        total: Int64? = nil
    ) -> DownloadRowItem {
        DownloadRowItem(
            id: UUID(), filename: name,
            url: URL(string: "https://example.com/\(name)")!,
            destinationURL: URL(fileURLWithPath: "/tmp/\(name)"),
            status: status, totalBytes: total, bytesDownloaded: done,
            speedBytesPerSec: 0, etaSeconds: nil, error: nil, createdAt: Date(),
            threadCount: 1, supportsRange: true, priority: .normal, phase: nil,
            kind: .httpFile, uploadSpeedBytesPerSec: 0, uploadedBytes: nil,
            seeders: nil, peers: nil, isSeeding: false, torrentFiles: nil
        )
    }

    // MARK: - Idle

    func test_idleWhenNothingIsDownloading() {
        let model = StatusBarModel(rows: [row("a.zip", status: .completed)], totalSpeed: 0)
        XCTAssertFalse(model.isActive)
        XCTAssertNil(model.fractionComplete)
        XCTAssertTrue(model.titleText.isEmpty, "no speed text when idle — the icon alone says MacGet is running")
        XCTAssertTrue(model.entries.isEmpty)
    }

    func test_idleWithAnEmptyQueue() {
        let model = StatusBarModel(rows: [], totalSpeed: 0)
        XCTAssertFalse(model.isActive)
        XCTAssertNil(model.fractionComplete)
    }

    // MARK: - Active

    func test_activeReportsSpeedAndFraction() {
        let model = StatusBarModel(
            rows: [row("a.bin", status: .downloading, done: 50, total: 100)],
            totalSpeed: 4_200_000
        )
        XCTAssertTrue(model.isActive)
        XCTAssertEqual(model.fractionComplete ?? 0, 0.5, accuracy: 0.001)
        XCTAssertFalse(model.titleText.isEmpty)
        XCTAssertEqual(model.entries.count, 1)
        XCTAssertEqual(model.entries[0].percentText, "50%")
    }

    /// Progress is aggregate bytes, not an average of percentages — a 1 GB file
    /// at 10% and a 1 MB file at 90% is not "50% done".
    func test_fractionIsByteWeightedAcrossDownloads() {
        let model = StatusBarModel(
            rows: [
                row("big.bin", status: .downloading, done: 100, total: 1000),
                row("small.bin", status: .downloading, done: 9, total: 10),
            ],
            totalSpeed: 1000
        )
        XCTAssertEqual(model.fractionComplete ?? 0, 109.0 / 1010.0, accuracy: 0.0001)
    }

    /// A download whose size the server never reported can't contribute to a
    /// ring, but it must still count as active.
    func test_unknownSizeStillCountsAsActive() {
        let model = StatusBarModel(
            rows: [row("stream.bin", status: .downloading, done: 500, total: nil)],
            totalSpeed: 1000
        )
        XCTAssertTrue(model.isActive)
        XCTAssertNil(model.fractionComplete)
        XCTAssertEqual(model.entries.count, 1)
        XCTAssertEqual(model.entries[0].percentText, "—")
    }

    func test_queuedCountsAsActiveButNotAsProgress() {
        let model = StatusBarModel(
            rows: [row("waiting.bin", status: .queued, total: 100)],
            totalSpeed: 0
        )
        XCTAssertTrue(model.isActive)
        XCTAssertEqual(model.entries.count, 1)
    }

    func test_pausedAndFailedAreNotActive() {
        let model = StatusBarModel(
            rows: [row("p.bin", status: .paused), row("f.bin", status: .failed)],
            totalSpeed: 0
        )
        XCTAssertFalse(model.isActive)
        XCTAssertTrue(model.entries.isEmpty)
    }

    // MARK: - Menu truncation

    func test_truncatesLongMenusAndReportsTheRemainder() {
        let rows = (0..<12).map { row("f\($0).bin", status: .downloading, done: 1, total: 10) }
        let model = StatusBarModel(rows: rows, totalSpeed: 1000)
        XCTAssertEqual(model.entries.count, StatusBarModel.maxEntries)
        XCTAssertEqual(model.overflowText, "+\(12 - StatusBarModel.maxEntries) more")
    }

    func test_noOverflowLineWhenEverythingFits() {
        let rows = (0..<3).map { row("f\($0).bin", status: .downloading, done: 1, total: 10) }
        XCTAssertNil(StatusBarModel(rows: rows, totalSpeed: 1000).overflowText)
    }

    func test_headerCountsActiveDownloads() {
        let rows = [
            row("a.bin", status: .downloading, done: 1, total: 10),
            row("b.bin", status: .downloading, done: 1, total: 10),
            row("c.bin", status: .completed),
        ]
        let model = StatusBarModel(rows: rows, totalSpeed: 1000)
        XCTAssertTrue(model.headerText.contains("2"), "header should count only the active ones: \(model.headerText)")
    }
}
