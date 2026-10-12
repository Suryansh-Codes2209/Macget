import XCTest
@testable import Macget

final class LinkBreakdownTextTests: XCTestCase {
    private func stat(_ id: String, _ name: String, _ speed: Double, estimate: Bool = false, status: LinkStat.Status = .active) -> LinkStat {
        LinkStat(linkID: id, displayName: name, kind: .wifi, speedBytesPerSec: speed, bytesThisSession: 0,
                 activeConnections: 1, status: status, isEstimate: estimate)
    }

    func test_captionListsEachMovingLink() {
        let caption = LinkBreakdownText.caption([stat("en0", "Wi-Fi", 1_200_000), stat("en7", "iPhone USB", 3_400_000)])
        XCTAssertEqual(caption, "Wi-Fi \(ByteFormatter.speedString(1_200_000)) · iPhone USB \(ByteFormatter.speedString(3_400_000))")
    }

    func test_captionPrefixesEstimate() {
        XCTAssertTrue(LinkBreakdownText.caption([stat("en0", "Wi-Fi", 1, estimate: true), stat("en7", "iPhone USB", 1)]).hasPrefix("≈ "))
    }

    func test_captionOmitsStoppedLinks() {
        let caption = LinkBreakdownText.caption([stat("en0", "Wi-Fi", 1000), stat("en7", "iPhone USB", 0, status: .rejectedByServer)])
        XCTAssertFalse(caption.contains("iPhone"))
    }

    func test_accessibilityIncludesPercent() {
        let a11y = LinkBreakdownText.accessibility([stat("en0", "Wi-Fi", 250), stat("en7", "iPhone USB", 750)])
        XCTAssertTrue(a11y.contains("Wi-Fi"))
        XCTAssertTrue(a11y.contains("25 percent"))
        XCTAssertTrue(a11y.contains("75 percent"))
    }

    func test_statusText() {
        XCTAssertEqual(LinkBreakdownText.statusText(.active), "Active")
        XCTAssertEqual(LinkBreakdownText.statusText(.rejectedByServer), "Not accepted by server")
        XCTAssertEqual(LinkBreakdownText.statusText(.down), "Link down")
    }
}
