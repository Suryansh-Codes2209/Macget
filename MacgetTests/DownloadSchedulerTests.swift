import XCTest
@testable import Macget

final class DownloadSchedulerTests: XCTestCase {

    private func make(_ name: String, _ priority: DownloadPriority) -> Download {
        Download(
            url: URL(string: "https://example.com/\(name)")!,
            destinationFolder: URL(fileURLWithPath: "/tmp"),
            filename: name,
            priority: priority
        )
    }

    func test_highPriorityScheduledFirst() {
        let queue = [make("a", .normal), make("b", .high), make("c", .low)]
        let ordered = DownloadScheduler.order(queue).map(\.filename)
        XCTAssertEqual(ordered, ["b", "a", "c"])
    }

    func test_tiesKeepInsertionOrder() {
        let queue = [make("a", .normal), make("b", .normal), make("c", .normal)]
        let ordered = DownloadScheduler.order(queue).map(\.filename)
        XCTAssertEqual(ordered, ["a", "b", "c"])
    }

    func test_stableWithinEachPriorityBand() {
        let queue = [
            make("n1", .normal), make("h1", .high), make("l1", .low),
            make("h2", .high), make("n2", .normal), make("l2", .low),
        ]
        let ordered = DownloadScheduler.order(queue).map(\.filename)
        XCTAssertEqual(ordered, ["h1", "h2", "n1", "n2", "l1", "l2"])
    }

    func test_emptyQueue() {
        XCTAssertTrue(DownloadScheduler.order([]).isEmpty)
    }
}
