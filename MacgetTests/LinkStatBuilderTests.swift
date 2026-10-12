import XCTest
@testable import Macget

final class LinkStatBuilderTests: XCTestCase {
    private let wifi = NetworkLink(id: "en0", displayName: "Wi-Fi", kind: .wifi, addresses: [], isDefaultRoute: true)
    private let tether = NetworkLink(id: "en7", displayName: "iPhone USB", kind: .tethered, addresses: [], isDefaultRoute: false)

    func test_buildsOneStatPerLinkInOrder() {
        let stats = LinkStatBuilder.build(
            links: [wifi, tether],
            speeds: ["en0": 1_000, "en7": 3_000],
            bytes: ["en0": 10, "en7": 30],
            connections: ["en0": 4, "en7": 4],
            statuses: [:]
        )
        XCTAssertEqual(stats.map(\.linkID), ["en0", "en7"])
        XCTAssertEqual(stats.map(\.speedBytesPerSec), [1_000, 3_000])
        XCTAssertEqual(stats.map(\.status), [.active, .active])
        XCTAssertEqual(stats.map(\.speedBytesPerSec).reduce(0, +), 4_000)
    }

    func test_rejectedLinkStillListedWithStatus() {
        let stats = LinkStatBuilder.build(links: [wifi, tether], speeds: ["en0": 1_000], bytes: ["en0": 10, "en7": 0],
                                          connections: ["en0": 8], statuses: ["en7": .rejectedByServer])
        XCTAssertEqual(stats.last?.status, .rejectedByServer)
        XCTAssertEqual(stats.last?.speedBytesPerSec, 0)
    }

    func test_goneLinkWithBytesIsKeptAsDown() {
        // The phone was unplugged: its link vanished from `links` but carried bytes earlier.
        let stats = LinkStatBuilder.build(links: [wifi], speeds: ["en0": 1_000], bytes: ["en0": 10, "en7": 99],
                                          connections: [:], statuses: ["en7": .down], knownNames: ["en7": ("iPhone USB", .tethered)])
        XCTAssertEqual(stats.map(\.linkID), ["en0", "en7"])
        XCTAssertEqual(stats.last?.status, .down)
    }

    func test_emptyWhenOnlyOneLinkInvolved() {
        XCTAssertEqual(LinkStatBuilder.build(links: [wifi], speeds: ["en0": 1], bytes: ["en0": 1], connections: [:], statuses: [:]), [])
    }
}
