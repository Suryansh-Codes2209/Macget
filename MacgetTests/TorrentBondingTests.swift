import XCTest
@testable import Macget

final class TorrentBondingTests: XCTestCase {
    func test_multipleInterfacePresentOnlyWithAddresses() {
        var options = TorrentEngineOptions()
        XCTAssertFalse(Aria2Daemon.arguments(port: 1, secret: "s", options: options)
            .contains { $0.hasPrefix("--multiple-interface") })

        options.bondingAddresses = ["192.168.0.5", "172.20.10.2"]
        XCTAssertTrue(Aria2Daemon.arguments(port: 1, secret: "s", options: options)
            .contains("--multiple-interface=192.168.0.5,172.20.10.2"))
    }

    func test_bondingAddressesAreLaunchOnly() {
        var options = TorrentEngineOptions()
        options.bondingAddresses = ["192.168.0.5", "172.20.10.2"]
        XCTAssertNil(options.mutableGlobalOptions["multiple-interface"])
    }

    func test_settingsDoNotCarryAddresses() {
        // Addresses come from live links, never from persisted settings.
        var settings = AppSettings()
        settings.bonding = BondingSettings(enabled: true)
        XCTAssertEqual(settings.torrentOptions.bondingAddresses, [])
    }
}

final class TorrentRestartPlanTests: XCTestCase {
    func test_onlyActiveTorrentsRestart() {
        let ids = (0..<5).map { _ in UUID() }
        let plan = TorrentRestartPlan.plan([
            (ids[0], .downloading), (ids[1], .queued), (ids[2], .paused),
            (ids[3], .completed), (ids[4], .failed),
        ])
        XCTAssertEqual(Set(plan.restart), [ids[0], ids[1]])
        XCTAssertEqual(Set(plan.drop), [ids[2], ids[3], ids[4]])
    }

    func test_addressComparisonIsOrderInsensitive() {
        XCTAssertTrue(TorrentRestartPlan.sameAddressSet(["a", "b"], ["b", "a"]))
        XCTAssertFalse(TorrentRestartPlan.sameAddressSet(["a"], ["a", "b"]))
        XCTAssertTrue(TorrentRestartPlan.sameAddressSet([], []))
    }
}
