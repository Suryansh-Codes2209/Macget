import XCTest
@testable import Macget

final class TorrentLinkAttributionTests: XCTestCase {
    private let sample1 = """
    ,interface,bytes_in,
    aria2c.4242,,0,
    tcp4 192.168.0.5:50001<->1.2.3.4:6881,en0,1000,
    tcp4 172.20.10.2:50002<->5.6.7.8:6881,en7,2000,
    udp4 *:*<->*:*,,,
    """
    private let sample2 = """
    ,interface,bytes_in,
    aria2c.4242,,0,
    tcp4 192.168.0.5:50001<->1.2.3.4:6881,en0,1500,
    tcp4 172.20.10.2:50002<->5.6.7.8:6881,en7,4000,
    tcp4 172.20.10.2:50003<->9.9.9.9:6881,en7,300,
    """

    func test_parseSkipsHeaderProcessAndInterfacelessRows() {
        let rows = NettopParser.parse(sample1)
        XCTAssertEqual(rows.map(\.interface), ["en0", "en7"])
        XCTAssertEqual(rows.map(\.bytesIn), [1000, 2000])
    }

    func test_deltaPerInterfaceCountsNewSockets() {
        let d = NettopParser.delta(previous: NettopParser.parse(sample1), current: NettopParser.parse(sample2))
        XCTAssertEqual(d, ["en0": 500, "en7": 2300])
    }

    func test_socketCounts() {
        XCTAssertEqual(NettopParser.socketCounts(NettopParser.parse(sample2)), ["en0": 1, "en7": 2])
    }

    private let wifi = NetworkLink(id: "en0", displayName: "Wi-Fi", kind: .wifi, addresses: [], isDefaultRoute: true)
    private let tether = NetworkLink(id: "en7", displayName: "iPhone USB", kind: .tethered, addresses: [], isDefaultRoute: false)

    func test_singleTorrentIsExactAndNotEstimate() {
        let id = UUID()
        let stats = TorrentLinkAttributor.apportion(id: id, speeds: [id: 900], linkRates: ["en0": 300, "en7": 600],
                                                    links: [wifi, tether], available: true, cumulative: [:], sockets: ["en0": 2, "en7": 3])
        XCTAssertEqual(stats.map(\.speedBytesPerSec), [300, 600])
        XCTAssertEqual(stats.map(\.isEstimate), [false, false])
        XCTAssertEqual(stats.map(\.activeConnections), [2, 3])
    }

    func test_twoTorrentsSplitProportionallyAndAreEstimates() {
        let a = UUID(), b = UUID()
        let stats = TorrentLinkAttributor.apportion(id: a, speeds: [a: 300, b: 900], linkRates: ["en0": 400, "en7": 800],
                                                    links: [wifi, tether], available: true, cumulative: [:], sockets: [:])
        XCTAssertEqual(stats.map(\.speedBytesPerSec), [100, 200])
        XCTAssertEqual(stats.map(\.isEstimate), [true, true])
    }

    func test_unavailableYieldsNothing() {
        let id = UUID()
        XCTAssertEqual(TorrentLinkAttributor.apportion(id: id, speeds: [id: 1], linkRates: ["en0": 1, "en7": 1],
                                                       links: [wifi, tether], available: false, cumulative: [:], sockets: [:]), [])
    }

    func test_actorIgnoresFirstSampleAndAttributesSecond() async {
        let outputs = Outputs([sample1, sample2])
        let attributor = TorrentLinkAttributor(sampler: { _ in outputs.next() }, pidProvider: { 4242 }, autoSample: false)
        let id = UUID()
        await attributor.sampleNow()
        let first = await attributor.linkStats(for: id, speed: 1000, links: [wifi, tether])
        XCTAssertEqual(first, [], "first nettop sample has no baseline")
        await attributor.sampleNow()
        let second = await attributor.linkStats(for: id, speed: 1000, links: [wifi, tether])
        XCTAssertEqual(second.count, 2)
        XCTAssertGreaterThan(second[1].speedBytesPerSec, second[0].speedBytesPerSec)
    }

    func test_actorMarksUnavailableWhenNettopFails() async {
        let attributor = TorrentLinkAttributor(sampler: { _ in nil }, pidProvider: { 4242 }, autoSample: false)
        await attributor.sampleNow()
        let available = await attributor.isAvailable
        XCTAssertFalse(available)
    }
}

private final class Outputs: @unchecked Sendable {
    private var queue: [String]
    private let lock = NSLock()
    init(_ q: [String]) { queue = q }
    func next() -> String? { lock.lock(); defer { lock.unlock() }; return queue.isEmpty ? nil : queue.removeFirst() }
}
