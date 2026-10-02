import XCTest
@testable import Macget

final class ConnectionsSummaryTests: XCTestCase {
    private let wifi = NetworkLink(id: "en0", displayName: "Wi-Fi", kind: .wifi, addresses: ["192.168.1.2"], isDefaultRoute: true)
    private let phone = NetworkLink(id: "en7", displayName: "iPhone USB", kind: .tethered, addresses: ["172.20.10.2"], isDefaultRoute: false)

    private func stat(_ link: NetworkLink, _ speed: Double) -> LinkStat {
        LinkStat(linkID: link.id, displayName: link.displayName, kind: link.kind, speedBytesPerSec: speed,
                 bytesThisSession: 0, activeConnections: 2, status: .active, isEstimate: false)
    }

    func test_oneChipPerLinkInMonitorOrder() {
        let chips = ConnectionsSummary.chips(links: [wifi, phone], totals: [], totalSpeed: 0, bonding: BondingSettings())
        XCTAssertEqual(chips.map(\.id), ["en0", "en7"])
        XCTAssertEqual(chips.map(\.displayName), ["Wi-Fi", "iPhone USB"])
        XCTAssertTrue(chips[0].isDefaultRoute)
        XCTAssertEqual(chips.map(\.speedBytesPerSec), [0, 0])
    }

    func test_speedsComeFromLinkTotals() {
        let chips = ConnectionsSummary.chips(links: [wifi, phone],
                                             totals: [stat(wifi, 1_000), stat(phone, 3_000)],
                                             totalSpeed: 4_000,
                                             bonding: BondingSettings(enabled: true))
        XCTAssertEqual(chips.map(\.speedBytesPerSec), [1_000, 3_000])
        XCTAssertTrue(ConnectionsSummary.showsTotal(chips))
    }

    func test_unbondedTrafficIsAttributedToTheDefaultRoute() {
        // Bonding off: every byte rides the default route, so that link's speed is the total.
        let chips = ConnectionsSummary.chips(links: [wifi, phone], totals: [], totalSpeed: 2_500, bonding: BondingSettings())
        XCTAssertEqual(chips.map(\.speedBytesPerSec), [2_500, 0])
        XCTAssertFalse(ConnectionsSummary.showsTotal(chips), "one moving link has nothing to total")
    }

    func test_bondedButUnsplitTrafficIsNotGuessed() {
        // Two usable bonded links but no breakdown yet: which one carries the bytes is unknown.
        let chips = ConnectionsSummary.chips(links: [wifi, phone], totals: [], totalSpeed: 2_500, bonding: BondingSettings(enabled: true))
        XCTAssertEqual(chips.map(\.speedBytesPerSec), [0, 0])
    }

    func test_bondingOnWithOneEnabledLinkStillAttributesToDefault() {
        let bonding = BondingSettings(enabled: true, disabledLinkIDs: ["en7"])
        let chips = ConnectionsSummary.chips(links: [wifi, phone], totals: [], totalSpeed: 900, bonding: bonding)
        XCTAssertEqual(chips.map(\.speedBytesPerSec), [900, 0])
    }

    func test_disabledLinksAreMarked() {
        let bonding = BondingSettings(enabled: true, disabledLinkIDs: ["en7"])
        let chips = ConnectionsSummary.chips(links: [wifi, phone], totals: [], totalSpeed: 0, bonding: bonding)
        XCTAssertEqual(chips.map(\.isEnabled), [true, false])
    }

    func test_totalsForVanishedLinksAreIgnored() {
        let gone = NetworkLink(id: "en9", displayName: "Ethernet", kind: .wiredEthernet, addresses: [], isDefaultRoute: false)
        let chips = ConnectionsSummary.chips(links: [wifi], totals: [stat(wifi, 10), stat(gone, 20)], totalSpeed: 30,
                                             bonding: BondingSettings(enabled: true))
        XCTAssertEqual(chips.map(\.id), ["en0"])
    }

    func test_accessibilityLabelNamesLinksAndState() {
        let idle = ConnectionsSummary.chips(links: [wifi, phone], totals: [], totalSpeed: 0, bonding: BondingSettings(enabled: true))
        XCTAssertEqual(ConnectionsSummary.accessibilityLabel(chips: idle, combining: true),
                       "Connections: Wi-Fi, iPhone USB. Combining on.")
        XCTAssertEqual(ConnectionsSummary.accessibilityLabel(chips: idle, combining: false),
                       "Connections: Wi-Fi, iPhone USB. Combining off.")
    }

    func test_accessibilityLabelIncludesSpeedsAndExclusions() {
        let bonding = BondingSettings(enabled: true, disabledLinkIDs: ["en7"])
        let chips = ConnectionsSummary.chips(links: [wifi, phone], totals: [], totalSpeed: 1_000_000, bonding: bonding)
        XCTAssertEqual(ConnectionsSummary.accessibilityLabel(chips: chips, combining: true),
                       "Connections: Wi-Fi \(ByteFormatter.speedString(1_000_000)), iPhone USB (not used). Combining on.")
    }
}
