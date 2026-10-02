import XCTest
@testable import Macget

final class BondingPolicyTests: XCTestCase {
    private let wifi = NetworkLink(id: "en0", displayName: "Wi-Fi", kind: .wifi, addresses: ["192.168.0.5"], isDefaultRoute: true)
    private let tether = NetworkLink(id: "en7", displayName: "iPhone USB", kind: .tethered, addresses: ["172.20.10.2"], isDefaultRoute: false)
    private let eth = NetworkLink(id: "en5", displayName: "Ethernet", kind: .wiredEthernet, addresses: ["10.0.0.2", "2001:db8::2"], isDefaultRoute: false)

    func test_evenSplitAcrossTwoLinks() {
        XCTAssertEqual(BondingPolicy.quotas(links: [wifi, tether], threadCount: 8), [
            LinkQuota(linkID: "en0", isDefault: true, slots: 4),
            LinkQuota(linkID: "en7", isDefault: false, slots: 4),
        ])
    }

    func test_remainderGoesToPreferredLink() {
        XCTAssertEqual(BondingPolicy.quotas(links: [wifi, tether], threadCount: 5).map(\.slots), [3, 2])
    }

    func test_singleLinkMeansNoQuotas() {
        XCTAssertEqual(BondingPolicy.quotas(links: [wifi], threadCount: 8), [])
    }

    func test_tooFewThreadsForTwoPerLinkMeansNoQuotas() {
        XCTAssertEqual(BondingPolicy.quotas(links: [wifi, tether], threadCount: 3), [])
    }

    func test_dropsLeastPreferredLinkWhenBudgetIsTight() {
        // 5 threads fit two links at 2+ each; the tethered link is the one dropped.
        let q = BondingPolicy.quotas(links: LinkFilter.sorted([tether, eth, wifi]), threadCount: 5)
        XCTAssertEqual(q.map(\.linkID), ["en0", "en5"])
    }

    func test_threadCountClampedTo16() {
        XCTAssertEqual(BondingPolicy.quotas(links: [wifi, tether], threadCount: 40).map(\.slots).reduce(0, +), 16)
    }

    func test_activeLinksHonorsSettingsAndExclusions() {
        let settings = BondingSettings(enabled: true, disabledLinkIDs: ["en5"])
        let active = BondingPolicy.activeLinks([wifi, tether, eth], settings: settings, excluded: ["en7"])
        XCTAssertEqual(active.map(\.id), ["en0"])
        XCTAssertEqual(BondingPolicy.activeLinks([wifi, tether], settings: BondingSettings(), excluded: []), [])
    }

    func test_nextLinkPicksMostUnderfilled() {
        let q = BondingPolicy.quotas(links: [wifi, tether], threadCount: 8)
        XCTAssertEqual(BondingPolicy.nextLink(quotas: q, occupied: ["en0": 4, "en7": 1])?.linkID, "en7")
        XCTAssertEqual(BondingPolicy.nextLink(quotas: q, occupied: [:])?.linkID, "en0")
        XCTAssertNil(BondingPolicy.nextLink(quotas: q, occupied: ["en0": 4, "en7": 4]))
    }

    func test_torrentAddressesNeedTwoEnabledLinks() {
        let on = BondingSettings(enabled: true)
        XCTAssertEqual(BondingPolicy.torrentAddresses(links: [wifi, eth], settings: on), ["192.168.0.5", "10.0.0.2"])
        XCTAssertEqual(BondingPolicy.torrentAddresses(links: [wifi], settings: on), [])
        XCTAssertEqual(BondingPolicy.torrentAddresses(links: [wifi, eth], settings: BondingSettings()), [])
    }

    func test_strikesExcludeAfterThreeInWindow() {
        var strikes = LinkStrikes()
        let t0 = Date()
        XCTAssertFalse(strikes.record("en7", at: t0))
        XCTAssertFalse(strikes.record("en7", at: t0.addingTimeInterval(1)))
        XCTAssertFalse(strikes.record("en0", at: t0.addingTimeInterval(1)))
        XCTAssertTrue(strikes.record("en7", at: t0.addingTimeInterval(2)))
    }

    func test_strikesOutsideWindowAreForgotten() {
        var strikes = LinkStrikes()
        let t0 = Date()
        _ = strikes.record("en7", at: t0)
        _ = strikes.record("en7", at: t0.addingTimeInterval(1))
        XCTAssertFalse(strikes.record("en7", at: t0.addingTimeInterval(45)))
    }

    func test_eligibility() {
        let https = URL(string: "https://example.com/a.iso")!
        XCTAssertTrue(BondingEligibility.isEligible(url: https, supportsRange: true, appProxyConfigured: false, systemProxyActive: false))
        XCTAssertFalse(BondingEligibility.isEligible(url: https, supportsRange: false, appProxyConfigured: false, systemProxyActive: false))
        XCTAssertFalse(BondingEligibility.isEligible(url: https, supportsRange: true, appProxyConfigured: true, systemProxyActive: false))
        XCTAssertFalse(BondingEligibility.isEligible(url: https, supportsRange: true, appProxyConfigured: false, systemProxyActive: true))
        XCTAssertFalse(BondingEligibility.isEligible(url: URL(string: "ftp://example.com/a")!, supportsRange: true, appProxyConfigured: false, systemProxyActive: false))
    }
}
