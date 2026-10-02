import XCTest
@testable import Macget

final class LinkFilterTests: XCTestCase {
    func test_excludesVirtualAndTunnelInterfaces() {
        for name in ["lo0", "utun3", "ipsec0", "awdl0", "llw0", "bridge0", "gif0", "stf0", "anpi1", "ap1", "nan0"] {
            XCTAssertFalse(LinkFilter.isCandidate(bsdName: name), name)
        }
        for name in ["en0", "en7", "en12"] {
            XCTAssertTrue(LinkFilter.isCandidate(bsdName: name), name)
        }
    }

    func test_classifiesTetheredByDisplayName() {
        // A USB-tethered iPhone presents as wired Ethernet; only its name gives it away.
        XCTAssertEqual(LinkFilter.classify(type: .wiredEthernet, displayName: "iPhone USB"), .tethered)
        XCTAssertEqual(LinkFilter.classify(type: .wiredEthernet, displayName: "iPad"), .tethered)
        XCTAssertEqual(LinkFilter.classify(type: .other, displayName: "Android RNDIS"), .tethered)
        XCTAssertEqual(LinkFilter.classify(type: .cellular, displayName: "anything"), .tethered)
        XCTAssertEqual(LinkFilter.classify(type: .wifi, displayName: "Wi-Fi"), .wifi)
        XCTAssertEqual(LinkFilter.classify(type: .wiredEthernet, displayName: "Thunderbolt Ethernet"), .wiredEthernet)
        XCTAssertEqual(LinkFilter.classify(type: .other, displayName: "Mystery"), .other)
    }

    func test_sortsDefaultFirstThenByKind() {
        let tether = NetworkLink(id: "en7", displayName: "iPhone USB", kind: .tethered, addresses: ["172.20.10.2"], isDefaultRoute: false)
        let wifi = NetworkLink(id: "en0", displayName: "Wi-Fi", kind: .wifi, addresses: ["192.168.0.5"], isDefaultRoute: true)
        let eth = NetworkLink(id: "en5", displayName: "Ethernet", kind: .wiredEthernet, addresses: ["10.0.0.2"], isDefaultRoute: false)
        XCTAssertEqual(LinkFilter.sorted([tether, eth, wifi]).map(\.id), ["en0", "en5", "en7"])
    }

    func test_ipv4AddressesExcludeIPv6() {
        let l = NetworkLink(id: "en0", displayName: "Wi-Fi", kind: .wifi, addresses: ["192.168.0.5", "2001:db8::1"], isDefaultRoute: true)
        XCTAssertEqual(l.ipv4Addresses, ["192.168.0.5"])
    }

    func test_aggregateSumsPerLinkAcrossDownloads() {
        func stat(_ id: String, _ kind: NetworkLink.Kind, _ speed: Double, estimate: Bool = false) -> LinkStat {
            LinkStat(linkID: id, displayName: id, kind: kind, speedBytesPerSec: speed, bytesThisSession: 10,
                     activeConnections: 2, status: .active, isEstimate: estimate)
        }
        let a = [stat("en0", .wifi, 100), stat("en7", .tethered, 300)]
        let b = [stat("en0", .wifi, 50), stat("en7", .tethered, 50, estimate: true)]
        let total = LinkStat.aggregate([a, b])
        XCTAssertEqual(total.map(\.linkID), ["en0", "en7"])
        XCTAssertEqual(total.map(\.speedBytesPerSec), [150, 350])
        XCTAssertEqual(total.map(\.bytesThisSession), [20, 20])
        XCTAssertEqual(total.map(\.activeConnections), [4, 4])
        XCTAssertEqual(total.map(\.isEstimate), [false, true])
    }

    func test_aggregateIsEmptyWithFewerThanTwoMovingLinks() {
        let only = [LinkStat(linkID: "en0", displayName: "Wi-Fi", kind: .wifi, speedBytesPerSec: 100,
                             bytesThisSession: 1, activeConnections: 1, status: .active, isEstimate: false),
                    LinkStat(linkID: "en7", displayName: "iPhone USB", kind: .tethered, speedBytesPerSec: 0,
                             bytesThisSession: 0, activeConnections: 0, status: .active, isEstimate: false)]
        XCTAssertTrue(LinkStat.aggregate([only]).isEmpty)
    }
}
